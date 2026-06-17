import Foundation
import AVFoundation
import AppKit

/// 권한 상태 조회 + 시스템 설정 deep link (M1.5 피드백 #3).
///
/// 마이크 권한(AVCaptureDevice)과 시스템 오디오 캡처 권한(Core Audio Tap, TCC)을
/// 다루며, 거부/미결정 시 사용자를 macOS "개인정보 보호 및 보안" 설정의 해당 pane으로
/// 직접 이동시키는 액션을 제공한다.
///
/// - 마이크: `AVCaptureDevice.authorizationStatus(for: .audio)`로 정확히 조회 가능.
/// - 시스템 오디오: macOS는 Core Audio Tap 권한을 사전 조회하는 공개 API를 제공하지 않는다.
///   첫 tap 생성 시 OS가 TCC 프롬프트를 띄우므로, 여기서는 "안내/설정 열기"만 제공하고
///   상태는 `.unknown`으로 둔다(실제 거부는 캡처 시 `lastErrorMessage`로 표면화됨).
@MainActor
enum PermissionHelper {

    /// 권한 상태(UI 표시용).
    enum Status: Equatable {
        /// 아직 묻지 않음(최초 실행).
        case notDetermined
        /// 허용됨.
        case authorized
        /// 거부됨 — 시스템 설정에서 직접 켜야 함.
        case denied
        /// 시스템 정책으로 제한됨.
        case restricted
        /// 조회 불가(시스템 오디오 등).
        case unknown

        /// 한국어 라벨.
        var label: String {
            switch self {
            case .notDetermined: return "미요청"
            case .authorized: return "허용됨"
            case .denied: return "거부됨"
            case .restricted: return "제한됨"
            case .unknown: return "확인 불가"
            }
        }

        /// 사용자가 조치(설정 열기)를 취해야 하는 상태인지.
        var needsAction: Bool {
            self == .denied || self == .restricted
        }

        /// 표시용 아이콘(SF Symbol).
        var symbolName: String {
            switch self {
            case .authorized: return "checkmark.circle.fill"
            case .denied, .restricted: return "exclamationmark.triangle.fill"
            case .notDetermined: return "questionmark.circle"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    // MARK: - 상태 조회

    /// 마이크 권한 상태.
    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// 시스템 오디오 캡처(Core Audio Tap) 권한 상태.
    /// 사전 조회 API가 없어 항상 `.unknown`(첫 캡처 시 OS가 프롬프트). 14.4 미만은 미지원.
    static func systemAudioStatus() -> Status {
        if #available(macOS 14.4, *) {
            return .unknown
        }
        return .restricted
    }

    // MARK: - Deep link

    /// 마이크 권한 설정 pane을 연다.
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// 시스템 오디오/화면 캡처 권한 pane을 연다.
    /// macOS는 시스템 오디오 캡처를 화면 녹화(ScreenCapture) TCC 카테고리와 함께 묶어 표시한다.
    static func openSystemAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// 개인정보 보호 및 보안 루트 pane을 연다(폴백).
    static func openPrivacyRoot() {
        open("x-apple.systempreferences:com.apple.preference.security")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
