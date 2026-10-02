import CoreGraphics
import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeContextServiceTests {
    @Test
    func originalFocusedWindowFrameIsPinnedWithoutReadingContent() throws {
        let frame = CGRect(x: 20, y: 30, width: 600, height: 400)
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "selected-field"
        ))
        reader.pinnedWindowFrame = frame
        let service = Self.makeService(reader)
        let capture = try service.capture()
        #expect(reader.windowFrameReadCount == 0)
        #expect(try service.pinnedWindowFrame(for: capture) == frame)
        #expect(reader.windowFrameReadCount == 1)
        #expect(capture.selectedText.isEmpty)
    }

    @Test
    func transientFocusedElementAbsenceRetriesBeforeCapturing() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "selected-field"
        ))
        reader.pinFailuresRemaining = 2
        let service = Self.makeService(reader)

        try await service.prepareTarget()
        let capture = try service.capture()
        #expect(reader.pinAttemptCount == 3)
        #expect(capture.verificationToken == "selected-field")
        #expect(try service.verifyTarget(for: capture))
    }

    @Test
    func persistentFocusedElementAbsenceFailsWithoutReusingOldPin() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "selected-field"
        ))
        reader.pinFailuresRemaining = 4
        let service = Self.makeService(reader)

        await #expect(throws: ScribeContextError.noFocusedTarget) { try await service.prepareTarget() }
        #expect(reader.pinAttemptCount == 4)
    }

    @Test
    func contextRefreshRestoresOnlyPinnedFieldAndNeverInserts() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, transientControlProcessIdentifier: 99, textInsertion: insertion)
        let capture = try service.capture()
        reader.currentSnapshot = .init(target: .init(processIdentifier: 99, bundleIdentifier: "com.darshshah.Cadence.debug"), verificationToken: "review")
        try await service.restoreTargetForContextRefresh(capture)
        #expect(reader.restoredProcessIdentifiers == [42])
        #expect(try service.verifyTarget(for: capture))
        #expect(insertion.insertedTexts.isEmpty)
        #expect(reader.pinnedReadCount == 1)
        reader.isTrusted = false
        await #expect(throws: ScribeContextError.accessibilityDenied) {
            try await service.restoreTargetForContextRefresh(capture)
        }
        #expect(reader.restoredProcessIdentifiers == [42])
    }

    @Test
    func contextRefreshRejectsUnrelatedFocusBeforeRestoration() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let service = Self.makeService(reader)
        let capture = try service.capture()
        reader.currentSnapshot = .init(target: .init(processIdentifier: 43, bundleIdentifier: "com.example.Other"), verificationToken: "other-field")
        await #expect(throws: ScribeContextError.targetChanged) { try await service.restoreTargetForContextRefresh(capture) }
        #expect(reader.restoredProcessIdentifiers.isEmpty)
    }

    @Test
    func missingFocusedElementInDifferentFrontmostProcessIsTargetChanged() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.example.Editor"),
            verificationToken: "original-field"
        ))
        reader.currentFocusError = .noFocusedTarget
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(
            reader, textInsertion: insertion, frontmostProcessIdentifier: { 43 }
        )
        let capture = try service.capture()
        await #expect(throws: ScribeContextError.targetChanged) {
            try await service.insert("Never redirect", for: capture)
        }
        #expect(insertion.insertedTexts.isEmpty)

        let sameProcess = Self.makeService(
            reader, textInsertion: insertion, frontmostProcessIdentifier: { 42 }
        )
        let sameCapture = try sameProcess.capture()
        await #expect(throws: ScribeContextError.noFocusedTarget) {
            try await sameProcess.insert("Still unavailable", for: sameCapture)
        }
        #expect(insertion.insertedTexts.isEmpty)
    }

    @Test
    func memoryReviewFocusAllowsOnlyCadenceControlsForThePinnedCapture() throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "selected-field"
        ))
        let service = Self.makeService(reader, transientControlProcessIdentifier: 99)
        let capture = try service.capture()
        reader.currentSnapshot = .init(
            target: .init(processIdentifier: 99, bundleIdentifier: "com.darshshah.Cadence.debug"),
            verificationToken: "review"
        )
        #expect(try service.verifyTargetAllowingComposeReviewFocus(for: capture))
        reader.currentSnapshot = .init(
            target: .init(processIdentifier: 43, bundleIdentifier: "com.example.Other"),
            verificationToken: "other-field"
        )
        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTargetAllowingComposeReviewFocus(for: capture)
        }
        service.clear(capture)
        #expect(throws: ScribeContextError.captureCleared) {
            try service.verifyTargetAllowingComposeReviewFocus(for: capture)
        }
    }

    @Test
    func contextRefreshChecksFieldAgainAfterRestoration() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let service = Self.makeService(reader)
        let capture = try service.capture()
        reader.restoredSnapshotOverride = .init(target: capture.target, verificationToken: "different-field")
        await #expect(throws: ScribeContextError.targetChanged) { try await service.restoreTargetForContextRefresh(capture) }
        service.clear(capture)
        await #expect(throws: ScribeContextError.captureCleared) { try await service.restoreTargetForContextRefresh(capture) }
        #expect(reader.restoredProcessIdentifiers == [42])
    }

    @Test
    func selectedReplacementPreflightRunsAfterOriginalFocusRestoration() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, transientControlProcessIdentifier: 99, textInsertion: insertion)
        let capture = try service.capture()
        reader.currentSnapshot = .init(target: .init(processIdentifier: 99, bundleIdentifier: "com.darshshah.Cadence.debug"), verificationToken: "review")
        var calls = 0
        let inserted = try await service.insert("Rewrite", for: capture, selectedTextPreflight: {
            calls += 1
            #expect(reader.restoredProcessIdentifiers == [42, 42])
            #expect((try? reader.readCurrentFocusSnapshot().target) == capture.target)
            #expect(insertion.insertedTexts.isEmpty)
            return true
        })
        #expect(inserted)
        #expect(calls == 1)
        #expect(insertion.insertedTexts == ["Rewrite"])
    }

    @Test
    func staleSelectionPreflightEmitsZeroReplacementEvents() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, textInsertion: insertion)
        let capture = try service.capture()
        await #expect(throws: ScribeContextError.selectionChanged) {
            try await service.insert("Never replace", for: capture, selectedTextPreflight: { false })
        }
        #expect(insertion.insertedTexts.isEmpty)
        #expect(try await service.insert("Replacement", for: capture, selectedTextPreflight: { true }))
        #expect(insertion.insertedTexts == ["Replacement"])
    }

    @Test
    func targetChangedDuringSelectionPreflightEmitsZeroEvents() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"), verificationToken: "selected-field"))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, textInsertion: insertion)
        let capture = try service.capture()
        await #expect(throws: ScribeContextError.targetChanged) {
            try await service.insert("Never redirect", for: capture, selectedTextPreflight: {
                reader.currentSnapshot = .init(target: capture.target, verificationToken: "changed-field")
                return true
            })
        }
        #expect(insertion.insertedTexts.isEmpty)
    }

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
    func secureAndKnownNoneditableTargetsAreRejectedBeforeInsertion() throws {
        let secureReader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "secure-field"
        ))
        let secureService = Self.makeService(
            secureReader,
            targetCapability: StubScribeTargetCapabilityService(.notEditable(.secureTextRole))
        )
        #expect(throws: ScribeContextError.secureField) {
            try secureService.capture()
        }

        let buttonReader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "button"
        ))
        let buttonService = Self.makeService(
            buttonReader,
            targetCapability: StubScribeTargetCapabilityService(.notEditable(.nonTextRole))
        )
        #expect(throws: ScribeContextError.unsupportedSelection) {
            try buttonService.capture()
        }
    }

    @Test
    func alreadyFocusedCursorComposerKeepsItsExistingKeyboardFocus() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.muse.app"),
            verificationToken: "cursor-composer",
            recognitionSignature: .init(role: "AXButton", subrole: nil, identifierAncestry: [])
        ))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(
            reader,
            targetCapability: StubScribeTargetCapabilityService(.unknown(.webTextCursorHint)),
            textInsertion: insertion,
            frontmostProcessIdentifier: { 42 }
        )
        let capture = try service.capture()

        #expect(try await service.insert("Draft", for: capture))
        // The AX wrapper can be a button around the real web editor. Re-focusing
        // that wrapper needlessly can replace its already-correct DOM cursor.
        #expect(reader.restoredProcessIdentifiers.isEmpty)
        #expect(insertion.insertedTexts == ["Draft"])
    }

    @Test
    func unknownCursorTargetRemainsEligibleForGuardedInsertion() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.muse.app"),
            verificationToken: "muse-editor"
        ))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(
            reader,
            targetCapability: StubScribeTargetCapabilityService(.unknown(.webTextCursorHint)),
            textInsertion: insertion
        )
        let capture = try service.capture()

        #expect(try await service.insert("Draft", for: capture))
        #expect(insertion.insertedTexts == ["Draft"])
        await #expect(throws: ScribeContextError.insertionUnconfirmed) {
            try await service.insert("Draft", for: capture)
        }
        #expect(insertion.insertedTexts == ["Draft"])
    }

    @Test
    func overlappingInsertionsForOneCapturePostOnlyOnce() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "same-field"
        ))
        let insertion = PausingScribeTextInsertionService()
        let service = Self.makeService(reader, textInsertion: insertion)
        let capture = try service.capture()
        let first = Task { try await service.insert("Draft", for: capture) }
        await insertion.waitUntilStarted()
        await #expect(throws: ScribeContextError.insertionUnconfirmed) {
            try await service.insert("Draft", for: capture)
        }
        await insertion.release()
        #expect(try await first.value)
        let posted = await insertion.insertedTexts
        #expect(posted == ["Draft"])
    }

    @Test
    func capabilityIsRecheckedAfterRestorationBeforeUnicodeEvents() async throws {
        for (assessment, expected) in [
            (DictationTargetCapabilityAssessment.notEditable(.secureTextRole), ScribeContextError.secureField),
            (.notEditable(.nonTextRole), .unsupportedSelection)
        ] {
            let reader = StubScribeAccessibilityReader(snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "field-a"
            ))
            let capability = StubScribeTargetCapabilityService(.editable(.standardTextRole))
            let insertion = StubScribeTextInsertionService()
            let service = Self.makeService(
                reader,
                targetCapability: capability,
                textInsertion: insertion
            )
            let capture = try service.capture()
            capability.assessment = assessment

            await #expect(throws: expected) {
                try await service.insert("Never emit", for: capture)
            }
            #expect(insertion.insertedTexts.isEmpty)
        }
    }

    @Test
    func changedFieldInSameProcessRejectsBeforeRestorationOrInsertion() async throws {
        let reader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "field-a",
            recognitionSignature: .init(role: "AXTextField", subrole: nil, identifierAncestry: ["field-a"])
        ))
        let insertion = StubScribeTextInsertionService()
        let service = Self.makeService(reader, textInsertion: insertion)
        let capture = try service.capture()
        reader.currentSnapshot = .init(
            target: capture.target,
            verificationToken: "field-b",
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: ["field-b"])
        )

        await #expect(throws: ScribeContextError.targetChanged) {
            try await service.insert("Do not redirect", for: capture)
        }
        #expect(reader.restoredProcessIdentifiers.isEmpty)
        #expect(insertion.insertedTexts.isEmpty)
    }

    @Test
    func restorationFailureAndDestroyedProcessLeaveDraftRecoverable() async throws {
        let restorationReader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "window-a"
        ))
        restorationReader.currentSnapshot = .init(
            target: .init(processIdentifier: 99, bundleIdentifier: "com.darshshah.Cadence.debug"),
            verificationToken: "review"
        )
        restorationReader.restoreError = .targetChanged
        let restorationInsertion = StubScribeTextInsertionService()
        let restorationService = Self.makeService(restorationReader, textInsertion: restorationInsertion)
        let restorationCapture = try restorationService.capture()

        await #expect(throws: ScribeContextError.targetChanged) {
            try await restorationService.insert("Keep available", for: restorationCapture)
        }
        #expect(restorationInsertion.insertedTexts.isEmpty)

        let destroyedReader = StubScribeAccessibilityReader(snapshot: .init(
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            verificationToken: "window-a"
        ))
        let process = ScribeProcessAuthorityFake(pid: 42, bundleID: "com.apple.TextEdit")
        let destroyedInsertion = StubScribeTextInsertionService()
        let destroyedService = ScribeContextService(
            reader: destroyedReader,
            processAuthority: process,
            insertionFocusSettleDelay: .zero,
            textInsertion: destroyedInsertion
        )
        let destroyedCapture = try destroyedService.capture()
        process.matches = false

        await #expect(throws: ScribeContextError.targetChanged) {
            try await destroyedService.insert("Never send", for: destroyedCapture)
        }
        #expect(destroyedInsertion.insertedTexts.isEmpty)
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
    func insertRejectsARebuiltAccessibilityWrapperBeforeRestoration() async throws {
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

        await #expect(throws: ScribeContextError.targetChanged) {
            try await service.insert("Visible draft", for: capture)
        }
        #expect(reader.restoredProcessIdentifiers.isEmpty)
        #expect(textInsertion.insertedTexts.isEmpty)
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
        await #expect(throws: ScribeContextError.unsupportedSelection) {
            try await service.restoreTargetForContextRefresh(capture)
        }
        #expect(monitor.activatedCaptures.isEmpty)
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
        targetCapability: (any DictationTargetCapabilityServing)? = nil,
        textInsertion: TextInsertionServing = StubScribeTextInsertionService(),
        frontmostProcessIdentifier: @escaping @MainActor () -> pid_t? = { nil }
    ) -> ScribeContextService {
        let target = reader.snapshot.target
        return ScribeContextService(
            reader: reader,
            processAuthority: ScribeProcessAuthorityFake(
                pid: target.processIdentifier,
                bundleID: target.bundleIdentifier ?? "com.apple.TextEdit"
            ),
            targetCapability: targetCapability ?? StubScribeTargetCapabilityService(.editable(.standardTextRole)),
            transientControlProcessIdentifier: transientControlProcessIdentifier,
            insertionFocusSettleDelay: insertionFocusSettleDelay,
            focusAcquisitionRetryDelay: .zero,
            textInsertion: textInsertion,
            frontmostProcessIdentifier: frontmostProcessIdentifier
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

private actor PausingScribeTextInsertionService: TextInsertionServing {
    private(set) var insertedTexts: [String] = []
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func insert(_ text: String) async throws {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        insertedTexts.append(text)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func pressReturn() async throws {}
    func deleteLastInsertion() async throws {}
}

@MainActor
private final class StubScribeTargetCapabilityService: DictationTargetCapabilityServing {
    var assessment: DictationTargetCapabilityAssessment

    init(_ assessment: DictationTargetCapabilityAssessment) {
        self.assessment = assessment
    }

    func assessFocusedElement(for _: ApplicationTargetCapture) -> DictationTargetCapabilityAssessment {
        assessment
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
    var restoredSnapshotOverride: ScribeAccessibilityReadSnapshot?
    var restoreError: ScribeContextError?
    var pinError: ScribeContextError?
    var pinFailuresRemaining = 0
    private(set) var pinAttemptCount = 0
    var pinnedReadError: ScribeContextError?
    var currentFocusError: ScribeContextError?
    private(set) var pinnedReadCount = 0
    private(set) var currentFocusReadCount = 0
    var pinnedWindowFrame: CGRect?
    private(set) var windowFrameReadCount = 0
    private(set) var restoredProcessIdentifiers: [pid_t] = []

    init(snapshot: ScribeAccessibilityReadSnapshot, isTrusted: Bool = true) {
        self.snapshot = snapshot
        self.isTrusted = isTrusted
    }

    func pinFocusedTarget() throws {
        pinAttemptCount += 1
        if pinFailuresRemaining > 0 {
            pinFailuresRemaining -= 1
            throw ScribeContextError.noFocusedTarget
        }
        if let pinError { throw pinError }
    }

    func readPinnedSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        pinnedReadCount += 1
        if let pinnedReadError { throw pinnedReadError }
        return snapshot
    }

    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        currentFocusReadCount += 1
        if let currentFocusError { throw currentFocusError }
        return currentSnapshot ?? snapshot
    }

    func readPinnedWindowFrame() -> CGRect? {
        windowFrameReadCount += 1
        return pinnedWindowFrame
    }

    func restorePinnedTargetFocus(processIdentifier: pid_t) throws {
        if let restoreError { throw restoreError }
        restoredProcessIdentifiers.append(processIdentifier)
        if let restoredSnapshotOverride {
            currentSnapshot = restoredSnapshotOverride
        } else if let restoredTargetOverride {
            currentSnapshot = ScribeAccessibilityReadSnapshot(
                target: restoredTargetOverride,
                verificationToken: "restored-wrapper"
            )
        } else {
            currentSnapshot = snapshot
        }
    }

    func clearPinnedTarget() {}
}
