import Foundation

/// A small, explicit set of recipient action limits that can be checked after
/// generation. These are omission guards, not a general semantic model.
enum ScribeRecipientRestriction: String, CaseIterable, Codable, Equatable, Sendable {
    /// The recipient must not make any kind of change.
    case noChanges
    /// The recipient must not change source code; non-code work is not implied.
    case noCodeChanges
    /// The recipient must not edit files; this remains distinct from code-only.
    case noFileEdits
    /// Configuration remains unchanged, independently of code or file limits.
    case noConfigurationChanges
}

enum ScribeRecipientRestrictionValidationError: Error, Equatable, Sendable {
    case missing(ScribeRecipientRestriction)
}
