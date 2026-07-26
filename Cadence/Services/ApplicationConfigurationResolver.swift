import Foundation

enum ApplicationConfigurationWriterError: Error, Equatable, Sendable {
    case rejectedStore
    case missingConfiguration
    case staleSnapshot
    case concurrentMutation
    case savedURLStillPresent
    case ambiguousIdentity
    case semanticReadbackFailed
    case invalidInstalledApplication
}

actor ApplicationConfigurationWriter {
    private let store: any ApplicationConfigurationPersisting

    init(store: any ApplicationConfigurationPersisting) {
        self.store = store
    }

    /// Creates or updates a configuration from a catalog descriptor. Callers
    /// deliberately cannot provide a bundle identifier: the descriptor is the
    /// installed-app identity boundary, and its canonical URL keeps duplicate
    /// installations distinct.
    func upsert(
        application: InstalledApplicationDescriptor,
        familyID: ScribeEnvironmentFamilyID,
        presetSelection: ScribePresetSelection = .familyDefault,
        customGuidance: ScribeCustomGuidance? = nil,
        promptOverride: ScribeCustomGuidance? = nil,
        isEnabled: Bool = true
    ) throws -> ApplicationConfiguration {
        guard application.isInstalled,
              application.bundleURL.isFileURL,
              application.bundleURL.pathExtension.lowercased() == "app",
              !application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !application.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplicationConfigurationWriterError.invalidInstalledApplication
        }
        if case let .explicit(presetID) = presetSelection,
           !presetID.rawValue.hasPrefix("\(familyID.rawValue).") {
            throw ApplicationConfigurationWriterError.invalidInstalledApplication
        }

        let library: ApplicationConfigurationLibrary
        switch store.load() {
        case .absent:
            library = .init(revision: 0, configurations: [])
        case let .valid(value):
            library = value
        case .rejected:
            throw ApplicationConfigurationWriterError.rejectedStore
        }

        let url = application.bundleURL.standardizedFileURL
        let existingIndex = library.configurations.firstIndex {
            $0.application.lastKnownBundleURL.standardizedFileURL == url
        }
        let existing = existingIndex.map { library.configurations[$0] }
        let reference = ApplicationReference(
            id: existing?.application.id ?? UUID(),
            bundleIdentifier: application.bundleIdentifier,
            lastKnownBundleURL: url,
            lastKnownDisplayName: application.displayName
        )
        let configuration = try ApplicationConfiguration(
            id: existing?.id ?? UUID(),
            application: reference,
            isEnabled: isEnabled,
            familyID: familyID,
            presetSelection: presetSelection,
            customGuidance: customGuidance,
            promptOverride: promptOverride,
            revision: (existing?.revision ?? 0) + 1
        )
        var configurations = library.configurations
        if let existingIndex {
            configurations[existingIndex] = configuration
        } else {
            configurations.append(configuration)
        }
        try persist(.init(revision: library.revision + 1, configurations: configurations))
        return configuration
    }

    func updateCustomGuidance(
        configurationID: UUID,
        input: String
    ) throws -> ApplicationConfiguration {
        let guidance = try CustomGuidanceValidator.validate(input)
        guard case let .valid(library) = store.load(),
              let index = library.configurations.firstIndex(where: { $0.id == configurationID }) else {
            throw ApplicationConfigurationWriterError.missingConfiguration
        }
        let original = library.configurations[index]
        let updated = try ApplicationConfiguration(
            id: original.id,
            application: original.application,
            isEnabled: original.isEnabled,
            familyID: original.familyID,
            presetSelection: original.presetSelection,
            customGuidance: guidance,
            promptOverride: original.promptOverride,
            revision: original.revision + 1
        )
        var configurations = library.configurations
        configurations[index] = updated
        try persist(
            ApplicationConfigurationLibrary(
                revision: library.revision + 1,
                configurations: configurations
            )
        )
        return updated
    }

    func replaceConfiguration(
        _ updated: ApplicationConfiguration,
        expectedLibraryRevision: Int,
        expectedConfigurationRevision: Int
    ) throws {
        guard case let .valid(library) = store.load(),
              library.revision == expectedLibraryRevision,
              let index = library.configurations.firstIndex(where: { $0.id == updated.id }),
              library.configurations[index].revision == expectedConfigurationRevision,
              updated.revision == expectedConfigurationRevision + 1 else {
            throw ApplicationConfigurationWriterError.concurrentMutation
        }
        var configurations = library.configurations
        configurations[index] = updated
        try persist(.init(revision: library.revision + 1, configurations: configurations))
    }

    func resetConfiguration(_ configurationID: UUID) throws {
        guard case let .valid(library) = store.load() else {
            throw ApplicationConfigurationWriterError.rejectedStore
        }
        let remaining = library.configurations.filter { $0.id != configurationID }
        guard remaining.count != library.configurations.count else {
            throw ApplicationConfigurationWriterError.missingConfiguration
        }
        try persist(.init(revision: library.revision + 1, configurations: remaining))
    }

    func resetAllApplications() throws {
        guard case let .valid(library) = store.load() else {
            throw ApplicationConfigurationWriterError.rejectedStore
        }
        try persist(.init(revision: library.revision + 1, configurations: []))
    }

    func rebind(
        configurationID: UUID,
        expectedLibraryRevision: Int,
        expectedConfigurationRevision: Int,
        expectedReferenceID: UUID,
        expectedOldURL: URL,
        snapshot: InstalledApplicationCatalogSnapshot,
        newestSnapshot: @Sendable () async -> InstalledApplicationCatalogSnapshot,
        savedURLExists: @Sendable () async -> Bool,
        onCommittedRememberedURLs: @Sendable (Set<URL>) async -> Void = { _ in }
    ) async throws -> ApplicationConfiguration {
        guard case let .valid(initialLibrary) = store.load() else {
            throw ApplicationConfigurationWriterError.rejectedStore
        }
        guard initialLibrary.revision == expectedLibraryRevision,
              let initial = initialLibrary.configurations.first(where: { $0.id == configurationID }),
              initial.revision == expectedConfigurationRevision,
              initial.application.id == expectedReferenceID,
              initial.application.lastKnownBundleURL.standardizedFileURL
                == expectedOldURL.standardizedFileURL else {
            throw ApplicationConfigurationWriterError.concurrentMutation
        }
        guard !(await savedURLExists()) else {
            throw ApplicationConfigurationWriterError.savedURLStillPresent
        }
        guard case let .uniqueRebind(candidate) = ApplicationIdentityResolver.resolve(
            reference: initial.application,
            applications: snapshot.applications,
            savedURLExists: false
        ) else { throw ApplicationConfigurationWriterError.ambiguousIdentity }
        let latest = await newestSnapshot()
        guard latest.generation == snapshot.generation else {
            throw ApplicationConfigurationWriterError.staleSnapshot
        }
        guard !(await savedURLExists()),
              case let .uniqueRebind(latestCandidate) = ApplicationIdentityResolver.resolve(
                reference: initial.application,
                applications: latest.applications,
                savedURLExists: false
              ), latestCandidate == candidate else {
            throw ApplicationConfigurationWriterError.staleSnapshot
        }
        guard case let .valid(currentLibrary) = store.load(),
              currentLibrary.revision == expectedLibraryRevision,
              let index = currentLibrary.configurations.firstIndex(where: { $0.id == configurationID }),
              currentLibrary.configurations[index].revision == expectedConfigurationRevision,
              currentLibrary.configurations[index].application.id == expectedReferenceID else {
            throw ApplicationConfigurationWriterError.concurrentMutation
        }
        let current = currentLibrary.configurations[index]
        let reboundReference = ApplicationReference(
            schemaVersion: current.application.schemaVersion,
            id: current.application.id,
            bundleIdentifier: current.application.bundleIdentifier,
            lastKnownBundleURL: candidate.bundleURL,
            lastKnownDisplayName: candidate.displayName
        )
        let rebound = try ApplicationConfiguration(
            id: current.id,
            application: reboundReference,
            isEnabled: current.isEnabled,
            familyID: current.familyID,
            presetSelection: current.presetSelection,
            customGuidance: current.customGuidance,
            promptOverride: current.promptOverride,
            revision: current.revision + 1
        )
        var configurations = currentLibrary.configurations
        configurations[index] = rebound
        let priorBytes = store.rawRepresentation()
        try persist(ApplicationConfigurationLibrary(
            revision: currentLibrary.revision + 1,
            configurations: configurations
        ))
        let committedBytes = store.rawRepresentation()
        let postSaveSnapshot = await newestSnapshot()
        let postSaveURLExists = await savedURLExists()
        let postSaveResolution = ApplicationIdentityResolver.resolve(
                reference: initial.application,
                applications: postSaveSnapshot.applications,
                savedURLExists: false
        )
        let candidateStillMatches: Bool
        if case let .uniqueRebind(postSaveCandidate) = postSaveResolution {
            candidateStillMatches = postSaveCandidate == candidate
        } else {
            candidateStillMatches = false
        }
        let committedLibrary: ApplicationConfigurationLibrary?
        if case let .valid(postSaveLibrary) = store.load() {
            committedLibrary = postSaveLibrary
        } else {
            committedLibrary = nil
        }
        let readbackStillMatches = committedLibrary?.configurations.contains(where: {
            $0 == rebound
        }) == true
        guard postSaveSnapshot.generation == snapshot.generation,
              !postSaveURLExists,
              candidateStillMatches,
              readbackStillMatches else {
            guard store.rawRepresentation() == committedBytes else {
                throw ApplicationConfigurationWriterError.concurrentMutation
            }
            store.restoreRawRepresentation(priorBytes)
            throw ApplicationConfigurationWriterError.staleSnapshot
        }
        await onCommittedRememberedURLs(Set(
            committedLibrary?.configurations.map(\.application.lastKnownBundleURL) ?? []
        ))
        return rebound
    }

    private func persist(_ library: ApplicationConfigurationLibrary) throws {
        try store.save(library)
        guard case let .valid(readback) = store.load(),
              readback.semanticallyEquals(library) else {
            throw ApplicationConfigurationWriterError.semanticReadbackFailed
        }
    }
}
