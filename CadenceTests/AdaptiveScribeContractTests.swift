import Foundation
import Testing
@testable import Cadence

struct AdaptiveScribeContractTests {
    @Test
    func privacyDocumentationContainsCanonicalRecipientAndDeletionTruth() throws {
        let privacy = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/privacy.md"),
            encoding: .utf8
        )

        #expect(privacy.contains("Cadence does not send audio, window titles, nearby text"))
        #expect(privacy.contains("Local removal does not revoke a key at the provider"))
        #expect(privacy.contains("Release one sends no remote Scribe telemetry"))
        #expect(ScribeProviderDisclosure.deepSeek.contains("directly to DeepSeek at api.deepseek.com"))
        #expect(ScribeProviderDisclosure.removal(provider: "DeepSeek").contains("does not revoke the key"))
    }

    @Test
    func releaseCorpusIsVersionedSyntheticBalancedAndComplete() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "CadenceTests/Fixtures/AdaptiveScribe/quality-corpus.json"
        ))
        let manifestData = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "CadenceTests/Fixtures/AdaptiveScribe/quality-corpus-manifest.json"
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let cases = try #require(object["cases"] as? [[String: Any]])
        let ids = cases.compactMap { $0["id"] as? String }

        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["syntheticOnly"] as? Bool == true)
        #expect(manifest["schemaVersion"] as? Int == 2)
        #expect(manifest["syntheticOnly"] as? Bool == true)
        #expect(manifest["dictationOnly"] as? Bool == true)
        #expect(manifest["caseCount"] as? Int == 24)
        #expect(cases.count == 24)
        #expect(Set(ids).count == 24)
        #expect(cases.filter { $0["family"] as? String == "general" }.count == 8)
        #expect(cases.filter { $0["family"] as? String == "messaging" }.count == 8)
        #expect(cases.filter { $0["family"] as? String == "coding" }.count == 8)
        #expect(cases.allSatisfy { $0["selection"] == nil && $0["intent"] == nil })
        #expect(cases.allSatisfy { ($0["spoken"] as? String)?.contains("CANARY") != true })
    }

    @Test
    func evidenceCollectorKeepsReleaseOnlyGatesExplicitlyNotRun() throws {
        let collector = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/collect_adaptive_scribe_evidence.sh"
            ),
            encoding: .utf8
        )
        let runbook = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "docs/adaptive-scribe-release-evidence.md"
            ),
            encoding: .utf8
        )

        #expect(collector.contains("Refusing evidence collection from a dirty worktree"))
        #expect(collector.contains("hdiutil attach"))
        #expect(collector.contains("CFBundleIdentifier"))
        #expect(collector.contains("evidenceArtifacts"))
        #expect(collector.contains("\"finalDecision\": \"NOT_RUN\""))
        #expect(runbook.contains("a green PR is never substituted"))
        #expect(runbook.contains("Five-Workday Dogfood"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
