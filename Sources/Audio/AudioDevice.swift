import Foundation
import CoreAudio
import os

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

/// 출력 가능한 오디오 장치 1개 (번역 오디오 출력 라우팅용).
///
/// 스피커/헤드폰은 물론 BlackHole 같은 가상 장치도 "출력 채널이 있는 장치"로 동일하게 열거된다.
/// UID는 장치 재연결/재부팅에도 안정적인 식별자라 설정 영속화에 적합하다.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio HAL 기반 입력 장치 열거기.
///
/// `kAudioHardwarePropertyDevices`로 전체 장치를 받고,
/// 각 장치의 입력 스코프 스트림 구성을 확인해 **입력 채널이 1개 이상인** 장치만 통과시킨다.
enum AudioDeviceEnumerator {

    /// 진단 로그용 Logger(장치 열거/매칭 추적). 민감정보 없음.
    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "AudioDevice")

    /// 시스템의 모든 입력 장치를 반환한다 (입력 채널 > 0).
    static func inputDevices() -> [AudioInputDevice] {
        let devices = allDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
            guard inputChannelCount(of: deviceID) > 0 else { return nil }
            guard let name = stringProperty(deviceID, kAudioObjectPropertyName),
                  let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
        // 진단(1회성 debug): 입력 장치 개수 + 이름 목록.
        log.debug("\(LogTag.audio, privacy: .public) inputDevices: \(devices.count, privacy: .public)개 [\(devices.map(\.name).joined(separator: ", "), privacy: .public)]")
        return devices
    }

    /// 시스템의 모든 출력 장치를 반환한다 (출력 채널 > 0).
    /// 번역 오디오를 특정 스피커/헤드폰으로 라우팅할 때 선택지로 노출한다.
    static func outputDevices() -> [AudioOutputDevice] {
        let devices = allDeviceIDs().compactMap { deviceID -> AudioOutputDevice? in
            guard outputChannelCount(of: deviceID) > 0 else { return nil }
            guard let name = stringProperty(deviceID, kAudioObjectPropertyName),
                  let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioOutputDevice(id: deviceID, uid: uid, name: name)
        }
        // 진단(1회성 debug): 출력 장치 개수 + 이름 목록.
        log.debug("\(LogTag.audio, privacy: .public) outputDevices: \(devices.count, privacy: .public)개 [\(devices.map(\.name).joined(separator: ", "), privacy: .public)]")
        return devices
    }

    /// UID로 출력 장치 ID를 해석한다. 일치하는 출력 장치가 없으면 nil(=시스템 기본 사용).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let id = outputDevices().first(where: { $0.uid == uid })?.id
        // 진단: UID 매칭 성공/실패(라우팅 실패 원인 추적).
        if let id {
            log.debug("\(LogTag.audio, privacy: .public) deviceID(forUID): 매칭 성공 uid=\(uid, privacy: .public) → id=\(id, privacy: .public)")
        } else {
            log.debug("\(LogTag.audio, privacy: .public) deviceID(forUID): 매칭 실패 uid=\(uid, privacy: .public) → 기본 출력")
        }
        return id
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

    /// 출력 스코프 채널 총합. inputChannelCount의 출력 스코프 버전.
    private static func outputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
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
