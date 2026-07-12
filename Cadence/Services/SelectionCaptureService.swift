import AppKit
import ApplicationServices
import OSLog

private let selectionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "SelectionCapture"
)

enum SelectionCaptureSource: String, Equatable, Sendable {
    case accessibility
    case clipboard
}

struct SelectionCapture: Equatable, Sendable {
    let text: String
    let source: SelectionCaptureSource
}

protocol AccessibilitySelectionReading {
    func selectedText() throws -> String?
}

protocol ClipboardTextReading {
    func clipboardText() throws -> String?
}

enum SelectionCaptureError: Error, Equatable {
    case unavailable
}

struct SystemAccessibilitySelectionReader: AccessibilitySelectionReading {
    func selectedText() throws -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw SelectionCaptureError.unavailable
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else {
            throw SelectionCaptureError.unavailable
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectionValue
        ) == .success else {
            throw SelectionCaptureError.unavailable
        }
        return selectionValue as? String
    }
}

struct SystemClipboardTextReader: ClipboardTextReading {
    func clipboardText() throws -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

@MainActor
final class SelectionCaptureService {
    private let accessibilityReader: AccessibilitySelectionReading
    private let clipboardReader: ClipboardTextReading

    init(
        accessibilityReader: AccessibilitySelectionReading = SystemAccessibilitySelectionReader(),
        clipboardReader: ClipboardTextReading = SystemClipboardTextReader()
    ) {
        self.accessibilityReader = accessibilityReader
        self.clipboardReader = clipboardReader
    }

    func capture() throws -> SelectionCapture? {
        do {
            if let text = Self.normalized(try accessibilityReader.selectedText()) {
                selectionLogger.debug("Selection captured source=accessibility")
                return SelectionCapture(text: text, source: .accessibility)
            }
        } catch {
            selectionLogger.debug("Accessibility selection unavailable; checking clipboard")
        }

        do {
            if let text = Self.normalized(try clipboardReader.clipboardText()) {
                selectionLogger.debug("Selection captured source=clipboard")
                return SelectionCapture(text: text, source: .clipboard)
            }
            return nil
        } catch {
            selectionLogger.error("Selection capture unavailable")
            throw SelectionCaptureError.unavailable
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum VocabularyTextAppender {
    static func appending(_ term: String, to vocabulary: String) -> String? {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty else { return nil }
        let normalizedVocabulary = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedVocabulary.isEmpty
            ? normalizedTerm
            : normalizedVocabulary + "\n" + normalizedTerm
    }
}

enum DictionaryCaptureOutcome: String {
    case added
    case nothingSelected
    case failed

    var analyticsProperties: [String: AnalyticsValue] {
        ["outcome": .string(rawValue)]
    }
}
