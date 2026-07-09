import Foundation

enum MeetingCaptureSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case systemAudio
    case microphone
    case microphoneAndSystemAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemAudio:
            return "System Audio"
        case .microphone:
            return "Microphone"
        case .microphoneAndSystemAudio:
            return "Mic + System"
        }
    }

    var shortDescription: String {
        switch self {
        case .systemAudio:
            return "Capture computer audio only."
        case .microphone:
            return "Capture your microphone only."
        case .microphoneAndSystemAudio:
            return "Capture your voice and computer audio."
        }
    }

    var requiresMicrophone: Bool {
        self == .microphone || self == .microphoneAndSystemAudio
    }

    var requiresScreenRecording: Bool {
        self == .systemAudio || self == .microphoneAndSystemAudio
    }
}

enum MeetingCapturePhase: String, Equatable, Sendable {
    case starting
    case recording
    case finalizing

    var displayName: String {
        switch self {
        case .starting:
            return "Starting"
        case .recording:
            return "Recording"
        case .finalizing:
            return "Transcribing"
        }
    }
}

struct MeetingCaptureSessionSummary: Equatable, Sendable {
    var noteID: UUID
    var noteTitle: String
    var source: MeetingCaptureSource
    var phase: MeetingCapturePhase
    var startedAt: Date?
    var capturedFrameCount: Int
    var level: Double

    func isTargeting(noteID: UUID) -> Bool {
        self.noteID == noteID
    }
}

enum MeetingTranscriptState: String, Codable, Equatable, Sendable {
    case empty
    case liveDraft
    case finalizing
    case final
    case finalizationFailed

    var displayName: String {
        switch self {
        case .empty:
            return "No transcript"
        case .liveDraft:
            return "Live draft"
        case .finalizing:
            return "Finalizing"
        case .final:
            return "Final transcript"
        case .finalizationFailed:
            return "Final pass failed"
        }
    }
}

enum TranscriptSegmentOrigin: String, Codable, Equatable, Sendable {
    case liveDraft
    case final
}

enum MeetingRecordingState: String, Codable, Equatable, Sendable {
    case recording
    case recorded
    case finalizing
    case final
    case finalizationFailed
}

struct MeetingAudioRecordingMetadata: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var source: MeetingCaptureSource
    var createdAt: Date
    var duration: TimeInterval
    var frameCount: Int
    var sampleRate: Double
    var speechDetected: Bool
    var speechFrameCount: Int
    var peakLevel: Double
    var state: MeetingRecordingState?

    var effectiveState: MeetingRecordingState {
        state ?? .final
    }

    init(
        id: UUID,
        fileName: String,
        source: MeetingCaptureSource,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        frameCount: Int = 0,
        sampleRate: Double = 16_000,
        speechDetected: Bool = false,
        speechFrameCount: Int = 0,
        peakLevel: Double = 0,
        state: MeetingRecordingState? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.source = source
        self.createdAt = createdAt
        self.duration = duration
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.speechDetected = speechDetected
        self.speechFrameCount = speechFrameCount
        self.peakLevel = peakLevel
        self.state = state
    }
}

/// Describes a saved meeting-audio file discovered on disk that no meeting note
/// references — the result of a launch-time audio-directory sweep. Cadence never
/// auto-deletes these; it relinks them to their note when possible and otherwise
/// surfaces them for a user keep/discard choice.
struct OrphanedMeetingRecording: Identifiable, Equatable, Sendable {
    let recordingID: UUID
    let noteID: UUID
    let fileName: String

    var id: UUID { recordingID }
}

enum MeetingRecordingRecovery {
    /// Relinks orphans whose note still exists by appending a `recording`-state
    /// ledger entry (so launch recovery marks the note `finalizationFailed` with
    /// an actionable message). Returns the updated notes plus the orphans that
    /// could not be relinked because their note is absent.
    static func relink(_ notes: [MeetingNote], orphans: [OrphanedMeetingRecording]) -> (notes: [MeetingNote], unrecoverable: [OrphanedMeetingRecording]) {
        var updatedNotes = notes
        var unrecoverable = [OrphanedMeetingRecording]()

        for orphan in orphans {
            guard let index = updatedNotes.firstIndex(where: { $0.id == orphan.noteID }) else {
                unrecoverable.append(orphan)
                continue
            }
            var recordings = updatedNotes[index].effectiveAudioRecordings
            if recordings.contains(where: { $0.id == orphan.recordingID }) { continue }
            recordings.append(MeetingAudioRecordingMetadata(
                id: orphan.recordingID,
                fileName: orphan.fileName,
                source: .systemAudio,
                state: .recording
            ))
            updatedNotes[index].audioRecordings = recordings
        }

        return (updatedNotes, unrecoverable)
    }
}

struct MeetingNote: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var title: String
    var userNotes: String
    var transcriptSegments: [TranscriptSegment]
    var summary: MeetingSummary?
    var calendarEventID: String?
    var createdAt: Date
    var updatedAt: Date
    var transcriptState: MeetingTranscriptState?
    var transcriptStatusMessage: String?
    var audioRecordings: [MeetingAudioRecordingMetadata]?
    var retainedLiveDraftByRecording: [String: [TranscriptSegment]]?
    var speakers: [MeetingSpeakerIdentity]?

    init(
        schemaVersion: Int = MeetingNote.currentSchemaVersion,
        id: UUID = UUID(),
        title: String = "Untitled Meeting",
        userNotes: String = "",
        transcriptSegments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil,
        calendarEventID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        transcriptState: MeetingTranscriptState? = nil,
        transcriptStatusMessage: String? = nil,
        audioRecordings: [MeetingAudioRecordingMetadata]? = nil,
        retainedLiveDraftByRecording: [String: [TranscriptSegment]]? = nil,
        speakers: [MeetingSpeakerIdentity]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.userNotes = userNotes
        self.transcriptSegments = transcriptSegments
        self.summary = summary
        self.calendarEventID = calendarEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptState = transcriptState
        self.transcriptStatusMessage = transcriptStatusMessage
        self.audioRecordings = audioRecordings
        self.retainedLiveDraftByRecording = retainedLiveDraftByRecording
        self.speakers = speakers
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case title
        case userNotes
        case transcriptSegments
        case summary
        case calendarEventID
        case createdAt
        case updatedAt
        case transcriptState
        case transcriptStatusMessage
        case audioRecordings
        case retainedLiveDraftByRecording
        case speakers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Meeting"
        self.userNotes = try container.decodeIfPresent(String.self, forKey: .userNotes) ?? ""
        self.transcriptSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
        self.summary = try container.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        self.calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.transcriptState = try container.decodeIfPresent(MeetingTranscriptState.self, forKey: .transcriptState)
        self.transcriptStatusMessage = try container.decodeIfPresent(String.self, forKey: .transcriptStatusMessage)
        self.audioRecordings = try container.decodeIfPresent([MeetingAudioRecordingMetadata].self, forKey: .audioRecordings)
        self.retainedLiveDraftByRecording = try container.decodeIfPresent([String: [TranscriptSegment]].self, forKey: .retainedLiveDraftByRecording)
        self.speakers = try container.decodeIfPresent([MeetingSpeakerIdentity].self, forKey: .speakers)
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !usesDefaultTitle {
            return trimmedTitle
        }

        return suggestedTitle ?? "Untitled Meeting"
    }

    var previewText: String {
        let trimmedNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            return trimmedNotes
        }

        if let transcriptText = transcriptSegments.first(where: { !Self.isTranscriptionProblemText($0.text) })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptText.isEmpty {
            return transcriptText
        }

        return "No notes yet"
    }

    var isBlankDraft: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedTitle.isEmpty || displayTitle == "Untitled Meeting") &&
            userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            transcriptSegments.isEmpty &&
            summary == nil &&
            calendarEventID == nil &&
            effectiveAudioRecordings.isEmpty
    }

    var effectiveTranscriptState: MeetingTranscriptState {
        if let transcriptState {
            return transcriptState
        }
        return transcriptSegments.isEmpty ? .empty : .final
    }

    var effectiveAudioRecordings: [MeetingAudioRecordingMetadata] {
        audioRecordings ?? []
    }

    var usesDefaultTitle: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ||
            trimmedTitle == "Untitled Meeting" ||
            Self.isTranscriptionProblemText(trimmedTitle)
    }

    var suggestedTitle: String? {
        let sourceText = [
            userNotes,
            transcriptSegments.first(where: { !Self.isTranscriptionProblemText($0.text) })?.text ?? "",
            summary?.overview ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty && !Self.isTranscriptionProblemText($0) }

        guard let sourceText else { return nil }
        let firstLine = sourceText.components(separatedBy: .newlines).first ?? sourceText
        let firstSentence = firstLine.components(separatedBy: ". ").first ?? firstLine
        let cleaned = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if cleaned.count <= 64 {
            return cleaned
        }

        let index = cleaned.index(cleaned.startIndex, offsetBy: 61)
        return cleaned[..<index].trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func isTranscriptionProblemText(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("whisper did not return any transcript text") ||
            normalized.contains("meeting transcription took too long") ||
            normalized.contains("no speech audio was captured")
    }

    mutating func replaceLiveDraftSegments(
        recordingID: UUID,
        with finalSegments: [TranscriptSegment]
    ) {
        transcriptSegments.removeAll { segment in
            segment.recordingID == recordingID &&
                segment.effectiveOrigin == .liveDraft
        }
        transcriptSegments.append(contentsOf: finalSegments)
        transcriptState = finalSegments.isEmpty ? .empty : .final
        transcriptStatusMessage = nil
        updatedAt = Date()
    }

    /// Replaces every segment belonging to the given recording (any origin) with
    /// `segments`. Used by final-pass retry so re-running a pass never duplicates
    /// output — it wholesale-replaces that recording's segments each time.
    mutating func replaceSegmentsForRecording(
        recordingID: UUID,
        with segments: [TranscriptSegment]
    ) {
        transcriptSegments.removeAll { $0.recordingID == recordingID }
        transcriptSegments.append(contentsOf: segments)
        transcriptState = segments.isEmpty ? .empty : .final
        transcriptStatusMessage = nil
        updatedAt = Date()
    }

    /// Captures the recording's current live-draft segments so a final pass can
    /// be reverted. Called before final segments replace the draft.
    mutating func retainLiveDraftSnapshot(for recordingID: UUID) {
        let key = recordingID.uuidString
        let draftSegments = transcriptSegments.filter {
            $0.recordingID == recordingID && $0.effectiveOrigin == .liveDraft
        }
        if draftSegments.isEmpty {
            retainedLiveDraftByRecording?.removeValue(forKey: key)
        } else {
            if retainedLiveDraftByRecording == nil { retainedLiveDraftByRecording = [:] }
            retainedLiveDraftByRecording?[key] = draftSegments
        }
    }

    func retainedLiveDraftText(for recordingID: UUID) -> String? {
        guard let segments = retainedLiveDraftByRecording?[recordingID.uuidString],
              !segments.isEmpty else { return nil }
        return segments.map(\.text).joined(separator: " ")
    }

    /// Applies a successful final pass, retaining the prior live draft only when
    /// the final text differs from it — so an unchanged final pass shows no
    /// lineage chrome. Idempotent (delegates to `replaceSegmentsForRecording`).
    mutating func applyFinalSegments(_ segments: [TranscriptSegment], forRecording recordingID: UUID) {
        let draftText = transcriptSegments
            .filter { $0.recordingID == recordingID && $0.effectiveOrigin == .liveDraft }
            .map(\.text)
            .joined(separator: " ")
        retainLiveDraftSnapshot(for: recordingID)
        replaceSegmentsForRecording(recordingID: recordingID, with: segments)

        let finalText = segments.map(\.text).joined(separator: " ")
        let key = recordingID.uuidString
        if draftText.isEmpty || draftText == finalText {
            retainedLiveDraftByRecording?.removeValue(forKey: key)
            if retainedLiveDraftByRecording?.isEmpty ?? true { retainedLiveDraftByRecording = nil }
        }
    }

    /// Restores the retained live-draft segments for `recordingID`, discarding
    /// that recording's final segments.
    mutating func revertFinalPass(for recordingID: UUID) {
        let key = recordingID.uuidString
        guard let draft = retainedLiveDraftByRecording?[key] else { return }
        transcriptSegments.removeAll {
            $0.recordingID == recordingID && $0.effectiveOrigin == .final
        }
        transcriptSegments.append(contentsOf: draft)
        transcriptState = .liveDraft
        transcriptStatusMessage = nil
        retainedLiveDraftByRecording?.removeValue(forKey: key)
        if retainedLiveDraftByRecording?.isEmpty ?? true { retainedLiveDraftByRecording = nil }
        updatedAt = Date()
    }

    /// Accepts the final pass for `recordingID`, clearing the retained draft.
    mutating func acceptFinalPass(for recordingID: UUID) {
        let key = recordingID.uuidString
        guard retainedLiveDraftByRecording?.removeValue(forKey: key) != nil else { return }
        if retainedLiveDraftByRecording?.isEmpty ?? true { retainedLiveDraftByRecording = nil }
        updatedAt = Date()
    }

    // MARK: - Speaker ledger

    var effectiveSpeakers: [MeetingSpeakerIdentity] {
        speakers ?? []
    }

    /// Resolves a segment's display label: the user-assigned Speaker name if
    /// present, otherwise the capture-source proxy label, otherwise "Speaker".
    func resolvedSpeakerLabel(for segment: TranscriptSegment) -> String {
        if let speakerID = segment.speakerID,
           let speaker = effectiveSpeakers.first(where: { $0.id == speakerID }) {
            return speaker.displayName
        }
        return segment.speakerDisplayName ?? "Speaker"
    }

    mutating func renameSpeaker(id: UUID, to displayName: String) {
        guard let index = effectiveSpeakers.firstIndex(where: { $0.id == id }) else { return }
        if speakers == nil { speakers = [] }
        speakers?[index].displayName = displayName
        updatedAt = Date()
    }

    /// Merges `sourceID` into `targetID`: all turns referencing `sourceID` are
    /// re-pointed to `targetID`, and `sourceID` is removed from the ledger.
    mutating func mergeSpeakers(from sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID else { return }
        let speakerIDs = Set(effectiveSpeakers.map(\.id))
        guard speakerIDs.contains(sourceID), speakerIDs.contains(targetID) else { return }
        for index in transcriptSegments.indices where transcriptSegments[index].speakerID == sourceID {
            transcriptSegments[index].speakerID = targetID
        }
        speakers?.removeAll { $0.id == sourceID }
        updatedAt = Date()
    }

    /// Splits a speaker: creates a new Speaker and re-points the given turns to
    /// it. Returns the new speaker's id, or nil if no turns were provided.
    @discardableResult
    mutating func splitSpeaker(from sourceID: UUID, named displayName: String, turnSegmentIDs: [UUID]) -> UUID? {
        guard effectiveSpeakers.contains(where: { $0.id == sourceID }) else { return nil }
        return assignNewSpeaker(named: displayName, turnSegmentIDs: turnSegmentIDs)
    }

    /// Assigns the given turns to a newly named meeting-local Speaker. This is
    /// used when a transcript row only has a capture-source proxy label.
    @discardableResult
    mutating func assignSpeaker(named displayName: String, turnSegmentIDs: [UUID]) -> UUID? {
        return assignNewSpeaker(named: displayName, turnSegmentIDs: turnSegmentIDs)
    }

    @discardableResult
    private mutating func assignNewSpeaker(named displayName: String, turnSegmentIDs: [UUID]) -> UUID? {
        guard !turnSegmentIDs.isEmpty else { return nil }
        let newSpeaker = MeetingSpeakerIdentity(displayName: displayName)
        if speakers == nil { speakers = [] }
        speakers?.append(newSpeaker)
        let turnIDSet = Set(turnSegmentIDs)
        for index in transcriptSegments.indices where turnIDSet.contains(transcriptSegments[index].id) {
            transcriptSegments[index].speakerID = newSpeaker.id
        }
        updatedAt = Date()
        return newSpeaker.id
    }

    /// Returns a recovered copy of this note after a launch-time discovery pass,
    /// translating an interrupted capture (a recording still marked `recording`)
    /// or an interrupted final pass into a calm, actionable `finalizationFailed`
    /// state. Audio and live-draft transcript are never discarded here.
    func recoveredAfterInterruptedCapture(usableRecordingIDs: Set<UUID>? = nil) -> MeetingNote {
        var recovered = self
        let interruptedStates: Set<MeetingRecordingState> = [.recording, .recorded, .finalizing]
        if let usableRecordingIDs {
            let unavailableInterruptedIDs = Set(
                recovered.effectiveAudioRecordings.compactMap { recording in
                    interruptedStates.contains(recording.effectiveState) && !usableRecordingIDs.contains(recording.id)
                        ? recording.id
                        : nil
                }
            )
            if !unavailableInterruptedIDs.isEmpty {
                recovered.audioRecordings?.removeAll { unavailableInterruptedIDs.contains($0.id) }
                let hasUsableInterruptedRecording = recovered.effectiveAudioRecordings.contains {
                    interruptedStates.contains($0.effectiveState) && usableRecordingIDs.contains($0.id)
                }
                if !hasUsableInterruptedRecording {
                    recovered.transcriptState = recovered.transcriptSegments.isEmpty ? .empty : .liveDraft
                    recovered.transcriptStatusMessage = recovered.transcriptSegments.isEmpty
                        ? "Recording was interrupted before audio could be saved."
                        : "Recording was interrupted before audio could be saved. Your draft transcript is still available."
                    return recovered
                }
            }
        }

        let recordings = recovered.effectiveAudioRecordings
        let hasRecordingInProgress = recordings.contains { $0.effectiveState == .recording }
        let interruptedMidCaptureMessage = "Recording was interrupted. Your audio and draft transcript are saved — run the final transcript when ready."

        switch recovered.effectiveTranscriptState {
        case .liveDraft, .finalizing:
            if recordings.isEmpty {
                recovered.transcriptState = recovered.transcriptSegments.isEmpty ? .empty : .liveDraft
                recovered.transcriptStatusMessage = nil
            } else if hasRecordingInProgress {
                recovered.transcriptState = .finalizationFailed
                recovered.transcriptStatusMessage = interruptedMidCaptureMessage
            } else {
                recovered.transcriptState = .finalizationFailed
                recovered.transcriptStatusMessage = "Final transcription was interrupted. Retry from the saved audio."
            }
        case .empty, .final, .finalizationFailed:
            if hasRecordingInProgress {
                recovered.transcriptState = .finalizationFailed
                recovered.transcriptStatusMessage = interruptedMidCaptureMessage
            }
        }
        if recovered.effectiveTranscriptState == .finalizationFailed {
            for index in recovered.effectiveAudioRecordings.indices
            where interruptedStates.contains(recovered.effectiveAudioRecordings[index].effectiveState) {
                recovered.audioRecordings?[index].state = .finalizationFailed
            }
        }
        return recovered
    }
}

enum TranscriptSpeaker: String, Codable, Sendable {
    case user
    case systemAudio
    case mixedAudio
    case unknown

    var displayName: String {
        switch self {
        case .user:
            return "You"
        case .systemAudio:
            return "System Audio"
        case .mixedAudio:
            return "Mixed Audio"
        case .unknown:
            return "Speaker"
        }
    }
}

/// An editable, per-meeting speaker identity. Distinct from the
/// `TranscriptSpeaker` capture-source proxy: a proxy is an inferred label
/// derived from the audio source, while a `MeetingSpeakerIdentity` is a
/// user-assigned (or user-corrected) person the user can rename, merge, or split.
struct MeetingSpeakerIdentity: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var displayName: String

    init(id: UUID = UUID(), displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speaker: TranscriptSpeaker?
    var captureSource: MeetingCaptureSource?
    var createdAt: Date
    var origin: TranscriptSegmentOrigin?
    var recordingID: UUID?
    var speakerID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: TranscriptSpeaker? = nil,
        captureSource: MeetingCaptureSource? = nil,
        createdAt: Date = Date(),
        origin: TranscriptSegmentOrigin? = nil,
        recordingID: UUID? = nil,
        speakerID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.captureSource = captureSource
        self.createdAt = createdAt
        self.origin = origin
        self.recordingID = recordingID
        self.speakerID = speakerID
    }

    var speakerDisplayName: String? {
        speaker?.displayName
    }

    var effectiveOrigin: TranscriptSegmentOrigin {
        origin ?? .final
    }

    func labeled(speaker: TranscriptSpeaker, captureSource: MeetingCaptureSource) -> TranscriptSegment {
        var segment = self
        segment.speaker = speaker
        segment.captureSource = captureSource
        return segment
    }

    func attributed(origin: TranscriptSegmentOrigin, recordingID: UUID?) -> TranscriptSegment {
        var segment = self
        segment.origin = origin
        segment.recordingID = recordingID
        return segment
    }
}

struct MeetingSummary: Codable, Equatable, Sendable {
    var overview: String
    var decisions: [String]
    var actionItems: [MeetingActionItem]
    var openQuestions: [String]
    var followUpDraft: String
    var generatedAt: Date

    init(
        overview: String = "",
        decisions: [String] = [],
        actionItems: [MeetingActionItem] = [],
        openQuestions: [String] = [],
        followUpDraft: String = "",
        generatedAt: Date = Date()
    ) {
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.followUpDraft = followUpDraft
        self.generatedAt = generatedAt
    }
}

enum MeetingSummaryProviderOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case localHeuristic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localHeuristic:
            return "Local Heuristic"
        }
    }
}

struct MeetingSummaryConfiguration: Codable, Equatable, Sendable {
    var provider: MeetingSummaryProviderOption

    init(provider: MeetingSummaryProviderOption = .localHeuristic) {
        self.provider = provider
    }
}

struct MeetingActionItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var owner: String?
    var dueDate: Date?
    var isComplete: Bool

    init(
        id: UUID = UUID(),
        text: String,
        owner: String? = nil,
        dueDate: Date? = nil,
        isComplete: Bool = false
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.isComplete = isComplete
    }
}
