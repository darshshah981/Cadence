import Foundation
import OSLog
import TelemetryDeck

struct AnalyticsEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]

    init(_ name: String, properties: [String: String] = [:]) {
        self.name = name
        self.properties = properties
    }
}

protocol AnalyticsSink: Sendable {
    func setEnabled(_ isEnabled: Bool)
    func send(_ event: AnalyticsEvent)
}

extension AnalyticsSink {
    func setEnabled(_ isEnabled: Bool) {}
}

struct NoopAnalyticsSink: AnalyticsSink {
    func send(_ event: AnalyticsEvent) {}
}

struct CompositeAnalyticsSink: AnalyticsSink {
    private let sinks: [any AnalyticsSink]

    init(_ sinks: any AnalyticsSink...) {
        self.sinks = sinks
    }

    func setEnabled(_ isEnabled: Bool) {
        sinks.forEach { $0.setEnabled(isEnabled) }
    }

    func send(_ event: AnalyticsEvent) {
        sinks.forEach { $0.send(event) }
    }
}

struct LoggingAnalyticsSink: AnalyticsSink {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
        category: "Analytics"
    )

    func send(_ event: AnalyticsEvent) {
        logger.info(
            "analytics event=\(event.name, privacy: .public) properties=\(Self.format(event.properties), privacy: .public)"
        )
    }

    private static func format(_ properties: [String: String]) -> String {
        properties
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}

final class TelemetryDeckAnalyticsSink: AnalyticsSink, @unchecked Sendable {
    private enum Configuration {
        static let appID = "0757A647-D529-4A65-A630-7507D3088454"
        static let namespace = "xyz.darshshah"
        static let signalPrefix = "Cadence."
        static let parameterPrefix = "Cadence."
    }

    private let configuration: TelemetryDeck.Config

    init(isEnabled: Bool) {
        let configuration = TelemetryDeck.Config(
            appID: Configuration.appID,
            namespace: Configuration.namespace
        )
        configuration.analyticsDisabled = !isEnabled
        configuration.defaultSignalPrefix = Configuration.signalPrefix
        configuration.defaultParameterPrefix = Configuration.parameterPrefix
        configuration.sendNewSessionBeganSignal = false
        configuration.sessionStatsEnabled = false
        self.configuration = configuration

        if !TelemetryManager.isInitialized {
            TelemetryDeck.initialize(config: configuration)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        configuration.analyticsDisabled = !isEnabled
    }

    func send(_ event: AnalyticsEvent) {
        TelemetryDeck.signal(event.name, parameters: event.properties)
    }
}

@MainActor
final class AnalyticsService {
    private let sink: AnalyticsSink
    private var isEnabled: Bool

    init(
        isEnabled: Bool,
        sink: AnalyticsSink? = nil
    ) {
        self.isEnabled = isEnabled
        self.sink = sink ?? CompositeAnalyticsSink(
            LoggingAnalyticsSink(),
            TelemetryDeckAnalyticsSink(isEnabled: isEnabled)
        )
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        sink.setEnabled(isEnabled)
        track("analytics_consent_updated", properties: ["enabled": String(isEnabled)])
    }

    func track(_ name: String, properties: [String: String] = [:]) {
        guard isEnabled else { return }
        sink.send(AnalyticsEvent(name, properties: sanitized(properties)))
    }

    private func sanitized(_ properties: [String: String]) -> [String: String] {
        properties.reduce(into: [:]) { result, item in
            result[Self.sanitize(item.key)] = Self.sanitize(item.value)
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(80)
            .description
    }
}
