import Foundation
import Testing
@testable import Cadence

/// U12 Release fixture isolation: synthetic hooks are DEBUG-only, synthetic
/// corpora cannot authorize live evidence, and fixture args cannot grant
/// consent, activation, approval, or insertion in production code paths.
struct ReleaseFixtureIsolationTests {
    @Test
    func launchFixturesAreDebugOnlyAndUseOnlyVolatileCredentialStorage() throws {
        let fixture = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadence/App/ScribeLaunchFixtures.swift"),
            encoding: .utf8
        )
        #expect(fixture.hasPrefix("#if DEBUG"))
        #expect(fixture.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(fixture.contains("VolatileScribeCredentialStore"))
        #expect(fixture.contains("usesIsolatedRuntimeStorage"))
        #expect(fixture.contains("--scribe-fixture"))
    }

    @Test
    func appModelFixturePresentationIsCompiledOutOfRelease() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadence/App/AppModel.swift"),
            encoding: .utf8
        )
        #expect(source.contains("#if DEBUG"))
        #expect(source.contains("presentScribeLaunchFixtureIfNeeded"))
        #expect(source.contains("ScribeLaunchFixtures.runtimeDefaults()"))

        // The fixture entry points must not appear outside DEBUG regions in a
        // way that Release can call them. Guard by requiring each fixture
        // presentation site sits after an open `#if DEBUG` in the same file.
        let fixtureSites = source.ranges(of: "presentScribeLaunchFixtureIfNeeded")
        #expect(!fixtureSites.isEmpty)
        for site in fixtureSites {
            let prefix = source[..<site.lowerBound]
            let debugOpens = prefix.components(separatedBy: "#if DEBUG").count - 1
            let debugCloses = prefix.components(separatedBy: "#endif").count - 1
            #expect(debugOpens > debugCloses, "Fixture presentation must be nested under #if DEBUG")
        }
    }

    @Test
    func adaptiveScribeFixturesDeclareSyntheticOnlyContent() throws {
        let root = repositoryRoot.appendingPathComponent("CadenceTests/Fixtures/AdaptiveScribe")
        let corpus = try String(contentsOf: root.appendingPathComponent("quality-corpus.json"), encoding: .utf8)
        let manifest = try String(contentsOf: root.appendingPathComponent("quality-corpus-manifest.json"), encoding: .utf8)
        #expect(corpus.contains("\"syntheticOnly\": true"))
        #expect(manifest.contains("\"syntheticOnly\": true"))
        #expect(manifest.contains("\"dictationOnly\": true"))
        #expect(!corpus.contains("SCRIBE_KEY_CANARY"))
        #expect(!manifest.contains("sk-"))
    }

    @Test
    func fixtureArgumentsCannotAppearInReleasePackagingScriptsAsAuthPath() throws {
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package_release.sh"),
            encoding: .utf8
        )
        #expect(!package.contains("--scribe-fixture"))
        #expect(!package.contains("ScribeLaunchFixture"))
        #expect(package.contains("Release") || package.contains("CONFIGURATION"))
    }

    @Test
    func evidenceCollectorCheckModeDoesNotTreatFixturesAsLiveGates() throws {
        let collector = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/collect_adaptive_scribe_evidence.sh"),
            encoding: .utf8
        )
        #expect(collector.contains("--check") || collector.contains("MODE=\"check\"") || collector.contains("MODE=check") || collector.contains("check"))
        #expect(collector.contains("NOT_RUN"))
        #expect(!collector.contains("SCRIBE_KEY_CANARY"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}

private extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let found = range(of: substring, range: search) {
            result.append(found)
            search = found.upperBound..<endIndex
        }
        return result
    }
}
