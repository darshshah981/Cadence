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
    func insertAllowsCadenceReviewSurfaceWaitsAndReverifiesPinnedTargetFocus() async throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: target,
            verificationToken: "window-a"
        ))
        let textInsertion = StubScribeTextInsertionService()
        let service = Self.makeService(
            reader,
            transientControlProcessIdentifier: 99,
            textInsertion: textInsertion
        )
        let capture = try service.capture()
        reader.currentSnapshot = .init(
            target: .init(
                processIdentifier: 99,
                bundleIdentifier: "com.darshshah.Cadence.debug"
            ),
            verificationToken: "scribe-review-window"
        )

        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }
        #expect(try await service.insert("Polished draft", for: capture))
        #expect(reader.restoredProcessIdentifiers == [42, 42])
        #expect(textInsertion.insertedTexts == ["Polished draft"])
        #expect(reader.currentFocusReadCount == 3)

        reader.currentSnapshot = .init(
            target: .init(processIdentifier: 100, bundleIdentifier: "com.apple.Safari"),
            verificationToken: "unrelated-window"
        )
        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }
    }

    @Test
    func insertNeverEmitsUnicodeWhenRestoredFocusIsNotTheCapturedApp() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(
                processIdentifier: 42,
                bundleIdentifier: "com.apple.TextEdit"
            ),
            verificationToken: "window-a"
        ))
        reader.restoredTargetOverride = .init(
            processIdentifier: 100,
            bundleIdentifier: "com.apple.Safari"
        )
        let textInsertion = StubScribeTextInsertionService()
        let service = Self.makeService(
            reader,
            transientControlProcessIdentifier: 99,
            textInsertion: textInsertion
        )
        let capture = try service.capture()
        reader.currentSnapshot = .init(
            target: .init(
                processIdentifier: 99,
                bundleIdentifier: "com.darshshah.Cadence.debug"
            ),
            verificationToken: "scribe-review-window"
        )

        await #expect(throws: ScribeContextError.targetChanged) {
            try await service.insert("Do not misdirect this", for: capture)
        }
        #expect(textInsertion.insertedTexts.isEmpty)
    }

    @Test
    func insertAllowsTheCapturedAppToRebuildItsAccessibilityWrapper() async throws {
        let target = ScribeTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit"
        )
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: target,
            verificationToken: "original-wrapper",
            recognitionSignature: .init(
                role: "AXTextArea",
                subrole: nil,
                identifierAncestry: ["original-editor"]
            )
        ))
        let textInsertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, textInsertion: textInsertion)
        let capture = try service.capture()
        reader.currentSnapshot = .init(
            target: target,
            verificationToken: "rebuilt-wrapper",
            recognitionSignature: .init(
                role: "AXTextArea",
                subrole: nil,
                identifierAncestry: ["rebuilt-editor"]
            )
        )

        #expect(try await service.insert("Visible draft", for: capture))
        #expect(textInsertion.insertedTexts == ["Visible draft"])
    }

    @Test
    func appTargetKeepsScribeAvailableWhenEditorHasNoFocusedAccessibilityElement() async throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "unavailable"
            )
        )
        reader.pinError = .noFocusedTarget
        reader.pinnedReadError = .noFocusedTarget
        let monitor = ScribeTargetAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        let textInsertion = StubScribeTextInsertionService()
        let service = ScribeContextService(
            reader: reader,
            processAuthority: ScribeProcessAuthorityFake(
                pid: 42,
                bundleID: "com.apple.TextEdit"
            ),
            targetAuthority: monitor,
            insertionFocusSettleDelay: .zero,
            textInsertion: textInsertion
        )

        try await service.prepareTarget()
        let capture = try service.capture()

        #expect(capture.target.processIdentifier == 42)
        #expect(capture.verificationToken.hasPrefix("application:"))
        #expect(try service.verifyTarget(for: capture))
        #expect(try await service.insert("Scribed draft", for: capture))
        #expect(monitor.activatedCaptures == [capture.applicationTarget])
        #expect(textInsertion.insertedTexts == ["Scribed draft"])
    }

    @Test
    func missingFrontmostApplicationStillProducesActionableContextError() async {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "unavailable"
            )
        )
        let monitor = ScribeTargetAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        monitor.captureError = .noExternalTarget
        let service = ScribeContextService(
            reader: reader,
            processAuthority: ScribeProcessAuthorityFake(
                pid: 42,
                bundleID: "com.apple.TextEdit"
            ),
            targetAuthority: monitor
        )

        await #expect(throws: ScribeContextError.noFocusedTarget) {
            try await service.prepareTarget()
        }
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
        _ reader: StubScribeAccessibilityReader,
        transientControlProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        insertionFocusSettleDelay: Duration = .zero,
        textInsertion: TextInsertionServing = StubScribeTextInsertionService()
    ) -> ScribeContextService {
        let target = reader.snapshot.target
        return ScribeContextService(
            reader: reader,
            processAuthority: ScribeProcessAuthorityFake(
                pid: target.processIdentifier,
                bundleID: target.bundleIdentifier ?? "com.apple.TextEdit"
            ),
            transientControlProcessIdentifier: transientControlProcessIdentifier,
            insertionFocusSettleDelay: insertionFocusSettleDelay,
            textInsertion: textInsertion
        )
    }
}

private final class StubScribeTextInsertionService: TextInsertionServing {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String) async throws {
        insertedTexts.append(text)
    }

    func pressReturn() async throws {}
    func deleteLastInsertion() async throws {}
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
    var captureError: ApplicationTargetAuthorityError?
    private(set) var activatedCaptures: [ApplicationTargetCapture] = []
    init(pid: Int32, bundleID: String) {
        identity = .init(
            processIdentifier: pid, bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 1)
        )
    }
    func capture(source: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture {
        if let captureError { throw captureError }
        return .init(process: identity, identityRevision: 1, captureRevision: 1, source: source)
    }
    func verify(_ capture: ApplicationTargetCapture) async throws {
        if !matches { throw ApplicationTargetAuthorityError.targetChanged }
    }
    func activate(_ capture: ApplicationTargetCapture) -> Bool {
        guard capture.process == identity, matches else { return false }
        activatedCaptures.append(capture)
        return true
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
    var restoredTargetOverride: ScribeTargetIdentity?
    var pinError: ScribeContextError?
    var pinnedReadError: ScribeContextError?
    private(set) var pinnedReadCount = 0
    private(set) var currentFocusReadCount = 0
    private(set) var restoredProcessIdentifiers: [pid_t] = []

    init(snapshot: ScribeAccessibilityReadSnapshot, isTrusted: Bool = true) {
        self.snapshot = snapshot
        self.isTrusted = isTrusted
    }

    func pinFocusedTarget() throws {
        if let pinError { throw pinError }
    }

    func readPinnedSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        pinnedReadCount += 1
        if let pinnedReadError { throw pinnedReadError }
        return snapshot
    }

    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        currentFocusReadCount += 1
        return currentSnapshot ?? snapshot
    }

    func restorePinnedTargetFocus(processIdentifier: pid_t) throws {
        restoredProcessIdentifiers.append(processIdentifier)
        currentSnapshot = ScribeAccessibilityReadSnapshot(
            target: restoredTargetOverride ?? snapshot.target,
            verificationToken: "restored-wrapper"
        )
    }

    func clearPinnedTarget() {}
}
