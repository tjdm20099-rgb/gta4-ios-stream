import Foundation
import Darwin

/// Embedded on-device HTTP/1.1 server on localhost:14444 (both 127.0.0.1 and ::1)
/// Serves the installed GTA IV WebAssembly/WebGPU engine + PS5 hub assets with
/// COOP/COEP Cross-Origin Isolation headers so SharedArrayBuffer, memory64,
/// WebGPU, and persistent OPFS storage run directly on the iPhone/iPad.
/// Serves /iso/gta4.iso & /iso/tu8 from local phone storage when downloaded, or
/// seamlessly streams byte-ranges from the remote server during installation.
final class LocalGameServer {
    static let shared = LocalGameServer()
    let port: UInt16 = 14444

    var remoteHostProvider: () -> String = { "204.12.199.24:4444" }
    private var running = false
    private let lock = NSLock()

    private let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "wasm": "application/wasm",
        "json": "application/json; charset=utf-8",
        "wgsl": "text/plain; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "otf": "font/otf",
        "ttf": "font/ttf"
    ]

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        startIPv4Loopback()
        startIPv6Loopback()
    }

    private func configureSocket(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startIPv4Loopback() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        configureSocket(fd)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            Darwin.close(fd)
            return
        }
        acceptLoop(serverFD: fd)
    }

    private func startIPv6Loopback() {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        configureSocket(fd)
        var v6Only: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))

        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = port.bigEndian
        addr6.sin6_addr = in6addr_loopback

        let bound = withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            Darwin.close(fd)
            return
        }
        acceptLoop(serverFD: fd)
    }

    private func acceptLoop(serverFD: Int32) {
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                let client = Darwin.accept(serverFD, nil, nil)
                if client < 0 { continue }
                self.configureSocket(client)
                var noDelay: Int32 = 1
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(client)
                }
            }
        }
    }

    private func readHeaders(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let marker = Data([13, 10, 13, 10]) // \r\n\r\n
        while data.count < 32768 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.range(of: marker) != nil { break }
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func commonHeaders(contentType: String, contentLength: Int64, extra: [String] = []) -> String {
        var lines = [
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: bytes",
            "Cross-Origin-Opener-Policy: same-origin",
            "Cross-Origin-Embedder-Policy: require-corp",
            "Cross-Origin-Resource-Policy: same-origin",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        lines.append(contentsOf: extra)
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func sendSimple(_ fd: Int32, status: String, contentType: String = "text/plain; charset=utf-8", body: Data, headOnly: Bool) {
        let head = "HTTP/1.1 \(status)\r\n" + commonHeaders(contentType: contentType, contentLength: Int64(body.count))
        if writeAll(fd, Data(head.utf8)), !headOnly, !body.isEmpty {
            _ = writeAll(fd, body)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let rawReq = readHeaders(fd) else { return }
        let lines = rawReq.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let cleanPath = (rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/")
            .removingPercentEncoding ?? "/"
        let headOnly = (method == "HEAD")

        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }

        if method == "OPTIONS" {
            sendSimple(fd, status: "204 No Content", body: Data(), headOnly: true)
            return
        }
        if method == "POST" {
            sendSimple(fd, status: "204 No Content", body: Data(), headOnly: true)
            return
        }

        // Virtual host endpoints used by gta4.wasm & index.html
        if cleanPath == "/host/info" {
            sendSimple(fd, status: "200 OK", body: Data("install\t~/GTA4Local/install/\n".utf8), headOnly: headOnly)
            return
        }
        if cleanPath == "/host/free" {
            let free = GameInstaller.shared.freeDiskBytes()
            sendSimple(fd, status: "200 OK", body: Data("\(free)\n".utf8), headOnly: headOnly)
            return
        }
        if cleanPath == "/host/list/install" {
            sendSimple(fd, status: "200 OK", body: Data("\n".utf8), headOnly: headOnly)
            return
        }
        if cleanPath == "/api/status" {
            let json = """
            {"type":"status","ip":"localhost","port":\(port),"isoReady":true,"tu8Ready":true,"hostConnected":true,"ipaAvailable":true}
            """
            sendSimple(fd, status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(json.utf8), headOnly: headOnly)
            return
        }

        // Disc / Title Update / AES Key resolution (local storage first, remote server fallback!)
        if cleanPath == "/iso/gta4.iso" {
            if let localISO = GameInstaller.shared.resolvedLocalISOURL() {
                serveLocalFile(fd, fileURL: localISO, rangeHeader: rangeHeader, headOnly: headOnly)
            } else {
                proxyFromRemote(fd, remotePath: "/iso/gta4.iso", rangeHeader: rangeHeader, headOnly: headOnly)
            }
            return
        }
        if cleanPath == "/iso/tu8" {
            if let localTU8 = GameInstaller.shared.resolvedLocalTU8URL() {
                serveLocalFile(fd, fileURL: localTU8, rangeHeader: rangeHeader, headOnly: headOnly)
            } else {
                proxyFromRemote(fd, remotePath: "/iso/tu8", rangeHeader: rangeHeader, headOnly: headOnly)
            }
            return
        }
        if cleanPath == "/iso/aes_key" {
            let keyURL = GameInstaller.shared.baseSupportDir.appendingPathComponent("iso/aes_key")
            if FileManager.default.fileExists(atPath: keyURL.path) {
                serveLocalFile(fd, fileURL: keyURL, rangeHeader: rangeHeader, headOnly: headOnly)
            } else {
                proxyFromRemote(fd, remotePath: "/iso/aes_key", rangeHeader: rangeHeader, headOnly: headOnly)
            }
            return
        }

        // Static engine & PS5 hub files
        let base = GameInstaller.shared.baseSupportDir
        let fileURL: URL
        if cleanPath.hasPrefix("/app0/hub/") {
            let sub = String(cleanPath.dropFirst("/app0/hub/".count))
            fileURL = base.appendingPathComponent("ps5/package/hub").appendingPathComponent(sub)
        } else if cleanPath.hasPrefix("/app0/fonts/") {
            let sub = String(cleanPath.dropFirst("/app0/fonts/".count))
            fileURL = base.appendingPathComponent("ps5/assets/fonts").appendingPathComponent(sub)
        } else {
            let rel = (cleanPath == "/" ? "index.html" : String(cleanPath.dropFirst()))
            fileURL = base.appendingPathComponent("site").appendingPathComponent(rel)
        }

        let standardized = fileURL.standardizedFileURL
        guard standardized.path.hasPrefix(base.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: standardized.path) else {
            sendSimple(fd, status: "404 Not Found", body: Data("Not Found".utf8), headOnly: headOnly)
            return
        }
        serveLocalFile(fd, fileURL: standardized, rangeHeader: rangeHeader, headOnly: headOnly)
    }

    private func parseByteRange(_ header: String?, totalSize: Int64) -> (Int64, Int64)? {
        guard let h = header, h.hasPrefix("bytes="), totalSize > 0 else { return nil }
        let spec = String(h.dropFirst(6))
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let startStr = String(pieces[0])
        let endStr = String(pieces[1])
        var start: Int64 = 0
        var end: Int64 = totalSize - 1
        if !startStr.isEmpty {
            guard let s = Int64(startStr) else { return nil }
            start = s
            if !endStr.isEmpty, let e = Int64(endStr) { end = min(e, totalSize - 1) }
        } else if !endStr.isEmpty, let suffix = Int64(endStr) {
            start = max(0, totalSize - suffix)
        } else {
            return nil
        }
        guard start <= end, start < totalSize else { return (-1, -1) }
        return (start, end)
    }

    private func serveLocalFile(_ fd: Int32, fileURL: URL, rangeHeader: String?, headOnly: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let numSize = attrs[.size] as? NSNumber else {
            sendSimple(fd, status: "404 Not Found", body: Data(), headOnly: true)
            return
        }
        let total = numSize.int64Value
        let ext = fileURL.pathExtension.lowercased()
        let ctype = mimeTypes[ext] ?? "application/octet-stream"

        var start: Int64 = 0
        var end: Int64 = max(0, total - 1)
        var status = "200 OK"
        var extra: [String] = []

        if let r = parseByteRange(rangeHeader, totalSize: total) {
            if r.0 < 0 {
                let hdr = "HTTP/1.1 416 Range Not Satisfiable\r\n" +
                    commonHeaders(contentType: ctype, contentLength: 0, extra: ["Content-Range: bytes */\(total)"])
                _ = writeAll(fd, Data(hdr.utf8))
                return
            }
            start = r.0
            end = r.1
            status = "206 Partial Content"
            extra.append("Content-Range: bytes \(start)-\(end)/\(total)")
        }

        let length = total == 0 ? 0 : (end - start + 1)
        let headerText = "HTTP/1.1 \(status)\r\n" + commonHeaders(contentType: ctype, contentLength: length, extra: extra)
        guard writeAll(fd, Data(headerText.utf8)), !headOnly, length > 0 else { return }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            var remaining = length
            while remaining > 0 {
                let toRead = Int(min(262144, remaining))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                if !writeAll(fd, chunk) { break }
                remaining -= Int64(chunk.count)
            }
        } catch {}
    }

    private func proxyFromRemote(_ fd: Int32, remotePath: String, rangeHeader: String?, headOnly: Bool) {
        let host = remoteHostProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (host.hasPrefix("http://") || host.hasPrefix("https://")) ? host : "http://\(host)"
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + remotePath) else {
            sendSimple(fd, status: "502 Bad Gateway", body: Data("Invalid remote host".utf8), headOnly: headOnly)
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = headOnly ? "HEAD" : "GET"
        if let r = rangeHeader {
            req.setValue(r, forHTTPHeaderField: "Range")
        }

        let sem = DispatchSemaphore(value: 0)
        var sentHeaders = false

        final class StreamForwarder: NSObject, URLSessionDataDelegate {
            let fd: Int32
            let headOnly: Bool
            let server: LocalGameServer
            let sem: DispatchSemaphore
            var headerSent = false

            init(fd: Int32, headOnly: Bool, server: LocalGameServer, sem: DispatchSemaphore) {
                self.fd = fd
                self.headOnly = headOnly
                self.server = server
                self.sem = sem
            }

            func urlSession(
                _ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
            ) {
                guard let http = response as? HTTPURLResponse else {
                    completionHandler(.cancel)
                    return
                }
                let code = http.statusCode
                let statusLine = code == 206 ? "206 Partial Content" : (code == 200 ? "200 OK" : "\(code) Response")
                let len = http.expectedContentLength >= 0 ? http.expectedContentLength : 0
                var extra: [String] = []
                if let cr = http.value(forHTTPHeaderField: "Content-Range") {
                    extra.append("Content-Range: \(cr)")
                }
                let hdr = "HTTP/1.1 \(statusLine)\r\n" +
                    server.commonHeaders(contentType: "application/octet-stream", contentLength: len, extra: extra)
                headerSent = true
                if !server.writeAll(fd, Data(hdr.utf8)) || headOnly {
                    completionHandler(.cancel)
                } else {
                    completionHandler(.allow)
                }
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                if !server.writeAll(fd, data) {
                    dataTask.cancel()
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if !headerSent {
                    server.sendSimple(fd, status: "502 Bad Gateway", body: Data("Server unreachable".utf8), headOnly: headOnly)
                }
                sem.signal()
            }
        }

        let delegate = StreamForwarder(fd: fd, headOnly: headOnly, server: self, sem: sem)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: req)
        task.resume()
        _ = sem.wait(timeout: .now() + 300)
        _ = sentHeaders
        session.finishTasksAndInvalidate()
    }
}
