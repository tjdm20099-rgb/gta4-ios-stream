import Foundation
import Compression

/// Downloads and installs the GTA IV WebAssembly/WebGPU engine + PS5 hub + TU8
/// from the host server (204.12.199.24:4444) into persistent phone storage, and
/// optionally downloads the full 7.3 GB GTA IV .iso disc image with HTTP Range resume.
final class GameInstaller {
    static let shared = GameInstaller()

    let baseSupportDir: URL
    let documentsDir: URL
    let isoDir: URL

    private var isoDownloadTask: URLSessionDataTask?
    private var isoSession: URLSession?
    private(set) var isDownloadingISO = false

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseSupportDir = appSupport.appendingPathComponent("GTA4Local", isDirectory: true)
        documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        isoDir = documentsDir.appendingPathComponent("GTA4Local/iso", isDirectory: true)

        try? fm.createDirectory(at: baseSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: isoDir, withIntermediateDirectories: true)

        var resValues = URLResourceValues()
        resValues.isExcludedFromBackup = true
        var mutableBase = baseSupportDir
        try? mutableBase.setResourceValues(resValues)
        var mutableISO = documentsDir.appendingPathComponent("GTA4Local", isDirectory: true)
        try? mutableISO.setResourceValues(resValues)
    }

    var isEngineInstalled: Bool {
        let wasmPath = baseSupportDir.appendingPathComponent("site/gta4.wasm").path
        return FileManager.default.fileExists(atPath: wasmPath)
    }

    func resolvedLocalISOURL() -> URL? {
        let fm = FileManager.default
        let managed = isoDir.appendingPathComponent("gta4.iso")
        if let attrs = try? fm.attributesOfItem(atPath: managed.path),
           let sz = attrs[.size] as? NSNumber, sz.int64Value > 100 * 1024 * 1024 {
            return managed
        }
        // Also support any .iso placed directly into the iOS Files "On My iPhone -> GTA IV" folder!
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
        let candidates = [
            isoDir.appendingPathComponent("tu8"),
            baseSupportDir.appendingPathComponent("iso/tu8")
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    func localISOBytes() -> Int64 {
        if let url = resolvedLocalISOURL(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sz = attrs[.size] as? NSNumber {
            return sz.int64Value
        }
        let part = isoDir.appendingPathComponent("gta4.iso.part")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: part.path),
           let sz = attrs[.size] as? NSNumber {
            return -sz.int64Value // Negative indicates partial resumable download
        }
        return 0
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

    func deleteLocalISO() {
        cancelISODownload()
        let fm = FileManager.default
        try? fm.removeItem(at: isoDir.appendingPathComponent("gta4.iso"))
        try? fm.removeItem(at: isoDir.appendingPathComponent("gta4.iso.part"))
    }

    // MARK: - Engine Bundle Download + Deflate Decompress + Tar Extract

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

        progress("Connecting to \(host) to prepare GTA IV Engine Pack…", 0.02)

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
                        progress("Installing engine, shaders, PS5 hub & TU8 to phone…", 0.90)
                        let count = try self.extractUSTar(tarURL: tarURL, into: self.baseSupportDir)
                        progress("Installed \(count) GTA IV files on phone!", 1.0)
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

        // Check for optional 2-byte RFC 1950 zlib header just in case
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
                streamPtr.pointee.src_ptr = rawIn.bindMemory(to: UInt8.self).baseAddress ?? dstBuf
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

            if typeFlag == 53 || fullRel.hasSuffix("/") { // '5' = directory
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if typeFlag == 0 || typeFlag == 48 { // '\0' or '0' = regular file
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

    // MARK: - Resumable 7.3 GB GTA IV Disc (.iso) Downloader

    func cancelISODownload() {
        isoDownloadTask?.cancel()
        isoDownloadTask = nil
        isoSession?.invalidateAndCancel()
        isoSession = nil
        isDownloadingISO = false
    }

    func downloadDiscISO(
        from rawHost: String,
        progress: @escaping (_ got: Int64, _ total: Int64, _ mbPerSec: Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if isDownloadingISO { return }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (host.hasPrefix("http://") || host.hasPrefix("https://")) ? host : "http://\(host)"
        guard let isoURL = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/iso/gta4.iso") else {
            completion(.failure(NSError(domain: "GTA4", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])))
            return
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: isoDir, withIntermediateDirectories: true)
        let partURL = isoDir.appendingPathComponent("gta4.iso.part")
        let finalURL = isoDir.appendingPathComponent("gta4.iso")

        var existing: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let sz = attrs[.size] as? NSNumber {
            existing = sz.int64Value
        } else {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        var req = URLRequest(url: isoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        if existing > 0 {
            req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        final class ISODelegate: NSObject, URLSessionDataDelegate {
            let partURL: URL
            let finalURL: URL
            var handle: FileHandle?
            var written: Int64
            var expectedTotal: Int64 = 7_835_492_352
            let startTime = Date()
            let startBytes: Int64
            var lastUIUpdate = Date.distantPast
            let onProgress: (Int64, Int64, Double) -> Void
            let onDone: (Result<Void, Error>) -> Void

            init(
                partURL: URL,
                finalURL: URL,
                existing: Int64,
                onProgress: @escaping (Int64, Int64, Double) -> Void,
                onDone: @escaping (Result<Void, Error>) -> Void
            ) {
                self.partURL = partURL
                self.finalURL = finalURL
                self.written = existing
                self.startBytes = existing
                self.onProgress = onProgress
                self.onDone = onDone
            }

            func urlSession(
                _ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
            ) {
                guard let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 206) else {
                    completionHandler(.cancel)
                    onDone(.failure(NSError(domain: "GTA4", code: 11, userInfo: [
                        NSLocalizedDescriptionKey: "GTA IV .iso not ready on server yet"
                    ])))
                    return
                }
                do {
                    if http.statusCode == 200 {
                        FileManager.default.createFile(atPath: partURL.path, contents: nil)
                        written = 0
                        expectedTotal = http.expectedContentLength > 0 ? http.expectedContentLength : expectedTotal
                    } else if http.expectedContentLength > 0 {
                        expectedTotal = written + http.expectedContentLength
                    }
                    let fh = try FileHandle(forWritingTo: partURL)
                    try fh.seekToEnd()
                    handle = fh
                    completionHandler(.allow)
                } catch {
                    completionHandler(.cancel)
                    onDone(.failure(error))
                }
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                do {
                    try handle?.write(contentsOf: data)
                    written += Int64(data.count)
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) >= 0.2 {
                        lastUIUpdate = now
                        let elapsed = max(0.1, now.timeIntervalSince(startTime))
                        let speed = Double(written - startBytes) / 1_048_576.0 / elapsed
                        onProgress(written, expectedTotal, max(0, speed))
                    }
                } catch {
                    dataTask.cancel()
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                try? handle?.close()
                handle = nil
                if let error = error {
                    onDone(.failure(error))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: partURL, to: finalURL)
                    onDone(.success(()))
                } catch {
                    onDone(.failure(error))
                }
            }
        }

        isDownloadingISO = true
        let del = ISODelegate(partURL: partURL, finalURL: finalURL, existing: existing, onProgress: progress) { [weak self] res in
            self?.isDownloadingISO = false
            completion(res)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: cfg, delegate: del, delegateQueue: nil)
        isoSession = session
        let task = session.dataTask(with: req)
        isoDownloadTask = task
        task.resume()
    }
}
