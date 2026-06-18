# liveTranslate

Google **Gemini 3.5 Live Translate** 기반의 macOS 실시간 자막 번역 앱입니다.
맥에서 흘러나오는 소리(또는 마이크 입력)를 실시간으로 받아 지정한 언어로 번역하고,
그 결과를 **영화 자막처럼 화면 위에 오버레이**로 띄웁니다. 선택적으로 **번역 음성도 재생**할 수 있습니다.

메뉴바 상주(menu bar) 네이티브 앱으로, Dock 아이콘 없이 가볍게 동작합니다.

---

## 주요 기능

- **시스템 오디오 직접 캡처** — Core Audio Process Tap(macOS 14.4+)으로 시스템 출력 오디오를 직접 캡처합니다.
  BlackHole 등 가상 루프백 장치나 화면 녹화 권한이 **불필요**합니다(오디오 캡처 권한만 요구).
- **다양한 입력 소스** — 시스템 오디오(Core Audio Tap) · 마이크 · BlackHole 등 루프백 장치를 지원하며,
  자동 선택(BlackHole 감지 시 사용 → 없으면 시스템 탭 → 마이크)도 가능합니다.
- **Silero VAD(음성 활동 감지)** — FluidAudio(CoreML Silero VAD)로 음악·소음을 거르고 **발화 구간만** 전송해 API 비용을 절감합니다(기본 ON, 모델 로드 실패 시 자동 우회).
- **영화 자막식 오버레이** — 최상위·클릭 통과 투명 창에 자막을 누적 표시하고 페이드 처리합니다.
- **자막 스타일 설정** — 폰트/크기/두께/글자색/외곽선/글로우/배경 박스/정렬/최대 줄수를 실시간 미리보기로 조정합니다.
- **번역 음성 재생(선택)** — 번역된 음성(24kHz)을 재생할 수 있고, **출력 장치 선택**과 **원문 오디오 덕킹**(재생 중 시스템 볼륨 자동 감소)을 지원합니다.
- **실시간 비용 추정** — 세션 비용(전송/수신/총 USD)을 HUD에 표시하고 누적 비용을 설정에 저장합니다.
- **무중단 재연결** — `sessionResumption`/`goAway` 기반 핸드오버와 세션 한도 전 선제 재연결로 장시간 사용 시 끊김을 방지합니다.
- **다국어 자동 감지** — 소스 언어를 지정하지 않아도 서버가 자동 감지합니다(프리뷰, 실측 권장).
- **자동 업데이트** — Sparkle 기반 in-app 자동 업데이트.

---

## 요구사항

- **macOS 14.0+** (마이크/BlackHole 입력)
- **macOS 14.4+** — 시스템 오디오 직접 캡처(Core Audio Process Tap) 사용 시
- **Gemini API 키** — [Google AI Studio](https://aistudio.google.com)에서 발급
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
- **번역 음성 재생** — 재생 on/off, 출력 장치 선택, 소프트 볼륨, 원문 덕킹 on/off 및 덕킹 볼륨.
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
   → Gemini 3.5 Live Translate (WebSocket)
   → 번역 텍스트(자막) + 선택적 번역 음성(24kHz)
   → 자막 오버레이 / 음성 재생
```

- 자막 본문은 `outputAudioTranscription` delta로 수신해 누적·확정합니다.
- 번역 음성은 재생을 켠 경우에만 디코드/재생합니다(끄면 폐기).

---

## 문서

- [설계 스펙 (001)](specs/001-liveTranslate-design.md) — 전체 아키텍처, 마일스톤, 비용 계획
- [Gemini Live & 오디오 (002)](specs/002-gemini-live-translate-and-audio.md) — Live Translate 사용법(검증 사실), 오디오 피드백 루프 재발 방지
- [릴리스 & 자동 업데이트 가이드](ref-docs/claude/release-guide.md) — Sparkle 기반 배포/공증/appcast 절차

---

## 비용 안내

`gemini-3.5-live-translate-preview`는 **프리뷰**이며 단가는 변동될 수 있습니다.
오디오 입력 $3.50 / 1M tokens, 오디오 출력 $21.00 / 1M tokens(출력이 비용의 ~85%)이며,
출력 오디오는 재생하지 않아도 생성·과금됩니다. **무음도 과금**되므로 VAD로 발화 구간만 전송해 비용을 절감합니다.
앱의 비용 HUD(세션 전송/수신/총 USD)와 설정의 누적 비용 표시로 사용량을 확인하세요.
