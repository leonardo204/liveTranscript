import Foundation

/// API 키 provider — **사용자 입력 키(Keychain) 전용**.
///
/// 키는 오직 사용자가 설정에서 입력해 Keychain에 저장한 값만 사용한다.
/// 최초 실행 등 저장된 키가 없으면 키 없음(비어 있음) — 사용자가 직접 입력해야 한다.
/// (`.env`는 개발 편의용이었으나, 배포 정책상 사용자 입력으로 일원화하여 폴백 제거.)
///
/// 보안: 어떤 메서드도 키 값을 로그/에러로 노출하지 않는다.
struct ResolvedAPIKeyProvider: APIKeyProvider {

    /// 현재 사용 중인 키의 출처. UI에 "현재: …"로 표시하기 위한 정보(값은 미포함).
    enum KeySource: Sendable, Equatable {
        /// Keychain에 사용자가 저장한 키.
        case keychain
        /// 저장된 키 없음.
        case none

        /// 설정 UI에 표시할 사람이 읽는 라벨.
        var label: String {
            switch self {
            case .keychain: return "저장된 키 사용 중"
            case .none:     return "키 없음 — 키를 입력하세요"
            }
        }
    }

    private let keychain: KeychainAPIKeyProvider

    init(keychain: KeychainAPIKeyProvider = KeychainAPIKeyProvider()) {
        self.keychain = keychain
    }

    // MARK: - APIKeyProvider

    /// Keychain에 저장된 사용자 키를 반환한다. 없으면 nil.
    func geminiAPIKey() -> String? {
        if let key = keychain.geminiAPIKey(), !key.isEmpty {
            return key
        }
        return nil
    }

    // MARK: - 출처/저장 위임

    /// 현재 키 저장 여부를 판별한다(값은 노출하지 않음).
    func currentKeySource() -> KeySource {
        if let key = keychain.geminiAPIKey(), !key.isEmpty {
            return .keychain
        }
        return .none
    }

    /// 사용자 입력 키를 Keychain에 저장한다.
    func save(_ key: String) throws {
        try keychain.save(key)
    }

    /// Keychain에 저장된 키를 삭제한다.
    func clear() throws {
        try keychain.clear()
    }
}
