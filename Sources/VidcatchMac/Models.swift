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

    var progress: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }

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
        speedBytesPerSecond: Int64 = 0
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
    }
}

struct DownloadSegment: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case pending, downloading, completed, failed }
    var id: UUID = UUID()
    var jobId: UUID
    var startByte: Int64
    var endByte: Int64
    var downloadedBytes: Int64 = 0
    var status: Status = .pending
}

struct AppSettings: Codable, Equatable {
    var defaultDownloadFolder: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    var maxSimultaneousDownloads: Int = 2
    var maxConnectionsPerFile: Int = 4
    var retryCount: Int = 3
    var retryIntervalSeconds: Double = 2
    var globalSpeedLimitBytesPerSecond: Int64 = 0
    var showNotifications: Bool = true
    var showFloatingButton: Bool = true
    var domainAllowlist: [String] = []
    var domainBlocklist: [String] = []
}

struct ExtensionPayload: Codable {
    struct Media: Codable { var url: URL; var mimeType: String?; var title: String?; var quality: String?; var isDrmProtected: Bool }
    struct Policy: Codable { var isAllowedByUser: Bool; var isAllowedByDomainPolicy: Bool }
    var type: String
    var version: String
    var source: String
    var browser: String
    var pageUrl: URL?
    var media: Media
    var policy: Policy
}
