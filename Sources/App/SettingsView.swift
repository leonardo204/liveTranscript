import SwiftUI

/// 설정 창 내용 (M1.5 피드백 #2, M5에서 사이드바 레이아웃으로 재구성).
///
/// 항목이 늘어나며 상단 TabView(8탭)가 폭을 초과해 오버플로 메뉴가 생겼다.
/// Xcode/시스템 설정 방식의 사이드바 레이아웃(`NavigationSplitView`)으로 전환한다:
/// 왼쪽 사이드바에서 8개 카테고리(입력 / 자막 / 오디오 / 제어 HUD / 비용 / 권한 / API 키 / 일반)를
/// 선택하면 오른쪽 detail에 해당 콘텐츠가 표시된다.
/// 각 카테고리 콘텐츠는 기존 grouped Form 계산 프로퍼티를 그대로 재사용한다.
/// 모든 변경은 기존 `AudioInputManager`/`SettingsStore`/`HUDController` 및
/// `AppState.applyAudioOutputPolicy()`에 즉시 반영된다.
struct SettingsView: View {
    var appState: AppState

    /// 설정 카테고리(사이드바 항목 = detail 콘텐츠). 라벨/아이콘을 함께 정의한다.
    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case input, subtitle, audio, monitor, cost, permission, apiKey, general
        var id: String { rawValue }
        var label: String {
            switch self {
            case .input: "입력"
            case .subtitle: "자막"
            case .audio: "오디오"
            case .monitor: "제어 HUD"
            case .cost: "비용"
            case .permission: "권한"
            case .apiKey: "API 키"
            case .general: "일반"
            }
        }
        var systemImage: String {
            switch self {
            case .input: "mic"
            case .subtitle: "captions.bubble"
            case .audio: "speaker.wave.2"
            case .monitor: "macwindow"
            case .cost: "dollarsign.circle"
            case .permission: "lock.shield"
            case .apiKey: "key"
            case .general: "gearshape"
            }
        }
    }

    // 사이드바에서 선택된 카테고리(Optional 바인딩 — List selection 요구사항).
    @State private var selection: SettingsCategory? = .input

    // 권한 상태는 창이 뜰 때/새로고침 시 다시 조회한다(시스템 설정에서 바꾸고 돌아올 수 있음).
    @State private var micStatus: PermissionHelper.Status = .unknown
    @State private var sysAudioStatus: PermissionHelper.Status = .unknown

    // 자막 위치 선택용 화면 목록(연결/해제 시 새로고침).
    @State private var screens: [ScreenOption] = []

    // API 키 입력 버퍼(화면에만 존재, 저장 시 Keychain으로만 이동). 저장/삭제 후 비운다.
    @State private var apiKeyInput: String = ""
    // 저장/삭제 실패 등 사용자에게 보여줄 일시 메시지(키 비포함).
    @State private var apiKeyMessage: String?

    // 설정 초기화 확인 다이얼로그 표시 여부(일반 탭).
    @State private var showResetConfirm = false

    // 번역 오디오 재생 ON 시 표시할 경고 팝업(입력 직접 캡쳐 전환 + 출력 선택 안내).
    @State private var showAudioOutputWarning = false
    // 번역 오디오 출력 장치 후보 목록(오디오 탭 onAppear/새로고침 시 갱신).
    @State private var outputDevices: [AudioOutputDevice] = []

    var body: some View {
        NavigationSplitView {
            // 사이드바: 8개 카테고리 목록. selection은 Optional 바인딩.
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.label, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .listStyle(.sidebar)
            // 자동으로 추가되는 사이드바 토글 버튼 제거(사이드바는 항상 표시 — 타이틀바 단순화).
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // detail: 선택된 카테고리의 콘텐츠(기존 grouped Form 재사용).
            // 선택이 없으면 입력으로 폴백한다.
            let category = selection ?? .input
            // 타이틀바에 카테고리명을 띄우지 않는다(사이드바 선택으로 충분 — 타이틀바 단순화).
            detailView(for: category)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 760, height: 580)
        .onAppear {
            refreshPermissions()
            refreshScreens()
            outputDevices = AudioDeviceEnumerator.outputDevices()
        }
    }

    /// 카테고리별 detail 콘텐츠 매핑. 콘텐츠는 모두 기존 grouped Form 계산 프로퍼티.
    @ViewBuilder
    private func detailView(for category: SettingsCategory) -> some View {
        switch category {
        case .input: inputTab
        case .subtitle: subtitleTab
        case .audio: audioTab
        case .monitor: monitorTab
        case .cost: costTab
        case .permission: permissionTab
        case .apiKey: apiKeyTab
        case .general: generalTab
        }
    }

    // MARK: - 카테고리 콘텐츠 (각 콘텐츠는 자체 grouped Form)

    private var inputTab: some View {
        Form {
            inputSection
            vadSection
        }
        .formStyle(.grouped)
    }

    private var subtitleTab: some View {
        Form {
            translationLanguageSection
            subtitlePositionSection
            subtitleStyleSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 번역 언어

    /// 번역 대상 언어 선택지(BCP-47 코드 + 한글 라벨). Picker selection 타입은 String.
    /// 기본값 ko가 포함되어 있어 현재값이 항상 목록에 존재한다(빈 선택 방지).
    private static let languageOptions: [(code: String, label: String)] = [
        ("ko", "한국어"),
        ("en", "English"),
        ("ja", "日本語"),
        ("zh", "中文(简体)"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("vi", "Tiếng Việt"),
        ("th", "ไทย"),
        ("id", "Bahasa Indonesia"),
    ]

    /// 번역 대상 언어 선택 Section. 번역 중 언어를 바꾸면 즉시 Gemini가 재연결되어 적용된다.
    private var translationLanguageSection: some View {
        Section("번역") {
            Picker("번역 언어", selection: Binding(
                get: { appState.settings.targetLanguageCode },
                set: {
                    appState.settings.targetLanguageCode = $0
                    appState.reloadTranslationSession()
                }
            )) {
                ForEach(Self.languageOptions, id: \.code) { opt in
                    Text(opt.label).tag(opt.code)
                }
            }
            .pickerStyle(.menu)
            Text("번역 중 언어를 바꾸면 즉시 재연결되어 적용됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioTab: some View {
        Form {
            audioSection
        }
        .formStyle(.grouped)
    }

    private var monitorTab: some View {
        Form {
            monitorSection
        }
        .formStyle(.grouped)
    }

    private var costTab: some View {
        Form {
            costSection
        }
        .formStyle(.grouped)
    }

    private var permissionTab: some View {
        Form {
            permissionSection
        }
        .formStyle(.grouped)
    }

    private var apiKeyTab: some View {
        Form {
            apiKeySection
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            updateSection
            generalSection
        }
        .formStyle(.grouped)
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
            // VAD 방식 선택: 클라이언트(Silero) ↔ 서버(Gemini 자동).
            // - "client": audio.vadEnabled = true  → 발화 구간만 전송(서버 VAD off + activity 신호).
            // - "server": audio.vadEnabled = false → 연속 전송(서버 자동 VAD가 발화 감지).
            // 번역 중 방식을 바꾸면 setup(realtimeInputConfig)이 달라지므로 재연결해 갱신한다
            // (안 그러면 double-VAD 재발 또는 누락).
            Picker("VAD 방식", selection: Binding(
                get: { audio.vadEnabled ? "client" : "server" },
                set: { newValue in
                    audio.vadEnabled = (newValue == "client")
                    appState.reloadTranslationSession()
                }
            )) {
                Text("클라이언트(Silero)").tag("client")
                Text("서버(Gemini 자동)").tag("server")
            }
            .pickerStyle(.segmented)

            Text("클라이언트: 음악/무음을 걸러 비용 절감, 소음에 강함. 서버: 연속 전송으로 Gemini가 발화를 감지(무음도 과금). 초기 반복이 심하면 서버 방식을 시도해 보세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 모델 상태: 클라이언트 방식일 때만 Silero 로드 상태가 의미 있다.
            // 서버 방식은 클라이언트 VAD를 사용하지 않으므로 별도 표기한다.
            if audio.vadEnabled {
                LabeledContent("모델 상태", value: audio.vadStatus.menuLabel)
            } else {
                LabeledContent("모델 상태", value: "서버 VAD 사용 중")
            }
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

            // 영역(상/중/하) 안에서의 세부 세로 위치(0=위, 1=아래) 미세 조정.
            VStack(alignment: .leading) {
                Slider(value: Binding(
                    get: { settings.subtitleVerticalOffset },
                    set: {
                        settings.subtitleVerticalOffset = $0
                        appState.subtitleOverlay.applyPositionChange()
                    }
                ), in: 0...1) {
                    Text("세부 위치")
                } minimumValueLabel: {
                    Text("위")
                } maximumValueLabel: {
                    Text("아래")
                }
                Text("선택한 영역(상/중/하) 안에서 자막을 위↔아래로 미세 조정합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("캡처 시작 시 자막 표시", isOn: Binding(
                get: { settings.subtitleAutoShowOnCapture },
                set: { settings.subtitleAutoShowOnCapture = $0 }
            ))

            Toggle("원문 동시 표시", isOn: Binding(
                get: { settings.showSourceText },
                set: { settings.showSourceText = $0 }
            ))

            // 테스트 자막: 토글 ON 동안 샘플 자막을 오버레이에 고정 표시한다(페이드 없음).
            // 이 상태에서 위 세부위치/세로위치/스타일을 바꾸면 실시간으로 따라 이동/갱신된다.
            // 번역 중에는 실자막을 덮어쓰지 않도록 비활성화한다.
            Toggle("테스트 자막 표시", isOn: Binding(
                get: { appState.isTestSubtitleOn },
                set: { appState.setTestSubtitle($0) }
            ))
            .disabled(appState.isRunning)

            Button("화면 목록 새로고침") { refreshScreens() }

            if appState.isRunning {
                Text("번역 정지 상태에서만 미리볼 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - 오디오

    /// 오디오 설정용 양방향 바인딩 헬퍼. set 시 즉시 `applyAudioOutputPolicy()`를
    /// 호출해 재생/덕킹 정책을 실시간으로 반영한다.
    private func audioBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Value>
    ) -> Binding<Value> {
        let settings = appState.settings
        return Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                appState.applyAudioOutputPolicy()
            }
        )
    }

    private var audioSection: some View {
        let settings = appState.settings
        return Group {
            Section("번역 오디오") {
                // 재생 ON 플로우: 끔→켬 순간 입력을 직접 캡쳐(systemTap)로 자동 전환하고
                // 경고 팝업을 띄운다(피드백 방지 + 출력 장치 선택 유도).
                Toggle("번역 오디오 재생", isOn: Binding(
                    get: { settings.translatedAudioPlaybackEnabled },
                    set: { newValue in
                        let wasOff = !settings.translatedAudioPlaybackEnabled
                        settings.translatedAudioPlaybackEnabled = newValue
                        if newValue && wasOff {
                            appState.audio.selectSystemTap()   // 입력 → 직접 캡쳐(피드백 방지)
                            outputDevices = AudioDeviceEnumerator.outputDevices()
                            showAudioOutputWarning = true       // 경고 팝업
                        }
                        appState.applyAudioOutputPolicy()
                    }
                ))

                // 재생이 켜져 있을 때만 출력 장치 선택 드롭다운을 토글 아래에 표시한다.
                if settings.translatedAudioPlaybackEnabled {
                    Picker("출력 장치", selection: Binding(
                        get: { settings.translatedAudioOutputDeviceUID ?? "" },
                        set: {
                            settings.translatedAudioOutputDeviceUID = $0.isEmpty ? nil : $0
                            appState.applyAudioOutputPolicy()
                        }
                    )) {
                        Text("시스템 기본").tag("")
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("출력 장치 새로고침") {
                        outputDevices = AudioDeviceEnumerator.outputDevices()
                    }
                }

                // B3: 재생 off일 때 아래 컨트롤이 회색(disabled)이 되어 on/off 상태가 안 보이던 혼동 제거.
                // disabled를 걷어내 항상 색상으로 상태가 보이게 하고, 적용 여부는 caption으로 안내한다.
                if !settings.translatedAudioPlaybackEnabled {
                    Text("번역 오디오 재생을 켜야 아래 볼륨/덕킹이 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading) {
                    // B3: .disabled 제거 — 재생이 off여도 값은 미리 설정 가능(정책은 재생 on일 때만 적용).
                    Slider(
                        value: audioBinding(\.translatedAudioVolume),
                        in: 0...1
                    ) {
                        Text("번역 볼륨")
                    }
                    LabeledContent("번역 볼륨", value: "\(Int(settings.translatedAudioVolume * 100))%")
                }
            }

            Section("원문(시스템) 오디오") {
                // B3: .disabled 제거 — 토글 색상으로 on/off가 항상 구분되게 한다.
                Toggle("원문 볼륨 덕킹", isOn: audioBinding(\.originalAudioDuckingEnabled))

                VStack(alignment: .leading) {
                    // B3: .disabled 제거 — 덕킹 off여도 값 미리 설정 가능.
                    Slider(
                        value: audioBinding(\.originalAudioDuckVolume),
                        in: 0...1
                    ) {
                        Text("원문 볼륨")
                    }
                    LabeledContent("원문 볼륨", value: "\(Int(settings.originalAudioDuckVolume * 100))%")
                }

                Text("번역 오디오도 같은 출력 장치로 나가므로 원문 볼륨을 낮추면 번역 소리도 함께 작아집니다. 0%로 두면 번역도 들리지 않습니다. (macOS는 앱별 볼륨 제어를 지원하지 않습니다.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("번역 오디오 재생", isPresented: $showAudioOutputWarning) {
            Button("확인") {}
        } message: {
            Text("입력을 ‘시스템 직접 캡쳐’로 전환했습니다. 스피커/헤드폰으로 듣고 피드백을 막으려면 아래에서 번역 오디오 ‘출력 장치’를 선택하세요. 출력을 BlackHole 등 캡처용 가상 장치로 두면 번역이 들리지 않고 피드백 루프가 생깁니다.")
        }
    }

    // MARK: - 업데이트 (Sparkle 자동 업데이트)

    /// 자동 업데이트 섹션. 현재 버전 표시 + 자동확인 토글 + 즉시 확인 버튼.
    /// 실제 업데이트 검증은 Info.plist `SUPublicEDKey`(EdDSA 공개키) 교체 후 동작한다.
    private var updateSection: some View {
        Section("업데이트") {
            LabeledContent("현재 버전", value: appState.updates.currentVersion)
            Toggle("자동으로 업데이트 확인", isOn: Binding(
                get: { appState.updates.automaticallyChecksForUpdates },
                set: { appState.updates.automaticallyChecksForUpdates = $0 }
            ))
            Button("지금 업데이트 확인") { appState.updates.checkForUpdates() }
                .disabled(!appState.updates.canCheckForUpdates)
        }
    }

    // MARK: - 일반 (설정 초기화)

    private var generalSection: some View {
        Section("설정 초기화") {
            Button("설정 초기화", role: .destructive) { showResetConfirm = true }
            Text("입력/자막/스타일/제어 HUD/오디오/비용 누적/위치 등 모든 설정이 기본값으로 되돌아갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "모든 설정을 초기 상태로 되돌릴까요?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("설정만 초기화") { appState.resetSettings(includingAPIKey: false); afterReset() }
            Button("설정 + API 키 삭제", role: .destructive) { appState.resetSettings(includingAPIKey: true); afterReset() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("API 키도 함께 삭제할지 선택하세요. ‘설정만 초기화’는 저장된 API 키를 유지합니다.")
        }
    }

    /// 설정 초기화 후 화면 상태를 동기화한다(입력 버퍼/메시지/권한/화면 목록).
    private func afterReset() {
        apiKeyInput = ""
        apiKeyMessage = nil
        refreshPermissions()
        refreshScreens()
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
