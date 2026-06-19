import Foundation
import os

/// Apple Translation(`TranslationSession`) 기반 번역 단계(spec 007 §7.4b).
///
/// 원문 세그먼트 스트림을 받아 번역 세그먼트 스트림을 낸다(isFinal 보존, 세그먼트 교체 모델).
/// 세션 발급은 `@MainActor TranslationSessionHost`(숨은 SwiftUI 호스트)에 위임한다.
///
/// ## 부하 제어 (spec §4/§8)
/// volatile(비-final)은 번역 in-flight 중이면 **드롭**(최신만 의미 있음), isFinal은 **항상 번역**한다.
/// 번역은 순차로 처리하되, 처리 중 도착한 final은 보장해 누락하지 않는다.
///
/// ## 동시성
/// actor 격리. transform 출력 펌프는 입력 스트림 종료로 자연 종료하고, `stop()`은 host teardown만 한다
/// (입력 스트림은 상류 ComposedTranslationProvider가 finish하므로 별도 cancel 불필요).
actor AppleTranslationStage: TextTransformStage {

    private let sourceLanguageCode: String
    private let targetLanguageCode: String
    private let host: TranslationSessionHost

    /// 번역 요청 로그 스로틀. 첫 1회 + N회마다 1회(확정 세그먼트는 항상).
    private var reqLogCount = 0

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    init(sourceLanguageCode: String, targetLanguageCode: String, host: TranslationSessionHost) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.host = host
    }

    nonisolated func transform(_ input: AsyncStream<TextSegmentEvent>) -> AsyncStream<TextSegmentEvent> {
        let host = self.host
        let source = self.sourceLanguageCode
        let target = self.targetLanguageCode

        return AsyncStream<TextSegmentEvent> { continuation in
            let task = Task {
                // 세션 발급 요청(언어 설정). 최초 1회.
                await host.configure(source: source, target: target)

                // 번역은 **확정(isFinal) 세그먼트만** 수행한다(spec §8 튜닝).
                // 이유: 온디바이스 번역이 빨라 volatile(부분 문장)마다 재번역되면, 부분 문장 MT가
                // 비단조적으로 요동쳐 자막이 심하게 깜빡인다. 확정 문장 단위로만 번역하면 안정적이다.
                // (라이브 진행 피드백이 필요하면 '원문 표시'로 STT 원문을 실시간으로 본다 — 원문 세그먼트는
                //  ComposedTranslationProvider가 .sourceSegment로 별도 방출한다.)
                for await ev in input {
                    if Task.isCancelled { break }
                    switch ev {
                    case .segment(let text, let isFinal):
                        guard isFinal else { continue }   // volatile 재번역 깜빡임 제거
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        let out = await host.translate(text) ?? text
                        continuation.yield(.segment(text: out, isFinal: true))
                        await self.logRequest(text: text, isFinal: true)
                    case .info(let msg):
                        continuation.yield(.info(msg))
                    case .failure(let reason):
                        continuation.yield(.failure(reason))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        await host.teardown()
        Self.log.info("\(LogTag.translate, privacy: .public) stage stop(host teardown)")
    }

    private func logRequest(text: String, isFinal: Bool) {
        reqLogCount += 1
        if isFinal || reqLogCount == 1 || reqLogCount % 25 == 0 {
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            Self.log.debug("\(LogTag.translate, privacy: .public) 번역 요청 final=\(isFinal, privacy: .public) n=\(self.reqLogCount, privacy: .public) src=\"\(preview, privacy: .public)\"")
        }
    }
}
