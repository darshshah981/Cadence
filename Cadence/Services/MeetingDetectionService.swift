import Foundation

struct MeetingDetectionService: Sendable {
    var promptWindow: TimeInterval = 5 * 60

    func nextPrompt(
        from events: [GoogleCalendarEvent],
        now: Date = Date(),
        promptedEventIDs: Set<String>
    ) -> GoogleCalendarEvent? {
        events
            .filter(\.isMeetingCandidate)
            .filter { $0.startsWithin(promptWindow, from: now) }
            .filter { !promptedEventIDs.contains($0.id) }
            .sorted { $0.startDate < $1.startDate }
            .first
    }
}
