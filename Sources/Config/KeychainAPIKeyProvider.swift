import Foundation
import Security

/// 배포용 키 저장소: macOS Keychain(Keychain Services)에 Gemini API 키를 안전 저장한다.
///
/// 정책(메모리): 개발은 `.env`, 배포는 사용자 입력 → Keychain.
/// App Sandbox가 꺼져 있으므로 access group 없이 기본 keychain을 사용한다.
///
/// 보안: 키 값은 Keychain에만 두고 평문 로그/에러로 노출하지 않는다.
/// (이 타입은 키를 받아 저장/조회/삭제만 하며 어떤 경우에도 키를 로깅하지 않는다.)
///
/// 항목 식별: `kSecClassGenericPassword` + service(번들 ID) + account(고정 문자열).
struct KeychainAPIKeyProvider: APIKeyProvider {

    /// Keychain 항목의 service 값(기본: 번들 ID).
    private let service: String
    /// Keychain 항목의 account 값(키 종류 구분).
    private let account: String

    /// Keychain 접근 중 발생할 수 있는 오류. 메시지에 키 값을 절대 포함하지 않는다.
    enum KeychainError: Error, LocalizedError {
        /// `SecItem*` 호출이 errSecSuccess 외의 OSStatus를 반환.
        case unexpectedStatus(OSStatus)
        /// 저장하려는 키 문자열을 UTF-8 데이터로 인코딩하지 못함.
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                // OSStatus 코드만 노출(키 비포함).
                return "Keychain 오류 (\(status))"
            case .encodingFailed:
                return "키 인코딩 실패"
            }
        }
    }

    /// - Parameters:
    ///   - service: Keychain service. 기본은 번들 ID(`com.altimedia.liveTranslate`).
    ///   - account: Keychain account. 기본은 `gemini_api_key`.
    init(service: String = AppConfig.bundleIdentifier,
         account: String = "gemini_api_key") {
        self.service = service
        self.account = account
    }

    // MARK: - APIKeyProvider

    /// Keychain에 저장된 Gemini 키를 반환한다. 없으면 nil(폴백은 상위 provider가 처리).
    func geminiAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    // MARK: - 저장/삭제

    /// 키를 Keychain에 저장한다(있으면 갱신, 없으면 추가). 빈 문자열은 거부하지 않고
    /// 호출자(UI)가 trim/검증하도록 둔다 — 다만 공백 제거 후 저장하는 편이 안전하다.
    func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // 먼저 갱신을 시도하고, 항목이 없으면 추가한다.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // 잠금 해제된 동안에만 접근(기본 디바이스 정책). 동기화 비대상.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(updateStatus)
    }

    /// 저장된 키를 삭제한다. 항목이 없으면(이미 비어 있으면) 성공으로 간주한다.
    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 저장된 키 존재 여부(값 자체는 메모리에 올리지 않고 존재만 확인).
    func hasKey() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - 헬퍼

    /// 항목을 유일하게 식별하는 공통 query(class/service/account).
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
