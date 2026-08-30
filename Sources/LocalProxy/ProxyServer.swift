import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Network)
import Network
import os
#endif

public enum ProxyServerError: Error {
    case networkingUnavailable
    case alreadyRunning
    case startupTimedOut
}

public final class ProxyServer: Sendable {
    public struct Configuration: Sendable {
        public let port: UInt16?
        public let maximumRequestBytes: Int
        public let maximumConnectionCount: Int

        public init(
            port: UInt16? = nil,
            maximumRequestBytes: Int = 64 * 1024,
            maximumConnectionCount: Int = 128
        ) {
            self.port = port
            self.maximumRequestBytes = max(1024, maximumRequestBytes)
            self.maximumConnectionCount = max(1, maximumConnectionCount)
        }
    }

    private let router: ProxyRouter
    private let configuration: Configuration

#if canImport(Network)
    private struct ListenerState {
        var listener: NWListener?
        var port: UInt16?
        var error: NWError?
    }
    private struct Client {
        let connection: NWConnection
        var task: Task<Void, Never>?
        var buffer = Data()
        var isResponding = false
    }
    private let listener = OSAllocatedUnfairLock(initialState: ListenerState())
    private let clients = OSAllocatedUnfairLock<[ObjectIdentifier: Client]>(initialState: [:])
    private let queue = DispatchQueue(label: "com.hlsproxybuffer.proxy", qos: .userInitiated)
#endif

    public init(configuration: Configuration = .init(), router: ProxyRouter) {
        self.configuration = configuration
        self.router = router
    }

    deinit { stop() }

    public func start() throws {
#if canImport(Network)
        let newListener = try listener.withLock { state in
            guard state.listener == nil else { throw ProxyServerError.alreadyRunning }
            let port = configuration.port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let value = try NWListener(using: parameters)
            state = ListenerState(listener: value)
            return value
        }
        router.freeze()
        newListener.stateUpdateHandler = { [weak self, weak newListener] update in
            guard let self, let newListener else { return }
            listener.withLock { state in
                guard state.listener === newListener else { return }
                switch update {
                case .ready: state.port = newListener.port?.rawValue
                case .failed(let error), .waiting(let error):
                    state.port = nil
                    state.error = error
                case .cancelled: state.port = nil
                default: break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        newListener.start(queue: queue)
#else
        throw ProxyServerError.networkingUnavailable
#endif
    }

    /// Returns a usable bound URL, or propagates bind failure/cancellation.
    /// A caller can explicitly fall back to another origin without mistaking a
    /// configured but unbound port for a running server.
    public func startAndWait(timeout: Duration = .seconds(2)) async throws -> URL {
        try start()
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try Task.checkCancellation()
#if canImport(Network)
                if let error = listener.withLock({ $0.error }) { throw error }
#endif
                if let baseURL { return baseURL }
                try await clock.sleep(for: .milliseconds(10))
            }
            throw ProxyServerError.startupTimedOut
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
#if canImport(Network)
        let current = listener.withLock { state in
            defer { state = ListenerState() }
            return state.listener
        }
        current?.cancel()
        let active = clients.withLock { value in
            defer { value.removeAll() }
            return Array(value.values)
        }
        for client in active {
            client.task?.cancel()
            client.connection.cancel()
        }
#endif
    }

    public var port: UInt16? {
#if canImport(Network)
        listener.withLock { $0.port }
#else
        nil
#endif
    }

    public var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

#if canImport(Network)
    private func handle(connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let admitted = listener.withLock { state in
            guard state.listener != nil else { return false }
            return clients.withLock { clients in
                guard clients.count < configuration.maximumConnectionCount else { return false }
                clients[key] = Client(connection: connection)
                return true
            }
        }
        guard admitted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                let client = self?.clients.withLock { $0.removeValue(forKey: key) }
                client?.task?.cancel()
                client?.connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                disconnect(connection)
                return
            }
            let accepted = clients.withLock { clients in
                let key = ObjectIdentifier(connection)
                guard var client = clients[key] else { return false }
                if let data { client.buffer.append(data) }
                guard client.buffer.count <= configuration.maximumRequestBytes else { return false }
                clients[key] = client
                return true
            }
            guard accepted else { disconnect(connection); return }
            processNextRequest(on: connection)
            // Observe closure even while a route is suspended or its body is
            // being sent. Pipelined input remains bounded in the client buffer.
            receive(on: connection)
        }
    }

    private func processNextRequest(on connection: NWConnection) {
        do {
            let request = try clients.withLock { clients -> HTTPRequest? in
                let key = ObjectIdentifier(connection)
                guard var client = clients[key], !client.isResponding else { return nil }
                guard let parsed = try HTTPRequestParser.parseAvailable(
                    data: client.buffer,
                    maximumRequestBytes: configuration.maximumRequestBytes
                ) else { return nil }
                client.buffer = Data(client.buffer.dropFirst(parsed.consumedBytes))
                client.isResponding = true
                clients[key] = client
                return parsed.request
            }
            guard let request else { return }
            let router = router
            let task = Task { [weak self] in
                let response = await router.handle(request)
                guard let self, !Task.isCancelled else { return }
                let responseWantsClose = response.headers["Connection"]?.lowercased() == "close"
                send(
                    response, for: request,
                    keepAlive: request.shouldKeepAlive && !responseWantsClose,
                    on: connection
                )
            }
            let retained = clients.withLock { clients in
                let key = ObjectIdentifier(connection)
                guard clients[key] != nil else { return false }
                clients[key]?.task = task
                return true
            }
            if !retained { task.cancel() }
        } catch {
            let status: HTTPResponse.Status
            switch error as? HTTPRequestParser.ParserError {
            case .requestTooLarge: status = .payloadTooLarge
            case .unsupportedMethod: status = .methodNotAllowed
            default: status = .badRequest
            }
            clients.withLock { $0[ObjectIdentifier(connection)]?.isResponding = true }
            send(HTTPResponse(status: status), for: nil, keepAlive: false, on: connection)
        }
    }

    private func disconnect(_ connection: NWConnection) {
        let client = clients.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) }
        client?.task?.cancel()
        connection.cancel()
    }

    private func send(
        _ response: HTTPResponse,
        for request: HTTPRequest?,
        keepAlive: Bool,
        on connection: NWConnection
    ) {
        let includesBody = request?.method != .head && response.status != .notModified
        let header = response.headerData(
            connection: keepAlive ? "keep-alive" : "close",
            includeBody: includesBody
        )
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }
            let shouldSendBody = includesBody && !response.body.isEmpty
            guard shouldSendBody else {
                finishResponse(keepAlive: keepAlive, on: connection)
                return
            }
            connection.send(content: response.body, completion: .contentProcessed { [weak self] error in
                // Keep the response's admission lease through Network's final
                // send completion (including error), not merely route return.
                defer { withExtendedLifetime(response) {} }
                guard let self else { return }
                guard error == nil else {
                    connection.cancel()
                    return
                }
                finishResponse(keepAlive: keepAlive, on: connection)
            })
        })
    }

    private func finishResponse(keepAlive: Bool, on connection: NWConnection) {
        clients.withLock {
            $0[ObjectIdentifier(connection)]?.task = nil
            $0[ObjectIdentifier(connection)]?.isResponding = false
        }
        guard keepAlive else {
            disconnect(connection)
            return
        }
        processNextRequest(on: connection)
    }
#endif
}
