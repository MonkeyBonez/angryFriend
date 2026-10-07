import Foundation
import Network

/// Whether the phone has any connection right now — Wi-Fi or cellular alike.
/// The iCloud downloads in the background scan skip a turn while offline
/// instead of burning their retries.
nonisolated final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.angryFriend.network", qos: .utility))
    }

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }
}
