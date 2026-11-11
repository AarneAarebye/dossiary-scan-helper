import Foundation
import HelperCore
import UserNotifications

/// Tells the person about a picked-up button scan. Asks for notification permission at the first scan, never at
/// launch; when it is refused the menu line "Last button scan" remains the only record.
final class PickupNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    func notify(_ scan: PickedUpScan) {
        notify(title: scan.pages == 1 ? L("1 page scanned") : L("%lld pages scanned", scan.pages), body: scan.name)
    }

    /// Any notification of the helper's own (a finished profile scan).
    func notify(title: String, body: String) {
        // A bare executable (swift run) has no bundle for the notification centre.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let firstTime = lock.withLock { () -> Bool in
            defer { asked = true }
            return !asked
        }
        Task {
            if firstTime {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
