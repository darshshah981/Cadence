import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeTextEditDocumentIdentityTests {
    @Test
    func onlyFocusedTextEditDocumentEditorQualifiesForIdentity() {
        func signature(
            _ role: String?, editorOwned: Bool = true,
            windowOwned: Bool = true, focusedWindow: Bool = true
        ) -> ScribeTextEditSurfaceSignature {
            .init(focusedRole: role, editorBelongsToProcess: editorOwned,
                  windowBelongsToProcess: windowOwned, editorWindowIsFocused: focusedWindow)
        }

        #expect(signature("AXTextArea").permitsDocumentIdentity)
        #expect(!signature("AXTextField").permitsDocumentIdentity) // Search field.
        #expect(!signature("AXSearchField").permitsDocumentIdentity)
        #expect(!signature("AXButton").permitsDocumentIdentity) // Navigation control.
        #expect(!signature("AXWebArea").permitsDocumentIdentity) // Changed app surface.
        #expect(!signature(nil).permitsDocumentIdentity)
        #expect(!signature("AXTextArea", editorOwned: false).permitsDocumentIdentity)
        #expect(!signature("AXTextArea", windowOwned: false).permitsDocumentIdentity)
        #expect(!signature("AXTextArea", focusedWindow: false).permitsDocumentIdentity)
    }

    @Test
    func replacedFileQuarantinesItsStillOpenWindow() {
        let original = id("original-file")
        let replacement = id("replacement-file")
        let window = ScribeTextEditWindowIdentityFence(documentID: original)
        #expect(window.accepts(original))
        #expect(!window.accepts(nil))
        #expect(window.accepts(original))

        #expect(!window.accepts(replacement))
        #expect(window.invalidated)
        // Neither the replacement nor a return to the old path identity may
        // revive a window that could still display stale editor contents.
        #expect(!window.accepts(replacement))
        #expect(!window.accepts(original))

        let reopenedWindow = ScribeTextEditWindowIdentityFence(documentID: replacement)
        #expect(reopenedWindow.accepts(replacement))
        #expect(reopenedWindow.navigationRevision != window.navigationRevision)
    }

    @Test
    func savedFilesGetDistinctOpaqueIDsButUnsupportedDocumentsDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("Same title.txt")
        let second = directory.appendingPathComponent("Other.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let firstID = try #require(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: first.absoluteString
        ))
        let secondID = try #require(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: second.absoluteString
        ))
        #expect(firstID != secondID)
        #expect(firstID.rawValue.count == 64)
        #expect(!firstID.rawValue.contains("Same title"))
        #expect(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: directory.appendingPathComponent("Unsaved.txt").absoluteString
        ) == nil)
        #expect(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: directory.absoluteString
        ) == nil)
        #expect(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: "https://example.test/thread/1"
        ) == nil)
        #expect(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: first.absoluteString + "?unexpected=1"
        ) == nil)
    }

    @Test
    func replacingAFileAtTheSamePathDoesNotReuseItsDocumentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("Conversation.txt")
        let oldDocument = directory.appendingPathComponent("Old document.txt")
        try Data("original".utf8).write(to: document)
        let originalID = try #require(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: document.absoluteString
        ))

        // Keep the old inode alive so a replacement at the same URL cannot
        // accidentally stand in for the document captured by an earlier action.
        try FileManager.default.moveItem(at: document, to: oldDocument)
        try Data("replacement".utf8).write(to: document)
        let replacementID = try #require(SystemScribeTextEditDocumentIdentityReader.stableDocumentID(
            documentURLString: document.absoluteString
        ))
        #expect(originalID != replacementID)
    }

    @Test
    func sameDocumentCanReturnAcrossActionsButChangedNavigationCannotRevalidate() throws {
        let process = makeProcess()
        let window = UUID()
        let firstDocument = id("document-a")
        let reader = FixtureTextEditDocumentReader(observation: .init(
            process: process, windowIncarnation: window,
            navigationRevision: UUID(), documentID: firstDocument
        ))
        let adapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 501)
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let firstBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let first = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: firstBinding))
        let secondBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let second = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: secondBinding))
        #expect(first.memoryKey == second.memoryKey)
        #expect(!resolver.revalidate(first, for: secondBinding))

        reader.observation = .init(process: process, windowIncarnation: window,
                                   navigationRevision: UUID(), documentID: id("document-b"))
        #expect(!resolver.revalidate(first, for: firstBinding))
        let thirdBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let third = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: thirdBinding))
        #expect(third.memoryKey != first.memoryKey)

        reader.observation = .init(process: process, windowIncarnation: window,
                                   navigationRevision: UUID(), documentID: firstDocument)
        let returnBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let returned = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: returnBinding))
        #expect(returned.memoryKey == first.memoryKey)
    }

    @Test
    func accountProcessAndWindowCannotBorrowAnotherDocumentBinding() throws {
        let process = makeProcess()
        let reader = FixtureTextEditDocumentReader(observation: .init(
            process: process, windowIncarnation: UUID(),
            navigationRevision: UUID(), documentID: id("document-a")
        ))
        let firstAdapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 501)
        let secondAdapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 502)
        let firstResolver = try ScribeConversationIdentityResolver(adapters: [firstAdapter])
        let secondResolver = try ScribeConversationIdentityResolver(adapters: [secondAdapter])
        let binding = try #require(firstAdapter.captureBinding(actionID: UUID(), process: process))
        let first = try verified(firstResolver.resolve(adapterID: firstAdapter.registration.adapterID, for: binding))
        let second = try verified(secondResolver.resolve(adapterID: secondAdapter.registration.adapterID, for: binding))
        #expect(first.memoryKey != second.memoryKey)
        #expect(firstAdapter.captureBinding(actionID: UUID(), process: makeProcess(bundle: "com.example.Other")) == nil)

        let wrongWindow = ScribeConversationActionBinding(
            actionID: binding.actionID, process: process, windowIncarnation: UUID(),
            tabIncarnation: nil, navigationRevision: binding.navigationRevision
        )
        #expect(firstResolver.resolve(adapterID: firstAdapter.registration.adapterID, for: wrongWindow).durableMemoryKey == nil)
        let wrongProcess = ScribeConversationActionBinding(
            actionID: binding.actionID, process: makeProcess(), windowIncarnation: binding.windowIncarnation,
            tabIncarnation: nil, navigationRevision: binding.navigationRevision
        )
        #expect(firstResolver.resolve(adapterID: firstAdapter.registration.adapterID, for: wrongProcess).durableMemoryKey == nil)
        reader.observation = nil
        #expect(!firstResolver.revalidate(first, for: binding))
    }

    @Test
    func lookalikeBundleCannotClaimSavedTextEditMemory() throws {
        let lookalike = makeProcess(path: "/Applications/Lookalike.app")
        let reader = FixtureTextEditDocumentReader(observation: .init(
            process: lookalike, windowIncarnation: UUID(),
            navigationRevision: UUID(), documentID: id("saved-document")
        ))
        let adapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 501)
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])

        #expect(adapter.captureBinding(actionID: UUID(), process: lookalike) == nil)
        let forgedBinding = ScribeConversationActionBinding(
            actionID: UUID(), process: lookalike, windowIncarnation: UUID(),
            tabIncarnation: nil, navigationRevision: UUID()
        )
        #expect(adapter.evidence(for: forgedBinding) == nil)
        #expect(resolver.resolve(
            adapterID: adapter.registration.adapterID, for: forgedBinding
        ).durableMemoryKey == nil)
    }

    @Test
    func reopenedWindowRecoversDocumentKeyWithoutRevivingOldActionBinding() throws {
        let process = makeProcess()
        let documentID = id("saved-document")
        let reader = FixtureTextEditDocumentReader(observation: .init(
            process: process, windowIncarnation: UUID(),
            navigationRevision: UUID(), documentID: documentID
        ))
        let adapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 501)
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let oldBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let oldIdentity = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: oldBinding))

        reader.observation = nil
        #expect(!resolver.revalidate(oldIdentity, for: oldBinding))
        reader.observation = .init(process: process, windowIncarnation: UUID(),
                                   navigationRevision: UUID(), documentID: documentID)
        let reopenedBinding = try #require(adapter.captureBinding(actionID: UUID(), process: process))
        let reopenedIdentity = try verified(resolver.resolve(
            adapterID: adapter.registration.adapterID, for: reopenedBinding
        ))
        #expect(reopenedIdentity.memoryKey == oldIdentity.memoryKey)
        #expect(!resolver.revalidate(oldIdentity, for: reopenedBinding))
        #expect(!resolver.revalidate(oldIdentity, for: oldBinding))
    }

    @Test
    func processRestartRecoversOnlyTheSavedDocumentKey() throws {
        let firstProcess = makeProcess()
        let documentID = id("saved-document")
        let reader = FixtureTextEditDocumentReader(observation: .init(
            process: firstProcess, windowIncarnation: UUID(),
            navigationRevision: UUID(), documentID: documentID
        ))
        let adapter = ScribeTextEditDocumentIdentityAdapter(reader: reader, localUserID: 501)
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let oldBinding = try #require(adapter.captureBinding(actionID: UUID(), process: firstProcess))
        let oldIdentity = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: oldBinding))

        let restartedProcess = makeProcess()
        reader.observation = .init(process: restartedProcess, windowIncarnation: UUID(),
                                   navigationRevision: UUID(), documentID: documentID)
        #expect(adapter.evidence(for: oldBinding) == nil)
        #expect(!resolver.revalidate(oldIdentity, for: oldBinding))

        let newBinding = try #require(adapter.captureBinding(actionID: UUID(), process: restartedProcess))
        let newIdentity = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: newBinding))
        #expect(newIdentity.memoryKey == oldIdentity.memoryKey)
        #expect(!resolver.revalidate(oldIdentity, for: newBinding))
        #expect(resolver.revalidate(newIdentity, for: newBinding))
    }

    private func id(_ text: String) -> ScribeConversationStableID {
        ScribeConversationStableID(rawValue: text)!
    }

    private func makeProcess(
        bundle: String = "com.apple.TextEdit",
        path: String = "/System/Applications/TextEdit.app"
    ) -> ApplicationProcessIdentity {
        .init(processIdentifier: 77, bundleIdentifier: bundle,
              bundleURL: URL(fileURLWithPath: path),
              incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 100))
    }

    private func verified(_ resolution: ScribeConversationIdentityResolution) throws -> ScribeVerifiedConversationIdentity {
        guard case let .verified(identity) = resolution else {
            Issue.record("Expected verified document identity")
            throw FixtureError.unexpectedResolution
        }
        return identity
    }
}

private enum FixtureError: Error { case unexpectedResolution }

@MainActor
private final class FixtureTextEditDocumentReader: ScribeTextEditDocumentIdentityReading {
    var observation: ScribeTextEditDocumentObservation?
    init(observation: ScribeTextEditDocumentObservation?) { self.observation = observation }
    func capture(process: ApplicationProcessIdentity) -> ScribeTextEditDocumentObservation? {
        guard observation?.process == process else { return nil }
        return observation
    }
    func refresh(for binding: ScribeConversationActionBinding) -> ScribeTextEditDocumentObservation? {
        observation
    }
}
