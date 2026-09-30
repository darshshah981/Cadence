import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeContentCaptureTests {
    @Test
    func disabledDefaultsPerformZeroReaderCalls() async {
        let fixture = Fixture()
        let service = ComposeContentCaptureService(reader: fixture.reader)
        #expect(await service.captureSelectedText(from: fixture.target) == .unavailable(.policy(.disabled)))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func OSAccessibilityWithoutCaptureGrantPerformsZeroReaderCalls() async {
        let fixture = Fixture()
        fixture.policy.captureGrants = []
        #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.policy(.missingCaptureGrant)))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func securePrivateUnsupportedAndExcludedTargetsPerformZeroReaderCalls() async {
        for eligibility in [ScribeContextSurfaceEligibility.secure, .privateSurface, .unsupported] {
            let fixture = Fixture(eligibility: eligibility)
            #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.policy(.ineligibleSurface)))
            #expect(await fixture.reader.readCount == 0)
        }
        let fixture = Fixture()
        fixture.policy.excludedScopes = [.application(bundleIdentifier: "test.cadence.context")]
        #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.policy(.excludedScope)))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func immutableTargetMismatchBeforeCapturePerformsZeroReaderCalls() async {
        let fixture = Fixture()
        fixture.currentTarget = nil
        #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.targetChanged))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func sourceFromAnotherInvocationPerformsZeroReaderCalls() async {
        let fixture = Fixture()
        let source = fixture.target.source
        let mismatched = ComposeContentCaptureTarget(action: fixture.target.action, source: .init(
            captureID: UUID(), target: source.target, process: source.process,
            verificationToken: source.verificationToken, recognitionSignature: source.recognitionSignature
        ))
        fixture.currentTarget = mismatched
        #expect(await fixture.service.captureSelectedText(from: mismatched) == .unavailable(.targetChanged))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func unicodeMultilineAndWhitespaceArePreservedByteForByte() async throws {
        let text = "  Cafe\u{301} 👩🏽‍💻\n第二行\t\r\n"
        let fixture = Fixture(text: text, location: 7)
        guard case .captured(let snapshot) = await fixture.service.captureSelectedText(from: fixture.target) else {
            Issue.record("Expected an exact selected-text snapshot")
            return
        }
        #expect(Data(snapshot.selectedText.utf8) == Data(text.utf8))
        #expect(snapshot.selectedRange == .init(location: 7, length: text.utf16.count))
        #expect(snapshot.completeness == .completeSelectedRange)
        #expect(snapshot.target == fixture.target)
        #expect(snapshot.capturedAt == fixture.now)
        #expect(snapshot.authorization.request.operation == .capture(.selectedText))
    }

    @Test
    func exactByteBudgetAcceptsBoundaryAndRejectsOverageWithoutTruncation() async {
        let fixture = Fixture(text: "éé")
        var budget = ComposeContentCaptureBudget()
        budget.maximumUTF8Bytes = 4
        guard case .captured = await fixture.service.captureSelectedText(from: fixture.target, budget: budget) else {
            Issue.record("Expected exact byte boundary to pass")
            return
        }
        budget.maximumUTF8Bytes = 3
        #expect(await fixture.service.captureSelectedText(from: fixture.target, budget: budget) == .unavailable(.contextTooLarge))
    }

    @Test
    func invalidBudgetsPerformZeroReaderCalls() async {
        let fixture = Fixture()
        var byteBudget = ComposeContentCaptureBudget()
        byteBudget.maximumUTF8Bytes = 0
        var timeBudget = ComposeContentCaptureBudget()
        timeBudget.timeoutMilliseconds = 1_001
        var nodeBudget = ComposeContentCaptureBudget()
        nodeBudget.maximumMetadataNodes = 0
        for budget in [byteBudget, timeBudget, nodeBudget] {
            #expect(await fixture.service.captureSelectedText(from: fixture.target, budget: budget) == .unavailable(.invalidBudget))
        }
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func malformedRangesAndUTF16MismatchDoNotProduceSnapshots() async {
        let fixture = Fixture(text: "👩🏽‍💻")
        for range in [
            ComposeSelectedTextRange(location: -1, length: 7),
            .init(location: Int.max, length: 1),
            .init(location: 0, length: 1)
        ] {
            await fixture.reader.setResult(.success(fixture.read(rangeBefore: range, rangeAfter: range)))
            #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.invalidSelection))
        }
    }

    @Test
    func emptySelectionAndUnsupportedControlsAreTypedFailures() async {
        let empty = Fixture(text: "")
        #expect(await empty.service.captureSelectedText(from: empty.target) == .unavailable(.noSelection))
        let control = Fixture(text: "hello\0world")
        #expect(await control.service.captureSelectedText(from: control.target) == .unavailable(.invalidContent))
    }

    @Test
    func rangeChangesDuringReadDiscardReturnedContent() async {
        let fixture = Fixture()
        await fixture.reader.setResult(.success(fixture.read(rangeAfter: .init(location: 1, length: fixture.text.utf16.count))))
        #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.selectionChanged))
    }

    @Test
    func changedFieldWindowOrProcessMetadataDiscardsReturnedContent() async {
        let fixture = Fixture()
        let original = fixture.target.source
        let changed = ComposeContentSourceIdentity(
            captureID: original.captureID, target: original.target, process: original.process,
            verificationToken: "different-window-or-field", recognitionSignature: original.recognitionSignature
        )
        let replacedProcess = ApplicationProcessIdentity(
            processIdentifier: original.process.processIdentifier,
            bundleIdentifier: original.process.bundleIdentifier, bundleURL: original.process.bundleURL,
            incarnation: UUID(), launchDate: original.process.launchDate
        )
        let changedProcess = ComposeContentSourceIdentity(
            captureID: original.captureID, target: original.target, process: replacedProcess,
            verificationToken: original.verificationToken, recognitionSignature: original.recognitionSignature
        )
        for identity in [changed, changedProcess] {
            await fixture.reader.setResult(.success(fixture.read(identityAfter: identity)))
            #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.targetChanged))
        }
    }

    @Test
    func revocationDuringAsyncReadDiscardsResult() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        let pending = Task { await fixture.service.captureSelectedText(from: fixture.target) }
        await fixture.reader.waitForRead()
        fixture.policy.revokedGrantIDs.insert(fixture.policy.captureGrants[0].id)
        await fixture.reader.resolvePending()
        #expect(await pending.value == .unavailable(.policy(.missingCaptureGrant)))
    }

    @Test
    func permissionLossDuringAsyncReadDiscardsResult() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        let pending = Task { await fixture.service.captureSelectedText(from: fixture.target) }
        await fixture.reader.waitForRead()
        fixture.permissions.accessibility = false
        await fixture.reader.resolvePending()
        #expect(await pending.value == .unavailable(.policy(.missingPlatformPermission)))
    }

    @Test
    func actionChangeDuringAsyncReadDiscardsResult() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        let pending = Task { await fixture.service.captureSelectedText(from: fixture.target) }
        await fixture.reader.waitForRead()
        fixture.currentTarget = nil
        await fixture.reader.resolvePending()
        #expect(await pending.value == .unavailable(.targetChanged))
    }

    @Test
    func elapsedBudgetUsesMonotonicClockAndRejectsLateValue() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        let pending = Task { await fixture.service.captureSelectedText(from: fixture.target) }
        await fixture.reader.waitForRead()
        fixture.clock.set(201_000_000)
        await fixture.reader.resolvePending()
        #expect(await pending.value == .unavailable(.timedOut))
    }

    @Test
    func timeoutReturnsWithoutWaitingForAnUncooperativeReader() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        var budget = ComposeContentCaptureBudget()
        budget.timeoutMilliseconds = 30
        budget.attributeTimeoutMilliseconds = 10
        #expect(await fixture.service.captureSelectedText(from: fixture.target, budget: budget) == .unavailable(.timedOut))
        await fixture.reader.resolvePending()
    }

    @Test
    func cancellationReturnsWithoutWaitingAndDropsLateRead() async {
        let fixture = Fixture()
        await fixture.reader.suspendNextRead()
        let pending = Task { await fixture.service.captureSelectedText(from: fixture.target) }
        await fixture.reader.waitForRead()
        pending.cancel()
        #expect(await pending.value == .unavailable(.cancelled))
        await fixture.reader.resolvePending()
    }

    @Test
    func alreadyCancelledActionPerformsZeroReaderCalls() async {
        let fixture = Fixture()
        let pending = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.service.captureSelectedText(from: fixture.target)
        }
        #expect(await pending.value == .unavailable(.cancelled))
        #expect(await fixture.reader.readCount == 0)
    }

    @Test
    func readerFailuresStayTypedAndUnknownErrorsLoseTheirMessage() async {
        let fixture = Fixture()
        for failure in [ComposeContentCaptureFailure.unsupportedAttribute, .metadataBudgetExceeded, .secureField] {
            await fixture.reader.setResult(.failure(failure))
            #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(failure))
        }
        await fixture.reader.setResult(.failure(NSError(domain: "private-canary", code: 1)))
        #expect(await fixture.service.captureSelectedText(from: fixture.target) == .unavailable(.readFailed))
    }

    @Test
    func laterSelectedTextChangeInvalidatesReplacementVerification() async {
        let fixture = Fixture(text: "one")
        guard case .captured(let snapshot) = await fixture.service.captureSelectedText(from: fixture.target) else {
            Issue.record("Expected initial capture")
            return
        }
        #expect(await fixture.service.revalidateSelectedText(snapshot) == .current)
        await fixture.reader.setResult(.success(fixture.read(text: "two")))
        #expect(await fixture.service.revalidateSelectedText(snapshot) == .unavailable(.selectionChanged))
    }

    @Test
    func replacementVerificationUsesExactUnicodeBytes() async {
        let fixture = Fixture(text: "a\u{301}\u{323}")
        guard case .captured(let snapshot) = await fixture.service.captureSelectedText(from: fixture.target) else {
            Issue.record("Expected initial capture")
            return
        }
        let reordered = "a\u{323}\u{301}"
        #expect(fixture.text == reordered)
        #expect(fixture.text.utf16.count == reordered.utf16.count)
        #expect(Data(fixture.text.utf8) != Data(reordered.utf8))
        await fixture.reader.setResult(.success(fixture.read(text: reordered)))
        #expect(await fixture.service.revalidateSelectedText(snapshot) == .unavailable(.selectionChanged))
    }

    @Test
    func revokedSnapshotCannotTriggerAnotherReadForReplacement() async {
        let fixture = Fixture()
        guard case .captured(let snapshot) = await fixture.service.captureSelectedText(from: fixture.target) else {
            Issue.record("Expected initial capture")
            return
        }
        fixture.policy.revision = UUID()
        #expect(await fixture.service.revalidateSelectedText(snapshot) == .unavailable(.policy(.policyChanged)))
        #expect(await fixture.reader.readCount == 1)
    }

    @MainActor
    private final class Fixture {
        let now = Date(timeIntervalSince1970: 10_000)
        let target: ComposeContentCaptureTarget
        let text: String
        let range: ComposeSelectedTextRange
        let reader: FakeReader
        let clock = TestClock()
        var currentTarget: ComposeContentCaptureTarget?
        var policy: ScribeContextPolicySnapshot
        var permissions = ScribeContextPlatformPermissions(accessibility: true)

        lazy var service = ComposeContentCaptureService(
            reader: reader, policy: { [unowned self] in self.policy }, permissions: { [unowned self] in self.permissions },
            currentTarget: { [unowned self] in self.currentTarget }, now: { [unowned self] in self.now }, uptimeNanoseconds: { [clock] in clock.now }
        )

        init(text: String = "Selected text", location: Int = 0, eligibility: ScribeContextSurfaceEligibility = .eligible) {
            self.text = text
            range = .init(location: location, length: text.utf16.count)
            let identity = ScribeTargetIdentity(processIdentifier: 123, bundleIdentifier: "test.cadence.context")
            let action = ScribeContextActionBinding(actionID: UUID(), captureID: UUID(), target: identity, opaqueSurfaceID: "thread-a", eligibility: eligibility)
            let process = ApplicationProcessIdentity(processIdentifier: 123, bundleIdentifier: "test.cadence.context", bundleURL: URL(fileURLWithPath: "/tmp/Synthetic.app"), incarnation: UUID(), launchDate: now - 10)
            let source = ComposeContentSourceIdentity(captureID: action.captureID, target: identity, process: process, verificationToken: "synthetic-window-and-element", recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []))
            target = .init(action: action, source: source)
            currentTarget = target
            reader = FakeReader(result: .success(.init(identityBefore: source, identityAfter: source, rangeBefore: range, rangeAfter: range, text: text)))
            policy = .init()
            policy.isEnabled = true
            policy.captureGrants = [.init(id: UUID(), scope: .application(bundleIdentifier: "test.cadence.context"), categories: [.selectedText], window: .init(acceptedAt: now - 1, expiresAt: now + 120))]
        }

        func read(
            text: String? = nil,
            identityAfter: ComposeContentSourceIdentity? = nil,
            rangeBefore: ComposeSelectedTextRange? = nil,
            rangeAfter: ComposeSelectedTextRange? = nil
        ) -> ComposeSelectedTextRead {
            .init(identityBefore: target.source, identityAfter: identityAfter ?? target.source, rangeBefore: rangeBefore ?? range, rangeAfter: rangeAfter ?? range, text: text ?? self.text)
        }
    }

    private actor FakeReader: ComposeSelectedTextReading {
        private(set) var readCount = 0
        private var result: Result<ComposeSelectedTextRead, any Error>
        private var shouldSuspend = false
        private var pending: CheckedContinuation<ComposeSelectedTextRead, any Error>?
        private var observer: CheckedContinuation<Void, Never>?

        init(result: Result<ComposeSelectedTextRead, any Error>) { self.result = result }

        func readSelectedText(from _: ComposeContentCaptureTarget, budget _: ComposeContentCaptureBudget) async throws -> ComposeSelectedTextRead {
            readCount += 1
            observer?.resume()
            observer = nil
            if shouldSuspend {
                shouldSuspend = false
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return try result.get()
        }

        func setResult(_ result: Result<ComposeSelectedTextRead, any Error>) { self.result = result }
        func suspendNextRead() { shouldSuspend = true }
        func waitForRead() async {
            if readCount > 0 { return }
            await withCheckedContinuation { observer = $0 }
        }
        func resolvePending() {
            pending?.resume(with: result)
            pending = nil
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        var now: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ value: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            self.value = value
        }
    }
}
