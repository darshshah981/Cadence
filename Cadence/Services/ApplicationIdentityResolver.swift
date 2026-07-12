import Foundation

enum ApplicationIdentityResolver {
    static func resolve(
        reference: ApplicationReference,
        applications: [InstalledApplicationDescriptor],
        savedURLExists: Bool
    ) -> ApplicationIdentityResolution {
        let normalized = reference.normalized()
        guard normalized.schemaVersion == ApplicationReference.currentSchemaVersion,
              !normalized.bundleIdentifier.isEmpty,
              normalized.bundleIdentifier.utf8.count <= 255,
              !normalized.bundleIdentifier.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              normalized.lastKnownBundleURL.isFileURL,
              normalized.lastKnownBundleURL.pathExtension.lowercased() == "app" else { return .invalid }
        if let exact = applications.first(where: {
            $0.bundleIdentifier == normalized.bundleIdentifier
                && $0.bundleURL.standardizedFileURL == normalized.lastKnownBundleURL.standardizedFileURL
        }) {
            return .exact(exact)
        }
        guard !savedURLExists else { return .missing }
        let lineage = applications.filter { $0.bundleIdentifier == normalized.bundleIdentifier }
        if lineage.count == 1, let only = lineage.first { return .uniqueRebind(only) }
        return lineage.isEmpty ? .missing : .ambiguous
    }

    static func runtimeExactConfiguration(
        identity: ActiveApplicationIdentity,
        library: ApplicationConfigurationLibrary
    ) -> ApplicationConfiguration? {
        let matches = library.configurations.filter {
            $0.application.bundleIdentifier == identity.bundleIdentifier
                && $0.application.lastKnownBundleURL.standardizedFileURL
                    == identity.bundleURL.standardizedFileURL
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
