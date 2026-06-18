#!/usr/bin/env bash
# scripts/release.sh — liveTranslate 전체 릴리스 자동화 (Sparkle 자동 업데이트 연동)
#
# 사용법:
#   ./scripts/release.sh [<version>] [--dry-run] [--skip-notarize] [--skip-upload]
#     <version>          예: 0.2.0  (생략 시 project.yml의 MARKETING_VERSION 사용)
#     --dry-run          실제 빌드/공증/업로드 없이 각 단계 검증만 수행
#     --skip-notarize    공증 단계 건너뜀
#     --skip-upload      GitHub Release 업로드 건너뜀
#
# ── 사전 준비 (최초 1회, 상세는 ref-docs/claude/release-guide.md) ─────────────
#   1. Developer ID Application 인증서 보유:
#        security find-identity -p codesigning -v
#   2. notarytool 키체인 프로필 등록:
#        xcrun notarytool store-credentials "livetranslate-notary" \
#          --apple-id "<apple-id>" --team-id "XU8HS9JUTS" --password "<앱 전용 암호>"
#   3. Sparkle EdDSA 키쌍 생성 후 공개키를 project.yml SUPublicEDKey에 입력:
#        generate_keys  (Sparkle artifacts 내 도구 — release-guide.md 참조)
#   4. gh CLI 로그인: gh auth login
#
# 비밀값(인증서 암호/앱 전용 암호/EdDSA 개인키)은 절대 이 스크립트에 하드코딩하지 않는다.

set -euo pipefail

# ── 로그 헬퍼 ─────────────────────────────────────────
info()    { echo "▶ $*"; }
success() { echo "✅ $*"; }
warn()    { echo "⚠️  $*"; }
error()   { echo "❌ $*" >&2; exit 1; }
dry()     { echo "   [DRY-RUN] $*"; }

# ── 프로젝트 루트 ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# .env가 있으면 로드(APPLE_NOTARY_PROFILE 등 환경변수 덮어쓰기용 — 비밀값 커밋 금지).
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a; . "$PROJECT_ROOT/.env"; set +a
fi

# ── 설정값 ────────────────────────────────────────────
APP_NAME="liveTranslate"
SCHEME="liveTranslate"
SIGNING_IDENTITY="Developer ID Application: YONGSUB LEE (XU8HS9JUTS)"
TEAM_ID="XU8HS9JUTS"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-livetranslate-notary}"
GITHUB_REPO="leonardo204/liveTranscript"
PROJECT_YML="$PROJECT_ROOT/project.yml"
APPCAST="$PROJECT_ROOT/appcast.xml"
BUILD_DIR="$PROJECT_ROOT/build"
# entitlements 파일이 있으면 재서명 시 적용(없으면 생략).
ENTITLEMENTS_FILE="$PROJECT_ROOT/Sources/liveTranslate.entitlements"

# ── 옵션 파싱 ─────────────────────────────────────────
DRY_RUN=false
SKIP_NOTARIZE=false
SKIP_UPLOAD=false
ARG_VERSION=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=true ;;
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --skip-upload)   SKIP_UPLOAD=true ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            error "알 수 없는 옵션: $arg"
            ;;
        *)
            ARG_VERSION="$arg" ;;
    esac
done

# ── 1단계: 버전 결정 (인자 우선, 없으면 project.yml) ───
info "버전 결정 중..."
[ -f "$PROJECT_YML" ] || error "project.yml 없음: $PROJECT_YML"

YML_MARKETING=$(grep -E '^\s*MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([0-9][0-9.]*)"?.*/\1/')
YML_BUILD=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed -E 's/.*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/')

VERSION="${ARG_VERSION:-$YML_MARKETING}"
[ -n "$VERSION" ] || error "버전을 결정할 수 없습니다(인자/project.yml 모두 없음)."
BUILD_NUMBER="${YML_BUILD:-1}"

# 인자로 새 버전을 받았고 project.yml과 다르면, project.yml의 MARKETING_VERSION을 갱신한다.
if [ -n "$ARG_VERSION" ] && [ "$ARG_VERSION" != "$YML_MARKETING" ]; then
    if $DRY_RUN; then
        dry "project.yml MARKETING_VERSION: $YML_MARKETING → $ARG_VERSION"
    else
        sed -i '' -E "s/(MARKETING_VERSION:[[:space:]]*\")[0-9][0-9.]*(\".*)/\1${ARG_VERSION}\2/" "$PROJECT_YML"
        info "  project.yml MARKETING_VERSION 갱신: $YML_MARKETING → $ARG_VERSION"
    fi
fi

ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
DMG_STAGING="$BUILD_DIR/dmg_staging"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TAG="v${VERSION}"

info "버전: $VERSION (build $BUILD_NUMBER)  |  태그: $TAG  |  DMG: $DMG_NAME"
echo ""
$DRY_RUN && { warn "DRY-RUN 모드 — 실제 빌드/공증/업로드는 수행하지 않습니다"; echo ""; }

# ── 2단계: 사전 요건 확인 ─────────────────────────────
info "사전 요건 확인..."
command -v xcodegen &>/dev/null || error "xcodegen 없음. 설치: brew install xcodegen"
command -v xcodebuild &>/dev/null || error "xcodebuild 없음. Xcode Command Line Tools를 설치하세요."

# SUPublicEDKey placeholder 경고(릴리스 전 교체 필수).
if grep -q "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" "$PROJECT_YML"; then
    warn "project.yml의 SUPublicEDKey가 아직 placeholder입니다."
    warn "  generate_keys로 키쌍을 만들고 공개키로 교체해야 자동 업데이트 서명 검증이 동작합니다."
    warn "  (ref-docs/claude/release-guide.md 참조)"
fi

if ! $SKIP_UPLOAD; then
    command -v gh &>/dev/null || error "gh CLI 없음. 설치: brew install gh"
    gh auth status &>/dev/null || error "gh CLI 로그인 필요: gh auth login"
fi

if ! $SKIP_NOTARIZE; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --no-progress &>/dev/null; then
        warn "공증 프로필 '$NOTARY_PROFILE' 미등록. 아래로 1회 등록 후 재실행:"
        echo "   xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "     --apple-id \"<apple-id>\" --team-id \"$TEAM_ID\" --password \"<앱 전용 암호>\""
        $DRY_RUN || error "공증 프로필 미등록. --skip-notarize 로 건너뛸 수 있습니다."
    else
        info "  공증 프로필 '$NOTARY_PROFILE' 확인됨"
    fi
fi
echo ""

# ── 3단계: 프로젝트 생성 + 이전 빌드 정리 ─────────────
info "xcodegen generate + 빌드 디렉토리 초기화..."
if $DRY_RUN; then
    dry "xcodegen generate"
    dry "rm -rf $BUILD_DIR && mkdir -p $DMG_STAGING"
else
    xcodegen generate
    rm -rf "$BUILD_DIR"
    mkdir -p "$DMG_STAGING"
fi
echo ""

# ── 4단계: Release 아카이브 ───────────────────────────
info "Release 아카이브 빌드..."
XCODEBUILD_LOG="$BUILD_DIR/xcodebuild-archive.log"
if $DRY_RUN; then
    dry "xcodebuild archive -scheme $SCHEME -configuration Release -archivePath $ARCHIVE_PATH ..."
else
    mkdir -p "$BUILD_DIR"
    xcodebuild archive \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        > "$XCODEBUILD_LOG" 2>&1 || {
            echo "❌ 아카이브 실패. 로그 마지막 40줄:"; tail -40 "$XCODEBUILD_LOG"; exit 1
        }
    [ -d "$ARCHIVE_PATH" ] || error "아카이브 없음: $ARCHIVE_PATH"
    success "아카이브 완료: $ARCHIVE_PATH"
fi
echo ""

# ── 5단계: Developer ID 재서명 ────────────────────────
info "Developer ID 서명..."
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if $DRY_RUN; then
    dry "cp -R '$APP_PATH' '$DMG_STAGING/'"
    if [ -f "$ENTITLEMENTS_FILE" ]; then
        dry "codesign --deep --force --options runtime --entitlements '$ENTITLEMENTS_FILE' --sign '$SIGNING_IDENTITY' '$DMG_STAGING/$APP_NAME.app'"
    else
        dry "codesign --deep --force --options runtime --sign '$SIGNING_IDENTITY' '$DMG_STAGING/$APP_NAME.app'"
    fi
else
    [ -d "$APP_PATH" ] || error "아카이브 내 앱 없음: $APP_PATH"
    cp -R "$APP_PATH" "$DMG_STAGING/"
    if [ -f "$ENTITLEMENTS_FILE" ]; then
        info "  entitlements 적용: $ENTITLEMENTS_FILE"
        codesign --deep --force --options runtime \
            --entitlements "$ENTITLEMENTS_FILE" \
            --sign "$SIGNING_IDENTITY" \
            "$DMG_STAGING/$APP_NAME.app" || error "Developer ID 서명 실패"
    else
        codesign --deep --force --options runtime \
            --sign "$SIGNING_IDENTITY" \
            "$DMG_STAGING/$APP_NAME.app" || error "Developer ID 서명 실패"
    fi
    codesign --verify --deep --strict "$DMG_STAGING/$APP_NAME.app" || error "코드 서명 검증 실패"
    success "Developer ID 서명 완료"
fi
echo ""

# ── 6단계: DMG 생성 ───────────────────────────────────
info "DMG 생성 중..."
if $DRY_RUN; then
    dry "ln -s /Applications $DMG_STAGING/Applications"
    dry "hdiutil create -volname '$APP_NAME $VERSION' -srcfolder $DMG_STAGING -ov -format UDZO $DMG_PATH"
else
    ln -s /Applications "$DMG_STAGING/Applications" 2>/dev/null || true
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" \
        || error "DMG 생성 실패"
    success "DMG 생성 완료: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
fi
echo ""

# ── 7단계: 공증(Notarization) + Staple ────────────────
if $SKIP_NOTARIZE; then
    warn "공증 건너뜀 (--skip-notarize)"
elif $DRY_RUN; then
    dry "xcrun notarytool submit $DMG_PATH --keychain-profile '$NOTARY_PROFILE' --wait"
    dry "xcrun stapler staple $DMG_PATH"
else
    info "공증 제출 중 (수 분 소요)..."
    NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --progress 2>&1) || true
    echo "$NOTARY_OUTPUT"
    if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        success "공증 성공"
        xcrun stapler staple "$DMG_PATH" || error "Staple 실패"
        success "Staple 완료"
    else
        SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -o 'id: [a-f0-9-]*' | head -1 | cut -d' ' -f2)
        [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -30
        error "공증 실패. 위 로그를 확인하세요."
    fi
fi
echo ""

# ── 8단계: Sparkle EdDSA 서명 (edSignature/length 추출) ─
info "Sparkle EdDSA 서명 생성..."
# Sparkle SPM artifacts에서 sign_update 도구를 동적 탐색(버전/경로 변동에 견고).
SPARKLE_BIN=""
for base in \
    "$HOME/Library/Developer/Xcode/DerivedData"/${APP_NAME}-*/SourcePackages/artifacts \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/artifacts ; do
    found="$(find "$base" -type f -name sign_update -path '*parkle*' 2>/dev/null | head -1)"
    [ -n "$found" ] && { SPARKLE_BIN="$found"; break; }
done

ED_SIGNATURE=""
DMG_LENGTH=""
if [ -z "$SPARKLE_BIN" ]; then
    warn "sign_update 도구를 찾지 못했습니다(Sparkle artifacts 미빌드?)."
    warn "  최소 1회 'make build' 또는 위 archive 수행 후 DerivedData에 artifacts가 생깁니다."
    warn "  appcast.xml에 edSignature/length를 수동으로 채워야 합니다."
elif $DRY_RUN; then
    dry "$SPARKLE_BIN $DMG_PATH   # edSignature/length 추출"
elif [ -f "$DMG_PATH" ]; then
    info "  도구: $SPARKLE_BIN"
    # sign_update 출력 예: sparkle:edSignature="..." length="..."
    SIGN_OUT="$("$SPARKLE_BIN" "$DMG_PATH" 2>/dev/null || true)"
    echo "  $SIGN_OUT"
    ED_SIGNATURE="$(echo "$SIGN_OUT" | sed -E 's/.*edSignature="([^"]*)".*/\1/')"
    DMG_LENGTH="$(echo "$SIGN_OUT" | sed -E 's/.*length="([0-9]+)".*/\1/')"
fi
echo ""

# ── 9단계: GitHub Release 업로드 ──────────────────────
if $SKIP_UPLOAD; then
    warn "GitHub Release 업로드 건너뜀 (--skip-upload)"
elif $DRY_RUN; then
    dry "gh release create $TAG '$DMG_PATH' --repo $GITHUB_REPO --title '$TAG' --generate-notes"
else
    if gh release view "$TAG" --repo "$GITHUB_REPO" &>/dev/null; then
        warn "태그 '$TAG' 릴리스가 이미 존재합니다. 삭제 후 재실행:"
        warn "  gh release delete $TAG --repo $GITHUB_REPO --yes"
    else
        gh release create "$TAG" "$DMG_PATH" --repo "$GITHUB_REPO" --title "$TAG" --generate-notes \
            || error "GitHub Release 생성 실패"
        success "GitHub Release: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
    fi
fi
echo ""

# ── 10단계: appcast.xml에 <item> 추가 ─────────────────
info "appcast.xml 갱신..."
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$DMG_NAME"
PUB_DATE="$(LC_ALL=en_US.UTF-8 date '+%a, %d %b %Y %H:%M:%S %z')"

if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_LENGTH" ]; then
    warn "edSignature/length 미확보 — appcast.xml 자동 갱신을 건너뜁니다."
    warn "  아래 <item>을 appcast.xml의 <channel> 안에 수동으로 추가하세요(서명/length 채움):"
    cat <<EOF
    <item>
      <title>$APP_NAME $VERSION</title>
      <link>https://github.com/$GITHUB_REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$DOWNLOAD_URL"
                 sparkle:edSignature="<EDSIGNATURE>" length="<LENGTH>" type="application/octet-stream"/>
    </item>
EOF
elif $DRY_RUN; then
    dry "appcast.xml <channel>에 $APP_NAME $VERSION <item> 삽입(url=$DOWNLOAD_URL)"
else
    # 새 <item>을 <!-- 릴리스마다 ... 주석 직전(= <channel> 최상단)에 삽입한다.
    NEW_ITEM=$(cat <<EOF
    <item>
      <title>$APP_NAME $VERSION</title>
      <link>https://github.com/$GITHUB_REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$DOWNLOAD_URL"
                 sparkle:edSignature="$ED_SIGNATURE" length="$DMG_LENGTH" type="application/octet-stream"/>
    </item>
EOF
)
    # <language>ko</language> 줄 뒤에 새 item을 삽입(Python으로 안전하게 처리).
    NEW_ITEM="$NEW_ITEM" python3 - "$APPCAST" <<'PY'
import os, sys
path = sys.argv[1]
item = os.environ["NEW_ITEM"]
with open(path, encoding="utf-8") as f:
    text = f.read()
anchor = "<language>ko</language>"
idx = text.find(anchor)
if idx == -1:
    sys.exit("appcast.xml에서 <language>ko</language> 앵커를 찾지 못했습니다.")
insert_at = idx + len(anchor)
new = text[:insert_at] + "\n" + item + text[insert_at:]
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
print("appcast.xml에 새 <item> 삽입 완료")
PY
    success "appcast.xml 갱신 완료"
fi
echo ""

# ── 11단계: 커밋/푸시 안내 (자동 커밋 금지) ───────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "릴리스 처리 완료 (버전 $VERSION)"
echo ""
echo "  다음을 수동으로 커밋/푸시하세요(appcast.xml은 main에 push되어야 피드가 갱신됩니다):"
echo ""
echo "    git add appcast.xml project.yml"
echo "    git commit -m \"[Release] $APP_NAME $VERSION — appcast 갱신\""
echo "    git push origin main"
echo ""
$DRY_RUN || open -R "$DMG_PATH" 2>/dev/null || true
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
