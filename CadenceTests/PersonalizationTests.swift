import Foundation
import Testing
@testable import Cadence

struct PersonalizationTests {
    @Test
    func storeRoundTripsVersionedPersonalizationWithoutLegacyData() throws {
        let suiteName = "CadenceTests.Personalization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationStore(defaults: defaults, key: "personalization")
        let shortcut = PersonalShortcut(trigger: "weekly update", template: "Wins:\nRisks:\nNext:")
        let profile = WritingStyleProfile(
            name: "Mail",
            appBundleIdentifier: "com.apple.mail",
            tone: .professional,
            length: .concise
        )

        try store.save(PersonalizationLibrary(shortcuts: [shortcut], styleProfiles: [profile]))
        let loaded = store.load()

        #expect(loaded.schemaVersion == PersonalizationLibrary.currentSchemaVersion)
        #expect(loaded.shortcuts == [shortcut])
        #expect(loaded.styleProfiles == [profile])
    }

    @Test
    func malformedOrFuturePersistenceFailsClosedToEmptyLibrary() {
        let suiteName = "CadenceTests.Personalization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationStore(defaults: defaults, key: "personalization")

        defaults.set(Data("not-json".utf8), forKey: "personalization")
        #expect(store.load() == .empty)

        let future = PersonalizationLibrary(schemaVersion: 999, shortcuts: [], styleProfiles: [])
        defaults.set(try? JSONEncoder().encode(future), forKey: "personalization")
        #expect(store.load() == .empty)
    }

    @Test
    func shortcutExpansionUsesAppScopeLongestMatchAndTokenBoundaries() {
        let global = PersonalShortcut(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            trigger: "update",
            template: "GLOBAL"
        )
        let longer = PersonalShortcut(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            trigger: "weekly update",
            template: "WEEKLY"
        )
        let mail = PersonalShortcut(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            trigger: "update",
            template: "MAIL",
            scope: .application("com.apple.mail")
        )

        let result = ShortcutExpansionService.expand(
            "weekly update, then update; updater stays.",
            bundleIdentifier: "com.apple.mail",
            shortcuts: [global, longer, mail]
        )

        #expect(result == "WEEKLY, then MAIL; updater stays.")
    }

    @Test
    func shortcutExpansionIgnoresDisabledAndMalformedEntries() {
        let shortcuts = [
            PersonalShortcut(trigger: "brb", template: "be right back", isEnabled: false),
            PersonalShortcut(trigger: "", template: "invalid"),
            PersonalShortcut(trigger: "x", template: "")
        ]

        #expect(ShortcutExpansionService.expand("brb x", bundleIdentifier: nil, shortcuts: shortcuts) == "brb x")
    }

    @Test
    func styleProfilesPreferExactAppAndPreserveDeterministicFallback() {
        let general = WritingStyleProfile(name: "Default", tone: .natural, length: .balanced)
        let code = WritingStyleProfile(
            name: "Code",
            appBundleIdentifier: "com.apple.dt.Xcode",
            tone: .natural,
            length: .balanced,
            punctuation: .literal,
            formatting: .plainText,
            preservesCodeLiterals: true
        )

        #expect(StyleProfileResolver.resolve(
            bundleIdentifier: "com.apple.dt.Xcode",
            profiles: [general, code]
        ) == code)
        #expect(StyleProfileResolver.resolve(
            bundleIdentifier: "com.unknown.app",
            profiles: [general, code]
        ) == general)
        #expect(StyleProfileResolver.resolve(bundleIdentifier: nil, profiles: []) == nil)
    }
}
