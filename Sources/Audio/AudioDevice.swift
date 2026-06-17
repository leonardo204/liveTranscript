import Foundation
import CoreAudio

/// 입력 가능한 오디오 장치 1개 (스펙 §5.2).
///
/// 마이크는 물론 BlackHole 같은 가상 루프백 장치도 "입력 채널이 있는 장치"로
/// 동일하게 열거된다. UID는 장치 재연결/재부팅에도 안정적인 식별자라 설정 영속화에 적합.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// 이름으로 BlackHole(또는 유사 가상 루프백)을 추정한다.
    /// M1a에서는 UI 표기/자동선택 힌트 용도. 정밀 판별은 M1c 자동선택에서 보강.
    var isLikelyLoopback: Bool {
        let lowered = name.lowercased()
        return lowered.contains("blackhole")
            || lowered.contains("loopback")
            || lowered.contains("soundflower")
            || lowered.contains("aggregate") && lowered.contains("virtual")
    }
}

/// Core Audio HAL 기반 입력 장치 열거기.
///
/// `kAudioHardwarePropertyDevices`로 전체 장치를 받고,
/// 각 장치의 입력 스코프 스트림 구성을 확인해 **입력 채널이 1개 이상인** 장치만 통과시킨다.
enum AudioDeviceEnumerator {

    /// 시스템의 모든 입력 장치를 반환한다 (입력 채널 > 0).
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(of: deviceID) > 0 else { return nil }
            guard let name = stringProperty(deviceID, kAudioObjectPropertyName),
                  let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// 시스템 기본 입력 장치 ID (마이크 기본값).
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Internals

    /// 전체 장치 ID 목록.
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// 입력 스코프 채널 총합. AudioBufferList를 순회해 채널 수를 합산한다.
    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return 0 }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPtr) == noErr
        else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 문자열 프로퍼티(CFString) 조회 헬퍼.
    private static func stringProperty(
        _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: CFString.self, capacity: 1) { _ in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
            }
        }
        guard status == noErr else { return nil }
        return cfString as String?
    }
}
