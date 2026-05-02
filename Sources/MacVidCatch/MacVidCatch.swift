import SwiftUI
@preconcurrency import UserNotifications

@main
struct MacVidCatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var router = DeepLinkRouter()
    @State private var engine: DownloadEngine?

    var body: some Scene {
        Window("MacVidCatch", id: "main") {
            ContentView(store: store, engine: engine)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    if engine == nil { engine = DownloadEngine(store: store); store.load() }
                }
                .onOpenURL { url in Task { await router.handle(url, store: store, engine: engine) } }
        }
        .commands { CommandGroup(after: .newItem) { Button("New Download…") { NotificationCenter.default.post(name: .newDownloadRequested, object: nil) }.keyboardShortcut("n") } }

        MenuBarExtra("MacVidCatch", systemImage: "arrow.down.circle") {
            MenuBarView(store: store, engine: engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.configure(delegate: self)
        AppNotifications.requestAuthorization()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let filePath = response.notification.request.content.userInfo["filePath"] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
    }
}

enum AppNotifications {
    static func configure(delegate: UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization(completion: (@Sendable (Bool, UNAuthorizationStatus, String?) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            AppLogger.log("Notification authorization status=\(settings.authorizationStatus.rawValue)")
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { AppLogger.log("Notification authorization failed: \(error.localizedDescription)") }
                AppLogger.log("Notification authorization granted=\(granted)")
                UNUserNotificationCenter.current().getNotificationSettings { updatedSettings in
                    AppLogger.log("Notification authorization updatedStatus=\(updatedSettings.authorizationStatus.rawValue) alerts=\(updatedSettings.alertSetting.rawValue) sounds=\(updatedSettings.soundSetting.rawValue)")
                    completion?(granted, updatedSettings.authorizationStatus, error?.localizedDescription)
                }
            }
        }
    }

    static func deliver(title: String, body: String, filePath: String? = nil, delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let filePath { content.userInfo = ["filePath": filePath] }
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)) { error in
            if let error { AppLogger.log("Notification delivery failed: \(error.localizedDescription)") }
            else { AppLogger.log("Notification delivery scheduled title=\(title)") }
        }
    }
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    func handle(_ url: URL, store: AppStore, engine: DownloadEngine?) async {
        guard url.scheme == "macvidcatch", url.host == "download", let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let downloadURL = URL(string: value) else { return }
        let pageURL = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value.flatMap(URL.init(string:))
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value?.replacingOccurrences(of: "+", with: " ")
        let mimeType = components.queryItems?.first(where: { $0.name == "mimeType" })?.value
        let browser = components.queryItems?.first(where: { $0.name == "browser" })?.value
        let quality = components.queryItems?.first(where: { $0.name == "quality" })?.value
        let defaultName = browserDownloadFileName(url: downloadURL, title: title, quality: quality)
        guard let destination = chooseBrowserDownloadDestination(defaultName: defaultName) else { return }
        await engine?.enqueue(url: downloadURL, pageURL: pageURL, suggestedTitle: title, mimeType: mimeType, destinationFolder: destination.deletingLastPathComponent().path, destinationFileName: destination.lastPathComponent, sourceType: .browserExtension, sourceBrowser: browser, preferredQuality: quality)
    }

    private func chooseBrowserDownloadDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Video"
        panel.message = "Choose the file name and save location."
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func browserDownloadFileName(url: URL, title: String?, quality: String?) -> String {
        let rawName = title?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "video"
        let baseName = sanitizedFileName((rawName as NSString).deletingPathExtension.nilIfEmpty ?? rawName)
        let suffix = quality.flatMap { $0 == "best" ? nil : $0.nilIfEmpty }.map { "-\($0)p" } ?? ""
        return baseName + suffix + ".mp4"
    }
}

extension Notification.Name { static let newDownloadRequested = Notification.Name("newDownloadRequested") }
