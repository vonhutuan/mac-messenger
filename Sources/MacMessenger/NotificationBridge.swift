import AppKit
import UserNotifications

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    var onNotificationClicked: ((String, String) -> Void)?

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func configure() {
        guard isAvailable else {
            NSLog("MacMessenger: Running outside .app bundle; native UNUserNotificationCenter disabled.")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("MacMessenger: Notification authorization error: %@", error.localizedDescription)
            } else {
                NSLog("MacMessenger: Notification authorization granted: %@", granted ? "true" : "false")
            }
        }
    }

    func postNotification(id: String, title: String, body: String, silent: Bool, threadHref: String = "") {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Messenger" : title
        content.body = body
        if !silent {
            content.sound = .default
        }
        content.userInfo = [
            "jsNotificationId": id,
            "threadHref": threadHref
        ]

        let request = UNNotificationRequest(
            identifier: "macmessenger-\(id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("MacMessenger: Failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    func sendTestNotification() {
        guard isAvailable else { return }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied:
                let alert = NSAlert()
                alert.messageText = "Notifications Are Disabled"
                alert.informativeText = "Enable notifications for MacMessenger in System Settings → Notifications to receive message alerts."
                alert.addButton(withTitle: "Open Notification Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                {
                    NSWorkspace.shared.open(url)
                }
            case .notDetermined:
                if let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge]), granted {
                    self.postNotification(
                        id: "test",
                        title: "MacMessenger",
                        body: "Native notifications are working!",
                        silent: false
                    )
                }
            default:
                self.postNotification(
                    id: "test",
                    title: "MacMessenger",
                    body: "Native notifications are working!",
                    silent: false
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let jsId = userInfo["jsNotificationId"] as? String ?? ""
        let threadHref = userInfo["threadHref"] as? String ?? ""
        Task { @MainActor in
            self.onNotificationClicked?(jsId, threadHref)
            completionHandler()
        }
    }
}
