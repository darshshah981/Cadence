import Foundation

enum WritingEnvironmentResolver {
    static func resolve(
        recognizedEnvironmentID: WritingEnvironmentID?,
        adaptationEnabled: Bool,
        preferenceLoadResult: WritingEnvironmentPreferenceLoadResult,
        catalog: WritingEnvironmentCatalog = .releaseOne
    ) -> ResolvedWritingEnvironment {
        guard case let .valid(preferences) = preferenceLoadResult else {
            if case .rejected = preferenceLoadResult {
                return globalFallback(in: catalog, source: .invalidPreferenceFallback)
            }
            return resolveValid(
                recognizedEnvironmentID: recognizedEnvironmentID,
                adaptationEnabled: adaptationEnabled,
                preferences: [],
                catalog: catalog
            )
        }

        guard preferencesAreValid(preferences, catalog: catalog) else {
            return globalFallback(in: catalog, source: .invalidPreferenceFallback)
        }
        return resolveValid(
            recognizedEnvironmentID: recognizedEnvironmentID,
            adaptationEnabled: adaptationEnabled,
            preferences: preferences,
            catalog: catalog
        )
    }

    private static func resolveValid(
        recognizedEnvironmentID: WritingEnvironmentID?,
        adaptationEnabled: Bool,
        preferences: [WritingEnvironmentPreference],
        catalog: WritingEnvironmentCatalog
    ) -> ResolvedWritingEnvironment {
        guard adaptationEnabled else {
            return globalFallback(in: catalog, source: .adaptationDisabledFallback)
        }
        guard let recognizedEnvironmentID,
              let definition = catalog.environment(id: recognizedEnvironmentID) else {
            return globalFallback(in: catalog, source: .unknownEnvironmentFallback)
        }
        guard recognizedEnvironmentID != .global else {
            return resolved(definition: definition, behaviorID: .neutral, source: .bundledDefault)
        }

        guard let preference = preferences.first(where: { $0.environmentID == recognizedEnvironmentID }) else {
            return resolved(
                definition: definition,
                behaviorID: definition.defaultBehaviorID,
                source: .bundledDefault
            )
        }
        guard preference.isEnabled else {
            return globalFallback(in: catalog, source: .environmentDisabledFallback)
        }
        return resolved(
            definition: definition,
            behaviorID: preference.selectedBehaviorID,
            source: .rememberedPreference
        )
    }

    private static func preferencesAreValid(
        _ preferences: [WritingEnvironmentPreference],
        catalog: WritingEnvironmentCatalog
    ) -> Bool {
        let ids = preferences.map(\.environmentID)
        guard Set(ids).count == ids.count else { return false }

        return preferences.allSatisfy { preference in
            guard let definition = catalog.environment(id: preference.environmentID) else { return false }
            guard preference.definitionVersion == definition.definitionVersion else { return false }
            guard definition.supportedBehaviorIDs.contains(preference.selectedBehaviorID) else { return false }
            return preference.environmentID != .global || preference.isEnabled
        }
    }

    private static func globalFallback(
        in catalog: WritingEnvironmentCatalog,
        source: WritingEnvironmentResolutionSource
    ) -> ResolvedWritingEnvironment {
        guard let definition = catalog.environment(id: .global) else {
            preconditionFailure("Writing environment catalog must contain the global fallback")
        }
        return resolved(definition: definition, behaviorID: .neutral, source: source)
    }

    private static func resolved(
        definition: WritingEnvironmentDefinition,
        behaviorID: WritingBehaviorID,
        source: WritingEnvironmentResolutionSource
    ) -> ResolvedWritingEnvironment {
        guard let instructions = definition.instructions(for: behaviorID) else {
            preconditionFailure("Writing environment catalog contains an unsupported behavior")
        }
        return ResolvedWritingEnvironment(
            environmentID: definition.id,
            environmentDisplayName: definition.displayName,
            behaviorID: behaviorID,
            behaviorDisplayName: behaviorID.displayName,
            definitionVersion: definition.definitionVersion,
            compiledInstructions: instructions,
            resolutionSource: source
        )
    }
}
