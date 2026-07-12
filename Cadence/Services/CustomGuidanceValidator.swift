import Foundation

enum CustomGuidanceValidator {
    static func validate(_ input: String) throws -> ScribeCustomGuidance? {
        let normalized = input.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try ScribeCustomGuidance(normalized)
    }
}
