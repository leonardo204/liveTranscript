import Foundation
import Sparkle

/// Sparkle 기반 자동 업데이트 관리자.
///
/// `SPUStandardUpdaterController`를 보유하고 업데이트 확인/자동확인 토글을 노출한다.
/// 피드는 Info.plist의 `SUFeedURL`(GitHub appcast.xml)을 사용하며, 다운로드된 업데이트는
/// `SUPublicEDKey`(EdDSA 공개키)로 서명 검증된다.
///
/// MenuBarExtra(LSUIElement) 앱에서도 `SPUStandardUpdaterController`는 정상 동작하며,
/// 업데이트 UI는 Sparkle 자체 창으로 표시된다(설정 창의 .regular 전환과 충돌 없음).
@MainActor
@Observable
final class UpdateChecker {
    /// Sparkle 표준 업데이터 컨트롤러. `startingUpdater: true`로 앱 launch 시 업데이터를 가동한다.
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// "지금 업데이트 확인" — 사용자 주도 확인을 트리거한다(업데이트가 있으면 Sparkle 창 표시).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 현재 업데이트 확인이 가능한 상태인지(이미 확인 중이면 false).
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// 자동 업데이트 확인 on/off. Sparkle이 사용자 기본값에 영속화한다.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 표시용 현재 앱 버전("0.1.0 (1)" 형식). 번들 Info.plist에서 읽는다.
    var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
