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

    var body: some View {
        Form {
            inputSection
            vadSection
            monitorSection
            permissionSection
            apiKeySection
            subtitleStyleSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear(perform: refreshPermissions)
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

    // MARK: - 모니터(HUD)

    private var monitorSection: some View {
        let settings = appState.settings
        return Section("모니터 (미니 HUD)") {
            Toggle("모니터 표시", isOn: Binding(
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
}
