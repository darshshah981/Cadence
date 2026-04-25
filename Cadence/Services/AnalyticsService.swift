import Foundation
import OSLog

struct AnalyticsEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]
    let timestamp: Date

    init(_ name: String, properties: [String: String] = [:], timestamp: Date = .now) {
        self.name = name
        self.properties = properties
        self.timestamp = timestamp
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

final class PostHogAnalyticsSink: AnalyticsSink, @unchecked Sendable {
    private enum Configuration {
        static let apiKey = "phc_kt6sLgHbU9jDQLCnjDEKb4Xtt7Ei9oAfWPBFPNPjQvu4"
        static let captureURL = URL(string: "https://us.i.posthog.com/capture/")!
        static let distinctIDDefaultsKey = "Cadence.analyticsDistinctID"
    }

    private struct CaptureRequest: Encodable {
        let api_key: String
        let event: String
        let properties: [String: String]
        let timestamp: String
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
        category: "PostHog"
    )

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let iso8601Formatter = ISO8601DateFormatter()
    private let distinctID: String
    private var isEnabled: Bool

    init(isEnabled: Bool, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.isEnabled = isEnabled
        self.distinctID = Self.loadOrCreateDistinctID(defaults: defaults)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func send(_ event: AnalyticsEvent) {
        guard isEnabled else { return }

        var properties = event.properties
        properties["distinct_id"] = distinctID
        properties["$process_person_profile"] = "false"

        let requestBody = CaptureRequest(
            api_key: Configuration.apiKey,
            event: event.name,
            properties: properties,
            timestamp: iso8601Formatter.string(from: event.timestamp)
        )

        do {
            var request = URLRequest(url: Configuration.captureURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(requestBody)

            let task = session.dataTask(with: request) { [logger] _, response, error in
                if let error {
                    logger.error("posthog send failed error=\(error.localizedDescription, privacy: .public)")
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    logger.error("posthog send failed status=\(httpResponse.statusCode, privacy: .public)")
                }
            }
            task.resume()
        } catch {
            logger.error("posthog encode failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadOrCreateDistinctID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: Configuration.distinctIDDefaultsKey), !existing.isEmpty {
            return existing
        }

        let distinctID = "cadence-macos-" + UUID().uuidString.lowercased()
        defaults.set(distinctID, forKey: Configuration.distinctIDDefaultsKey)
        return distinctID
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
            PostHogAnalyticsSink(isEnabled: isEnabled)
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
