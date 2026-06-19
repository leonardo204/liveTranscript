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

    /// 번역 요청/스킵 로그 스로틀(고빈도 volatile). 첫 1회 + N회마다 1회.
    private var reqLogCount = 0
    private var skipLogCount = 0

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

                // 부하 제어 상태: 현재 번역 처리 중인지 + 대기 중인 final.
                var inFlight = false
                // 마지막으로 처리하지 못한 입력(volatile은 최신, final은 보장). 처리 후 갱신.
                var pending: (text: String, isFinal: Bool)?

                // 직렬 번역 펌프 — pending을 하나씩 처리한다.
                func drain() async {
                    while let next = pending {
                        pending = nil
                        inFlight = true
                        let out = await host.translate(next.text) ?? next.text
                        continuation.yield(.segment(text: out, isFinal: next.isFinal))
                        await self.logRequest(text: next.text, isFinal: next.isFinal)
                        inFlight = false
                    }
                }

                for await ev in input {
                    if Task.isCancelled { break }
                    switch ev {
                    case .segment(let text, let isFinal):
                        if isFinal {
                            // final은 항상 보장 — pending에 적재(기존 volatile pending을 덮어씀).
                            pending = (text, isFinal)
                        } else if inFlight {
                            // in-flight 중 volatile은 최신만 유지(드롭하되 pending에 최신 보관).
                            // 단, pending이 이미 final이면 final을 보호한다.
                            if pending?.isFinal != true {
                                pending = (text, false)
                            }
                            await self.logSkip()
                            continue
                        } else {
                            pending = (text, false)
                        }
                        if !inFlight {
                            await drain()
                        }
                    case .info(let msg):
                        continuation.yield(.info(msg))
                    case .failure(let reason):
                        continuation.yield(.failure(reason))
                    }
                }
                // 입력 종료 — 남은 pending(특히 final) 마무리.
                await drain()
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

    private func logSkip() {
        skipLogCount += 1
        if skipLogCount == 1 || skipLogCount % 50 == 0 {
            Self.log.debug("\(LogTag.translate, privacy: .public) volatile 스킵(in-flight) 누적=\(self.skipLogCount, privacy: .public)")
        }
    }
}
