import Foundation
import OSLog

struct AnalyticsEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]

    init(_ name: String, properties: [String: String] = [:]) {
        self.name = name
        self.properties = properties
    }
}

protocol AnalyticsSink: Sendable {
    func send(_ event: AnalyticsEvent)
}

struct NoopAnalyticsSink: AnalyticsSink {
    func send(_ event: AnalyticsEvent) {}
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

@MainActor
final class AnalyticsService {
    private let sink: AnalyticsSink
    private var isEnabled: Bool

    init(isEnabled: Bool, sink: AnalyticsSink = LoggingAnalyticsSink()) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
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
