import Foundation

/// API 키 로딩 추상화.
///
/// 메모리/보안 정책상 키 출처를 빌드/환경에 따라 교체할 수 있어야 한다.
/// - 개발: `DotEnvAPIKeyProvider` — 프로젝트 루트 `.env` 파싱.
/// - 배포(M5+): `KeychainAPIKeyProvider`(구현됨) — 사용자 입력 → Keychain 저장.
///   배포 시 `AppState`의 기본 provider만 교체하면 된다.
protocol APIKeyProvider: Sendable {
    /// Gemini API 키. 없으면 nil.
    func geminiAPIKey() -> String?
}

/// 개발용 구현: 프로젝트 루트의 `.env`에서 `GEMINI_API_KEY`를 읽는다.
///
/// 빌드된 `.app`은 번들 내부에서 실행되어 루트 `.env`를 직접 못 찾으므로,
/// 다음 순서로 경로를 탐색한다 (개발 편의 우선):
///   1. 환경변수 `LIVETRANSLATE_ENV_PATH` (파일 직접 지정)
///   2. 소스 파일(`#filePath`) 기준 프로젝트 루트 (`Sources/Config/..` → 루트)
///   3. 현재 작업 디렉토리의 `.env`
///   4. 홈 디렉토리의 `~/.liveTranslate.env`
///
/// ⚠️ 개발 전용. 배포 빌드에서는 Keychain provider로 교체할 것.
struct DotEnvAPIKeyProvider: APIKeyProvider {
    private let key = "GEMINI_API_KEY"

    func geminiAPIKey() -> String? {
        for path in candidateEnvPaths() {
            if let value = parse(path: path, key: key) {
                return value
            }
        }
        return nil
    }

    /// 탐색 후보 경로 목록 (우선순위 순).
    private func candidateEnvPaths() -> [String] {
        var paths: [String] = []

        let env = ProcessInfo.processInfo.environment
        if let override = env[AppConfig.envPathOverrideKey], !override.isEmpty {
            paths.append(override)
        }

        // 소스 파일 기준 프로젝트 루트: .../Sources/Config/APIKeyProvider.swift → 3단계 상위
        let sourceURL = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceURL
            .deletingLastPathComponent() // Config
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // 프로젝트 루트
        paths.append(projectRoot.appendingPathComponent(".env").path)

        // 현재 작업 디렉토리
        paths.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env").path
        )

        // 홈 디렉토리 fallback
        paths.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".liveTranslate.env").path
        )

        return paths
    }

    /// `.env` 파일을 단순 파싱해 주어진 키의 값을 반환한다.
    /// - `KEY=VALUE` 형식, `#` 주석/빈 줄 무시, 값의 양쪽 따옴표 제거.
    private func parse(path: String, key: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let lineKey = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard lineKey == key else { continue }

            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // 인라인 주석 제거(따옴표로 감싸지 않은 경우만 단순 처리는 생략 — 개발용)
            value = stripQuotes(value)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 값 양쪽을 감싼 동일한 따옴표("..." 또는 '...')를 제거한다.
    private func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!
        let last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
