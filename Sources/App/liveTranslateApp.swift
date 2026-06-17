import SwiftUI

/// liveTranslate — Gemini 3.5 Live 기반 macOS 실시간 자막 번역 앱.
///
/// M0: 메뉴바 상주 앱 골격. 실제 번역/오디오 기능은 M1+에서 구현된다.
/// `LSUIElement = YES`(project.yml)로 Dock 아이콘 없이 메뉴바에만 상주한다.
@main
struct liveTranslateApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("liveTranslate", systemImage: "captions.bubble") {
            MenuBarContent()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 메뉴바 드롭다운 내용.
/// M0 수준: 토글 상태만 가진 placeholder 항목들 + API 키 로드 상태 표시.
private struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(appState.isRunning ? "번역 정지" : "번역 시작") {
            // TODO(M2): GeminiLiveClient 연결/해제 토글
            appState.isRunning.toggle()
        }

        Button("설정…") {
            // TODO(M4): SettingsStore 기반 설정 창 표시
        }

        Divider()

        // API 키 로드 여부 표시 (개발용 .env 또는 배포용 Keychain)
        Text(appState.apiKeyLoaded ? "API 키: 로드됨" : "API 키: 없음")

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
