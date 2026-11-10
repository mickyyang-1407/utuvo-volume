import AppKit

// 自我檢查（不開視窗）：--selftest 只讀；--selftest-set 會暫時改音量再還原
if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-set") {
    let a = SystemVolume()
    if let i = CommandLine.arguments.firstIndex(of: "--device-name"), i + 1 < CommandLine.arguments.count {
        guard a.useDevice(named: CommandLine.arguments[i + 1]) else { print("device not found"); exit(2) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--set"), i + 1 < CommandLine.arguments.count, let v = Float32(CommandLine.arguments[i + 1]) {
        a.setVolume(v)                                   // 測試收尾用：把音量放回原值
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    print("device: \(a.deviceName)")
    print("supported: \(a.supported)")
    print("volume: \(a.volume.map { String(format: "%.3f", $0) } ?? "nil")  muted: \(a.muted)")
    if CommandLine.arguments.contains("--selftest-set"), a.supported, let before = a.volume {
        var heard = 0
        a.onChange = { heard += 1 }
        let probe: Float32 = before > 0.5 ? before - 0.2 : before + 0.2
        let ok = a.setVolume(probe)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let mid = a.volume ?? -1
        a.setVolume(before)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let after = a.volume ?? -1
        print(String(format: "set %.3f -> ok=%@ readback=%.3f  restored=%.3f  listener fired=%d", probe, ok ? "true" : "false", mid, after, heard))
        let pass = ok && abs(mid - probe) < 0.03 && abs(after - before) < 0.03 && heard >= 2
        print(pass ? "SELFTEST PASS" : "SELFTEST FAIL")
        exit(pass ? 0 : 1)
    }
    exit(0)
}

// 測試用：從另一個行程送出一個按鍵，拿來驗證正在執行的 App 有沒有收到。
// --post-key <keyCode> <ctrl|opt|cmd|shift 以逗號分隔>；--post-media <0 音量大｜1 音量小｜7 靜音>
if let i = CommandLine.arguments.firstIndex(of: "--post-key"), i + 2 < CommandLine.arguments.count, let code = UInt16(CommandLine.arguments[i + 1]) {
    var flags: CGEventFlags = []
    for m in CommandLine.arguments[i + 2].split(separator: ",") {
        switch m { case "ctrl": flags.insert(.maskControl); case "opt": flags.insert(.maskAlternate); case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); default: break }
    }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags; e?.post(tap: .cghidEventTap); usleep(60_000)
    }
    print("posted key \(code) trusted=\(AXIsProcessTrusted())"); exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--post-media"), i + 1 < CommandLine.arguments.count, let key = Int(CommandLine.arguments[i + 1]) {
    for state in [0xA, 0xB] {
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                                   windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | (state << 8), data2: -1)
        e?.cgEvent?.post(tap: .cghidEventTap); usleep(60_000)
    }
    print("posted media key \(key) trusted=\(AXIsProcessTrusted())"); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
