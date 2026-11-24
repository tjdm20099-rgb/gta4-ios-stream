import UIKit
import WebKit

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class StreamViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private static let defaultServer = "204.12.199.24:4444"
    private static let hostPrefKey = "gta4_stream_server_host"

    private var webView: WKWebView!
    private let hostButton = UIButton(type: .system)
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    private var currentHost: String {
        get {
            let saved = UserDefaults.standard.string(forKey: Self.hostPrefKey) ?? ""
            return saved.isEmpty ? Self.defaultServer : saved
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hostPrefKey)
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        lightHaptic.prepare()
        mediumHaptic.prepare()
        heavyHaptic.prepare()

        let contentController = WKUserContentController()
        contentController.add(WeakScriptHandler(self), name: "gta4Native")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "GTA4StreamIOS/1.0"

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        view.addSubview(webView)

        setupHostPill()
        connectToStream()
    }

    private func setupHostPill() {
        hostButton.translatesAutoresizingMaskIntoConstraints = false
        hostButton.setTitle("⚙ Host", for: .normal)
        hostButton.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        hostButton.setTitleColor(UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 1.0), for: .normal)
        hostButton.backgroundColor = UIColor(white: 0.08, alpha: 0.78)
        hostButton.layer.cornerRadius = 6
        hostButton.layer.borderWidth = 1
        hostButton.layer.borderColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 0.45).cgColor
        hostButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        hostButton.addTarget(self, action: #selector(promptServerSettings), for: .touchUpInside)
        view.addSubview(hostButton)

        NSLayoutConstraint.activate([
            hostButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            hostButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 34)
        ])
    }

    private func normalizedStreamURL(for rawHost: String) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if trimmed.contains("/stream") {
                return URL(string: trimmed)
            }
            return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/stream.html")
        }
        return URL(string: "http://\(trimmed)/stream.html")
    }

    private func connectToStream() {
        guard let url = normalizedStreamURL(for: currentHost) else {
            showOfflineFallback(errorText: "Invalid host address: \(currentHost)")
            return
        }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        webView.load(req)
    }

    @objc private func promptServerSettings() {
        lightHaptic.impactOccurred()
        let alert = UIAlertController(
            title: "GTA IV Stream Host",
            message: "Streaming from your GTA IV host machine (default \(Self.defaultServer))",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.text = self.currentHost
            tf.placeholder = "204.12.199.24:4444"
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let self = self else { return }
            if let entered = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !entered.isEmpty {
                self.currentHost = entered
            }
            self.connectToStream()
        })
        alert.addAction(UIAlertAction(title: "Reset Default (\(Self.defaultServer))", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.currentHost = Self.defaultServer
            self.connectToStream()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "haptic" {
            let style = (body["style"] as? String) ?? "light"
            switch style {
            case "heavy": heavyHaptic.impactOccurred()
            case "medium": mediumHaptic.impactOccurred()
            default: lightHaptic.impactOccurred()
            }
        } else if type == "changeServer" {
            promptServerSettings()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOfflineFallback(errorText: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showOfflineFallback(errorText: error.localizedDescription)
    }

    // Accept the local GTA IV self-signed CA certificate when HTTPS mode is used
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func showOfflineFallback(errorText: String) {
        let escapedHost = currentHost.replacingOccurrences(of: "\"", with: "")
        let escapedErr = errorText.replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <style>
          body { margin:0; height:100vh; display:flex; align-items:center; justify-content:center;
                 background:#080a0f; color:#eee; font:15px -apple-system,system-ui,sans-serif; }
          .box { max-width:460px; padding:24px; background:#121620; border:1px solid #f0b030; border-radius:16px; text-align:center; }
          h2 { color:#f0b030; margin:0 0 8px; }
          p { color:#bbb; font-size:13.5px; }
          button { margin:8px 6px 0; padding:11px 18px; border-radius:10px; border:none; font-weight:700; font-size:14px; cursor:pointer; }
          .pri { background:#f0b030; color:#111; }
          .sec { background:#252d3d; color:#fff; border:1px solid #4a5568; }
        </style></head><body>
        <div class="box">
          <h2>GTA IV Stream (iOS)</h2>
          <p>Could not reach host <b>\(escapedHost)</b></p>
          <p style="color:#ff8a80;font-size:12px;">\(escapedErr)</p>
          <button class="pri" onclick="location.href='http://\(escapedHost)/stream.html'">Retry Stream</button>
          <button class="sec" onclick="window.webkit.messageHandlers.gta4Native.postMessage({type:'changeServer'})">Change IP / Port</button>
        </div>
        <script>setTimeout(() => { location.href = 'http://\(escapedHost)/stream.html'; }, 4000);</script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
