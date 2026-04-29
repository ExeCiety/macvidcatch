import Foundation
import UserNotifications

@MainActor
final class DownloadEngine: NSObject, ObservableObject {
    private let store: AppStore
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pausedIDs = Set<UUID>()
    private var activeProcesses: [UUID: Process] = [:]

    init(store: AppStore) { self.store = store }

    func enqueue(url: URL, pageURL: URL? = nil, suggestedTitle: String? = nil, mimeType: String? = nil, destinationFolder: String? = nil, sourceType: DownloadJob.SourceType = .manual) async {
        do {
            let method = preferredDownloadMethod(for: url, mimeType: mimeType, sourceType: sourceType)
            AppLogger.log("Enqueue url=\(redactedURLString(url)) pageUrl=\(pageURL.map(redactedURLString) ?? "-") mimeType=\(mimeType ?? "-") source=\(sourceType.rawValue) method=\(method.rawValue)")
            let metadata = method == .ytDlp ? ytDlpMetadata(for: url, title: suggestedTitle) : try await probe(url)
            let folder = destinationFolder ?? store.settings.defaultDownloadFolder
            var job = DownloadJob(
                sourceUrl: url,
                pageUrl: pageURL,
                finalUrl: metadata.finalURL,
                fileName: metadata.fileName,
                destinationPath: URL(fileURLWithPath: folder).appendingPathComponent(metadata.fileName).path,
                totalBytes: metadata.size,
                supportsResume: metadata.supportsResume,
                sourceType: sourceType,
                downloadMethod: method,
                domain: url.host ?? ""
            )
            AppLogger.log("Created job id=\(job.id.uuidString) fileName=\(job.fileName) destination=\(job.destinationPath)", jobID: job.id)
            if store.settings.domainBlocklist.contains(where: { job.domain.localizedCaseInsensitiveContains($0) }) {
                job.status = .failed; job.errorCode = "Domain diblokir oleh policy pengguna."
                AppLogger.log("Blocked by user domain policy domain=\(job.domain)", jobID: job.id)
            }
            store.upsert(job)
            startQueue()
        } catch {
            let fileName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
            let job = DownloadJob(sourceUrl: url, pageUrl: pageURL, fileName: fileName, destinationPath: URL(fileURLWithPath: store.settings.defaultDownloadFolder).appendingPathComponent(fileName).path, status: .failed, sourceType: sourceType, domain: url.host ?? "", errorCode: error.localizedDescription)
            AppLogger.log("Failed to enqueue url=\(redactedURLString(url)) error=\(error.localizedDescription)", jobID: job.id)
            store.upsert(job)
        }
    }

    func startQueue() {
        let activeCount = store.jobs.filter { $0.status == .downloading }.count
        let capacity = max(0, store.settings.maxSimultaneousDownloads - activeCount)
        let queued = store.jobs.filter { $0.status == .queued }.prefix(capacity)
        for job in queued { start(job.id) }
    }

    func start(_ id: UUID) {
        guard activeTasks[id] == nil, let job = store.jobs.first(where: { $0.id == id }) else { return }
        pausedIDs.remove(id)
        AppLogger.log("Start job id=\(id.uuidString) method=\(job.downloadMethod.rawValue) url=\(redactedURLString(job.sourceUrl))", jobID: id)
        store.update(id) { $0.status = .downloading; $0.errorCode = nil }
        activeTasks[id] = Task { [weak self] in
            await self?.run(jobID: id, originalJob: job)
        }
    }

    func pause(_ id: UUID) {
        pausedIDs.insert(id)
        AppLogger.log("Pause job id=\(id.uuidString)", jobID: id)
        activeTasks[id]?.cancel(); activeTasks[id] = nil
        activeProcesses[id]?.terminate(); activeProcesses[id] = nil
        store.update(id) { $0.status = .paused }
        startQueue()
    }

    func cancel(_ id: UUID) {
        AppLogger.log("Cancel job id=\(id.uuidString)", jobID: id)
        activeTasks[id]?.cancel(); activeTasks[id] = nil
        activeProcesses[id]?.terminate(); activeProcesses[id] = nil
        store.update(id) { $0.status = .canceled }
        cleanupPartials(for: id)
        startQueue()
    }

    func retry(_ id: UUID) {
        AppLogger.log("Retry job id=\(id.uuidString)", jobID: id)
        store.update(id) { $0.status = .queued; $0.downloadedBytes = 0; $0.errorCode = nil }
        cleanupPartials(for: id)
        startQueue()
    }

    func delete(_ id: UUID) {
        guard let job = store.jobs.first(where: { $0.id == id }) else { return }
        guard job.status != .downloading else {
            AppLogger.log("Delete ignored because job is downloading id=\(id.uuidString)", jobID: id)
            return
        }
        AppLogger.log("Delete job id=\(id.uuidString) status=\(job.status.rawValue)", jobID: id)
        activeTasks[id]?.cancel(); activeTasks[id] = nil
        activeProcesses[id]?.terminate(); activeProcesses[id] = nil
        pausedIDs.remove(id)
        cleanupPartials(for: id)
        store.remove(id)
        startQueue()
    }

    func deleteAllNotDownloading() {
        let removable = store.jobs.filter { $0.status != .downloading }
        AppLogger.log("Delete all non-downloading jobs count=\(removable.count)")
        for job in removable {
            activeTasks[job.id]?.cancel(); activeTasks[job.id] = nil
            activeProcesses[job.id]?.terminate(); activeProcesses[job.id] = nil
            pausedIDs.remove(job.id)
            cleanupPartials(for: job.id)
        }
        store.removeAllNotDownloading()
        startQueue()
    }

    func pauseAll() { store.jobs.filter { $0.status == .downloading }.forEach { pause($0.id) } }
    func resumeAll() { store.jobs.filter { $0.status == .paused }.forEach { store.update($0.id) { $0.status = .queued } }; startQueue() }

    private func run(jobID: UUID, originalJob: DownloadJob) async {
        defer { activeTasks[jobID] = nil; startQueue() }
        var attempts = 0
        while attempts <= store.settings.retryCount && !Task.isCancelled {
            do {
                let latest = store.jobs.first(where: { $0.id == jobID }) ?? originalJob
                try await download(job: latest)
                guard !Task.isCancelled else { return }
                AppLogger.log("Completed job id=\(jobID.uuidString)", jobID: jobID)
                store.update(jobID) { $0.status = .completed; $0.downloadedBytes = max($0.downloadedBytes, $0.totalBytes); $0.speedBytesPerSecond = 0 }
                notify(title: "Download selesai", body: latest.fileName)
                return
            } catch {
                if pausedIDs.contains(jobID) || Task.isCancelled { return }
                attempts += 1
                AppLogger.log("Attempt \(attempts) failed for job id=\(jobID.uuidString): \(error.localizedDescription)", jobID: jobID)
                if attempts > store.settings.retryCount {
                    store.update(jobID) { $0.status = .failed; $0.errorCode = error.localizedDescription; $0.speedBytesPerSecond = 0 }
                    notify(title: "Download gagal", body: error.localizedDescription)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(store.settings.retryIntervalSeconds * Double(attempts) * 1_000_000_000))
                }
            }
        }
    }

    private func download(job: DownloadJob) async throws {
        if job.downloadMethod == .ytDlp {
            try await ytDlpDownload(job: job)
            return
        }
        if job.supportsResume && job.totalBytes > 1_048_576 && store.settings.maxConnectionsPerFile > 1 {
            try await segmentedDownload(job: job)
        } else {
            try await singleDownload(job: job)
        }
    }

    private func singleDownload(job: DownloadJob) async throws {
        var request = URLRequest(url: job.finalUrl ?? job.sourceUrl)
        let partial = partialURL(for: job.id, suffix: "single")
        let existing = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if existing > 0 && job.supportsResume { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTP(response)
        if existing == 0 { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        var downloaded = existing; var lastTick = Date(); var tickBytes: Int64 = 0
        for try await byte in stream {
            try Task.checkCancellation()
            try handle.write(contentsOf: [byte])
            downloaded += 1; tickBytes += 1
            if tickBytes >= 64 * 1024 { await updateProgress(job.id, downloaded: downloaded, tickBytes: tickBytes, lastTick: &lastTick); tickBytes = 0 }
        }
        try handle.close()
        try mergePartials(partials: [partial], destination: URL(fileURLWithPath: job.destinationPath), expectedBytes: job.totalBytes)
    }

    private func segmentedDownload(job: DownloadJob) async throws {
        let count = min(max(1, store.settings.maxConnectionsPerFile), 8)
        let segmentSize = Int64(ceil(Double(job.totalBytes) / Double(count)))
        try await withThrowingTaskGroup(of: URL.self) { group in
            for index in 0..<count {
                let start = Int64(index) * segmentSize
                let end = min(job.totalBytes - 1, start + segmentSize - 1)
                guard start <= end else { continue }
                group.addTask { try await self.downloadSegment(job: job, index: index, start: start, end: end) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            let ordered = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            try mergePartials(partials: ordered, destination: URL(fileURLWithPath: job.destinationPath), expectedBytes: job.totalBytes)
        }
    }

    private nonisolated func downloadSegment(job: DownloadJob, index: Int, start: Int64, end: Int64) async throws -> URL {
        let url = partialURL(for: job.id, suffix: String(format: "%03d", index))
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if existing >= end - start + 1 { return url }
        var request = URLRequest(url: job.finalUrl ?? job.sourceUrl)
        request.setValue("bytes=\(start + existing)-\(end)", forHTTPHeaderField: "Range")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTP(response)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
        for try await byte in stream { try Task.checkCancellation(); try handle.write(contentsOf: [byte]) }
        try handle.close()
        return url
    }

    private func updateProgress(_ id: UUID, downloaded: Int64, tickBytes: Int64, lastTick: inout Date) async {
        let now = Date(); let elapsed = now.timeIntervalSince(lastTick)
        guard elapsed >= 0.5 else { return }
        let speed = Int64(Double(tickBytes) / elapsed)
        if store.settings.globalSpeedLimitBytesPerSecond > 0, speed > store.settings.globalSpeedLimitBytesPerSecond {
            let delay = Double(tickBytes) / Double(store.settings.globalSpeedLimitBytesPerSecond) - elapsed
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        store.update(id) { $0.downloadedBytes = downloaded; $0.speedBytesPerSecond = speed }
        lastTick = now
    }

    private func probe(_ url: URL) async throws -> (fileName: String, size: Int64, supportsResume: Bool, finalURL: URL?) {
        var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<400).contains(http.statusCode) else { throw NSError(domain: "Download", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: http.statusCode == 403 || http.statusCode == 401 ? "Permission denied atau URL expired." : "Server mengembalikan HTTP \(http.statusCode)."] ) }
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let name = filename(from: disposition) ?? http.url?.lastPathComponent.nilIfEmpty ?? url.lastPathComponent.nilIfEmpty ?? "download"
        let size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").localizedCaseInsensitiveContains("bytes")
        return (name, size, ranges, http.url)
    }

    private func ytDlpMetadata(for url: URL, title: String?) -> (fileName: String, size: Int64, supportsResume: Bool, finalURL: URL?) {
        let rawName = title?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "video"
        let baseName = sanitizedFileName((rawName as NSString).deletingPathExtension.nilIfEmpty ?? rawName)
        let fileName = baseName + ".%(ext)s"
        return (fileName, 0, false, url)
    }

    private func ytDlpDownload(job: DownloadJob) async throws {
        guard let executable = findExecutable("yt-dlp") else {
            AppLogger.log("yt-dlp executable not found", jobID: job.id)
            throw NSError(domain: "Download", code: 2, userInfo: [NSLocalizedDescriptionKey: "yt-dlp belum terinstall. Install dengan: brew install yt-dlp aria2"])
        }

        let outputTemplate = ytDlpOutputTemplate(for: job)
        let process = Process()
        process.executableURL = executable
        process.arguments = ytDlpArguments(for: job, outputTemplate: outputTemplate)
        AppLogger.log("Run yt-dlp executable=\(executable.path) args=\(redactedArguments(process.arguments ?? []))", jobID: job.id)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        activeProcesses[job.id] = process

        try process.run()
        let reader = Task.detached { [weak pipe] in
            guard let handle = pipe?.fileHandleForReading else { return Data() }
            return handle.readDataToEndOfFile()
        }
        await waitForProcess(process)
        activeProcesses[job.id] = nil
        let output = await reader.value
        let outputText = String(data: output, encoding: .utf8) ?? ""
        AppLogger.writeJobOutput(outputText, jobID: job.id)
        AppLogger.log("yt-dlp exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)", jobID: job.id)

        guard process.terminationStatus == 0 else {
            let message = outputText.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).joined(separator: "\n").nilIfEmpty ?? "yt-dlp gagal dengan kode \(process.terminationStatus)."
            throw NSError(domain: "Download", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }

        updateCompletedYtDlpJob(job)
    }

    private func ytDlpOutputTemplate(for job: DownloadJob) -> String {
        let destination = URL(fileURLWithPath: job.destinationPath)
        guard isHLSPlaylist(job.sourceUrl) || destination.pathExtension.lowercased() == "m3u8" else {
            return destination.path
        }
        return destination.deletingPathExtension().appendingPathExtension("%(ext)s").path
    }

    private func ytDlpArguments(for job: DownloadJob, outputTemplate: String) -> [String] {
        var arguments = [
            "--cookies-from-browser", "chrome",
            "--user-agent", defaultBrowserUserAgent,
            "--downloader", "aria2c",
            "--downloader-args", "aria2c:-x 8 -s 8 -k 1M",
            "--no-check-certificate",
            "--merge-output-format", "mp4",
            "-N", "5",
            "-o", outputTemplate,
            job.sourceUrl.absoluteString
        ]
        if isHLSPlaylist(job.sourceUrl) {
            arguments.insert("--force-generic-extractor", at: 0)
        }
        if let referer = job.pageUrl?.absoluteString.nilIfEmpty {
            arguments.insert(contentsOf: ["--referer", referer], at: 0)
        }
        return arguments
    }

    private func updateCompletedYtDlpJob(_ job: DownloadJob) {
        let outputTemplate = URL(fileURLWithPath: ytDlpOutputTemplate(for: job))
        let folder = outputTemplate.deletingLastPathComponent()
        let prefix = outputTemplate.lastPathComponent.replacingOccurrences(of: ".%(ext)s", with: "")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        guard let file = files.filter({ $0.lastPathComponent.hasPrefix(prefix) }).max(by: { lhs, rhs in
            ((try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        AppLogger.log("yt-dlp output file=\(file.path) size=\(size)", jobID: job.id)
        store.update(job.id) { $0.fileName = file.lastPathComponent; $0.destinationPath = file.path; $0.totalBytes = size; $0.downloadedBytes = size }
    }

    private func notify(title: String, body: String) {
        guard store.settings.showNotifications else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private let defaultBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

private func preferredDownloadMethod(for url: URL, mimeType: String?, sourceType: DownloadJob.SourceType) -> DownloadJob.DownloadMethod {
    let mime = mimeType?.lowercased() ?? ""
    if isHLSPlaylist(url) || mime.contains("mpegurl") || mime.contains("x-mpegurl") { return .ytDlp }
    if sourceType == .browserExtension { return .ytDlp }
    return .native
}

private func isHLSPlaylist(_ url: URL) -> Bool {
    url.path.lowercased().contains(".m3u8")
}

private func findExecutable(_ name: String) -> URL? {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func waitForProcess(_ process: Process) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            continuation.resume()
        }
    }
}

private func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>")
    let cleaned = value.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.nilIfEmpty ?? "video"
}

private func redactedArguments(_ arguments: [String]) -> String {
    arguments.map { argument in
        if let url = URL(string: argument), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            return redactedURLString(url)
        }
        if argument.count > 180 { return String(argument.prefix(180)) + "…" }
        return argument
    }.joined(separator: " ")
}

private func redactedURLString(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.queryItems?.isEmpty == false else {
        return url.absoluteString
    }
    components.queryItems = components.queryItems?.map { item in
        let sensitiveNames = ["token", "signature", "sig", "policy", "key", "jwt"]
        if sensitiveNames.contains(item.name.lowercased()) {
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return item
    }
    let value = components.string ?? url.absoluteString
    return value.count > 240 ? String(value.prefix(240)) + "…" : value
}

private func validateHTTP(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 206 else { throw URLError(.badServerResponse) }
}

private func partialURL(for id: UUID, suffix: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VidcatchMac", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(suffix + ".part")
}

private func mergePartials(partials: [URL], destination: URL, expectedBytes: Int64) throws {
    let tmp = destination.appendingPathExtension("download")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let output = try FileHandle(forWritingTo: tmp)
    for partial in partials { let input = try FileHandle(forReadingFrom: partial); try output.write(contentsOf: input.readDataToEndOfFile()); try input.close() }
    try output.close()
    if expectedBytes > 0 {
        let actual = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
        guard actual == expectedBytes else { throw NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ukuran file akhir tidak sesuai."]) }
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: tmp, to: destination)
}

private func cleanupPartials(for id: UUID) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VidcatchMac", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
}

private func filename(from disposition: String) -> String? {
    disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.lowercased().hasPrefix("filename=") }?.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
