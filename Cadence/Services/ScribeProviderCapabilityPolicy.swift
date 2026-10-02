import Foundation

/// Validates Cadence's declared provider-action contract before generation.
/// It does not infer task complexity and never selects or contacts another provider.
enum ScribeProviderCapabilityPolicy {
    static func validate(
        input: ProviderSafeScribeInput,
        profile: ScribeProviderCapabilityProfile,
        requirements: ScribeProviderCapabilityRequirements
    ) throws {
        guard profile.availability == .available else {
            throw ScribeProviderCapabilityRejection.unavailable
        }
        for modality in requirements.inputModalities.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard profile.supportedInputModalities.contains(modality) else {
                throw ScribeProviderCapabilityRejection.unsupportedModality(modality)
            }
        }
        for task in requirements.taskRequirements.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard profile.supportedTaskRequirements.contains(task) else {
                throw ScribeProviderCapabilityRejection.unsupportedTask(task)
            }
        }
        let bytes = input.systemMessage.utf8.count + input.userMessage.utf8.count
            + (input.preparedDraft?.utf8.count ?? 0)
        guard bytes <= profile.maximumCompiledRequestUTF8Bytes else {
            throw ScribeProviderCapabilityRejection.inputTooLarge(
                actualUTF8Bytes: bytes,
                maximumUTF8Bytes: profile.maximumCompiledRequestUTF8Bytes
            )
        }
    }
}
