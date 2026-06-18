import CoreAudio
import os

/// 기본 출력 장치의 볼륨을 일시적으로 낮춰(덕킹) 원문(시스템) 소리를 줄인다.
/// 번역 오디오도 같은 장치로 나가므로 함께 작아진다(설계상 부분 덕킹). 정지 시 원래 볼륨 복원.
/// 마스터 볼륨 스칼라를 지원하지 않는 장치(일부 aggregate 등)에서는 조용히 무시한다.
@MainActor
final class SystemAudioDucker {
    private var savedVolume: Float?
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "AudioDucker")

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard st == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func currentVolume() -> Float? {
        guard let dev = defaultOutputDevice() else { return nil }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var vol: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr ? vol : nil
    }

    @discardableResult
    private func setVolume(_ v: Float) -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var vol = max(0, min(1, v))
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol) == noErr
    }

    /// 현재 볼륨을 1회 저장하고 지정 레벨로 덕킹한다(이미 덕킹 중이면 레벨만 갱신).
    func duck(to level: Float) {
        if savedVolume == nil { savedVolume = currentVolume() }
        if !setVolume(level) { log.info("출력 장치 볼륨 제어 미지원 — 덕킹 생략") }
    }

    /// 저장해 둔 원래 볼륨으로 복원한다(없으면 무시).
    func restore() {
        if let v = savedVolume { setVolume(v) }
        savedVolume = nil
    }
}
