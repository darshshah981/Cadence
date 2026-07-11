import Foundation

enum DurableReaderValidity: String, Codable, Equatable, Sendable {
    case absent
    case valid
    case rejected
}

extension ScribeProviderLibraryLoadResult {
    var readerValidity: DurableReaderValidity {
        switch self {
        case .absent: return .absent
        case .valid: return .valid
        case .rejected: return .rejected
        }
    }
}

extension ApplicationConfigurationLoadResult {
    var readerValidity: DurableReaderValidity {
        switch self {
        case .absent: return .absent
        case .valid: return .valid
        case .rejected: return .rejected
        }
    }
}

extension ScribePresetCatalogStateLoadResult {
    var readerValidity: DurableReaderValidity {
        switch self {
        case .absent: return .absent
        case .valid: return .valid
        case .rejected: return .rejected
        }
    }
}

extension SettingsPresentationLoadResult {
    var readerValidity: DurableReaderValidity {
        switch self {
        case .absent: return .absent
        case .valid: return .valid
        case .rejected: return .rejected
        }
    }
}

struct AdaptiveScribeReaderValidity: Equatable, Sendable {
    let providerLibrary: DurableReaderValidity
    let applicationConfigurations: DurableReaderValidity
    let presetCatalogState: DurableReaderValidity
    let settingsPresentation: DurableReaderValidity

    func withProviderLibrary(_ value: DurableReaderValidity) -> AdaptiveScribeReaderValidity {
        replacing(providerLibrary: value)
    }

    func withApplicationConfigurations(_ value: DurableReaderValidity) -> AdaptiveScribeReaderValidity {
        replacing(applicationConfigurations: value)
    }

    func withSettingsPresentation(_ value: DurableReaderValidity) -> AdaptiveScribeReaderValidity {
        replacing(settingsPresentation: value)
    }

    private func replacing(
        providerLibrary: DurableReaderValidity? = nil,
        applicationConfigurations: DurableReaderValidity? = nil,
        settingsPresentation: DurableReaderValidity? = nil
    ) -> AdaptiveScribeReaderValidity {
        AdaptiveScribeReaderValidity(
            providerLibrary: providerLibrary ?? self.providerLibrary,
            applicationConfigurations: applicationConfigurations ?? self.applicationConfigurations,
            presetCatalogState: presetCatalogState,
            settingsPresentation: settingsPresentation ?? self.settingsPresentation
        )
    }
}

struct AdaptiveScribeEligibility: Equatable, Sendable {
    let providerLibraryEnabled: Bool
    let applicationIntelligenceEnabled: Bool
    let settingsControlSystemEnabled: Bool
    let polishedDictationEnabled: Bool
    let adaptiveScribeEnabled: Bool
}

struct AdaptiveScribeFeatureGates: Codable, Equatable, Sendable {
    let providerLibraryV2: Bool
    let applicationIntelligenceV2: Bool
    let settingsControlSystemV2: Bool
    let polishedDictationV2: Bool
    let adaptiveScribeV2: Bool

    static let allEnabled = AdaptiveScribeFeatureGates(
        providerLibraryV2: true,
        applicationIntelligenceV2: true,
        settingsControlSystemV2: true,
        polishedDictationV2: true,
        adaptiveScribeV2: true
    )

    func withPolishedDictation(_ enabled: Bool) -> AdaptiveScribeFeatureGates {
        AdaptiveScribeFeatureGates(
            providerLibraryV2: providerLibraryV2,
            applicationIntelligenceV2: applicationIntelligenceV2,
            settingsControlSystemV2: settingsControlSystemV2,
            polishedDictationV2: enabled,
            adaptiveScribeV2: adaptiveScribeV2
        )
    }

    func eligibility(readers: AdaptiveScribeReaderValidity) -> AdaptiveScribeEligibility {
        let provider = providerLibraryV2 && readers.providerLibrary == .valid
        let applications = applicationIntelligenceV2
            && readers.applicationConfigurations == .valid
            && readers.presetCatalogState == .valid
        let settings = settingsControlSystemV2 && readers.settingsPresentation == .valid
        let polished = polishedDictationV2 && provider
        return AdaptiveScribeEligibility(
            providerLibraryEnabled: provider,
            applicationIntelligenceEnabled: applications,
            settingsControlSystemEnabled: settings,
            polishedDictationEnabled: polished,
            adaptiveScribeEnabled: adaptiveScribeV2 && provider && applications && polished
        )
    }
}

struct AdaptiveScribeFeatureGateEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let gates: AdaptiveScribeFeatureGates

    init(
        schemaVersion: Int = AdaptiveScribeFeatureGateEnvelope.currentSchemaVersion,
        gates: AdaptiveScribeFeatureGates
    ) {
        self.schemaVersion = schemaVersion
        self.gates = gates
    }
}

enum AdaptiveScribeFeatureGateRejection: Equatable, Sendable {
    case malformed
    case futureSchema
}

enum AdaptiveScribeFeatureGateLoadResult: Equatable, Sendable {
    case absent
    case valid(AdaptiveScribeFeatureGates)
    case rejected(AdaptiveScribeFeatureGateRejection)
}

final class AdaptiveScribeFeatureGateStore {
    static let defaultKey = CadenceDurablePreferenceKeys.featureGates

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = AdaptiveScribeFeatureGateStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AdaptiveScribeFeatureGateLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? JSONDecoder().decode(AdaptiveScribeFeatureGateEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= AdaptiveScribeFeatureGateEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == AdaptiveScribeFeatureGateEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        return .valid(envelope.gates)
    }

    func save(_ gates: AdaptiveScribeFeatureGates) throws {
        let previous = defaults.data(forKey: key)
        defaults.set(try JSONEncoder().encode(AdaptiveScribeFeatureGateEnvelope(gates: gates)), forKey: key)
        guard load() == .valid(gates) else {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw StrictPersistenceError.semanticReadbackFailed
        }
    }
}
