import SwiftUI
import WebKit
import Combine

// MARK: - Delegate / script proxy (WKWebView needs NSObject delegates)

final class BrowserProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var model: BrowserModel?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String else { return }
        model?.setFullscreen(s == "enter")
    }

    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = Settings.shared.requestDesktop ? .desktop : .mobile
        decisionHandler(.allow, preferences)
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        model?.setFullscreen(false)          // a new page never stays stuck in fullscreen
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if let u = w.url?.absoluteString, u != "about:blank" { Settings.shared.lastURL = u }
    }

    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }   // open "new tab" links in place
        return nil
    }
}

// MARK: - Model

final class BrowserModel: AppModel {
    static let bar: CGFloat = 44

    let web: WKWebView
    private let proxy = BrowserProxy()
    @Published var address = ""
    @Published var typed = ""
    @Published var editing = false
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var fullscreen = false
    private var obs: [NSKeyValueObservation] = []
    private var prefsSub: AnyCancellable?

    var toolbar: CGFloat { fullscreen ? 0 : BrowserModel.bar }

    var displayAddress: String {
        if let u = URL(string: address), let h = u.host {
            return (h.hasPrefix("www.") ? String(h.dropFirst(4)) : h) + (u.path == "/" ? "" : u.path)
        }
        return address
    }
    var isSecure: Bool { address.hasPrefix("https") }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.preferredContentMode = Settings.shared.requestDesktop ? .desktop : .mobile
        cfg.allowsInlineMediaPlayback = true                  // stops iPhone auto-forcing native fullscreen
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: BrowserModel.fullscreenJS,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()

        ucc.add(proxy, name: "ntfs")
        proxy.model = self
        web.navigationDelegate = proxy
        web.uiDelegate = proxy

        obs = [
            web.observe(\.url) { [weak self] w, _ in
                DispatchQueue.main.async {
                    guard let self, !self.editing else { return }
                    self.address = w.url?.absoluteString ?? ""
                }
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
        prefsSub = NotificationCenter.default.publisher(for: .browserPrefsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.web.reload() }

        let last = Settings.shared.lastURL
        go(last.isEmpty ? Settings.shared.homepage : last)
    }

    func startEditing() { typed = ""; editing = true }
    func home() { go(Settings.shared.homepage) }

    func go(_ input: String) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var s: String
        if (!t.contains(" ") && (t.contains(".") || t.hasPrefix("http"))) || t.hasPrefix("localhost") {
            s = t.hasPrefix("http") ? t : "https://" + t
        } else {
            s = Settings.shared.searchEngine.searchURL + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
        }
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
    }

    private func js(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }

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

    // MARK: Input

    private func pageKey(_ key: String, code: String, keyCode: Int) {
        js("""
        (function(){var t=document.activeElement||document.body;['keydown','keyup'].forEach(function(n){t.dispatchEvent(new KeyboardEvent(n,{key:'\(key)',code:'\(code)',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}))})})()
        """)
    }

    override func insert(_ s: String) {
        if editing { typed += s; return }
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        // Type into focused fields; if nothing is editable, send as key events (YouTube: space, k, f, …)
        js("""
        (function(){var s='\(esc)',ok=false;try{ok=document.execCommand('insertText',false,s)}catch(e){}
        if(!ok){var t=document.activeElement||document.body,c=s.toUpperCase().charCodeAt(0);
        ['keydown','keypress','keyup'].forEach(function(n){t.dispatchEvent(new KeyboardEvent(n,{key:s,code:s==' '?'Space':(/[a-z]/i.test(s)?'Key'+s.toUpperCase():''),keyCode:c,which:c,bubbles:true,cancelable:true}))})}})()
        """)
    }

    override func special(_ k: SpecialKey) {
        if editing {
            switch k {
            case .enter: editing = false; go(typed)
            case .escape: editing = false
            case .backspace: typed = String(typed.dropLast())
            default: break
            }
            return
        }
        if k == .escape && fullscreen { exitFullscreen(); return }
        switch k {
        case .backspace: js("document.execCommand('delete')")
        case .enter:
            js("var e=document.activeElement; if(e&&e.form){ if(e.form.requestSubmit){e.form.requestSubmit()}else{e.form.submit()} }")
        case .up: js("window.scrollBy(0,-80)")
        case .down: js("window.scrollBy(0,80)")
        case .left: pageKey("ArrowLeft", code: "ArrowLeft", keyCode: 37)
        case .right: pageKey("ArrowRight", code: "ArrowRight", keyCode: 39)
        default: break
        }
    }

    override func contentClick(_ p: CGPoint) {
        guard p.y > toolbar else { return }
        editing = false
        let x = p.x, y = p.y - toolbar
        let w = max(web.bounds.width, 1)
        js("""
        (function(){
          var s = window.innerWidth / \(w);
          var e = document.elementFromPoint(\(x) * s, \(y) * s);
          if (e) { if (e.focus) e.focus(); e.click(); }
        })()
        """)
    }

    override func scroll(_ dy: CGFloat) { js("window.scrollBy(0, \(dy))") }

    // MARK: Fullscreen polyfill (works for <video>, YouTube, and fullscreen iframes)

    static let fullscreenJS = #"""
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
}

// MARK: - Views

struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.fullscreen { toolbarView }
            ZStack(alignment: .topTrailing) {
                WebHost(web: model.web)
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
                }
            }
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 8) {
            tool("chevron.left", enabled: model.canGoBack) { model.web.goBack() }
            tool("chevron.right", enabled: model.canGoForward) { model.web.goForward() }
            tool(model.loading ? "xmark" : "arrow.clockwise") {
                if model.loading { model.web.stopLoading() } else { model.web.reload() }
            }
            tool("house") { model.home() }

            HStack(spacing: 6) {
                Image(systemName: model.editing ? "magnifyingglass" : (model.isSecure ? "lock.fill" : "globe"))
                    .font(.system(size: 11))
                    .opacity(0.6)
                Text(model.editing ? model.typed + "▏" : (model.displayAddress.isEmpty ? "Search or enter address" : model.displayAddress))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(Capsule().fill(Color(white: model.editing ? 0.28 : 0.2)))
            .overlay(Capsule().stroke(Color.blue, lineWidth: model.editing ? 1.5 : 0))
            .clickable { model.startEditing() }
        }
        .padding(.horizontal, 10)
        .frame(height: BrowserModel.bar)
        .background(Color(white: 0.14))
        .overlay(alignment: .bottomLeading) {
            if model.loading {
                GeometryReader { g in
                    Rectangle().fill(Color.blue)
                        .frame(width: g.size.width * CGFloat(model.progress), height: 2)
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
}
