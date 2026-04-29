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
            Spacer()
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
            TableColumn("File") { job in VStack(alignment: .leading) { Text(job.fileName).fontWeight(.medium); Text(job.domain).foregroundStyle(.secondary).font(.caption) } }
            TableColumn("Progress") { job in ProgressView(value: job.progress) { Text(job.status.title) }.frame(width: 180) }
            TableColumn("Speed") { job in Text(formatBytes(job.speedBytesPerSecond) + "/s") }
            TableColumn("Size") { job in Text(job.totalBytes > 0 ? formatBytes(job.totalBytes) : "Unknown") }
            TableColumn("Actions") { job in actionButtons(for: job) }
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
        HStack {
            if job.status == .downloading { Button("Pause") { engine?.pause(job.id) } }
            if job.status == .paused || job.status == .queued { Button("Start") { engine?.start(job.id) } }
            if job.status == .failed { Button("Retry") { engine?.retry(job.id) } }
            if job.status == .downloading || job.status == .queued || job.status == .paused { Button("Cancel") { engine?.cancel(job.id) } }
        }
        .buttonStyle(.borderless)
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
            Section("Browser Integration") { Toggle("Show floating button", isOn: $settings.showFloatingButton); TextField("Blocklist domains, comma separated", text: Binding(get: { settings.domainBlocklist.joined(separator: ",") }, set: { settings.domainBlocklist = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 520)
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

func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
