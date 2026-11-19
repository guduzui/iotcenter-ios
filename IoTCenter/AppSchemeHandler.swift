import Foundation
import UniformTypeIdentifiers
import WebKit
import zlib

final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app"

    private let fileManager = FileManager.default
    private let webAppManager = WebAppManager.shared

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            let requestURL = try requestedURL(from: urlSchemeTask)
            let fileURL = try resolveFileURL(for: requestURL)
            let data = try Data(contentsOf: fileURL)

            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: textEncodingName(for: fileURL)
            )

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func requestedURL(from task: any WKURLSchemeTask) throws -> URL {
        guard let url = task.request.url else {
            throw SchemeError.invalidRequest
        }

        return url
    }

    private func resolveFileURL(for requestURL: URL) throws -> URL {
        let rootURL = try webAppManager.currentWWWRootURL()
        let relativePath = normalizedPath(from: requestURL)
        let candidateURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL

        try validate(candidateURL, inside: rootURL)

        if isFile(at: candidateURL) {
            return candidateURL
        }

        if isDirectory(at: candidateURL) {
            let indexURL = candidateURL.appendingPathComponent("index.html").standardizedFileURL
            try validate(indexURL, inside: rootURL)

            if isFile(at: indexURL) {
                return indexURL
            }
        }

        if candidateURL.pathExtension.isEmpty {
            let fallbackURL = rootURL.appendingPathComponent("index.html").standardizedFileURL
            if isFile(at: fallbackURL) {
                return fallbackURL
            }
        }

        throw SchemeError.fileNotFound(path: requestURL.path)
    }

    private func normalizedPath(from requestURL: URL) -> String {
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmedPath.isEmpty {
            return "index.html"
        }

        return trimmedPath
    }

    private func validate(_ candidateURL: URL, inside rootURL: URL) throws {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let candidatePath = candidateURL.path

        guard candidatePath == rootURL.path || candidatePath.hasPrefix(rootPath) else {
            throw SchemeError.forbiddenPath(candidatePath)
        }
    }

    private func isFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func mimeType(for fileURL: URL) -> String {
        guard !fileURL.pathExtension.isEmpty else {
            return "text/html"
        }

        return UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func textEncodingName(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm", "css", "js", "mjs", "json", "map", "svg", "txt":
            return "utf-8"
        default:
            return nil
        }
    }
}

extension AppSchemeHandler {
    enum SchemeError: LocalizedError {
        case invalidRequest
        case forbiddenPath(String)
        case fileNotFound(path: String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "WKWebView 发起了一个无效请求。"
            case .forbiddenPath(let path):
                return "访问被拒绝：\(path)"
            case .fileNotFound(let path):
                return "未找到资源：\(path)"
            }
        }
    }
}

extension Notification.Name {
    static let webAppDownloadProgressDidChange = Notification.Name("WebAppDownloadProgressDidChange")
}

final class WebAppManager {
    static let shared = WebAppManager()
    static let remoteZipURL = URL(string: "http://yunxue.online/version/web/www.zip")!

    enum DownloadProgressState: String {
        case idle
        case downloading
        case installing
        case completed
        case failed
    }

    enum DownloadProgressUserInfoKey {
        static let state = "state"
        static let receivedBytes = "receivedBytes"
        static let totalBytes = "totalBytes"
        static let message = "message"
    }

    enum UpdateOutcome {
        case alreadyCurrent
        case installed
        case failed(Error)
    }

    private struct Metadata: Codable, Equatable {
        var activeReleaseIdentifier: String?
        var remoteETag: String?
        var remoteLastModified: String?
        var remoteContentLength: Int64?

        func matches(_ remoteInfo: RemoteArchiveInfo) -> Bool {
            remoteETag == remoteInfo.eTag &&
            remoteLastModified == remoteInfo.lastModified &&
            remoteContentLength == remoteInfo.contentLength
        }
    }

    private struct RemoteArchiveInfo: Equatable {
        let eTag: String?
        let lastModified: String?
        let contentLength: Int64?
    }

    enum UpdateError: LocalizedError {
        case bundleResourcesMissing
        case webRootMissing(path: String)
        case applicationSupportDirectoryUnavailable
        case invalidHTTPResponse
        case unexpectedStatusCode(Int)
        case unsupportedArchiveLayout

        var errorDescription: String? {
            switch self {
            case .bundleResourcesMissing:
                return "未找到 App 包内的资源目录。"
            case .webRootMissing(let path):
                return "未找到前端目录：\(path)"
            case .applicationSupportDirectoryUnavailable:
                return "无法定位 App 的本地资源目录。"
            case .invalidHTTPResponse:
                return "远端更新服务返回了无效响应。"
            case .unexpectedStatusCode(let statusCode):
                return "远端更新服务返回了异常状态码：\(statusCode)。"
            case .unsupportedArchiveLayout:
                return "下载到的前端压缩包结构不正确，未找到 www/index.html。"
            }
        }
    }

    private let fileManager = FileManager.default
    private let stateLock = NSLock()
    private let downloadDelegate: DownloadDelegate
    private let session: URLSession
    private var cachedWWWRootURL: URL?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        self.downloadDelegate = DownloadDelegate()
        self.session = URLSession(configuration: configuration, delegate: downloadDelegate, delegateQueue: nil)
    }

    func currentWWWRootURL() throws -> URL {
        if let cachedWWWRootURL = withLockedState({ cachedWWWRootURL }), isValidWWWRoot(at: cachedWWWRootURL) {
            return cachedWWWRootURL
        }

        let resolvedURL = try resolveCurrentWWWRootURL()

        withLockedState {
            cachedWWWRootURL = resolvedURL
        }

        return resolvedURL
    }

    func refreshFromRemoteIfNeeded(force: Bool = false) async -> UpdateOutcome {
        do {
            let remoteInfo = try await fetchRemoteArchiveInfo()

            let installedWWWRootURL = try await downloadAndInstall(remoteInfo: remoteInfo)
            withLockedState {
                cachedWWWRootURL = installedWWWRootURL
            }

            postDownloadProgress(
                state: .completed,
                receivedBytes: remoteInfo.contentLength ?? 0,
                totalBytes: remoteInfo.contentLength
            )
            return .installed
        } catch {
            postDownloadProgress(state: .failed, message: error.localizedDescription)
            return .failed(error)
        }
    }

    private func resolveCurrentWWWRootURL() throws -> URL {
        let metadata = loadMetadata()

        if let installedWWWRootURL = installedWWWRootURL(for: metadata.activeReleaseIdentifier), isValidWWWRoot(at: installedWWWRootURL) {
            return installedWWWRootURL
        }

        return try bundledWWWRootURL()
    }

    private func bundledWWWRootURL() throws -> URL {
        guard let resourcesURL = Bundle.main.resourceURL else {
            throw UpdateError.bundleResourcesMissing
        }

        let rootURL = resourcesURL.appendingPathComponent("www", isDirectory: true).standardizedFileURL
        guard isValidWWWRoot(at: rootURL) else {
            throw UpdateError.webRootMissing(path: rootURL.path)
        }

        return rootURL
    }

    private func installedWWWRootURL(for releaseIdentifier: String?) -> URL? {
        guard let releaseIdentifier, !releaseIdentifier.isEmpty else {
            return nil
        }

        return releasesDirectoryURL()
            .appendingPathComponent(releaseIdentifier, isDirectory: true)
            .appendingPathComponent("www", isDirectory: true)
            .standardizedFileURL
    }

    private func releasesDirectoryURL() -> URL {
        appStorageDirectoryURL().appendingPathComponent("releases", isDirectory: true)
    }

    private func metadataFileURL() -> URL {
        appStorageDirectoryURL().appendingPathComponent("metadata.json")
    }

    private func appStorageDirectoryURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return baseURL
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "IoTCenter", isDirectory: true)
            .appendingPathComponent("WebAppStorage", isDirectory: true)
            .standardizedFileURL
    }

    private func ensureStorageDirectories() throws {
        let storageDirectoryURL = appStorageDirectoryURL()
        try fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: releasesDirectoryURL(), withIntermediateDirectories: true)
    }

    private func loadMetadata() -> Metadata {
        let metadataURL = metadataFileURL()
        guard let data = try? Data(contentsOf: metadataURL) else {
            return Metadata()
        }

        return (try? JSONDecoder().decode(Metadata.self, from: data)) ?? Metadata()
    }

    private func saveMetadata(_ metadata: Metadata) throws {
        try ensureStorageDirectories()
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataFileURL(), options: .atomic)
    }

    private func fetchRemoteArchiveInfo() async throws -> RemoteArchiveInfo {
        var request = URLRequest(url: Self.remoteZipURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (_, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(from: response)

        return RemoteArchiveInfo(
            eTag: normalizedHeaderValue(httpResponse.value(forHTTPHeaderField: "ETag")),
            lastModified: normalizedHeaderValue(httpResponse.value(forHTTPHeaderField: "Last-Modified")),
            contentLength: parseContentLength(from: httpResponse)
        )
    }

    private func downloadAndInstall(remoteInfo: RemoteArchiveInfo) async throws -> URL {
        try ensureStorageDirectories()

        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("web-update-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectoryURL)
        }

        postDownloadProgress(state: .downloading, receivedBytes: 0, totalBytes: remoteInfo.contentLength)
        let (downloadedFileURL, response) = try await downloadArchive()
        _ = try validatedHTTPResponse(from: response)

        let archiveURL = temporaryDirectoryURL.appendingPathComponent("www.zip")
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.moveItem(at: downloadedFileURL, to: archiveURL)

        postDownloadProgress(state: .installing, receivedBytes: remoteInfo.contentLength ?? 0, totalBytes: remoteInfo.contentLength)
        let extractionDirectoryURL = temporaryDirectoryURL.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectoryURL, withIntermediateDirectories: true)
        try ZipArchiveExtractor.extractArchive(at: archiveURL, to: extractionDirectoryURL)

        let extractedWWWRootURL = try resolveExtractedWWWRootURL(in: extractionDirectoryURL)
        let releaseIdentifier = UUID().uuidString.lowercased()
        let releaseDirectoryURL = releasesDirectoryURL().appendingPathComponent(releaseIdentifier, isDirectory: true)

        try fileManager.createDirectory(at: releaseDirectoryURL, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: extractedWWWRootURL,
            to: releaseDirectoryURL.appendingPathComponent("www", isDirectory: true)
        )

        try saveMetadata(
            Metadata(
                activeReleaseIdentifier: releaseIdentifier,
                remoteETag: remoteInfo.eTag,
                remoteLastModified: remoteInfo.lastModified,
                remoteContentLength: remoteInfo.contentLength
            )
        )

        cleanupInactiveReleases(keeping: releaseIdentifier)

        return releaseDirectoryURL.appendingPathComponent("www", isDirectory: true)
    }

    private func downloadArchive() async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            downloadDelegate.prepareForDownload(
                progress: { [weak self] receivedBytes, totalBytes in
                    self?.postDownloadProgress(
                        state: .downloading,
                        receivedBytes: receivedBytes,
                        totalBytes: totalBytes > 0 ? totalBytes : nil
                    )
                },
                completion: { result in
                    continuation.resume(with: result)
                }
            )

            let task = session.downloadTask(with: Self.remoteZipURL)
            task.resume()
        }
    }

    private func postDownloadProgress(
        state: DownloadProgressState,
        receivedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        message: String? = nil
    ) {
        var userInfo: [String: Any] = [
            DownloadProgressUserInfoKey.state: state.rawValue
        ]

        if let receivedBytes {
            userInfo[DownloadProgressUserInfoKey.receivedBytes] = receivedBytes
        }

        if let totalBytes {
            userInfo[DownloadProgressUserInfoKey.totalBytes] = totalBytes
        }

        if let message, !message.isEmpty {
            userInfo[DownloadProgressUserInfoKey.message] = message
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .webAppDownloadProgressDidChange,
                object: self,
                userInfo: userInfo
            )
        }
    }

    private func resolveExtractedWWWRootURL(in extractionDirectoryURL: URL) throws -> URL {
        let directWWWRootURL = extractionDirectoryURL.appendingPathComponent("www", isDirectory: true).standardizedFileURL
        if isValidWWWRoot(at: directWWWRootURL) {
            return directWWWRootURL
        }

        if isValidWWWRoot(at: extractionDirectoryURL) {
            return extractionDirectoryURL
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: extractionDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for itemURL in contents {
            let nestedWWWRootURL = itemURL.appendingPathComponent("www", isDirectory: true).standardizedFileURL
            if isValidWWWRoot(at: nestedWWWRootURL) {
                return nestedWWWRootURL
            }

            if isValidWWWRoot(at: itemURL) {
                return itemURL
            }
        }

        throw UpdateError.unsupportedArchiveLayout
    }

    private func cleanupInactiveReleases(keeping activeReleaseIdentifier: String) {
        let releasesDirectoryURL = releasesDirectoryURL()
        let releaseDirectoryURLs = (try? fileManager.contentsOfDirectory(
            at: releasesDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for releaseDirectoryURL in releaseDirectoryURLs where releaseDirectoryURL.lastPathComponent != activeReleaseIdentifier {
            try? fileManager.removeItem(at: releaseDirectoryURL)
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let lock = NSLock()
        private var progressHandler: ((Int64, Int64) -> Void)?
        private var completionHandler: ((Result<(URL, URLResponse), Error>) -> Void)?
        private var downloadedFileURL: URL?
        private var downloadPersistenceError: Error?

        func prepareForDownload(
            progress: @escaping (Int64, Int64) -> Void,
            completion: @escaping (Result<(URL, URLResponse), Error>) -> Void
        ) {
            lock.lock()
            progressHandler = progress
            completionHandler = completion
            downloadedFileURL = nil
            downloadPersistenceError = nil
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            lock.lock()
            let progressHandler = self.progressHandler
            lock.unlock()
            progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            lock.lock()
            do {
                downloadedFileURL = try persistDownloadedFile(at: location)
                downloadPersistenceError = nil
            } catch {
                downloadedFileURL = nil
                downloadPersistenceError = error
            }
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            let completionHandler = self.completionHandler
            let downloadedFileURL = self.downloadedFileURL
            let downloadPersistenceError = self.downloadPersistenceError
            self.progressHandler = nil
            self.completionHandler = nil
            self.downloadedFileURL = nil
            self.downloadPersistenceError = nil
            lock.unlock()

            if let error {
                completionHandler?(.failure(error))
                return
            }

            if let downloadPersistenceError {
                completionHandler?(.failure(downloadPersistenceError))
                return
            }

            guard let downloadedFileURL, let response = task.response else {
                completionHandler?(.failure(UpdateError.invalidHTTPResponse))
                return
            }

            completionHandler?(.success((downloadedFileURL, response)))
        }

        private func persistDownloadedFile(at sourceURL: URL) throws -> URL {
            let fileManager = FileManager.default
            let destinationDirectoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("web-update-downloads", isDirectory: true)
                .standardizedFileURL
            try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

            let destinationURL = destinationDirectoryURL
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    }

    private func validatedHTTPResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return httpResponse
    }

    private func normalizedHeaderValue(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedValue.isEmpty else {
            return nil
        }

        return trimmedValue
    }

    private func parseContentLength(from response: HTTPURLResponse) -> Int64? {
        guard
            let contentLengthValue = response.value(forHTTPHeaderField: "Content-Length")?.trimmingCharacters(in: .whitespacesAndNewlines),
            let contentLength = Int64(contentLengthValue)
        else {
            return nil
        }

        return contentLength
    }

    private func isValidWWWRoot(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let indexURL = url.appendingPathComponent("index.html").standardizedFileURL
        return fileManager.fileExists(atPath: indexURL.path)
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        return body()
    }
}

private enum ZipArchiveExtractor {
    private static let localFileHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50

    struct CentralDirectoryEntry {
        let path: String
        let flags: UInt16
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
        let recordLength: Int
    }

    enum ExtractionError: LocalizedError {
        case invalidArchive
        case unsupportedZIP64
        case unsupportedCompressionMethod(UInt16)
        case encryptedEntriesAreNotSupported(String)
        case malformedEntry(String)
        case invalidDestinationPath(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return "前端压缩包不是有效的 ZIP 文件。"
            case .unsupportedZIP64:
                return "当前 ZIP 文件使用了不支持的 ZIP64 格式。"
            case .unsupportedCompressionMethod(let method):
                return "当前 ZIP 使用了不支持的压缩方法：\(method)。"
            case .encryptedEntriesAreNotSupported(let path):
                return "ZIP 中包含加密文件，无法解压：\(path)"
            case .malformedEntry(let path):
                return "ZIP 中存在损坏的文件条目：\(path)"
            case .invalidDestinationPath(let path):
                return "ZIP 中存在非法路径，已拒绝解压：\(path)"
            case .checksumMismatch(let path):
                return "ZIP 中文件校验失败：\(path)"
            }
        }
    }

    static func extractArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let endRecordOffset = try endOfCentralDirectoryOffset(in: archiveData)
        let (totalEntries, centralDirectoryOffset) = try endOfCentralDirectory(in: archiveData, at: endRecordOffset)

        var cursor = centralDirectoryOffset
        for _ in 0..<totalEntries {
            let entry = try centralDirectoryEntry(in: archiveData, at: cursor)
            cursor += entry.recordLength

            guard shouldExtract(path: entry.path) else {
                continue
            }

            let outputURL = try resolvedOutputURL(for: entry.path, inside: destinationURL)

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }

            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let extractedData = try fileData(for: entry, in: archiveData)
            try extractedData.write(to: outputURL, options: .atomic)
        }
    }

    private static func shouldExtract(path: String) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            return false
        }

        if normalizedPath.hasPrefix("__MACOSX/") {
            return false
        }

        return true
    }

    private static func resolvedOutputURL(for path: String, inside destinationURL: URL) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let outputURL = destinationURL.appendingPathComponent(normalizedPath).standardizedFileURL

        let destinationPath = destinationURL.path.hasSuffix("/") ? destinationURL.path : destinationURL.path + "/"
        guard outputURL.path.hasPrefix(destinationPath) else {
            throw ExtractionError.invalidDestinationPath(path)
        }

        return outputURL
    }

    private static func endOfCentralDirectoryOffset(in archiveData: Data) throws -> Int {
        let minimumRecordLength = 22
        guard archiveData.count >= minimumRecordLength else {
            throw ExtractionError.invalidArchive
        }

        let lowestSearchOffset = max(0, archiveData.count - (minimumRecordLength + 65_535))
        var cursor = archiveData.count - minimumRecordLength

        while cursor >= lowestSearchOffset {
            if try archiveData.uint32LE(at: cursor) == endOfCentralDirectorySignature {
                return cursor
            }
            cursor -= 1
        }

        throw ExtractionError.invalidArchive
    }

    private static func endOfCentralDirectory(in archiveData: Data, at offset: Int) throws -> (totalEntries: Int, centralDirectoryOffset: Int) {
        let totalEntries = try archiveData.uint16LE(at: offset + 10)
        let centralDirectoryOffset = try archiveData.uint32LE(at: offset + 16)

        guard totalEntries != .max, centralDirectoryOffset != .max else {
            throw ExtractionError.unsupportedZIP64
        }

        return (Int(totalEntries), Int(centralDirectoryOffset))
    }

    private static func centralDirectoryEntry(in archiveData: Data, at offset: Int) throws -> CentralDirectoryEntry {
        guard try archiveData.uint32LE(at: offset) == centralDirectoryHeaderSignature else {
            throw ExtractionError.invalidArchive
        }

        let flags = try archiveData.uint16LE(at: offset + 8)
        let compressionMethod = try archiveData.uint16LE(at: offset + 10)
        let crc32 = try archiveData.uint32LE(at: offset + 16)
        let compressedSize = try archiveData.uint32LE(at: offset + 20)
        let uncompressedSize = try archiveData.uint32LE(at: offset + 24)
        let fileNameLength = try archiveData.uint16LE(at: offset + 28)
        let extraFieldLength = try archiveData.uint16LE(at: offset + 30)
        let commentLength = try archiveData.uint16LE(at: offset + 32)
        let localHeaderOffset = try archiveData.uint32LE(at: offset + 42)

        guard compressedSize != .max, uncompressedSize != .max, localHeaderOffset != .max else {
            throw ExtractionError.unsupportedZIP64
        }

        let nameOffset = offset + 46
        let path = try archiveData.string(at: nameOffset, length: Int(fileNameLength))
        let isDirectory = path.hasSuffix("/")
        let recordLength = 46 + Int(fileNameLength) + Int(extraFieldLength) + Int(commentLength)

        return CentralDirectoryEntry(
            path: path,
            flags: flags,
            compressionMethod: compressionMethod,
            crc32: crc32,
            compressedSize: Int(compressedSize),
            uncompressedSize: Int(uncompressedSize),
            localHeaderOffset: Int(localHeaderOffset),
            isDirectory: isDirectory,
            recordLength: recordLength
        )
    }

    private static func fileData(for entry: CentralDirectoryEntry, in archiveData: Data) throws -> Data {
        if entry.flags & 0x0001 != 0 {
            throw ExtractionError.encryptedEntriesAreNotSupported(entry.path)
        }

        guard try archiveData.uint32LE(at: entry.localHeaderOffset) == localFileHeaderSignature else {
            throw ExtractionError.malformedEntry(entry.path)
        }

        let fileNameLength = try archiveData.uint16LE(at: entry.localHeaderOffset + 26)
        let extraFieldLength = try archiveData.uint16LE(at: entry.localHeaderOffset + 28)
        let payloadOffset = entry.localHeaderOffset + 30 + Int(fileNameLength) + Int(extraFieldLength)
        let payloadEndOffset = payloadOffset + entry.compressedSize

        guard payloadOffset >= 0, payloadEndOffset <= archiveData.count else {
            throw ExtractionError.malformedEntry(entry.path)
        }

        let compressedData = archiveData.subdata(in: payloadOffset..<payloadEndOffset)
        let extractedData: Data

        switch entry.compressionMethod {
        case 0:
            extractedData = compressedData
        case 8:
            extractedData = try inflate(data: compressedData, expectedSize: entry.uncompressedSize)
        default:
            throw ExtractionError.unsupportedCompressionMethod(entry.compressionMethod)
        }

        guard extractedData.count == entry.uncompressedSize else {
            throw ExtractionError.malformedEntry(entry.path)
        }

        let calculatedCRC32 = extractedData.withUnsafeBytes { rawBufferPointer -> UInt32 in
            guard let baseAddress = rawBufferPointer.bindMemory(to: Bytef.self).baseAddress else {
                return 0
            }
            return UInt32(crc32(0, baseAddress, uInt(extractedData.count)))
        }

        guard calculatedCRC32 == entry.crc32 else {
            throw ExtractionError.checksumMismatch(entry.path)
        }

        return extractedData
    }

    private static func inflate(data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ExtractionError.invalidArchive
        }
        defer {
            inflateEnd(&stream)
        }

        let bufferChunkSize = max(expectedSize, 64 * 1024)
        var outputData = Data(count: max(bufferChunkSize, 1))
        var inflateStatus: Int32 = Z_OK

        try data.withUnsafeBytes { compressedBytes in
            guard let inputAddress = compressedBytes.bindMemory(to: Bytef.self).baseAddress else {
                throw ExtractionError.invalidArchive
            }

            stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                if Int(stream.total_out) >= outputData.count {
                    outputData.count += bufferChunkSize
                }

                let outputStartOffset = Int(stream.total_out)
                let writableByteCount = outputData.count - outputStartOffset

                try outputData.withUnsafeMutableBytes { outputBytes in
                    guard let outputAddress = outputBytes.bindMemory(to: Bytef.self).baseAddress else {
                        throw ExtractionError.invalidArchive
                    }

                    stream.next_out = outputAddress.advanced(by: outputStartOffset)
                    stream.avail_out = uInt(writableByteCount)
                    inflateStatus = zlib.inflate(&stream, Z_NO_FLUSH)
                }
            } while inflateStatus == Z_OK
        }

        guard inflateStatus == Z_STREAM_END else {
            throw ExtractionError.invalidArchive
        }

        outputData.count = Int(stream.total_out)
        return outputData
    }
}

private extension Data {
    func uint16LE(at offset: Int) throws -> UInt16 {
        let range = offset..<(offset + 2)
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ZipArchiveExtractor.ExtractionError.invalidArchive
        }

        var value: UInt16 = 0
        _ = withUnsafeBytes { rawBufferPointer in
            memcpy(&value, rawBufferPointer.baseAddress!.advanced(by: offset), 2)
        }
        return UInt16(littleEndian: value)
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        let range = offset..<(offset + 4)
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ZipArchiveExtractor.ExtractionError.invalidArchive
        }

        var value: UInt32 = 0
        _ = withUnsafeBytes { rawBufferPointer in
            memcpy(&value, rawBufferPointer.baseAddress!.advanced(by: offset), 4)
        }
        return UInt32(littleEndian: value)
    }

    func string(at offset: Int, length: Int) throws -> String {
        let range = offset..<(offset + length)
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ZipArchiveExtractor.ExtractionError.invalidArchive
        }

        let data = self.subdata(in: range)
        if let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            return string
        }

        throw ZipArchiveExtractor.ExtractionError.invalidArchive
    }
}
