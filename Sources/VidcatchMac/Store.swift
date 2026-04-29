import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var jobs: [DownloadJob] = [] { didSet { saveJobs() } }
    @Published var settings: AppSettings = Persistence.loadSettings() { didSet { Persistence.saveSettings(settings) } }
    @Published var selectedFilter: DownloadJob.Status?

    var visibleJobs: [DownloadJob] { selectedFilter.map { filter in jobs.filter { $0.status == filter } } ?? jobs }

    func upsert(_ job: DownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
    }

    func update(_ id: UUID, _ mutate: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        jobs[index].updatedAt = Date()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func removeAllNotDownloading() {
        jobs.removeAll { $0.status != .downloading }
    }

    func load() { jobs = Persistence.loadJobs() }
    private func saveJobs() { Persistence.saveJobs(jobs) }
}

enum Persistence {
    private static var supportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("VidcatchMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var jobsURL: URL { supportURL.appendingPathComponent("downloads.json") }
    private static var settingsURL: URL { supportURL.appendingPathComponent("settings.json") }

    static func loadJobs() -> [DownloadJob] { decode([DownloadJob].self, from: jobsURL) ?? [] }
    static func saveJobs(_ jobs: [DownloadJob]) { encode(jobs, to: jobsURL) }
    static func loadSettings() -> AppSettings { decode(AppSettings.self, from: settingsURL) ?? AppSettings() }
    static func saveSettings(_ settings: AppSettings) { encode(settings, to: settingsURL) }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func encode<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
