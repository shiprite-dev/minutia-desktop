import AppKit
import CryptoKit
import SwiftUI
import WebKit

enum RecapNavigation: Equatable {
    case allow, openInBrowser, deny

    static func decide(url: URL, instance: URL, isNewWindow: Bool, isDownload: Bool) -> RecapNavigation {
        let scheme = url.scheme?.lowercased() ?? ""
        if isDownload || scheme == "mailto" { return .openInBrowser }
        guard ["http", "https"].contains(scheme) else { return .deny }
        return !isNewWindow && origin(url) == origin(instance) ? .allow : .openInBrowser
    }

    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
        return "\(scheme)://\(url.host?.lowercased() ?? "")" + (port.map { ":\($0)" } ?? "")
    }
}

enum RecapScreen: Equatable {
    case loading, slow, offline, insecure, page

    var announcement: String? {
        switch self {
        case .slow: ReviewCopy.windowSlow
        case .offline: ReviewCopy.windowOffline
        case .insecure: ReviewCopy.windowCert
        case .loading, .page: nil
        }
    }
}

struct RecapStores {
    var all: @MainActor () async -> [UUID]
    var remove: @MainActor (UUID) async throws -> Void

    static let webKit = RecapStores(
        all: { await WKWebsiteDataStore.allDataStoreIdentifiers },
        remove: { try await WKWebsiteDataStore.remove(forIdentifier: $0) })
}

/// The one Minutia window that shows a meeting's web page. Each time the window opens it signs in
/// with a fresh one-time handoff into a web data store of its own per server and account, so it is
/// always the Mac's account; the Mac's own session never enters it.
@MainActor
final class RecapWindowController: NSObject, ObservableObject {
    typealias Account = (client: MinutiaClient, userId: String?)
    private struct Handoff { let id: String, nonce: String, minted: Date }

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
    private let defaults: UserDefaults
    private let stores: RecapStores
    private let announce: (String) -> Void
    private let onSignedOut: () -> Void
    private var current: (meetingId: UUID, page: URL, next: String, client: MinutiaClient)?
    private var signedIn = false
    private var generation = 0
    private var epoch = 0
    private var minting: Task<Result<Handoff, Error>, Never>?
    private var unused: Handoff?
    private var slow: Task<Void, Never>?

    private static let presenceId = "recap"
    private static let frameName = "MinutiaRecap"
    private static let removalKey = "recap.storesToRemove"
    private static let handoffReuse: TimeInterval = 9 * 60
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
        defaults: UserDefaults = .standard,
        stores: RecapStores = .webKit,
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        onSignedOut: @escaping () -> Void = {}
    ) {
        self.account = account
        self.openURL = openURL
        self.copy = copy
        self.clock = clock
        self.presence = presence
        self.defaults = defaults
        self.stores = stores
        self.announce = announce
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

    /// Closes the window and erases every recap web data store, so a sign-out or a server switch
    /// leaves no web session behind. Stores WebKit cannot remove yet are retried at the next launch.
    func forgetWebSessions() async {
        window?.close()
        epoch += 1
        minting?.cancel()
        minting = nil
        unused = nil
        await remove(await stores.all())
    }

    /// At launch: erase every recap web data store except the signed-in account's, plus any whose
    /// removal failed before.
    func pruneStores(keeping current: UUID?) async {
        await remove(await stores.all().filter { $0 != current })
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

    private func remove(_ ids: [UUID]) async {
        var pending = Set((defaults.stringArray(forKey: Self.removalKey) ?? []).compactMap(UUID.init(uuidString:)) + ids)
        defaults.set(pending.map(\.uuidString), forKey: Self.removalKey)
        for id in pending {
            for attempt in 0..<10 {
                if (try? await stores.remove(id)) != nil {
                    pending.remove(id)
                    break
                }
                if attempt < 9 { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        }
        defaults.set(pending.map(\.uuidString), forKey: Self.removalKey)
    }

    private func focus(_ window: NSWindow) {
        presence.opened(Self.presenceId)
        window.makeKeyAndOrderFront(nil)
    }

    private func setScreen(_ screen: RecapScreen) {
        if let line = screen.announcement { announce(line) }
        self.screen = screen
        webView?.isHidden = screen != .page
        overlay?.isHidden = screen == .page
        if screen != .loading { slow?.cancel() }
    }

    private func load() async {
        guard let current, let webView else { return }
        generation += 1
        let mine = generation
        setScreen(.loading)
        slow?.cancel()
        slow = Task { [clock] in
            await clock.sleep(8)
            if !Task.isCancelled, mine == generation, screen == .loading { setScreen(.slow) }
        }
        guard !signedIn else {
            webView.load(URLRequest(url: current.page))
            return
        }
        let minted = await handoff(current.client)
        guard mine == generation, self.webView === webView else { return }
        switch minted {
        case .success(let handoff):
            webView.load(MinutiaClient.companionSessionRequest(
                instance: current.client.instance, handoffId: handoff.id, nonce: handoff.nonce, next: current.next))
        case .failure(MinutiaClientError.serverError(status: 404)):
            window?.close()
            openURL(current.page)
        case .failure(let error as URLError) where Self.offline.contains(error.code):
            setScreen(.offline)
        case .failure(let error):
            if error as? MinutiaClientError == .signedOut { onSignedOut() }
            signedIn = true
            webView.load(URLRequest(url: current.page))
        }
    }

    /// One mint at a time: every attempt while one is pending waits for it, and a handoff minted but
    /// not yet used (its window closed, or a newer attempt took over) is reused while still valid.
    private func handoff(_ client: MinutiaClient) async -> Result<Handoff, Error> {
        if let unused, clock.now().timeIntervalSince(unused.minted) < Self.handoffReuse { return .success(unused) }
        let epoch = epoch
        let task = minting ?? Task { [clock] in
            let (nonce, digest) = MinutiaClient.makeHandoffNonce()
            do {
                return .success(Handoff(id: try await client.webSessionHandoff(nonceDigest: digest), nonce: nonce, minted: clock.now()))
            } catch {
                return .failure(error)
            }
        }
        minting = task
        let result = await task.value
        guard epoch == self.epoch else { return .failure(CancellationError()) }
        if minting == task { minting = nil }
        if case .success(let handoff) = result { unused = handoff }
        return result
    }

    private func openOutside(_ url: URL) {
        guard let current else { return }
        openURL(["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? url : current.page)
    }

    private func shortcut(_ event: NSEvent) -> Bool {
        switch (event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "w"): window?.performClose(nil)
        case (.command, "["): goBack()
        case (.command, "r"): reload()
        case ([.command, .shift], "c"): copyLink()
        default: return false
        }
        return true
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
        window.shortcut = { [weak self] in self?.shortcut($0) ?? false }
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
        signedIn = false
        return window
    }
}

/// Handles the window's own shortcuts: a menu-bar app may have no File or View menu to carry them.
private final class RecapWindow: NSWindow {
    var shortcut: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        shortcut(event) || super.performKeyEquivalent(with: event)
    }
}

extension RecapWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        generation += 1
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
        let subframe = action.targetFrame.map { !$0.isMainFrame } ?? false
        switch RecapNavigation.decide(
            url: url, instance: current.client.instance, isNewWindow: action.targetFrame == nil, isDownload: action.shouldPerformDownload) {
        case .allow:
            return .allow
        case .openInBrowser where !subframe:
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

    /// The server answered the sign-in post: the handoff is spent and the window is signed in.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        signedInByServer()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        signedInByServer()
        setScreen(.page)
    }

    private func signedInByServer() {
        unused = nil
        signedIn = true
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
           RecapNavigation.decide(url: url, instance: current.client.instance, isNewWindow: true, isDownload: false) == .openInBrowser {
            openOutside(url)
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
