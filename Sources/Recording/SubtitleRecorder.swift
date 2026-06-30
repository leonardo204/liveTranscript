import Foundation
import os

/// 확정 자막을 텍스트 파일로 기록하는 녹화기.
///
/// 제어 HUD의 '녹화' 토글이 켜지면 AppState가 `start(url:append:)`로 파일을 열고,
/// SubtitleEngine의 확정 줄 콜백(`onConfirmedLine`)이 들어올 때마다 `writeLine`으로
/// **타임스탬프 + 원문 + 번역문**을 한 줄씩 append 한다. 토글 OFF/세션 정지 시 `stop()`.
///
/// `@MainActor` — 자막 확정 콜백/토글이 모두 메인 액터에서 들어오므로 동기화 부담 없이
/// `FileHandle`을 단일 스레드로 다룬다. 민감정보(키)는 기록하지 않는다(자막 텍스트만).
@MainActor
final class SubtitleRecorder {

    /// 진단 로그용 Logger(녹화 시작/종료/쓰기 실패 추적). 경로 평문/민감값은 로그하지 않는다.
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Recording")

    /// 현재 파일이 열려 기록 가능한 상태인지. 토글/UI가 참조한다.
    private(set) var isOpen: Bool = false

    /// 열린 파일 핸들(닫히면 nil). append/새로쓰기 모두 이 핸들로 write 한다.
    private var fileHandle: FileHandle?

    /// 각 줄 앞에 붙일 타임스탬프 포맷터(HH:mm:ss, 로컬). 1회 생성해 재사용한다.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale.current
        return f
    }()

    /// 녹화 파일을 연다(또는 새로 만든다).
    ///
    /// - append=false: 기존 파일이 있으면 삭제 후 새로 생성한다(새로 쓰기).
    /// - append=true: 기존 파일이 없으면 새로 생성, 있으면 끝(EOF)으로 이동해 이어붙인다.
    /// 성공하면 세션 시작 헤더 1줄을 기록하고 `isOpen=true`로 만든다. 실패는 throw.
    func start(url: URL, append: Bool) throws {
        // 이미 열려 있으면 정리 후 새로 연다(멱등).
        if isOpen { stop() }

        let fm = FileManager.default
        if !append {
            // 새로 쓰기: 기존 파일 제거 후 빈 파일 생성.
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            fm.createFile(atPath: url.path, contents: nil)
        } else if !fm.fileExists(atPath: url.path) {
            // 이어붙이기지만 파일이 없으면 새로 생성.
            fm.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        if append {
            handle.seekToEndOfFile()
        }
        fileHandle = handle
        isOpen = true

        // 세션 시작 헤더(append든 새로든 매 세션 시작 시 1줄).
        writeRaw("===== liveTranslate 녹화 시작 =====\n")
        log.info("\(LogTag.subtitle, privacy: .public) 녹화 시작(append=\(append, privacy: .public))")
    }

    /// 확정 자막 한 줄을 기록한다(타임스탬프 + 원문 + 번역문).
    /// 닫혀 있으면 무시한다. source가 nil/공백뿐이면 번역문만, 아니면 "원문 → 번역문"으로 적는다.
    func writeLine(source: String?, translation: String) {
        guard isOpen else { return }
        let ts = timeFormatter.string(from: Date())
        let prefix = "[\(ts)] "
        let line: String
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line = "\(prefix)\(source) → \(translation)\n"
        } else {
            line = "\(prefix)\(translation)\n"
        }
        writeRaw(line)
    }

    /// 열려 있으면 종료 헤더를 적고 파일을 닫는다(멱등).
    func stop() {
        guard isOpen else { return }
        writeRaw("===== 녹화 종료 =====\n")
        try? fileHandle?.close()
        fileHandle = nil
        isOpen = false
        log.info("\(LogTag.subtitle, privacy: .public) 녹화 종료")
    }

    /// UTF-8로 인코딩해 파일에 쓴다. 실패는 로그만 남기고 무시한다(녹화는 best-effort).
    private func writeRaw(_ text: String) {
        guard let handle = fileHandle, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            log.error("\(LogTag.subtitle, privacy: .public) 녹화 쓰기 실패: \(error.localizedDescription, privacy: .public)")
        }
    }
}
