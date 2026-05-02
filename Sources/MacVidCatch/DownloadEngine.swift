import Foundation
import UserNotifications

@MainActor
final class DownloadEngine: NSObject, ObservableObject {
    private let store: AppStore
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pausedIDs = Set<UUID>()
    private var activeProcesses: [UUID: Process] = [:]
    private var lastYtDlpProgressUpdateAt: [UUID: Date] = [:]

    init(store: AppStore) { self.store = store }

    func enqueue(url: URL, pageURL: URL? = nil, suggestedTitle: String? = nil, mimeType: String? = nil, destinationFolder: String? = nil, destinationFileName: String? = nil, sourceType: DownloadJob.SourceType = .manual, sourceBrowser: String? = nil, preferredQuality: String? = nil) async {
        do {
            let method = preferredDownloadMethod(for: url, mimeType: mimeType, sourceType: sourceType)
            AppLogger.log("Enqueue url=\(redactedURLString(url)) pageUrl=\(pageURL.map(redactedURLString) ?? "-") mimeType=\(mimeType ?? "-") source=\(sourceType.rawValue) browser=\(sourceBrowser ?? "-") method=\(method.rawValue) quality=\(preferredQuality ?? "-")")
            let metadata = method == .ytDlp ? ytDlpMetadata(for: url, title: suggestedTitle) : try await probe(url)
            let folder = destinationFolder ?? store.settings.defaultDownloadFolder
            let fileName = sanitizedFileName(destinationFileName?.nilIfEmpty ?? metadata.fileName)
            var job = DownloadJob(
                sourceUrl: url,
                pageUrl: pageURL,
                finalUrl: metadata.finalURL,
                fileName: fileName,
                destinationPath: URL(fileURLWithPath: folder).appendingPathComponent(fileName).path,
                totalBytes: metadata.size,
                supportsResume: metadata.supportsResume,
                sourceType: sourceType,
                downloadMethod: method,
                domain: url.host ?? "",
                sourceBrowser: sourceBrowser,
                preferredQuality: preferredQuality
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
            let job = DownloadJob(sourceUrl: url, pageUrl: pageURL, fileName: fileName, destinationPath: URL(fileURLWithPath: store.settings.defaultDownloadFolder).appendingPathComponent(fileName).path, status: .failed, sourceType: sourceType, domain: url.host ?? "", errorCode: error.localizedDescription, sourceBrowser: sourceBrowser)
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
        lastYtDlpProgressUpdateAt[id] = nil
        store.update(id) { $0.status = .paused }
        startQueue()
    }

    func cancel(_ id: UUID) {
        AppLogger.log("Cancel job id=\(id.uuidString)", jobID: id)
        activeTasks[id]?.cancel(); activeTasks[id] = nil
        activeProcesses[id]?.terminate(); activeProcesses[id] = nil
        lastYtDlpProgressUpdateAt[id] = nil
        store.update(id) { $0.status = .canceled }
        cleanupPartials(for: id)
        startQueue()
    }

    func retry(_ id: UUID) {
        AppLogger.log("Retry job id=\(id.uuidString)", jobID: id)
        store.update(id) { $0.status = .queued; $0.downloadedBytes = 0; $0.errorCode = nil; $0.externalProgress = nil; $0.isConverting = false }
        cleanupPartials(for: id)
        startQueue()
    }

    func delete(_ id: UUID, deletingFile: Bool = false) {
        guard let job = store.jobs.first(where: { $0.id == id }) else { return }
        guard job.status != .downloading else {
            AppLogger.log("Delete ignored because job is downloading id=\(id.uuidString)", jobID: id)
            return
        }
        AppLogger.log("Delete job id=\(id.uuidString) status=\(job.status.rawValue) deletingFile=\(deletingFile)", jobID: id)
        activeTasks[id]?.cancel(); activeTasks[id] = nil
        activeProcesses[id]?.terminate(); activeProcesses[id] = nil
        lastYtDlpProgressUpdateAt[id] = nil
        pausedIDs.remove(id)
        cleanupPartials(for: id)
        if deletingFile { deleteDownloadedFile(for: job) }
        store.remove(id)
        startQueue()
    }

    func deleteAllNotDownloading(deletingFiles: Bool = false) {
        let removable = store.jobs.filter { $0.status != .downloading }
        AppLogger.log("Delete all non-downloading jobs count=\(removable.count) deletingFiles=\(deletingFiles)")
        for job in removable {
            activeTasks[job.id]?.cancel(); activeTasks[job.id] = nil
            activeProcesses[job.id]?.terminate(); activeProcesses[job.id] = nil
            lastYtDlpProgressUpdateAt[job.id] = nil
            pausedIDs.remove(job.id)
            cleanupPartials(for: job.id)
            if deletingFiles { deleteDownloadedFile(for: job) }
        }
        store.removeAllNotDownloading()
        startQueue()
    }

    private func deleteDownloadedFile(for job: DownloadJob) {
        let file = URL(fileURLWithPath: job.destinationPath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            AppLogger.log("Downloaded file not found for delete path=\(file.lastPathComponent)", jobID: job.id)
            return
        }
        do {
            try FileManager.default.removeItem(at: file)
            AppLogger.log("Deleted downloaded file path=\(file.lastPathComponent)", jobID: job.id)
        } catch {
            AppLogger.log("Failed deleting downloaded file path=\(file.lastPathComponent) error=\(error.localizedDescription)", jobID: job.id)
        }
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
                store.update(jobID) { $0.status = .completed; $0.downloadedBytes = max($0.downloadedBytes, $0.totalBytes); $0.speedBytesPerSecond = 0; $0.externalProgress = 1; $0.isConverting = false }
                let completedJob = store.jobs.first(where: { $0.id == jobID }) ?? latest
                notify(title: "Download complete", body: completedJob.fileName, filePath: completedJob.destinationPath)
                return
            } catch {
                if pausedIDs.contains(jobID) || Task.isCancelled { return }
                attempts += 1
                AppLogger.log("Attempt \(attempts) failed for job id=\(jobID.uuidString): \(error.localizedDescription)", jobID: jobID)
                if attempts > store.settings.retryCount {
                    store.update(jobID) { $0.status = .failed; $0.errorCode = error.localizedDescription; $0.speedBytesPerSecond = 0; $0.isConverting = false }
                    notify(title: "Download failed", body: error.localizedDescription)
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
        guard (200..<400).contains(http.statusCode) else { throw NSError(domain: "Download", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: http.statusCode == 403 || http.statusCode == 401 ? "Permission denied or URL expired." : "Server returned HTTP \(http.statusCode)."] ) }
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
            throw NSError(domain: "Download", code: 2, userInfo: [NSLocalizedDescriptionKey: "yt-dlp is not installed. Install it with: brew install yt-dlp aria2"])
        }

        let outputTemplate = ytDlpOutputTemplate(for: job)
        var arguments = ytDlpArguments(for: job, outputTemplate: outputTemplate)
        var result = try await runYtDlp(executable: executable, arguments: arguments, jobID: job.id)

        if result.status != 0, isYouTubeURL(job.sourceUrl), isYouTubeChallengeFailure(result.output) {
            AppLogger.log("yt-dlp YouTube challenge failure detected; retry with alternate YouTube client", jobID: job.id)
            arguments = ytDlpArguments(for: job, outputTemplate: outputTemplate, youtubeFallback: true)
            result = try await runYtDlp(executable: executable, arguments: arguments, jobID: job.id)
        }

        if result.status != 0, isYouTubeURL(job.sourceUrl), isYouTubeForbiddenFailure(result.output) {
            AppLogger.log("yt-dlp YouTube 403 detected; retry without external downloader and constrained formats", jobID: job.id)
            arguments = ytDlpArguments(for: job, outputTemplate: outputTemplate, youtubeForbiddenFallback: true)
            result = try await runYtDlp(executable: executable, arguments: arguments, jobID: job.id)
        }

        guard result.status == 0 else {
            let message = ytDlpErrorMessage(from: result.output, status: result.status)
            throw NSError(domain: "Download", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
        }

        try await updateCompletedYtDlpJob(job)
    }

    private func runYtDlp(executable: URL, arguments: [String], jobID: UUID) async throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = processEnvironmentWithToolPaths()
        AppLogger.log("Run yt-dlp executable=\(executable.path) args=\(redactedArguments(process.arguments ?? []))", jobID: jobID)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        activeProcesses[jobID] = process
        let outputCollector = YtDlpOutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for progress in outputCollector.append(data) {
                Task { @MainActor in self?.applyYtDlpProgress(progress, jobID: jobID) }
            }
        }

        try process.run()
        await waitForProcess(process)
        pipe.fileHandleForReading.readabilityHandler = nil
        activeProcesses[jobID] = nil
        if let progress = outputCollector.flushProgress() {
            applyYtDlpProgress(progress, jobID: jobID, force: true)
        }
        lastYtDlpProgressUpdateAt[jobID] = nil
        let output = outputCollector.data
        let outputText = String(data: output, encoding: .utf8) ?? ""
        AppLogger.writeJobOutput(outputText, jobID: jobID)
        AppLogger.log("yt-dlp exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)", jobID: jobID)
        return (outputText, process.terminationStatus)
    }

    private func applyYtDlpProgress(_ progress: YtDlpProgress, jobID: UUID, force: Bool = false) {
        let now = Date()
        if !force, let lastUpdate = lastYtDlpProgressUpdateAt[jobID], now.timeIntervalSince(lastUpdate) < 0.75 {
            return
        }
        lastYtDlpProgressUpdateAt[jobID] = now
        store.update(jobID) { job in
            job.externalProgress = progress.fraction
            if let speedBytesPerSecond = progress.speedBytesPerSecond {
                job.speedBytesPerSecond = speedBytesPerSecond
            }
            if let totalBytes = progress.totalBytes, totalBytes > 0 {
                job.totalBytes = isHLSPlaylist(job.sourceUrl) ? totalBytes : max(job.totalBytes, totalBytes)
                job.downloadedBytes = Int64(Double(job.totalBytes) * progress.fraction)
            }
        }
    }

    private func ytDlpOutputTemplate(for job: DownloadJob) -> String {
        let destination = URL(fileURLWithPath: job.destinationPath)
        guard isHLSPlaylist(job.sourceUrl) || destination.pathExtension.lowercased() == "m3u8" else {
            return destination.path
        }
        return hlsTransportStreamURL(for: destination).path
    }

    private func ytDlpArguments(for job: DownloadJob, outputTemplate: String, youtubeFallback: Bool = false, youtubeForbiddenFallback: Bool = false) -> [String] {
        let browser = ytDlpCookieBrowser(for: job)
        let cookieArguments = ytDlpCookieArguments(for: job, browser: browser, cookiesProfilePath: store.settings.firefoxCookiesPath)
        var arguments: [String] = []
        if let referer = ytDlpReferer(for: job)?.absoluteString.nilIfEmpty {
            arguments += ["--referer", referer]
        }
        if isHLSPlaylist(job.sourceUrl) {
            arguments += ["--hls-use-mpegts", "--force-generic-extractor"]
        }
        if youtubeFallback {
            arguments += ["--extractor-args", "youtube:player_client=web_safari,web_embedded,web"]
        }
        if youtubeForbiddenFallback {
            arguments += ["--http-chunk-size", "10M"]
            arguments += ["--format", "bv*[height<=2160][vcodec!^=av01]+ba/bv*[height<=1440]+ba/best[height<=1080]/best"]
            arguments += ["--extractor-args", "youtube:player_client=default,-tv,web_safari,web_embedded"]
        } else if let format = ytDlpFormatSelector(for: job.preferredQuality) {
            arguments += ["--format", format]
        }

        arguments += cookieArguments
        if !youtubeForbiddenFallback {
            arguments += ["--downloader", "aria2c", "--downloader-args", "aria2c:-x 8 -s 8 -k 1M"]
        }
        arguments += [
            "--user-agent", defaultBrowserUserAgent(for: browser),
            "--no-check-certificate",
            "-N", "5"
        ]
        if !isHLSPlaylist(job.sourceUrl) {
            arguments += ["--merge-output-format", "mp4"]
        }
        arguments += ["-o", outputTemplate, job.sourceUrl.absoluteString]
        return arguments
    }

    private func ytDlpFormatSelector(for quality: String?) -> String? {
        guard let quality = quality?.nilIfEmpty, quality != "best" else { return nil }
        let digits = quality.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return "bv*[height<=\(digits)]+ba/best[height<=\(digits)]/best"
    }

    private func updateCompletedYtDlpJob(_ job: DownloadJob) async throws {
        let outputTemplate = URL(fileURLWithPath: ytDlpOutputTemplate(for: job))
        let folder = outputTemplate.deletingLastPathComponent()
        let prefix = outputTemplate.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".%(ext)s", with: "")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        guard let file = files.filter({ $0.lastPathComponent.hasPrefix(prefix) }).max(by: { lhs, rhs in
            ((try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else { return }
        let finalFile = try await convertHLSMpegTSToMP4IfNeeded(file, job: job)
        let size = (try? finalFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        AppLogger.log("yt-dlp output file=\(finalFile.path) size=\(size)", jobID: job.id)
        store.update(job.id) { $0.fileName = finalFile.lastPathComponent; $0.destinationPath = finalFile.path; $0.totalBytes = size; $0.downloadedBytes = size }
    }

    private func convertHLSMpegTSToMP4IfNeeded(_ file: URL, job: DownloadJob) async throws -> URL {
        guard isHLSPlaylist(job.sourceUrl), file.pathExtension.lowercased() == "ts" || isMpegTSFile(file) else { return file }
        guard let executable = findExecutable("ffmpeg") else {
            AppLogger.log("ffmpeg executable not found for HLS TS to MP4 conversion", jobID: job.id)
            throw NSError(domain: "Download", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg is not installed. Install it with: brew install ffmpeg"])
        }

        let replacingBrokenMP4 = file.pathExtension.lowercased() == "mp4"
        let output = replacingBrokenMP4 ? uniqueFileURL(file.deletingPathExtension().appendingPathExtension("remux.mp4")) : uniqueFileURL(file.deletingPathExtension().appendingPathExtension("mp4"))
        let arguments = ["-f", "mpegts", "-i", file.path, "-c", "copy", "-bsf:a", "aac_adtstoasc", output.path]
        store.update(job.id) { $0.isConverting = true; $0.speedBytesPerSecond = 0 }
        defer { store.update(job.id) { $0.isConverting = false } }
        let result = try await runExternalTool(executable: executable, arguments: arguments, jobID: job.id, toolName: "ffmpeg")
        guard result.status == 0 else {
            let message = result.output.split(separator: "\n").filter { !String($0).trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }.suffix(8).joined(separator: "\n").nilIfEmpty ?? "ffmpeg failed to convert TS to MP4 with code \(result.status)."
            throw NSError(domain: "Download", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        if replacingBrokenMP4 {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: output)
            return file
        }
        try? FileManager.default.removeItem(at: file)
        return output
    }

    private nonisolated func hlsTransportStreamURL(for destination: URL) -> URL {
        let fileName = destination.lastPathComponent.replacingOccurrences(of: ".%(ext)s", with: "")
        let baseName = (fileName as NSString).deletingPathExtension.nilIfEmpty ?? fileName
        return destination.deletingLastPathComponent().appendingPathComponent(baseName).appendingPathExtension("ts")
    }

    private nonisolated func isMpegTSFile(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 377)
        guard data.count >= 377 else { return false }
        return data[0] == 0x47 && data[188] == 0x47 && data[376] == 0x47
    }

    private func runExternalTool(executable: URL, arguments: [String], jobID: UUID, toolName: String) async throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = processEnvironmentWithToolPaths()
        AppLogger.log("Run \(toolName) executable=\(executable.path) args=\(redactedArguments(arguments))", jobID: jobID)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        activeProcesses[jobID] = process

        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        await waitForProcess(process)
        activeProcesses[jobID] = nil

        let outputText = String(data: output, encoding: .utf8) ?? ""
        AppLogger.writeJobOutput(outputText, jobID: jobID)
        AppLogger.log("\(toolName) exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)", jobID: jobID)
        return (outputText, process.terminationStatus)
    }

    private func notify(title: String, body: String, filePath: String? = nil) {
        guard store.settings.showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let filePath { content.userInfo = ["filePath": filePath] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { AppLogger.log("Notification delivery failed: \(error.localizedDescription)") }
        }
    }
}

private let chromeBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
private let firefoxBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:125.0) Gecko/20100101 Firefox/125.0"
private let toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/opt/node/bin", "/usr/local/opt/node/bin"]

private struct YtDlpProgress {
    var fraction: Double
    var totalBytes: Int64?
    var speedBytesPerSecond: Int64?
}

private final class YtDlpOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var bufferedText = ""

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return outputData
    }

    func append(_ data: Data) -> [YtDlpProgress] {
        lock.lock(); defer { lock.unlock() }
        outputData.append(data)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        bufferedText += text
        let parts = bufferedText.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        bufferedText = parts.last ?? ""
        return parts.dropLast().compactMap(parseYtDlpProgress)
    }

    func flushProgress() -> YtDlpProgress? {
        lock.lock(); defer { lock.unlock() }
        return parseYtDlpProgress(bufferedText)
    }
}

private func preferredDownloadMethod(for url: URL, mimeType: String?, sourceType: DownloadJob.SourceType) -> DownloadJob.DownloadMethod {
    let mime = mimeType?.lowercased() ?? ""
    if isHLSPlaylist(url) || mime.contains("mpegurl") || mime.contains("x-mpegurl") { return .ytDlp }
    if sourceType == .browserExtension { return .ytDlp }
    return .native
}

private func ytDlpCookieBrowser(for job: DownloadJob) -> String {
    switch job.sourceBrowser?.lowercased() {
    case "firefox": return "firefox"
    default: return "chrome"
    }
}

private func ytDlpCookieArguments(for job: DownloadJob, browser: String, cookiesProfilePath: String) -> [String] {
    if browser == "firefox" {
        guard let profile = firefoxCookieProfilePath(from: cookiesProfilePath) else {
            AppLogger.log("Firefox cookies unavailable; no cookies.sqlite found at configured cookies/profile path. Continuing without browser cookies.", jobID: job.id)
            return []
        }
        return ["--cookies-from-browser", "firefox:\(profile)"]
    }
    if let profile = chromiumCookieProfilePath(from: cookiesProfilePath) {
        return ["--cookies-from-browser", "\(browser):\(profile)"]
    }
    return ["--cookies-from-browser", browser]
}

private func firefoxCookieProfilePath(from configuredPath: String) -> String? {
    let expandedPath = (configuredPath as NSString).expandingTildeInPath
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return nil }

    let url = URL(fileURLWithPath: expandedPath)
    if !isDirectory.boolValue {
        return url.lastPathComponent == "cookies.sqlite" ? url.deletingLastPathComponent().path : nil
    }

    if fileManager.fileExists(atPath: url.appendingPathComponent("cookies.sqlite").path) {
        return url.path
    }

    guard let profiles = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
    return profiles
        .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("cookies.sqlite").path) }
        .max { lhs, rhs in
            profileModificationDate(lhs) < profileModificationDate(rhs)
        }?
        .path
}

private func chromiumCookieProfilePath(from configuredPath: String) -> String? {
    let expandedPath = (configuredPath as NSString).expandingTildeInPath
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return nil }

    let url = URL(fileURLWithPath: expandedPath)
    if !isDirectory.boolValue {
        return url.lastPathComponent == "Cookies" ? url.deletingLastPathComponent().path : nil
    }

    if fileManager.fileExists(atPath: url.appendingPathComponent("Cookies").path) {
        return url.path
    }

    guard let profiles = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
    return profiles
        .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Cookies").path) }
        .max { lhs, rhs in
            profileModificationDate(lhs) < profileModificationDate(rhs)
        }?
        .path
}

private func profileModificationDate(_ url: URL) -> Date {
    ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
}

private func defaultBrowserUserAgent(for browser: String) -> String {
    browser == "firefox" ? firefoxBrowserUserAgent : chromeBrowserUserAgent
}

private func isHLSPlaylist(_ url: URL) -> Bool {
    url.path.lowercased().contains(".m3u8")
}

private func isYouTubeURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
}

private func parseYtDlpProgress(_ line: String) -> YtDlpProgress? {
    guard line.contains("[download]") else { return nil }
    guard let percentMatch = firstRegexMatch(in: line, pattern: #"(\d+(?:\.\d+)?)%"#), let percent = Double(percentMatch) else { return nil }
    let totalBytes = firstRegexMatch(in: line, pattern: #"of\s+~?\s*([0-9.]+\s*[KMGT]?i?B)"#).flatMap(parseByteCount)
    let speedBytesPerSecond = firstRegexMatch(in: line, pattern: #"at\s+([0-9.]+\s*[KMGT]?i?B)/s"#).flatMap(parseByteCount)
    return YtDlpProgress(fraction: min(max(percent / 100, 0), 1), totalBytes: totalBytes, speedBytesPerSecond: speedBytesPerSecond)
}

private func firstRegexMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let matchRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[matchRange]).replacingOccurrences(of: " ", with: "")
}

private func parseByteCount(_ value: String) -> Int64? {
    guard let match = firstRegexMatch(in: value, pattern: #"^([0-9.]+)([KMGT]?i?B)$"#), let number = Double(match) else { return nil }
    let unit = value.replacingOccurrences(of: " ", with: "").drop { $0.isNumber || $0 == "." }.lowercased()
    let multiplier: Double
    switch unit {
    case "kb": multiplier = 1_000
    case "mb": multiplier = 1_000_000
    case "gb": multiplier = 1_000_000_000
    case "tb": multiplier = 1_000_000_000_000
    case "kib": multiplier = 1_024
    case "mib": multiplier = 1_048_576
    case "gib": multiplier = 1_073_741_824
    case "tib": multiplier = 1_099_511_627_776
    default: multiplier = 1
    }
    return Int64(number * multiplier)
}

private func ytDlpReferer(for job: DownloadJob) -> URL? {
    if isYouTubeURL(job.sourceUrl) { return job.sourceUrl }
    return job.pageUrl
}

private func isYouTubeChallengeFailure(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("signature solving failed") || lower.contains("n challenge solving failed") || lower.contains("the page needs to be reloaded")
}

private func isYouTubeForbiddenFailure(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("http error 403") || lower.contains("403: forbidden") || lower.contains("unable to download video data")
}

private func ytDlpErrorMessage(from output: String, status: Int32) -> String {
    var message = output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).joined(separator: "\n").nilIfEmpty ?? "yt-dlp failed with code \(status)."
    if isYouTubeChallengeFailure(output) {
        message += "\n\nTry updating dependencies: brew upgrade yt-dlp node deno aria2, then reload the YouTube page and try again."
    } else if isYouTubeForbiddenFailure(output) {
        message += "\n\nTry reloading the YouTube video, make sure it plays in the same Chrome browser, then update yt-dlp: brew upgrade yt-dlp."
    }
    return message
}

private func processEnvironmentWithToolPaths() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let existingPath = environment["PATH"] ?? ""
    var seen = Set<String>()
    let path = (toolSearchPaths + existingPath.split(separator: ":").map(String.init)).filter { seen.insert($0).inserted }.joined(separator: ":")
    environment["PATH"] = path
    return environment
}

private func findExecutable(_ name: String) -> URL? {
    let candidates = toolSearchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
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

func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>")
    let decoded = value.removingPercentEncoding ?? value
    let cleaned = decoded.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
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
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacVidCatch", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
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
        guard actual == expectedBytes else { throw NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Final file size does not match."]) }
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: tmp, to: destination)
}

private func uniqueFileURL(_ url: URL) -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return url }
    let directory = url.deletingLastPathComponent()
    let baseName = url.deletingPathExtension().lastPathComponent
    let pathExtension = url.pathExtension
    var index = 1
    while true {
        let candidate = directory.appendingPathComponent("\(baseName)-\(index)").appendingPathExtension(pathExtension)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        index += 1
    }
}

private func cleanupPartials(for id: UUID) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacVidCatch", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
}

private func filename(from disposition: String) -> String? {
    disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.lowercased().hasPrefix("filename=") }?.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
