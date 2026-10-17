import Foundation

public struct DiscoveredServer: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
}

/// Finds scanix500-servers announcing `_dossiary-scan._tcp` on the local network. Start it on the main thread.
public final class RemoteDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    public static let serviceType = "_dossiary-scan._tcp."
    public private(set) var servers: [DiscoveredServer] = []
    public var onChange: (() -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    public func start() {
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving = []
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        servers.removeAll { $0.name == service.name }
        onChange?()
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let host = sender.hostName else { return }
        let found = DiscoveredServer(name: sender.name, host: host.hasSuffix(".") ? String(host.dropLast()) : host,
                                     port: sender.port)
        servers.removeAll { $0.name == found.name }
        servers.append(found)
        onChange?()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
