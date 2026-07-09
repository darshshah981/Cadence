import Foundation

protocol SummaryProvider: Sendable {
    func generateSummary(for note: MeetingNote) -> MeetingSummary
}

struct MeetingSummaryService: Sendable {
    private let provider: any SummaryProvider

    init(configuration: MeetingSummaryConfiguration = MeetingSummaryConfiguration()) {
        self.provider = Self.provider(for: configuration.provider)
    }

    init(provider: any SummaryProvider) {
        self.provider = provider
    }

    func generateSummary(for note: MeetingNote) -> MeetingSummary {
        provider.generateSummary(for: note)
    }

    private static func provider(for option: MeetingSummaryProviderOption) -> any SummaryProvider {
        switch option {
        case .localHeuristic:
            return LocalHeuristicSummaryProvider()
        }
    }
}

struct LocalHeuristicSummaryProvider: SummaryProvider {
    func generateSummary(for note: MeetingNote) -> MeetingSummary {
        let noteLines = Self.cleanedLines(from: note.userNotes)
        let transcriptLines = Self.collapsedTranscriptSegments(note.transcriptSegments)
            .flatMap { Self.cleanedLines(from: $0.text) }
        let allLines = noteLines + transcriptLines

        let overview = Self.overview(title: note.displayTitle, noteLines: noteLines, transcriptLines: transcriptLines)
        let decisions = Self.extractLines(from: allLines, prefixes: ["decision:", "decided:", "decisions:"])
        let actionItems = Self.extractLines(from: allLines, prefixes: ["action:", "todo:", "follow up:", "follow-up:"])
            .map(Self.actionItem)
        let openQuestions = Self.extractQuestions(from: allLines)
        let followUpDraft = Self.followUpDraft(title: note.displayTitle, overview: overview, actionItems: actionItems)

        return MeetingSummary(
            overview: overview,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            followUpDraft: followUpDraft
        )
    }

    private static func overview(title: String, noteLines: [String], transcriptLines: [String]) -> String {
        if let firstNote = noteLines.first {
            return firstNote
        }

        if let firstTranscript = transcriptLines.first {
            return firstTranscript
        }

        return "\(title) has no meeting content yet."
    }

    private static func extractLines(from lines: [String], prefixes: [String]) -> [String] {
        lines.compactMap { line in
            let lowercased = line.lowercased()
            guard let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) else { return nil }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    private static func extractQuestions(from lines: [String]) -> [String] {
        lines.filter { line in
            let lowercased = line.lowercased()
            return line.hasSuffix("?") ||
                lowercased.hasPrefix("question:") ||
                lowercased.hasPrefix("open question:")
        }
        .map { line in
            line.replacingOccurrences(of: "question:", with: "", options: [.caseInsensitive, .anchored])
                .replacingOccurrences(of: "open question:", with: "", options: [.caseInsensitive, .anchored])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    private static func actionItem(from line: String) -> MeetingActionItem {
        let components = line.components(separatedBy: " - ")
        if components.count >= 2 {
            return MeetingActionItem(
                text: components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines),
                owner: components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return MeetingActionItem(text: line)
    }

    private static func followUpDraft(title: String, overview: String, actionItems: [MeetingActionItem]) -> String {
        var lines = [
            "Subject: \(title) follow-up",
            "",
            "Hi all,",
            "",
            overview,
            ""
        ]

        if !actionItems.isEmpty {
            lines.append("Next steps:")
            lines += actionItems.map { item in
                if let owner = item.owner, !owner.isEmpty {
                    return "- \(owner): \(item.text)"
                }
                return "- \(item.text)"
            }
            lines.append("")
        }

        lines.append("Thanks,")
        return lines.joined(separator: "\n")
    }

    private static func cleanedLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func collapsedTranscriptSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var collapsed = [TranscriptSegment]()

        for segment in segments {
            if let lastIndex = collapsed.indices.last,
               shouldMergeAdjacentTranscript(collapsed[lastIndex], with: segment) {
                collapsed[lastIndex].endTime = max(collapsed[lastIndex].endTime, segment.endTime)
            } else {
                collapsed.append(segment)
            }
        }

        return collapsed
    }

    private static func shouldMergeAdjacentTranscript(_ previous: TranscriptSegment, with next: TranscriptSegment) -> Bool {
        normalizedTranscriptText(previous.text) == normalizedTranscriptText(next.text) &&
            !normalizedTranscriptText(previous.text).isEmpty &&
            previous.speaker == next.speaker &&
            previous.captureSource == next.captureSource &&
            previous.effectiveOrigin == next.effectiveOrigin &&
            previous.recordingID == next.recordingID
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MeetingMarkdownFormatter {
    static func markdown(for note: MeetingNote) -> String {
        var lines = [
            "# \(note.displayTitle)",
            "",
            "Created: \(note.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "Updated: \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))",
            ""
        ]

        if let summary = note.summary {
            lines += [
                "## Summary",
                "",
                summary.overview,
                ""
            ]

            lines += section("Decisions", items: summary.decisions)
            lines += section("Action Items", items: summary.actionItems.map { item in
                if let owner = item.owner, !owner.isEmpty {
                    return "\(owner): \(item.text)"
                }
                return item.text
            })
            lines += section("Open Questions", items: summary.openQuestions)

            if !summary.followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines += [
                    "## Follow-up Draft",
                    "",
                    summary.followUpDraft,
                    ""
                ]
            }
        }

        if !note.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += [
                "## Notes",
                "",
                note.userNotes,
                ""
            ]
        }

        if !note.transcriptSegments.isEmpty {
            lines += [
                "## Transcript",
                ""
            ]
            lines += collapsedTranscriptSegments(note.transcriptSegments).map { segment in
                "- [\(timestamp(segment.startTime))] \(transcriptLine(for: segment, in: note))"
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func section(_ title: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        return [
            "## \(title)",
            ""
        ] + items.map { "- \($0)" } + [""]
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func transcriptLine(for segment: TranscriptSegment, in note: MeetingNote) -> String {
        // Prefer a user-assigned Speaker identity; fall back to the capture-source
        // proxy label. If neither is present, emit the text with no speaker prefix.
        let label: String?
        if let speakerID = segment.speakerID,
           let speaker = note.effectiveSpeakers.first(where: { $0.id == speakerID }) {
            label = speaker.displayName
        } else {
            label = segment.speakerDisplayName
        }
        guard let label, !label.isEmpty else {
            return segment.text
        }
        return "\(label): \(segment.text)"
    }

    private static func collapsedTranscriptSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var collapsed = [TranscriptSegment]()

        for segment in segments {
            if let lastIndex = collapsed.indices.last,
               shouldMergeAdjacentTranscript(collapsed[lastIndex], with: segment) {
                collapsed[lastIndex].endTime = max(collapsed[lastIndex].endTime, segment.endTime)
            } else {
                collapsed.append(segment)
            }
        }

        return collapsed
    }

    private static func shouldMergeAdjacentTranscript(_ previous: TranscriptSegment, with next: TranscriptSegment) -> Bool {
        normalizedTranscriptText(previous.text) == normalizedTranscriptText(next.text) &&
            !normalizedTranscriptText(previous.text).isEmpty &&
            previous.speaker == next.speaker &&
            previous.captureSource == next.captureSource &&
            previous.effectiveOrigin == next.effectiveOrigin &&
            previous.recordingID == next.recordingID
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
