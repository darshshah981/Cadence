import AppKit
import Foundation

enum ScribeNotchContent: Equatable, Sendable {
    case hidden
    case transcribing
    case typingTranscript(String, isSlow: Bool)
    case replacing(source: String, result: ScribeResult)
    case ready(ScribeResult)
    case insertionRecovery(message: String, result: ScribeResult)
    case inserting
    case failure(
        message: String,
        literalTranscript: String?,
        recovery: ScribeNotchFailureRecovery
    )
}

enum ScribeNotchFailureRecovery: Equatable, Sendable {
    case none
    case retryGeneration
    case setUpProvider
    case reviewProvider
    case returnToTargetApp
    case openPermissions

    static func providerRecovery(
        for failure: ScribeProviderFailure?
    ) -> Self? {
        guard let failure else { return nil }
        if failure.category == .setupRequired {
            return .setUpProvider
        }
        switch failure.retryDisposition {
        case .reconnect, .changeConfiguration:
            return .reviewProvider
        case .manualNow, .manualAfterWait:
            return .retryGeneration
        case .none, .updateCadence:
            return nil
        }
    }

    static func contextRecovery(
        for error: ScribeContextError?
    ) -> Self? {
        switch error {
        case .accessibilityDenied:
            return .openPermissions
        case .noFocusedTarget, .targetChanged:
            return .returnToTargetApp
        case .captureCleared:
            return .retryGeneration
        default:
            return nil
        }
    }
}

enum ScribePillPresentation: Equatable, Sendable {
    case hidden
    case listening
    case transcribing
    case scribed
    case failed
}

struct ScribeNotchPresentation: Equatable, Sendable {
    let content: ScribeNotchContent
    let pill: ScribePillPresentation

    var allowsReviewActions: Bool {
        switch content {
        case .ready, .insertionRecovery, .failure:
            return true
        default:
            return false
        }
    }

    var requiresImmediateFocusHandoff: Bool {
        if case .inserting = content {
            return true
        }
        return false
    }

    static func project(
        state: ScribeSessionState,
        literalTranscript: String?,
        failureMessage: String?,
        canRetryGeneration: Bool = false,
        failureRecovery: ScribeNotchFailureRecovery? = nil
    ) -> Self {
        let literal = literalTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch state {
        case .idle, .succeeded, .cancelled:
            return Self(content: .hidden, pill: .hidden)
        case .listening:
            return Self(content: .hidden, pill: .listening)
        case .transcribing:
            return Self(content: .transcribing, pill: .transcribing)
        case .generating:
            return Self(
                content: literal.map { .typingTranscript($0, isSlow: false) } ?? .transcribing,
                pill: .transcribing
            )
        case .generatingSlow:
            return Self(
                content: literal.map { .typingTranscript($0, isSlow: true) } ?? .transcribing,
                pill: .transcribing
            )
        case let .reviewing(result):
            return Self(
                content: .replacing(source: literal ?? "", result: result),
                pill: .transcribing
            )
        case let .insertionRecovery(result):
            return Self(
                content: .insertionRecovery(
                    message: failureMessage
                        ?? "Return to the original app and insertion point. Your draft is still here.",
                    result: result
                ),
                pill: .failed
            )
        case .inserting:
            return Self(content: .inserting, pill: .scribed)
        case .failed:
            return Self(
                content: .failure(
                    message: failureMessage ?? "Compose could not finish this draft.",
                    literalTranscript: literal,
                    recovery: failureRecovery
                        ?? (canRetryGeneration ? .retryGeneration : .none)
                ),
                pill: .failed
            )
        }
    }
}

enum ScribeNotchAutoDismissPolicy {
    static let attentionDelay: Duration = .seconds(6)

    static func delay(
        for presentation: ScribeNotchPresentation
    ) -> Duration? {
        if case .failure = presentation.content {
            return attentionDelay
        }
        return nil
    }
}

enum ScribeCopyOutsideDismissalPolicy {
    static func shouldDismiss(
        clickLocation: NSPoint,
        panelFrame: NSRect?
    ) -> Bool {
        guard let panelFrame else { return true }
        return !panelFrame.contains(clickLocation)
    }
}

enum ScribeNotchGeometry {
    static let surfaceSize = NSSize(width: 330, height: 176)
    static let floatingTopGap: CGFloat = 8
    static let hardwareNotchContentInset: CGFloat = 34
    static let surfaceBottomCornerRadius: CGFloat = 17
    static let hardwareAttachmentShoulderRadius =
        surfaceBottomCornerRadius - 4

    static func expandedFrame(
        screenFrame: NSRect,
        surfaceSize requestedSize: NSSize = surfaceSize,
        hasHardwareNotch: Bool
    ) -> NSRect {
        let size = NSSize(
            width: min(max(0, requestedSize.width), screenFrame.width),
            height: min(max(0, requestedSize.height), screenFrame.height)
        )
        let x = min(
            max(screenFrame.midX - size.width / 2, screenFrame.minX),
            screenFrame.maxX - size.width
        )
        let gap = hasHardwareNotch ? 0 : floatingTopGap
        let y = max(screenFrame.minY, screenFrame.maxY - size.height - gap)
        return NSRect(origin: NSPoint(x: floor(x), y: floor(y)), size: size)
    }
}

enum ScribeNotchPalette {
    static let surfaceHex: UInt32 = 0x000000
}

enum ScribeHUDProjection {
    static func visualState(
        for state: ScribeSessionState,
        replacementCompleted: Bool,
        failureMessage: String? = nil
    ) -> HUDVisualState {
        switch state {
        case .idle, .cancelled:
            return .idle
        case .listening:
            return .scribeRecording
        case .transcribing, .generating, .generatingSlow:
            return .scribeTranscribing
        case .reviewing:
            return replacementCompleted ? .scribed : .scribeTranscribing
        case .inserting:
            return .scribed
        case .succeeded:
            return .idle
        case .insertionRecovery:
            return .error(message: "Draft not inserted")
        case let .failed(_, error):
            return .error(message: failureMessage ?? error.userMessage)
        }
    }
}

enum ScribeHUDRestorationAction: Equatable {
    case hide
    case leaveCurrentHUD
    case showIdle
    case showReadyLogo

    static func resolve(
        requiredPermissionsGranted: Bool,
        isDictationIdle: Bool,
        discardedComposedDraft: Bool = false
    ) -> Self {
        guard isDictationIdle else { return .leaveCurrentHUD }
        if discardedComposedDraft { return .hide }
        return requiredPermissionsGranted ? .showReadyLogo : .showIdle
    }
}
