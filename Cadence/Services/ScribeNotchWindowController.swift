import AppKit
import Carbon
import OSLog
import SwiftUI

private let scribeNotchWindowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeNotchWindow"
)

@MainActor
private final class ScribeNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol ScribeOutsideClickMonitoring: AnyObject {
    func start(handler: @escaping (NSPoint) -> Void)
    func stop()
}

enum ScribeReviewKeyboardCommand: Hashable, Sendable {
    case insert
    case copy
    case discard
}

enum ScribeReviewKeyboardPolicy {
    static func commands(
        for content: ScribeNotchContent
    ) -> Set<ScribeReviewKeyboardCommand> {
        switch content {
        case .replacing, .ready, .insertionRecovery:
            return [.insert, .copy, .discard]
        case let .failure(_, literalTranscript, _):
            return literalTranscript == nil ? [.discard] : [.copy, .discard]
        default:
            return []
        }
    }
}

@MainActor
protocol ScribeReviewKeyboardShortcutMonitoring: AnyObject {
    func start(
        commands: Set<ScribeReviewKeyboardCommand>,
        handler: @escaping (ScribeReviewKeyboardCommand) -> Void
    )
    func stop()
}

@MainActor
private final class CarbonScribeReviewKeyboardShortcutMonitor:
    ScribeReviewKeyboardShortcutMonitoring {
    private static let signature = OSType(0x5343_5242) // SCRB

    private var hotKeyReferences: [ScribeReviewKeyboardCommand: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var handler: ((ScribeReviewKeyboardCommand) -> Void)?

    deinit {
        for reference in hotKeyReferences.values {
            UnregisterEventHotKey(reference)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func start(
        commands: Set<ScribeReviewKeyboardCommand>,
        handler: @escaping (ScribeReviewKeyboardCommand) -> Void
    ) {
        stop()
        guard !commands.isEmpty else { return }
        self.handler = handler

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<CarbonScribeReviewKeyboardShortcutMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature
                        == CarbonScribeReviewKeyboardShortcutMonitor.signature,
                      let command = ScribeReviewKeyboardCommand(
                        eventHotKeyID: hotKeyID.id
                      ) else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    monitor.handler?(command)
                }
                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
        guard installStatus == noErr else {
            scribeNotchWindowLogger.error(
                "Could not install Scribe review keyboard handler status=\(installStatus, privacy: .public)"
            )
            self.handler = nil
            return
        }

        for command in commands {
            let shortcut = command.shortcut
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.modifiers,
                EventHotKeyID(
                    signature: CarbonScribeReviewKeyboardShortcutMonitor.signature,
                    id: command.eventHotKeyID
                ),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeyReferences[command] = reference
            } else {
                scribeNotchWindowLogger.error(
                    "Could not register Scribe review shortcut command=\(command.logName, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        }
    }

    func stop() {
        for reference in hotKeyReferences.values {
            UnregisterEventHotKey(reference)
        }
        hotKeyReferences.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }
}

private extension ScribeReviewKeyboardCommand {
    var eventHotKeyID: UInt32 {
        switch self {
        case .insert: 1
        case .copy: 2
        case .discard: 3
        }
    }

    init?(eventHotKeyID: UInt32) {
        switch eventHotKeyID {
        case 1: self = .insert
        case 2: self = .copy
        case 3: self = .discard
        default: return nil
        }
    }

    var shortcut: (keyCode: CGKeyCode, modifiers: UInt32) {
        switch self {
        case .insert:
            return (36, 0)
        case .copy:
            return (8, UInt32(cmdKey))
        case .discard:
            return (53, 0)
        }
    }

    var logName: String {
        switch self {
        case .insert: "insert"
        case .copy: "copy"
        case .discard: "discard"
        }
    }
}

@MainActor
private final class AppKitScribeOutsideClickMonitor: ScribeOutsideClickMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func start(handler: @escaping (NSPoint) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask
        ) { _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in
                handler(clickLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mask
        ) { event in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in
                handler(clickLocation)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

@MainActor
final class ScribeNotchWindowController {
    let viewModel = ScribeNotchViewModel()
    var onOutsideClickAfterCopy: (() -> Void)?

    private var panel: NSPanel?
    private var screenChangeObserver: NSObjectProtocol?
    private var dismissalTask: Task<Void, Never>?
    private let outsideClickMonitor: ScribeOutsideClickMonitoring
    private let reviewKeyboardMonitor: ScribeReviewKeyboardShortcutMonitoring
    private var pinnedDisplayID: CGDirectDisplayID?

    convenience init() {
        self.init(
            outsideClickMonitor: AppKitScribeOutsideClickMonitor(),
            reviewKeyboardMonitor: CarbonScribeReviewKeyboardShortcutMonitor()
        )
    }

    convenience init(outsideClickMonitor: ScribeOutsideClickMonitoring) {
        self.init(
            outsideClickMonitor: outsideClickMonitor,
            reviewKeyboardMonitor: CarbonScribeReviewKeyboardShortcutMonitor()
        )
    }

    init(
        outsideClickMonitor: ScribeOutsideClickMonitoring,
        reviewKeyboardMonitor: ScribeReviewKeyboardShortcutMonitoring
    ) {
        self.outsideClickMonitor = outsideClickMonitor
        self.reviewKeyboardMonitor = reviewKeyboardMonitor
        viewModel.setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        viewModel.onInteractionAvailabilityChanged = { [weak self] isInteractive in
            guard let self else { return }
            self.panel?.ignoresMouseEvents = !isInteractive
            if isInteractive {
                self.startReviewKeyboardMonitoring()
            } else {
                self.reviewKeyboardMonitor.stop()
            }
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionIfVisible()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    func update(_ presentation: ScribeNotchPresentation) {
        dismissalTask?.cancel()
        stopOutsideClickDismissalMonitoring()
        if !presentation.allowsReviewActions {
            reviewKeyboardMonitor.stop()
        }

        if presentation.requiresImmediateFocusHandoff {
            panel?.ignoresMouseEvents = true
            panel?.resignKey()
            panel?.orderOut(nil)
            viewModel.apply(presentation)
            return
        }

        if presentation.content == .hidden {
            viewModel.apply(presentation)
            dismissalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
                self?.viewModel.resetImmediately()
                self?.pinnedDisplayID = nil
            }
            return
        }

        let panel = makePanelIfNeeded()
        position(panel)
        panel.ignoresMouseEvents = !presentation.allowsReviewActions
        panel.orderFrontRegardless()
        viewModel.apply(presentation)

        if let delay = ScribeNotchAutoDismissPolicy.delay(for: presentation) {
            dismissalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self,
                      !Task.isCancelled,
                      self.viewModel.presentation == presentation else { return }
                self.viewModel.apply(
                    ScribeNotchPresentation(content: .hidden, pill: .hidden)
                )
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                self.panel?.orderOut(nil)
                self.viewModel.resetImmediately()
                self.pinnedDisplayID = nil
            }
        }
    }

    func showCopyFeedback(_ message: String) {
        dismissalTask?.cancel()
        let panel = makePanelIfNeeded()
        position(panel)
        panel.ignoresMouseEvents = !viewModel.showsReviewActions
        panel.orderFrontRegardless()
        viewModel.showFeedback(message)
        startOutsideClickDismissalMonitoring()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_300))
            guard let self, !Task.isCancelled else { return }
            guard self.viewModel.presentation.content == .hidden else {
                self.panel?.ignoresMouseEvents = !self.viewModel.showsReviewActions
                return
            }
            self.panel?.orderOut(nil)
            self.viewModel.resetImmediately()
            self.pinnedDisplayID = nil
            self.stopOutsideClickDismissalMonitoring()
        }
    }

    func close() {
        dismissalTask?.cancel()
        stopOutsideClickDismissalMonitoring()
        reviewKeyboardMonitor.stop()
        viewModel.resetImmediately()
        panel?.orderOut(nil)
        pinnedDisplayID = nil
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = ScribeNotchPanel(
            contentRect: NSRect(origin: .zero, size: ScribeNotchMotion.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(
            rootView: ScribeNotchView(model: viewModel)
                .environment(\.colorScheme, .dark)
        )
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: ScribeNotchMotion.canvasSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    private func startOutsideClickDismissalMonitoring() {
        outsideClickMonitor.start { [weak self] clickLocation in
            self?.dismissCopiedReviewIfOutside(clickLocation)
        }
    }

    private func dismissCopiedReviewIfOutside(_ clickLocation: NSPoint) {
        guard ScribeCopyOutsideDismissalPolicy.shouldDismiss(
            clickLocation: clickLocation,
            panelFrame: panel?.frame
        ) else { return }
        stopOutsideClickDismissalMonitoring()
        update(ScribeNotchPresentation(content: .hidden, pill: .hidden))
        onOutsideClickAfterCopy?()
    }

    private func stopOutsideClickDismissalMonitoring() {
        outsideClickMonitor.stop()
    }

    private func startReviewKeyboardMonitoring() {
        let commands = ScribeReviewKeyboardPolicy.commands(
            for: viewModel.presentation.content
        )
        reviewKeyboardMonitor.start(commands: commands) { [weak self] command in
            guard let self else { return }
            switch command {
            case .insert:
                self.viewModel.onInsert?()
            case .copy:
                self.viewModel.onCopy?()
            case .discard:
                self.viewModel.onDiscard?()
            }
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = pinnedScreen() else { return }
        let hasHardwareNotch = screen.safeAreaInsets.top > 0
        viewModel.configureDisplay(hasHardwareNotch: hasHardwareNotch)

        let size = ScribeNotchMotion.canvasSize
        let origin = NSPoint(
            x: floor(screen.frame.midX - size.width / 2),
            y: floor(
                screen.frame.maxY
                    - size.height
                    - (hasHardwareNotch ? 0 : ScribeNotchGeometry.floatingTopGap)
            )
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func pinnedScreen() -> NSScreen? {
        if let pinnedDisplayID,
           let screen = NSScreen.screens.first(where: {
               Self.displayID(for: $0) == pinnedDisplayID
           }) {
            return screen
        }
        guard let screen = WindowPlacement.screen() ?? NSScreen.main else { return nil }
        pinnedDisplayID = Self.displayID(for: screen)
        return screen
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
