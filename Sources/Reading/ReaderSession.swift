import SwiftUI
import WebKit

/// Serves the bundled reader engine and the one open book from an app-only
/// scheme. Nothing else is reachable: no network, no other files.
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pocket-reader"
    static let bookPath = "/book.epub"
    static var entryURL: URL { URL(string: "\(scheme)://engine/reader.html")! }
    static var bookURL: URL { URL(string: "\(scheme)://engine\(bookPath)")! }

    private let engineRoot: URL?
    private let bookFile: URL
    private let lock = NSLock()
    private var stopped: Set<ObjectIdentifier> = []

    init(bookFile: URL, engineRoot: URL? = Bundle.main.url(forResource: "ReaderEngine", withExtension: nil)) {
        self.bookFile = bookFile
        self.engineRoot = engineRoot
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "engine" else {
            return task.didFailWithError(URLError(.unsupportedURL))
        }
        let file: URL
        if url.path == Self.bookPath {
            file = bookFile
        } else if let resolved = resolve(url.path) {
            file = resolved
        } else {
            return respond(task, url: url, status: 404, type: "text/plain", data: Data())
        }
        let type = Self.contentType(file.pathExtension)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard let self, !self.consumeStop(task) else { return }
                if let data { self.respond(task, url: url, status: 200, type: type, data: data) }
                else { self.respond(task, url: url, status: 404, type: "text/plain", data: Data()) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock()
    }

    private func consumeStop(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped.remove(ObjectIdentifier(task)) != nil
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Only regular files inside the bundled engine folder.
    func resolve(_ path: String) -> URL? {
        guard let engineRoot, !path.contains(".."), !path.contains("\\") else { return nil }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty else { return nil }
        let candidate = engineRoot.appendingPathComponent(relative).standardizedFileURL
        let root = engineRoot.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(root) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "epub": "application/epub+zip"
        default: "application/octet-stream"
        }
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ReaderSession?
    init(_ target: ReaderSession) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}

@MainActor
final class ReaderSession: NSObject, ObservableObject, WKNavigationDelegate {
    struct TOCItem: Identifiable, Hashable {
        let id: Int
        let label: String
        let href: String
        let depth: Int
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var toc: [TOCItem] = []
    @Published private(set) var position: ReadingPosition?
    @Published private(set) var locationLabel: String?
    /// Books open straight to the page; a tap in the middle shows the controls.
    @Published var chromeVisible = false

    let webView: WKWebView
    var onPosition: ((ReadingPosition) -> Void)?
    var onExternalLink: ((URL) -> Void)?
    var onEscape: (() -> Void)?

    private let handler: ReaderSchemeHandler
    private var engineReady = false
    private var pendingOpen: [String: Any]?
    private var appearance: ReaderAppearance
    private var insets: (top: Double, bottom: Double) = (0, 0)

    init(bookFile: URL, appearance: ReaderAppearance) {
        handler = ReaderSchemeHandler(bookFile: bookFile)
        self.appearance = appearance
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
#if os(iOS)
        configuration.dataDetectorTypes = []
#endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "pocket")
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
#if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
#else
        webView.setValue(false, forKey: "drawsBackground")
#endif
#if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = true }
#endif
        webView.load(URLRequest(url: ReaderSchemeHandler.entryURL))
    }

    func open(at position: ReadingPosition?) {
        var location: [String: Any] = [:]
        if let position {
            location["fraction"] = position.fraction
            if let cfi = position.cfi { location["cfi"] = cfi }
            if let xpointer = position.xpointer { location["xpointer"] = xpointer }
        }
        pendingOpen = [
            "url": ReaderSchemeHandler.bookURL.absoluteString,
            "location": location,
            "appearance": appearance.script(insetTop: insets.top, insetBottom: insets.bottom),
        ]
        flushOpen()
    }

    func next() { call("PocketReader.next()") }
    func previous() { call("PocketReader.prev()") }
    func goLeft() { call("PocketReader.goLeft()") }
    func goRight() { call("PocketReader.goRight()") }

    func go(to href: String) {
        call("PocketReader.goToHref(href)", ["href": href])
    }

    func go(toFraction fraction: Double) {
        call("PocketReader.goTo(target)", ["target": ["fraction": min(max(fraction, 0), 1)]])
    }

    /// Jumps to a position from another device: XPointer first, then progress.
    func go(to position: ReadingPosition) {
        var target: [String: Any] = ["fraction": position.fraction]
        if let xpointer = position.xpointer { target["xpointer"] = xpointer }
        if let cfi = position.cfi { target["cfi"] = cfi }
        call("PocketReader.goTo(target)", ["target": target])
    }

    func apply(_ appearance: ReaderAppearance) {
        self.appearance = appearance
        pushAppearance()
    }

    func setInsets(top: Double, bottom: Double) {
        guard insets.top != top || insets.bottom != bottom else { return }
        insets = (top, bottom)
        pushAppearance()
    }

    private func pushAppearance() {
        guard engineReady else { return }
        call("PocketReader.setAppearance(a)", ["a": appearance.script(insetTop: insets.top, insetBottom: insets.bottom)])
    }

    private func flushOpen() {
        guard engineReady, let options = pendingOpen else { return }
        pendingOpen = nil
        call("PocketReader.open(o)", ["o": options])
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:]) {
        guard engineReady else { return }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("Pocket reader script failed: %@", error.localizedDescription)
            }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            engineReady = true
            flushOpen()
        case "opened":
            let items = message["toc"] as? [[String: Any]] ?? []
            toc = items.enumerated().compactMap { index, item in
                guard let label = item["label"] as? String, let href = item["href"] as? String, !label.isEmpty else { return nil }
                return TOCItem(id: index, label: label, href: href, depth: item["depth"] as? Int ?? 0)
            }
            phase = .ready
        case "relocate":
            let reported = (message["fraction"] as? NSNumber)?.doubleValue ?? 0
            let fraction = reported.isFinite ? min(max(reported, 0), 1) : 0
            let next = ReadingPosition(fraction: fraction,
                                       xpointer: message["xpointer"] as? String,
                                       cfi: message["cfi"] as? String,
                                       chapter: message["chapter"] as? String,
                                       updatedAt: Date())
            position = next
            if let location = message["location"] as? [String: Any],
               let current = (location["current"] as? NSNumber)?.intValue,
               let total = (location["total"] as? NSNumber)?.intValue, total > 0 {
                locationLabel = "\(min(current + 1, total)) of \(total)"
            }
            onPosition?(next)
        case "tap":
            chromeVisible.toggle()
        case "escape":
            onEscape?()
        case "external-link":
            if let href = message["href"] as? String, let url = URL(string: href),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                onExternalLink?(url)
            }
        case "error":
            let detail = message["message"] as? String ?? ""
            if phase != .ready || message["stage"] as? String == "open" {
                phase = .failed(Self.describe(detail))
            } else {
                NSLog("Pocket reader error: %@", detail)
            }
        default:
            break
        }
    }

    static func describe(_ detail: String) -> String {
        let base = "This book could not be opened. It may be damaged or use a format the reader does not support."
        return detail.isEmpty ? base : "\(base) (\(detail.prefix(160)))"
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased()
        decisionHandler(scheme == ReaderSchemeHandler.scheme || scheme == "blob" || scheme == "about" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engineReady = false
        let restore = position
        phase = .loading
        webView.load(URLRequest(url: ReaderSchemeHandler.entryURL))
        open(at: restore)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        phase = .failed(Self.describe(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        phase = .failed(Self.describe(error.localizedDescription))
    }
}

#if os(iOS)
struct ReaderWebView: UIViewRepresentable {
    let session: ReaderSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct ReaderWebView: NSViewRepresentable {
    let session: ReaderSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
