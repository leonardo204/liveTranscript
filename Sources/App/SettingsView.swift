import SwiftUI

/// 설정 창 내용 (M1.5 피드백 #2).
///
/// 섹션: 입력 / 음성 감지(VAD) / 모니터(HUD) / 권한 / API 키 / 자막 스타일(M4 placeholder).
/// 모든 변경은 기존 `AudioInputManager`/`SettingsStore`/`HUDController`에 즉시 반영된다.
struct SettingsView: View {
    var appState: AppState

    // 권한 상태는 창이 뜰 때/새로고침 시 다시 조회한다(시스템 설정에서 바꾸고 돌아올 수 있음).
    @State private var micStatus: PermissionHelper.Status = .unknown
    @State private var sysAudioStatus: PermissionHelper.Status = .unknown

    // 자막 위치 선택용 화면 목록(연결/해제 시 새로고침).
    @State private var screens: [ScreenOption] = []

    var body: some View {
        Form {
            inputSection
            vadSection
            subtitlePositionSection
            monitorSection
            costSection
            permissionSection
            apiKeySection
            subtitleStyleSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .onAppear {
            refreshPermissions()
            refreshScreens()
        }
    }

    // MARK: - 입력

    private var inputSection: some View {
        let audio = appState.audio
        return Section("입력") {
            Picker("입력 소스", selection: Binding(
                get: { currentSelectionTag },
                set: { applySelection($0) }
            )) {
                Text("자동 (\(audio.activeSourceLabel))").tag(SelectionTag.auto)
                Text("시스템 오디오 (직접 캡처)")
                    .tag(SelectionTag.systemTap)
                ForEach(audio.devices) { device in
                    Text(device.name + (device.isLikelyLoopback ? " (루프백)" : ""))
                        .tag(SelectionTag.device(device.uid))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("장치 목록 새로고침") { audio.refreshDevices() }
                Spacer()
                Text(audio.isCapturing ? "캡처중" : "정지됨")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 음성 감지(VAD)

    private var vadSection: some View {
        let audio = appState.audio
        return Section("음성 감지(VAD)") {
            Toggle("음성 감지 사용", isOn: Binding(
                get: { audio.vadEnabled },
                set: { audio.vadEnabled = $0 }
            ))
            LabeledContent("모델 상태", value: audio.vadStatus.menuLabel)
        }
    }

    // MARK: - 자막 위치 (M3, 피드백 #5)

    private var subtitlePositionSection: some View {
        let settings = appState.settings
        return Section("자막 위치") {
            // 모니터 선택: 연결된 화면 목록 + 자동(주 화면).
            Picker("표시 화면", selection: Binding(
                get: { settings.subtitleScreenID ?? -1 },
                set: { newValue in
                    settings.subtitleScreenID = (newValue == -1) ? nil : newValue
                    appState.subtitleOverlay.applyPositionChange()
                }
            )) {
                Text("자동 (주 화면)").tag(-1)
                ForEach(screens) { screen in
                    Text(screen.label).tag(screen.id)
                }
            }
            .pickerStyle(.menu)

            // 세로 위치: 위/중앙/아래.
            Picker("세로 위치", selection: Binding(
                get: { settings.subtitleVerticalPosition },
                set: {
                    settings.subtitleVerticalPosition = $0
                    appState.subtitleOverlay.applyPositionChange()
                }
            )) {
                ForEach(SubtitleVerticalPosition.allCases) { pos in
                    Text(pos.label).tag(pos)
                }
            }
            .pickerStyle(.segmented)

            Toggle("캡처 시작 시 자막 표시", isOn: Binding(
                get: { settings.subtitleAutoShowOnCapture },
                set: { settings.subtitleAutoShowOnCapture = $0 }
            ))

            Toggle("원문 동시 표시", isOn: Binding(
                get: { settings.showSourceText },
                set: { settings.showSourceText = $0 }
            ))

            HStack {
                Button("화면 목록 새로고침") { refreshScreens() }
                Spacer()
                Button(appState.subtitleOverlay.isVisible ? "자막 숨김" : "자막 표시") {
                    if appState.subtitleOverlay.isVisible {
                        appState.subtitleOverlay.hide()
                    } else {
                        appState.subtitleOverlay.show()
                    }
                }
            }
        }
    }

    // MARK: - 제어 HUD

    private var monitorSection: some View {
        let settings = appState.settings
        return Section("제어 HUD") {
            Toggle("제어 HUD 표시", isOn: Binding(
                get: { settings.monitorEnabled },
                set: { settings.monitorEnabled = $0; appState.hud.applyEnabledPolicy() }
            ))
            Toggle("캡처 시작 시 자동 표시", isOn: Binding(
                get: { settings.monitorAutoShowOnCapture },
                set: { settings.monitorAutoShowOnCapture = $0 }
            ))
            .disabled(!settings.monitorEnabled)
            Toggle("캡처 정지 시 숨김", isOn: Binding(
                get: { settings.monitorHideOnStop },
                set: { settings.monitorHideOnStop = $0 }
            ))
            .disabled(!settings.monitorEnabled)
            Button("위치 리셋") { appState.hud.resetPosition() }
        }
    }

    // MARK: - 비용 (M2b, 태스크 C, 스펙 §9.4)

    private var costSection: some View {
        let settings = appState.settings
        let cost = appState.cost
        return Section("비용 (USD)") {
            Toggle("비용 표시 (제어 HUD)", isOn: Binding(
                get: { settings.costHUDEnabled },
                set: { settings.costHUDEnabled = $0 }
            ))
            LabeledContent("세션 — 전송", value: usd(cost.sessionInputUSD))
            LabeledContent("세션 — 수신", value: usd(cost.sessionOutputUSD))
            LabeledContent("세션 — 총", value: usd(cost.sessionTotalUSD))
            LabeledContent("누적 — 전송", value: usd(cost.cumulativeInputUSD))
            LabeledContent("누적 — 수신", value: usd(cost.cumulativeOutputUSD))
            LabeledContent("누적 — 총", value: usd(cost.cumulativeTotalUSD))
            Button("누적 비용 리셋") { cost.resetCumulative() }
            Text("출력 오디오가 비용의 약 85%를 차지합니다(스펙 §9.2). 단가는 프리뷰 기준으로 변동될 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// USD 금액 포맷($0.0000, 소수 4자리).
    private func usd(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    // MARK: - 권한

    private var permissionSection: some View {
        Section("권한") {
            permissionRow(
                title: "마이크",
                status: micStatus,
                action: { PermissionHelper.openMicrophoneSettings() }
            )
            permissionRow(
                title: "시스템 오디오 캡처",
                status: sysAudioStatus,
                action: { PermissionHelper.openSystemAudioSettings() }
            )
            Button("권한 상태 새로고침") { refreshPermissions() }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        status: PermissionHelper.Status,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.needsAction ? Color.orange : Color.secondary)
            Text(title)
            Spacer()
            Text(status.label).foregroundStyle(.secondary)
            Button("시스템 설정 열기", action: action)
                .buttonStyle(.link)
        }
    }

    // MARK: - API 키

    private var apiKeySection: some View {
        Section("API 키") {
            LabeledContent("Gemini API 키") {
                Text(appState.apiKeyLoaded ? "로드됨" : "없음")
                    .foregroundStyle(appState.apiKeyLoaded ? .green : .secondary)
            }
            Text("보안을 위해 키 값은 표시하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 자막 스타일 (M4 placeholder)

    private var subtitleStyleSection: some View {
        Section("자막 스타일") {
            Text("추후 제공 (M4) — 폰트·크기·색상·외곽선·글로우 등")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 헬퍼

    private enum SelectionTag: Hashable {
        case auto
        case systemTap
        case device(String)
    }

    private var currentSelectionTag: SelectionTag {
        switch appState.audio.selection {
        case .auto: return .auto
        case .systemTap: return .systemTap
        case .device(let uid): return .device(uid)
        }
    }

    private func applySelection(_ tag: SelectionTag) {
        let audio = appState.audio
        switch tag {
        case .auto: audio.selectAuto()
        case .systemTap: audio.selectSystemTap()
        case .device(let uid):
            if let device = audio.devices.first(where: { $0.uid == uid }) {
                audio.selectDevice(device)
            }
        }
    }

    private func refreshPermissions() {
        micStatus = PermissionHelper.microphoneStatus()
        sysAudioStatus = PermissionHelper.systemAudioStatus()
    }

    /// 자막 위치 Picker용 화면 목록을 다시 읽는다(모니터 연결/해제 대응).
    private func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return ScreenOption(id: id, label: screen.menuLabel)
        }
    }

    /// 자막 표시 화면 선택지(displayID + 사람이 읽는 이름).
    private struct ScreenOption: Identifiable, Hashable {
        let id: Int
        let label: String
    }
}
