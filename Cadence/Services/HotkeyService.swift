import Carbon
import AppKit
import Foundation
import OSLog

private let hotkeyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Hotkey"
)
private let cadenceHotKeySignature = OSType(0x4653_5441) // FSTA

protocol HotkeyServing: AnyObject {
    var onPress: ((HotkeyAction) -> Void)? { get set }
    var onRelease: ((HotkeyAction) -> Void)? { get set }
    var onQuickTap: ((HotkeyAction) -> Void)? { get set }
    var onDoublePress: ((HotkeyAction) -> Void)? { get set }
    var onAnyKeyPress: (() -> Void)? { get set }
    var onObservedKeyEvent: ((ObservedKeyEvent) -> Void)? { get set }
    var onDiagnosticsEvent: ((String, [String: String]) -> Void)? { get set }
    func updateBindings(_ bindings: [HotkeyBinding])
    func setPaused(_ paused: Bool)
}

struct ObservedKeyEvent: Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    var isDeleteOrUndo: Bool {
        keyCode == 51 || keyCode == 117 || (keyCode == 6 && modifiers.contains(.command))
    }
}

enum HotkeyAnyKeyPressPolicy {
    static func matchesManagedShortcut(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        activeModifierKeyCodes: Set<UInt16>,
        bindings: [HotkeyBinding]
    ) -> Bool {
        let flags = modifiers.intersection([.command, .option, .control, .shift, .function])
        return bindings.contains { binding in
            guard binding.isEnabled,
                  binding.action == .holdToTalk || binding.action == .tapToStartStop,
                  !binding.shortcut.isModifierOnly else {
                return false
            }
            return binding.shortcut.matches(
                keyCode: keyCode,
                modifiers: flags,
                activeModifierKeyCodes: activeModifierKeyCodes
            )
        }
    }
}

enum ModifierOnlyGestureEffect: Equatable, Sendable {
    case schedule(HotkeyAction)
    case cancelScheduled(HotkeyAction)
    case press(HotkeyAction)
    case release(HotkeyAction)
    case quickTap(HotkeyAction)
    case doublePress(HotkeyAction)
}

struct ModifierOnlyGestureEngine: Sendable {
    private static let doublePressInterval: TimeInterval = 0.38
    private(set) var pendingActions = Set<HotkeyAction>()
    private(set) var activeActions = Set<HotkeyAction>()
    private(set) var blockedActions = Set<HotkeyAction>()
    private var lastQuickTapTimes: [HotkeyAction: TimeInterval] = [:]

    mutating func flagsChanged(
        bindings: [HotkeyBinding],
        flags: NSEvent.ModifierFlags,
        activeModifierKeyCodes: Set<UInt16>,
        releasedKeyCode: UInt16?,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [ModifierOnlyGestureEffect] {
        var effects: [ModifierOnlyGestureEffect] = []

        for binding in bindings where binding.isEnabled && binding.shortcut.isModifierOnly {
            let action = binding.action
            if blockedActions.contains(action) {
                if flags.isEmpty {
                    blockedActions.remove(action)
                }
                continue
            }
            let matches = binding.shortcut.matches(
                modifiers: flags,
                activeModifierKeyCodes: activeModifierKeyCodes
            )

            if matches && !activeActions.contains(action) && !pendingActions.contains(action) {
                if action.supportsHoldAndLockGesture,
                   consumesDoublePress(for: action, at: time) {
                    blockedActions.insert(action)
                    effects.append(.doublePress(action))
                } else {
                    pendingActions.insert(action)
                    effects.append(.schedule(action))
                }
            } else if !matches && pendingActions.remove(action) != nil {
                effects.append(.cancelScheduled(action))
                if Self.isRelease(releasedKeyCode, flags: flags) {
                    if action.supportsHoldAndLockGesture {
                        lastQuickTapTimes[action] = time
                        effects.append(.quickTap(action))
                    } else {
                        effects.append(.press(action))
                    }
                } else {
                    blockedActions.insert(action)
                }
            } else if !matches && activeActions.remove(action) != nil {
                effects.append(.release(action))
            }
        }

        return effects
    }

    mutating func activationDelayElapsed(for action: HotkeyAction) -> ModifierOnlyGestureEffect? {
        guard pendingActions.remove(action) != nil else { return nil }
        lastQuickTapTimes[action] = nil
        activeActions.insert(action)
        return .press(action)
    }

    mutating func reset() {
        pendingActions.removeAll()
        activeActions.removeAll()
        blockedActions.removeAll()
        lastQuickTapTimes.removeAll()
    }

    mutating func cancelPending() {
        pendingActions.removeAll()
    }

    private mutating func consumesDoublePress(
        for action: HotkeyAction,
        at time: TimeInterval
    ) -> Bool {
        guard let previousTime = lastQuickTapTimes[action] else { return false }
        lastQuickTapTimes[action] = nil
        let interval = time - previousTime
        return interval >= 0 && interval <= Self.doublePressInterval
    }

    private static func isRelease(
        _ keyCode: UInt16?,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let keyCode,
              let flag = HotkeyConfiguration.modifierFlag(forKeyCode: keyCode) else {
            return flags.isEmpty
        }
        return !flags.contains(flag)
    }
}

final class HotkeyService: HotkeyServing {
    private enum ModifierOnlyTuning {
        static let activationDelay: TimeInterval = 0.24
    }

    var onPress: ((HotkeyAction) -> Void)?
    var onRelease: ((HotkeyAction) -> Void)?
    var onQuickTap: ((HotkeyAction) -> Void)?
    var onDoublePress: ((HotkeyAction) -> Void)?
    var onAnyKeyPress: (() -> Void)?
    var onObservedKeyEvent: ((ObservedKeyEvent) -> Void)?
    var onDiagnosticsEvent: ((String, [String: String]) -> Void)?

    private var bindings: [HotkeyBinding]
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var activeSideSpecificActions = Set<HotkeyAction>()
    private var activeModifierKeyCodes = Set<UInt16>()
    private var pendingModifierOnlyWorkItems: [HotkeyAction: DispatchWorkItem] = [:]
    private var modifierOnlyGestureEngine = ModifierOnlyGestureEngine()
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
        modifierOnlyGestureEngine.reset()
        registerHotKeys()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            activeSideSpecificActions.removeAll()
            modifierOnlyGestureEngine.reset()
            cancelPendingModifierOnlyActions()
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
                guard let userData else { return OSStatus(eventNotHandledErr) }
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
                      hotKeyID.signature == cadenceHotKeySignature,
                      let action = HotkeyAction(eventHotKeyID: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }

                guard !service.isPaused else {
                    return noErr
                }

                service.cancelPendingModifierOnlyActions()

                switch kind {
                case UInt32(kEventHotKeyPressed):
                    hotkeyLogger.info("Hotkey pressed action=\(action.displayName, privacy: .public)")
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
            onDiagnosticsEvent?(
                "hotkey_registration_failed",
                [
                    "stage": "eventHandler",
                    "status": String(status)
                ]
            )
        }
    }

    private func registerHotKeys() {
        for binding in bindings
            where binding.isEnabled &&
            !binding.shortcut.isEmpty &&
            !binding.shortcut.isModifierOnly &&
            !binding.shortcut.requiresSpecificModifierSides {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: cadenceHotKeySignature,
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
                    "Registered hotkey action=\(binding.action.displayName, privacy: .public)"
                )
            } else {
                hotkeyLogger.error(
                    "Failed to register hotkey action=\(binding.action.displayName, privacy: .public) status=\(status, privacy: .public)"
                )
                onDiagnosticsEvent?(
                    "hotkey_registration_failed",
                    [
                        "stage": "registerHotKey",
                        "action": binding.action.rawValue,
                        "status": String(status)
                    ]
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

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleAnyKeyPress(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleAnyKeyPress(event)
            return event
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyRelease(event)
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyRelease(event)
            return event
        }
        if globalKeyMonitor == nil || localKeyMonitor == nil {
            onDiagnosticsEvent?("hotkey_registration_failed", ["stage": "keyMonitor"])
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
        [globalKeyMonitor, localKeyMonitor, globalKeyUpMonitor, localKeyUpMonitor, globalFlagsMonitor, localFlagsMonitor].forEach { monitor in
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalKeyUpMonitor = nil
        localKeyUpMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        modifierOnlyGestureEngine.reset()
        activeSideSpecificActions.removeAll()
        activeModifierKeyCodes.removeAll()
        cancelPendingModifierOnlyActions()
    }

    private func handleAnyKeyPress(_ event: NSEvent? = nil) {
        guard !isPaused else { return }
        cancelPendingModifierOnlyActions()
        if let event {
            onObservedKeyEvent?(ObservedKeyEvent(keyCode: event.keyCode, modifiers: event.modifierFlags))
            handleSideSpecificKeyPress(event)
            if HotkeyAnyKeyPressPolicy.matchesManagedShortcut(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                activeModifierKeyCodes: activeModifierKeyCodes,
                bindings: bindings
            ) {
                return
            }
        }
        onAnyKeyPress?()
    }

    private func handleSideSpecificKeyPress(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        for binding in bindings
            where binding.isEnabled &&
            binding.shortcut.requiresSpecificModifierSides &&
            !binding.shortcut.isModifierOnly &&
            binding.shortcut.matches(
                keyCode: event.keyCode,
                modifiers: flags,
                activeModifierKeyCodes: activeModifierKeyCodes
            ) {
            let action = binding.action
            guard !activeSideSpecificActions.contains(action) else { continue }
            activeSideSpecificActions.insert(action)
            hotkeyLogger.info("Side-specific hotkey pressed action=\(action.displayName, privacy: .public)")
            onPress?(action)
        }
    }

    private func handleKeyRelease(_ event: NSEvent) {
        guard !isPaused else { return }

        for action in Array(activeSideSpecificActions) {
            guard let binding = bindings.first(where: { $0.action == action }),
                  binding.shortcut.keyCode == UInt32(event.keyCode) else {
                continue
            }
            activeSideSpecificActions.remove(action)
            hotkeyLogger.info("Side-specific hotkey released action=\(action.displayName, privacy: .public)")
            onRelease?(action)
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard !isPaused else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        activeModifierKeyCodes = HotkeyConfiguration.updatedActiveModifierKeyCodes(activeModifierKeyCodes, with: event)

        let effects = modifierOnlyGestureEngine.flagsChanged(
            bindings: bindings,
            flags: flags,
            activeModifierKeyCodes: activeModifierKeyCodes,
            releasedKeyCode: event.keyCode
        )
        applyModifierOnlyEffects(effects)
    }

    private func applyModifierOnlyEffects(_ effects: [ModifierOnlyGestureEffect]) {
        for effect in effects {
            switch effect {
            case let .schedule(action):
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPaused else { return }
                    self.pendingModifierOnlyWorkItems[action] = nil
                    guard self.modifierOnlyGestureEngine.activationDelayElapsed(for: action) != nil else { return }
                    hotkeyLogger.info("Modifier-only hotkey pressed action=\(action.displayName, privacy: .public)")
                    self.onPress?(action)
                }
                pendingModifierOnlyWorkItems[action] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + ModifierOnlyTuning.activationDelay, execute: workItem)
            case let .cancelScheduled(action):
                pendingModifierOnlyWorkItems[action]?.cancel()
                pendingModifierOnlyWorkItems[action] = nil
            case let .quickTap(action):
                onQuickTap?(action)
            case let .doublePress(action):
                onDoublePress?(action)
            case let .press(action):
                if action != .holdToTalk {
                    cancelPendingModifierOnlyActions()
                }
                onPress?(action)
            case let .release(action):
                if action != .holdToTalk {
                    cancelPendingModifierOnlyActions()
                }
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
        modifierOnlyGestureEngine.cancelPending()
    }

}

private extension HotkeyAction {
    var supportsHoldAndLockGesture: Bool {
        self == .holdToTalk || self == .scribe
    }

    var eventHotKeyID: UInt32 {
        switch self {
        case .holdToTalk:
            return 1
        case .tapToStartStop:
            return 2
        case .scribe:
            return 3
        }
    }

    init?(eventHotKeyID: UInt32) {
        switch eventHotKeyID {
        case 1:
            self = .holdToTalk
        case 2:
            self = .tapToStartStop
        case 3:
            self = .scribe
        default:
            return nil
        }
    }
}
