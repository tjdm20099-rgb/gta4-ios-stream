import Foundation
import Compression

/// Manages the on-phone GTA IV Engine Bundle and automatically detects or syncs
/// an Extracted GTA IV ISO directory (in On My iPhone -> GTA IV or synced from
/// 204.12.199.24:4444/extracted) so the game plays directly with zero ISO unpacking.
final class GameInstaller {
    static let shared = GameInstaller()
    static let currentBundleVersion = "2.2.0"

    let baseSupportDir: URL
    let documentsDir: URL
    let extractedSyncDir: URL
    let isoDir: URL

    private var cancelSyncFlag = false
    private(set) var isSyncingExtracted = false
    private var cachedManifestDir: String?
    private var cachedManifestData: Data?
    private let cacheLock = NSLock()

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseSupportDir = appSupport.appendingPathComponent("GTA4Local", isDirectory: true)
        documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        extractedSyncDir = documentsDir.appendingPathComponent("extracted-iso", isDirectory: true)
        isoDir = documentsDir.appendingPathComponent("GTA4Local/iso", isDirectory: true)

        try? fm.createDirectory(at: baseSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: extractedSyncDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: isoDir, withIntermediateDirectories: true)

        var resValues = URLResourceValues()
        resValues.isExcludedFromBackup = true
        var mutableBase = baseSupportDir
        try? mutableBase.setResourceValues(resValues)
        var mutableExt = extractedSyncDir
        try? mutableExt.setResourceValues(resValues)
    }

    var isEngineInstalled: Bool {
        let wasmPath = baseSupportDir.appendingPathComponent("site/gta4.wasm").path
        let verURL = baseSupportDir.appendingPathComponent("bundle-version.txt")
        let installedVer = (try? String(contentsOf: verURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: wasmPath) && installedVer == Self.currentBundleVersion
    }

    // MARK: - Extracted ISO Detection & Resolution (On My iPhone -> GTA IV)

    private func directoryContainsDefaultXex(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return items.contains { $0.lowercased() == "default.xex" }
    }

    /// Searches phone Documents folder for any extracted GTA IV ISO folder containing default.xex.
    func resolvedLocalExtractedDir() -> URL? {
        let fm = FileManager.default
        let directCandidates = [
            extractedSyncDir,
            documentsDir.appendingPathComponent("extracted", isDirectory: true),
            documentsDir.appendingPathComponent("game", isDirectory: true),
            documentsDir.appendingPathComponent("GTA4Local/extracted", isDirectory: true),
            documentsDir
        ]
        for cand in directCandidates where directoryContainsDefaultXex(cand) {
            return cand
        }
        // Also scan any top-level folder user dropped into Files -> On My iPhone -> GTA IV
        if let children = try? fm.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   directoryContainsDefaultXex(child) {
                    return child
                }
            }
        }
        return nil
    }

    func invalidateExtractedCache() {
        cacheLock.lock()
        cachedManifestDir = nil
        cachedManifestData = nil
        cacheLock.unlock()
    }

    func localExtractedSummary() -> (found: Bool, fileCount: Int, totalBytes: Int64) {
        guard let data = localExtractedManifestData(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ready"] as? Bool) == true else {
            return (false, 0, 0)
        }
        let count = (obj["fileCount"] as? Int) ?? 0
        let bytes = (obj["totalBytes"] as? NSNumber)?.int64Value ?? 0
        return (true, count, bytes)
    }

    func localExtractedManifestData() -> Data? {
        guard let root = resolvedLocalExtractedDir() else { return nil }
        let rootStd = root.standardizedFileURL.path
        cacheLock.lock()
        if cachedManifestDir == rootStd, let existing = cachedManifestData {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [[Any]] = []
        var totalBytes: Int64 = 0
        var hasXex = false
        var hasXexp = false

        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            let stdPath = fileURL.standardizedFileURL.path
            guard stdPath.hasPrefix(rootStd + "/") else { continue }
            let rel = String(stdPath.dropFirst(rootStd.count + 1))
            if rel.hasSuffix(".ipa") { continue }
            let sz = Int64(vals.fileSize ?? 0)
            if rel.lowercased() == "default.xex" { hasXex = true }
            if rel.lowercased() == "default.xexp" { hasXexp = true }
            files.append([rel, sz])
            totalBytes += sz
        }

        // Include .install-manifest if present
        let manifestDot = root.appendingPathComponent(".install-manifest")
        if let attrs = try? fm.attributesOfItem(atPath: manifestDot.path),
           let sz = attrs[.size] as? NSNumber {
            files.append([".install-manifest", sz.int64Value])
        }

        guard hasXex, files.count > 5 else { return nil }
        let dict: [String: Any] = [
            "ready": true,
            "fileCount": files.count,
            "totalBytes": totalBytes,
            "hasBaseXex": hasXex,
            "hasPatchXexp": hasXexp,
            "files": files
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        cacheLock.lock()
        cachedManifestDir = rootStd
        cachedManifestData = data
        cacheLock.unlock()
        return data
    }

    /// Resolves a relative path inside the phone's local extracted ISO directory (case-insensitive fallback).
    func resolveExtractedFile(relativePath: String) -> URL? {
        guard let root = resolvedLocalExtractedDir() else { return nil }
        let rootStd = root.standardizedFileURL.path
        let direct = root.appendingPathComponent(relativePath).standardizedFileURL
        guard direct.path.hasPrefix(rootStd + "/") else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: direct.path) { return direct }

        var cur = root
        for comp in relativePath.split(separator: "/") {
            let wanted = comp.lowercased()
            guard let entries = try? fm.contentsOfDirectory(atPath: cur.path),
                  let match = entries.first(where: { $0.lowercased() == wanted }) else {
                return nil
            }
            cur.appendPathComponent(match)
        }
        return fm.fileExists(atPath: cur.path) ? cur : nil
    }

    // MARK: - Sync Extracted ISO Folder from Server to Phone SSD

    func cancelExtractedSync() {
        cancelSyncFlag = true
        isSyncingExtracted = false
    }

    func deleteLocalExtractedCopy() {
        cancelExtractedSync()
        try? FileManager.default.removeItem(at: extractedSyncDir)
        try? FileManager.default.createDirectory(at: extractedSyncDir, withIntermediateDirectories: true)
        invalidateExtractedCache()
    }

    func syncExtractedFolderFromServer(
        host rawHost: String,
        progress: @escaping (_ doneFiles: Int, _ totalFiles: Int, _ gotBytes: Int64, _ totalBytes: Int64) -> Void,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        if isSyncingExtracted { return }
        isSyncingExtracted = true
        cancelSyncFlag = false

        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (host.hasPrefix("http://") || host.hasPrefix("https://"))
            ? host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : "http://\(host)"

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.isSyncingExtracted = false
                self.invalidateExtractedCache()
            }
            guard let manifestURL = URL(string: base + "/extracted/manifest.json") else {
                completion(.failure(NSError(domain: "GTA4", code: 20, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])))
                return
            }
            do {
                let mData = try Data(contentsOf: manifestURL)
                guard let obj = try JSONSerialization.jsonObject(with: mData) as? [String: Any],
                      (obj["ready"] as? Bool) == true,
                      let list = obj["files"] as? [[Any]], !list.isEmpty else {
                    throw NSError(domain: "GTA4", code: 21, userInfo: [
                        NSLocalizedDescriptionKey: "Server is still finishing ISO extraction — try again in a minute"
                    ])
                }

                let totalBytes = (obj["totalBytes"] as? NSNumber)?.int64Value ?? 1
                var gotBytes: Int64 = 0
                let fm = FileManager.default
                let cfg = URLSessionConfiguration.ephemeral
                cfg.timeoutIntervalForRequest = 60
                cfg.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: cfg)
                defer { session.finishTasksAndInvalidate() }

                for (idx, item) in list.enumerated() {
                    if self.cancelSyncFlag {
                        throw NSError(domain: "GTA4", code: NSURLErrorCancelled, userInfo: [NSLocalizedDescriptionKey: "Paused"])
                    }
                    guard item.count >= 2,
                          let rel = item[0] as? String,
                          let szNum = item[1] as? NSNumber else { continue }
                    let expected = szNum.int64Value
                    let dest = self.extractedSyncDir.appendingPathComponent(rel).standardizedFileURL
                    guard dest.path.hasPrefix(self.extractedSyncDir.standardizedFileURL.path) else { continue }

                    if let attrs = try? fm.attributesOfItem(atPath: dest.path),
                       let curSz = attrs[.size] as? NSNumber, curSz.int64Value == expected {
                        gotBytes += expected
                        if idx % 15 == 0 { progress(idx + 1, list.count, gotBytes, totalBytes) }
                        continue
                    }

                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoded = rel
                        .split(separator: "/")
                        .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                        .joined(separator: "/")
                    guard let fURL = URL(string: base + "/extracted/file/" + encoded) else { continue }

                    let sem = DispatchSemaphore(value: 0)
                    var dlErr: Error?
                    let task = session.downloadTask(with: fURL) { tmpURL, resp, err in
                        defer { sem.signal() }
                        if let err = err { dlErr = err; return }
                        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let tmpURL = tmpURL else {
                            dlErr = NSError(domain: "GTA4", code: 22, userInfo: [NSLocalizedDescriptionKey: "Failed downloading \(rel)"])
                            return
                        }
                        do {
                            try? fm.removeItem(at: dest)
                            try fm.moveItem(at: tmpURL, to: dest)
                        } catch {
                            dlErr = error
                        }
                    }
                    task.resume()
                    _ = sem.wait(timeout: .now() + 600)
                    if let dlErr = dlErr { throw dlErr }

                    gotBytes += expected
                    progress(idx + 1, list.count, gotBytes, totalBytes)
                }
                completion(.success(list.count))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Legacy Raw ISO / TU8 Fallbacks & Free Space

    func resolvedLocalISOURL() -> URL? {
        let fm = FileManager.default
        let managed = isoDir.appendingPathComponent("gta4.iso")
        if let attrs = try? fm.attributesOfItem(atPath: managed.path),
           let sz = attrs[.size] as? NSNumber, sz.int64Value > 100 * 1024 * 1024 {
            return managed
        }
        if let items = try? fm.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items where item.pathExtension.lowercased() == "iso" {
                if let attrs = try? fm.attributesOfItem(atPath: item.path),
                   let sz = attrs[.size] as? NSNumber, sz.int64Value > 100 * 1024 * 1024 {
                    return item
                }
            }
        }
        return nil
    }

    func resolvedLocalTU8URL() -> URL? {
        let fm = FileManager.default
        for c in [isoDir.appendingPathComponent("tu8"), baseSupportDir.appendingPathComponent("iso/tu8")] {
            if fm.fileExists(atPath: c.path) { return c }
        }
        return nil
    }

    func freeDiskBytes() -> Int64 {
        if let vals = try? documentsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = vals.volumeAvailableCapacityForImportantUsage {
            return free
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: documentsDir.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    // MARK: - Engine Bundle Installer

    func installEngineBundle(
        from rawHost: String,
        progress: @escaping (_ status: String, _ fraction: Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (host.hasPrefix("http://") || host.hasPrefix("https://")) ? host : "http://\(host)"
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/bundle.tar.deflate") else {
            completion(.failure(NSError(domain: "GTA4", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])))
            return
        }

        progress("Connecting to \(host) for GTA IV Engine v2.2…", 0.02)

        final class BundleDelegate: NSObject, URLSessionDownloadDelegate {
            let onProgress: (String, Double) -> Void
            let onFinish: (Result<URL, Error>) -> Void
            var completed = false

            init(onProgress: @escaping (String, Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
                self.onProgress = onProgress
                self.onFinish = onFinish
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                let mbGot = Double(totalBytesWritten) / 1_048_576.0
                if totalBytesExpectedToWrite > 0 {
                    let mbTot = Double(totalBytesExpectedToWrite) / 1_048_576.0
                    let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    onProgress(String(format: "Downloading GTA IV Engine: %.1f / %.1f MB", mbGot, mbTot), 0.03 + frac * 0.75)
                } else {
                    onProgress(String(format: "Downloading GTA IV Engine: %.1f MB…", mbGot), 0.4)
                }
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    completed = true
                    onFinish(.failure(NSError(domain: "GTA4", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"
                    ])))
                    return
                }
                let saved = FileManager.default.temporaryDirectory.appendingPathComponent("gta4-bundle-\(UUID().uuidString).deflate")
                do {
                    try? FileManager.default.removeItem(at: saved)
                    try FileManager.default.moveItem(at: location, to: saved)
                    completed = true
                    onFinish(.success(saved))
                } catch {
                    completed = true
                    onFinish(.failure(error))
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error = error, !completed {
                    completed = true
                    onFinish(.failure(error))
                }
            }
        }

        let del = BundleDelegate(onProgress: progress) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let deflateURL):
                DispatchQueue.global(qos: .userInitiated).async {
                    let tarURL = FileManager.default.temporaryDirectory.appendingPathComponent("gta4-bundle-\(UUID().uuidString).tar")
                    defer {
                        try? FileManager.default.removeItem(at: deflateURL)
                        try? FileManager.default.removeItem(at: tarURL)
                    }
                    do {
                        progress("Decompressing GTA IV Engine archive…", 0.82)
                        try self.decompressDeflateFile(src: deflateURL, dst: tarURL)
                        progress("Installing engine & extracted-ISO mounter…", 0.90)
                        let count = try self.extractUSTar(tarURL: tarURL, into: self.baseSupportDir)
                        let verURL = self.baseSupportDir.appendingPathComponent("bundle-version.txt")
                        try? Self.currentBundleVersion.write(to: verURL, atomically: true, encoding: .utf8)
                        progress("Installed \(count) GTA IV Engine files!", 1.0)
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 900
        let session = URLSession(configuration: cfg, delegate: del, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    private func decompressDeflateFile(src: URL, dst: URL) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let inHandle = try FileHandle(forReadingFrom: src)
        let outHandle = try FileHandle(forWritingTo: dst)
        defer {
            try? inHandle.close()
            try? outHandle.close()
        }

        if let peek = try inHandle.read(upToCount: 2), peek.count == 2 {
            let b0 = Int(peek[peek.startIndex])
            let b1 = Int(peek[peek.startIndex + 1])
            if !(b0 == 0x78 && (b0 * 256 + b1) % 31 == 0) {
                try inHandle.seek(toOffset: 0)
            }
        } else {
            try inHandle.seek(toOffset: 0)
        }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw NSError(domain: "GTA4", code: 2, userInfo: [NSLocalizedDescriptionKey: "Compression init failed"])
        }
        defer { compression_stream_destroy(streamPtr) }

        let dstCap = 262_144
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dstBuf.deallocate() }

        while true {
            let chunk = (try inHandle.read(upToCount: 262_144)) ?? Data()
            let isEOF = chunk.isEmpty
            let flags: Int32 = isEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            var finished = false
            try chunk.withUnsafeBytes { rawIn in
                streamPtr.pointee.src_ptr = rawIn.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dstBuf)
                streamPtr.pointee.src_size = chunk.count

                repeat {
                    streamPtr.pointee.dst_ptr = dstBuf
                    streamPtr.pointee.dst_size = dstCap
                    let status = compression_stream_process(streamPtr, flags)
                    let produced = dstCap - streamPtr.pointee.dst_size
                    if produced > 0 {
                        try outHandle.write(contentsOf: Data(bytes: dstBuf, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        finished = true
                        break
                    }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw NSError(domain: "GTA4", code: 3, userInfo: [NSLocalizedDescriptionKey: "Archive decompression error"])
                    }
                } while streamPtr.pointee.src_size > 0 || (isEOF && !finished)
            }
            if finished || isEOF { break }
        }
    }

    private func extractUSTar(tarURL: URL, into destRoot: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: tarURL)
        defer { try? handle.close() }
        let fm = FileManager.default
        let rootStd = destRoot.standardizedFileURL.path
        var extracted = 0

        func readExact(_ count: Int) throws -> Data {
            var out = Data()
            while out.count < count {
                guard let part = try handle.read(upToCount: count - out.count), !part.isEmpty else { break }
                out.append(part)
            }
            return out
        }

        func cString(_ slice: Data) -> String {
            if let nul = slice.firstIndex(of: 0) {
                return String(decoding: slice[slice.startIndex..<nul], as: UTF8.self)
            }
            return String(decoding: slice, as: UTF8.self)
        }

        while true {
            let header = try readExact(512)
            if header.count < 512 || header.allSatisfy({ $0 == 0 }) { break }

            let name = cString(header.subdata(in: 0..<100))
            let prefix = cString(header.subdata(in: 345..<500))
            let fullRel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let sizeStr = cString(header.subdata(in: 124..<136)).trimmingCharacters(in: .whitespaces)
            let fileSize = Int64(sizeStr, radix: 8) ?? 0
            let typeFlag = header[156]

            let targetURL = destRoot.appendingPathComponent(fullRel).standardizedFileURL
            guard targetURL.path.hasPrefix(rootStd) else {
                let skip = ((fileSize + 511) / 512) * 512
                if skip > 0 { try handle.seek(toOffset: (try handle.offset()) + UInt64(skip)) }
                continue
            }

            if typeFlag == 53 || fullRel.hasSuffix("/") {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if typeFlag == 0 || typeFlag == 48 {
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: targetURL.path, contents: nil)
                let out = try FileHandle(forWritingTo: targetURL)
                var rem = fileSize
                while rem > 0 {
                    let n = Int(min(262_144, rem))
                    let chunk = try readExact(n)
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                    rem -= Int64(chunk.count)
                }
                try out.close()
                extracted += 1
                let pad = Int(((fileSize + 511) / 512) * 512 - fileSize)
                if pad > 0 { _ = try readExact(pad) }
            } else {
                let skip = ((fileSize + 511) / 512) * 512
                if skip > 0 { try handle.seek(toOffset: (try handle.offset()) + UInt64(skip)) }
            }
        }
        return extracted
    }
}
