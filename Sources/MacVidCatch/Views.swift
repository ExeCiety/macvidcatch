import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    let engine: DownloadEngine?
    @State private var showingNewDownload = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedFilter) {
                NavigationLink(value: Optional<DownloadJob.Status>.none) { Label("All Downloads", systemImage: "tray.full") }
                ForEach(DownloadJob.Status.allCases, id: \.self) { status in NavigationLink(value: Optional(status)) { Label(status.title, systemImage: status.icon) } }
            }
            .navigationTitle("Downloads")
        } detail: {
            VStack(spacing: 0) {
                toolbar
                DownloadListView(store: store, engine: engine)
            }
        }
        .sheet(isPresented: $showingNewDownload) { NewDownloadView(store: store, engine: engine) }
        .sheet(isPresented: $showingSettings) { SettingsView(settings: $store.settings) }
        .onReceive(NotificationCenter.default.publisher(for: .newDownloadRequested)) { _ in showingNewDownload = true }
    }

    private var toolbar: some View {
        HStack {
            Button { showingNewDownload = true } label: { Label("New Download", systemImage: "plus") }
            Button { engine?.resumeAll() } label: { Label("Start All", systemImage: "play.fill") }
            Button { engine?.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
            Button(role: .destructive) { engine?.deleteAllNotDownloading() } label: { Label("Delete All", systemImage: "trash") }
                .disabled(!store.jobs.contains { $0.status != .downloading })
            Spacer()
            Button { NSWorkspace.shared.open(AppLogger.logsDirectory) } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
        .padding()
    }
}

struct DownloadListView: View {
    @ObservedObject var store: AppStore
    let engine: DownloadEngine?

    var body: some View {
        Table(store.visibleJobs) {
            TableColumn("File") { job in
                VStack(alignment: .leading) {
                    Text(job.fileName).fontWeight(.medium)
                    Text(job.domain).foregroundStyle(.secondary).font(.caption)
                    if let error = job.errorCode, job.status == .failed { Text(error).foregroundStyle(.red).font(.caption).lineLimit(3) }
                }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Progress") { job in ProgressView(value: job.progress) { Text(job.progressTitle) }.frame(width: 150) }
                .width(ideal: 170)
            TableColumn("Speed") { job in Text(formatBytes(job.speedBytesPerSecond) + "/s") }
                .width(min: 72, ideal: 92, max: 120)
            TableColumn("Size") { job in Text(job.totalBytes > 0 ? formatBytes(job.totalBytes) : "Unknown") }
                .width(min: 72, ideal: 92, max: 120)
            TableColumn("Actions") { job in actionButtons(for: job) }
                .width(min: 112, ideal: 132, max: 156)
        }
        .overlay {
            if store.visibleJobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No Downloads").font(.headline)
                    Text("Klik New Download untuk mulai.").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func actionButtons(for job: DownloadJob) -> some View {
        HStack(spacing: 6) {
            if job.status == .downloading { iconButton("Pause", systemImage: "pause.fill") { engine?.pause(job.id) } }
            if job.status == .paused || job.status == .queued { iconButton("Start", systemImage: "play.fill") { engine?.start(job.id) } }
            if job.status == .failed { iconButton("Retry", systemImage: "arrow.clockwise") { engine?.retry(job.id) } }
            if job.status == .downloading || job.status == .queued || job.status == .paused { iconButton("Cancel", systemImage: "xmark") { engine?.cancel(job.id) } }
            iconButton("Open Log", systemImage: "doc.text") { NSWorkspace.shared.open(AppLogger.jobLogURL(for: job.id)) }
            iconButton("Delete", systemImage: "trash", role: .destructive) { engine?.delete(job.id) }
                .disabled(job.status == .downloading)
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .help(title)
    }
}

struct NewDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let engine: DownloadEngine?
    @State private var urlText = ""
    @State private var folder = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Download").font(.title2).fontWeight(.semibold)
            TextField("https://example.com/file.zip", text: $urlText).textFieldStyle(.roundedBorder)
            HStack { TextField("Destination folder", text: $folder).textFieldStyle(.roundedBorder); Button("Choose…", action: chooseFolder) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Download") { add() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560).onAppear { folder = store.settings.defaultDownloadFolder }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func add() {
        guard let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased()) else { error = "Masukkan URL HTTP/HTTPS yang valid."; return }
        Task { await engine?.enqueue(url: url, destinationFolder: folder); dismiss() }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section("General") { TextField("Default folder", text: $settings.defaultDownloadFolder); Toggle("Show notifications", isOn: $settings.showNotifications) }
            Section("Download") {
                Stepper("Max simultaneous downloads: \(settings.maxSimultaneousDownloads)", value: $settings.maxSimultaneousDownloads, in: 1...10)
                Stepper("Connections per file: \(settings.maxConnectionsPerFile)", value: $settings.maxConnectionsPerFile, in: 1...8)
                Stepper("Retry count: \(settings.retryCount)", value: $settings.retryCount, in: 0...10)
                TextField("Global speed limit bytes/sec (0 = unlimited)", value: $settings.globalSpeedLimitBytesPerSecond, format: .number)
            }
            Section("Browser Integration") {
                Toggle("Show floating button", isOn: $settings.showFloatingButton)
                HStack {
                    TextField("Cookies Profile Path", text: $settings.firefoxCookiesPath)
                    Button("Choose…", action: chooseFirefoxCookiesPath)
                    Button("Default") { settings.firefoxCookiesPath = defaultFirefoxCookiesPath() }
                }
                Text("Accepts a browser Profiles folder, a profile folder, or cookies.sqlite.").font(.caption).foregroundStyle(.secondary)
                TextField("Blocklist domains, comma separated", text: Binding(get: { settings.domainBlocklist.joined(separator: ",") }, set: { settings.domainBlocklist = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 640)
    }

    private func chooseFirefoxCookiesPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose browser Profiles folder, profile folder, or cookies.sqlite"
        if panel.runModal() == .OK, let url = panel.url { settings.firefoxCookiesPath = url.path }
    }
}

struct MenuBarView: View {
    @ObservedObject var store: AppStore
    let engine: DownloadEngine?
    var body: some View {
        Text("Active: \(store.jobs.filter { $0.status == .downloading }.count)")
        Text("Total speed: \(formatBytes(store.jobs.map(\.speedBytesPerSecond).reduce(0, +)))/s")
        Divider()
        Button("Pause All") { engine?.pauseAll() }
        Button("Resume All") { engine?.resumeAll() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

private extension DownloadJob.Status {
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var icon: String { switch self { case .queued: "clock"; case .downloading: "arrow.down"; case .paused: "pause.circle"; case .completed: "checkmark.circle"; case .failed: "exclamationmark.triangle"; case .canceled: "xmark.circle" } }
}

private extension DownloadJob {
    var progressTitle: String { isConverting && status == .downloading ? "Converting" : status.title }
}

func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
