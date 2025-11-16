import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Network)
import Network
#endif

public enum ProxyServerError: Error {
    case networkingUnavailable
    case alreadyRunning
}

public final class ProxyServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let port: UInt16?

        public init(port: UInt16? = nil) {
            self.port = port
        }
    }

    private let router: ProxyRouter
    private let configuration: Configuration

#if canImport(Network)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.hlsproxybuffer.proxy")
#endif

    public init(configuration: Configuration = .init(), router: ProxyRouter) {
        self.configuration = configuration
        self.router = router
    }

    public func start() throws {
#if canImport(Network)
        guard listener == nil else { throw ProxyServerError.alreadyRunning }
        let port: NWEndpoint.Port
        if let explicit = configuration.port, let explicitPort = NWEndpoint.Port(rawValue: explicit) {
            port = explicitPort
        } else {
            port = 0
        }

        listener = try NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: queue)
#else
        throw ProxyServerError.networkingUnavailable
#endif
    }

    public func stop() {
#if canImport(Network)
        listener?.cancel()
        listener = nil
#endif
    }

    public var port: UInt16? {
#if canImport(Network)
        guard let nwPort = listener?.port else { return configuration.port }
        return nwPort.rawValue
#else
        return configuration.port
#endif
    }

    public var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

#if canImport(Network)
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }

            if let data {
                Task {
                    let responseData = await self.response(for: data)
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            } else if let error {
                print("Proxy connection error: \(error)")
                connection.cancel()
            }
        }
    }

    private func response(for data: Data) async -> Data {
        do {
            let request = try HTTPRequestParser.parse(data: data)
            let response = await router.handle(request)
            return response.encoded()
        } catch {
            return HTTPResponse(status: .internalServerError).encoded()
        }
    }
#endif
}
