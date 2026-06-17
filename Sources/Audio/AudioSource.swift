import Foundation

/// 오디오 캡처 백엔드 공통 인터페이스 (스펙 §4.1, §5.2).
///
/// 마이크 · BlackHole(AVAudioEngine) · ScreenCaptureKit 시스템 오디오를
/// 동일 파이프라인에 연결하기 위한 추상화.
///
/// TODO(M1): 각 백엔드 구현 + 자동 선택(AudioInputManager) + Silero VAD 게이트.
/// 캡처 결과는 16kHz/16-bit/mono PCM 100ms 청크로 콜백된다.
protocol AudioSource: AnyObject {
    /// 16kHz mono 16-bit PCM 청크가 준비될 때마다 호출되는 콜백.
    /// little-endian raw PCM 바이트(100ms 분량)를 전달한다.
    var onPCMChunk: ((Data) -> Void)? { get set }

    /// 캡처 시작. 권한 요청/실패는 throws로 전달.
    func start() throws

    /// 캡처 정지.
    func stop()
}
