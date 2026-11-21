import AppKit
import CryptoKit
import SwiftUI
import WebKit

enum RecapNavigation: Equatable {
    case allow, openInBrowser, deny

    static func decide(url: URL, instance: URL, isMainFrame: Bool, isDownload: Bool) -> RecapNavigation {
        if isDownload { return .openInBrowser }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .deny }
        return isMainFrame && origin(url) == origin(instance) ? .allow : .openInBrowser
    }

    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
        return "\(scheme)://\(url.host?.lowercased() ?? "")" + (port.map { ":\($0)" } ?? "")
    }
}

enum RecapScreen: Equatable {
    case loading, slow, offline, insecure, page
}

/// The one Minutia window that shows a meeting's web page, signed in with a one-time handoff into a
/// web data store of its own per server and account. The Mac's own session never enters it.
@MainActor
final class RecapWindowController: NSObject, ObservableObject {
    typealias Account = (client: MinutiaClient, userId: String?)

    @Published private(set) var screen = RecapScreen.loading
    @Published private(set) var title = ""
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    private var overlay: NSView?

    private let account: () async -> Account?
    private let openURL: (URL) -> Void
    private let copy: (String) -> Void
    private let clock: ReviewClock
    private let presence: WindowPresence
    private let onSignedOut: () -> Void
    private var current: (meetingId: UUID, page: URL, next: String, client: MinutiaClient)?
    private var handoffTried = false
    private var handoff: Task<Void, Never>?
    private var slow: Task<Void, Never>?

    private static let presenceId = "recap"
    private static let frameName = "MinutiaRecap"
    private static let offline: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ]

    init(
        account: @escaping () async -> Account?,
        openURL: @escaping (URL) -> Void,
        copy: @escaping (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        },
        clock: ReviewClock = .live,
        presence: WindowPresence = .shared,
        onSignedOut: @escaping () -> Void = {}
    ) {
        self.account = account
        self.openURL = openURL
        self.copy = copy
        self.clock = clock
        self.presence = presence
        self.onSignedOut = onSignedOut
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    static func storeIdentifier(instance: URL, userId: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(RecapNavigation.origin(instance))|\(userId.lowercased())".utf8)))
        return NSUUID(uuidBytes: digest) as UUID
    }

    @discardableResult
    func show(meetingId: UUID, seriesId: UUID, title: String) -> Task<Void, Never> {
        Task {
            guard let account = await account() else { return }
            let page = MinutiaClient.recapURL(instance: account.client.instance, seriesId: seriesId, meetingId: meetingId)
            guard let userId = account.userId else { return openURL(page) }
            if let window, current?.meetingId == meetingId { return focus(window) }
            current = (meetingId, page, "/series/\(seriesId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())", account.client)
            self.title = title.isEmpty ? "Minutia" : title
            let window = window ?? makeWindow(store: WKWebsiteDataStore(
                forIdentifier: Self.storeIdentifier(instance: account.client.instance, userId: userId)))
            window.title = self.title
            focus(window)
            await load()
        }
    }

    /// Closes the window and erases every web data store, so a sign-out or a server switch leaves
    /// no web session behind.
    func forgetWebSessions() async {
        window?.close()
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers {
            for _ in 0..<20 {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                    break
                } catch {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    func tryAgain() { Task { await load() } }

    @objc func openInBrowser() {
        if let current { openURL(current.page) }
    }

    @objc func copyLink() {
        if let current { copy(current.page.absoluteString) }
    }

    @objc private func goBack() { webView?.goBack() }

    @objc private func reload() {
        if screen == .page { webView?.reload() } else { tryAgain() }
    }

    @objc private func didWake() {
        if window != nil { tryAgain() }
    }

    private func focus(_ window: NSWindow) {
        presence.opened(Self.presenceId)
        window.makeKeyAndOrderFront(nil)
    }

    private func setScreen(_ screen: RecapScreen) {
        self.screen = screen
        webView?.isHidden = screen != .page
        overlay?.isHidden = screen == .page
        if screen != .loading { slow?.cancel() }
    }

    private func load() async {
        guard let current, let webView else { return }
        handoff?.cancel()
        handoff = nil
        handoffTried = false
        setScreen(.loading)
        slow?.cancel()
        slow = Task { [clock] in
            await clock.sleep(8)
            if !Task.isCancelled, screen == .loading { setScreen(.slow) }
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard self.current?.page == current.page, self.webView === webView else { return }
        if cookies.isEmpty { mint() } else { webView.load(URLRequest(url: current.page)) }
    }

    private func mint() {
        guard handoff == nil, let current else { return }
        handoffTried = true
        handoff = Task {
            let (nonce, digest) = MinutiaClient.makeHandoffNonce()
            let result: Result<String, Error>
            do { result = .success(try await current.client.webSessionHandoff(nonceDigest: digest)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            handoff = nil
            switch result {
            case .success(let id):
                webView?.load(MinutiaClient.companionSessionRequest(
                    instance: current.client.instance, handoffId: id, nonce: nonce, next: current.next))
            case .failure(MinutiaClientError.serverError(status: 404)):
                window?.close()
                openURL(current.page)
            case .failure(let error as URLError) where Self.offline.contains(error.code):
                setScreen(.offline)
            case .failure(let error):
                if error as? MinutiaClientError == .signedOut { onSignedOut() }
                webView?.load(URLRequest(url: current.page))
            }
        }
    }

    private func openOutside(_ url: URL) {
        guard let current else { return }
        openURL(["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : current.page)
    }

    private func makeWindow(store: WKWebsiteDataStore) -> NSWindow {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let overlay = NSHostingView(rootView: RecapOverlay(controller: self))
        let content = NSView()
        for view in [webView, overlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        let window = RecapWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 400)
        window.contentView = content
        window.delegate = self
        let toolbar = NSToolbar(identifier: Self.frameName)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        self.window = window
        self.webView = webView
        self.overlay = overlay
        return window
    }
}

private final class RecapWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension RecapWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        handoff?.cancel()
        handoff = nil
        slow?.cancel()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        window = nil
        webView = nil
        overlay = nil
        current = nil
        presence.closed(Self.presenceId)
    }
}

extension RecapWindowController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let current, let url = action.request.url else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch RecapNavigation.decide(
            url: url, instance: current.client.instance, isMainFrame: action.targetFrame != nil, isDownload: action.shouldPerformDownload) {
        case .allow where mainFrame && url.path == "/login" && !handoffTried && screen != .page:
            mint()
            return .cancel
        case .allow:
            return .allow
        case .openInBrowser where mainFrame:
            openOutside(url)
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        guard !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") else { return .allow }
        if response.isForMainFrame, let url = response.response.url { openOutside(url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setScreen(.page)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func fail(_ error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled else { return }
        setScreen((NSURLErrorClientCertificateRequired...NSURLErrorSecureConnectionFailed).contains(error.code) ? .insecure : .offline)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, let current,
           RecapNavigation.decide(url: url, instance: current.client.instance, isMainFrame: false, isDownload: false) == .openInBrowser {
            openURL(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }
}

extension RecapWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    private static let items: [(id: String, label: String, symbol: String, action: Selector)] = [
        ("back", "Back", "chevron.backward", #selector(goBack)),
        ("reload", "Reload", "arrow.clockwise", #selector(reload)),
        ("openInBrowser", ReviewCopy.openInBrowser, "safari", #selector(openInBrowser)),
        ("copyLink", "Copy link", "link", #selector(copyLink)),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let ids = Self.items.map { NSToolbarItem.Identifier($0.id) }
        return Array(ids.prefix(2)) + [.flexibleSpace] + ids.suffix(2)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let spec = Self.items.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.isBordered = true
        item.target = self
        item.action = spec.action
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.action == #selector(goBack) ? webView?.canGoBack == true : current != nil
    }
}

private struct RecapOverlay: View {
    @ObservedObject var controller: RecapWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(controller.title).font(Typo.masthead)
            switch controller.screen {
            case .loading, .page:
                skeleton
            case .slow:
                skeleton
                message(ReviewCopy.windowSlow, primary: (ReviewCopy.tryAgain, controller.tryAgain),
                        secondary: (ReviewCopy.openInBrowser, controller.openInBrowser))
            case .offline:
                message(ReviewCopy.windowOffline, primary: (ReviewCopy.tryAgain, controller.tryAgain), secondary: nil)
            case .insecure:
                message(ReviewCopy.windowCert, primary: (ReviewCopy.openInBrowser, controller.openInBrowser), secondary: nil)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(Space.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([0.92, 0.7, 0.82, 0.55], id: \.self) { width in
                RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.07))
                    .frame(width: 520 * width, height: 12)
            }
        }
        .accessibilityHidden(true)
    }

    private func message(_ text: String, primary: (String, () -> Void), secondary: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(text).font(Typo.bodyStrong)
            HStack(spacing: Space.x2) {
                Button(primary.0, action: primary.1).buttonStyle(PrimaryButtonStyle())
                if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(SecondaryButtonStyle()) }
            }
            .frame(width: secondary == nil ? 160 : 328)
        }
    }
}
