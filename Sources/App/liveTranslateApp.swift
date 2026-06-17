import SwiftUI

/// liveTranslate — Gemini 3.5 Live 기반 macOS 실시간 자막 번역 앱.
///
/// M0: 메뉴바 상주 앱 골격. M1a: 마이크/BlackHole 캡처 + 입력 소스 선택 + 레벨 미터.
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
/// M1a: 캡처 시작/정지(실동작), 입력 소스 선택 서브메뉴, 레벨 미터, API 키 상태.
private struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let audio = appState.audio

        // 캡처 시작/정지 — 실제 오디오 캡처와 연동.
        Button(audio.isCapturing ? "번역 정지" : "번역 시작") {
            appState.toggleCapture()
        }

        // 입력 소스 선택 서브메뉴 (체크마크로 현재 선택 표시).
        Menu("입력 소스") {
            Button("장치 목록 새로고침") {
                audio.refreshDevices()
            }
            Divider()
            if audio.devices.isEmpty {
                Text("입력 장치 없음")
            } else {
                ForEach(audio.devices) { device in
                    Button {
                        audio.selectDevice(device)
                    } label: {
                        let selected = audio.selectedDevice?.uid == device.uid
                        let mark = selected ? "✓ " : "   "
                        let tag = device.isLikelyLoopback ? " (루프백)" : ""
                        Text("\(mark)\(device.name)\(tag)")
                    }
                }
            }
        }

        Divider()

        // 레벨 미터 — 캡처 중일 때 입력 소리에 반응.
        if audio.isCapturing {
            Text("입력 레벨: \(LevelMeter.bar(for: audio.level))")
            Text("선택: \(audio.selectedDevice?.name ?? "기본 입력")")
        } else {
            Text("캡처 정지됨")
        }

        if let error = audio.lastErrorMessage {
            Text("⚠️ \(error)")
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
