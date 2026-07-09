import Foundation

struct CalendarEventCache: Codable, Equatable, Sendable {
    var generatedAt: Date
    var windowStart: Date
    var windowEnd: Date
    var events: [GoogleCalendarEvent]
}

final class CalendarEventCacheStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> CalendarEventCache? {
        let url = cacheURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        var cache = try decoder.decode(CalendarEventCache.self, from: data)
        cache.events.sort { $0.startDate < $1.startDate }
        return cache
    }

    func save(_ cache: CalendarEventCache) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var sortedCache = cache
        sortedCache.events.sort { $0.startDate < $1.startDate }
        let data = try encoder.encode(sortedCache)
        try data.write(to: cacheURL, options: [.atomic])
    }

    func delete() throws {
        let url = cacheURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private var cacheURL: URL {
        directoryURL.appendingPathComponent("today-tomorrow", isDirectory: false).appendingPathExtension("json")
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("CalendarEvents", isDirectory: true)
    }
}

struct CalendarEventDayGroup: Identifiable, Equatable, Sendable {
    enum Day: String, Sendable {
        case today = "Today"
        case tomorrow = "Tomorrow"
    }

    var day: Day
    var events: [GoogleCalendarEvent]

    var id: String { day.rawValue }
    var title: String { day.rawValue }
}

enum CalendarEventDashboard {
    static func groups(
        events: [GoogleCalendarEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CalendarEventDayGroup] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return []
        }

        let upcoming = events
            .filter { $0.endDate > now && $0.startDate < startOfDayAfterTomorrow }
            .sorted { $0.startDate < $1.startDate }

        let today = upcoming.filter { $0.endDate > now && $0.startDate < startOfTomorrow }
        let tomorrow = upcoming.filter { $0.startDate >= startOfTomorrow && $0.startDate < startOfDayAfterTomorrow }

        return [
            CalendarEventDayGroup(day: .today, events: today),
            CalendarEventDayGroup(day: .tomorrow, events: tomorrow)
        ]
        .filter { !$0.events.isEmpty }
    }

    static func endOfTomorrow(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now.addingTimeInterval(2 * 24 * 60 * 60)
    }

    static func calendarMeetingNoteTitle(for event: GoogleCalendarEvent, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: event.startDate)) - \(event.title)"
    }
}
