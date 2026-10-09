//  ClaudeMonitor.swift
//  모니터: claude.ai를 모니터 해상도 그대로 선명하게, 화면 꽉 차게 표시 (미러링 아님)
//  아이폰: 가로 모드 고정, 블루투스 마우스/키보드 입력을 모니터로 전달하는 리모컨
//  모니터 미연결 시: 아이폰에 claude.ai가 그대로 보임 (로그인용)
//  최소 iOS 16

import UIKit
import WebKit
import GameController

extension Notification.Name {
    static let externalDisplayChanged = Notification.Name("externalDisplayChanged")
}

// MARK: - 설정 (앱을 꺼도 유지)

enum Settings {
    private static let d = UserDefaults.standard
    static var invertY: Bool {
        get { d.bool(forKey: "invertY") }
        set { d.set(newValue, forKey: "invertY") }
    }
    static var invertScroll: Bool {
        get { d.bool(forKey: "invertScroll3") }
        set { d.set(newValue, forKey: "invertScroll3") }
    }
    static var zoom: CGFloat {
        get { let v = d.double(forKey: "zoom"); return v > 0 ? CGFloat(v) : 1.0 }
        set { d.set(Double(newValue), forKey: "zoom") }
    }
    static let mouseSpeed: CGFloat = 1.5   // 마우스 감도
    static let scrollSpeed: CGFloat = 60   // 휠 스크롤 속도
}

// MARK: - 앱 진입점

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalSceneDelegate.self   // 모니터
        } else {
            config.delegateClass = PhoneSceneDelegate.self      // 아이폰
        }
        return config
    }

    // 아이폰 화면은 가로 모드 고정
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if window?.windowScene?.session.role == .windowExternalDisplayNonInteractive { return .all }
        return .landscape
    }
}

// MARK: - 블루투스 마우스 (움직임 값을 직접 받아서 모니터 커서로)

final class MouseController {
    static let shared = MouseController()
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onClick: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    private(set) var isPressed = false
    private(set) var lastClick = Date.distantPast
    private(set) var lastScroll = Date.distantPast
    var isConnected: Bool { !GCMouse.mice().isEmpty }
    private var started = false

    /// 방금 마우스를 클릭했는지 (아이폰 화면에 같이 눌리는 터치를 무시하기 위함)
    var clickedJustNow: Bool { isPressed || Date().timeIntervalSince(lastClick) < 0.5 }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            if let m = n.object as? GCMouse { self?.setup(m) }
        }
        GCMouse.mice().forEach { setup($0) }
    }

    private func setup(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            // 마우스 자체 기준 값이라 아이폰 방향과 무관. 위로 밀면 dy > 0 → 화면 좌표는 위가 음수
            DispatchQueue.main.async { self?.onMove?(CGFloat(dx), CGFloat(-dy)) }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPressed = pressed
                if pressed {
                    self.lastClick = Date()
                    self.onClick?()
                }
            }
        }
        input.scroll.valueChangedHandler = { [weak self] _, _, y in
            self?.lastScroll = Date()
            // 휠을 아래(몸 쪽)로 굴리면 y < 0
            DispatchQueue.main.async { self?.onScroll?(CGFloat(-y)) }
        }
    }
}

// MARK: - WebView 하나를 폰/모니터가 공유 (로그인 유지)

final class WebViewStore {
    static let shared = WebViewStore()
    let webView: WKWebView
    private var lastHover = Date.distantPast

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        ignoreKeyboard()
        webView.pageZoom = Settings.zoom
        webView.load(URLRequest(url: URL(string: "https://claude.ai")!))
    }

    /// 웹뷰가 아이폰 키보드에 반응하지 않게 (모니터 화면 아래쪽이 비어 보이는 문제 방지)
    /// 키보드는 아이폰에서 올라오지만 웹뷰는 모니터에 있어서, 키보드 높이만큼 화면을 잘라버리는 걸 막음
    func ignoreKeyboard() {
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
        ]
        names.forEach { NotificationCenter.default.removeObserver(webView, name: $0, object: nil) }
    }

    func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(webView, at: 0)
        ignoreKeyboard()
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    func changeZoom(by delta: CGFloat) {
        let z = min(max(webView.pageZoom + delta, 0.5), 3.0)
        webView.pageZoom = z
        Settings.zoom = z
    }

    func newChat() { webView.load(URLRequest(url: URL(string: "https://claude.ai/new")!)) }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func reload() { webView.reload() }

    // MARK: JS 조작

    private func run(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    private func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private func pt(_ p: CGPoint) -> (CGFloat, CGFloat) {
        let z = webView.pageZoom
        return (p.x / z, p.y / z)
    }

    /// 포커스된 입력칸을 찾고, 없으면 채팅 입력창에 포커스 (커서는 맨 끝)
    private let editableJS = """
    function __cmEditable(){
      var el = document.activeElement;
      if (el && (el.isContentEditable || el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) return el;
      el = document.querySelector('div[contenteditable="true"]');
      if (!el) return null;
      el.focus();
      var r = document.createRange(); r.selectNodeContents(el); r.collapse(false);
      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      return el;
    }
    """

    /// 글자 지우기/넣기 (한글 조합 중 변화도 반영)
    func edit(delete count: Int, insert text: String) {
        run("""
        \(editableJS)
        (function(n, t){
          if (!__cmEditable()) return;
          var s = window.getSelection();
          // 글자가 선택(블록)된 상태면: 입력 시 선택 영역을 교체, 백스페이스 시 선택 영역 삭제
          if (!s.isCollapsed) {
            if (t) document.execCommand('insertText', false, t);
            else document.execCommand('delete', false);
            return;
          }
          // 지울 글자를 선택한 뒤 새 글자로 한 번에 교체 (중간 상태가 생기지 않게)
          for (var i = 0; i < n; i++) s.modify('extend', 'backward', 'character');
          if (t) document.execCommand('insertText', false, t);
          else if (n > 0) document.execCommand('delete', false);
        })(\(count), \(jsString(text)));
        """)
    }

    /// 방향키: 커서 이동 / Shift 누르면 선택 영역 확장
    func moveCaret(extend: Bool, direction: String, granularity: String) {
        run("""
        \(editableJS)
        (function(){
          if (!__cmEditable()) return;
          window.getSelection().modify('\(extend ? "extend" : "move")', '\(direction)', '\(granularity)');
        })();
        """)
    }

    /// ⌘A: 입력칸 전체 선택
    func selectAll() {
        run("""
        \(editableJS)
        (function(){
          var el = __cmEditable();
          if (!el) return;
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') el.select();
          else document.execCommand('selectAll', false);
        })();
        """)
    }

    /// 선택된 글자 가져오기 (입력칸이든 Claude 답변이든)
    func selectedText(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("""
        (function(){
          var el = document.activeElement;
          if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA'))
            return el.value.substring(el.selectionStart, el.selectionEnd);
          return window.getSelection().toString();
        })();
        """) { result, _ in completion(result as? String ?? "") }
    }

    /// 선택 영역 삭제 (잘라내기용)
    func deleteSelection() {
        run("""
        (function(){
          var s = window.getSelection();
          if (s && !s.isCollapsed) document.execCommand('delete', false);
        })();
        """)
    }

    func pressSend() {
        run("""
        (function(){
          var b = document.querySelector('button[aria-label="Send message"], button[aria-label="메시지 보내기"]');
          if (b && !b.disabled) { b.click(); return; }
          var el = document.querySelector('div[contenteditable="true"]');
          if (el) el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));
        })();
        """)
    }

    /// 화살표 위치의 스크롤 영역을 스크롤. 결과(찾은 영역, 실제 이동량)를 돌려줌
    func scroll(by dy: CGFloat, at p: CGPoint, result: ((String) -> Void)? = nil) {
        let (x, y) = pt(p)
        webView.evaluateJavaScript("""
        (function(x,y,dy){
          function canScroll(el){
            var s = getComputedStyle(el);
            return /(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 1;
          }
          // 1) 화살표 아래 요소에서 위로 올라가며 스크롤 영역 찾기
          var el = document.elementFromPoint(x,y);
          while (el && el !== document.body && el !== document.documentElement && !canScroll(el)) el = el.parentElement;
          // 2) 못 찾으면: 화살표 위치를 포함하는 가장 큰 스크롤 영역 → 그래도 없으면 화면에서 가장 큰 스크롤 영역
          if (!el || el === document.body || el === document.documentElement) {
            var best = null, area = 0, any = null, anyArea = 0;
            document.querySelectorAll('div, main, section').forEach(function(c){
              if (!canScroll(c)) return;
              var r = c.getBoundingClientRect(), a = r.width * r.height;
              if (a > anyArea) { anyArea = a; any = c; }
              if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom && a > area) { area = a; best = c; }
            });
            el = best || any || document.scrollingElement;
          }
          // 부드러운 스크롤(smooth) 설정이 있으면 연속 스크롤이 서로 취소돼서 안 움직임 → 즉시 이동
          el.style.scrollBehavior = 'auto';
          var before = el.scrollTop;
          el.scrollTop = before + dy;
          return (el.tagName || '?') + ' ' + Math.round(el.scrollTop - before) + 'px';
        })(\(x), \(y), \(dy / webView.pageZoom));
        """) { value, error in
            result?(error != nil ? "JS 오류" : (value as? String ?? "?"))
        }
    }

    func click(at p: CGPoint) {
        let (x, y) = pt(p)
        run("""
        (function(x,y){
          var el = document.elementFromPoint(x,y);
          if (!el) return;
          var o = {bubbles:true, cancelable:true, composed:true, clientX:x, clientY:y, view:window, button:0, buttons:1, pointerType:'mouse', pointerId:1, isPrimary:true};
          el.dispatchEvent(new PointerEvent('pointerdown', o));
          el.dispatchEvent(new MouseEvent('mousedown', o));
          var f = el.closest('input, textarea, [contenteditable="true"], button, a, [tabindex]');
          if (f && f.focus) f.focus();
          o.buttons = 0;
          el.dispatchEvent(new PointerEvent('pointerup', o));
          el.dispatchEvent(new MouseEvent('mouseup', o));
          // 버튼/링크 안의 아이콘(svg)을 눌렀을 때도 버튼 자체를 클릭
          var target = el.closest('button, a, [role="button"], [role="menuitem"], [role="option"], label') || el;
          if (typeof target.click === 'function') target.click();
          else target.dispatchEvent(new MouseEvent('click', o));
        })(\(x), \(y));
        """)
    }

    /// 커서가 지나갈 때 마우스 오버 효과 (메시지 복사 버튼 등이 보이도록)
    func hover(at p: CGPoint) {
        guard Date().timeIntervalSince(lastHover) > 0.12 else { return }
        lastHover = Date()
        let (x, y) = pt(p)
        run("""
        (function(x,y){
          var el = document.elementFromPoint(x,y);
          if (!el) return;
          var o = {bubbles:true, composed:true, clientX:x, clientY:y, view:window, pointerType:'mouse', pointerId:1, isPrimary:true};
          el.dispatchEvent(new PointerEvent('pointermove', o));
          el.dispatchEvent(new MouseEvent('mousemove', o));
          el.dispatchEvent(new MouseEvent('mouseover', o));
        })(\(x), \(y));
        """)
    }
}

// MARK: - 외부 모니터 (모니터 해상도 그대로 꽉 차게)

final class ExternalDisplay {
    static let shared = ExternalDisplay()
    weak var controller: ExternalViewController?
    var isConnected: Bool { controller != nil }
}

final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        ws.screen.overscanCompensation = .none
        let w = UIWindow(windowScene: ws)
        let vc = ExternalViewController()
        w.rootViewController = vc
        w.isHidden = false
        window = w
        ExternalDisplay.shared.controller = vc
        NotificationCenter.default.post(name: .externalDisplayChanged, object: nil)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.controller = nil
        NotificationCenter.default.post(name: .externalDisplayChanged, object: nil)
        window = nil
    }
}

final class ExternalViewController: UIViewController {
    private let cursor = CAShapeLayer()
    private let notice = UILabel()
    private(set) var cursorPoint = CGPoint(x: 400, y: 300)

    /// 로그인 화면처럼 아이폰에서 직접 조작해야 할 때 모니터에 안내 표시
    func showPhoneNotice(_ show: Bool) {
        if notice.superview == nil {
            notice.text = "아이폰 화면에서 로그인을 진행해 주세요"
            notice.textColor = .white
            notice.font = .systemFont(ofSize: 32, weight: .semibold)
            notice.textAlignment = .center
            notice.backgroundColor = .black
            notice.frame = view.bounds
            notice.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(notice)
        }
        notice.isHidden = !show
        cursor.isHidden = show
        if !show { WebViewStore.shared.attach(to: view) }
        view.bringSubviewToFront(notice)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        WebViewStore.shared.attach(to: view)

        // 화살표 모양 커서 (끝점이 클릭 위치)
        let p = UIBezierPath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 24))
        p.addLine(to: CGPoint(x: 6, y: 18))
        p.addLine(to: CGPoint(x: 10, y: 27))
        p.addLine(to: CGPoint(x: 14, y: 25))
        p.addLine(to: CGPoint(x: 10, y: 17))
        p.addLine(to: CGPoint(x: 18, y: 17))
        p.close()
        cursor.path = p.cgPath
        cursor.fillColor = UIColor.black.cgColor
        cursor.strokeColor = UIColor.white.cgColor
        cursor.lineWidth = 1.5
        cursor.zPosition = 1000
        view.layer.addSublayer(cursor)
        updateCursor()
    }

    private var pending = CGPoint.zero
    private var displayLink: CADisplayLink?
    private(set) var lastMove = Date.distantPast
    var onCursorMoved: (() -> Void)?

    /// 마우스 신호를 모아두고 화면 갱신 때 한 번에 이동 (끊김 방지)
    func addMouseDelta(dx: CGFloat, dy: CGFloat) {
        let v = hypot(dx, dy)
        let gain = Settings.mouseSpeed * (1 + min(v, 24) / 10)   // 가속
        pending.x += dx * gain
        pending.y += dy * gain
        lastMove = Date()
        if displayLink == nil {
            let link = (view.window?.windowScene?.screen ?? UIScreen.main)
                .displayLink(withTarget: self, selector: #selector(tick))
                ?? CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick() {
        guard pending != .zero else {
            // 0.5초 동안 움직임이 없으면 멈춤 (배터리 절약)
            if Date().timeIntervalSince(lastMove) > 0.5 { displayLink?.invalidate(); displayLink = nil }
            return
        }
        let d = pending
        pending = .zero
        moveCursor(dx: d.x, dy: d.y)
        onCursorMoved?()
    }

    func moveCursor(dx: CGFloat, dy: CGFloat) {
        let b = view.bounds
        cursorPoint.x = min(max(0, cursorPoint.x + dx), b.width - 1)
        cursorPoint.y = min(max(0, cursorPoint.y + dy), b.height - 1)
        updateCursor()
        WebViewStore.shared.hover(at: cursorPoint)
    }

    /// 아이폰 화면에서 가리킨 위치로 커서를 바로 옮김
    func setCursor(_ p: CGPoint) {
        let b = view.bounds
        cursorPoint = CGPoint(x: min(max(0, p.x), b.width - 1), y: min(max(0, p.y), b.height - 1))
        updateCursor()
    }

    private func updateCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 커서 이동 애니메이션 끄기 (반응 속도)
        cursor.position = cursorPoint
        CATransaction.commit()
    }
}

// MARK: - 아이폰 화면

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = PhoneViewController()
        w.makeKeyAndVisible()
        window = w
        // 기기 방향/화면 회전 잠금과 상관없이 가로 모드로 강제 전환
        ws.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (scene as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }
}

/// 블루투스 키보드 입력을 받는 숨은 입력칸 (화면 밖에 있어서 마우스로 눌릴 일 없음)
final class KeyCatcher: UITextView {
    var onEmptyDelete: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?

    override func deleteBackward() {
        if text.isEmpty && markedTextRange == nil { onEmptyDelete?() } else { super.deleteBackward() }
    }

    // ⌘A / ⌘C / ⌘X / ⌘V 를 숨은 입력칸이 아니라 모니터 화면에 적용
    override func selectAll(_ sender: Any?) { onSelectAll?() }
    override func copy(_ sender: Any?) { onCopy?() }
    override func cut(_ sender: Any?) { onCut?() }
    override func paste(_ sender: Any?) { onPaste?() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(selectAll(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:))].contains(action) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// 아이폰 화면: 모니터 연결 시 모니터와 "같은 화면"을 축소해서 보여주고,
/// 아이폰에서 누른 위치 = 모니터의 같은 위치로 클릭이 전달됨
final class PhoneViewController: UIViewController, UITextViewDelegate, UIScrollViewDelegate {
    /// 마우스 휠·손가락 스크롤을 받는 투명한 스크롤 영역
    /// (아이폰은 마우스 휠을 "화면 아래에 있는 스크롤 가능한 뷰"에만 보내기 때문에,
    ///  보이지 않는 스크롤 뷰를 깔아두고 그 움직임을 모니터 스크롤로 옮김)
    private let scrollCatcher = UIScrollView()
    private let scrollDebug = UILabel()
    private var scrollDebugHide: DispatchWorkItem?
    private var lastOffsetY: CGFloat = 0
    private var lastCatcherScroll = Date.distantPast   // 투명 스크롤 영역이 마지막으로 움직인 시각
    private var wheelRemainder: CGFloat = 0             // 휠의 1px 미만 값을 모아두는 곳
    private let scrollCenter: CGFloat = 500_000
    private let webContainer = UIView()
    private let remote = UIView()                 // 모니터 연결 시 화면
    private let preview = UIImageView()           // 모니터 화면 복사본
    private let previewCursor = UIImageView(image: UIImage(systemName: "cursorarrow"))
    private let leftBar = UIStackView()
    private let rightBar = UIStackView()
    private let keyCatcher = KeyCatcher(frame: CGRect(x: -200, y: -200, width: 10, height: 40))
    private var scrollToggle: UIButton!
    private var snapshotTimer: Timer?
    private var snapshotBusy = false
    private var lastHover = Date.distantPast
    private var sentText = ""
    private var allowNewline = false
    private var urlObservation: NSKeyValueObservation?
    private var phoneNative = true   // true: 웹 화면을 아이폰에서 직접 조작

    /// 로그인/인증 화면인지 (가짜 클릭이 막히는 화면 → 아이폰에서 직접 터치해야 함)
    private var needsNativeLogin: Bool {
        guard let url = WebViewStore.shared.webView.url, let host = url.host else { return false }
        if host != "claude.ai" && !host.hasSuffix(".claude.ai") { return true }
        let path = url.path.lowercased()
        return ["/login", "/logout", "/magic-link", "/verify", "/oauth", "/sso"].contains { path.hasPrefix($0) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var external: ExternalViewController? { ExternalDisplay.shared.controller }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebContainer()
        setupRemote()
        setupKeyCatcher()
        setupMouse()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .externalDisplayChanged, object: nil)
        // 페이지 주소가 바뀔 때마다 (로그인 화면 ↔ 채팅 화면) 조작 방식 다시 결정
        urlObservation = WebViewStore.shared.webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    @objc private func refresh() {
        let connected = ExternalDisplay.shared.isConnected
        let native = !connected || needsNativeLogin
        UIApplication.shared.isIdleTimerDisabled = connected

        let web = WebViewStore.shared.webView
        if native {
            // 아이폰에서 직접 조작 (터치·마우스·키보드 모두 아이폰 기본 동작)
            if web.superview !== webContainer {
                snapshotTimer?.invalidate()
                snapshotTimer = nil
                keyCatcher.resignFirstResponder()
                preview.image = nil
                WebViewStore.shared.attach(to: webContainer)
            }
            webContainer.isHidden = false
            remote.isHidden = true
            external?.showPhoneNotice(connected)
        } else if remote.isHidden || web.superview !== external?.view {
            // 모니터에 표시 + 아이폰은 같은 화면 복사본
            external?.showPhoneNotice(false)
            webContainer.isHidden = true
            remote.isHidden = false
            resetTyping()
            keyCatcher.becomeFirstResponder()
            view.setNeedsLayout()
            snapshotTimer?.invalidate()
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updatePreview()
            }
        }
        phoneNative = native
    }

    // MARK: 화면 구성

    private func pin(_ v: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: g.topAnchor),
            v.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: g.trailingAnchor),
        ])
    }

    private func setupWebContainer() { pin(webContainer) }

    private func setupRemote() {
        pin(remote)

        preview.backgroundColor = UIColor(white: 0.1, alpha: 1)
        preview.contentMode = .scaleToFill
        preview.isUserInteractionEnabled = true
        remote.addSubview(preview)

        previewCursor.tintColor = .systemOrange
        previewCursor.frame = CGRect(x: 0, y: 0, width: 16, height: 18)
        previewCursor.contentMode = .scaleAspectFit
        previewCursor.isUserInteractionEnabled = false
        preview.addSubview(previewCursor)

        // 화면 전체를 덮는 투명 스크롤 영역 (휠 + 손가락 스크롤 + 클릭을 여기서 받음)
        scrollCatcher.frame = remote.bounds
        scrollCatcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollCatcher.backgroundColor = .clear
        scrollCatcher.showsVerticalScrollIndicator = false
        scrollCatcher.showsHorizontalScrollIndicator = false
        scrollCatcher.alwaysBounceHorizontal = false
        scrollCatcher.bounces = false
        scrollCatcher.scrollsToTop = false
        scrollCatcher.contentInsetAdjustmentBehavior = .never
        scrollCatcher.delegate = self
        remote.addSubview(scrollCatcher)

        // 아이폰 화면 = 모니터 화면: 누른 위치가 모니터의 같은 위치
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollCatcher.addGestureRecognizer(tap)

        // 양옆 여백 버튼
        scrollToggle = iconButton("arrow.up.arrow.down", #selector(toggleScroll))
        updateScrollToggle()
        configureBar(leftBar, [
            iconButton("plus.bubble", #selector(newChat)),
            iconButton("chevron.left", #selector(goBack)),
            iconButton("keyboard", #selector(toggleSoftKeyboard)),
        ])
        configureBar(rightBar, [
            iconButton("textformat.size.larger", #selector(zoomIn)),
            iconButton("textformat.size.smaller", #selector(zoomOut)),
            scrollToggle,
        ])
        NSLayoutConstraint.activate([
            leftBar.leadingAnchor.constraint(equalTo: remote.leadingAnchor, constant: 2),
            leftBar.centerYAnchor.constraint(equalTo: remote.centerYAnchor),
            rightBar.trailingAnchor.constraint(equalTo: remote.trailingAnchor, constant: -2),
            rightBar.centerYAnchor.constraint(equalTo: remote.centerYAnchor),
        ])
    }

    /// 마우스 연결 중엔 양옆 버튼을 끄고 화면 어디를 클릭하든 화살표 위치 클릭으로 처리
    @objc private func updateMouseMode() {
        DispatchQueue.main.async { [self] in
            let mouse = MouseController.shared.isConnected
            for bar in [leftBar, rightBar] {
                bar.isUserInteractionEnabled = !mouse
                bar.alpha = mouse ? 0.3 : 1
            }
        }
    }

    private func configureBar(_ bar: UIStackView, _ buttons: [UIButton]) {
        buttons.forEach { bar.addArrangedSubview($0) }
        bar.axis = .vertical
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        remote.addSubview(bar)
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0.2, alpha: 1)
        b.layer.cornerRadius = 10
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func updateScrollToggle() {
        scrollToggle.tintColor = Settings.invertScroll ? .systemOrange : .white
    }

    /// 모니터 비율(16:9 등) 그대로, 양옆 버튼 자리를 빼고 최대 크기로 배치
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let monitor = external?.view.bounds.size ?? CGSize(width: 16, height: 9)
        guard monitor.width > 0, monitor.height > 0 else { return }
        let area = remote.bounds.insetBy(dx: 48, dy: 0)
        let s = min(area.width / monitor.width, area.height / monitor.height)
        let size = CGSize(width: monitor.width * s, height: monitor.height * s)
        preview.frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height)
        let w = remote.bounds.width
        if scrollCatcher.contentSize.width != w {
            scrollCatcher.contentSize = CGSize(width: w, height: scrollCenter * 2)
            recenterScroll()
        }
    }

    /// 스크롤 영역을 가운데로 되돌림 (끝에 닿지 않게)
    private func recenterScroll() {
        scrollCatcher.delegate = nil
        scrollCatcher.contentOffset = CGPoint(x: 0, y: scrollCenter)
        lastOffsetY = scrollCenter
        scrollCatcher.delegate = self
    }

    // 투명 스크롤 영역이 움직인 만큼 모니터 화면을 스크롤
    func scrollViewDidScroll(_ sv: UIScrollView) {
        let dy = sv.contentOffset.y - lastOffsetY
        lastOffsetY = sv.contentOffset.y
        guard abs(dy) > 0.1, let ext = external else { return }

        let point: CGPoint
        var amount = dy * monitorPerPreview
        lastCatcherScroll = Date()
        if MouseController.shared.isConnected {
            point = ext.cursorPoint                       // 화살표 위치를 스크롤
            amount = -amount                              // 휠을 아래로 굴리면 페이지 아래로
            if Settings.invertScroll { amount = -amount }  // ⌘⇧S 로 방향 반전
        } else {
            let loc = sv.panGestureRecognizer.location(in: preview)
            point = toMonitor(loc) ?? ext.cursorPoint     // 손가락 위치를 스크롤
        }
        let input = Int(amount.rounded())
        WebViewStore.shared.scroll(by: amount, at: point) { [weak self] r in
            self?.showScrollDebug("스크롤 입력 \(input)px → \(r)")
        }

        // 끝 쪽에 가까워지면 가운데로 되돌림
        if abs(sv.contentOffset.y - scrollCenter) > scrollCenter * 0.8 { recenterScroll() }
    }

    /// 화면 아래에 잠깐 표시 (스크롤이 안 될 때 원인 확인용)
    private func showScrollDebug(_ text: String) {
        if scrollDebug.superview == nil {
            scrollDebug.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            scrollDebug.textColor = .systemGreen
            scrollDebug.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            scrollDebug.isUserInteractionEnabled = false
            remote.addSubview(scrollDebug)
        }
        scrollDebug.text = " " + text + " "
        scrollDebug.sizeToFit()
        scrollDebug.frame.origin = CGPoint(x: preview.frame.minX + 4, y: preview.frame.maxY - scrollDebug.frame.height - 4)
        scrollDebug.isHidden = false
        scrollDebugHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrollDebug.isHidden = true }
        scrollDebugHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func scrollViewDidEndDecelerating(_ sv: UIScrollView) { recenterScroll() }
    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { recenterScroll() }
    }

    // MARK: 모니터 → 아이폰 화면 복사

    private func updatePreview() {
        guard !snapshotBusy, let ext = external else { return }
        if Date().timeIntervalSince(ext.lastMove) < 0.08 { return }
        if preview.bounds.width < 1 { view.setNeedsLayout(); return }
        snapshotBusy = true
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(preview.bounds.width))
        config.afterScreenUpdates = false
        WebViewStore.shared.webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotBusy = false
            if let image { self.preview.image = image }
            self.updatePreviewCursor()
        }
    }

    // MARK: 좌표 변환 (아이폰 화면 ↔ 모니터)

    private func toMonitor(_ p: CGPoint) -> CGPoint? {
        guard let ext = external, preview.bounds.width > 0 else { return nil }
        let m = ext.view.bounds.size
        return CGPoint(x: p.x / preview.bounds.width * m.width, y: p.y / preview.bounds.height * m.height)
    }

    private func toPreview(_ p: CGPoint) -> CGPoint {
        guard let ext = external, ext.view.bounds.width > 0 else { return .zero }
        let m = ext.view.bounds.size
        return CGPoint(x: p.x / m.width * preview.bounds.width, y: p.y / m.height * preview.bounds.height)
    }

    private var monitorPerPreview: CGFloat {
        guard let ext = external, preview.bounds.width > 0 else { return 1 }
        return ext.view.bounds.width / preview.bounds.width
    }

    /// 화살표 끝이 커서 위치에 오도록
    private func updatePreviewCursor() {
        guard let ext = external else { return }
        let p = toPreview(ext.cursorPoint)
        previewCursor.frame.origin = CGPoint(x: p.x - 3, y: p.y - 2)
    }

    /// 모니터 커서 위치를 클릭
    private func clickAtCursor() {
        guard !phoneNative, let ext = external else { return }
        resetTyping()   // 다른 칸을 누르면 입력 기록 초기화
        WebViewStore.shared.click(at: ext.cursorPoint)
        keyCatcher.becomeFirstResponder()
        updatePreview()
    }

    // MARK: 손가락 터치 → 누른 위치 그대로 모니터에 클릭
    // (마우스 클릭은 아이폰 기본 포인터가 아니라 화살표 커서 위치로 처리)

    // 마우스 클릭은 iOS가 "회색 포인터 위치의 터치"로만 앱에 전달함 (버튼 신호는 안 옴)
    // → 마우스 연결 중에는 이 터치를 "주황 화살표 위치 클릭"으로 바꿔서 처리
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let ext = external else { return }
        if MouseController.shared.isConnected {
            clickAtCursor()                       // 커서는 움직이지 않고 화살표 위치 클릭
            return
        }
        // 마우스 없을 때: 손가락으로 누른 위치 그대로 클릭
        let loc = g.location(in: preview)
        guard preview.bounds.contains(loc), let p = toMonitor(loc) else { return }
        ext.setCursor(p)
        updatePreviewCursor()
        clickAtCursor()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let ext = external else { return }
        let t = g.translation(in: preview)
        g.setTranslation(.zero, in: preview)
        if MouseController.shared.isConnected {
            // 휠 신호가 따로 오고 있으면 중복 스크롤 방지
            guard Date().timeIntervalSince(MouseController.shared.lastScroll) > 0.3 else { return }
            // 마우스 휠: 아래로 굴리면 페이지 아래로 (반대면 ⌘⇧S)
            let dir: CGFloat = Settings.invertScroll ? -1 : 1
            WebViewStore.shared.scroll(by: t.y * monitorPerPreview * dir, at: ext.cursorPoint)
            return
        }
        // 손가락: 위로 쓸어올리면 아래 내용이 올라옴 (아이폰과 같은 방향)
        guard let p = toMonitor(g.location(in: preview)) else { return }
        WebViewStore.shared.scroll(by: -t.y * monitorPerPreview, at: p)
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard GCMouse.mice().isEmpty else { return }   // 블루투스 마우스가 있으면 화살표 커서 기준
        guard let p = toMonitor(g.location(in: preview)), let ext = external else { return }
        lastHover = Date()
        ext.setCursor(p)
        WebViewStore.shared.hover(at: p)
    }

    // MARK: 블루투스 마우스 (휠 스크롤 + 커서 표시 보조)

    private func setupMouse() {
        let mouse = MouseController.shared
        // 마우스 움직임을 직접 받아서 화살표 커서를 이동 → 화면 방향(가로)과 항상 일치
        mouse.onMove = { [weak self] dx, dy in
            guard let self, !self.phoneNative, let ext = self.external else { return }
            ext.onCursorMoved = { [weak self] in self?.updatePreviewCursor() }
            ext.addMouseDelta(dx: dx, dy: dy)
        }
        mouse.onClick = nil   // 클릭은 handleTap 한 곳에서만 처리 (두 번 눌림 방지)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMouseMode), name: .GCMouseDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMouseMode), name: .GCMouseDidDisconnect, object: nil)
        updateMouseMode()
        // 마우스 휠 신호 (원인: 휠을 멈출 때 0 값 신호가 같이 오고, 실제 값은 1px 미만으로 작아서
        //  페이지가 0px만 움직이고 있었음 → 0은 무시하고, 작은 값은 모아서 1px 이상일 때 이동)
        mouse.onScroll = { [weak self] dy in
            guard let self, !self.phoneNative, let ext = self.external, dy != 0 else { return }
            // 투명 스크롤 영역이 휠을 이미 받고 있으면 그쪽을 사용 (두 번 스크롤 방지)
            guard Date().timeIntervalSince(self.lastCatcherScroll) > 0.2 else { return }
            let raw = (Settings.invertScroll ? dy : -dy) * Settings.scrollSpeed   // 휠 아래 → 페이지 아래
            self.wheelRemainder += raw
            let step = self.wheelRemainder.rounded(.towardZero)
            guard step != 0 else { return }
            self.wheelRemainder -= step
            WebViewStore.shared.scroll(by: step, at: ext.cursorPoint) { [weak self] r in
                self?.showScrollDebug("휠 y=\(String(format: "%.3f", Double(dy))) \(Int(step))px → \(r)")
            }
        }
        mouse.start()
    }

    // MARK: 키보드 → 모니터

    private func setupKeyCatcher() {
        keyCatcher.delegate = self
        keyCatcher.autocorrectionType = .no
        keyCatcher.autocapitalizationType = .none
        keyCatcher.spellCheckingType = .no
        keyCatcher.smartQuotesType = .no
        keyCatcher.smartDashesType = .no
        keyCatcher.smartInsertDeleteType = .no
        keyCatcher.inputView = UIView()   // 화면 키보드 숨김 (블루투스 키보드 사용)
        keyCatcher.inputAssistantItem.leadingBarButtonGroups = []
        keyCatcher.inputAssistantItem.trailingBarButtonGroups = []
        keyCatcher.onEmptyDelete = { WebViewStore.shared.edit(delete: 1, insert: "") }
        keyCatcher.onSelectAll = { [weak self] in
            self?.resetTyping()
            WebViewStore.shared.selectAll()
        }
        keyCatcher.onCopy = { [weak self] in
            self?.resetTyping()
            WebViewStore.shared.selectedText { text in
                if !text.isEmpty { UIPasteboard.general.string = text }
            }
        }
        keyCatcher.onCut = { [weak self] in
            self?.resetTyping()
            WebViewStore.shared.selectedText { text in
                guard !text.isEmpty else { return }
                UIPasteboard.general.string = text
                WebViewStore.shared.deleteSelection()
            }
        }
        keyCatcher.onPaste = { [weak self] in
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            self?.resetTyping()
            WebViewStore.shared.edit(delete: 0, insert: text)
        }
        view.addSubview(keyCatcher)
    }

    // MARK: 방향키 (Shift = 선택, ⌘ = 줄 처음/끝·문서 처음/끝, ⌥ = 단어 단위)

    private func arrowCommands() -> [UIKeyCommand] {
        let arrows: [(String, String, String)] = [   // (키, 방향, 세로 방향)
            (UIKeyCommand.inputLeftArrow, "backward", ""),
            (UIKeyCommand.inputRightArrow, "forward", ""),
            (UIKeyCommand.inputUpArrow, "backward", "v"),
            (UIKeyCommand.inputDownArrow, "forward", "v"),
        ]
        let mods: [UIKeyModifierFlags] = [[], .shift, .command, [.command, .shift], .alternate, [.alternate, .shift]]
        var list: [UIKeyCommand] = []
        for (input, _, _) in arrows {
            for m in mods {
                list.append(UIKeyCommand(input: input, modifierFlags: m, action: #selector(handleArrow(_:))))
            }
        }
        return list
    }

    @objc private func handleArrow(_ cmd: UIKeyCommand) {
        resetTyping()   // 한글 조합 중이면 확정 후 이동
        let f = cmd.modifierFlags
        let vertical = cmd.input == UIKeyCommand.inputUpArrow || cmd.input == UIKeyCommand.inputDownArrow
        let back = cmd.input == UIKeyCommand.inputLeftArrow || cmd.input == UIKeyCommand.inputUpArrow
        let granularity: String
        if f.contains(.command) {
            granularity = vertical ? "documentboundary" : "lineboundary"
        } else if f.contains(.alternate) {
            granularity = vertical ? "paragraphboundary" : "word"
        } else {
            granularity = vertical ? "line" : "character"
        }
        WebViewStore.shared.moveCaret(extend: f.contains(.shift),
                                      direction: back ? "backward" : "forward",
                                      granularity: granularity)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" && !allowNewline {
            DispatchQueue.main.async { self.send() }
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) { syncText() }

    /// 바뀐 부분만 모니터 입력창에 반영 (한글 조합 중에도 실시간 표시)
    private func syncText(final: Bool = false) {
        // 맨 끝 공백만 단독으로 넣으면 웹 입력창이 지워버려서,
        // 끝 공백은 다음 글자가 올 때 그 글자와 함께 넣음 (입력을 마칠 때는 그대로 반영)
        var now = keyCatcher.text ?? ""
        if !final { while now.hasSuffix(" ") { now.removeLast() } }
        let prefix = zip(sentText, now).prefix { $0 == $1 }.count
        let del = sentText.count - prefix
        let ins = String(now.dropFirst(prefix))
        guard del > 0 || !ins.isEmpty else { return }
        WebViewStore.shared.edit(delete: del, insert: ins)
        sentText = now
    }

    private func resetTyping() {
        keyCatcher.unmarkText()
        syncText(final: true)
        keyCatcher.text = ""
        sentText = ""
    }

    private func send() {
        resetTyping()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WebViewStore.shared.pressSend() }
    }

    @objc private func insertNewline() {
        allowNewline = true
        keyCatcher.insertText("\n")
        allowNewline = false
    }

    override var keyCommands: [UIKeyCommand]? {
        let list = [
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertNewline)),
            UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(newChat)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(goBack)),
            UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(zoomIn)),
            UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(zoomOut)),
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(reload)),
            UIKeyCommand(input: "s", modifierFlags: [.command, .shift], action: #selector(toggleScrollKey)),
            // 키보드로 스크롤: Page Up/Down, Ctrl + ↑/↓
            UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(scrollUpKey)),
            UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(scrollDownKey)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .control, action: #selector(scrollUpKey)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .control, action: #selector(scrollDownKey)),
        ]
        let all = list + arrowCommands()
        all.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return all
    }

    // MARK: 버튼 / 단축키

    /// 아이폰 화면 버튼: 마우스 클릭(회색 포인터)으로 눌린 거면 무시, 손가락 터치일 때만 실행
    private func afterMouseCheck(_ action: @escaping () -> Void) {
        guard !MouseController.shared.clickedJustNow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !MouseController.shared.clickedJustNow else { return }
            action()
        }
    }

    @objc private func newChat() {
        afterMouseCheck { [self] in resetTyping(); WebViewStore.shared.newChat(); keyCatcher.becomeFirstResponder() }
    }
    @objc private func goBack() {
        afterMouseCheck { [self] in WebViewStore.shared.goBack(); keyCatcher.becomeFirstResponder() }
    }
    @objc private func reload() { WebViewStore.shared.reload() }
    @objc private func zoomIn() {
        afterMouseCheck { [self] in WebViewStore.shared.changeZoom(by: 0.1); keyCatcher.becomeFirstResponder() }
    }
    @objc private func zoomOut() {
        afterMouseCheck { [self] in WebViewStore.shared.changeZoom(by: -0.1); keyCatcher.becomeFirstResponder() }
    }

    @objc private func scrollUpKey() { keyScroll(-400) }
    @objc private func scrollDownKey() { keyScroll(400) }

    private func keyScroll(_ amount: CGFloat) {
        guard !phoneNative, let ext = external else { return }
        WebViewStore.shared.scroll(by: amount, at: ext.cursorPoint) { [weak self] r in
            self?.showScrollDebug("키보드 스크롤 \(Int(amount))px → \(r)")
        }
    }

    @objc private func toggleScrollKey() {
        Settings.invertScroll.toggle()
        updateScrollToggle()
    }

    @objc private func toggleScroll() {
        afterMouseCheck { [self] in
            Settings.invertScroll.toggle()
            updateScrollToggle()
            keyCatcher.becomeFirstResponder()
        }
    }

    @objc private func toggleSoftKeyboard() {
        afterMouseCheck { [self] in
            keyCatcher.inputView = keyCatcher.inputView == nil ? UIView() : nil
            keyCatcher.reloadInputViews()
            keyCatcher.becomeFirstResponder()
        }
    }
}
