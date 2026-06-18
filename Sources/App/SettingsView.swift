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

    // API 키 입력 버퍼(화면에만 존재, 저장 시 Keychain으로만 이동). 저장/삭제 후 비운다.
    @State private var apiKeyInput: String = ""
    // 저장/삭제 실패 등 사용자에게 보여줄 일시 메시지(키 비포함).
    @State private var apiKeyMessage: String?

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
            // 현재 키 출처(값은 표시하지 않음).
            LabeledContent("현재") {
                Text(keySourceLabel)
                    .foregroundStyle(appState.apiKeyLoaded ? .green : .secondary)
            }

            // 키 입력(마스킹). 화면 버퍼에만 존재, 저장 시 Keychain으로만 이동.
            SecureField("Gemini API 키 입력", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKeyInput) {
                    // 입력이 바뀌면 직전 테스트 결과가 무의미하므로 초기화.
                    appState.resetConnectionTestState()
                    apiKeyMessage = nil
                }

            // 흐름: 입력 → 연결 테스트(성공) → 저장. 연결 테스트를 저장보다 앞(왼쪽)에 둔다.
            HStack {
                Button("연결 테스트") { appState.testConnection(candidateKey: apiKeyInput) }
                    .disabled((apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.apiKeyLoaded) || isTesting)
                Button("저장") { saveAPIKey() }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isTestSucceeded)
                Spacer()
                Button("삭제", role: .destructive) { clearAPIKey() }
                    .disabled(appState.keySource != .keychain)
            }

            // 연결 테스트 상태 표시.
            connectionTestStatusView

            // 저장/삭제 결과 메시지(있을 때만).
            if let message = apiKeyMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("키를 입력하고 먼저 연결 테스트에 성공해야 저장할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("보안을 위해 키 값은 표시하지 않습니다. 저장된 키는 macOS Keychain에 보관됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 연결 테스트 진행/결과 표시(키 비포함).
    @ViewBuilder
    private var connectionTestStatusView: some View {
        switch appState.connectionTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("테스트 중…").foregroundStyle(.secondary)
            }
        case .success:
            Label {
                Text("연결됨").foregroundStyle(.green)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.green)
            }
        case .failure(let reason):
            Label {
                Text("연결 실패: \(reason)").foregroundStyle(.red)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.red)
            }
        }
    }

    /// 테스트 진행 중 여부(버튼 비활성화용).
    private var isTesting: Bool {
        if case .testing = appState.connectionTestState { return true }
        return false
    }

    /// 연결 테스트가 성공했는지 여부(저장 버튼 활성화 조건).
    private var isTestSucceeded: Bool {
        if case .success = appState.connectionTestState { return true }
        return false
    }

    /// 현재 키 출처 라벨.
    private var keySourceLabel: String {
        switch appState.keySource {
        case .keychain: return "저장된 키 사용 중"
        case .none:     return "키 없음 — 키를 입력하세요"
        }
    }

    private func saveAPIKey() {
        switch appState.saveAPIKey(apiKeyInput) {
        case .success:
            apiKeyInput = ""
            apiKeyMessage = "키를 저장했습니다."
        case .failure:
            // 사유 원문에 키가 섞이지 않도록 일반화된 메시지만 노출.
            apiKeyMessage = "키 저장에 실패했습니다."
        }
    }

    private func clearAPIKey() {
        switch appState.clearAPIKey() {
        case .success:
            apiKeyInput = ""
            apiKeyMessage = "저장된 키를 삭제했습니다."
        case .failure:
            apiKeyMessage = "키 삭제에 실패했습니다."
        }
    }

    // MARK: - 자막 스타일 (M4, FR-7 / 스펙 §5.5)

    private var subtitleStyleSection: some View {
        let settings = appState.settings
        return Section("자막 스타일") {
            stylePreview
            fontFamilyPicker
            fontSizeSlider
            weightPicker
            alignPicker
            maxLinesStepper
            textColorPicker
            strokeControls
            glowControls
            backgroundControls
            Button("스타일 기본값으로 리셋") { settings.resetSubtitleStyle() }
        }
    }

    /// 실시간 미리보기(설정 변경 즉시 반영). 오버레이와 동일한 StyledSubtitleText 사용.
    @ViewBuilder
    private var stylePreview: some View {
        let settings = appState.settings
        let style = SubtitleStyle(settings: settings)
        ZStack {
            // 대표 배경(밝음~어두움) 위에서 가독성 확인.
            LinearGradient(
                colors: [Color(white: 0.55), Color(white: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            Group {
                if style.backgroundEnabled {
                    StyledSubtitleText(
                        text: "안녕하세요, 자막 미리보기입니다",
                        size: settings.subtitleFontSize,
                        style: style
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(style.backgroundOpacity))
                    )
                } else {
                    StyledSubtitleText(
                        text: "안녕하세요, 자막 미리보기입니다",
                        size: settings.subtitleFontSize,
                        style: style
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var fontFamilyPicker: some View {
        let settings = appState.settings
        Picker("폰트", selection: Binding(
            get: { settings.subtitleFontName },
            set: { settings.subtitleFontName = $0 }
        )) {
            Text("시스템 기본").tag("")
            ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var fontSizeSlider: some View {
        let settings = appState.settings
        VStack(alignment: .leading) {
            LabeledContent("크기", value: "\(Int(settings.subtitleFontSize)) pt")
            Slider(
                value: Binding(
                    get: { settings.subtitleFontSize },
                    set: { settings.subtitleFontSize = $0 }
                ),
                in: 16...72,
                step: 1
            )
        }
    }

    @ViewBuilder
    private var weightPicker: some View {
        let settings = appState.settings
        Picker("두께", selection: Binding(
            get: { settings.subtitleFontWeight },
            set: { settings.subtitleFontWeight = $0 }
        )) {
            ForEach(SubtitleFontWeight.allCases) { w in
                Text(w.label).tag(w)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var alignPicker: some View {
        let settings = appState.settings
        Picker("정렬", selection: Binding(
            get: { settings.subtitleTextAlign },
            set: { settings.subtitleTextAlign = $0 }
        )) {
            ForEach(SubtitleTextAlign.allCases) { a in
                Text(a.label).tag(a)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var maxLinesStepper: some View {
        let settings = appState.settings
        Stepper(
            "최대 줄수: \(settings.subtitleMaxLines)",
            value: Binding(
                get: { settings.subtitleMaxLines },
                set: { settings.subtitleMaxLines = $0 }
            ),
            in: 1...4
        )
    }

    @ViewBuilder
    private var textColorPicker: some View {
        let settings = appState.settings
        ColorPicker("글자색", selection: Binding(
            get: { settings.subtitleTextColor },
            set: { settings.subtitleTextColor = $0 }
        ), supportsOpacity: true)
    }

    @ViewBuilder
    private var strokeControls: some View {
        let settings = appState.settings
        Toggle("외곽선", isOn: Binding(
            get: { settings.subtitleStrokeEnabled },
            set: { settings.subtitleStrokeEnabled = $0 }
        ))
        if settings.subtitleStrokeEnabled {
            ColorPicker("외곽선 색", selection: Binding(
                get: { settings.subtitleStrokeColor },
                set: { settings.subtitleStrokeColor = $0 }
            ), supportsOpacity: true)
        }
    }

    @ViewBuilder
    private var glowControls: some View {
        let settings = appState.settings
        Toggle("글로우", isOn: Binding(
            get: { settings.subtitleGlowEnabled },
            set: { settings.subtitleGlowEnabled = $0 }
        ))
        if settings.subtitleGlowEnabled {
            ColorPicker("글로우 색", selection: Binding(
                get: { settings.subtitleGlowColor },
                set: { settings.subtitleGlowColor = $0 }
            ), supportsOpacity: true)
            VStack(alignment: .leading) {
                LabeledContent("글로우 반경", value: "\(Int(settings.subtitleGlowRadius))")
                Slider(
                    value: Binding(
                        get: { settings.subtitleGlowRadius },
                        set: { settings.subtitleGlowRadius = $0 }
                    ),
                    in: 0...30,
                    step: 1
                )
            }
        }
    }

    @ViewBuilder
    private var backgroundControls: some View {
        let settings = appState.settings
        Toggle("배경 박스", isOn: Binding(
            get: { settings.subtitleBackgroundEnabled },
            set: { settings.subtitleBackgroundEnabled = $0 }
        ))
        if settings.subtitleBackgroundEnabled {
            VStack(alignment: .leading) {
                LabeledContent("배경 불투명도", value: String(format: "%.0f%%", settings.subtitleBackgroundOpacity * 100))
                Slider(
                    value: Binding(
                        get: { settings.subtitleBackgroundOpacity },
                        set: { settings.subtitleBackgroundOpacity = $0 }
                    ),
                    in: 0...1
                )
            }
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
