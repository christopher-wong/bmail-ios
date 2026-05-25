import Foundation
import Network
import Observation

/// Observable wrapper around `NWPathMonitor`. Views read `isOnline` to
/// surface an indicator and to skip network requests when offline.
///
/// Starts optimistic (`isOnline = true`) so the very first frame after
/// launch — before the first path callback fires — doesn't show a
/// false "offline" banner.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}
