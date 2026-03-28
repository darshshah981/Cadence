import ApplicationServices
import Foundation

protocol TextInsertionServing: AnyObject {
    func insert(_ text: String) async throws
    func deleteLastInsertion() async throws
}

final class TextInsertionService: TextInsertionServing {
    private var lastInsertedText = ""

    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw FlowStateError.accessibilityPermissionMissing
        }

        try await postUnicodeString(text)
        lastInsertedText = text
    }

    func deleteLastInsertion() async throws {
        guard !lastInsertedText.isEmpty else { return }
        try await postModifiedKeystroke(keyCode: 6, modifiers: .maskCommand)
        lastInsertedText = ""
    }

    private func postUnicodeString(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw FlowStateError.eventSourceUnavailable
        }

        for scalar in text.utf16 {
            try autoreleasepool {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw FlowStateError.eventSourceUnavailable
                }

                var value = scalar
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private func postModifiedKeystroke(keyCode: CGKeyCode, modifiers: CGEventFlags) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw FlowStateError.eventSourceUnavailable
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
