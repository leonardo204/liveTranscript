import Foundation
import Observation

/// 앱 전역 상태 (M0 스텁).
///
/// M1+에서 오디오 캡처 상태, 세션 사용량/비용, 현재 입력 소스 등이 추가된다.
@MainActor
@Observable
final class AppState {
    /// 번역 세션 실행 중 여부. M1a부터 실제 오디오 캡처 상태와 연동된다.
    var isRunning: Bool = false

    /// API 키 로드 성공 여부. 메뉴바에 상태로 표시된다.
    private(set) var apiKeyLoaded: Bool = false

    /// 오디오 입력 캡처 매니저 (M1a). 입력 소스/레벨/start-stop을 소유.
    let audio: AudioInputManager

    /// 키 로딩 추상화. 개발 빌드는 .env, 배포 빌드는 Keychain 구현으로 교체 가능.
    private let apiKeyProvider: APIKeyProvider

    init(apiKeyProvider: APIKeyProvider = DotEnvAPIKeyProvider()) {
        self.apiKeyProvider = apiKeyProvider
        self.audio = AudioInputManager()
        // 실행 시 키 로드 시도 (값 자체는 저장하지 않고 로드 여부만 노출).
        self.apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
    }

    /// 캡처 토글 (메뉴바 "번역 시작/정지"). M1a에서는 오디오 캡처만 켜고 끈다.
    /// M2에서 GeminiLiveClient 연결/해제가 여기에 추가된다.
    func toggleCapture() {
        if audio.isCapturing {
            audio.stop()
            isRunning = false
        } else {
            audio.requestPermissionAndStart()
            // 권한 콜백 후 isCapturing이 true가 되며, UI는 audio.isCapturing을 직접 관찰한다.
            isRunning = true
        }
    }

    /// 필요 시점에 키를 조회한다 (메모리 상주 최소화를 위해 캐싱하지 않음).
    func geminiAPIKey() -> String? {
        apiKeyProvider.geminiAPIKey()
    }
}
