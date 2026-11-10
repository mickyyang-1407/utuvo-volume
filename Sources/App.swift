import AppKit
import WebKit
import Carbon.HIToolbox
import ServiceManagement

// UTUVO Volume — 選單列上的液態玻璃音量滑桿，可以取代系統的音量調節：
// 鍵盤音量鍵由它接手（需要「輔助使用」權限）、可自訂全域快速鍵、按鍵時滑桿會自己浮出來。

// MARK: - 全域快速鍵（Carbon，不需要任何權限）

final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var repeats: Set<UInt32> = []
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var timer: Timer?
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeys.shared.fire(hk.id, pressed: GetEventKind(ev) == UInt32(kEventHotKeyPressed))
            return noErr
        }, 2, &specs, nil, nil)
    }

    private func fire(_ id: UInt32, pressed: Bool) {
        timer?.invalidate(); timer = nil
        guard pressed, let h = handlers[id] else { return }
        h()
        guard repeats.contains(id) else { return }           // 按住不放會連續調
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in h() }
        }
    }

    /// keyCode 給 nil＝取消這組快速鍵。回傳 false＝這組按鍵被系統或別的 App 佔用了。
    @discardableResult func set(id: UInt32, keyCode: UInt32?, mods: UInt32, repeating: Bool, handler: @escaping () -> Void) -> Bool {
        install()
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        handlers[id] = handler
        if repeating { repeats.insert(id) }
        guard let kc = keyCode else { return true }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(kc, mods, EventHotKeyID(signature: OSType(0x5554_5656), id: id), GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }
}

enum KeyLabel {
    private static let special: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
    static func isFunctionKey(_ code: UInt16) -> Bool { special[code]?.hasPrefix("F") == true }
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
    static func text(_ e: NSEvent) -> String {
        var s = ""
        if e.modifierFlags.contains(.control) { s += "⌃" }
        if e.modifierFlags.contains(.option) { s += "⌥" }
        if e.modifierFlags.contains(.shift) { s += "⇧" }
        if e.modifierFlags.contains(.command) { s += "⌘" }
        return s + (special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased())
    }
}

// MARK: - 浮出來的滑桿視窗

final class SliderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 鍵盤音量鍵的攔截點。回傳 nil＝這個按鍵由我們處理，系統不再處理。
private func mediaTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let d = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = d.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
    let key = (ns.data1 & 0xFFFF_0000) >> 16, flags = ns.data1 & 0xFFFF
    guard key == 0 || key == 1 || key == 7 else { return pass }          // 音量大、音量小、靜音
    guard d.takeKeys, d.audio.supported else { return pass }               // 調不動的裝置交還系統
    if ((flags & 0xFF00) >> 8) == 0xA {                                    // 按下（含按住重複）
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        d.step(key == 7 ? .mute : (key == 0 ? .up : .down), fine: fine)
    }
    return nil
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    enum Action: UInt32, CaseIterable { case up = 0, down, mute, toggle
        var key: String { ["up", "down", "mute", "toggle"][Int(rawValue)] }
    }
    static let widths: [CGFloat] = [230, 290, 360]

    let audio = SystemVolume()
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var panel: SliderPanel!
    var webView: WKWebView!
    var pageReady = false
    var interactive = false
    var hideTimer: Timer?
    var outsideMonitor: Any?
    var keyMonitor: Any?
    var tap: CFMachPort?
    var trustTimer: Timer?
    var guideWindow: NSWindow?
    var guideView: WKWebView?
    var recording: Action?
    var hotkeyFailed: String?

    var takeKeys: Bool { defaults.object(forKey: "takeKeys") as? Bool ?? true }
    var sizeIndex: Int { min(2, max(0, defaults.integer(forKey: "size"))) }
    var panelSize: NSSize { let w = Self.widths[sizeIndex]; return NSSize(width: w, height: (w * 0.5).rounded() + 48) }

    func applicationDidFinishLaunching(_ note: Notification) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "vol")
        webView = WKWebView(frame: NSRect(origin: .zero, size: panelSize), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        let page = Bundle.main.url(forResource: "slider", withExtension: "html")!
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        panel = SliderPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 18; glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(webView)
        panel.contentView = glass

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel("UTUVO Volume")
        }
        audio.onChange = { [weak self] in self?.push(snap: false) }
        refreshIcon()
        applyHotKeys()
        ensureTap()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--device-name"), i + 1 < args.count { _ = audio.useDevice(named: args[i + 1]) }   // 測試用
        if let i = args.firstIndex(of: "--gui-selftest"), i + 1 < args.count { runGUISelfTest(shotDir: args[i + 1]); return }
        if !defaults.bool(forKey: "guideShown") {
            defaults.set(true, forKey: "guideShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showGuide() }
        }
    }

    // MARK: 音量

    func step(_ a: Action, fine: Bool = false) {
        switch a {
        case .toggle: togglePanel(); return
        case .mute: audio.muted.toggle()
        case .up, .down:
            guard audio.supported, let v = audio.volume else { NSSound.beep(); return }
            let s: Float32 = fine ? 1.0 / 64 : 1.0 / 16                     // 跟系統一樣 16 格；⌥⇧ 是四分之一格
            let n = ((v / s).rounded() + (a == .up ? 1 : -1)) * s
            audio.setVolume(n)
            if a == .up, audio.muted { audio.muted = false }
        }
        push(snap: false)
        showPanel(interactive: false)
    }

    private func refreshIcon() {
        let v = audio.volume ?? 0
        let name: String
        if !audio.supported { name = "speaker.badge.exclamationmark.fill" }
        else if audio.muted || v <= 0.001 { name = "speaker.slash.fill" }
        else if v < 0.34 { name = "speaker.wave.1.fill" }
        else if v < 0.67 { name = "speaker.wave.2.fill" }
        else { name = "speaker.wave.3.fill" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "UTUVO Volume")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    private func js(_ view: WKWebView?, _ call: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let json = String(data: data, encoding: .utf8) else { return }
        view?.evaluateJavaScript("\(call)(\(json))", completionHandler: nil)
    }

    private func push(snap: Bool) {
        refreshIcon()
        guard pageReady else { return }
        js(webView, "window.__native && window.__native.set", ["v": Double(audio.volume ?? 0), "muted": audio.muted, "supported": audio.supported,
                                                                "device": audio.deviceName, "snap": snap])
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if message.name == "guide" { guideMessage(m); return }
        if m["ready"] != nil {
            pageReady = true
            push(snap: true)
            webView.evaluateJavaScript("window.__native.pause(\(panel.isVisible ? "false" : "true"))", completionHandler: nil)
        }
        if let v = m["v"] as? Double {
            audio.setVolume(Float32(v))
            if v > 0.001, audio.muted { audio.muted = false }
            refreshIcon()
        }
        if m["mute"] != nil { audio.muted.toggle(); push(snap: false) }
    }

    // MARK: 滑桿視窗

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true { showMenu() }
        else { togglePanel() }
    }

    private func togglePanel() {
        if panel.isVisible && interactive { hidePanel() } else { showPanel(interactive: true) }
    }

    /// interactive＝使用者點開的（留著，點外面或按 Esc 才關）；否則是按音量鍵浮出來的（1.5 秒後自己收）。
    func showPanel(interactive wantInteractive: Bool) {
        let size = panelSize
        var origin = NSPoint(x: 200, y: 200)
        if let bw = statusItem.button?.window, let screen = bw.screen ?? NSScreen.main {
            let f = bw.frame, vis = screen.visibleFrame
            origin.x = min(max(f.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
            origin.y = f.minY - 6 - size.height
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            push(snap: true)
            webView.evaluateJavaScript("window.__native && window.__native.pause(false)", completionHandler: nil)
        }
        hideTimer?.invalidate(); hideTimer = nil
        if wantInteractive {
            interactive = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(webView)
            webView.evaluateJavaScript("document.getElementById('stage').focus()", completionHandler: nil)
            if outsideMonitor == nil {
                outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hidePanel() }
            }
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    if e.keyCode == 53, self?.panel.isKeyWindow == true { self?.hidePanel(); return nil }
                    return e
                }
            }
        } else {
            panel.orderFrontRegardless()                                   // 不搶焦點
            if !interactive {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.panel.frame.contains(NSEvent.mouseLocation) { return }     // 滑鼠停在上面就先不收
                    self.hidePanel()
                }
            }
        }
    }

    func hidePanel() {
        hideTimer?.invalidate(); hideTimer = nil
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        interactive = false
        panel.orderOut(nil)
        webView.evaluateJavaScript("window.__native && window.__native.pause(true)", completionHandler: nil)   // 收起來就停止算圖
    }

    private func showMenu() {
        let menu = NSMenu()
        let guide = NSMenuItem(title: "設定與教學 Settings & Guide…", action: #selector(showGuide), keyEquivalent: ",")
        guide.target = self
        menu.addItem(guide)
        let login = NSMenuItem(title: "登入時啟動 Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let about = NSMenuItem(title: "UTUVO Volume \(ver)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        pushGuide()
    }

    // MARK: 鍵盤音量鍵（需要「輔助使用」權限）

    /// 有權限就把攔截點裝起來；沒有就每 2 秒看一次，使用者一打開權限馬上生效，不用重開 App。
    func ensureTap() {
        if tap == nil, AXIsProcessTrusted() {
            let mask = CGEventMask(1) << 14                                 // 系統定義事件（媒體鍵在這裡面）
            if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                         callback: mediaTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                tap = t
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
                CGEvent.tapEnable(tap: t, enable: true)
            }
        }
        if tap == nil, trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.ensureTap()
                if self.tap != nil { self.trustTimer?.invalidate(); self.trustTimer = nil; self.pushGuide() }
            }
        }
    }

    // MARK: 自訂快速鍵

    func applyHotKeys() {
        var failed: [String] = []
        for a in Action.allCases {
            let code = defaults.object(forKey: "hk.\(a.key).code") as? Int
            let mods = UInt32(defaults.integer(forKey: "hk.\(a.key).mods"))
            let ok = HotKeys.shared.set(id: a.rawValue, keyCode: code.map { UInt32($0) }, mods: mods, repeating: a == .up || a == .down) { [weak self] in self?.step(a) }
            if !ok { failed.append(a.key) }
        }
        hotkeyFailed = failed.first
    }

    private func startRecording(_ a: Action) {
        recording = a
        pushGuide()
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let a = self.recording else { return e }
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if e.keyCode == 53 && mods.isEmpty { self.stopRecording(); return nil }                 // Esc＝取消
            guard !mods.isEmpty || KeyLabel.isFunctionKey(e.keyCode) else { NSSound.beep(); return nil }   // 至少要一個修飾鍵
            self.defaults.set(Int(e.keyCode), forKey: "hk.\(a.key).code")
            self.defaults.set(Int(KeyLabel.carbonMods(mods)), forKey: "hk.\(a.key).mods")
            self.defaults.set(KeyLabel.text(e), forKey: "hk.\(a.key).label")
            self.stopRecording()
            return nil
        }
    }
    private var recordMonitor: Any?
    private func stopRecording() {
        recording = nil
        if let m = recordMonitor { NSEvent.removeMonitor(m); recordMonitor = nil }
        applyHotKeys()
        pushGuide()
    }

    // MARK: 設定與教學視窗

    @objc func showGuide() {
        if guideWindow == nil {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "guide")
            let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 680), configuration: config)
            let page = Bundle.main.url(forResource: "guide", withExtension: "html")!
            v.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "UTUVO Volume — 設定與教學 Settings & Guide"
            w.contentView = v
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            guideWindow = w; guideView = v
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
        pushGuide()
    }

    func windowWillClose(_ notification: Notification) { if recording != nil { stopRecording() } }

    func guideState() -> [String: Any] {
        var hk: [String: String] = [:]
        for a in Action.allCases where defaults.object(forKey: "hk.\(a.key).code") != nil { hk[a.key] = defaults.string(forKey: "hk.\(a.key).label") ?? "?" }
        return ["trusted": AXIsProcessTrusted(), "tapOn": tap != nil, "takeKeys": takeKeys, "login": SMAppService.mainApp.status == .enabled,
                "hotkeys": hk, "size": sizeIndex, "recording": recording?.key ?? "", "failed": hotkeyFailed ?? "",
                "supported": audio.supported, "device": audio.deviceName,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
    }
    func pushGuide() { js(guideView, "window.__guide && window.__guide.set", guideState()) }

    private func guideMessage(_ m: [String: Any]) {
        guard let cmd = m["cmd"] as? String else { return }
        let id = (m["id"] as? String).flatMap { k in Action.allCases.first { $0.key == k } }
        switch cmd {
        case "state": break
        case "ax":                                                          // 請系統跳出授權，並打開設定頁
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            ensureTap()
        case "controlcenter": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
        case "login": toggleLogin(); return
        case "takeKeys": defaults.set(!takeKeys, forKey: "takeKeys")
        case "size": if let n = m["value"] as? Int { defaults.set(n, forKey: "size"); if panel.isVisible { showPanel(interactive: interactive) } }
        case "record": if let id { startRecording(id); return }
        case "clear":
            if let id { for k in ["code", "mods", "label"] { defaults.removeObject(forKey: "hk.\(id.key).\(k)") }; applyHotKeys() }
        case "try": showPanel(interactive: false)
        default: break
        }
        pushGuide()
    }

    // MARK: 測試用：真的打開視窗，從畫面與按鍵兩條路改音量，確認系統音量跟著變再還原，並存下畫面

    private func runGUISelfTest(shotDir: String) {
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func shot(_ view: WKWebView?, _ name: String, _ done: @escaping () -> Void) {
            guard let view else { done(); return }
            view.takeSnapshot(with: nil) { img, _ in
                if let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: shotDir).appendingPathComponent(name))
                }
                done()
            }
        }
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String) { print("\(cond ? "ok  " : "FAIL") \(name) — \(detail)"); if !cond { ok = false } }
        after(1.0) {
            self.showPanel(interactive: true)
            after(2.0) {
                let before = self.audio.volume ?? -1
                print("gui: device=\(self.audio.deviceName) supported=\(self.audio.supported) before=\(before) panel=\(Int(self.panel.frame.width))x\(Int(self.panel.frame.height)) trusted=\(AXIsProcessTrusted()) tap=\(self.tap != nil)")
                check("panel visible + page ready", self.panel.isVisible && self.pageReady, "")
                shot(self.webView, "1-slider.png") {
                    guard self.audio.supported, before >= 0 else {
                        self.showGuide(); after(1.5) { shot(self.guideView, "3-guide.png") { print("GUI SELFTEST DONE (unsupported device)"); exit(ok ? 0 : 1) } }
                        return
                    }
                    // 玻璃從 30% 滑到 70%，每一格都量位置：不准超過 70%，停下來後不准再動
                    let probeJS = "window.__slider.jump(0.3); await new Promise(r => setTimeout(r, 400)); window.__slider.set(0.7); let mx = 0, t0 = performance.now(), last = []; while (performance.now() - t0 < 1500) { await new Promise(r => requestAnimationFrame(r)); const v = window.__slider.get(); mx = Math.max(mx, v); if (performance.now() - t0 > 1100) last.push(v); } return [mx, Math.min(...last), Math.max(...last)];"
                    self.webView.callAsyncJavaScript(probeJS, arguments: [:], in: nil, in: .page) { result in
                        if case .success(let any) = result, let r = any as? [Double], r.count == 3 {
                            check("glass does not overshoot", r[0] <= 0.7005, String(format: "peak %.4f (target 0.7000)", r[0]))
                            check("glass settles and stays still", r[2] - r[1] < 0.002 && abs(r[2] - 0.7) < 0.01, String(format: "last 400 ms range %.4f–%.4f", r[1], r[2]))
                        } else { check("overshoot probe ran", false, "\(result)") }
                        self.afterOvershootProbe(before: before, shot: shot, check: check, after: after) { print(ok ? "GUI SELFTEST PASS" : "GUI SELFTEST FAIL"); exit(ok ? 0 : 1) }
                    }
                }
            }
        }
    }

    private func afterOvershootProbe(before: Float32, shot: @escaping (WKWebView?, String, @escaping () -> Void) -> Void,
                                     check: @escaping (String, Bool, String) -> Void, after: @escaping (Double, @escaping () -> Void) -> Void,
                                     finish: @escaping () -> Void) {
        do { do { do {
                    let probe = before > 0.5 ? before - 0.25 : before + 0.25
                    self.webView.evaluateJavaScript("window.__slider.set(\(probe))", completionHandler: nil)
                    after(1.5) {
                        check("drag in page -> system volume", abs((self.audio.volume ?? -1) - probe) < 0.03, String(format: "want %.3f got %.3f", probe, self.audio.volume ?? -1))
                        self.hidePanel()
                        self.audio.setVolume(0.5)
                        after(0.5) {
                            self.step(.up)                                   // 跟按音量鍵走同一段程式
                            after(0.6) {
                                check("key step up = 1/16", abs((self.audio.volume ?? -1) - 0.5625) < 0.02, String(format: "got %.4f", self.audio.volume ?? -1))
                                check("key press shows panel without click", self.panel.isVisible && !self.interactive, "")
                                self.step(.down); self.step(.down, fine: true)
                                after(0.6) {
                                    check("step down + fine step = 0.5 - 1/64", abs((self.audio.volume ?? -1) - 0.484375) < 0.02, String(format: "got %.4f", self.audio.volume ?? -1))
                                    let regOK = HotKeys.shared.set(id: 0, keyCode: UInt32(kVK_F19), mods: UInt32(controlKey | optionKey), repeating: true) { self.step(.up) }
                                    check("hotkey registers", regOK, "⌃⌥F19")
                                    let src = CGEventSource(stateID: .hidSystemState)
                                    for down in [true, false] {
                                        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F19), keyDown: down)
                                        e?.flags = [.maskControl, .maskAlternate]; e?.post(tap: .cghidEventTap)
                                    }
                                    after(0.8) {
                                        let v = self.audio.volume ?? -1
                                        print(String(format: "info hotkey via posted key event: volume now %.4f (%@)", v, v > 0.5 ? "fired" : "not delivered — posting synthetic keys needs Accessibility on this machine"))
                                        after(1.8) {
                                            check("panel auto-hides after key press", !self.panel.isVisible, "")
                                            self.audio.setVolume(before)
                                            self.showGuide()
                                            after(1.5) {
                                                shot(self.guideView, "3-guide.png") {
                                                    check("volume restored", abs((self.audio.volume ?? -1) - before) < 0.03, String(format: "%.3f", self.audio.volume ?? -1))
                                                    finish()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
