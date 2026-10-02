import Foundation

/// Explicit global style choices only. No source text, inferred traits, app
/// identity, or arbitrary prompt instructions can be stored in this payload.
struct ComposeGlobalWritingDefaults: Codable, Equatable, Sendable {
    enum Tone: String, Codable, CaseIterable, Sendable {
        case automatic, formal, casual, polite, professional, warm, upbeat
        var title: String { self == .automatic ? "Use existing style" : rawValue.capitalized }
        var value: ScribeWritingTone? {
            switch self {
            case .automatic: nil
            case .formal: .formal
            case .casual: .casual
            case .polite: .polite
            case .professional: .professional
            case .warm: .warm
            case .upbeat: .upbeat
            }
        }
    }
    var isEnabled = false
    var tone: Tone = .automatic
    var preferConcise = false

    var values: [ComposeWritingPreferenceValue] {
        guard isEnabled else { return [] }
        return (tone.value.map { [.tone($0)] } ?? [])
            + (preferConcise ? [.concise] : [])
    }
}

/// The first explicitly named app profile. It has no free-form prompt or
/// inferred traits; Reset removes its two optional choices.
struct ComposeTextEditWritingDefaults: Equatable, Sendable {
    var tone: ComposeGlobalWritingDefaults.Tone = .automatic
    var preferConcise = false

    var values: [ComposeWritingPreferenceValue] {
        (tone.value.map { [.tone($0)] } ?? [])
            + (preferConcise ? [.concise] : [])
    }
}
