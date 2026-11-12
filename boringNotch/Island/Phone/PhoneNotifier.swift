//
//  PhoneNotifier.swift
//  boringNotch
//
//  Shows the phone's notifications as macOS notifications, with the sending app's icon
//  and a reply field where the app supports it.
//

import AppKit
import UserNotifications

@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneNotifier()

    private static let replyCategory = "island.phone.reply"
    private static let plainCategory = "island.phone.plain"
    private static let replyAction = "island.phone.reply.action"

    private var generation = 0
    private var prepared = false

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Antworten", options: [],
            textInputButtonTitle: "Senden", textInputPlaceholder: "Nachricht"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Listens on the daemon's notification socket until `stop()` or the next `start()`.
    func start(socketPath: String) {
        prepare()
        generation += 1
        let current = generation
        let thread = Thread { [weak self] in
            while true {
                let active = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.generation == current } }
                guard active else { return }
                if let fd = LineSocket.open(socketPath) {
                    LineSocket.readLines(from: fd) { line in
                        guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return true }
                        return DispatchQueue.main.sync {
                            MainActor.assumeIsolated {
                                guard let self, self.generation == current else { return false }
                                self.handle(frame)
                                return true
                            }
                        }
                    }
                    close(fd)
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        thread.name = "island.phone.notifications"
        thread.start()
    }

    func stop() {
        generation += 1
    }

    private func handle(_ frame: [String: Any]) {
        guard let key = frame["key"] as? String else { return }
        let center = UNUserNotificationCenter.current()

        if frame["type"] as? String == "remove" {
            center.removeDeliveredNotifications(withIdentifiers: [key])
            return
        }
        guard frame["type"] as? String == "notification" else { return }

        let app = frame["app"] as? String ?? ""
        let title = frame["title"] as? String ?? ""
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        if !title.isEmpty, title != app { content.subtitle = app }
        content.body = frame["body"] as? String ?? ""
        content.sound = .default
        content.userInfo = ["key": key]
        content.threadIdentifier = frame["pkg"] as? String ?? app
        content.categoryIdentifier = frame["replyable"] as? Bool == true ? Self.replyCategory : Self.plainCategory

        // macOS always shows this app's own icon on the left; the sending app's icon goes on the right.
        if let attachment = Self.attachment(for: frame["icon"] as? String) ?? Self.attachment(for: frame["picture"] as? String) {
            content.attachments = [attachment]
        }
        // Same identifier: an updated notification replaces the earlier banner.
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    /// The system moves attachment files away, so it gets its own copy with a proper file extension.
    private static func attachment(for path: String?) -> UNNotificationAttachment? {
        guard let path, !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 8 else { return nil }
        let isPNG = data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-notification-\(UUID().uuidString).\(isPNG ? "png" : "jpg")")
        guard (try? data.write(to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: copy)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.replyAction,
              let text = (response as? UNTextInputNotificationResponse)?.userText,
              let key = response.notification.request.content.userInfo["key"] as? String else { return }
        _ = await PhoneLink.shared.reply(key: key, text: text)
    }
}
