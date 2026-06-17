import Foundation

/// 캡처 백엔드가 자신을 식별하기 위한 종류 (스펙 §5.2).
enum AudioSourceKind: Sendable, Equatable {
    /// 마이크 등 일반 물리 입력 장치.
    case microphone
    /// BlackHole 등 가상 루프백 입력 장치(시스템 소리 캡처).
    case loopback
    /// Core Audio Tap 시스템 직접 캡처(M1c).
    case systemTap
}

/// 사용자/자동 입력 소스 선택 (스펙 §5.2 자동 선택 규칙).
///
/// - `.auto`: 앱이 판별 — BlackHole 감지 시 BlackHole, 없고 14.4+면 시스템 Tap, 둘 다 아니면 기본 입력.
/// - `.device(uid)`: 특정 입력 장치(마이크/BlackHole)를 수동 강제.
/// - `.systemTap`: Core Audio Tap 시스템 직접 캡처를 수동 강제(14.4+에서만).
enum InputSelection: Sendable, Equatable {
    case auto
    case device(String)
    case systemTap
}

/// 오디오 캡처 백엔드 공통 인터페이스 (스펙 §4.1, §5.2).
///
/// 마이크 · BlackHole(AVAudioEngine) · Core Audio Tap 시스템 오디오를
/// 동일 파이프라인에 연결하기 위한 추상화.
///
/// 모든 백엔드는 캡처 결과를 **16kHz / mono / Float32**, 100ms(1600 samples) 청크로
/// `onChunk` 콜백에 전달한다. Gemini 송신용 Int16 LE 변환은 상위(M2 GeminiLiveClient)가 담당.
///
/// ⚠️ 동시성: `onChunk`는 실시간 오디오 스레드에서 호출될 수 있다.
/// 콜백 내부에서 UI/메인 액터 상태를 직접 만지지 말고 hop 할 것.
protocol AudioSource: AnyObject {
    /// 소스 사람이 읽는 이름 (예: "MacBook Pro Microphone", "BlackHole 2ch").
    var name: String { get }

    /// 소스 종류 (마이크/루프백/시스템탭).
    var kind: AudioSourceKind { get }

    /// 16kHz mono Float32 100ms 청크가 준비될 때마다 호출되는 콜백.
    /// `[Float]`는 정규화된 PCM 샘플(-1.0 ~ 1.0), 길이 = `AppConfig.audioChunkSampleCount`.
    ///
    /// `@Sendable`: 실시간 오디오 스레드에서 호출되므로 캡처 안전성을 컴파일러가 강제하도록 한다.
    var onChunk: (@Sendable ([Float]) -> Void)? { get set }

    /// 캡처 시작. 권한 요청/엔진 실패는 throws로 전달.
    func start() throws

    /// 캡처 정지.
    func stop()
}
