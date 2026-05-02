import Foundation

struct DownloadJob: Identifiable, Codable, Equatable {
    enum Status: String, Codable, CaseIterable { case queued, downloading, paused, completed, failed, canceled }
    enum SourceType: String, Codable { case manual, browserExtension, clipboard }
    enum DownloadMethod: String, Codable { case native, ytDlp }

    var id: UUID = UUID()
    var sourceUrl: URL
    var pageUrl: URL?
    var finalUrl: URL?
    var fileName: String
    var destinationPath: String
    var status: Status = .queued
    var totalBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var supportsResume: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var sourceType: SourceType = .manual
    var downloadMethod: DownloadMethod = .native
    var domain: String
    var errorCode: String?
    var speedBytesPerSecond: Int64 = 0
    var externalProgress: Double?
    var isConverting: Bool = false
    var sourceBrowser: String?
    var preferredQuality: String?

    var progress: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : externalProgress ?? 0 }

    init(
        id: UUID = UUID(),
        sourceUrl: URL,
        pageUrl: URL? = nil,
        finalUrl: URL? = nil,
        fileName: String,
        destinationPath: String,
        status: Status = .queued,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        supportsResume: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceType: SourceType = .manual,
        downloadMethod: DownloadMethod = .native,
        domain: String,
        errorCode: String? = nil,
        speedBytesPerSecond: Int64 = 0,
        externalProgress: Double? = nil,
        isConverting: Bool = false,
        sourceBrowser: String? = nil,
        preferredQuality: String? = nil
    ) {
        self.id = id
        self.sourceUrl = sourceUrl
        self.pageUrl = pageUrl
        self.finalUrl = finalUrl
        self.fileName = fileName
        self.destinationPath = destinationPath
        self.status = status
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.supportsResume = supportsResume
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceType = sourceType
        self.downloadMethod = downloadMethod
        self.domain = domain
        self.errorCode = errorCode
        self.speedBytesPerSecond = speedBytesPerSecond
        self.externalProgress = externalProgress
        self.isConverting = isConverting
        self.sourceBrowser = sourceBrowser
        self.preferredQuality = preferredQuality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceUrl = try container.decode(URL.self, forKey: .sourceUrl)
        pageUrl = try container.decodeIfPresent(URL.self, forKey: .pageUrl)
        finalUrl = try container.decodeIfPresent(URL.self, forKey: .finalUrl)
        fileName = try container.decode(String.self, forKey: .fileName)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        downloadedBytes = try container.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        supportsResume = try container.decodeIfPresent(Bool.self, forKey: .supportsResume) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sourceType = try container.decodeIfPresent(SourceType.self, forKey: .sourceType) ?? .manual
        downloadMethod = try container.decodeIfPresent(DownloadMethod.self, forKey: .downloadMethod) ?? .native
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? sourceUrl.host ?? ""
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        speedBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .speedBytesPerSecond) ?? 0
        externalProgress = try container.decodeIfPresent(Double.self, forKey: .externalProgress)
        isConverting = try container.decodeIfPresent(Bool.self, forKey: .isConverting) ?? false
        sourceBrowser = try container.decodeIfPresent(String.self, forKey: .sourceBrowser)
        preferredQuality = try container.decodeIfPresent(String.self, forKey: .preferredQuality)
    }
}

struct AppSettings: Codable, Equatable {
    var defaultDownloadFolder: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    var maxSimultaneousDownloads: Int = 2
    var maxConnectionsPerFile: Int = 4
    var retryCount: Int = 3
    var retryIntervalSeconds: Double = 2
    var globalSpeedLimitBytesPerSecond: Int64 = 0
    var showNotifications: Bool = true
    var firefoxCookiesPath: String = defaultFirefoxCookiesPath()
    var domainAllowlist: [String] = []
    var domainBlocklist: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultDownloadFolder = try container.decodeIfPresent(String.self, forKey: .defaultDownloadFolder) ?? defaultDownloadFolder
        maxSimultaneousDownloads = try container.decodeIfPresent(Int.self, forKey: .maxSimultaneousDownloads) ?? maxSimultaneousDownloads
        maxConnectionsPerFile = try container.decodeIfPresent(Int.self, forKey: .maxConnectionsPerFile) ?? maxConnectionsPerFile
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? retryCount
        retryIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .retryIntervalSeconds) ?? retryIntervalSeconds
        globalSpeedLimitBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .globalSpeedLimitBytesPerSecond) ?? globalSpeedLimitBytesPerSecond
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? showNotifications
        firefoxCookiesPath = migratedCookiesProfilePath(try container.decodeIfPresent(String.self, forKey: .firefoxCookiesPath))
        domainAllowlist = try container.decodeIfPresent([String].self, forKey: .domainAllowlist) ?? domainAllowlist
        domainBlocklist = try container.decodeIfPresent([String].self, forKey: .domainBlocklist) ?? domainBlocklist
    }
}

func migratedCookiesProfilePath(_ path: String?) -> String {
    let legacyDefault = "~/Library/Application Support/Firefox/Profiles"
    guard let path, !path.isEmpty, path != legacyDefault else { return defaultFirefoxCookiesPath() }
    return path
}

func defaultFirefoxCookiesPath() -> String {
    let candidates = [
        "~/Library/Application Support/Firefox/Profiles",
        "~/Library/Application Support/Firefox Developer Edition/Profiles",
        "~/Library/Application Support/LibreWolf/Profiles",
        "~/Library/Application Support/Waterfox/Profiles",
        "~/Library/Application Support/Google/Chrome/Default",
        "~/Library/Application Support/Google/Chrome/Profile 1",
        "~/Library/Application Support/Chromium/Default",
        "~/Library/Application Support/Microsoft Edge/Default",
        "~/Library/Application Support/BraveSoftware/Brave-Browser/Default"
    ].map { ($0 as NSString).expandingTildeInPath }

    let fileManager = FileManager.default
    return candidates.first { path in
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("cookies.sqlite").path)
            || fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("Cookies").path)
            || ((try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty == false)
    } ?? "~/Library/Application Support/Firefox/Profiles"
}
