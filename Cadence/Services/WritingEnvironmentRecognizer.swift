import Foundation

struct WritingEnvironmentRecognitionCatalog: Equatable, Sendable {
    let slackBundleIdentifiers: Set<String>
    let claudeDesktopBundleIdentifier: String
    let certifiedClaudeCodeSignatures: [TargetRecognitionSignature]

    init(
        slackBundleIdentifiers: Set<String>,
        claudeDesktopBundleIdentifier: String,
        certifiedClaudeCodeSignatures: [TargetRecognitionSignature]
    ) {
        self.slackBundleIdentifiers = slackBundleIdentifiers
        self.claudeDesktopBundleIdentifier = claudeDesktopBundleIdentifier
        self.certifiedClaudeCodeSignatures = certifiedClaudeCodeSignatures
    }

    static let releaseOne = WritingEnvironmentRecognitionCatalog(
        slackBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
        claudeDesktopBundleIdentifier: "com.anthropic.Claude",
        certifiedClaudeCodeSignatures: []
    )
}

struct WritingEnvironmentRecognizer: Sendable {
    private let catalog: WritingEnvironmentRecognitionCatalog

    init(catalog: WritingEnvironmentRecognitionCatalog = .releaseOne) {
        self.catalog = catalog
    }

    func recognize(
        target: ScribeTargetIdentity,
        signature: TargetRecognitionSignature?
    ) -> WritingEnvironmentID {
        guard let bundleIdentifier = target.bundleIdentifier else { return .global }
        var matches: [WritingEnvironmentID] = []

        if catalog.slackBundleIdentifiers.contains(bundleIdentifier) {
            matches.append(.slack)
        }
        if bundleIdentifier == catalog.claudeDesktopBundleIdentifier, let signature {
            matches.append(contentsOf: catalog.certifiedClaudeCodeSignatures.compactMap {
                $0 == signature ? .claudeCode : nil
            })
        }
        return matches.count == 1 ? matches[0] : .global
    }
}
