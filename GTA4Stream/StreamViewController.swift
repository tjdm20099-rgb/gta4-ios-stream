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
    private let menuButton = UIButton(type: .system)
    private let hubOverlay = UIView()
    private let statusLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let playDirectBtn = UIButton(type: .system)
    private let syncExtractedBtn = UIButton(type: .system)
    private let clearExtractedBtn = UIButton(type: .system)
    private let streamBtn = UIButton(type: .system)
    private let hostField = UITextField()

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private var lastBootLogLine: String = "starting"

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

        LocalGameServer.shared.remoteHostProvider = { [weak self] in
            self?.currentHost ?? Self.defaultServer
        }

        let contentController = WKUserContentController()
        contentController.add(WeakScriptHandler(self), name: "gta4Native")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "GTA4StreamIOS/2.2"

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

        setupFloatingMenuButton()
        setupHubOverlay()
        refreshHubState()
    }

    private func setupFloatingMenuButton() {
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.setTitle("⚙ GTA IV", for: .normal)
        menuButton.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        menuButton.setTitleColor(UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 1.0), for: .normal)
        menuButton.backgroundColor = UIColor(white: 0.08, alpha: 0.82)
        menuButton.layer.cornerRadius = 6
        menuButton.layer.borderWidth = 1
        menuButton.layer.borderColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 0.5).cgColor
        menuButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        menuButton.addTarget(self, action: #selector(toggleHub), for: .touchUpInside)
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 34)
        ])
    }

    private func makeButton(_ title: String, primary: Bool, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        styleActionButton(b, primary: primary, action: action)
        b.setTitle(title, for: .normal)
        return b
    }

    private func styleActionButton(_ b: UIButton, primary: Bool, action: Selector) {
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = UIFont.systemFont(ofSize: primary ? 14.5 : 12.5, weight: .bold)
        if primary {
            b.backgroundColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 1.0)
            b.setTitleColor(UIColor(white: 0.06, alpha: 1.0), for: .normal)
        } else {
            b.backgroundColor = UIColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1.0)
            b.setTitleColor(.white, for: .normal)
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 1.0, alpha: 0.22).cgColor
        }
        b.layer.cornerRadius = 10
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setupHubOverlay() {
        hubOverlay.translatesAutoresizingMaskIntoConstraints = false
        hubOverlay.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.96)
        view.addSubview(hubOverlay)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1.5
        card.layer.borderColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 0.65).cgColor
        hubOverlay.addSubview(card)

        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.text = "GRAND THEFT AUTO IV — DIRECT EXTRACTED-ISO PLAY"
        titleLbl.font = UIFont.systemFont(ofSize: 15.5, weight: .heavy)
        titleLbl.textColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 1.0)

        let closeBtn = UIButton(type: .system)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.setTitle("✕", for: .normal)
        closeBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        closeBtn.setTitleColor(.lightGray, for: .normal)
        closeBtn.addTarget(self, action: #selector(hideHub), for: .touchUpInside)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.86, alpha: 1.0)
        statusLabel.numberOfLines = 3

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = UIColor(red: 0.94, green: 0.69, blue: 0.19, alpha: 1.0)
        progressBar.trackTintColor = UIColor(white: 1.0, alpha: 0.15)
        progressBar.isHidden = true

        styleActionButton(playDirectBtn, primary: true, action: #selector(onPlayOrInstallTapped))
        playDirectBtn.setTitle("▶ Play Directly from Extracted ISO", for: .normal)

        styleActionButton(syncExtractedBtn, primary: false, action: #selector(onSyncExtractedTapped))
        styleActionButton(clearExtractedBtn, primary: false, action: #selector(onDeleteExtractedTapped))
        clearExtractedBtn.setTitleColor(UIColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1.0), for: .normal)

        styleActionButton(streamBtn, primary: false, action: #selector(onStreamModeTapped))
        streamBtn.setTitle("⚡ Stream Mode", for: .normal)

        let checkBtn = makeButton("🔍 Check", primary: false, action: #selector(onDeviceCheckTapped))
        let updateBtn = makeButton("↻ Sync Engine", primary: false, action: #selector(onForceReinstallTapped))

        hostField.translatesAutoresizingMaskIntoConstraints = false
        hostField.text = currentHost
        hostField.placeholder = "204.12.199.24:4444"
        hostField.font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        hostField.textColor = .white
        hostField.backgroundColor = UIColor(white: 0.04, alpha: 1.0)
        hostField.layer.cornerRadius = 8
        hostField.layer.borderWidth = 1
        hostField.layer.borderColor = UIColor(white: 1.0, alpha: 0.2).cgColor
        hostField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        hostField.leftViewMode = .always
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.keyboardType = .URL

        let extractedRow = UIStackView(arrangedSubviews: [syncExtractedBtn, clearExtractedBtn])
        extractedRow.translatesAutoresizingMaskIntoConstraints = false
        extractedRow.axis = .horizontal
        extractedRow.spacing = 8
        extractedRow.distribution = .fillProportionally

        let hostRow = UIStackView(arrangedSubviews: [hostField, streamBtn, checkBtn, updateBtn])
        hostRow.translatesAutoresizingMaskIntoConstraints = false
        hostRow.axis = .horizontal
        hostRow.spacing = 8
        hostRow.distribution = .fillProportionally

        card.addSubview(titleLbl)
        card.addSubview(closeBtn)
        card.addSubview(statusLabel)
        card.addSubview(progressBar)
        card.addSubview(playDirectBtn)
        card.addSubview(extractedRow)
        card.addSubview(hostRow)

        NSLayoutConstraint.activate([
            hubOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hubOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hubOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            hubOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: hubOverlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: hubOverlay.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 630),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: hubOverlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: hubOverlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            titleLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            closeBtn.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            statusLabel.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            progressBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            playDirectBtn.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            playDirectBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            playDirectBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            playDirectBtn.heightAnchor.constraint(equalToConstant: 44),

            extractedRow.topAnchor.constraint(equalTo: playDirectBtn.bottomAnchor, constant: 9),
            extractedRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            extractedRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            extractedRow.heightAnchor.constraint(equalToConstant: 38),

            hostRow.topAnchor.constraint(equalTo: extractedRow.bottomAnchor, constant: 9),
            hostRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            hostRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            hostRow.heightAnchor.constraint(equalToConstant: 36),
            hostRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func saveEnteredHost() {
        if let txt = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty {
            currentHost = txt
        }
        hostField.resignFirstResponder()
    }

    private func refreshHubState() {
        let inst = GameInstaller.shared
        inst.invalidateExtractedCache()
        let freeGB = Double(inst.freeDiskBytes()) / 1_073_741_824.0
        let localExt = inst.localExtractedSummary()

        if localExt.found {
            let gb = Double(localExt.totalBytes) / 1_073_741_824.0
            playDirectBtn.setTitle("▶ Play Directly (Local Extracted ISO Ready)", for: .normal)
            statusLabel.text = String(
                format: "✓ Extracted ISO found on this phone (%d files, %.2f GiB) — skips install & plays 100%% offline!",
                localExt.fileCount, gb
            )
            syncExtractedBtn.setTitle("✓ Extracted ISO On Phone (Re-Sync)", for: .normal)
            clearExtractedBtn.isHidden = false
            clearExtractedBtn.setTitle("🗑 Remove Copy", for: .normal)
        } else {
            playDirectBtn.setTitle(
                inst.isEngineInstalled
                    ? "▶ Play Directly (Mounts Extracted ISO)"
                    : "⬇ Setup Engine & Play Directly (Extracted ISO)",
                for: .normal
            )
            statusLabel.text = String(
                format: "Mounts extracted ISO directly from On My iPhone → GTA IV or %@ (no ISO install step · %.1f GiB free)",
                currentHost, freeGB
            )
            if inst.isSyncingExtracted {
                syncExtractedBtn.setTitle("⏸ Pause Extracted Sync", for: .normal)
                clearExtractedBtn.isHidden = true
            } else {
                syncExtractedBtn.setTitle("📂 Download Extracted ISO Folder to Phone (Offline Copy)", for: .normal)
                clearExtractedBtn.isHidden = true
            }
        }
    }

    @objc private func toggleHub() {
        lightHaptic.impactOccurred()
        hubOverlay.isHidden.toggle()
        if !hubOverlay.isHidden { refreshHubState() }
    }

    @objc private func hideHub() {
        saveEnteredHost()
        hubOverlay.isHidden = true
    }

    private func launchLocalEngine(path: String = "/index.html?localapp=1") {
        hubOverlay.isHidden = true
        let url = URL(string: "http://localhost:\(LocalGameServer.shared.port)\(path)")!
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    @objc private func onPlayOrInstallTapped() {
        saveEnteredHost()
        mediumHaptic.impactOccurred()
        if GameInstaller.shared.isEngineInstalled {
            launchLocalEngine()
            return
        }
        runEngineInstall(thenLaunchPath: "/index.html?localapp=1")
    }

    @objc private func onForceReinstallTapped() {
        saveEnteredHost()
        lightHaptic.impactOccurred()
        runEngineInstall(thenLaunchPath: nil)
    }

    @objc private func onDeviceCheckTapped() {
        saveEnteredHost()
        lightHaptic.impactOccurred()
        if GameInstaller.shared.isEngineInstalled {
            launchLocalEngine(path: "/check.html")
        } else {
            runEngineInstall(thenLaunchPath: "/check.html")
        }
    }

    private func runEngineInstall(thenLaunchPath: String?) {
        playDirectBtn.isEnabled = false
        progressBar.isHidden = false
        progressBar.progress = 0.02

        GameInstaller.shared.installEngineBundle(from: currentHost) { [weak self] msg, frac in
            DispatchQueue.main.async {
                self?.statusLabel.text = msg
                self?.progressBar.progress = Float(frac)
            }
        } completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.playDirectBtn.isEnabled = true
                switch result {
                case .success:
                    self.heavyHaptic.impactOccurred()
                    self.progressBar.isHidden = true
                    self.refreshHubState()
                    if let path = thenLaunchPath {
                        self.launchLocalEngine(path: path)
                    }
                case .failure(let err):
                    self.statusLabel.text = "Engine sync error: \(err.localizedDescription)"
                }
            }
        }
    }

    @objc private func onSyncExtractedTapped() {
        saveEnteredHost()
        lightHaptic.impactOccurred()
        let inst = GameInstaller.shared
        if inst.isSyncingExtracted {
            inst.cancelExtractedSync()
            progressBar.isHidden = true
            refreshHubState()
            return
        }
        progressBar.isHidden = false
        progressBar.progress = 0.01
        syncExtractedBtn.setTitle("⏸ Pause Extracted Sync", for: .normal)

        inst.syncExtractedFolderFromServer(host: currentHost) { [weak self] doneFiles, totalFiles, gotB, totalB in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let gGB = Double(gotB) / 1_073_741_824.0
                let tGB = Double(max(1, totalB)) / 1_073_741_824.0
                self.progressBar.progress = Float(Double(gotB) / Double(max(1, totalB)))
                self.statusLabel.text = String(
                    format: "Syncing Extracted ISO to Phone: %d / %d files (%.2f / %.2f GiB)",
                    doneFiles, totalFiles, gGB, tGB
                )
            }
        } completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressBar.isHidden = true
                self.refreshHubState()
                if case .failure(let err) = result, (err as NSError).code != NSURLErrorCancelled {
                    self.statusLabel.text = "Extracted sync note: \(err.localizedDescription)"
                } else if case .success(let count) = result {
                    self.heavyHaptic.impactOccurred()
                    self.statusLabel.text = "✓ Synced \(count) extracted GTA IV files to phone — ready to play offline!"
                }
            }
        }
    }

    @objc private func onDeleteExtractedTapped() {
        lightHaptic.impactOccurred()
        GameInstaller.shared.deleteLocalExtractedCopy()
        refreshHubState()
    }

    @objc private func onStreamModeTapped() {
        saveEnteredHost()
        lightHaptic.impactOccurred()
        let trimmed = currentHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            ? trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/stream.html"
            : "http://\(trimmed)/stream.html"
        guard let url = URL(string: urlStr) else { return }
        hubOverlay.isHidden = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
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
        } else if type == "bootLog" {
            if let txt = body["text"] as? String, !txt.isEmpty {
                lastBootLogLine = txt
            }
        } else if type == "changeServer" {
            hubOverlay.isHidden = false
            refreshHubState()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hubOverlay.isHidden = false
        statusLabel.text = "⚠️ iOS stopped the WebKit tab (RAM limit reached after: \(lastBootLogLine)). Tap Play to retry or use ⚡ Stream Mode."
    }

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
}
