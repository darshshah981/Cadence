import Foundation

struct ScribeGuidancePresetDefinition: Equatable, Sendable {
    let id: ScribePresetID
    let familyID: ScribeEnvironmentFamilyID
    let definitionVersion: Int
    let compiledInstructions: String
}

struct ScribeGuidanceFamilyDefinition: Equatable, Sendable {
    let id: ScribeEnvironmentFamilyID
    let definitionVersion: Int
    let defaultPresetID: ScribePresetID
    let presets: [ScribeGuidancePresetDefinition]
}

struct CertifiedApplicationGuidanceCatalog: Equatable, Sendable {
    let claudeDesktopBundleIdentifier: String
    let certifiedClaudeCodeSignatures: [TargetRecognitionSignature]

    static let releaseOne = CertifiedApplicationGuidanceCatalog(
        claudeDesktopBundleIdentifier: "com.anthropic.Claude",
        certifiedClaudeCodeSignatures: []
    )
}

struct ScribeGuidanceCatalog: Equatable, Sendable {
    static let revision = 1
    let families: [ScribeGuidanceFamilyDefinition]

    func family(_ id: ScribeEnvironmentFamilyID) -> ScribeGuidanceFamilyDefinition? {
        families.first { $0.id == id }
    }

    func preset(_ id: ScribePresetID, in familyID: ScribeEnvironmentFamilyID) -> ScribeGuidancePresetDefinition? {
        family(familyID)?.presets.first { $0.id == id }
    }

    static let releaseOne = ScribeGuidanceCatalog(families: [
        family(.general, defaultID: "general.neutral", presets: [
            ("general.neutral", instructions([
                "Clear, natural prose.",
                "Correct grammar, punctuation, and structure.",
                "Keep length proportional to the dictated content.",
                "Do not add unsupported warmth, urgency, formality, or technical structure.",
                "Preserve all claims, requested actions, factual detail, ambiguity, and exact literals."
            ]))
        ]),
        family(.messaging, defaultID: "messaging.neutral", presets: [
            ("messaging.neutral", instructions([
                "Clear, conversational wording with natural contractions.",
                "Lead with the dictated point, request, or update.",
                "Keep warmth moderate and directness natural.",
                "Prefer short paragraphs; use a list only when the dictation contains distinct items.",
                "Do not add greetings, sign-offs, emoji, urgency, enthusiasm, promises, or slang the user did not dictate."
            ])),
            ("messaging.formal", instructions([
                "Polished, measured wording and complete sentences.",
                "Restrained warmth and neutral punctuation.",
                "Make dictated requests, owners, and deadlines explicit without inventing them.",
                "Avoid legalistic, ceremonial, or excessively verbose phrasing."
            ])),
            ("messaging.casual", instructions([
                "Relaxed, direct wording and shorter sentences or fragments where clear.",
                "Natural contractions are preferred.",
                "Do not force lowercase styling, slang, emoji, exclamation marks, or exaggerated enthusiasm."
            ]))
        ]),
        family(.coding, defaultID: "coding.precise", presets: [
            ("coding.precise", instructions([
                "State the dictated task first.",
                "Preserve the action boundary: inspect, explain, diagnose, review, plan, implement, test, commit, and publish remain distinct.",
                "Preserve all supplied files, identifiers, flags, commands, errors, constraints, non-goals, and expected outcomes.",
                "Format technical literals conservatively.",
                "Ask the downstream coding agent to inspect available repository context only when the user’s dictation already delegates that judgment; do not invent repository facts or implementation choices."
            ])),
            ("coding.concise", instructions([
                "Produce a compact, task-first instruction.",
                "Remove repetition and speech filler.",
                "Preserve every dictated constraint, literal, authorization boundary, and expected outcome even when shortening.",
                "Do not collapse multi-part work into a broader or less precise request."
            ])),
            ("coding.structured", instructions([
                "Organize a genuinely multi-part dictated request for scanning.",
                "Use short sections or bullets such as Goal, Context, Constraints, and Verification only when corresponding material was dictated.",
                "Omit empty headings.",
                "Never synthesize missing acceptance criteria, commands, files, tests, or non-goals."
            ]))
        ])
    ])

    private static func instructions(_ lines: [String]) -> String {
        lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func family(
        _ id: ScribeEnvironmentFamilyID,
        defaultID: String,
        presets: [(String, String)]
    ) -> ScribeGuidanceFamilyDefinition {
        ScribeGuidanceFamilyDefinition(
            id: id,
            definitionVersion: 1,
            defaultPresetID: try! ScribePresetID(defaultID),
            presets: presets.map {
                ScribeGuidancePresetDefinition(
                    id: try! ScribePresetID($0.0),
                    familyID: id,
                    definitionVersion: 1,
                    compiledInstructions: $0.1
                )
            }
        )
    }
}

enum ApplicationPromptProjection {
    static func preset(
        for configuration: ApplicationConfiguration,
        catalog: ScribeGuidanceCatalog = .releaseOne
    ) -> ScribeGuidancePresetDefinition {
        guard let family = catalog.family(configuration.familyID) else {
            preconditionFailure("Scribe guidance catalog is missing a configured family")
        }
        let presetID: ScribePresetID
        switch configuration.presetSelection {
        case .familyDefault:
            presetID = family.defaultPresetID
        case let .explicit(explicit):
            presetID = explicit
        }
        return catalog.preset(presetID, in: configuration.familyID)
            ?? catalog.preset(family.defaultPresetID, in: configuration.familyID)!
    }

    static func presetInstructions(
        for configuration: ApplicationConfiguration,
        catalog: ScribeGuidanceCatalog = .releaseOne
    ) -> String {
        preset(for: configuration, catalog: catalog).compiledInstructions
    }

    static func effectiveInstructions(
        for configuration: ApplicationConfiguration,
        catalog: ScribeGuidanceCatalog = .releaseOne
    ) -> String {
        configuration.promptOverride?.rawValue
            ?? presetInstructions(for: configuration, catalog: catalog)
    }
}

enum ScribeGuidanceResolver {
    private static let builtIns: [String: ScribeEnvironmentFamilyID] = [
        "com.tinyspeck.slackmacgap": .messaging,
        "com.openai.codex": .coding,
        "com.todesktop.230313mzl4w4u92": .coding
    ]

    static func resolve(
        application: ResolvedApplicationSelection,
        adaptationEnabled: Bool,
        configurationLoadResult: ApplicationConfigurationLoadResult,
        presetState: ScribePresetCatalogStateLoadResult,
        targetSignature: TargetRecognitionSignature? = nil,
        catalog: ScribeGuidanceCatalog = .releaseOne,
        certifiedCatalog: CertifiedApplicationGuidanceCatalog = .releaseOne
    ) -> ResolvedScribeGuidance {
        guard adaptationEnabled else {
            return fallback(catalog: catalog, source: .adaptationDisabledFallback)
        }
        guard validPresetState(presetState) else {
            return fallback(catalog: catalog, source: .invalidConfigurationFallback)
        }
        guard case let .exact(descriptor) = application else {
            switch application {
            case .ambiguous:
                return fallback(catalog: catalog, source: .ambiguousApplicationFallback)
            case .missing:
                return fallback(catalog: catalog, source: .missingApplicationFallback)
            case .invalid:
                return fallback(catalog: catalog, source: .invalidConfigurationFallback)
            case .exact:
                preconditionFailure()
            }
        }

        switch configurationLoadResult {
        case .rejected:
            return fallback(catalog: catalog, source: .invalidConfigurationFallback)
        case let .valid(library):
            guard libraryIsStructurallyValid(library) else {
                return fallback(catalog: catalog, source: .invalidConfigurationFallback)
            }
            if let configuration = ApplicationIdentityResolver.runtimeExactConfiguration(
                bundleIdentifier: descriptor.bundleIdentifier,
                bundleURL: descriptor.bundleURL,
                library: library
            ) {
                guard configuration.isEnabled else {
                    return fallback(catalog: catalog, source: .disabledApplicationFallback)
                }
                guard let preset = selectedPreset(configuration, catalog: catalog) else {
                    return fallback(catalog: catalog, source: .invalidConfigurationFallback)
                }
                return resolved(
                    preset: preset,
                    custom: configuration.customGuidance,
                    promptOverride: configuration.promptOverride,
                    source: .configuredApplication
                )
            }
        case .absent:
            break
        }

        if let familyID = builtIns[descriptor.bundleIdentifier],
           let family = catalog.family(familyID),
           let preset = catalog.preset(family.defaultPresetID, in: familyID) {
            return resolved(preset: preset, custom: nil, source: .bundledDefault)
        }
        if descriptor.bundleIdentifier == certifiedCatalog.claudeDesktopBundleIdentifier,
           let targetSignature,
           certifiedCatalog.certifiedClaudeCodeSignatures.contains(targetSignature),
           let family = catalog.family(.coding),
           let preset = catalog.preset(family.defaultPresetID, in: .coding) {
            return resolved(preset: preset, custom: nil, source: .bundledDefault)
        }
        return fallback(catalog: catalog, source: .bundledDefault)
    }

    private static func selectedPreset(
        _ configuration: ApplicationConfiguration,
        catalog: ScribeGuidanceCatalog
    ) -> ScribeGuidancePresetDefinition? {
        guard let family = catalog.family(configuration.familyID) else { return nil }
        let id: ScribePresetID
        switch configuration.presetSelection {
        case .familyDefault: id = family.defaultPresetID
        case let .explicit(explicit): id = explicit
        }
        return catalog.preset(id, in: configuration.familyID)
    }

    private static func validPresetState(_ state: ScribePresetCatalogStateLoadResult) -> Bool {
        switch state {
        case .absent: return true
        case let .valid(value): return value == .generalNeutral
        case .rejected: return false
        }
    }

    private static func libraryIsStructurallyValid(_ library: ApplicationConfigurationLibrary) -> Bool {
        guard library.revision >= 0,
              Set(library.configurations.map(\.id)).count == library.configurations.count,
              Set(library.configurations.map(\.application.id)).count == library.configurations.count,
              Set(library.configurations.map {
                  "\($0.application.bundleIdentifier)|\($0.application.lastKnownBundleURL.standardizedFileURL.path)"
              }).count == library.configurations.count else {
            return false
        }
        return true
    }

    private static func fallback(
        catalog: ScribeGuidanceCatalog,
        source: ScribeGuidanceResolutionSource
    ) -> ResolvedScribeGuidance {
        let family = catalog.family(.general)!
        return resolved(
            preset: catalog.preset(family.defaultPresetID, in: .general)!,
            custom: nil,
            source: source
        )
    }

    private static func resolved(
        preset: ScribeGuidancePresetDefinition,
        custom: ScribeCustomGuidance?,
        promptOverride: ScribeCustomGuidance? = nil,
        source: ScribeGuidanceResolutionSource
    ) -> ResolvedScribeGuidance {
        ResolvedScribeGuidance(
            familyID: preset.familyID,
            familyDefinitionVersion: 1,
            presetID: preset.id,
            presetDefinitionVersion: preset.definitionVersion,
            compiledPresetInstructions: promptOverride?.rawValue
                ?? preset.compiledInstructions,
            customGuidance: custom,
            resolutionSource: source,
            preservesExactLiterals: true,
            literalCapabilities: preset.familyID == .coding
                ? [.automaticTechnicalLiteralNormalization]
                : []
        )
    }
}
