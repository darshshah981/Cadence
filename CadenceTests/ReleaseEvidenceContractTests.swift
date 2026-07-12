import Foundation
import Testing
@testable import Cadence

/// U13 evidence/packaging contracts: scripts, schema fields, and fail-closed live gates.
struct ReleaseEvidenceContractTests {
    @Test
    func packageReleaseEmbedsFullSourceCommitAndRefusesDirtyTrees() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package_release.sh"),
            encoding: .utf8
        )
        #expect(script.contains("CADENCE_SOURCE_COMMIT"))
        #expect(script.contains("git rev-parse HEAD"))
        #expect(script.contains("dirty worktree"))
        #expect(script.contains("CadenceSourceCommit"))
        #expect(script.contains("Refusing to package a debug build") || script.contains("debug build"))

        let info = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadence/Supporting/Info.plist"),
            encoding: .utf8
        )
        #expect(info.contains("CadenceSourceCommit"))
        #expect(info.contains("CADENCE_SOURCE_COMMIT"))

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(project.contains("CADENCE_SOURCE_COMMIT"))
    }

    @Test
    func collectorCheckCoversLiveVerifiersAndSchemaV2Fields() throws {
        let collector = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/collect_adaptive_scribe_evidence.sh"),
            encoding: .utf8
        )
        #expect(collector.contains("verify_live_scribe_providers.sh"))
        #expect(collector.contains("verify_scribe_real_apps.sh"))
        #expect(collector.contains("schemaVersion\": 2") || collector.contains("\"schemaVersion\": 2"))
        #expect(collector.contains("embeddedSourceCommit"))
        #expect(collector.contains("Refusing to overwrite finalized manifest"))
        #expect(collector.contains("liveOpenAIDirectGate"))
        #expect(collector.contains("liveOpenRouterGate"))
        #expect(collector.contains("DOGOFOOD_ALLOWLIST") || collector.contains("Dogfood artifact"))
        #expect(collector.contains("os.replace"))
    }

    @Test
    func liveProviderVerifierNeverAutoPassesAndHasCheckMode() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify_live_scribe_providers.sh"),
            encoding: .utf8
        )
        #expect(script.contains("--check"))
        #expect(script.contains("openAIDirect"))
        #expect(script.contains("openRouter"))
        #expect(script.contains("NOT_RUN"))
        #expect(script.contains("refused to emit PASS") || script.contains("never auto-PASS") || script.contains("never auto"))
        #expect(!script.contains("sk-"))
    }

    @Test
    func realAppVerifierIsOperatorAttestedOnly() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify_scribe_real_apps.sh"),
            encoding: .utf8
        )
        #expect(script.contains("cursor"))
        #expect(script.contains("slack"))
        #expect(script.contains("codex"))
        #expect(script.contains("CADENCE_REAL_APP_PROOF"))
        #expect(script.contains("aggregateOnly") || script.contains("Aggregate"))
        #expect(script.contains("does not emit raw PASS") || script.contains("PASS_OPERATOR_ATTESTED"))
    }

    @Test
    func releaseEvidenceDocsCoverOpenAIOpenRouterAndCursorSlackCodex() throws {
        let evidence = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/adaptive-scribe-release-evidence.md"),
            encoding: .utf8
        )
        let checklist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/release-checklist.md"),
            encoding: .utf8
        )
        for doc in [evidence, checklist] {
            #expect(doc.localizedCaseInsensitiveContains("OpenAI") || doc.contains("openAI"))
            #expect(doc.localizedCaseInsensitiveContains("OpenRouter") || doc.contains("openrouter"))
        }
        #expect(evidence.localizedCaseInsensitiveContains("Cursor") || evidence.contains("cursor"))
        #expect(evidence.localizedCaseInsensitiveContains("Slack"))
        #expect(evidence.localizedCaseInsensitiveContains("Codex") || evidence.contains("codex"))
        #expect(evidence.contains("NOT RUN") || evidence.contains("NOT_RUN") || evidence.contains("a green PR is never substituted"))
    }

    @Test
    func evidenceCheckModeScriptsAreExecutableContracts() throws {
        // Structural presence only — network and signing are release-owner paths.
        for relative in [
            "scripts/verify_live_scribe_providers.sh",
            "scripts/verify_scribe_real_apps.sh",
            "scripts/collect_adaptive_scribe_evidence.sh",
            "scripts/package_release.sh"
        ] {
            let url = repositoryRoot.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.hasPrefix("#!/usr/bin/env bash") || content.contains("set -euo pipefail"))
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
