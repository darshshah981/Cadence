import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let onDeviceScribeLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "OnDeviceScribe")

enum OnDeviceScribeAvailability: Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable
    case unsupportedOS

    var unavailableReason: String? {
        switch self {
        case .available:
            return nil
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence. Choose a cloud provider to use Compose."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use Compose without an API key."
        case .modelNotReady:
            return "Apple Intelligence is preparing its model. Try again when its download is complete."
        case .unavailable:
            return "Apple Intelligence is unavailable. Check Apple Intelligence in System Settings or choose a cloud provider."
        case .unsupportedOS:
            return "On-device Compose requires macOS 26 or later and Apple Intelligence. Choose a cloud provider on this Mac."
        }
    }
}

/// Availability is read afresh so enabling Apple Intelligence or completing
/// its model download does not require a Cadence reinstall or restart.
enum OnDeviceScribeService {
    static var isAvailable: Bool {
        availability == .available
    }

    static var unavailableReason: String? {
        availability.unavailableReason
    }

    static var availability: OnDeviceScribeAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unavailable
            }
        }
        #endif
        return .unsupportedOS
    }
}
