import Foundation
import Observation

/// 앱 전역 상태 (M0 스텁).
///
/// M1+에서 오디오 캡처 상태, 세션 사용량/비용, 현재 입력 소스 등이 추가된다.
@MainActor
@Observable
final class AppState {
    /// 번역 세션 실행 중 여부 (M0: UI 토글 placeholder).
    var isRunning: Bool = false

    /// API 키 로드 성공 여부. 메뉴바에 상태로 표시된다.
    private(set) var apiKeyLoaded: Bool = false

    /// 키 로딩 추상화. 개발 빌드는 .env, 배포 빌드는 Keychain 구현으로 교체 가능.
    private let apiKeyProvider: APIKeyProvider

    init(apiKeyProvider: APIKeyProvider = DotEnvAPIKeyProvider()) {
        self.apiKeyProvider = apiKeyProvider
        // 실행 시 키 로드 시도 (값 자체는 저장하지 않고 로드 여부만 노출).
        self.apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
    }

    /// 필요 시점에 키를 조회한다 (메모리 상주 최소화를 위해 캐싱하지 않음).
    func geminiAPIKey() -> String? {
        apiKeyProvider.geminiAPIKey()
    }
}
