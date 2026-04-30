import SwiftUI
import UserNotifications

@main
struct MacVidCatchApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var router = DeepLinkRouter()
    @State private var engine: DownloadEngine?

    var body: some Scene {
        Window("MacVidCatch", id: "main") {
            ContentView(store: store, engine: engine)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    if engine == nil { engine = DownloadEngine(store: store); store.load(); requestNotifications() }
                }
                .onOpenURL { url in Task { await router.handle(url, store: store, engine: engine) } }
        }
        .commands { CommandGroup(after: .newItem) { Button("New Download…") { NotificationCenter.default.post(name: .newDownloadRequested, object: nil) }.keyboardShortcut("n") } }

        MenuBarExtra("MacVidCatch", systemImage: "arrow.down.circle") {
            MenuBarView(store: store, engine: engine)
        }
    }

    private func requestNotifications() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    func handle(_ url: URL, store: AppStore, engine: DownloadEngine?) async {
        guard url.scheme == "macvidcatch", url.host == "download", let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let downloadURL = URL(string: value) else { return }
        let pageURL = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value.flatMap(URL.init(string:))
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
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
