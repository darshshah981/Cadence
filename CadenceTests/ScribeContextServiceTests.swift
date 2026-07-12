import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeContextServiceTests {
    @Test
    func composeCapturesTargetWithoutReadingSelection() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a",
                recognitionSignature: nil
            )
        )
        let service = Self.makeService(reader)

        let capture = try service.capture()

        #expect(capture.scope == .none)
        #expect(capture.selectedText.isEmpty)
        #expect(capture.selectionIdentity == nil)
        #expect(reader.pinnedReadCount == 1)
        #expect(try service.verifyTarget(for: capture))
        #expect(reader.currentFocusReadCount == 1)
    }

    @Test
    func directDictationNeverReadsSelectionForLegacyIntentValues() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a"
            )
        )
        let service = Self.makeService(reader)

        let capture = try service.capture()

        #expect(capture.scope == .none)
        #expect(capture.selectedText.isEmpty)
        #expect(reader.pinnedReadCount == 1)
    }

    @Test
    func targetCaptureFailsClosedOnlyForUnavailableAccessibility() {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: nil)
        let cases: [(ScribeAccessibilityReadSnapshot, Bool, ScribeContextError)] = [
            (.init(target: target, verificationToken: "a"), false, .accessibilityDenied)
        ]

        for (snapshot, trusted, expectedError) in cases {
            let reader = StubScribeAccessibilityReader(snapshot: snapshot, isTrusted: trusted)
            let service = Self.makeService(reader)

            #expect(throws: expectedError) {
                try service.capture()
            }
        }
    }

    @Test
    func targetVerificationDetectsWindowChangeAndClearedCapture() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a"
            )
        )
        let service = Self.makeService(reader)
        let capture = try service.capture()

        reader.snapshot = .init(
            target: capture.target,
            verificationToken: "window-b"
        )
        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }

        service.clear(capture)
        #expect(throws: ScribeContextError.captureCleared) {
            try service.verifyTarget(for: capture)
        }
    }

    @Test
    func targetVerificationDoesNotReadSelectionForSameElement() throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: target,
                verificationToken: "window-a"
            )
        )
        let service = Self.makeService(reader)
        let capture = try service.capture()

        reader.snapshot = .init(
            target: target,
            verificationToken: "window-a"
        )

        #expect(try service.verifyTarget(for: capture))
    }

    @Test
    func verificationUsesFreshSystemFocusAndIgnoresMovedCaret() throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let signature = TargetRecognitionSignature(
            role: "AXTextArea",
            subrole: nil,
            identifierAncestry: ["editor"]
        )
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: target,
                verificationToken: "window-a",
                recognitionSignature: signature
            )
        )
        let service = Self.makeService(reader)
        let capture = try service.capture()

        reader.currentSnapshot = .init(
            target: target,
            verificationToken: "window-a",
            recognitionSignature: signature
        )

        #expect(try service.verifyTarget(for: capture))
        #expect(reader.currentFocusReadCount == 1)
    }

    @Test
    func accessibilityCaptureEnrichesOnlyExactRuntimeIdentityAndRejectsPIDReuse() throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let reader = StubScribeAccessibilityReader(snapshot: .init(
        target: target, verificationToken: "window-a"
        ))
        let monitor = ScribeTargetAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        let process = ScribeProcessAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        let service = ScribeContextService(
            reader: reader, processAuthority: process, targetAuthority: monitor
        )
        let capture = try service.capture()
        #expect(capture.applicationTarget.process.bundleURL.path == "/Applications/TextEdit.app")

        process.matches = false
        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }
    }

    @Test
    func monitorMismatchCannotOverrideAccessibilityAuthority() throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "window-a"
        ))
        let monitor = ScribeTargetAuthorityFake(pid: 99, bundleID: "other.app")
        let process = ScribeProcessAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        let service = ScribeContextService(
            reader: reader, processAuthority: process, targetAuthority: monitor
        )
        let capture = try service.capture()

        #expect(capture.applicationTarget.process.processIdentifier == 42)
        #expect(capture.applicationTarget.identityRevision == 0)
        #expect(try service.verifyTarget(for: capture))
    }

    @Test
    func unresolvedAccessibilityPIDFailsClosed() {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 404, bundleIdentifier: "missing.app"),
            verificationToken: "window-a"
        ))
        let process = ScribeProcessAuthorityFake(pid: 42, bundleID: "other.app")
        let service = ScribeContextService(reader: reader, processAuthority: process)

        #expect(throws: ScribeContextError.noFocusedTarget) {
            try service.capture()
        }
    }

    @Test
    func pidDirectAuthorityRejectsSamePIDRelaunchIncarnation() throws {
        let source = RuntimeProcessSourceFake(snapshot: .init(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
            displayName: "TextEdit",
            launchDate: Date(timeIntervalSince1970: 10)
        ))
        let authority = RuntimeApplicationProcessAuthority(source: source)
        let captured = try authority.capture(
            processIdentifier: 42,
            expectedBundleIdentifier: "com.apple.TextEdit"
        ).identity
        source.snapshot = .init(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
            displayName: "TextEdit",
            launchDate: Date(timeIntervalSince1970: 20)
        )

        #expect(authority.verify(captured) == false)
    }

    private static func makeService(
        _ reader: StubScribeAccessibilityReader
    ) -> ScribeContextService {
        let target = reader.snapshot.target
        return ScribeContextService(
            reader: reader,
            processAuthority: ScribeProcessAuthorityFake(
                pid: target.processIdentifier,
                bundleID: target.bundleIdentifier ?? "com.apple.TextEdit"
            )
        )
    }
}

@MainActor
private final class RuntimeProcessSourceFake: RuntimeApplicationProcessSourcing {
    var snapshot: RuntimeApplicationProcessSnapshot?
    init(snapshot: RuntimeApplicationProcessSnapshot?) { self.snapshot = snapshot }
    func process(processIdentifier: Int32) -> RuntimeApplicationProcessSnapshot? {
        snapshot?.processIdentifier == processIdentifier ? snapshot : nil
    }
}

@MainActor
private final class ScribeProcessAuthorityFake: RuntimeApplicationProcessAuthorizing {
    let identity: ApplicationProcessIdentity
    let displayName: String?
    var matches = true

    init(pid: Int32, bundleID: String, displayName: String? = "TextEdit") {
        self.identity = .init(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 1)
        )
        self.displayName = displayName
    }

    func capture(
        processIdentifier: Int32,
        expectedBundleIdentifier: String?
    ) throws -> (identity: ApplicationProcessIdentity, displayName: String?) {
        guard processIdentifier == identity.processIdentifier,
              expectedBundleIdentifier == nil || expectedBundleIdentifier == identity.bundleIdentifier else {
            throw ScribeContextError.noFocusedTarget
        }
        return (identity, displayName)
    }

    func verify(_ identity: ApplicationProcessIdentity) -> Bool {
        matches && identity == self.identity
    }
}

@MainActor
private final class ScribeTargetAuthorityFake: ApplicationTargetAuthorizing {
    let identity: ApplicationProcessIdentity
    var matches = true
    init(pid: Int32, bundleID: String) {
        identity = .init(
            processIdentifier: pid, bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"), incarnation: UUID()
        )
    }
    func capture(source: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture {
        .init(process: identity, identityRevision: 1, captureRevision: 1, source: source)
    }
    func verify(_ capture: ApplicationTargetCapture) async throws {
        if !matches { throw ApplicationTargetAuthorityError.targetChanged }
    }
    func enrich(processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationProcessIdentity? {
        processIdentifier == identity.processIdentifier && bundleIdentifier == identity.bundleIdentifier
            ? identity : nil
    }
    func enrichCapture(id: UUID, processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationTargetCapture? {
        guard let process = enrich(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return .init(
            id: id, process: process, identityRevision: 1, captureRevision: 1,
            source: .scribeAccessibility
        )
    }
    func matchesCurrent(_ identity: ApplicationProcessIdentity) -> Bool { matches && identity == self.identity }
}

@MainActor
private final class StubScribeAccessibilityReader: ScribeAccessibilityReading {
    var snapshot: ScribeAccessibilityReadSnapshot
    var currentSnapshot: ScribeAccessibilityReadSnapshot?
    var isTrusted: Bool
    private(set) var pinnedReadCount = 0
    private(set) var currentFocusReadCount = 0

    init(snapshot: ScribeAccessibilityReadSnapshot, isTrusted: Bool = true) {
        self.snapshot = snapshot
        self.isTrusted = isTrusted
    }

    func pinFocusedTarget() throws {}

    func readPinnedSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        pinnedReadCount += 1
        return snapshot
    }

    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        currentFocusReadCount += 1
        return currentSnapshot ?? snapshot
    }

    func replacePinnedSelection(with text: String) throws -> Bool { true }
    func clearPinnedTarget() {}
}
