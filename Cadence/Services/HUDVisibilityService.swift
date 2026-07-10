import Foundation

enum HUDVisibilityState: Equatable, Sendable {
    case visible
    case hidden(until: Date)
    case hiddenUntilRelaunch

    var showsIdleBar: Bool {
        self == .visible
    }
}

protocol HUDVisibilityClock: Sendable {
    func now() -> Date
}

struct SystemHUDVisibilityClock: HUDVisibilityClock {
    func now() -> Date { .now }
}

protocol HUDVisibilitySleeping: Sendable {
    func sleep(until date: Date) async throws
}

struct SystemHUDVisibilitySleeper: HUDVisibilitySleeping {
    func sleep(until date: Date) async throws {
        let seconds = max(0, date.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
final class HUDVisibilityStore {
    private static let hiddenUntilKey = "Cadence.hudHiddenUntil"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(now: Date) -> HUDVisibilityState {
        guard let expiry = defaults.object(forKey: Self.hiddenUntilKey) as? Date else {
            return .visible
        }
        guard expiry > now else {
            clear()
            return .visible
        }
        return .hidden(until: expiry)
    }

    func save(_ state: HUDVisibilityState) {
        switch state {
        case .hidden(let expiry):
            defaults.set(expiry, forKey: Self.hiddenUntilKey)
        case .visible, .hiddenUntilRelaunch:
            clear()
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.hiddenUntilKey)
    }
}

@MainActor
final class HUDVisibilityController {
    private(set) var state: HUDVisibilityState
    var onChange: ((HUDVisibilityState) -> Void)?

    private let store: HUDVisibilityStore
    private let clock: HUDVisibilityClock
    private let sleeper: HUDVisibilitySleeping
    private var expiryTask: Task<Void, Never>?

    init(
        store: HUDVisibilityStore,
        clock: HUDVisibilityClock = SystemHUDVisibilityClock(),
        sleeper: HUDVisibilitySleeping = SystemHUDVisibilitySleeper()
    ) {
        self.store = store
        self.clock = clock
        self.sleeper = sleeper
        self.state = store.load(now: clock.now())
        scheduleExpiryIfNeeded()
    }

    deinit {
        expiryTask?.cancel()
    }

    func hide(for duration: HUDHideDuration) {
        switch duration.seconds {
        case .some(let seconds):
            transition(to: .hidden(until: clock.now().addingTimeInterval(seconds)))
        case .none:
            transition(to: .hiddenUntilRelaunch)
        }
    }

    func show() {
        transition(to: .visible)
    }

    func refresh() {
        guard case .hidden(let expiry) = state, expiry <= clock.now() else { return }
        transition(to: .visible)
    }

    private func transition(to state: HUDVisibilityState) {
        guard self.state != state else { return }
        self.state = state
        store.save(state)
        scheduleExpiryIfNeeded()
        onChange?(state)
    }

    private func scheduleExpiryIfNeeded() {
        expiryTask?.cancel()
        expiryTask = nil
        guard case .hidden(let expiry) = state else { return }
        let sleeper = sleeper
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(until: expiry)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}

enum HUDIdleVisibilityPolicy {
    static func showsIdleBar(
        visibility: HUDVisibilityState,
        permissionsGranted: Bool
    ) -> Bool {
        visibility.showsIdleBar && permissionsGranted
    }

    static func shouldPresent(
        visualState: HUDVisualState,
        idleBarVisible: Bool
    ) -> Bool {
        visualState != .idle || idleBarVisible
    }
}
