# liveTranslate

macOS 실시간 자막 번역 앱입니다. **Gemini 3.5 Live Translate**(클라우드, API 키) 또는
**Apple 온디바이스 번역**(Apple Speech + Translation, **키 불필요**) 엔진을 선택해 사용합니다.
맥에서 흘러나오는 소리(또는 마이크 입력)를 실시간으로 받아 지정한 언어로 번역하고,
그 결과를 **영화 자막처럼 화면 위에 roll-up 오버레이**로 띄웁니다. 선택적으로 **번역 음성도 재생**할 수 있습니다.

메뉴바 상주(menu bar) 네이티브 앱으로, Dock 아이콘 없이 가볍게 동작합니다.

---

## 주요 기능

- **시스템 오디오 직접 캡처** — Core Audio Process Tap(macOS 14.4+)으로 시스템 출력 오디오를 직접 캡처합니다.
  BlackHole 등 가상 루프백 장치나 화면 녹화 권한이 **불필요**합니다(오디오 캡처 권한만 요구).
- **다양한 입력 소스** — 시스템 오디오(Core Audio Tap) · 마이크 · BlackHole 등 루프백 장치를 지원하며,
  자동 선택(BlackHole 감지 시 사용 → 없으면 시스템 탭 → 마이크)도 가능합니다.
- **엔진 선택(클라우드/온디바이스)** — Gemini Live(클라우드, API 키) 또는 Apple Speech+Translation(온디바이스, **키 불필요**)을 모델 카탈로그에서 선택합니다. 엔진 능력에 따라 설정 UI가 자동 게이팅됩니다.
- **Silero VAD(음성 활동 감지)** — FluidAudio(CoreML Silero VAD)로 음악·소음을 거르고 **발화 구간만** 전송해 API 비용을 절감합니다(기본 ON, 모델 로드 실패 시 자동 우회).
- **영화 자막식 roll-up 오버레이** — 최상위·클릭 통과 투명 창에 자막을 여러 줄로 누적(roll-up)해 위로 굴려 표시합니다. 클라우드(누적 delta)·온디바이스(세그먼트) 양 엔진이 **동일한 표시 모델**을 쓰고, 무음 시 자동 정리합니다.
- **자막 스타일 설정** — 폰트/크기/두께/글자색/외곽선/글로우/배경 박스/정렬/최대 줄수를 실시간 미리보기로 조정합니다.
- **번역 음성 재생(선택)** — 번역된 음성(24kHz)을 재생할 수 있고, **출력 장치 선택**과 **원문 오디오 덕킹**(재생 중 시스템 볼륨 자동 감소)을 지원합니다. 같은 출력 장치를 공유할 때도 번역 소리는 **자동 게인 보상**으로 설정 볼륨이 유지되며, 볼륨 조절을 지원하지 않는 출력 장치에서는 덕킹이 자동 비활성화됩니다.
- **자막 녹화** — 제어 HUD의 '녹화'로 확정 자막을 텍스트 파일에 저장합니다. **원문+번역문**을 `[HH:MM:SS]` 타임스탬프와 함께 기록하며, 파일 이름을 지정하고 동일 파일은 **이어붙이기/새로 쓰기**를 선택할 수 있습니다(저장 경로는 설정에서 변경).
- **실시간 비용 추정** — 세션 비용(전송/수신/총 USD)을 HUD에 표시하고 누적 비용을 설정에 저장합니다.
- **무중단 재연결** — `sessionResumption`/`goAway` 기반 핸드오버와 세션 한도 전 선제 재연결로 장시간 사용 시 끊김을 방지합니다.
- **다국어 자동 감지** — 소스 언어를 지정하지 않아도 서버가 자동 감지합니다(프리뷰, 실측 권장).
- **자동 업데이트** — Sparkle 기반 in-app 자동 업데이트.

---

## 요구사항

- **macOS 26 (Tahoe) 이상** (최소 사양 — 이전 버전 미지원, OS가 실행 차단)
- **Gemini API 키** — [Google AI Studio](https://aistudio.google.com)에서 발급 (클라우드 번역용)
- **오프라인 번역(Apple Speech + Apple Translation, 키 불필요)** — 온디바이스, 추가 키 불필요
- 빌드: [XcodeGen](https://github.com/yonaskolb/XcodeGen), Xcode (Swift 6.0)

---

## 빌드 & 실행

이 프로젝트는 `Makefile`로 XcodeGen 기반 빌드를 감쌉니다.

```bash
make gen      # project.yml → .xcodeproj 생성 (생성물 — gitignore됨)
make build    # 프로젝트 생성 후 Debug 빌드
make run      # 빌드 후 실행 (메뉴바 아이콘 확인)
make clean    # 빌드 산출물 + .xcodeproj 삭제
```

`make app-path`로 빌드 산출물(.app) 경로를 출력할 수 있습니다.

---

## 설정

- **API 키** — 개발 시 `.env`의 `GEMINI_API_KEY`를 사용하고, 배포 시에는 macOS **Keychain**에 저장합니다(평문 보관 금지). 설정 창에서 키 입력 → 연결 테스트 → 저장 흐름을 제공합니다.
- **번역 대상 언어** — 기본 `ko`(한국어), BCP-47 코드로 변경 가능. 소스 언어는 자동 감지됩니다.
- **입력 소스** — 자동 / 시스템 오디오 직접 캡처 / 특정 장치 중 선택.
- **VAD** — Silero VAD on/off(기본 ON).
- **자막 스타일** — 폰트, 크기(16–72pt), 두께, 글자색, 외곽선, 글로우, 배경 박스/불투명도, 정렬, 최대 줄수.
- **자막 위치** — 표시 모니터 선택 + 상/중/하 수직 위치(드래그로 이동, 위치 영속화).
- **원문 동시 표시** — 번역문과 함께 원문 자막을 표시(기본 OFF).
- **번역 음성 재생** — 재생 on/off, 출력 장치 선택, 소프트 볼륨, 원문 덕킹 on/off 및 덕킹 볼륨(번역 자동 게인 보상, 미지원 장치 시 덕킹 비활성).
- **자막 녹화** — 녹화 경로 지정. 제어 HUD에서 on/off하며 파일명·이어붙이기/덮어쓰기를 선택.
- **비용** — 비용 HUD on/off, 누적 비용 표시/초기화.
- **자동 업데이트** — 자동 확인 토글, "지금 업데이트 확인", 현재 버전 표시.

---

## 권한

- **마이크** (`NSMicrophoneUsageDescription`) — 마이크 입력 캡처 시.
- **시스템 오디오 캡처** (`NSAudioCaptureUsageDescription`) — 시스템 오디오 직접 캡처(Core Audio Tap, macOS 14.4+). 첫 캡처 시작 시 OS가 권한을 묻습니다. **화면 녹화 권한은 불필요**합니다.

권한이 거부되면 설정 창에서 시스템 설정(개인정보 보호 및 보안)으로 가는 deep link를 제공합니다.

---

## 동작 개요

```
입력 오디오 → VAD(Silero) 게이트 → 16kHz mono PCM(100ms 청크)
   ├─[클라우드] Gemini 3.5 Live Translate(WebSocket) → 번역 텍스트(누적 delta) + 선택적 번역 음성(24kHz)
   └─[온디바이스] Apple SpeechTranscriber(STT) → Apple Translation(MT) → 번역 텍스트(세그먼트)
   → 자막 roll-up 오버레이 / (클라우드) 음성 재생
```

- 자막은 **누적(delta)·세그먼트 두 입력 모델을 하나의 roll-up 표시로 통일**하고, STT/스트림 출력 heartbeat를 기준으로 연속 무음 시 화면을 정리합니다 → [자막 아키텍처(008)](specs/008-subtitle-rendering-architecture.md).
- 번역 음성은 재생을 켠 경우에만 디코드/재생합니다(끄면 폐기).

---

## 문서

- [설계 스펙 (001)](specs/001-liveTranslate-design.md) — 전체 아키텍처, 마일스톤, 비용 계획
- [Gemini Live & 오디오 (002)](specs/002-gemini-live-translate-and-audio.md) — Live Translate 사용법(검증 사실), 오디오 피드백 루프 재발 방지
- [번역 파이프라인 추상화 (004)](specs/004-translation-pipeline-architecture.md) — 공통 API 레이어 + Stage 파이프라인(엔진 플러그인 구조)
- [모델 카탈로그 + 설정 (005)](specs/005-model-catalog-and-settings.md) — JSON 모델 레지스트리 + 엔진/능력 기반 UI
- [Apple Speech 오프라인 번역 (007)](specs/007-apple-speech-offline-translate.md) — 온디바이스 STT+번역(키 불필요, macOS 26+)
- [자막 표시 아키텍처 (008)](specs/008-subtitle-rendering-architecture.md) — 누적/세그먼트 통합 roll-up + STT heartbeat 무음 처리 + 글로우 클립 렌더
- [릴리스 & 자동 업데이트 가이드](ref-docs/claude/release-guide.md) — Sparkle 기반 배포/공증/appcast 절차

---

## 비용 안내

비용은 **클라우드(Gemini) 엔진에만** 적용됩니다 — 온디바이스(Apple Speech+Translation) 엔진은 API 비용이 없습니다(전력만 사용).

`gemini-3.5-live-translate-preview`는 **프리뷰**이며 단가는 변동될 수 있습니다.
오디오 입력 $3.50 / 1M tokens, 오디오 출력 $21.00 / 1M tokens(출력이 비용의 ~85%)이며,
출력 오디오는 재생하지 않아도 생성·과금됩니다. **무음도 과금**되므로 VAD로 발화 구간만 전송해 비용을 절감합니다.
앱의 비용 HUD(세션 전송/수신/총 USD)와 설정의 누적 비용 표시로 사용량을 확인하세요.
