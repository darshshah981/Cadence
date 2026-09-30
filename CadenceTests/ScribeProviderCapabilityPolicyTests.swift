import Foundation
import Testing
@testable import Cadence

struct ScribeProviderCapabilityPolicyTests {
    @Test
    func defaultProfilesPermitLocalRefinementWithoutQualityOrCloudClaims() throws {
        let local = ScribeProviderCapabilityProfile.defaultProfile(for: .legacyLocal)
        let cloud = ScribeProviderCapabilityProfile.defaultProfile(for: .openAIDirect)

        #expect(local.revision == ScribeProviderCapabilityProfile.currentRevision)
        #expect(local.supportedInputModalities == [.text])
        #expect(local.supportedTaskRequirements == [.directDraft, .draftRefinement, .selectedTextRewrite])
        #expect(cloud.supportedTaskRequirements == [.directDraft])
        #expect(local.providerContextCapacity == .unknown)
        #expect(local.qualityStatus == .notEvaluated)
        #expect(local.maximumCompiledRequestUTF8Bytes == 12 * 1_024)
        #expect(cloud.maximumCompiledRequestUTF8Bytes == 64 * 1_024)
        let input = ProviderSafeScribeInput(systemMessage: "Revise", userMessage: "Synthetic draft")
        try ScribeProviderCapabilityPolicy.validate(input: input, profile: local, requirements: .draftRefinement)
        #expect(throws: ScribeProviderCapabilityRejection.unsupportedTask(.draftRefinement)) {
            try ScribeProviderCapabilityPolicy.validate(input: input, profile: cloud, requirements: .draftRefinement)
        }
        try ScribeProviderCapabilityPolicy.validate(input: input, profile: local, requirements: .selectedTextRewrite)
        #expect(throws: ScribeProviderCapabilityRejection.unsupportedTask(.selectedTextRewrite)) {
            try ScribeProviderCapabilityPolicy.validate(input: input, profile: cloud, requirements: .selectedTextRewrite)
        }
    }

    @Test
    func exactLocalBudgetBoundaryAcceptsCombinedCompiledText() throws {
        let profile = ScribeProviderCapabilityProfile.defaultProfile(for: .legacyLocal)
        let input = ProviderSafeScribeInput(
            systemMessage: String(repeating: "a", count: 4 * 1_024),
            userMessage: String(repeating: "b", count: 8 * 1_024)
        )

        try ScribeProviderCapabilityPolicy.validate(
            input: input, profile: profile, requirements: .directTextDraft
        )
    }

    @Test
    func combinedCompiledTextOverBudgetIsRejected() {
        let profile = ScribeProviderCapabilityProfile.defaultProfile(for: .legacyLocal)
        let input = ProviderSafeScribeInput(
            systemMessage: String(repeating: "a", count: 12 * 1_024), userMessage: "b"
        )

        #expect(throws: ScribeProviderCapabilityRejection.inputTooLarge(
            actualUTF8Bytes: 12 * 1_024 + 1,
            maximumUTF8Bytes: 12 * 1_024
        )) {
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: profile, requirements: .directTextDraft
            )
        }
    }

    @Test
    func unicodeUsesUtf8BytesRatherThanCharacterCount() {
        let profile = ScribeProviderCapabilityProfile(
            maximumCompiledRequestUTF8Bytes: 3
        )
        let input = ProviderSafeScribeInput(systemMessage: "é", userMessage: "é")

        #expect(throws: ScribeProviderCapabilityRejection.inputTooLarge(
            actualUTF8Bytes: 4, maximumUTF8Bytes: 3
        )) {
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: profile, requirements: .directTextDraft
            )
        }
    }

    @Test
    func unavailableModalityAndTaskRejectionsAreTyped() {
        let input = ProviderSafeScribeInput(systemMessage: "system", userMessage: "draft")
        let unavailable = ScribeProviderCapabilityProfile(
            availability: .unavailable, maximumCompiledRequestUTF8Bytes: 10
        )
        #expect(throws: ScribeProviderCapabilityRejection.unavailable) {
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: unavailable, requirements: .directTextDraft
            )
        }

        let textOnly = ScribeProviderCapabilityProfile(maximumCompiledRequestUTF8Bytes: 10)
        #expect(throws: ScribeProviderCapabilityRejection.unsupportedModality(.image)) {
            try ScribeProviderCapabilityPolicy.validate(
                input: input,
                profile: textOnly,
                requirements: .init(inputModalities: [.image], taskRequirements: [.directDraft])
            )
        }

        let noTasks = ScribeProviderCapabilityProfile(
            supportedTaskRequirements: [], maximumCompiledRequestUTF8Bytes: 10
        )
        #expect(throws: ScribeProviderCapabilityRejection.unsupportedTask(.directDraft)) {
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: noTasks, requirements: .directTextDraft
            )
        }
    }

    @Test
    func actionSnapshotUsesDestinationDefaultUnlessProfileIsExplicit() {
        let defaultAction = ScribeProviderActionSnapshot(
            provider: MockScribeProvider(), destination: .legacyLocal
        )
        #expect(defaultAction.capabilityProfile.maximumCompiledRequestUTF8Bytes == 12 * 1_024)

        let explicit = ScribeProviderCapabilityProfile(
            availability: .unavailable, maximumCompiledRequestUTF8Bytes: 7
        )
        let explicitAction = ScribeProviderActionSnapshot(
            provider: MockScribeProvider(), destination: .openAIDirect, capabilityProfile: explicit
        )
        #expect(explicitAction.capabilityProfile == explicit)
    }
}
