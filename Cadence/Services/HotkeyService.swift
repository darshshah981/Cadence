import Carbon
import AppKit
import Foundation
import OSLog

private let hotkeyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Hotkey"
)

protocol HotkeyServing: AnyObject {
    var onPress: ((HotkeyAction) -> Void)? { get set }
    var onRelease: ((HotkeyAction) -> Void)? { get set }
    var onAnyKeyPress: (() -> Void)? { get set }
    func updateBindings(_ bindings: [HotkeyBinding])
    func setPaused(_ paused: Bool)
}

final class HotkeyService: HotkeyServing {
    private enum ModifierOnlyTuning {
        static let activationDelay: TimeInterval = 0.24
    }

    var onPress: ((HotkeyAction) -> Void)?
    var onRelease: ((HotkeyAction) -> Void)?
    var onAnyKeyPress: (() -> Void)?

    private var bindings: [HotkeyBinding]
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var activeModifierOnlyActions = Set<HotkeyAction>()
    private var pendingModifierOnlyWorkItems: [HotkeyAction: DispatchWorkItem] = [:]
    private var suppressNextAnyKeyPress = false
    private var isPaused = false

    init(bindings: [HotkeyBinding]) {
        self.bindings = bindings
        register()
    }

    deinit {
        unregisterHotKeys()
        removeMonitors()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func updateBindings(_ bindings: [HotkeyBinding]) {
        guard bindings != self.bindings else { return }
        self.bindings = bindings
        unregisterHotKeys()
        cancelPendingModifierOnlyActions()
        registerHotKeys()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            activeModifierOnlyActions.removeAll()
            cancelPendingModifierOnlyActions()
            suppressNextAnyKeyPress = false
        }
    }

    private func register() {
        installHandlerIfNeeded()
        registerHotKeys()
        installMonitorsIfNeeded()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)

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
                      let action = HotkeyAction(eventHotKeyID: hotKeyID.id) else {
                    return noErr
                }

                guard !service.isPaused else {
                    return noErr
                }

                service.cancelPendingModifierOnlyActions()

                switch kind {
                case UInt32(kEventHotKeyPressed):
                    hotkeyLogger.info("Hotkey pressed action=\(action.displayName, privacy: .public)")
                    service.suppressNextAnyKeyPress = action == .tapToStartStop
                    service.onPress?(action)
                case UInt32(kEventHotKeyReleased):
                    hotkeyLogger.info("Hotkey released action=\(action.displayName, privacy: .public)")
                    service.onRelease?(action)
                default:
                    break
                }

                return noErr
            },
            2,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )

        if status == noErr {
            hotkeyLogger.info("Installed Carbon hotkey event handler")
        } else {
            hotkeyLogger.error("Failed to install Carbon hotkey event handler status=\(status, privacy: .public)")
        }
    }

    private func registerHotKeys() {
        for binding in bindings where binding.isEnabled && !binding.shortcut.isEmpty && !binding.shortcut.isModifierOnly {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: OSType(0x46535441),
                id: binding.action.eventHotKeyID
            )

            let status = RegisterEventHotKey(
                binding.shortcut.keyCode,
                binding.shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if let hotKeyRef {
                hotKeyRefs[binding.action] = hotKeyRef
                hotkeyLogger.info(
                    "Registered hotkey action=\(binding.action.displayName, privacy: .public) shortcut=\(binding.shortcut.displayName, privacy: .public)"
                )
            } else {
                hotkeyLogger.error(
                    "Failed to register hotkey action=\(binding.action.displayName, privacy: .public) shortcut=\(binding.shortcut.displayName, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func installMonitorsIfNeeded() {
        guard globalKeyMonitor == nil else { return }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleAnyKeyPress()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleAnyKeyPress()
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlagsChanged(event)
            return event
        }
        hotkeyLogger.info("Installed key and modifier monitors")
    }

    private func removeMonitors() {
        [globalKeyMonitor, localKeyMonitor, globalFlagsMonitor, localFlagsMonitor].forEach { monitor in
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        activeModifierOnlyActions.removeAll()
        cancelPendingModifierOnlyActions()
    }

    private func handleAnyKeyPress() {
        guard !isPaused else { return }
        cancelPendingModifierOnlyActions()
        if suppressNextAnyKeyPress {
            suppressNextAnyKeyPress = false
            return
        }
        onAnyKeyPress?()
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard !isPaused else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonModifiers = HotkeyConfiguration.carbonModifiers(for: flags)

        for binding in bindings where binding.isEnabled && binding.shortcut.isModifierOnly {
            let action = binding.action
            let matches = carbonModifiers == binding.shortcut.carbonModifiers && carbonModifiers != 0
            let isActive = activeModifierOnlyActions.contains(action)
            let isPending = pendingModifierOnlyWorkItems[action] != nil

            if matches && !isActive && !isPending {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPaused else { return }
                    self.pendingModifierOnlyWorkItems[action] = nil
                    self.activeModifierOnlyActions.insert(action)
                    self.suppressNextAnyKeyPress = action == .tapToStartStop
                    hotkeyLogger.info("Modifier-only hotkey pressed action=\(action.displayName, privacy: .public)")
                    self.onPress?(action)
                }
                pendingModifierOnlyWorkItems[action] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + ModifierOnlyTuning.activationDelay, execute: workItem)
            } else if !matches && isPending {
                pendingModifierOnlyWorkItems[action]?.cancel()
                pendingModifierOnlyWorkItems[action] = nil
            } else if !matches && isActive {
                activeModifierOnlyActions.remove(action)
                hotkeyLogger.info("Modifier-only hotkey released action=\(action.displayName, privacy: .public)")
                onRelease?(action)
            }
        }
    }

    private func cancelPendingModifierOnlyActions() {
        for workItem in pendingModifierOnlyWorkItems.values {
            workItem.cancel()
        }
        pendingModifierOnlyWorkItems.removeAll()
    }
}

private extension HotkeyAction {
    var eventHotKeyID: UInt32 {
        switch self {
        case .holdToTalk:
            return 1
        case .tapToStartStop:
            return 2
        }
    }

    init?(eventHotKeyID: UInt32) {
        switch eventHotKeyID {
        case 1:
            self = .holdToTalk
        case 2:
            self = .tapToStartStop
        default:
            return nil
        }
    }
}
