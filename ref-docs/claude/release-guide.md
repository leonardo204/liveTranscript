# 릴리스 & 자동 업데이트 가이드 — Sparkle 기반 배포/공증/appcast 절차

liveTranslate는 [Sparkle](https://sparkle-project.org) 2.7.0+로 in-app 자동 업데이트를 제공한다.
앱은 `SUFeedURL`(GitHub `appcast.xml`)을 주기적으로 확인하고, 다운로드한 DMG를 `SUPublicEDKey`(EdDSA 공개키)로 검증한 뒤 설치한다.

릴리스 자동화는 `scripts/release.sh`가 담당한다(아카이브 → Developer ID 재서명 → DMG → 공증/Staple → EdDSA 서명 → GitHub Release → appcast 갱신).

---

## 0. 한눈에 보기

```bash
# 사전 준비를 1회 마친 뒤:
./scripts/release.sh 0.2.0            # 전체 릴리스
./scripts/release.sh 0.2.0 --dry-run  # 각 단계 검증만(빌드/공증/업로드 없음)
```

릴리스 후 `appcast.xml`/`project.yml` 변경을 **수동으로** commit & push 한다(자동 커밋 안 함).

---

## 1. 사용자가 직접 해야 할 사전 준비 (최초 1회)

### 1-1. Developer ID Application 인증서 확인

```bash
security find-identity -p codesigning -v
```
출력에 `Developer ID Application: YONGSUB LEE (XU8HS9JUTS)`가 있어야 한다.
없으면 Apple Developer 계정에서 Developer ID Application 인증서를 발급/설치한다.

### 1-2. notarytool 키체인 프로필 등록

```bash
xcrun notarytool store-credentials "livetranslate-notary" \
  --apple-id "<your@apple.id>" \
  --team-id "XU8HS9JUTS" \
  --password "<앱 전용 암호>"
```
- 앱 전용 암호: https://appleid.apple.com → 로그인 및 보안 → 앱 전용 암호.
- 프로필 이름을 바꾸려면 `.env`에 `APPLE_NOTARY_PROFILE=<이름>`을 넣으면 스크립트가 사용한다.

### 1-3. Sparkle EdDSA 키쌍 생성 → 공개키를 project.yml에 입력 (핵심)

Sparkle의 `generate_keys` 도구는 SPM artifacts 안에 있다. 먼저 한 번 빌드해 artifacts를 받는다:

```bash
make build   # Sparkle SPM fetch → DerivedData에 artifacts 생성
```

`generate_keys` 위치를 찾아 실행한다:

```bash
GEN="$(find ~/Library/Developer/Xcode/DerivedData/liveTranslate-*/SourcePackages/artifacts \
  -type f -name generate_keys -path '*parkle*' 2>/dev/null | head -1)"
"$GEN"
```

- **개인키**는 macOS Keychain에 안전하게 저장된다(절대 커밋/공유 금지).
- 출력되는 **공개키**(`SUPublicEDKey`)를 복사한다.
- `project.yml`의 placeholder를 교체한다:

```yaml
SUPublicEDKey: "<여기에 생성된 공개키>"   # REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY 대체
```

교체 후 `make build`로 다시 빌드해 Info.plist에 반영한다.

> 이미 키쌍이 있으면 `generate_keys -p`로 기존 공개키를 다시 출력할 수 있다.

### 1-4. gh CLI 로그인

```bash
brew install gh    # 미설치 시
gh auth login
```

---

## 2. 릴리스 실행

```bash
./scripts/release.sh <version>     # 예: ./scripts/release.sh 0.2.0
```

`<version>`을 주면 `project.yml`의 `MARKETING_VERSION`이 자동 갱신된다(생략 시 현재 값 사용).
빌드 번호는 `CURRENT_PROJECT_VERSION`을 쓰며, 새 릴리스마다 직접 올리는 것을 권장한다(appcast `sparkle:version`은 정수 비교).

스크립트 단계:
1. 버전 결정/갱신 (project.yml)
2. 사전 요건 확인 (xcodegen/xcodebuild/gh/공증 프로필/SUPublicEDKey placeholder 경고)
3. `xcodegen generate` + 빌드 디렉토리 초기화
4. `xcodebuild archive` (Release, Developer ID, Manual 서명)
5. archive에서 .app 추출 → `codesign --options runtime`(+entitlements 있으면) 재서명
6. `hdiutil`로 DMG 생성
7. `notarytool submit --wait` → `stapler staple`
8. Sparkle `sign_update`로 DMG EdDSA 서명 → `edSignature`/`length` 추출
9. `gh release create`로 DMG 업로드
10. `appcast.xml`에 새 `<item>` 삽입
11. commit/push 안내 출력(자동 커밋 안 함)

유용한 옵션: `--dry-run`, `--skip-notarize`, `--skip-upload`.

---

## 3. 릴리스 후 (피드 게시)

`appcast.xml`은 main 브랜치에 push되어 `raw.githubusercontent.com`으로 서비스된다
(`SUFeedURL`과 동일 경로). 스크립트가 안내하는 대로 수동 커밋한다:

```bash
git add appcast.xml project.yml
git commit -m "[Release] liveTranslate <version> — appcast 갱신"
git push origin main
```

push 후 사용자의 앱이 다음 확인 주기(또는 "지금 업데이트 확인")에 새 버전을 감지한다.

---

## 4. 동작 확인 / 트러블슈팅

- **설정 > 일반 > 업데이트**: 현재 버전 표시 / 자동확인 토글 / "지금 업데이트 확인".
- `SUPublicEDKey`가 placeholder면 다운로드는 되지만 **서명 검증 실패**로 설치가 거부된다 → 1-3 수행.
- `sign_update`/`generate_keys`를 못 찾으면: 먼저 `make build`로 Sparkle artifacts를 받았는지 확인.
- 공증 실패: 스크립트가 `notarytool log`를 출력한다(주로 Hardened Runtime/서명 누락). 본 프로젝트는 `ENABLE_HARDENED_RUNTIME: YES`로 설정됨.
- `SUFeedURL`/리포지토리 경로(`leonardo204/liveTranscript`)가 실제 GitHub repo와 일치하는지 확인.

---

## 5. 관련 파일

| 파일 | 역할 |
|------|------|
| `project.yml` | Sparkle 패키지/의존성, Info.plist Sparkle 키, 버전, Hardened Runtime |
| `Sources/Update/UpdateChecker.swift` | Sparkle `SPUStandardUpdaterController` 래퍼 |
| `Sources/App/AppState.swift` | `let updates = UpdateChecker()` 보유 |
| `Sources/App/SettingsView.swift` | 일반 탭 "업데이트" 섹션 |
| `appcast.xml` | 업데이트 피드(릴리스마다 `<item>` 추가) |
| `scripts/release.sh` | 릴리스 자동화 |
