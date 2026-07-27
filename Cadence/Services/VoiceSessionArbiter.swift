import Foundation

enum VoiceSessionKind: String, Equatable, Sendable {
    case dictation
    case scribe
    case meeting
    case microphoneCheck

    var displayName: String {
        switch self {
        case .dictation: return "dictation"
        case .scribe: return "Compose"
        case .meeting: return "meeting"
        case .microphoneCheck: return "microphone check"
        }
    }
}

struct VoiceSessionLease: Equatable, Sendable {
    let id: UUID
    let kind: VoiceSessionKind
}

enum VoiceSessionArbiterError: Error, Equatable, Sendable {
    case busy(VoiceSessionKind)
}

@MainActor
final class VoiceSessionArbiter {
    private var activeLease: VoiceSessionLease?

    var activeKind: VoiceSessionKind? { activeLease?.kind }

    func acquire(for kind: VoiceSessionKind) throws -> VoiceSessionLease {
        if let activeLease {
            throw VoiceSessionArbiterError.busy(activeLease.kind)
        }
        let lease = VoiceSessionLease(id: UUID(), kind: kind)
        activeLease = lease
        return lease
    }

    func release(_ lease: VoiceSessionLease) {
        guard activeLease == lease else { return }
        activeLease = nil
    }
}
