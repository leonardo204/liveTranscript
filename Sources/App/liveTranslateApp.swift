import SwiftUI

/// liveTranslate — Gemini 3.5 Live 기반 macOS 실시간 자막 번역 앱.
///
/// M0: 메뉴바 상주 앱 골격. M1a: 마이크/BlackHole 캡처 + 입력 소스 선택 + 레벨 미터.
/// `LSUIElement = YES`(project.yml)로 Dock 아이콘 없이 메뉴바에만 상주한다.
@main
struct liveTranslateApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            // 커스텀 메뉴바 글리프(Assets: MenuBarGlyph, 템플릿 렌더링 → 라이트/다크 자동 틴트).
            Image("MenuBarGlyph")
                .accessibilityLabel("liveTranslate")
        }
        .menuBarExtraStyle(.menu)
        // macOS 표준 "설정…"(⌘,) — 앱 메뉴의 기본 appSettings 항목을 커스텀 설정 창에 연결한다.
        // (SwiftUI Settings 씬을 쓰지 않고 SettingsWindowController로 띄우는 구조 유지.)
        // 앱이 활성(설정 창 등으로 .regular)일 때 ⌘,가 동작한다. 메뉴 드롭다운이 열린 경우는
        // 아래 MenuBarContent의 "설정…" 버튼 단축키가 처리한다(종료 ⌘Q와 동일 모델).
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { appState.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// 메뉴바 드롭다운 내용 (M3 간소화 — 피드백 #3).
///
/// VAD/오디오/레벨/입력소스 등 **상태 정보 항목을 제거**하고(제어 HUD로 대체),
/// 최소한의 제어만 남긴다: 번역 시작/정지, 제어 HUD 표시 토글, 설정, 종료.
/// (상세 입력 소스 선택은 설정 창에 있다.)
private struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // 번역 시작/정지 — 제어 HUD 버튼과 동일 동작(메뉴에도 남겨 빠른 접근).
        // 라벨은 세션 단일 진실(isRunning)을 따른다(hot-swap 실패로 인한 뒤집힘 방지).
        Button(appState.isRunning ? "번역 정지" : "번역 시작") {
            appState.toggleCapture()
        }

        Divider()

        // 제어 HUD 표시/숨김 토글 (피드백 #1·#3 — 상태 정보는 제어 HUD에서 본다).
        Button {
            appState.toggleMonitor()
        } label: {
            let mark = appState.hud.isVisible ? "✓ " : "   "
            Text("\(mark)제어 HUD 표시")
        }

        Button("설정…") {
            appState.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// 레벨(0~1)을 유니코드 블록 바 문자열로 변환하는 유틸 (메뉴바 텍스트 미터).
enum LevelMeter {
    private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// 8칸 바. 각 칸은 0~1 구간을 8등분하여 채운다.
    static func bar(for level: Float, width: Int = 8) -> String {
        let clamped = max(0, min(level, 1))
        var result = ""
        for i in 0..<width {
            let cellStart = Float(i) / Float(width)
            let cellEnd = Float(i + 1) / Float(width)
            if clamped >= cellEnd {
                result.append(blocks.last!)
            } else if clamped <= cellStart {
                result.append(blocks.first!)
            } else {
                let frac = (clamped - cellStart) / (cellEnd - cellStart)
                let idx = min(blocks.count - 1, max(0, Int(frac * Float(blocks.count - 1))))
                result.append(blocks[idx])
            }
        }
        return result
    }
}
