import UIKit
import WebKit

final class RootViewController: UIViewController {
    private let schemeHandler: AppSchemeHandler
    private let contentView = UIView()
    private let topBar = UIView()
    private let buttonStackView = UIStackView()
    private let webView: WKWebView
    private let downloadProgressContainerView = UIView()
    private let downloadProgressLabel = UILabel()
    private let downloadProgressView = UIProgressView(progressViewStyle: .default)
    private var remoteUpdateTask: Task<Void, Never>?
    private var downloadProgressHideWorkItem: DispatchWorkItem?
    private var isCheckingForUpdate = false {
        didSet {
            updateButton.isEnabled = !isCheckingForUpdate
        }
    }
    private lazy var backButton = makeButton(title: "后退", systemImageName: "chevron.backward", action: #selector(handleBack))
    private lazy var forwardButton = makeButton(title: "前进", systemImageName: "chevron.forward", action: #selector(handleForward))
    private lazy var refreshButton = makeButton(title: "刷新", systemImageName: "arrow.clockwise", action: #selector(handleRefresh))
    private lazy var updateButton = makeButton(title: "更新", systemImageName: "arrow.down.circle", action: #selector(handleUpdate))
    private lazy var exitButton = makeButton(title: "退出", systemImageName: "xmark", action: #selector(handleExit))

    init() {
        let schemeHandler = AppSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.schemeHandler = schemeHandler
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = contentView
        configureLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .systemBackground

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        updateNavigationButtons()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDownloadProgressNotification(_:)),
            name: .webAppDownloadProgressDidChange,
            object: WebAppManager.shared
        )

        loadLocalApp()
    }

    deinit {
        remoteUpdateTask?.cancel()
        downloadProgressHideWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLayout() {
        contentView.backgroundColor = .systemBackground

        topBar.backgroundColor = .black
        topBar.translatesAutoresizingMaskIntoConstraints = false

        buttonStackView.axis = .horizontal
        buttonStackView.alignment = .fill
        buttonStackView.distribution = .fillEqually
        buttonStackView.spacing = 6
        buttonStackView.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressContainerView.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressView.translatesAutoresizingMaskIntoConstraints = false

        downloadProgressContainerView.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        downloadProgressContainerView.layer.cornerRadius = 12
        downloadProgressContainerView.clipsToBounds = true
        downloadProgressContainerView.isHidden = true

        downloadProgressLabel.font = .systemFont(ofSize: 13, weight: .medium)
        downloadProgressLabel.textColor = .white
        downloadProgressLabel.numberOfLines = 2

        downloadProgressView.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        downloadProgressView.progressTintColor = UIColor.systemGreen

        contentView.addSubview(topBar)
        contentView.addSubview(webView)
        contentView.addSubview(downloadProgressContainerView)
        topBar.addSubview(buttonStackView)
        downloadProgressContainerView.addSubview(downloadProgressLabel)
        downloadProgressContainerView.addSubview(downloadProgressView)

        [backButton, forwardButton, refreshButton, updateButton, exitButton].forEach {
            buttonStackView.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            buttonStackView.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 6),
            buttonStackView.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            buttonStackView.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            buttonStackView.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            downloadProgressContainerView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            downloadProgressContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            downloadProgressContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            downloadProgressLabel.topAnchor.constraint(equalTo: downloadProgressContainerView.topAnchor, constant: 12),
            downloadProgressLabel.leadingAnchor.constraint(equalTo: downloadProgressContainerView.leadingAnchor, constant: 12),
            downloadProgressLabel.trailingAnchor.constraint(equalTo: downloadProgressContainerView.trailingAnchor, constant: -12),

            downloadProgressView.topAnchor.constraint(equalTo: downloadProgressLabel.bottomAnchor, constant: 10),
            downloadProgressView.leadingAnchor.constraint(equalTo: downloadProgressContainerView.leadingAnchor, constant: 12),
            downloadProgressView.trailingAnchor.constraint(equalTo: downloadProgressContainerView.trailingAnchor, constant: -12),
            downloadProgressView.bottomAnchor.constraint(equalTo: downloadProgressContainerView.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, systemImageName: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImageName)
        configuration.imagePadding = 4
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 9.6, weight: .medium)
            return outgoing
        }

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.titleLabel?.lineBreakMode = .byClipping
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor(white: 1.0, alpha: 0.45), for: .disabled)
        button.tintColor = .white
        button.configurationUpdateHandler = { updatedButton in
            guard var updatedConfiguration = updatedButton.configuration else { return }
            let foregroundColor = UIColor.white.withAlphaComponent(updatedButton.isEnabled ? 1.0 : 0.45)
            updatedConfiguration.baseForegroundColor = foregroundColor
            updatedConfiguration.imageColorTransformer = UIConfigurationColorTransformer { _ in foregroundColor }
            updatedConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 9.6, weight: .medium)
                outgoing.foregroundColor = foregroundColor
                return outgoing
            }
            updatedButton.configuration = updatedConfiguration
            updatedButton.tintColor = foregroundColor
            updatedButton.setTitleColor(foregroundColor, for: updatedButton.isEnabled ? .normal : .disabled)
            updatedButton.titleLabel?.textColor = foregroundColor
        }
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func loadLocalApp() {
        guard let url = URL(string: "\(AppSchemeHandler.scheme)://localhost/") else {
            presentFallback(message: "无法创建本地入口地址。")
            return
        }

        loadWebViewURL(url)
    }

    private func loadWebViewURL(_ url: URL) {
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        webView.load(request)
    }

    private func startRemoteUpdateCheck(userInitiated: Bool = false) {
        remoteUpdateTask?.cancel()
        isCheckingForUpdate = true
        remoteUpdateTask = Task { [weak self] in
            let outcome = await WebAppManager.shared.refreshFromRemoteIfNeeded(force: userInitiated)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.isCheckingForUpdate = false

                switch outcome {
                case .alreadyCurrent:
                    if userInitiated {
                        self.presentStatusAlert(title: "检查完成", message: "当前已经是最新版本。")
                    }
                case .installed:
                    self.reloadCurrentPageAfterUpdate()
                    if userInitiated {
                        self.presentStatusAlert(title: "更新成功", message: "最新前端资源已经下载并重新加载。")
                    }
                case .failed(let error):
                    if userInitiated {
                        self.presentStatusAlert(title: "更新失败", message: error.localizedDescription)
                    } else {
                        print("WebApp update skipped: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func reloadCurrentPageAfterUpdate() {
        if let currentURL = webView.url {
            loadWebViewURL(currentURL)
        } else {
            loadLocalApp()
        }
    }

    private func presentStatusAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func presentFallback(message: String) {
        let escapedMessage = Self.htmlEscaped(message)
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>IoTCenter</title>
          <style>
            :root {
              color-scheme: light;
              font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
            }
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: linear-gradient(180deg, #f6f9fc 0%, #ebf2f7 100%);
              color: #15324b;
            }
            main {
              width: min(520px, calc(100vw - 32px));
              padding: 28px;
              border-radius: 20px;
              background: rgba(255, 255, 255, 0.92);
              box-shadow: 0 18px 48px rgba(29, 58, 88, 0.12);
            }
            h1 {
              margin: 0 0 12px;
              font-size: 28px;
            }
            p {
              margin: 0 0 12px;
              line-height: 1.65;
            }
            code {
              padding: 2px 6px;
              border-radius: 8px;
              background: #edf3f8;
              font-size: 0.95em;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>本地前端还没有准备好</h1>
            <p>App 会优先加载已下载的前端更新，没有可用更新时再回退到包内资源。</p>
            <p>请确认包内或远端资源中存在可访问的 <code>www/index.html</code>。</p>
            <p>当前错误：\(escapedMessage)</p>
          </main>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    @objc
    private func handleBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    @objc
    private func handleForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    @objc
    private func handleRefresh() {
        if let currentURL = webView.url {
            loadWebViewURL(currentURL)
        } else {
            loadLocalApp()
        }
    }

    @objc
    private func handleUpdate() {
        guard !isCheckingForUpdate else { return }
        startRemoteUpdateCheck(userInitiated: true)
    }

    @objc
    private func handleExit() {
        let alert = UIAlertController(
            title: "关闭应用",
            message: "确认关闭当前应用？",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in
            self.terminateApplication()
        })

        present(alert, animated: true)
    }

    private func terminateApplication() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exit(0)
        }
    }

    @objc
    private func handleDownloadProgressNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let rawState = userInfo[WebAppManager.DownloadProgressUserInfoKey.state] as? String,
            let state = WebAppManager.DownloadProgressState(rawValue: rawState)
        else {
            return
        }

        let receivedBytes = userInfo[WebAppManager.DownloadProgressUserInfoKey.receivedBytes] as? Int64
        let totalBytes = userInfo[WebAppManager.DownloadProgressUserInfoKey.totalBytes] as? Int64
        let message = userInfo[WebAppManager.DownloadProgressUserInfoKey.message] as? String

        updateDownloadProgressUI(
            state: state,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            message: message
        )
    }

    private func updateDownloadProgressUI(
        state: WebAppManager.DownloadProgressState,
        receivedBytes: Int64?,
        totalBytes: Int64?,
        message: String?
    ) {
        downloadProgressHideWorkItem?.cancel()

        switch state {
        case .idle:
            hideDownloadProgress(animated: true)
        case .downloading:
            let progress = normalizedProgress(receivedBytes: receivedBytes, totalBytes: totalBytes)
            downloadProgressContainerView.alpha = 1
            downloadProgressContainerView.isHidden = false
            downloadProgressView.setProgress(progress, animated: true)
            downloadProgressLabel.text = downloadProgressText(
                prefix: "正在下载更新",
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                progress: progress
            )
        case .installing:
            downloadProgressContainerView.alpha = 1
            downloadProgressContainerView.isHidden = false
            downloadProgressView.setProgress(1.0, animated: true)
            downloadProgressLabel.text = "下载完成，正在安装更新…"
        case .completed:
            downloadProgressContainerView.alpha = 1
            downloadProgressContainerView.isHidden = false
            downloadProgressView.setProgress(1.0, animated: true)
            downloadProgressLabel.text = "更新下载完成"
            hideDownloadProgress(animated: true, delay: 1.2)
        case .failed:
            downloadProgressContainerView.alpha = 1
            downloadProgressContainerView.isHidden = false
            downloadProgressView.setProgress(0, animated: false)
            downloadProgressLabel.text = "下载失败\(message.map { "：\($0)" } ?? "")"
            hideDownloadProgress(animated: true, delay: 2.5)
        }
    }

    private func normalizedProgress(receivedBytes: Int64?, totalBytes: Int64?) -> Float {
        guard let receivedBytes, let totalBytes, totalBytes > 0 else {
            return 0
        }

        let progress = Double(receivedBytes) / Double(totalBytes)
        return Float(max(0, min(progress, 1)))
    }

    private func downloadProgressText(
        prefix: String,
        receivedBytes: Int64?,
        totalBytes: Int64?,
        progress: Float
    ) -> String {
        guard let receivedBytes, let totalBytes, totalBytes > 0 else {
            return "\(prefix)…"
        }

        let percent = Int((progress * 100).rounded())
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true

        let receivedText = formatter.string(fromByteCount: receivedBytes)
        let totalText = formatter.string(fromByteCount: totalBytes)
        return "\(prefix) \(percent)% (\(receivedText) / \(totalText))"
    }

    private func hideDownloadProgress(animated: Bool, delay: TimeInterval = 0) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            if animated {
                UIView.animate(withDuration: 0.2, animations: {
                    self.downloadProgressContainerView.alpha = 0
                }, completion: { _ in
                    self.downloadProgressContainerView.isHidden = true
                    self.downloadProgressContainerView.alpha = 1
                })
            } else {
                self.downloadProgressContainerView.isHidden = true
                self.downloadProgressContainerView.alpha = 1
            }
        }

        downloadProgressHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

}

extension RootViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavigationButtons()
        presentFallback(message: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateNavigationButtons()
        presentFallback(message: error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard
            let url = navigationAction.request.url,
            navigationAction.navigationType == .linkActivated,
            navigationAction.targetFrame?.isMainFrame == true
        else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        updateNavigationButtons()
        decisionHandler(.allow)
    }
}

extension RootViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }

        return nil
    }
}
