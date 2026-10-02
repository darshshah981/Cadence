import Foundation
import CryptoKit
import Testing
@testable import Cadence

struct ComposeGlobalWritingDefaultsTests {
    @Test func exportProductionPreferenceEvaluation() throws {
        let fixtures: [(String, String, ComposeGlobalWritingDefaults.Tone, Bool, String)] = [
            ("defaults-formal", "Hey, are you free to review the draft?", .formal, false, "Hello, are you available to review the draft?"),
            ("defaults-warm", "Maya, the preview is ready for review.", .warm, false, "Hi Maya, the preview is ready for your review."),
            ("defaults-concise", "The project status update is ready for everyone to review.", .automatic, true, "The project update is ready for review."),
            ("defaults-voice-override", "Hey, how's it going? Write this formally.", .warm, true, "Hello, how are you?"),
            ("defaults-uncertainty", "I think the draft is ready.", .formal, false, "I believe the draft is ready."),
            ("defaults-recipient", "Ask Lee to send the report on Friday. Do not send it before review.", .polite, true, "Lee, please send the report on Friday, after review.")
        ]
        var cases: [[String: Any]] = [], exports: [[String: Any]] = []
        for (id, spoken, tone, concise, example) in fixtures {
            let defaults = ComposeGlobalWritingDefaults(isEnabled: true, tone: tone, preferConcise: concise)
            let input = try ScribeRequestPolicy.providerSafeInput(for: .init(intent: .compose, spokenTranscript: spoken, writingDefaults: defaults.values), destination: .legacyLocal)
            #expect((input.preparedDraft != nil) == [
                "defaults-formal", "defaults-warm", "defaults-concise", "defaults-uncertainty"
            ].contains(id))
            cases.append(["id": id, "family": "globalPreferences", "spoken": spoken, "tone": tone.rawValue, "preferConcise": concise, "exampleDraft": example, "required": [String](), "forbidden": [String]()])
            var bytes = Data(input.systemMessage.utf8); bytes.append(0); bytes.append(contentsOf: input.userMessage.utf8)
            var export: [String: Any] = ["id": id, "system": input.systemMessage, "user": input.userMessage]
            if let prepared = input.preparedDraft {
                bytes.append(0)
                bytes.append(contentsOf: "preparedDraft".utf8)
                bytes.append(0)
                bytes.append(contentsOf: prepared.utf8)
                export["preparedDraft"] = prepared
            }
            export["requestSHA256"] = digest(bytes)
            exports.append(export)
        }
        guard ProcessInfo.processInfo.environment["CADENCE_EXPORT_GLOBAL_DEFAULTS"] == "1" else { return }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CADENCE_SCRIBE_EVALUATION_DIRECTORY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "syntheticOnly": true, "cases": cases], options: [.prettyPrinted, .sortedKeys])
        try corpus.write(to: directory.appendingPathComponent("corpus.json"), options: .atomic)
        let requests = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "syntheticOnly": true, "corpusSHA256": digest(corpus), "requests": exports], options: [.prettyPrinted, .sortedKeys])
        try requests.write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
    }

    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    @Test func saveCancelRestartResetAndStaleEdit() throws {
        let suite = "ComposeGlobalDefaultsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposeGlobalWritingDefaultsStore(defaults: defaults, key: "choices")
        let original = try store.load()
        #expect(original == .init())
        var draft = original; draft.isEnabled = true; draft.tone = .warm; draft.preferConcise = true
        #expect(try store.load() == original) // Editing/Cancel has no storage effect.
        try store.save(draft, replacing: original)
        let restarted = ComposeGlobalWritingDefaultsStore(defaults: try #require(UserDefaults(suiteName: suite)), key: "choices")
        #expect(try restarted.load() == draft)
        #expect(draft.values == [.tone(.warm), .concise])
        #expect(throws: ComposeGlobalWritingDefaultsError.staleEdit) { try store.save(original, replacing: original) }
        #expect(try store.load() == draft)
        try store.reset(replacing: draft)
        #expect(try restarted.load() == original)
        #expect(defaults.object(forKey: "choices") == nil)
    }

    @Test(arguments: [Data("bad".utf8), Data(#"{"schemaVersion":2,"choices":{"isEnabled":true,"tone":"warm","preferConcise":true}}"#.utf8), Data(#"{"schemaVersion":1,"choices":{"isEnabled":true,"tone":"invented","preferConcise":true}}"#.utf8)])
    func invalidStorageIsPreserved(_ bytes: Data) throws {
        let suite = "ComposeGlobalDefaultsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(bytes, forKey: "choices")
        let store = ComposeGlobalWritingDefaultsStore(defaults: defaults, key: "choices")
        #expect(throws: ComposeGlobalWritingDefaultsError.invalidStoredDefaults) { try store.load() }
        #expect(throws: ComposeGlobalWritingDefaultsError.invalidStoredDefaults) { try store.save(.init(), replacing: .init()) }
        #expect(defaults.data(forKey: "choices") == bytes)
        try store.removeUnreadableDefaults()
        #expect(try store.load() == .init())
        #expect(throws: ComposeGlobalWritingDefaultsError.staleEdit) { try store.removeUnreadableDefaults() }
    }

    @Test func spokenDirectionsRemoveConflictingDefaultsWithoutEditingThem() throws {
        let choices = ComposeGlobalWritingDefaults(isEnabled: true, tone: .warm, preferConcise: true)
        let input = try ScribeRequestPolicy.providerSafeInput(for: .init(intent: .compose, spokenTranscript: "Hey how are you? Write this formally.", writingDefaults: choices.values), destination: .legacyLocal)
        #expect(input.systemMessage.contains(ScribeWritingDirection.tone(.formal).instruction))
        #expect(!input.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(input.userMessage.contains(ScribeWritingDirection.concise.instruction))
        #expect(choices.tone == .warm)
        #expect(ComposeGlobalWritingDefaults().values.isEmpty)
    }

    @Test func explicitAppProfileOverridesGlobalDefaults() throws {
        let guidance = ResolvedScribeGuidance(familyID: .general, familyDefinitionVersion: 1, presetID: try ScribePresetID("general.neutral"), presetDefinitionVersion: 1, compiledPresetInstructions: "APP PROFILE STYLE", customGuidance: nil, resolutionSource: .configuredApplication, preservesExactLiterals: true, literalCapabilities: [])
        let request = ScribeRequest(intent: .compose, spokenTranscript: "The draft is ready.", resolvedGuidance: guidance, writingDefaults: [.tone(.warm)])
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(request.effectiveWritingDefaults.isEmpty)
        #expect(input.userMessage.contains("APP PROFILE STYLE"))
        #expect(!input.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
    }

    @Test func globalDefaultsNeverSelectAProviderOrBecomeSourceText() throws {
        let request = ScribeRequest(intent: .compose, spokenTranscript: "The draft is ready.", writingDefaults: [.tone(.polite)])
        for destination in [ScribeEgressDestination.legacyLocal, .openAIDirect] {
            let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: destination)
            #expect(input.userMessage.contains(ScribeWritingDirection.tone(.polite).instruction))
            #expect(request.spokenTranscript == "The draft is ready.")
            #expect(request.context == nil)
        }
    }

    @Test(arguments: [
        ("Hey, are you free to review the draft?", ComposeWritingPreferenceValue.tone(.formal), "Hello, are you available to review the draft?"),
        ("I think the draft is ready.", .tone(.formal), "I believe the draft is ready."),
        ("Maya, the preview is ready for review.", .tone(.warm), "Hi Maya, the preview is ready for review."),
        ("The project status update is ready for everyone to review.", .concise, "The project update is ready for everyone to review.")
    ])
    func simpleSavedPreferenceProducesImmediateVisibleEdit(
        spoken: String, preference: ComposeWritingPreferenceValue, expected: String
    ) throws {
        let request = ScribeRequest(intent: .compose, spokenTranscript: spoken, writingDefaults: [preference])
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.preparedDraft == expected)
        #expect(try ScribeRequestPolicy.validateOutput(expected, requiredLiterals: [], spokenRequest: spoken) == expected)
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .openAIDirect).preparedDraft == nil)
    }

    @Test(arguments: [
        "Hey, are you free to review the draft? I can send it today.",
        "Hey, are you free to review the draft; can you approve it?",
        "Maya, the preview is ready for review. Please call me.",
        "The project status update is ready for everyone to review. Keep the status word.",
        "I think the draft is ready, but I'm not sure."
    ])
    func compoundSavedPreferenceStaysOnModelPath(spoken: String) throws {
        let preference: ComposeWritingPreferenceValue = spoken.hasPrefix("Maya") ? .tone(.warm)
            : spoken.hasPrefix("The project") ? .concise : .tone(.formal)
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .init(intent: .compose, spokenTranscript: spoken, writingDefaults: [preference]),
            destination: .legacyLocal
        )
        #expect(input.preparedDraft == nil)
    }

    @Test func savedPreferenceShortcutRespectsOtherWritingAuthorities() throws {
        let spoken = "Maya, the preview is ready for review."
        let base = ScribeRequest(intent: .compose, spokenTranscript: spoken, writingDefaults: [.tone(.warm)])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: base, destination: .legacyLocal).preparedDraft != nil)
        let withLiteral = ScribeRequest(intent: .compose, spokenTranscript: spoken,
            exactLiterals: [.init(id: 1, value: "preview", source: .alreadyExact)], writingDefaults: [.tone(.warm)])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: withLiteral, destination: .legacyLocal).preparedDraft == nil)
        let withMorePreferences = ScribeRequest(intent: .compose, spokenTranscript: spoken,
            writingDefaults: [.tone(.warm), .concise])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: withMorePreferences, destination: .legacyLocal).preparedDraft == nil)
        let quoted = ScribeRequest(intent: .compose, spokenTranscript: "\"Maya, the preview is ready for review.\"",
            writingDefaults: [.tone(.warm)])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: quoted, destination: .legacyLocal).preparedDraft == nil)
        let explicitVoice = ScribeRequest(intent: .compose,
            spokenTranscript: "Maya, the preview is ready for review. Make this formal.", writingDefaults: [.tone(.warm)])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: explicitVoice, destination: .legacyLocal).preparedDraft == nil)
        let profile = ResolvedScribeGuidance(
            familyID: .general, familyDefinitionVersion: 1,
            presetID: try ScribePresetID("general.neutral"), presetDefinitionVersion: 1,
            compiledPresetInstructions: "Use the configured app style.", customGuidance: nil,
            resolutionSource: .configuredApplication, preservesExactLiterals: true,
            literalCapabilities: []
        )
        let configured = ScribeRequest(intent: .compose, spokenTranscript: spoken,
            resolvedGuidance: profile, writingDefaults: [.tone(.warm)])
        #expect(try ScribeRequestPolicy.providerSafeInput(for: configured, destination: .legacyLocal).preparedDraft == nil)
    }
}
