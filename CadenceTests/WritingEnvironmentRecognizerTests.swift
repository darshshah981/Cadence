import Foundation
import Testing
@testable import Cadence

struct WritingEnvironmentRecognizerTests {
    private let codePrompt = TargetRecognitionSignature(
        role: "AXTextArea",
        subrole: "AXStandardTextArea",
        identifierAncestry: ["claude-code-prompt", "claude-code-session"]
    )

    @Test
    func slackUsesExactBundledIdentity() {
        let recognizer = WritingEnvironmentRecognizer(catalog: .init(
            slackBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            claudeDesktopBundleIdentifier: "com.anthropic.Claude",
            certifiedClaudeCodeSignatures: []
        ))

        #expect(recognizer.recognize(
            target: .init(processIdentifier: 1, bundleIdentifier: "com.tinyspeck.slackmacgap"),
            signature: nil
        ) == .slack)
        #expect(recognizer.recognize(
            target: .init(processIdentifier: 1, bundleIdentifier: "com.tinyspeck.slackmacgap.helper"),
            signature: nil
        ) == .global)
    }

    @Test
    func claudeCodeRequiresOneExactCertifiedNonContentSignature() {
        let recognizer = WritingEnvironmentRecognizer(catalog: .init(
            slackBundleIdentifiers: [],
            claudeDesktopBundleIdentifier: "com.anthropic.Claude",
            certifiedClaudeCodeSignatures: [codePrompt]
        ))
        let target = ScribeTargetIdentity(
            processIdentifier: 2,
            bundleIdentifier: "com.anthropic.Claude"
        )

        #expect(recognizer.recognize(target: target, signature: codePrompt) == .claudeCode)
        #expect(recognizer.recognize(target: target, signature: nil) == .global)
        #expect(recognizer.recognize(
            target: target,
            signature: .init(
                role: codePrompt.role,
                subrole: codePrompt.subrole,
                identifierAncestry: ["claude-chat-prompt", "claude-chat"]
            )
        ) == .global)
    }

    @Test
    func duplicateRulesAndGenericHostsFailClosed() {
        let duplicateCatalog = WritingEnvironmentRecognitionCatalog(
            slackBundleIdentifiers: [],
            claudeDesktopBundleIdentifier: "com.anthropic.Claude",
            certifiedClaudeCodeSignatures: [codePrompt, codePrompt]
        )
        #expect(WritingEnvironmentRecognizer(catalog: duplicateCatalog).recognize(
            target: .init(processIdentifier: 2, bundleIdentifier: "com.anthropic.Claude"),
            signature: codePrompt
        ) == .global)

        for bundleID in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.microsoft.VSCode",
            "com.jetbrains.intellij",
            "com.apple.Safari",
            "com.google.Chrome"
        ] {
            #expect(WritingEnvironmentRecognizer(catalog: .releaseOne).recognize(
                target: .init(processIdentifier: 3, bundleIdentifier: bundleID),
                signature: codePrompt
            ) == .global)
        }
    }
}
