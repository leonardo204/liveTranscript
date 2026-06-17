SCHEME := liveTranslate
CONFIG := Debug

.PHONY: gen build clean run all

# XcodeGen으로 .xcodeproj 생성 (생성물 — gitignore됨)
gen:
	xcodegen generate

# 프로젝트 생성 후 Debug 빌드
build: gen
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) build

# 빌드 산출물 경로 출력
app-path: gen
	@xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) \
		-showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} / FULL_PRODUCT_NAME /{n=$$2} END{print d"/"n}'

# 빌드 후 실행 (메뉴바 아이콘 확인용)
run: build
	@open "$$(make -s app-path)"

clean:
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) clean
	rm -rf liveTranslate.xcodeproj

all: build
