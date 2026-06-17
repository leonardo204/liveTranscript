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

            // 자동 선택(스펙 §5.2 기본값): BlackHole 우선 → 시스템 Tap → 기본 입력.
            Button {
                audio.selectAuto()
            } label: {
                let mark = audio.selection == .auto ? "✓ " : "   "
                Text("\(mark)자동 (\(audio.activeSourceLabel))")
            }

            // 시스템 오디오 직접 캡처 (Core Audio Tap, 14.4+에서만 활성).
            Button {
                audio.selectSystemTap()
            } label: {
                let mark = audio.selection == .systemTap ? "✓ " : "   "
                Text("\(mark)시스템 오디오 (직접 캡처)")
            }
            .disabled(!audio.systemTapAvailable)
            .help(audio.systemTapAvailable
                  ? "추가 설치 없이 시스템 소리를 직접 캡처합니다 (macOS 14.4+)"
                  : "macOS 14.4 미만 — BlackHole 설치가 필요합니다")

            Divider()

            if audio.devices.isEmpty {
                Text("입력 장치 없음")
            } else {
                ForEach(audio.devices) { device in
                    Button {
                        audio.selectDevice(device)
                    } label: {
                        let selected = audio.selection == .device(device.uid)
                        let mark = selected ? "✓ " : "   "
                        let tag = device.isLikelyLoopback ? " (루프백)" : ""
                        Text("\(mark)\(device.name)\(tag)")
                    }
                }
            }
        }

        Divider()

        // VAD(음성 감지) on/off 토글 (M1b, 기본 on). 음악·소음·무음 송신 차단으로 비용 절감.
        Toggle("음성 감지(VAD)", isOn: Binding(
            get: { audio.vadEnabled },
            set: { audio.vadEnabled = $0 }
        ))

        // VAD 모델 상태 + 발화중 표시.
        if audio.vadEnabled {
            Text(audio.vadStatus.menuLabel)
            if audio.isCapturing, audio.vadStatus == .ready {
                Text(audio.isSpeaking ? "● 발화 감지됨" : "○ 무음/대기")
            }
        }

        Divider()

        // 레벨 미터 — 캡처 중일 때 입력 소리에 반응.
        if audio.isCapturing {
            Text("입력 레벨: \(LevelMeter.bar(for: audio.level))")
            Text("선택: \(audio.activeSourceLabel)")
        } else {
            Text("캡처 정지됨")
        }

        // 권한 거부 등 오류는 클릭하면 해당 시스템 설정 창이 열리도록 한다(피드백 #3).
        if let error = audio.lastErrorMessage {
            Button("⚠️ \(error)") {
                openSettingsForError()
            }
        }

        Divider()

        // Gemini 번역 상태 (M2a). 키 미포함 라벨만 표시.
        Text("번역 상태: \(appState.geminiStatus)")

        // 번역 자막 현재 줄(최근 1줄) — 메뉴에서도 흐름 확인.
        if !appState.subtitles.displayTranslation.isEmpty {
            Text("자막: \(appState.subtitles.displayTranslation)")
        }

        // 원문 동시 표시 토글 (FR-8, 기본 OFF).
        Toggle("원문 동시 표시", isOn: Binding(
            get: { appState.settings.showSourceText },
            set: { appState.settings.showSourceText = $0 }
        ))

        Divider()

        // 미니 HUD(플로팅 모니터) 표시 토글 (피드백 #1).
        Button {
            appState.toggleMonitor()
        } label: {
            let mark = appState.hud.isVisible ? "✓ " : "   "
            Text("\(mark)모니터 표시")
        }

        Button("설정…") {
            appState.openSettings()
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

    /// 캡처 오류 항목 클릭 시: 마이크/시스템 오디오 권한 거부면 해당 설정 pane을 직접 연다.
    /// 그 외 오류는 설정 창을 띄워 권한 섹션에서 상태를 확인하게 한다(피드백 #3).
    private func openSettingsForError() {
        let audio = appState.audio
        if case .systemTap = audio.effectiveSelection {
            PermissionHelper.openSystemAudioSettings()
            return
        }
        if PermissionHelper.microphoneStatus().needsAction {
            PermissionHelper.openMicrophoneSettings()
        } else {
            appState.openSettings()
        }
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
