import Foundation
import CoreAudio
import AudioToolbox

// 系統音量（CoreAudio）：讀、寫、監聽目前預設輸出裝置的音量與靜音。

final class SystemVolume {
    var onChange: (() -> Void)?
    private(set) var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    private static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                             _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }
    private var watched: [AudioObjectPropertyAddress] {
        [Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume), Self.addr(kAudioDevicePropertyMute),
         Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1),
         Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2)]
    }

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.rebind(); self?.onChange?() }
        }
        defaultListener = block
        var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        rebind()
    }

    /// 換了預設輸出裝置就把監聽搬到新裝置上。
    private func rebind() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        guard id != device else { return }
        if let old = deviceListener, device != kAudioObjectUnknown {
            for var w in watched { AudioObjectRemovePropertyListenerBlock(device, &w, DispatchQueue.main, old) }
        }
        device = id
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } }
        deviceListener = block
        guard id != kAudioObjectUnknown else { return }
        for var w in watched where AudioObjectHasProperty(id, &w) { AudioObjectAddPropertyListenerBlock(id, &w, DispatchQueue.main, block) }
    }

    private func getFloat(_ a: AudioObjectPropertyAddress) -> Float32? {
        var a = a, v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }
    private func setFloat(_ a: AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var a = a, v = value, settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
    private func settable(_ a: AudioObjectPropertyAddress) -> Bool {
        var a = a, s = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &s) == noErr && s.boolValue
    }

    /// 自我檢查用：改盯指定名稱的裝置（不改系統的預設輸出）。
    func useDevice(named wanted: String) -> Bool {
        var a = Self.addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal), size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            device = AudioObjectID(kAudioObjectUnknown); deviceListener = nil
            device = id
            if deviceName == wanted {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } }
                deviceListener = block
                for var w in watched where AudioObjectHasProperty(id, &w) { AudioObjectAddPropertyListenerBlock(id, &w, DispatchQueue.main, block) }
                return true
            }
        }
        return false
    }

    /// 這個輸出裝置能不能用軟體調音量（很多專業錄音介面不行）。
    var supported: Bool {
        settable(Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
            || settable(Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1))
    }

    var volume: Float32? {
        if let v = getFloat(Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)) { return v }
        let ch = [1, 2].compactMap { getFloat(Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, UInt32($0))) }
        return ch.isEmpty ? nil : ch.reduce(0, +) / Float32(ch.count)
    }

    @discardableResult func setVolume(_ value: Float32) -> Bool {
        let v = max(0, min(1, value))
        if setFloat(Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume), v) { return true }
        var ok = false
        for ch in [UInt32(1), 2] where setFloat(Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch), v) { ok = true }
        return ok
    }

    var muted: Bool {
        get {
            var a = Self.addr(kAudioDevicePropertyMute), m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m) == noErr else { return false }
            return m != 0
        }
        set {
            var a = Self.addr(kAudioDevicePropertyMute), m: UInt32 = newValue ? 1 : 0, s = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &s) == noErr, s.boolValue else { return }
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    var deviceName: String {
        var a = Self.addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard device != kAudioObjectUnknown, AudioObjectGetPropertyData(device, &a, 0, nil, &size, &name) == noErr, let n = name else { return "—" }
        return n.takeRetainedValue() as String
    }
}

