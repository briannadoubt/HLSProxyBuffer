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
}

public final class ProxyServer: Sendable {
    public struct Configuration: Sendable {
        public let port: UInt16?
        public let maximumRequestBytes: Int

        public init(port: UInt16? = nil, maximumRequestBytes: Int = 64 * 1024) {
            self.port = port
            self.maximumRequestBytes = max(1024, maximumRequestBytes)
        }
    }

    private let router: ProxyRouter
    private let configuration: Configuration

#if canImport(Network)
    private let listener = OSAllocatedUnfairLock<NWListener?>(initialState: nil)
    private let queue = DispatchQueue(label: "com.hlsproxybuffer.proxy", qos: .userInitiated)
#endif

    public init(configuration: Configuration = .init(), router: ProxyRouter) {
        self.configuration = configuration
        self.router = router
    }

    public func start() throws {
#if canImport(Network)
        guard listener.withLock({ $0 == nil }) else { throw ProxyServerError.alreadyRunning }
        let port = configuration.port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let newListener = try NWListener(using: parameters)
        router.freeze()
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.withLock { $0 = newListener }
        newListener.start(queue: queue)
#else
        throw ProxyServerError.networkingUnavailable
#endif
    }

    public func stop() {
#if canImport(Network)
        let current = listener.withLock { value -> NWListener? in
            defer { value = nil }
            return value
        }
        current?.cancel()
#endif
    }

    public var port: UInt16? {
#if canImport(Network)
        listener.withLock { $0?.port?.rawValue ?? configuration.port }
#else
        configuration.port
#endif
    }

    public var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

#if canImport(Network)
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if accumulated.count > configuration.maximumRequestBytes {
                send(
                    HTTPResponse(status: .payloadTooLarge),
                    for: nil,
                    keepAlive: false,
                    remainder: Data(),
                    on: connection
                )
                return
            }

            do {
                if let parsed = try HTTPRequestParser.parseAvailable(
                    data: accumulated,
                    maximumRequestBytes: configuration.maximumRequestBytes
                ) {
                    let remainder = accumulated.dropFirst(parsed.consumedBytes)
                    Task { [weak self] in
                        guard let self else { return }
                        let response = await router.handle(parsed.request)
                        let responseWantsClose = response.headers["Connection"]?.lowercased() == "close"
                        send(
                            response,
                            for: parsed.request,
                            keepAlive: parsed.request.shouldKeepAlive && !responseWantsClose,
                            remainder: Data(remainder),
                            on: connection
                        )
                    }
                    return
                }
            } catch let parserError as HTTPRequestParser.ParserError {
                let status: HTTPResponse.Status
                switch parserError {
                case .requestTooLarge:
                    status = .payloadTooLarge
                case .unsupportedMethod:
                    status = .methodNotAllowed
                default:
                    status = .badRequest
                }
                send(HTTPResponse(status: status), for: nil, keepAlive: false, remainder: Data(), on: connection)
                return
            } catch {
                send(HTTPResponse(status: .badRequest), for: nil, keepAlive: false, remainder: Data(), on: connection)
                return
            }

            if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffer: accumulated)
            }
        }
    }

    private func send(
        _ response: HTTPResponse,
        for request: HTTPRequest?,
        keepAlive: Bool,
        remainder: Data,
        on connection: NWConnection
    ) {
        let header = response.headerData(connection: keepAlive ? "keep-alive" : "close")
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }
            let shouldSendBody = request?.method != .head && !response.body.isEmpty
            guard shouldSendBody else {
                finishResponse(keepAlive: keepAlive, remainder: remainder, on: connection)
                return
            }
            connection.send(content: response.body, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    connection.cancel()
                    return
                }
                finishResponse(keepAlive: keepAlive, remainder: remainder, on: connection)
            })
        })
    }

    private func finishResponse(keepAlive: Bool, remainder: Data, on connection: NWConnection) {
        guard keepAlive else {
            connection.cancel()
            return
        }
        if remainder.isEmpty {
            receive(on: connection, buffer: Data())
        } else {
            receive(on: connection, buffer: remainder)
        }
    }
#endif
}
