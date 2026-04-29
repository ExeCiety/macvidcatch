import SwiftUI
import UserNotifications

@main
struct VidcatchMacApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var router = DeepLinkRouter()
    @State private var engine: DownloadEngine?

    var body: some Scene {
        WindowGroup {
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
        guard url.scheme == "vidcatchmac", url.host == "download", let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let downloadURL = URL(string: value) else { return }
        let pageURL = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value.flatMap(URL.init(string:))
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
        let mimeType = components.queryItems?.first(where: { $0.name == "mimeType" })?.value
        await engine?.enqueue(url: downloadURL, pageURL: pageURL, suggestedTitle: title, mimeType: mimeType, sourceType: .browserExtension)
    }
}

extension Notification.Name { static let newDownloadRequested = Notification.Name("newDownloadRequested") }
