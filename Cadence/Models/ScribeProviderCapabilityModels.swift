import Foundation

/// The kind of input a provider profile is permitted to receive. This describes
/// Cadence's dispatch contract; it is not a claim about every model capability.
enum ScribeProviderInputModality: String, CaseIterable, Equatable, Hashable, Sendable {
    case text
    case image
}

/// A request capability Cadence can explicitly require before dispatching.
/// Tasks are independently enabled; accepting direct drafting does not imply
/// that previous-draft or context payloads are permitted.
enum ScribeProviderTaskRequirement: String, CaseIterable, Equatable, Hashable, Sendable {
    case directDraft
    case draftRefinement
    case selectedTextRewrite
}

enum ScribeProviderCapabilityAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// Provider context windows are provider/model properties. Cadence must not
/// infer one from its own request-size ceiling when no provider value is known.
enum ScribeProviderContextCapacity: Equatable, Sendable {
    case unknown
}

/// Quality evidence is intentionally separate from dispatch availability.
/// A provider can be available while Cadence has not evaluated a task category.
enum ScribeProviderQualityStatus: Equatable, Sendable {
    case notEvaluated
}

struct ScribeProviderCapabilityRequirements: Equatable, Sendable {
    let inputModalities: Set<ScribeProviderInputModality>
    let taskRequirements: Set<ScribeProviderTaskRequirement>

    init(
        inputModalities: Set<ScribeProviderInputModality> = [.text],
        taskRequirements: Set<ScribeProviderTaskRequirement> = [.directDraft]
    ) {
        self.inputModalities = inputModalities
        self.taskRequirements = taskRequirements
    }

    static let directTextDraft = ScribeProviderCapabilityRequirements()
    static let draftRefinement = ScribeProviderCapabilityRequirements(taskRequirements: [.draftRefinement])
    static let selectedTextRewrite = ScribeProviderCapabilityRequirements(taskRequirements: [.selectedTextRewrite])
}

/// Immutable, app-owned dispatch limits for one provider action.
/// `maximumCompiledRequestUTF8Bytes` limits system, user, and prepared-draft text
/// Cadence compiles. It is a conservative application limit, not a provider
/// token limit or a statement of a model's context-window capacity.
struct ScribeProviderCapabilityProfile: Equatable, Sendable {
    static let currentRevision = 3
    static let localMaximumCompiledRequestUTF8Bytes = 12 * 1_024
    static let configuredCloudMaximumCompiledRequestUTF8Bytes = 64 * 1_024

    let revision: Int
    let availability: ScribeProviderCapabilityAvailability
    let supportedInputModalities: Set<ScribeProviderInputModality>
    let supportedTaskRequirements: Set<ScribeProviderTaskRequirement>
    let maximumCompiledRequestUTF8Bytes: Int
    let providerContextCapacity: ScribeProviderContextCapacity
    let qualityStatus: ScribeProviderQualityStatus

    init(
        revision: Int = Self.currentRevision,
        availability: ScribeProviderCapabilityAvailability = .available,
        supportedInputModalities: Set<ScribeProviderInputModality> = [.text],
        supportedTaskRequirements: Set<ScribeProviderTaskRequirement> = [.directDraft],
        maximumCompiledRequestUTF8Bytes: Int,
        providerContextCapacity: ScribeProviderContextCapacity = .unknown,
        qualityStatus: ScribeProviderQualityStatus = .notEvaluated
    ) {
        self.revision = revision
        self.availability = availability
        self.supportedInputModalities = supportedInputModalities
        self.supportedTaskRequirements = supportedTaskRequirements
        self.maximumCompiledRequestUTF8Bytes = maximumCompiledRequestUTF8Bytes
        self.providerContextCapacity = providerContextCapacity
        self.qualityStatus = qualityStatus
    }

    static func defaultProfile(for destination: ScribeEgressDestination) -> Self {
        Self(
            supportedTaskRequirements: destination == .legacyLocal
                ? [.directDraft, .draftRefinement, .selectedTextRewrite] : [.directDraft],
            maximumCompiledRequestUTF8Bytes: destination.isRemote
                ? configuredCloudMaximumCompiledRequestUTF8Bytes
                : localMaximumCompiledRequestUTF8Bytes
        )
    }
}

enum ScribeProviderCapabilityRejection: Error, Equatable, Sendable {
    case unavailable
    case unsupportedModality(ScribeProviderInputModality)
    case unsupportedTask(ScribeProviderTaskRequirement)
    case inputTooLarge(actualUTF8Bytes: Int, maximumUTF8Bytes: Int)

    var userMessage: String {
        switch self {
        case .unavailable:
            return "The selected provider is unavailable. Your original words are still available."
        case .unsupportedModality, .unsupportedTask:
            return "The selected provider cannot use this kind of input. Your original words are still available."
        case .inputTooLarge:
            return "This request is too long for the selected provider's Compose limit. Record a shorter request or use your original words."
        }
    }
}
