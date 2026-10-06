import SwiftUI
import WebKit
import Combine

// MARK: - Saved sites

struct Site: Codable, Identifiable, Equatable {
    var title: String
    var url: String
    var id: String { url }
}

enum BrowserStore {
    static let defaults: [Site] = [
        Site(title: "YouTube", url: "https://www.youtube.com"),
        Site(title: "Wikipedia", url: "https://www.wikipedia.org"),
        Site(title: "GitHub", url: "https://github.com"),
        Site(title: "Reddit", url: "https://www.reddit.com"),
        Site(title: "Hacker News", url: "https://news.ycombinator.com"),
        Site(title: "Maps", url: "https://www.openstreetmap.org")
    ]
    static func load(_ key: String) -> [Site]? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([Site].self, from: d)
    }
    static func save(_ sites: [Site], _ key: String) {
        if let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Delegate / script proxy (WKWebView needs NSObject delegates)

final class BrowserProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String, let t = tab, t.owner?.active === t else { return }
        t.owner?.setFullscreen(s == "enter")
    }

    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = Settings.shared.requestDesktop ? .desktop : .mobile
        decisionHandler(.allow, preferences)
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        if tab?.owner?.active === tab { tab?.owner?.setFullscreen(false) }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { tab?.finished() }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError error: Error) { tab?.showError(error) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError error: Error) { tab?.showError(error) }

    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url?.absoluteString { tab?.owner?.newTab(u) }   // popups / target=_blank → new tab
        return nil
    }
}

// MARK: - Tab

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let web: WKWebView
    weak var owner: BrowserModel?
    private let proxy = BrowserProxy()
    @Published var title = "New Tab"
    @Published var url = ""
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    private var obs: [NSKeyValueObservation] = []

    var isStart: Bool { url.isEmpty }
    var displayTitle: String { isStart ? "New Tab" : (title.isEmpty ? displayHost : title) }
    var displayHost: String {
        if let u = URL(string: url), let h = u.host { return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        return url
    }

    init(owner: BrowserModel) {
        self.owner = owner
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.preferredContentMode = Settings.shared.requestDesktop ? .desktop : .mobile
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: browserFullscreenJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(proxy, name: "ntfs")
        proxy.tab = self
        web.navigationDelegate = proxy
        web.uiDelegate = proxy
        web.isOpaque = false
        web.backgroundColor = .black

        obs = [
            web.observe(\.url) { [weak self] w, _ in
                DispatchQueue.main.async { self?.url = w.url?.absoluteString ?? "" }
            },
            web.observe(\.title) { [weak self] w, _ in
                DispatchQueue.main.async { self?.title = w.title ?? "" }
            },
            web.observe(\.estimatedProgress) { [weak self] w, _ in
                DispatchQueue.main.async { self?.progress = w.estimatedProgress }
            },
            web.observe(\.isLoading) { [weak self] w, _ in
                DispatchQueue.main.async { self?.loading = w.isLoading }
            },
            web.observe(\.canGoBack) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoBack = w.canGoBack }
            },
            web.observe(\.canGoForward) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoForward = w.canGoForward }
            }
        ]
    }

    func load(_ input: String) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let s: String
        if (!t.contains(" ") && (t.contains(".") || t.hasPrefix("http"))) || t.hasPrefix("localhost") {
            s = t.hasPrefix("http") ? t : "https://" + t
        } else {
            s = Settings.shared.searchEngine.searchURL + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
        }
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
    }

    func finished() {
        owner?.visited(Site(title: title.isEmpty ? displayHost : title, url: url))
        owner?.saveTabs()
    }

    func showError(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let msg = ns.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <html><head><meta name=viewport content='width=device-width,initial-scale=1'>
        <style>body{background:#16161c;color:#eee;font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        div{text-align:center;max-width:460px;padding:20px}h1{font-size:28px;margin:0 0 10px}p{color:#9a9aa6;font-size:16px}</style></head>
        <body><div><h1>Can’t open this page</h1><p>\(msg)</p></div></body></html>
        """
        web.loadHTMLString(html, baseURL: web.url ?? URL(string: url))
    }
}

// MARK: - Model

final class BrowserModel: AppModel {
    static let tabBar: CGFloat = 34
    static let bar: CGFloat = 44

    @Published var tabs: [BrowserTab] = []
    @Published var activeID: UUID?
    @Published var typed = ""
    @Published var editing = false
    @Published var fullscreen = false
    @Published var bookmarks: [Site] = BrowserStore.load("nt.bookmarks") ?? BrowserStore.defaults
    @Published var history: [Site] = BrowserStore.load("nt.history") ?? []

    private var subs: [UUID: AnyCancellable] = [:]
    private var prefsSub: AnyCancellable?
    private var lastHover = Date.distantPast
    private var lastPoint = CGPoint(x: 200, y: 200)

    var active: BrowserTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var chrome: CGFloat { fullscreen ? 0 : BrowserModel.tabBar + BrowserModel.bar }
    var isBookmarked: Bool { !active.isStart && bookmarks.contains { $0.url == active.url } }

    override init() {
        super.init()
        let saved = UserDefaults.standard.stringArray(forKey: "nt.tabs") ?? []
        let urls = saved.isEmpty ? [""] : saved
        for u in urls { addTab(u, activate: false) }
        let i = min(UserDefaults.standard.integer(forKey: "nt.activeTab"), tabs.count - 1)
        activeID = tabs[max(i, 0)].id
        prefsSub = NotificationCenter.default.publisher(for: .browserPrefsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tabs.forEach { if !$0.isStart { $0.web.reload() } } }
    }

    // MARK: Tabs

    @discardableResult
    private func addTab(_ url: String, activate: Bool) -> BrowserTab {
        let t = BrowserTab(owner: self)
        subs[t.id] = t.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tabs.append(t)
        if activate { activeID = t.id }
        if !url.isEmpty { t.load(url) }
        return t
    }

    func newTab(_ url: String? = nil) {
        setFullscreen(false)
        addTab(url ?? "", activate: true)
        editing = false
        if url == nil { startEditing() }
        saveTabs()
    }

    func select(_ t: BrowserTab) {
        guard t.id != activeID else { return }
        setFullscreen(false)
        activeID = t.id
        editing = false
        saveTabs()
    }

    func close(_ t: BrowserTab) {
        setFullscreen(false)
        if tabs.count == 1 {
            t.web.stopLoading()
            tabs = []; subs = [:]
            let n = addTab("", activate: true)
            activeID = n.id
        } else if let i = tabs.firstIndex(where: { $0.id == t.id }) {
            let wasActive = t.id == activeID
            subs[t.id] = nil
            tabs.remove(at: i)
            if wasActive { activeID = tabs[min(i, tabs.count - 1)].id }
        }
        editing = false
        saveTabs()
    }

    func saveTabs() {
        UserDefaults.standard.set(tabs.map { $0.url }, forKey: "nt.tabs")
        UserDefaults.standard.set(tabs.firstIndex { $0.id == activeID } ?? 0, forKey: "nt.activeTab")
    }

    // MARK: Bookmarks / history

    func toggleBookmark() {
        let t = active
        guard !t.isStart else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == t.url }) { bookmarks.remove(at: i) }
        else { bookmarks.append(Site(title: t.title.isEmpty ? t.displayHost : t.title, url: t.url)) }
        BrowserStore.save(bookmarks, "nt.bookmarks")
    }

    func visited(_ s: Site) {
        guard !s.url.isEmpty, s.url != "about:blank" else { return }
        history.removeAll { $0.url == s.url }
        history.insert(s, at: 0)
        if history.count > 150 { history.removeLast(history.count - 150) }
        BrowserStore.save(history, "nt.history")
    }

    var suggestions: [Site] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return Array(bookmarks.prefix(5)) }
        var seen = Set<String>()
        return (bookmarks + history).filter {
            ($0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)) && seen.insert($0.url).inserted
        }.prefix(5).map { $0 }
    }

    // MARK: Address bar

    func startEditing() { typed = ""; editing = true }
    func go(_ s: String) { editing = false; active.load(s) }
    func home() { go(Settings.shared.homepage) }

    // MARK: Fullscreen

    func setFullscreen(_ on: Bool) {
        guard on != fullscreen else { return }
        fullscreen = on
        editing = false
        if let w = win { Desktop.shared.setFullscreen(w, on) }
    }

    func exitFullscreen() {
        js("window.__ntfsExit && window.__ntfsExit()")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.setFullscreen(false) }
    }

    // MARK: Page interaction

    private func js(_ code: String) { active.web.evaluateJavaScript(code, completionHandler: nil) }

    /// Runs `body` with x, y already converted from window points to page CSS pixels.
    private func atPoint(_ p: CGPoint, _ body: String) {
        let w = max(active.web.bounds.width, 1)
        js("""
        (function(){var s=window.innerWidth/\(w),x=\(p.x)*s,y=\(p.y)*s;\(body)})()
        """)
    }

    override func hover(_ p: CGPoint) {
        lastPoint = CGPoint(x: p.x, y: p.y - chrome)
        guard !active.isStart, p.y > chrome, Date().timeIntervalSince(lastHover) > 0.04 else { return }
        lastHover = Date()
        atPoint(lastPoint, """
        var e=document.elementFromPoint(x,y);if(!e)return;
        var o={clientX:x,clientY:y,bubbles:true,view:window};
        if(window.__nth!==e){if(window.__nth)window.__nth.dispatchEvent(new MouseEvent('mouseout',o));
        e.dispatchEvent(new MouseEvent('mouseover',o));window.__nth=e}
        e.dispatchEvent(new MouseEvent('mousemove',o));
        """)
    }

    override func contentClick(_ p: CGPoint) {
        editing = false
        guard p.y > chrome, !active.isStart else { return }
        atPoint(CGPoint(x: p.x, y: p.y - chrome), """
        var e=document.elementFromPoint(x,y);if(!e)return;
        var o={clientX:x,clientY:y,bubbles:true,cancelable:true,view:window,button:0};
        if(e.focus)e.focus();
        try{e.dispatchEvent(new PointerEvent('pointerdown',o))}catch(_){}
        e.dispatchEvent(new MouseEvent('mousedown',o));
        try{e.dispatchEvent(new PointerEvent('pointerup',o))}catch(_){}
        e.dispatchEvent(new MouseEvent('mouseup',o));
        e.click();
        """)
    }

    override func scroll(_ dy: CGFloat) {
        guard !active.isStart else { return }
        atPoint(lastPoint, """
        var e=document.elementFromPoint(x,y),d=\(dy);
        while(e&&e!==document.body&&e!==document.documentElement){
          var st=getComputedStyle(e);
          if(/(auto|scroll)/.test(st.overflowY)&&e.scrollHeight>e.clientHeight+2){
            var b=e.scrollTop;e.scrollTop+=d;if(e.scrollTop!==b)return;}
          e=e.parentElement}
        window.scrollBy(0,d);
        """)
    }

    // MARK: Keyboard

    override func insert(_ s: String) {
        if editing { typed += s; return }
        if active.isStart { startEditing(); typed = s; return }     // just start typing on the start page
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        js("""
        (function(){var s='\(esc)',ok=false;try{ok=document.execCommand('insertText',false,s)}catch(e){}
        if(!ok){var t=document.activeElement||document.body,c=s.toUpperCase().charCodeAt(0);
        ['keydown','keypress','keyup'].forEach(function(n){t.dispatchEvent(new KeyboardEvent(n,{key:s,code:s==' '?'Space':(/[a-z]/i.test(s)?'Key'+s.toUpperCase():''),keyCode:c,which:c,bubbles:true,cancelable:true}))})}})()
        """)
    }

    private func pageKey(_ key: String, keyCode: Int) {
        js("""
        (function(){var t=document.activeElement||document.body;['keydown','keyup'].forEach(function(n){t.dispatchEvent(new KeyboardEvent(n,{key:'\(key)',code:'\(key)',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}))})})()
        """)
    }

    override func special(_ k: SpecialKey) {
        if editing {
            switch k {
            case .enter: go(typed)
            case .escape: editing = false
            case .backspace: typed = String(typed.dropLast())
            default: break
            }
            return
        }
        if k == .escape && fullscreen { exitFullscreen(); return }
        switch k {
        case .backspace: if active.isStart { return } else { js("document.execCommand('delete')") }
        case .enter:
            js("var e=document.activeElement; if(e&&e.form){ if(e.form.requestSubmit){e.form.requestSubmit()}else{e.form.submit()} }")
        case .up: scroll(-80)
        case .down: scroll(80)
        case .left: pageKey("ArrowLeft", keyCode: 37)
        case .right: pageKey("ArrowRight", keyCode: 39)
        case .tab: pageKey("Tab", keyCode: 9)
        default: break
        }
    }

    override func command(_ key: String) {
        switch key {
        case "t": newTab()
        case "l": startEditing()
        case "r": active.web.reload()
        case "d": toggleBookmark()
        default: break
        }
    }

    override func handleClose() -> Bool {
        guard tabs.count > 1 else { return false }
        close(active)
        return true
    }
}

// MARK: - Fullscreen polyfill (works for <video>, YouTube, and fullscreen iframes)

let browserFullscreenJS = #"""
(function(){
if (window.__ntfs) return; window.__ntfs = 1;
var isTop = (window === window.top), cur = null;
function post(m){ try { window.webkit.messageHandlers.ntfs.postMessage(m); } catch(e) {} }
function style(el, on){
  if (on) {
    el.__s = el.getAttribute('style');
    var s = 'position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;border:0!important;z-index:2147483647!important;background:#000!important;transform:none!important;';
    el.setAttribute('style', (el.__s ? el.__s + ';' : '') + s);
  } else {
    if (el.__s == null) el.removeAttribute('style'); else el.setAttribute('style', el.__s);
  }
}
function fire(el){
  ['fullscreenchange','webkitfullscreenchange'].forEach(function(n){ try { el.dispatchEvent(new Event(n, {bubbles:true})); } catch(e){} });
  setTimeout(function(){ window.dispatchEvent(new Event('resize')); }, 30);
}
function enter(el){
  if (cur === el) return;
  if (cur) exit();
  cur = el; style(el, true);
  document.documentElement.style.overflow = 'hidden';
  if (isTop) post('enter'); else window.parent.postMessage('ntfs-enter', '*');
  fire(el);
}
function exit(){
  if (!cur) return;
  var el = cur; cur = null; style(el, false);
  document.documentElement.style.overflow = '';
  if (el.tagName === 'IFRAME') { try { el.contentWindow.postMessage('ntfs-leave', '*'); } catch(e){} }
  if (isTop) post('exit'); else window.parent.postMessage('ntfs-exit', '*');
  fire(el);
}
window.__ntfsExit = exit;
window.addEventListener('message', function(e){
  var d = e.data;
  if (d === 'ntfs-leave' && e.source === window.parent) { exit(); return; }
  if (d !== 'ntfs-enter' && d !== 'ntfs-exit') return;
  var fr = document.getElementsByTagName('iframe');
  for (var i = 0; i < fr.length; i++) {
    if (fr[i].contentWindow === e.source) { if (d === 'ntfs-enter') enter(fr[i]); else if (cur === fr[i]) exit(); }
  }
});
var E = Element.prototype, D = Document.prototype;
E.requestFullscreen = E.webkitRequestFullscreen = E.webkitRequestFullScreen = function(){ enter(this); return Promise.resolve(); };
D.exitFullscreen = D.webkitExitFullscreen = D.webkitCancelFullScreen = function(){ exit(); return Promise.resolve(); };
try {
  HTMLVideoElement.prototype.webkitEnterFullscreen = HTMLVideoElement.prototype.webkitEnterFullScreen = function(){ enter(this); };
  HTMLVideoElement.prototype.webkitExitFullscreen = function(){ exit(); };
} catch(e){}
function def(o, n, f){ try { Object.defineProperty(o, n, {get: f, configurable: true}); } catch(e){} }
['fullscreenElement','webkitFullscreenElement','webkitCurrentFullScreenElement'].forEach(function(n){ def(D, n, function(){ return cur; }); });
['fullscreenEnabled','webkitFullscreenEnabled'].forEach(function(n){ def(D, n, function(){ return true; }); });
['fullscreen','webkitIsFullScreen'].forEach(function(n){ def(D, n, function(){ return !!cur; }); });
})();
"""#

// MARK: - Views

/// Hosts whichever tab's WKWebView is active.
struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .black; return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        if web.superview !== v {
            v.subviews.forEach { $0.removeFromSuperview() }
            web.frame = v.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(web)
        }
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.fullscreen {
                tabStrip
                toolbarView
            }
            ZStack(alignment: .topLeading) {
                WebHost(web: model.active.web)
                if model.active.isStart { StartPage(model: model) }
                if model.editing && !model.fullscreen { suggestionsPanel }
                if model.fullscreen {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                        Text("Exit full screen")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .clickable { model.exitFullscreen() }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
        }
        .background(Color.black)
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { t in tabItem(t) }
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                .clickable { model.newTab() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserModel.tabBar)
        .background(Color(white: 0.09))
    }

    private func tabItem(_ t: BrowserTab) -> some View {
        let on = t.id == model.activeID
        return HStack(spacing: 6) {
            Image(systemName: t.loading ? "arrow.triangle.2.circlepath" : (t.isStart ? "square.grid.2x2" : "globe"))
                .font(.system(size: 10)).opacity(0.6)
            Text(t.displayTitle).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(on ? 0.12 : 0)))
                .clickable { model.close(t) }
        }
        .foregroundStyle(.white.opacity(on ? 1 : 0.6))
        .padding(.horizontal, 10)
        .frame(maxWidth: 190)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color(white: 0.22) : Color(white: 0.13)))
        .clickable { model.select(t) }
    }

    // MARK: Toolbar

    private var toolbarView: some View {
        let t = model.active
        return HStack(spacing: 8) {
            tool("chevron.left", enabled: t.canGoBack) { t.web.goBack() }
            tool("chevron.right", enabled: t.canGoForward) { t.web.goForward() }
            tool(t.loading ? "xmark" : "arrow.clockwise") {
                if t.loading { t.web.stopLoading() } else if !t.isStart { t.web.reload() }
            }
            tool("house") { model.home() }

            HStack(spacing: 6) {
                Image(systemName: model.editing ? "magnifyingglass" : (t.url.hasPrefix("https") ? "lock.fill" : "globe"))
                    .font(.system(size: 11)).opacity(0.6)
                Text(model.editing ? model.typed + "▏" : (t.isStart ? "Search or enter address" : t.displayHost))
                    .font(.system(size: 14)).lineLimit(1)
                    .opacity(!model.editing && t.isStart ? 0.5 : 1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(Capsule().fill(Color(white: model.editing ? 0.28 : 0.2)))
            .overlay(Capsule().stroke(Color.blue, lineWidth: model.editing ? 1.5 : 0))
            .clickable { model.startEditing() }

            Image(systemName: model.isBookmarked ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isBookmarked ? Color.yellow : .white.opacity(t.isStart ? 0.3 : 0.9))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.08)))
                .clickable { model.toggleBookmark() }
        }
        .padding(.horizontal, 10)
        .frame(height: BrowserModel.bar)
        .background(Color(white: 0.14))
        .overlay(alignment: .bottomLeading) {
            if t.loading {
                GeometryReader { g in
                    Rectangle().fill(Color.blue).frame(width: g.size.width * CGFloat(t.progress), height: 2)
                }
                .frame(height: 2)
            }
        }
    }

    private func tool(_ icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
            .frame(width: 32, height: 30)
            .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.08)))
            .clickable { if enabled { action() } }
    }

    // MARK: Address suggestions

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.typed.isEmpty {
                suggestionRow("magnifyingglass", "Search “\(model.typed)”", nil) { model.go(model.typed) }
            }
            ForEach(model.suggestions) { s in
                suggestionRow("star.fill", s.title, s.url) { model.go(s.url) }
            }
        }
        .padding(6)
        .frame(width: 520)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .padding(.leading, 150).padding(.top, 6)
    }

    private func suggestionRow(_ icon: String, _ title: String, _ sub: String?, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 18).opacity(0.7)
            Text(title).font(.system(size: 14)).lineLimit(1)
            if let sub { Text(sub).font(.system(size: 12)).opacity(0.45).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
        .clickable(action)
    }
}

// MARK: - Start page

struct StartPage: View {
    @ObservedObject var model: BrowserModel

    private func color(_ s: String) -> Color {
        let h = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Color(hue: Double(h) / 360, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 18)
            Text("NanoTower")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.7, green: 0.7, blue: 1)], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").opacity(0.6)
                Text("Search or enter address").opacity(0.5)
                Spacer()
            }
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(width: 480, height: 46)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .clickable { model.startEditing() }

            let rows = stride(from: 0, to: model.bookmarks.count, by: 6).map { Array(model.bookmarks[$0..<min($0 + 6, model.bookmarks.count)]) }
            VStack(spacing: 14) {
                ForEach(Array(rows.prefix(2).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 18) {
                        ForEach(row) { s in tile(s) }
                    }
                }
            }

            if !model.history.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT").font(.system(size: 11, weight: .semibold)).opacity(0.4).padding(.bottom, 2)
                    ForEach(model.history.prefix(4)) { s in
                        HStack(spacing: 10) {
                            Image(systemName: "clock").font(.system(size: 11)).opacity(0.5)
                            Text(s.title).font(.system(size: 13)).lineLimit(1)
                            Text(s.url).font(.system(size: 11)).opacity(0.4).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 480, height: 28, alignment: .leading)
                        .contentShape(Rectangle())
                        .clickable { model.go(s.url) }
                    }
                }
                .foregroundStyle(.white)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.3), Color(white: 0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func tile(_ s: Site) -> some View {
        VStack(spacing: 6) {
            Text(String(s.title.prefix(1)).uppercased())
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16).fill(color(s.title).gradient))
            Text(s.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
        }
        .frame(width: 80)
        .contentShape(Rectangle())
        .clickable { model.go(s.url) }
    }
}
