import ApplicationServices
import Foundation

protocol TextInsertionServing: AnyObject {
    func insert(_ text: String) async throws
    func deleteLastInsertion() async throws
}

enum GuardedTextInsertionOutcome: Equatable, Sendable {
    case inserted
}

enum GuardedTextInsertionError: Error, Equatable, Sendable {
    case uncertainPartialInsertion
}

@MainActor
protocol GuardedTextInsertionServing: AnyObject {
    func insertGuarded(_ text: String) async throws -> GuardedTextInsertionOutcome
}

final class TextInsertionService: TextInsertionServing, GuardedTextInsertionServing {
    private var lastInsertedText = ""

    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw CadenceError.accessibilityPermissionMissing
        }

        try await postUnicodeString(text)
        lastInsertedText = text
    }

    func insertGuarded(_ text: String) async throws -> GuardedTextInsertionOutcome {
        try await insert(text)
        return .inserted
    }

    func deleteLastInsertion() async throws {
        guard !lastInsertedText.isEmpty else { return }
        try await postModifiedKeystroke(keyCode: 6, modifiers: .maskCommand)
        lastInsertedText = ""
    }

    private func postUnicodeString(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw CadenceError.eventSourceUnavailable
        }

        var insertedScalars = 0
        for scalar in text.utf16 {
            do {
                try autoreleasepool {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw CadenceError.eventSourceUnavailable
                }

                var value = scalar
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                }
                insertedScalars += 1
            } catch {
                if insertedScalars > 0 {
                    throw GuardedTextInsertionError.uncertainPartialInsertion
                }
                throw error
            }
        }
    }

    private func postModifiedKeystroke(keyCode: CGKeyCode, modifiers: CGEventFlags) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw CadenceError.eventSourceUnavailable
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
