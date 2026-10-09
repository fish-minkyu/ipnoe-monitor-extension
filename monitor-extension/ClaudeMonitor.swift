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
        get { d.bool(forKey: "invertScroll") }
        set { d.set(newValue, forKey: "invertScroll") }
    }
    static var zoom: CGFloat {
        get { let v = d.double(forKey: "zoom"); return v > 0 ? CGFloat(v) : 1.0 }
        set { d.set(Double(newValue), forKey: "zoom") }
    }
    static let mouseSpeed: CGFloat = 1.5   // 마우스 감도
    static let scrollSpeed: CGFloat = 25   // 휠 스크롤 속도
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
        webView.pageZoom = Settings.zoom
        webView.load(URLRequest(url: URL(string: "https://claude.ai")!))
    }

    func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(webView, at: 0)
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

    /// 포커스된 입력칸(없으면 채팅 입력창)에서 글자 지우기/넣기 (한글 조합 중 변화도 반영)
    func edit(delete count: Int, insert text: String) {
        run("""
        (function(n, t){
          var el = document.activeElement;
          var ok = el && (el.isContentEditable || el.tagName === 'INPUT' || el.tagName === 'TEXTAREA');
          if (!ok) {
            el = document.querySelector('div[contenteditable="true"]');
            if (!el) return;
            el.focus();
            var r = document.createRange(); r.selectNodeContents(el); r.collapse(false);
            var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          }
          for (var i = 0; i < n; i++) document.execCommand('delete', false);
          if (t) document.execCommand('insertText', false, t);
        })(\(count), \(jsString(text)));
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

    func scroll(by dy: CGFloat, at p: CGPoint) {
        let (x, y) = pt(p)
        run("""
        (function(x,y,dy){
          var el = document.elementFromPoint(x,y);
          while (el && el !== document.body) {
            var s = getComputedStyle(el);
            if (/(auto|scroll)/.test(s.overflowY) && el.scrollHeight > el.clientHeight) break;
            el = el.parentElement;
          }
          (el && el !== document.body ? el : document.scrollingElement).scrollBy(0, dy);
        })(\(x), \(y), \(dy / webView.pageZoom));
        """)
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
        guard Date().timeIntervalSince(lastHover) > 0.05 else { return }
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
    private(set) var cursorPoint = CGPoint(x: 400, y: 300)

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

    func moveCursor(dx: CGFloat, dy: CGFloat) {
        let b = view.bounds
        cursorPoint.x = min(max(0, cursorPoint.x + dx), b.width - 1)
        cursorPoint.y = min(max(0, cursorPoint.y + dy), b.height - 1)
        updateCursor()
        WebViewStore.shared.hover(at: cursorPoint)
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
    override func deleteBackward() {
        if text.isEmpty && markedTextRange == nil { onEmptyDelete?() } else { super.deleteBackward() }
    }
}

final class PhoneViewController: UIViewController, UITextViewDelegate {
    private let webContainer = UIView()
    private let panel = UIStackView()
    private let trackpad = UIView()
    private let keyCatcher = KeyCatcher(frame: CGRect(x: -200, y: -200, width: 10, height: 40))
    private var invertYButton: UIButton!
    private var invertScrollButton: UIButton!
    private var sentText = ""          // 모니터에 이미 반영된 글자
    private var allowNewline = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebContainer()
        setupPanel()
        setupKeyCatcher()
        setupMouse()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .externalDisplayChanged, object: nil)
        refresh()
    }

    @objc private func refresh() {
        let connected = ExternalDisplay.shared.isConnected
        webContainer.isHidden = connected
        panel.isHidden = !connected
        UIApplication.shared.isIdleTimerDisabled = connected
        if connected {
            resetTyping()
            keyCatcher.becomeFirstResponder()
        } else {
            keyCatcher.resignFirstResponder()
            WebViewStore.shared.attach(to: webContainer)
        }
    }

    // MARK: 화면 구성

    private func setupWebContainer() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webContainer.topAnchor.constraint(equalTo: g.topAnchor),
            webContainer.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: g.trailingAnchor),
        ])
    }

    private func setupPanel() {
        panel.axis = .vertical
        panel.spacing = 8
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            panel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8),
            panel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8),
        ])

        invertYButton = makeButton("", #selector(toggleInvertY))
        invertScrollButton = makeButton("", #selector(toggleInvertScroll))
        updateToggleTitles()

        let bar = UIStackView(arrangedSubviews: [
            makeButton("새 채팅", #selector(newChat)),
            makeButton("뒤로", #selector(goBack)),
            makeButton("글자 −", #selector(zoomOut)),
            makeButton("글자 +", #selector(zoomIn)),
            invertYButton,
            invertScrollButton,
            makeButton("화면 키보드", #selector(toggleSoftKeyboard)),
        ])
        bar.distribution = .fillEqually
        bar.spacing = 6
        panel.addArrangedSubview(bar)

        trackpad.backgroundColor = UIColor(white: 0.12, alpha: 1)
        trackpad.layer.cornerRadius = 16
        let hint = UILabel()
        hint.text = "블루투스 마우스·키보드로 모니터 화면을 조작하세요\n(손가락: 드래그 = 커서 이동 · 탭 = 클릭 · 두 손가락 = 스크롤)\nEnter 전송 · Shift+Enter 줄바꿈"
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.textColor = .gray
        hint.font = .systemFont(ofSize: 14)
        hint.translatesAutoresizingMaskIntoConstraints = false
        trackpad.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: trackpad.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: trackpad.centerYAnchor),
        ])

        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        [move, scroll, tap].forEach { trackpad.addGestureRecognizer($0) }
        panel.addArrangedSubview(trackpad)
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.backgroundColor = UIColor(white: 0.18, alpha: 1)
        b.layer.cornerRadius = 8
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func updateToggleTitles() {
        invertYButton.setTitle(Settings.invertY ? "상하반전 켬" : "상하반전 끔", for: .normal)
        invertScrollButton.setTitle(Settings.invertScroll ? "스크롤반전 켬" : "스크롤반전 끔", for: .normal)
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
        view.addSubview(keyCatcher)
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
    private func syncText() {
        let now = keyCatcher.text ?? ""
        let prefix = zip(sentText, now).prefix { $0 == $1 }.count
        let del = sentText.count - prefix
        let ins = String(now.dropFirst(prefix))
        guard del > 0 || !ins.isEmpty else { return }
        WebViewStore.shared.edit(delete: del, insert: ins)
        sentText = now
    }

    private func resetTyping() {
        keyCatcher.unmarkText()
        syncText()
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

    @objc private func toggleSoftKeyboard() {
        guard !MouseController.shared.clickedJustNow else { return }
        keyCatcher.inputView = keyCatcher.inputView == nil ? UIView() : nil
        keyCatcher.reloadInputViews()
        keyCatcher.becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let list = [
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertNewline)),
            UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(newChatKey)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(goBackKey)),
            UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(zoomInKey)),
            UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(zoomOutKey)),
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(reloadKey)),
        ]
        list.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return list
    }

    // MARK: 마우스 → 모니터

    private var external: ExternalViewController? { ExternalDisplay.shared.controller }

    private func setupMouse() {
        let mouse = MouseController.shared
        mouse.onMove = { [weak self] dx, dy in
            let s = Settings.mouseSpeed
            self?.external?.moveCursor(dx: dx * s, dy: (Settings.invertY ? -dy : dy) * s)
        }
        mouse.onClick = { [weak self] in self?.clickMonitor() }
        mouse.onScroll = { [weak self] dy in
            guard let ext = self?.external else { return }
            let v = (Settings.invertScroll ? -dy : dy) * Settings.scrollSpeed
            WebViewStore.shared.scroll(by: v, at: ext.cursorPoint)
        }
        mouse.start()
    }

    private func clickMonitor() {
        guard let ext = external else { return }
        resetTyping()   // 다른 칸을 클릭하면 입력 기록 초기화
        WebViewStore.shared.click(at: ext.cursorPoint)
        keyCatcher.becomeFirstResponder()
    }

    // 손가락 트랙패드 (마우스 클릭으로 같이 눌린 터치는 무시)
    @objc private func handleMove(_ g: UIPanGestureRecognizer) {
        guard !MouseController.shared.clickedJustNow else { return }
        let t = g.translation(in: trackpad)
        external?.moveCursor(dx: t.x * 2.2, dy: t.y * 2.2)
        g.setTranslation(.zero, in: trackpad)
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        guard let ext = external else { return }
        let t = g.translation(in: trackpad)
        WebViewStore.shared.scroll(by: -t.y * 3, at: ext.cursorPoint)
        g.setTranslation(.zero, in: trackpad)
    }

    @objc private func handleTap() {
        guard !MouseController.shared.clickedJustNow else { return }
        clickMonitor()
    }

    // 버튼 (마우스 클릭으로 같이 눌린 경우 무시)
    private func button(_ f: () -> Void) {
        guard !MouseController.shared.clickedJustNow else { return }
        f()
        keyCatcher.becomeFirstResponder()
    }

    @objc private func newChat() { button { WebViewStore.shared.newChat() } }
    @objc private func goBack() { button { WebViewStore.shared.goBack() } }
    @objc private func zoomIn() { button { WebViewStore.shared.changeZoom(by: 0.1) } }
    @objc private func zoomOut() { button { WebViewStore.shared.changeZoom(by: -0.1) } }
    @objc private func toggleInvertY() { button { Settings.invertY.toggle(); updateToggleTitles() } }
    @objc private func toggleInvertScroll() { button { Settings.invertScroll.toggle(); updateToggleTitles() } }

    // 단축키
    @objc private func newChatKey() { resetTyping(); WebViewStore.shared.newChat() }
    @objc private func goBackKey() { WebViewStore.shared.goBack() }
    @objc private func zoomInKey() { WebViewStore.shared.changeZoom(by: 0.1) }
    @objc private func zoomOutKey() { WebViewStore.shared.changeZoom(by: -0.1) }
    @objc private func reloadKey() { WebViewStore.shared.reload() }
}
