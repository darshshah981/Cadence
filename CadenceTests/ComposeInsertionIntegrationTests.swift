import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Testing
@testable import Cadence

/// Opt-in platform evidence. No model, microphone, clipboard, or user editor.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CADENCE_COMPOSE_INSERTION_INTEGRATION"] == "1"), .serialized)
@MainActor
struct ComposeInsertionIntegrationTests {
    @Test
    func productionInsertionAgainstControlledSyntheticHost() async {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["CADENCE_COMPOSE_INSERTION_REPORT"],
              reportPath.hasPrefix("/") else {
            Issue.record("Integration requires an absolute evidence report path")
            return
        }
        let report = InsertionIntegrationReport(url: URL(fileURLWithPath: reportPath))
        report.save(status: "preflight")
        // This is the actual test-host process. A grant to another installed
        // Cadence build, xcodebuild, or Terminal cannot stand in for this check.
        guard AXIsProcessTrusted() else {
            report.save(status: "blocked_permission")
            Issue.record("Controlled insertion blocked: actual test process lacks Accessibility trust")
            return
        }
        guard let appPath = environment["CADENCE_COMPOSE_TEST_HOST_APP"],
              let runPath = environment["CADENCE_COMPOSE_TEST_HOST_RUN"],
              appPath.hasPrefix("/"), runPath.hasPrefix("/") else {
            report.save(status: "blocked_configuration")
            Issue.record("Controlled insertion requires explicit synthetic host paths")
            return
        }
        var host: SyntheticInsertionHost?
        var otherHost: SyntheticInsertionHost?
        var externalEditor: NSRunningApplication?
        defer {
            externalEditor?.terminate()
            otherHost?.terminateOwnedApplication()
            host?.terminateOwnedApplication()
        }
        do {
            let controller = try SyntheticInsertionHost(
                appURL: URL(fileURLWithPath: appPath),
                directory: URL(fileURLWithPath: runPath, isDirectory: true)
            )
            host = controller
            try await controller.launch()
            report.hostBinarySHA256 = try controller.binaryHash()
            report.hostProcessIdentifier = controller.processIdentifier
            report.hostInstanceID = controller.instanceID

            let insertionCases: [(String, String, String)] = [
                ("native-field-one-copy", "native-field", "short"),
                ("native-editor-multiline", "native-editor", "multiline"),
                ("native-editor-unicode", "native-editor", "unicode"),
                ("web-textarea-one-copy", "web-textarea", "short"),
                ("web-textarea-unicode", "web-textarea", "unicode"),
                ("web-contenteditable-one-copy", "web-contenteditable", "short"),
                ("cursor-button-unknown-insertion", "web-cursor-button", "short")
            ]
            for (id, target, fixture) in insertionCases {
                await report.record(id) {
                    try await controller.resetAndFocus(target)
                    let insertion = SyntheticHostBoundInsertion(host: controller)
                    let service = Self.context(insertion: insertion)
                    try await Self.stage("prepare") { try await service.prepareTarget() }
                    let capture = try await Self.stage("capture") { try service.capture() }
                    defer { service.clear(capture) }
                    try controller.requireCapturedHost(capture)
                    let assessment = SystemDictationTargetCapabilityService()
                        .assessFocusedElement(for: capture.applicationTarget)
                    if target == "web-cursor-button" {
                        guard assessment == .unknown(.webTextCursorHint) else {
                            throw SyntheticIntegrationFailure.cursorHintNotExposed
                        }
                    } else {
                        guard !assessment.isDefinitelyNotEditable else {
                            throw SyntheticIntegrationFailure.editableTargetRejected
                        }
                    }
                    let verified = try await Self.stage("verify") { try service.verifyTarget(for: capture) }
                    guard verified else {
                        throw SyntheticIntegrationFailure.targetVerificationFailed
                    }
                    let inserted = try await Self.stage("insert") {
                        try await service.insert(SyntheticInsertionHost.fixtures[fixture]!, for: capture)
                    }
                    guard inserted,
                          insertion.realInsertionCallCount == 1 else {
                        throw SyntheticIntegrationFailure.insertionNotAttemptedOnce
                    }
                    try await controller.requireExactInsertion(target: target, fixture: fixture)
                }
            }
            await report.record("repeat-successful-insert-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)
                guard try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture) else {
                    throw SyntheticIntegrationFailure.insertionNotAttemptedOnce
                }
                do {
                    _ = try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture)
                    throw SyntheticIntegrationFailure.duplicateInsertionAccepted
                } catch ScribeContextError.insertionUnconfirmed {}
                guard insertion.realInsertionCallCount == 1 else {
                    throw SyntheticIntegrationFailure.duplicateInsertionAccepted
                }
                try await controller.requireExactInsertion(target: "native-field", fixture: "short")
            }
            for target in ["native-button", "web-button", "native-secure"] {
                await report.record("refuse-\(target)") {
                    try await controller.resetAndFocus(target)
                    let insertion = SyntheticHostBoundInsertion(host: controller)
                    let service = Self.context(insertion: insertion)
                    defer { service.discardPreparedTarget() }
                    var refused = false
                    do {
                        try await service.prepareTarget()
                        let capture = try service.capture()
                        try controller.requireCapturedHost(capture)
                        refused = !(try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture))
                    } catch let error as ScribeContextError {
                        refused = target == "native-secure" ? error == .secureField : error == .unsupportedSelection
                    }
                    guard refused, insertion.realInsertionCallCount == 0 else {
                        throw SyntheticIntegrationFailure.noneditableTargetNotRefused
                    }
                    try await controller.requireAllEmpty()
                }
            }
            await report.record("changed-field-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)
                _ = try await controller.command("focus", target: "native-editor")
                try await controller.requireFrontmostHost()
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion)
                try await controller.requireAllEmpty()
            }
            await report.record("other-process-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)

                let other = try SyntheticInsertionHost(
                    appURL: URL(fileURLWithPath: appPath),
                    directory: URL(fileURLWithPath: runPath + "-other", isDirectory: true)
                )
                otherHost = other
                try await other.launch()
                guard other.processIdentifier != controller.processIdentifier else {
                    throw SyntheticIntegrationFailure.hostIdentityChanged
                }
                report.otherHostProcessIdentifier = other.processIdentifier
                try await other.resetAndFocus("native-field")
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion)
                try await controller.requireAllEmpty()
                try await other.requireAllEmpty()
                other.terminateOwnedApplication()
                try await other.waitTerminated()
                otherHost = nil
            }
            await report.record("different-bundle-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)

                let appURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                let documentURL = URL(fileURLWithPath: runPath + "-external.txt")
                try "Cadence synthetic focus test.\n".write(to: documentURL, atomically: true, encoding: .utf8)
                let previousPIDs = Set(NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.TextEdit"
                ).map(\.processIdentifier))
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = ["-n", "-a", appURL.path, documentURL.path]
                try opener.run()
                opener.waitUntilExit()
                guard opener.terminationStatus == 0 else {
                    throw SyntheticIntegrationFailure.externalAppNotReady
                }
                for _ in 0..<80 {
                    externalEditor = NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.TextEdit"
                    ).first {
                        !previousPIDs.contains($0.processIdentifier)
                            && $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
                    }
                    if externalEditor != nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let externalEditor else {
                    throw SyntheticIntegrationFailure.externalAppNotReady
                }
                _ = externalEditor.activate(options: [.activateIgnoringOtherApps])
                for _ in 0..<80 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == externalEditor.processIdentifier { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == externalEditor.processIdentifier else {
                    throw SyntheticIntegrationFailure.unexpectedForegroundApplication
                }
                report.externalEditorProcessIdentifier = externalEditor.processIdentifier
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion)
                try await controller.requireAllEmpty()
                externalEditor.terminate()
            }
            await report.record("recreated-window-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)
                let priorGeneration = controller.windowGeneration
                _ = try await controller.command("close-window")
                _ = try await controller.command("reopen-window")
                try await controller.waitReady()
                try await controller.resetAndFocus("native-field")
                guard controller.windowGeneration > priorGeneration else {
                    throw SyntheticIntegrationFailure.windowDidNotChange
                }
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion)
                try await controller.requireAllEmpty()
            }
            await report.record("cleared-capture-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                try controller.requireCapturedHost(capture)
                service.clear(capture)
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion,
                                                        expectedError: .captureCleared)
                try await controller.requireAllEmpty()
            }
            await report.record("partial-event-reported-unconfirmed") {
                try await controller.resetAndFocus("native-field")
                let production = TextInsertionService(unicodePosterFactory: {
                    try StopAfterOneUnicodeScalarPoster()
                })
                let insertion = SyntheticHostBoundInsertion(host: controller, production: production)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)
                do {
                    _ = try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture)
                    throw SyntheticIntegrationFailure.partialEventNotReported
                } catch GuardedTextInsertionError.uncertainPartialInsertion {
                    // The host must still observe exactly the one posted prefix.
                }
                do {
                    _ = try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture)
                    throw SyntheticIntegrationFailure.duplicateInsertionAccepted
                } catch ScribeContextError.insertionUnconfirmed {}
                guard insertion.realInsertionCallCount == 1 else {
                    throw SyntheticIntegrationFailure.insertionNotAttemptedOnce
                }
                try await controller.requireExactInsertion(target: "native-field", fixture: "partial-prefix")
            }
            await report.record("terminated-process-refused") {
                try await controller.resetAndFocus("native-field")
                let insertion = SyntheticHostBoundInsertion(host: controller)
                let service = Self.context(insertion: insertion)
                try await service.prepareTarget()
                let capture = try service.capture()
                defer { service.clear(capture) }
                try controller.requireCapturedHost(capture)
                try await controller.requireAllEmpty()
                _ = try await controller.command("quit")
                try await controller.waitTerminated()
                // The wrapper must not be invoked here. If production reaches
                // it, its boundary error fails this case before any CGEvents.
                try await Self.requireProductionRefusal(service, capture: capture, insertion: insertion)
            }
            report.save(status: report.failures == 0 ? "passed" : "failed")
        } catch {
            report.save(status: "failed_setup")
            Issue.record("Controlled insertion host setup failed; no insertion result claimed")
        }
    }

    private static func context(insertion: TextInsertionServing) -> ScribeContextService {
        ScribeContextService(
            reader: SystemScribeAccessibilityReader(),
            processAuthority: RuntimeApplicationProcessAuthority(),
            textInsertion: insertion
        )
    }

    private static func requireProductionRefusal(
        _ service: ScribeContextService,
        capture: ScribeContextSnapshot,
        insertion: SyntheticHostBoundInsertion,
        expectedError: ScribeContextError = .targetChanged
    ) async throws {
        var refused = false
        var contextError: ScribeContextError?
        do {
            refused = !(try await service.insert(SyntheticInsertionHost.fixtures["short"]!, for: capture))
        } catch let error as ScribeContextError {
            contextError = error
        }
        guard insertion.realInsertionCallCount == 0 else {
            throw SyntheticIntegrationFailure.changedTargetInsertionAttempted
        }
        if let contextError {
            guard contextError == expectedError else { throw contextError }
            return
        }
        guard refused else { throw SyntheticIntegrationFailure.changedTargetAcceptedWithoutInsertion }
    }

    private static func stage<T>(_ name: String, _ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw SyntheticIntegrationStageFailure(stage: name, underlying: error) }
    }
}

private struct SyntheticIntegrationStageFailure: Error {
    let stage: String
    let underlying: Error
}

private enum SyntheticIntegrationFailure: String, Error {
    case invalidConfiguration, hostNotReady, invalidAcknowledgement, hostIdentityChanged
    case unexpectedForegroundApplication, windowDidNotChange, targetVerificationFailed
    case cursorHintNotExposed, editableTargetRejected, insertionNotAttemptedOnce
    case valueMismatch, noneditableTargetNotRefused, changedTargetInsertionAttempted
    case changedTargetAcceptedWithoutInsertion
    case partialEventNotReported, duplicateInsertionAccepted
    case harnessBoundaryIntervened, unexpectedReturn, processStillRunning
    case externalAppNotReady
}

@MainActor
private final class InsertionIntegrationReport {
    private let url: URL
    private var rows: [[String: String]] = []
    var hostBinarySHA256: String?
    var hostProcessIdentifier: Int32?
    var hostInstanceID: String?
    var otherHostProcessIdentifier: Int32?
    var externalEditorProcessIdentifier: Int32?
    var failures: Int { rows.filter { $0["status"] != "passed" }.count }

    init(url: URL) { self.url = url }

    func record(_ id: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            rows.append(["id": id, "status": "passed"])
        } catch {
            let stageFailure = error as? SyntheticIntegrationStageFailure
            let underlying = stageFailure?.underlying ?? error
            let reason: String
            if let failure = underlying as? SyntheticIntegrationFailure {
                reason = failure.rawValue
            } else if let context = underlying as? ScribeContextError {
                reason = "context_\(context.rawValue)"
            } else {
                // Never serialize a platform error description: it may carry
                // focused UI content. A type name is enough to locate the
                // failing boundary without retaining any editor value.
                reason = "platform_\(String(reflecting: type(of: underlying)))"
            }
            var row = ["id": id, "status": "failed", "reason": reason]
            if let stageFailure { row["stage"] = stageFailure.stage }
            rows.append(row)
            Issue.record("Synthetic insertion case \(id) failed: \(reason)")
        }
        save(status: "running")
    }

    func save(status: String) {
        var value: [String: Any] = [
            "schemaVersion": 1, "syntheticOnly": true, "status": status,
            "productionServices": ["ScribeContextService", "SystemScribeAccessibilityReader", "RuntimeApplicationProcessAuthority", "TextInsertionService"],
            "accessibilityTrustedInActualTestProcess": AXIsProcessTrusted(),
            "testProcessID": ProcessInfo.processInfo.processIdentifier,
            "testExecutablePath": Bundle.main.executableURL?.path ?? "unavailable",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "expectedCaseCount": 18, "completedCaseCount": rows.count,
            "passedCaseCount": rows.count - failures, "failedCaseCount": failures,
            "cases": rows,
            "limitations": ["The cross-bundle focus switch uses a new system editor instance with a synthetic document; no user document is read or certified.", "Does not exercise clipboard failure or a naturally occurring partial CGEvent failure.", "A dead process is tested; OS PID reuse is not forced."]
        ]
        if let hostBinarySHA256 { value["hostBinarySHA256"] = hostBinarySHA256 }
        if let hostProcessIdentifier { value["hostProcessID"] = hostProcessIdentifier }
        if let hostInstanceID { value["hostInstanceID"] = hostInstanceID }
        if let otherHostProcessIdentifier { value["otherHostProcessID"] = otherHostProcessIdentifier }
        if let externalEditorProcessIdentifier { value["externalEditorProcessID"] = externalEditorProcessIdentifier }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Issue.record("Could not persist integration evidence")
        }
    }
}

private struct SyntheticHostState: Decodable {
    struct Field: Decodable {
        let isEmpty: Bool
        let utf16Length: Int
        let redacted: Bool
        let containsOnlySyntheticFixtures: Bool
        let sha256: String?
    }
    let schemaVersion: Int
    let syntheticOnly: Bool
    let commandID: String?
    let instanceID: String
    let processID: Int32
    let status: String
    let webReady: Bool
    let windowVisible: Bool
    let windowGeneration: Int
    let nativeFocusedID: String
    let webFocusedID: String
    let webDocumentFocused: Bool
    let fields: [String: Field]
    let nativeFieldReturnCount: Int
    let nativeEditorReturnCount: Int
    let secureFieldReturnCount: Int
    let webReturnCounts: [String: Int]
}

@MainActor
private final class SyntheticInsertionHost {
    static let bundleID = "com.darshshah.Cadence.compose-test-host"
    static let fixtures = ["short": "SYNTHETIC alpha 314.", "unicode": "SYNTHETIC café 🌿 東京.",
                           "multiline": "SYNTHETIC first line.\nSYNTHETIC second line.",
                           "partial-prefix": "S"]
    private let appURL: URL
    private let directory: URL
    private var application: NSRunningApplication?
    private(set) var instanceID: String?
    private(set) var windowGeneration = 0
    var processIdentifier: Int32? { application?.processIdentifier }

    init(appURL: URL, directory: URL) throws {
        self.appURL = appURL.standardizedFileURL.resolvingSymlinksInPath()
        self.directory = directory.standardizedFileURL
        guard Bundle(url: self.appURL)?.bundleIdentifier == Self.bundleID,
              !FileManager.default.fileExists(atPath: directory.path) else {
            throw SyntheticIntegrationFailure.invalidConfiguration
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func binaryHash() throws -> String {
        let executable = appURL.appendingPathComponent("Contents/MacOS/ComposeTestHost")
        return SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
    }

    func launch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--control-directory", directory.path]
        configuration.createsNewApplicationInstance = true
        application = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try requireOwnedProcess()
        try await waitReady()
    }

    func terminateOwnedApplication() {
        guard let application, !application.isTerminated,
              application.bundleIdentifier == Self.bundleID,
              application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == appURL else { return }
        application.terminate()
    }

    func waitTerminated() async throws {
        for _ in 0..<100 {
            if application?.isTerminated == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.processStillRunning
    }

    func waitReady() async throws {
        for _ in 0..<200 {
            if let state = try? readState(), state.webReady && state.windowVisible {
                try bind(state)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.hostNotReady
    }

    func command(_ action: String, target: String? = nil) async throws -> SyntheticHostState {
        try requireOwnedProcess()
        let id = UUID().uuidString
        var command: [String: Any] = ["schemaVersion": 1, "id": id, "action": action]
        if let target { command["target"] = target }
        let data = try JSONSerialization.data(withJSONObject: command)
        try data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<200 {
            if let state = try? readState(), state.commandID == id {
                try bind(state)
                guard ["ok", "ready", "loading"].contains(state.status) else {
                    throw SyntheticIntegrationFailure.invalidAcknowledgement
                }
                return state
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.invalidAcknowledgement
    }

    func resetAndFocus(_ target: String) async throws {
        _ = try await command("reset")
        _ = try await command("focus", target: target)
        // The host may acknowledge focus while Launch Services leaves another
        // app foreground. Request activation from this owned process handle too;
        // requireFrontmostHost still refuses the case if macOS does not switch.
        _ = application?.activate()
        try await requireFrontmostHost()
        for _ in 0..<40 {
            let state = try await command("snapshot")
            let matches = target.hasPrefix("web-")
                ? state.webFocusedID == target && state.webDocumentFocused
                : state.nativeFocusedID == target
            if matches { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.targetVerificationFailed
    }

    func requireFrontmostHost() async throws {
        for _ in 0..<40 {
            try requireOwnedProcess()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application?.processIdentifier { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.unexpectedForegroundApplication
    }

    func requireCapturedHost(_ capture: ScribeContextSnapshot) throws {
        try requireOwnedProcess()
        guard capture.target.processIdentifier == application?.processIdentifier,
              capture.applicationTarget.process.bundleIdentifier == Self.bundleID,
              capture.applicationTarget.process.bundleURL == appURL else {
            throw SyntheticIntegrationFailure.hostIdentityChanged
        }
    }

    func validateFinalEventBoundary(expectedGeneration: Int) async throws {
        try requireOwnedProcess()
        let state = try await command("snapshot")
        guard state.windowVisible, state.windowGeneration == expectedGeneration,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application?.processIdentifier else {
            throw SyntheticIntegrationFailure.harnessBoundaryIntervened
        }
    }

    func requireExactInsertion(target: String, fixture: String) async throws {
        // CGEvents are asynchronous. Poll observations for a bounded interval;
        // then take one additional snapshot to detect queued duplicate events.
        for _ in 0..<60 {
            let state = try await command("snapshot")
            if matches(state, target: target, value: Self.fixtures[fixture]!) {
                try await Task.sleep(for: .milliseconds(150))
                let settled = try await command("snapshot")
                guard matches(settled, target: target, value: Self.fixtures[fixture]!) else {
                    throw SyntheticIntegrationFailure.valueMismatch
                }
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SyntheticIntegrationFailure.valueMismatch
    }

    func requireAllEmpty() async throws {
        let state = try await command("snapshot")
        guard state.fields.count == 6,
              state.fields.values.allSatisfy({ $0.isEmpty && $0.utf16Length == 0 }),
              noReturn(state) else { throw SyntheticIntegrationFailure.valueMismatch }
    }

    private func matches(_ state: SyntheticHostState, target: String, value: String) -> Bool {
        let hash = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        guard state.fields.count == 6, let field = state.fields[target],
              field.sha256 == hash, !field.redacted, field.containsOnlySyntheticFixtures,
              state.fields.filter({ $0.key != target }).allSatisfy({ $0.value.isEmpty && $0.value.utf16Length == 0 })
        else { return false }
        // Newlines inside a multiline Unicode insertion may be represented by
        // the editor as Return. Zero Return is required for single-line fixtures.
        return value.contains("\n") || noReturn(state)
    }

    private func noReturn(_ state: SyntheticHostState) -> Bool {
        state.nativeFieldReturnCount == 0 && state.nativeEditorReturnCount == 0
            && state.secureFieldReturnCount == 0 && state.webReturnCounts.values.allSatisfy { $0 == 0 }
    }

    private func readState() throws -> SyntheticHostState {
        let path = directory.appendingPathComponent("state.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 1_048_576 else {
            throw SyntheticIntegrationFailure.invalidAcknowledgement
        }
        return try JSONDecoder().decode(SyntheticHostState.self, from: Data(contentsOf: path))
    }

    private func bind(_ state: SyntheticHostState) throws {
        guard state.schemaVersion == 1, state.syntheticOnly,
              state.processID == application?.processIdentifier,
              instanceID == nil || instanceID == state.instanceID else {
            throw SyntheticIntegrationFailure.hostIdentityChanged
        }
        instanceID = state.instanceID
        windowGeneration = state.windowGeneration
    }

    private func requireOwnedProcess() throws {
        guard let application, !application.isTerminated,
              application.bundleIdentifier == Self.bundleID,
              application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == appURL else {
            throw SyntheticIntegrationFailure.hostIdentityChanged
        }
    }
}

/// A final test-safety boundary around the actual production CGEvent service.
/// Reaching this guard in a refusal case fails the test; it is never evidence
/// that production rejected the target. No inserted text is mocked or replaced.
@MainActor
private final class SyntheticHostBoundInsertion: TextInsertionServing {
    private let host: SyntheticInsertionHost
    private let expectedGeneration: Int
    private let production: TextInsertionServing
    private(set) var realInsertionCallCount = 0

    init(host: SyntheticInsertionHost, production: TextInsertionServing = TextInsertionService()) {
        self.host = host
        self.production = production
        expectedGeneration = host.windowGeneration
    }

    func insert(_ text: String) async throws {
        do { try await host.validateFinalEventBoundary(expectedGeneration: expectedGeneration) }
        catch { throw SyntheticIntegrationFailure.harnessBoundaryIntervened }
        guard SyntheticInsertionHost.fixtures.values.contains(text) else {
            throw SyntheticIntegrationFailure.harnessBoundaryIntervened
        }
        realInsertionCallCount += 1
        try await production.insert(text)
    }

    func pressReturn() async throws { throw SyntheticIntegrationFailure.unexpectedReturn }
    func deleteLastInsertion() async throws { throw SyntheticIntegrationFailure.harnessBoundaryIntervened }
}

private final class StopAfterOneUnicodeScalarPoster: UnicodeScalarEventPosting {
    private let systemPoster: SystemUnicodeScalarEventPoster
    private var posted = false

    init() throws { systemPoster = try SystemUnicodeScalarEventPoster() }

    func post(_ scalar: UInt16) throws {
        guard !posted else { throw CadenceError.eventSourceUnavailable }
        try systemPoster.post(scalar)
        posted = true
    }
}
