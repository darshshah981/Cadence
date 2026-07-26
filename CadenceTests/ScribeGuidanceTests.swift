import Foundation
import Testing
@testable import Cadence

struct ScribeGuidanceTests {
    @Test(arguments: [
        ("com.tinyspeck.slackmacgap", ScribeEnvironmentFamilyID.messaging, "messaging.neutral"),
        ("com.openai.codex", .coding, "coding.precise"),
        ("com.todesktop.230313mzl4w4u92", .coding, "coding.precise"),
        ("unknown.app", .general, "general.neutral")
    ])
    func builtInTemplatesResolveExactDefaults(
        bundleID: String,
        family: ScribeEnvironmentFamilyID,
        preset: String
    ) throws {
        let resolved = ScribeGuidanceResolver.resolve(
            application: .exact(Self.descriptor(bundleID: bundleID)),
            adaptationEnabled: true,
            configurationLoadResult: .absent,
            presetState: .valid(.generalNeutral)
        )
        let expectedPreset = try ScribePresetID(preset)
        #expect(resolved.familyID == family)
        #expect(resolved.presetID == expectedPreset)
    }

    @Test
    func configuredOverrideDisabledMissingAmbiguousAndAdaptationOffFollowPrecedence() throws {
        let descriptor = Self.descriptor(bundleID: "com.tinyspeck.slackmacgap")
        let enabled = try Self.configuration(for: descriptor, enabled: true)
        let disabled = try Self.configuration(for: descriptor, enabled: false)
        let enabledLibrary = ApplicationConfigurationLibrary(revision: 1, configurations: [enabled])
        let disabledLibrary = ApplicationConfigurationLibrary(revision: 1, configurations: [disabled])
        let custom = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .valid(enabledLibrary), presetState: .valid(.generalNeutral)
        )
        let formal = try ScribePresetID("messaging.formal")
        #expect(custom.presetID == formal)
        #expect(custom.customGuidance?.rawValue == "Use British spelling.")
        let disabledResolution = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .valid(disabledLibrary), presetState: .valid(.generalNeutral)
        )
        #expect(disabledResolution.resolutionSource == .disabledApplicationFallback)

        for resolved in [
            disabledResolution,
            ScribeGuidanceResolver.resolve(application: .missing, adaptationEnabled: true, configurationLoadResult: .valid(enabledLibrary), presetState: .valid(.generalNeutral)),
            ScribeGuidanceResolver.resolve(application: .ambiguous, adaptationEnabled: true, configurationLoadResult: .valid(enabledLibrary), presetState: .valid(.generalNeutral)),
            ScribeGuidanceResolver.resolve(application: .exact(descriptor), adaptationEnabled: false, configurationLoadResult: .valid(enabledLibrary), presetState: .valid(.generalNeutral))
        ] {
            #expect(resolved.familyID == .general)
            #expect(resolved.customGuidance == nil)
        }
    }

    @Test
    func configuredAppPromptReplacesPresetAndReachesProviderRequest() throws {
        let descriptor = Self.descriptor(bundleID: "com.tinyspeck.slackmacgap")
        let promptOverride = try ScribeCustomGuidance(
            "Write a terse project update. Preserve every dictated fact."
        )
        let configuration = try ApplicationConfiguration(
            application: ApplicationReference(
                bundleIdentifier: descriptor.bundleIdentifier,
                lastKnownBundleURL: descriptor.bundleURL,
                lastKnownDisplayName: descriptor.displayName
            ),
            isEnabled: true,
            familyID: .messaging,
            presetSelection: .familyDefault,
            customGuidance: nil,
            promptOverride: promptOverride,
            revision: 1
        )
        let resolved = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor),
            adaptationEnabled: true,
            configurationLoadResult: .valid(
                .init(revision: 1, configurations: [configuration])
            ),
            presetState: .valid(.generalNeutral)
        )

        #expect(resolved.compiledPresetInstructions == promptOverride.rawValue)
        let request = ScribeRequest(
            intent: .compose,
            spokenTranscript: "We shipped the calendar fix today.",
            resolvedGuidance: resolved
        )
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: request,
            destination: .deepSeek
        )
        #expect(input.userMessage.contains(promptOverride.rawValue))
        #expect(!input.userMessage.contains("Natural contractions are preferred."))
        #expect(!input.userMessage.contains(descriptor.bundleIdentifier))
        #expect(!input.userMessage.contains(descriptor.displayName))
    }

    @Test
    func codingHasSeparateAutomaticLiteralCapabilityAndProviderSafeValueLeaksNoIdentity() throws {
        let descriptor = Self.descriptor(bundleID: "com.openai.codex")
        let resolved = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .absent, presetState: .valid(.generalNeutral)
        )
        #expect(resolved.preservesExactLiterals)
        #expect(resolved.literalCapabilities.contains(.automaticTechnicalLiteralNormalization))
        let encoded = try JSONEncoder().encode(resolved.providerSafeValue)
        let text = try #require(String(data: encoded, encoding: .utf8))
        for forbidden in ["Codex", "com.openai.codex", "/Applications", "coding.precise", "icon", "signature"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test
    func certifiedClaudeSignatureIsExactNarrowAndNeverInferredFromName() {
        let signature = TargetRecognitionSignature(
            role: "AXTextArea", subrole: nil, identifierAncestry: ["certified-code-prompt"]
        )
        let certified = CertifiedApplicationGuidanceCatalog(
            claudeDesktopBundleIdentifier: "com.anthropic.Claude",
            certifiedClaudeCodeSignatures: [signature]
        )
        let claude = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Claude.app"),
            bundleIdentifier: "com.anthropic.Claude", displayName: "Claude",
            version: nil, build: nil, isInstalled: true, isRunning: true
        )
        let matched = ScribeGuidanceResolver.resolve(
            application: .exact(claude), adaptationEnabled: true,
            configurationLoadResult: .absent, presetState: .valid(.generalNeutral),
            targetSignature: signature, certifiedCatalog: certified
        )
        #expect(matched.familyID == .coding)
        let unmatched = ScribeGuidanceResolver.resolve(
            application: .exact(claude), adaptationEnabled: true,
            configurationLoadResult: .absent, presetState: .valid(.generalNeutral),
            targetSignature: nil, certifiedCatalog: certified
        )
        #expect(unmatched.familyID == .general)
        let misleadingName = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "unknown.other", displayName: "Claude Code Codex",
            version: nil, build: nil, isInstalled: true, isRunning: false
        )
        #expect(ScribeGuidanceResolver.resolve(
            application: .exact(misleadingName), adaptationEnabled: true,
            configurationLoadResult: .absent, presetState: .valid(.generalNeutral),
            targetSignature: signature, certifiedCatalog: certified
        ).familyID == .general)
    }

    @Test
    func rejectedPresetStateAndIncompatibleExplicitPresetFailClosed() throws {
        let descriptor = Self.descriptor(bundleID: "com.openai.codex")
        let incompatible = try ApplicationConfiguration(
            application: ApplicationReference(
                bundleIdentifier: descriptor.bundleIdentifier,
                lastKnownBundleURL: descriptor.bundleURL,
                lastKnownDisplayName: descriptor.displayName
            ),
            isEnabled: true,
            familyID: .coding,
            presetSelection: .explicit(try ScribePresetID("messaging.formal")),
            customGuidance: nil,
            revision: 1
        )
        let invalidConfiguration = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .valid(.init(revision: 1, configurations: [incompatible])),
            presetState: .valid(.generalNeutral)
        )
        #expect(invalidConfiguration.familyID == .general)
        let rejectedCatalog = ScribeGuidanceResolver.resolve(
            application: .exact(descriptor), adaptationEnabled: true,
            configurationLoadResult: .absent,
            presetState: .rejected(.futureSchema)
        )
        #expect(rejectedCatalog.familyID == .general)
    }

    private static func descriptor(bundleID: String) -> InstalledApplicationDescriptor {
        .init(bundleURL: URL(fileURLWithPath: "/Applications/Secret Name.app"), bundleIdentifier: bundleID, displayName: "Secret Name", version: nil, build: nil, isInstalled: true, isRunning: false)
    }
    private static func configuration(for descriptor: InstalledApplicationDescriptor, enabled: Bool) throws -> ApplicationConfiguration {
        try ApplicationConfiguration(
            application: ApplicationReference(bundleIdentifier: descriptor.bundleIdentifier, lastKnownBundleURL: descriptor.bundleURL, lastKnownDisplayName: descriptor.displayName),
            isEnabled: enabled, familyID: .messaging,
            presetSelection: .explicit(try ScribePresetID("messaging.formal")),
            customGuidance: try ScribeCustomGuidance("Use British spelling."), revision: 1
        )
    }
}
