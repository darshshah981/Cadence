import AppKit
import SwiftUI

private func meetingAccessibilityIdentifierSuffix(_ rawValue: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let characters = rawValue.unicodeScalars.map { scalar -> Character in
        allowedCharacters.contains(scalar) ? Character(scalar) : "-"
    }
    let suffix = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return suffix.isEmpty ? "unknown" : suffix
}

@MainActor
final class MeetingNotesWindowController: NSWindowController {
    private var hostingController: NSHostingController<MeetingNotesView>?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadence"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 620)
        self.init(window: window)
    }

    func show(appModel: AppModel) {
        if hostingController == nil {
            let view = MeetingNotesView(appModel: appModel)
            let hostingController = NSHostingController(rootView: view)
            self.hostingController = hostingController
            window?.contentViewController = hostingController
        }

        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MeetingNotesView: View {
    @ObservedObject var appModel: AppModel
    var presentation: MeetingNotesPresentation = .standalone
    var onBack: (() -> Void)?
    @State private var searchText = ""

    private var displayedNotes: [MeetingNote] {
        appModel.filteredMeetingNotes(query: searchText)
    }

    private var selectedNote: MeetingNote? {
        appModel.selectedMeetingNote
    }

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                NavigationSplitView {
                    meetingList
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    detailView
                }
            case .embedded:
                detailView
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(FlowTheme.background)
        .toolbar {
            if presentation == .standalone {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appModel.createMeetingNote(openWindow: false)
                    } label: {
                        Label("New Meeting Note", systemImage: "square.and.pencil")
                    }
                    .accessibilityLabel("New meeting note")
                    .accessibilityIdentifier("meeting-notes-toolbar-new-note")
                }
            }
        }
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            GoogleCalendarConnectionCard(
                state: appModel.googleCalendarConnectionState,
                upcomingMeetings: appModel.upcomingCalendarMeetings,
                detectedMeeting: appModel.detectedCalendarMeeting,
                onConnect: appModel.connectGoogleCalendar,
                onRefresh: appModel.refreshUpcomingCalendarMeetingsFromUI,
                onDisconnect: appModel.disconnectGoogleCalendar,
                onStartDetectedMeeting: appModel.startDetectedCalendarMeetingCapture
            )
            .padding(12)
            .accessibilityIdentifier("meeting-notes-calendar-card")

            List(displayedNotes, selection: meetingSelectionBinding) { note in
                MeetingNoteRow(note: note, captureSession: appModel.meetingCaptureSession)
                    .tag(note.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar)
            .accessibilityIdentifier("meeting-notes-list")

            CadenceActionButton(title: "New Meeting Note", role: .primary, accessibilityIdentifier: "meeting-notes-new-note-button") {
                appModel.createMeetingNote(openWindow: false)
            }
            .controlSize(.large)
            .accessibilityLabel("New meeting note")
            .padding(12)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if !appModel.recoverableOrphanedRecordings.isEmpty {
                MeetingRecoverySection(
                    recordings: appModel.recoverableOrphanedRecordings,
                    onKeep: appModel.keepOrphanedRecording,
                    onDiscard: appModel.discardOrphanedRecording
                )
            }

            if let selectedNote {
                MeetingNoteEditor(
                    note: selectedNote,
                    permissions: appModel.permissions,
                    captureState: appModel.systemAudioCaptureState,
                    captureSource: appModel.meetingCaptureSource,
                    captureSession: appModel.meetingCaptureSession,
                    captureLevel: appModel.systemAudioCaptureLevel,
                    capturedFrameCount: appModel.systemAudioCapturedFrameCount,
                    onSelectCaptureSource: appModel.setMeetingCaptureSource,
                    title: Binding(
                        get: { selectedNote.title },
                        set: { appModel.updateMeetingNote(id: selectedNote.id, title: $0, userNotes: nil) }
                    ),
                    userNotes: Binding(
                        get: { selectedNote.userNotes },
                        set: { appModel.updateMeetingNote(id: selectedNote.id, title: nil, userNotes: $0) }
                    ),
                    onDelete: {
                        appModel.deleteMeetingNote(id: selectedNote.id)
                    },
                    onToggleSystemAudioCapture: {
                        appModel.toggleMeetingCaptureForSelectedMeeting()
                    },
                    onStopCapture: {
                        appModel.stopMeetingCapture()
                    },
                    onSelectActiveCaptureNote: {
                        appModel.selectActiveMeetingCaptureNote()
                    },
                    onRequestScreenRecording: {
                        appModel.requestMeetingCaptureSourcePermissions()
                    },
                    onGenerateSummary: {
                        appModel.generateSummaryForSelectedMeetingNote()
                    },
                    onRetryFinalTranscription: { recordingID in
                        appModel.retryFinalTranscriptionPass(noteID: selectedNote.id, recordingID: recordingID)
                    },
                    onRevertFinalPass: { recordingID in
                        appModel.revertFinalPass(noteID: selectedNote.id, recordingID: recordingID)
                    },
                    onAcceptFinalPass: { recordingID in
                        appModel.acceptFinalPass(noteID: selectedNote.id, recordingID: recordingID)
                    },
                    onRenameSpeaker: { speakerID, displayName in
                        appModel.renameSpeaker(noteID: selectedNote.id, speakerID: speakerID, displayName: displayName)
                    },
                    onMergeSpeakers: { sourceID, targetID in
                        appModel.mergeSpeakers(noteID: selectedNote.id, sourceID: sourceID, targetID: targetID)
                    },
                    onSplitSpeaker: { sourceID, displayName, segmentIDs in
                        appModel.splitSpeaker(noteID: selectedNote.id, sourceID: sourceID, displayName: displayName, segmentIDs: segmentIDs)
                    },
                    onAssignSpeaker: { displayName, segmentIDs in
                        appModel.assignSpeaker(noteID: selectedNote.id, displayName: displayName, segmentIDs: segmentIDs)
                    },
                    onCopyMarkdown: {
                        appModel.copySelectedMeetingNoteMarkdown()
                    },
                    onExportMarkdown: {
                        appModel.exportSelectedMeetingNoteMarkdown()
                    },
                    onBack: onBack
                )
            } else {
                EmptyMeetingSelectionView {
                    appModel.createMeetingNote(openWindow: false)
                }
            }
        }
    }

    private var meetingSelectionBinding: Binding<UUID?> {
        Binding(
            get: { appModel.selectedMeetingNoteID },
            set: { appModel.selectMeetingNote(id: $0) }
        )
    }
}

enum MeetingNotesPresentation: Equatable {
    case standalone
    case embedded
}

private enum MeetingLayout {
    static let editorMaxWidth: CGFloat = 720
    static let editorTopPadding: CGFloat = 24
    static let editorHorizontalPadding: CGFloat = 52
    static let editorBottomPadding: CGFloat = 56
    static let askDockBottomPadding: CGFloat = 118
}

private struct EmptyMeetingSelectionView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(FlowTheme.textTertiary)

            VStack(spacing: 6) {
                Text("No meeting selected")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text("Create a note or choose one from Recent.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
            }

            CadenceActionButton(title: "New Meeting Note", role: .primary, accessibilityIdentifier: "empty-meeting-new-note-button") {
                onCreate()
            }
            .controlSize(.large)
            .accessibilityLabel("New meeting note")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.background)
    }
}

private struct MeetingRecoverySection: View {
    let recordings: [OrphanedMeetingRecording]
    let onKeep: (OrphanedMeetingRecording) -> Void
    let onDiscard: (OrphanedMeetingRecording) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .foregroundStyle(FlowTheme.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording recovery")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Cadence found an interrupted recording file that is not attached to a meeting note. Keep it on this Mac or discard it.")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                }
            }

            ForEach(Array(recordings.enumerated()), id: \.element.id) { index, recording in
                HStack(spacing: 10) {
                    Text(recordings.count == 1 ? "Interrupted recording" : "Interrupted recording \(index + 1)")
                        .font(.system(size: 12, weight: .medium))

                    Spacer()

                    CadenceActionButton(title: "Keep", role: .secondary, accessibilityIdentifier: "meeting-recovery-keep-\(recording.id.uuidString)") {
                        onKeep(recording)
                    }
                    .controlSize(.small)

                    CadenceActionButton(title: "Discard", role: .destructive, accessibilityIdentifier: "meeting-recovery-discard-\(recording.id.uuidString)") {
                        onDiscard(recording)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(FlowTheme.elevated)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-recovery-section")
    }
}

private struct GoogleCalendarConnectionCard: View {
    let state: GoogleCalendarConnectionState
    let upcomingMeetings: [GoogleCalendarEvent]
    let detectedMeeting: GoogleCalendarEvent?
    let onConnect: () -> Void
    let onRefresh: () -> Void
    let onDisconnect: () -> Void
    let onStartDetectedMeeting: () -> Void

    private var nextMeeting: GoogleCalendarEvent? {
        detectedMeeting ?? upcomingMeetings.first { $0.isMeetingCandidate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.isConnected ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                    .foregroundStyle(state.isConnected ? FlowTheme.success : FlowTheme.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Text(stateDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if let nextMeeting {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nextMeeting.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .lineLimit(1)

                    Text(nextMeeting.startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                if detectedMeeting != nil {
                    CadenceActionButton(title: "Start capture", role: .primary, action: onStartDetectedMeeting)
                        .controlSize(.small)
                        .accessibilityLabel("Start capture for detected meeting")
                        .accessibilityIdentifier("calendar-detected-start-capture")
                } else if state.isConnected {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh calendar")
                    .accessibilityLabel("Refresh calendar")
                    .accessibilityIdentifier("calendar-refresh-button")

                    Button(action: onDisconnect) {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .help("Disconnect calendar")
                    .accessibilityLabel("Disconnect calendar")
                    .accessibilityIdentifier("calendar-disconnect-button")
                } else if state.isConfigured {
                    CadenceActionButton(title: "Continue with Google", role: .primary, action: onConnect)
                        .controlSize(.small)
                        .accessibilityLabel("Sign in with Google")
                        .accessibilityIdentifier("calendar-sign-in-button")
                }
            }
        }
        .padding(10)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stateTitle)
        .accessibilityValue(stateDetail)
        .accessibilityIdentifier("google-calendar-connection-card")
    }

    private var stateTitle: String {
        if state.isConnected {
            return "Google Calendar connected"
        }
        if state.isConfigured {
            return "Google Calendar ready"
        }
        return "Google Sign-In unavailable"
    }

    private var stateDetail: String {
        if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if state.isConnected {
            return upcomingMeetings.isEmpty ? "No upcoming meetings found" : "\(upcomingMeetings.count) upcoming events"
        }
        if state.isConfigured {
            return "Sign in to detect upcoming meetings."
        }
        return "Google Sign-In is not configured in this build."
    }
}

private struct MeetingNoteRow: View {
    let note: MeetingNote
    let captureSession: MeetingCaptureSessionSummary?

    private var isCaptureTarget: Bool {
        captureSession?.isTargeting(noteID: note.id) == true
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: rowSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCaptureTarget ? rowTint : FlowTheme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(rowDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(isCaptureTarget ? rowTint : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting note \(note.displayTitle)")
        .accessibilityValue(rowDetail)
        .accessibilityIdentifier("meeting-note-row-\(note.id.uuidString)")
    }

    private var rowDetail: String {
        if let captureSession, isCaptureTarget {
            return "\(captureSession.phase.displayName) • \(captureSession.source.displayName)"
        }

        switch note.effectiveTranscriptState {
        case .liveDraft:
            return "Live draft"
        case .finalizing:
            return "Finalizing"
        case .finalizationFailed:
            return "Final pass failed"
        case .empty, .final:
            return note.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    private var rowSymbolName: String {
        if let captureSession, isCaptureTarget {
            switch captureSession.phase {
            case .starting:
                return "dot.radiowaves.left.and.right"
            case .recording:
                return "waveform"
            case .finalizing:
                return "text.bubble"
            }
        }

        switch note.effectiveTranscriptState {
        case .liveDraft:
            return "waveform"
        case .finalizing:
            return "hourglass"
        case .finalizationFailed:
            return "exclamationmark.triangle"
        case .empty, .final:
            return "doc.text"
        }
    }

    private var rowTint: Color {
        if let captureSession, isCaptureTarget {
            switch captureSession.phase {
            case .starting, .finalizing:
                return FlowTheme.teal
            case .recording:
                return FlowTheme.accent
            }
        }

        switch note.effectiveTranscriptState {
        case .liveDraft:
            return FlowTheme.accent
        case .finalizing:
            return FlowTheme.teal
        case .finalizationFailed:
            return FlowTheme.error
        case .empty, .final:
            return FlowTheme.textTertiary
        }
    }
}

private enum MeetingWorkspaceMode: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case summary = "Summary"
    case transcript = "Transcript"
    case ask = "Ask"
    case reports = "Reports"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .notes:
            return "square.and.pencil"
        case .summary:
            return "doc.text.magnifyingglass"
        case .transcript:
            return "text.bubble"
        case .ask:
            return "sparkle.magnifyingglass"
        case .reports:
            return "doc.richtext"
        }
    }
}

private enum MeetingReportTemplate: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case decisionLog = "Decision Log"
    case actionPlan = "Action Plan"
    case followUpEmail = "Follow-up Email"

    var id: String { rawValue }
}

private struct MeetingNoteEditor: View {
    let note: MeetingNote
    let permissions: PermissionsSnapshot
    let captureState: SystemAudioCaptureState
    let captureSource: MeetingCaptureSource
    let captureSession: MeetingCaptureSessionSummary?
    let captureLevel: Double
    let capturedFrameCount: Int
    let onSelectCaptureSource: (MeetingCaptureSource) -> Void
    @Binding var title: String
    @Binding var userNotes: String
    let onDelete: () -> Void
    let onToggleSystemAudioCapture: () -> Void
    let onStopCapture: () -> Void
    let onSelectActiveCaptureNote: () -> Void
    let onRequestScreenRecording: () -> Void
    let onGenerateSummary: () -> Void
    let onRetryFinalTranscription: (UUID) -> Void
    let onRevertFinalPass: (UUID) -> Void
    let onAcceptFinalPass: (UUID) -> Void
    let onRenameSpeaker: (UUID, String) -> Void
    let onMergeSpeakers: (UUID, UUID) -> Void
    let onSplitSpeaker: (UUID, String, [UUID]) -> Void
    let onAssignSpeaker: (String, [UUID]) -> Void
    let onCopyMarkdown: () -> Void
    let onExportMarkdown: () -> Void
    let onBack: (() -> Void)?
    @State private var selectedMode: MeetingWorkspaceMode = .notes
    @State private var selectedReportTemplate: MeetingReportTemplate = .standard
    @State private var transcriptSearchText = ""
    @State private var askQuestion = ""
    @State private var askAnswer: MeetingAskAnswer?
    @State private var isTranscriptSourceExpanded = false
    @State private var speakerEditRequest: SpeakerEditRequest?
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if isBackgroundCaptureVisible {
                        backgroundCaptureBanner
                    } else {
                        captureBar
                    }

                    workspaceTabs

                    switch selectedMode {
                    case .notes:
                        notesFirstWorkspace
                    case .summary:
                        summarySection
                    case .transcript:
                        transcriptSection
                    case .ask:
                        askSection
                    case .reports:
                        reportsSection
                    }
                }
                .frame(maxWidth: MeetingLayout.editorMaxWidth, alignment: .topLeading)
                .padding(.top, MeetingLayout.editorTopPadding)
                .padding(.bottom, isAskDockVisible ? MeetingLayout.askDockBottomPadding : MeetingLayout.editorBottomPadding)
                .padding(.horizontal, MeetingLayout.editorHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(FlowTheme.background)

            if isAskDockVisible {
                askDock
                    .padding(.horizontal, MeetingLayout.editorHorizontalPadding)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(FlowTheme.background)
        .onChange(of: note.id) {
            transcriptSearchText = ""
            askQuestion = ""
            askAnswer = nil
            isTranscriptSourceExpanded = false
            selectedMode = .notes
        }
        .sheet(item: $speakerEditRequest) { request in
            SpeakerNameSheet(
                request: request,
                onCancel: {
                    speakerEditRequest = nil
                },
                onCommit: { displayName in
                    applySpeakerEdit(request, displayName: displayName)
                    speakerEditRequest = nil
                }
            )
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Note", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the note and its saved recordings from Cadence.")
        }
    }

    private var isAskDockVisible: Bool {
        selectedMode == .ask
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("All notes")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(FlowTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to all notes")
                .accessibilityIdentifier("meeting-note-back-button")
            }

            HStack(alignment: .top, spacing: 12) {
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(2)
                    .accessibilityLabel("Meeting title")
                    .accessibilityIdentifier("meeting-note-title-field")

                Spacer()

                HStack(spacing: 6) {
                    MeetingInlineButton(
                        title: "Copy",
                        systemImage: "doc.on.doc",
                        accessibilityIdentifier: "meeting-note-copy-markdown-button",
                        action: onCopyMarkdown
                    )

                    Menu {
                        Button {
                            onExportMarkdown()
                        } label: {
                            Label("Export Markdown", systemImage: "square.and.arrow.down")
                        }
                        .accessibilityIdentifier("meeting-note-export-markdown-button")

                        Divider()

                        Button(role: .destructive) {
                            isDeleteConfirmationPresented = true
                        } label: {
                            Label("Delete Note…", systemImage: "trash")
                        }
                        .disabled(isCaptureTarget && captureState.isCaptureBusy)
                        .accessibilityIdentifier("meeting-note-delete-button")
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(FlowTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(FlowTheme.border.opacity(0.8), lineWidth: 1)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More note actions")
                    .accessibilityIdentifier("meeting-note-actions-menu")
                }
            }

            ViewThatFits(in: .horizontal) {
                metadataChips

                stackedMetadataChips
            }
        }
    }

    private var metadataChips: some View {
        HStack(spacing: 8) {
            metadataDateChip
            metadataWordChip
            metadataTranscriptChip
            metadataStateChip
            metadataCaptureChip
        }
    }

    private var stackedMetadataChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                metadataDateChip
                metadataWordChip
            }
            HStack(spacing: 8) {
                metadataTranscriptChip
                metadataStateChip
                metadataCaptureChip
            }
        }
    }

    private var metadataDateChip: some View {
        MeetingMetaChip(
            text: note.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
            systemImage: "clock"
        )
    }

    private var metadataWordChip: some View {
        MeetingMetaChip(
            text: "\(meetingWordCount) words",
            systemImage: "text.word.spacing"
        )
    }

    private var metadataTranscriptChip: some View {
        MeetingMetaChip(
            text: "\(transcriptRuns.count) transcript \(transcriptRuns.count == 1 ? "block" : "blocks")",
            systemImage: "quote.bubble"
        )
    }

    private var metadataStateChip: some View {
        MeetingMetaChip(
            text: note.effectiveTranscriptState.displayName,
            systemImage: transcriptStateSymbolName,
            tint: transcriptStateTint
        )
    }

    @ViewBuilder
    private var metadataCaptureChip: some View {
        if isCaptureTarget, let captureSession {
            MeetingMetaChip(
                text: captureSession.phase.displayName,
                systemImage: captureSession.phase == .recording ? "waveform" : "text.bubble",
                tint: captureTint
            )
        }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(MeetingWorkspaceMode.allCases) { mode in
                    MeetingModePill(mode: mode, isSelected: selectedMode == mode) {
                        selectedMode = mode
                    }
                }
            }

            Spacer()

            MeetingInlineButton(
                title: visibleSummary == nil ? "Generate summary" : "Regenerate summary",
                systemImage: "sparkles",
                isPrimary: visibleSummary == nil,
                isDisabled: !hasSummarySourceContent,
                accessibilityIdentifier: "meeting-summary-generate-button"
            ) {
                onGenerateSummary()
                selectedMode = .summary
            }
        }
        .frame(minHeight: 34)
    }

    private var captureSourceMenu: some View {
        Menu {
            ForEach(MeetingCaptureSource.allCases) { source in
                Button {
                    onSelectCaptureSource(source)
                } label: {
                    if source == captureSource {
                        Label(source.displayName, systemImage: "checkmark")
                    } else {
                        Text(source.displayName)
                    }
                }
                .accessibilityIdentifier("capture-source-option-\(source.rawValue)")
            }
        } label: {
            HStack(spacing: 7) {
                Text(captureSource.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
            .foregroundStyle(captureState.isCaptureBusy ? FlowTheme.textTertiary : FlowTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(FlowTheme.border.opacity(0.8), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(captureState.isCaptureBusy)
        .accessibilityLabel("Capture source")
        .accessibilityValue(captureSource.displayName)
        .accessibilityIdentifier("capture-source-menu")
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingSectionTitle(title: "Notes", detail: "Write while Cadence captures the call in the background.")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $userNotes)
                    .font(.system(size: 14))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Meeting notes")
                    .accessibilityIdentifier("meeting-notes-editor")

                if userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Notes")
                        .font(.system(size: 14))
                        .foregroundStyle(FlowTheme.placeholder)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 190)
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.border, lineWidth: 1)
            )
        }
    }

    private var notesFirstWorkspace: some View {
        VStack(alignment: .leading, spacing: 24) {
            notesSection
            summarySection
            transcriptSourceDisclosure
        }
    }

    private var transcriptSourceDisclosure: some View {
        DisclosureGroup(isExpanded: $isTranscriptSourceExpanded) {
            transcriptSection
                .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
                Text("Transcript source")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text("\(transcriptRuns.count) \(transcriptRuns.count == 1 ? "block" : "blocks")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(FlowTheme.subtle, in: Capsule())
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .font(.system(size: 12.5))
        .padding(12)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("transcript-source-disclosure")
    }

    private var backgroundCaptureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: backgroundCaptureSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(backgroundCaptureTint)
                .frame(width: 28, height: 28)
                .background(backgroundCaptureTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(backgroundCaptureTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(1)

                Text(backgroundCaptureDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            MeetingInlineButton(title: "Go to note", systemImage: "arrow.turn.up.right") {
                onSelectActiveCaptureNote()
            }

            MeetingInlineButton(
                title: "Stop",
                systemImage: "stop.fill",
                isPrimary: true,
                isDisabled: captureSession?.phase != .recording,
                accessibilityIdentifier: "background-capture-stop-button"
            ) {
                onStopCapture()
            }
        }
        .padding(12)
        .background(FlowTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.accentBorder.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(backgroundCaptureTitle)
        .accessibilityValue(backgroundCaptureDetail)
        .accessibilityIdentifier("background-capture-banner")
    }

    private var captureBar: some View {
        HStack(alignment: .center, spacing: 9) {
            if selectedSourcePermissionsGranted {
                MeetingInlineButton(
                    title: capturePrimaryButtonTitle,
                    systemImage: capturePrimarySystemImage,
                    isPrimary: true,
                    isDisabled: captureState == .starting || captureState == .stopping,
                    accessibilityIdentifier: "meeting-recording-toggle"
                ) {
                    onToggleSystemAudioCapture()
                }
            } else {
                MeetingInlineButton(title: "Allow Access", systemImage: "lock.open", accessibilityIdentifier: "meeting-recording-allow-access") {
                    onRequestScreenRecording()
                }
            }

            captureSourceMenu

            if let captureStatusText {
                Text(captureStatusText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(captureTint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controls")
        .accessibilityValue(captureStatusText ?? captureSource.displayName)
        .accessibilityIdentifier("meeting-recording-controls")
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeetingSectionTitle(
                title: "Summary",
                detail: note.effectiveTranscriptState == .finalizing ? "Final transcript is still running." : nil
            )

            if let summary = visibleSummary {
                Text(summary.overview)
                    .font(.system(size: 16))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                SummaryMetricStrip(summary: summary, transcriptCount: transcriptRuns.count)

                summaryList(title: "Decisions", items: summary.decisions)
                summaryList(title: "Action Items", items: summary.actionItems.map { item in
                    if let owner = item.owner, !owner.isEmpty {
                        return "\(owner): \(item.text)"
                    }
                    return item.text
                })
                summaryList(title: "Open Questions", items: summary.openQuestions)
            } else {
                EmptyWorkspaceState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "No summary yet",
                    detail: note.transcriptSegments.isEmpty
                        ? "Start recording or write notes, then generate a recap."
                        : "Generate a structured recap from your notes and transcript."
                )
            }
        }
    }

    @ViewBuilder
    private func summaryList(title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .textCase(.uppercase)

                ForEach(items, id: \.self) { item in
                    Text("- \(item)")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeetingSectionTitle(title: "Transcript", detail: transcriptStatusDetail)

            ForEach(note.finalPassChallenges) { challenge in
                finalPassChallengeRow(challenge)
            }

            HStack(spacing: 10) {
                Label("Search transcript", systemImage: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textTertiary)

                TextField("Find words, names, or decisions", text: $transcriptSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Search transcript")
                    .accessibilityIdentifier("transcript-search-field")

                if !transcriptSearchText.isEmpty {
                    Button {
                        transcriptSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FlowTheme.textTertiary)
                    .help("Clear search")
                    .accessibilityLabel("Clear transcript search")
                    .accessibilityIdentifier("transcript-search-clear-button")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.border, lineWidth: 1)
            )

            if collapsedTranscriptCount > 0 {
                Text("\(collapsedTranscriptCount) repeated live fragments collapsed")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowTheme.textTertiary)
            }

            if filteredTranscriptRuns.isEmpty {
                EmptyWorkspaceState(
                    systemImage: "text.bubble",
                    title: transcriptSearchText.isEmpty ? "No transcript yet" : "No matching transcript",
                    detail: transcriptSearchText.isEmpty
                        ? "Start capture to create a live draft, then Cadence will replace it with the final pass."
                        : "Try a different word or clear the search field."
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredTranscriptRuns) { run in
                        TranscriptRunRow(
                            run: run,
                            speakers: note.effectiveSpeakers,
                            highlight: transcriptSearchText,
                            onRename: { requestRenameSpeaker(for: run) },
                            onMerge: { targetID in
                                guard let sourceID = run.speakerID else { return }
                                onMergeSpeakers(sourceID, targetID)
                            },
                            onSplit: { requestSplitSpeaker(for: run) },
                            onAssign: { requestAssignSpeaker(for: run) }
                        )
                    }
                }
            }
        }
    }

    private func finalPassChallengeRow(_ challenge: MeetingFinalPassChallenge) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: challenge.kind == .failure ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(challenge.kind == .failure
                    ? "Final pass could not improve this recording."
                    : "Final transcript replaced your draft.")
                    .font(.system(size: 12, weight: .semibold))

                if let peek = challenge.draftPeek {
                    Text("Draft: \(peek)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.textTertiary)
                        .lineLimit(1)
                } else if challenge.kind == .failure {
                    Text("Retry the final pass from the saved recording when ready.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowTheme.textTertiary)
                }
            }

            Spacer()

            Button("Retry") {
                onRetryFinalTranscription(challenge.recordingID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("final-pass-retry-\(challenge.recordingID.uuidString)")

            if challenge.allowsRevertToDraft {
                Button("Revert") {
                    onRevertFinalPass(challenge.recordingID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("final-pass-revert-\(challenge.recordingID.uuidString)")

                Button("Keep") {
                    onAcceptFinalPass(challenge.recordingID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("final-pass-keep-\(challenge.recordingID.uuidString)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private func requestRenameSpeaker(for run: TranscriptRun) {
        guard let speakerID = run.speakerID else { return }
        speakerEditRequest = SpeakerEditRequest(
            title: "Rename speaker",
            detail: "Rename every turn currently labeled \(run.conversationSpeakerName).",
            placeholder: "Speaker name",
            initialName: run.conversationSpeakerName,
            confirmTitle: "Rename",
            action: .rename(speakerID: speakerID)
        )
    }

    private func requestSplitSpeaker(for run: TranscriptRun) {
        guard let speakerID = run.speakerID else { return }
        speakerEditRequest = SpeakerEditRequest(
            title: "Split this turn",
            detail: "Move this visible transcript turn into a new meeting-local speaker.",
            placeholder: "New speaker name",
            initialName: "",
            confirmTitle: "Split",
            action: .split(sourceID: speakerID, segmentIDs: run.segmentIDs)
        )
    }

    private func requestAssignSpeaker(for run: TranscriptRun) {
        speakerEditRequest = SpeakerEditRequest(
            title: "Name speaker",
            detail: "Assign this inferred transcript turn to a meeting-local speaker.",
            placeholder: "Speaker name",
            initialName: "",
            confirmTitle: "Name",
            action: .assign(segmentIDs: run.segmentIDs)
        )
    }

    private func applySpeakerEdit(_ request: SpeakerEditRequest, displayName: String) {
        switch request.action {
        case .rename(let speakerID):
            onRenameSpeaker(speakerID, displayName)
        case .split(let sourceID, let segmentIDs):
            onSplitSpeaker(sourceID, displayName, segmentIDs)
        case .assign(let segmentIDs):
            onAssignSpeaker(displayName, segmentIDs)
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            MeetingSectionTitle(
                title: "Ask this meeting",
                detail: "Answers use the current note, summary, and transcript."
            )

            if let askAnswer {
                MeetingAskAnswerView(answer: askAnswer)
            } else {
                EmptyWorkspaceState(
                    systemImage: "sparkle.magnifyingglass",
                    title: "Ask this meeting",
                    detail: "Try decisions, action items, open questions, or a keyword from the call.",
                    minHeight: 88
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
                    .textCase(.uppercase)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        askSuggestion("What decisions were made?")
                        askSuggestion("What are the action items?")
                        askSuggestion("What questions are still open?")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        askSuggestion("What decisions were made?")
                        askSuggestion("What are the action items?")
                        askSuggestion("What questions are still open?")
                    }
                }
            }
        }
    }

    private var reportsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                MeetingSectionTitle(
                    title: "Reports",
                    detail: "Generate reusable views from the same meeting record."
                )

                Spacer()

                reportTemplateMenu
            }

            let reportText = reportText(for: selectedReportTemplate)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(selectedReportTemplate.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Spacer()

                    MeetingInlineButton(title: "Copy", systemImage: "doc.on.doc") {
                        copyToPasteboard(reportText)
                    }
                }

                Text(reportText)
                    .font(.system(size: 14))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.border, lineWidth: 1)
            )
        }
    }

    private var reportTemplateMenu: some View {
        Menu {
            ForEach(MeetingReportTemplate.allCases) { template in
                Button {
                    selectedReportTemplate = template
                } label: {
                    if template == selectedReportTemplate {
                        Label(template.rawValue, systemImage: "checkmark")
                    } else {
                        Text(template.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedReportTemplate.rawValue)
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
            .foregroundStyle(FlowTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(FlowTheme.border.opacity(0.8), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var askDock: some View {
        let canSubmit = !askQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.textTertiary)

            TextField("Ask this meeting", text: $askQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(submitAskQuestion)
                .accessibilityLabel("Ask this meeting")
                .accessibilityIdentifier("meeting-ask-field")

            Button {
                submitAskQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(canSubmit ? FlowTheme.background : FlowTheme.textTertiary)
                    .background(canSubmit ? FlowTheme.textPrimary : FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Ask this meeting")
            .accessibilityLabel("Submit question")
            .accessibilityIdentifier("meeting-ask-submit-button")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
        .shadow(color: FlowTheme.textPrimary.opacity(0.08), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-ask-dock")
    }

    private var transcriptRuns: [TranscriptRun] {
        TranscriptRun.makeRuns(from: note)
    }

    private var meetingWordCount: Int {
        let noteWords = userNotes.split(whereSeparator: \.isWhitespace).count
        let transcriptWords = note.transcriptSegments.reduce(0) { count, segment in
            count + segment.text.split(whereSeparator: \.isWhitespace).count
        }
        return noteWords + transcriptWords
    }

    private var filteredTranscriptRuns: [TranscriptRun] {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcriptRuns }
        return transcriptRuns.filter {
            $0.text.localizedCaseInsensitiveContains(query) ||
                ($0.speakerDisplayName?.localizedCaseInsensitiveContains(query) == true) ||
                ($0.captureSource?.displayName.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var collapsedTranscriptCount: Int {
        transcriptRuns.reduce(0) { total, run in
            total + max(run.segmentCount - 1, 0)
        }
    }

    private var visibleSummary: MeetingSummary? {
        guard let summary = note.summary,
              !Self.isTranscriptionProblemText(summary.overview) else {
            return nil
        }
        return summary
    }

    private var hasSummarySourceContent: Bool {
        if !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return note.transcriptSegments.contains { segment in
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var transcriptStatusDetail: String? {
        if let message = note.transcriptStatusMessage,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        switch note.effectiveTranscriptState {
        case .liveDraft:
            return "Live draft"
        case .finalizing:
            return "Finalizing from saved audio"
        case .finalizationFailed:
            return "Live draft retained"
        case .final:
            return nil
        case .empty:
            return nil
        }
    }

    private static func isTranscriptionProblemText(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("whisper did not return any transcript text") ||
            normalized.contains("meeting transcription took too long") ||
            normalized.contains("no speech audio was captured") ||
            normalized.hasSuffix("has no meeting content yet.")
    }

    private var captureTitle: String {
        switch captureState {
        case .idle:
            return selectedSourcePermissionsGranted ? "\(captureSource.displayName) ready" : "\(captureSource.displayName) needs access"
        case .starting:
            return "Starting \(captureSource.displayName.lowercased())"
        case .capturing:
            return "Recording to this note"
        case .stopping:
            return "Closing recording"
        case .failed:
            return "\(captureSource.displayName) unavailable"
        }
    }

    private var captureDetail: String {
        switch captureState {
        case .idle:
            if selectedSourcePermissionsGranted {
                return captureSource.shortDescription
            }
            return missingPermissionDetail
        case .starting:
            return "Preparing the selected audio stream."
        case .capturing:
            return "\(captureSource.displayName) • level \(Int((captureLevel * 100).rounded()))% • \(capturedDurationDescription)"
        case .stopping:
            return capturedFrameCount > 0 ? "Saving audio from \(capturedDurationDescription)." : "Stopping capture."
        case .failed(let message):
            return message
        }
    }

    private var captureSymbolName: String {
        switch captureState {
        case .capturing:
            return "waveform"
        case .stopping:
            return "hourglass"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return selectedSourcePermissionsGranted ? sourceSymbolName : "lock.fill"
        }
    }

    private var captureTint: Color {
        switch captureState {
        case .capturing:
            return FlowTheme.accent
        case .stopping:
            return FlowTheme.teal
        case .failed:
            return FlowTheme.error
        case .starting:
            return FlowTheme.teal
        case .idle:
            return selectedSourcePermissionsGranted ? FlowTheme.success : FlowTheme.textTertiary
        }
    }

    private var selectedSourcePermissionsGranted: Bool {
        (!captureSource.requiresMicrophone || permissions.microphoneGranted) &&
            (!captureSource.requiresScreenRecording || permissions.screenRecordingGranted)
    }

    private var captureButtonTitle: String {
        switch captureState {
        case .starting:
            return "Starting"
        case .capturing:
            return "Stop"
        case .stopping:
            return "Finalizing"
        default:
            return note.transcriptSegments.isEmpty && note.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Start" : "Append"
        }
    }

    private var capturePrimaryButtonTitle: String {
        switch captureState {
        case .starting:
            return "Starting"
        case .capturing:
            return "Stop"
        case .stopping:
            return "Transcribing"
        default:
            return "Start Recording"
        }
    }

    private var capturePrimarySystemImage: String {
        switch captureState {
        case .capturing:
            return "stop.fill"
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .stopping:
            return "text.bubble"
        default:
            return "record.circle"
        }
    }

    private var captureStatusText: String? {
        switch captureState {
        case .idle:
            return selectedSourcePermissionsGranted ? nil : missingPermissionDetail
        case .starting:
            return "Preparing audio"
        case .capturing:
            return "\(capturedDurationDescription) captured"
        case .stopping:
            return "Creating final transcript"
        case .failed(let message):
            return message
        }
    }

    private var isCaptureTarget: Bool {
        captureSession?.isTargeting(noteID: note.id) == true
    }

    private var isBackgroundCaptureVisible: Bool {
        guard let captureSession else { return false }
        return !captureSession.isTargeting(noteID: note.id)
    }

    private var backgroundCaptureTitle: String {
        guard let captureSession else { return "Meeting capture active" }
        switch captureSession.phase {
        case .starting:
            return "Starting capture for \(captureSession.noteTitle)"
        case .recording:
            return "Recording to \(captureSession.noteTitle)"
        case .finalizing:
            return "Transcribing \(captureSession.noteTitle)"
        }
    }

    private var backgroundCaptureDetail: String {
        guard let captureSession else { return "" }
        switch captureSession.phase {
        case .starting:
            return "Preparing \(captureSession.source.displayName.lowercased())."
        case .recording:
            return "\(captureSession.source.displayName) • \(Self.durationDescription(frameCount: captureSession.capturedFrameCount)) captured"
        case .finalizing:
            return "Saving audio and creating the final transcript."
        }
    }

    private var backgroundCaptureSymbolName: String {
        guard let captureSession else { return "waveform" }
        switch captureSession.phase {
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .recording:
            return "waveform"
        case .finalizing:
            return "text.bubble"
        }
    }

    private var backgroundCaptureTint: Color {
        guard let captureSession else { return FlowTheme.accent }
        switch captureSession.phase {
        case .starting, .finalizing:
            return FlowTheme.teal
        case .recording:
            return FlowTheme.accent
        }
    }

    private var transcriptStateSymbolName: String {
        switch note.effectiveTranscriptState {
        case .empty:
            return "quote.bubble"
        case .liveDraft:
            return "waveform"
        case .finalizing:
            return "hourglass"
        case .final:
            return "checkmark.circle.fill"
        case .finalizationFailed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var transcriptStateTint: Color {
        switch note.effectiveTranscriptState {
        case .empty:
            return FlowTheme.textTertiary
        case .liveDraft:
            return FlowTheme.accent
        case .finalizing:
            return FlowTheme.teal
        case .final:
            return FlowTheme.success
        case .finalizationFailed:
            return FlowTheme.error
        }
    }

    private var missingPermissionDetail: String {
        var missing = [String]()
        if captureSource.requiresMicrophone, !permissions.microphoneGranted {
            missing.append("Microphone")
        }
        if captureSource.requiresScreenRecording, !permissions.screenRecordingGranted {
            missing.append("Screen Recording")
        }
        return "Grant \(missing.joined(separator: " and ")) permission to use \(captureSource.displayName.lowercased())."
    }

    private var sourceSymbolName: String {
        switch captureSource {
        case .systemAudio:
            return "speaker.wave.2.fill"
        case .microphone:
            return "mic.fill"
        case .microphoneAndSystemAudio:
            return "waveform.and.mic"
        }
    }

    private var capturedDurationDescription: String {
        Self.durationDescription(frameCount: capturedFrameCount)
    }

    private func askSuggestion(_ question: String) -> some View {
        MeetingInlineButton(title: question) {
            askQuestion = question
            submitAskQuestion()
        }
    }

    private func submitAskQuestion() {
        let question = askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        askAnswer = MeetingAskAnswer.answer(question: question, note: note)
        selectedMode = .ask
    }

    private func reportText(for template: MeetingReportTemplate) -> String {
        MeetingReportFormatter.report(template: template, note: note, transcriptRuns: transcriptRuns)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func durationDescription(frameCount: Int, sampleRate: Double = 16_000) -> String {
        let totalSeconds = max(Int((Double(frameCount) / sampleRate).rounded()), 0)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct MeetingIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = FlowTheme.textTertiary
    var isDisabled = false
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isDisabled ? FlowTheme.textTertiary.opacity(0.45) : tint)
                .frame(width: 30, height: 30)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(accessibilityIdentifier ?? "meeting-icon-button-\(meetingAccessibilityIdentifierSuffix(help))")
    }
}

private struct MeetingModePill: View {
    let mode: MeetingWorkspaceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(mode.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? FlowTheme.textPrimary : FlowTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isSelected ? FlowTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? FlowTheme.border.opacity(0.85) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("meeting-tab-\(mode.rawValue.lowercased())")
    }
}

private struct MeetingInlineButton: View {
    let title: String
    var systemImage: String?
    var isPrimary = false
    var isDisabled = false
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isPrimary || isDisabled ? Color.clear : FlowTheme.border.opacity(0.85), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier ?? "meeting-inline-button-\(meetingAccessibilityIdentifierSuffix(title))")
    }

    private var foreground: Color {
        if isDisabled {
            return FlowTheme.textTertiary
        }
        return isPrimary ? FlowTheme.background : FlowTheme.textPrimary
    }

    private var background: Color {
        if isDisabled {
            return FlowTheme.subtle
        }
        return isPrimary ? FlowTheme.textPrimary : FlowTheme.elevated
    }
}

private struct MeetingMetaChip: View {
    let text: String
    let systemImage: String
    var tint: Color = FlowTheme.textSecondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FlowTheme.subtle, in: Capsule())
    }
}

private struct MeetingSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SummaryMetricStrip: View {
    let summary: MeetingSummary
    let transcriptCount: Int

    var body: some View {
        HStack(spacing: 8) {
            metric(title: "Decisions", value: summary.decisions.count)
            metric(title: "Actions", value: summary.actionItems.count)
            metric(title: "Questions", value: summary.openQuestions.count)
            metric(title: "Transcript", value: transcriptCount)
        }
    }

    private func metric(title: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(FlowTheme.subtle, in: Capsule())
    }
}

private struct EmptyWorkspaceState: View {
    let systemImage: String
    let title: String
    let detail: String
    var minHeight: CGFloat = 190

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(FlowTheme.textTertiary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .padding(18)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct MeetingAskAnswer: Equatable {
    let question: String
    let answer: String
    let matches: [TranscriptRun]

    static func answer(question: String, note: MeetingNote) -> MeetingAskAnswer {
        let runs = TranscriptRun.makeRuns(from: note)
        let lowercasedQuestion = question.lowercased()
        let summary = note.summary

        if lowercasedQuestion.contains("decision") {
            let answer = listAnswer(
                empty: "No decisions have been identified yet.",
                items: summary?.decisions ?? []
            )
            return MeetingAskAnswer(question: question, answer: answer, matches: matchingRuns(runs, keywords: ["decided", "decision"]))
        }

        if lowercasedQuestion.contains("action") || lowercasedQuestion.contains("todo") || lowercasedQuestion.contains("next") {
            let items = (summary?.actionItems ?? []).map { item in
                if let owner = item.owner, !owner.isEmpty {
                    return "\(owner): \(item.text)"
                }
                return item.text
            }
            return MeetingAskAnswer(
                question: question,
                answer: listAnswer(empty: "No action items have been identified yet.", items: items),
                matches: matchingRuns(runs, keywords: ["action", "todo", "follow up", "follow-up", "next step"])
            )
        }

        if lowercasedQuestion.contains("question") || lowercasedQuestion.contains("open") {
            let answer = listAnswer(
                empty: "No open questions have been identified yet.",
                items: summary?.openQuestions ?? []
            )
            return MeetingAskAnswer(question: question, answer: answer, matches: matchingRuns(runs, keywords: ["?", "question", "open"]))
        }

        let keywords = keywords(from: question)
        let matches = matchingRuns(runs, keywords: keywords)
        if !matches.isEmpty {
            let excerpt = matches.prefix(3).map { "- [\($0.timeDescription)] \($0.text)" }.joined(separator: "\n")
            return MeetingAskAnswer(question: question, answer: "I found this in the meeting:\n\(excerpt)", matches: Array(matches.prefix(5)))
        }

        if let overview = summary?.overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MeetingAskAnswer(question: question, answer: overview, matches: [])
        }

        let notes = note.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            return MeetingAskAnswer(question: question, answer: notes, matches: [])
        }

        return MeetingAskAnswer(
            question: question,
            answer: "There is not enough meeting content yet. Record audio or add notes, then ask again.",
            matches: []
        )
    }

    private static func listAnswer(empty: String, items: [String]) -> String {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return empty }
        return cleaned.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func keywords(from question: String) -> [String] {
        let ignored: Set<String> = ["about", "after", "again", "could", "should", "there", "their", "these", "those", "what", "when", "where", "which", "would", "were", "with", "this", "that", "from", "meeting"]
        return question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 && !ignored.contains($0) }
    }

    private static func matchingRuns(_ runs: [TranscriptRun], keywords: [String]) -> [TranscriptRun] {
        let cleanedKeywords = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !cleanedKeywords.isEmpty else { return [] }
        return runs.filter { run in
            let text = run.text.lowercased()
            return cleanedKeywords.contains { text.contains($0) }
        }
    }
}

private struct MeetingAskAnswerView: View {
    let answer: MeetingAskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(answer.question)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.textSecondary)

                Text(answer.answer)
                    .font(.system(size: 14))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !answer.matches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcript matches")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FlowTheme.textTertiary)
                        .textCase(.uppercase)

                    ForEach(answer.matches.prefix(4)) { run in
                        TranscriptRunRow(
                            run: run,
                            speakers: [],
                            highlight: "",
                            isEditable: false,
                            onRename: {},
                            onMerge: { _ in },
                            onSplit: {},
                            onAssign: {}
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private enum MeetingReportFormatter {
    static func report(
        template: MeetingReportTemplate,
        note: MeetingNote,
        transcriptRuns: [TranscriptRun]
    ) -> String {
        switch template {
        case .standard:
            return MeetingMarkdownFormatter.markdown(for: note).trimmingCharacters(in: .whitespacesAndNewlines)
        case .decisionLog:
            return decisionLog(note: note, transcriptRuns: transcriptRuns)
        case .actionPlan:
            return actionPlan(note: note)
        case .followUpEmail:
            return followUpEmail(note: note)
        }
    }

    private static func decisionLog(note: MeetingNote, transcriptRuns: [TranscriptRun]) -> String {
        var lines = ["# Decision Log: \(note.displayTitle)", ""]
        let decisions = note.summary?.decisions ?? []
        if decisions.isEmpty {
            lines.append("No decisions have been identified yet.")
        } else {
            lines += decisions.enumerated().map { index, decision in
                "\(index + 1). \(decision)"
            }
        }

        let matches = transcriptRuns.filter { $0.text.localizedCaseInsensitiveContains("decid") }
        if !matches.isEmpty {
            lines += ["", "## Supporting Transcript"]
            lines += matches.prefix(6).map { "- [\($0.timeDescription)] \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    private static func actionPlan(note: MeetingNote) -> String {
        var lines = ["# Action Plan: \(note.displayTitle)", ""]
        let actionItems = note.summary?.actionItems ?? []
        if actionItems.isEmpty {
            lines.append("No action items have been identified yet.")
        } else {
            lines += actionItems.map { item in
                let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let owner, !owner.isEmpty {
                    return "- [ ] \(owner): \(item.text)"
                }
                return "- [ ] \(item.text)"
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func followUpEmail(note: MeetingNote) -> String {
        if let draft = note.summary?.followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
            return draft
        }

        let overview = note.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Subject: \(note.displayTitle) follow-up",
            "",
            "Hi all,",
            "",
            overview?.isEmpty == false ? overview! : "Sharing a quick follow-up from our meeting.",
            "",
            "Thanks,"
        ].joined(separator: "\n")
    }
}

private struct SpeakerEditRequest: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let placeholder: String
    let initialName: String
    let confirmTitle: String
    let action: SpeakerEditAction
}

private enum SpeakerEditAction {
    case rename(speakerID: UUID)
    case split(sourceID: UUID, segmentIDs: [UUID])
    case assign(segmentIDs: [UUID])
}

private struct SpeakerNameSheet: View {
    let request: SpeakerEditRequest
    let onCancel: () -> Void
    let onCommit: (String) -> Void
    @State private var displayName: String

    init(
        request: SpeakerEditRequest,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onCommit = onCommit
        _displayName = State(initialValue: request.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(request.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(request.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(request.placeholder, text: $displayName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13.5))
                .accessibilityIdentifier("speaker-name-field")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) {
                    onCommit(trimmedName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(FlowTheme.background)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TranscriptRun: Identifiable, Equatable {
    let id: UUID
    let text: String
    let speaker: TranscriptSpeaker?
    let speakerDisplayName: String?
    let proxyDisplayName: String?
    let speakerID: UUID?
    let captureSource: MeetingCaptureSource?
    let origin: TranscriptSegmentOrigin
    let recordingID: UUID?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segmentCount: Int
    let segmentIDs: [UUID]

    static func makeRuns(from note: MeetingNote) -> [TranscriptRun] {
        var runs = [TranscriptRun]()

        for segment in note.transcriptSegments {
            if let lastIndex = runs.indices.last,
               runs[lastIndex].canMerge(segment, in: note) {
                runs[lastIndex] = runs[lastIndex].merging(segment)
            } else {
                runs.append(TranscriptRun(segment: segment, in: note))
            }
        }

        return runs
    }

    init(segment: TranscriptSegment, in note: MeetingNote) {
        id = segment.id
        text = segment.text
        speaker = segment.speaker
        speakerDisplayName = note.resolvedSpeakerLabel(for: segment)
        proxyDisplayName = segment.speakerDisplayName
        speakerID = segment.speakerID
        captureSource = segment.captureSource
        origin = segment.effectiveOrigin
        recordingID = segment.recordingID
        startTime = segment.startTime
        endTime = segment.endTime
        segmentCount = 1
        segmentIDs = [segment.id]
    }

    private init(
        id: UUID,
        text: String,
        speaker: TranscriptSpeaker?,
        speakerDisplayName: String?,
        proxyDisplayName: String?,
        speakerID: UUID?,
        captureSource: MeetingCaptureSource?,
        origin: TranscriptSegmentOrigin,
        recordingID: UUID?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        segmentCount: Int,
        segmentIDs: [UUID]
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.speakerDisplayName = speakerDisplayName
        self.proxyDisplayName = proxyDisplayName
        self.speakerID = speakerID
        self.captureSource = captureSource
        self.origin = origin
        self.recordingID = recordingID
        self.startTime = startTime
        self.endTime = endTime
        self.segmentCount = segmentCount
        self.segmentIDs = segmentIDs
    }

    private func canMerge(_ segment: TranscriptSegment, in note: MeetingNote) -> Bool {
        Self.normalized(text) == Self.normalized(segment.text) &&
            speaker == segment.speaker &&
            speakerDisplayName == note.resolvedSpeakerLabel(for: segment) &&
            proxyDisplayName == segment.speakerDisplayName &&
            speakerID == segment.speakerID &&
            captureSource == segment.captureSource &&
            origin == segment.effectiveOrigin &&
            recordingID == segment.recordingID
    }

    private func merging(_ segment: TranscriptSegment) -> TranscriptRun {
        TranscriptRun(
            id: id,
            text: text,
            speaker: speaker,
            speakerDisplayName: speakerDisplayName,
            proxyDisplayName: proxyDisplayName,
            speakerID: speakerID,
            captureSource: captureSource,
            origin: origin,
            recordingID: recordingID,
            startTime: min(startTime, segment.startTime),
            endTime: max(endTime, segment.endTime),
            segmentCount: segmentCount + 1,
            segmentIDs: segmentIDs + [segment.id]
        )
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var timeDescription: String {
        let start = Self.timestamp(startTime)
        guard segmentCount > 1, Int(startTime.rounded()) != Int(endTime.rounded()) else {
            return start
        }
        return "\(start)-\(Self.timestamp(endTime))"
    }

    var isUserSpeaker: Bool {
        speaker == .user || captureSource == .microphone
    }

    var conversationSpeakerName: String {
        speakerDisplayName ?? "Speaker"
    }

    var sourceDescription: String? {
        if speakerID == nil {
            return proxyDisplayName == nil ? nil : "Inferred"
        }
        if let proxyDisplayName, proxyDisplayName != speakerDisplayName {
            return "Source: \(proxyDisplayName)"
        }
        return nil
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct TranscriptRunRow: View {
    let run: TranscriptRun
    let speakers: [MeetingSpeakerIdentity]
    let highlight: String
    var isEditable = true
    let onRename: () -> Void
    let onMerge: (UUID) -> Void
    let onSplit: () -> Void
    let onAssign: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if run.isUserSpeaker {
                Spacer(minLength: 72)
            }

            bubble

            if !run.isUserSpeaker {
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: run.isUserSpeaker ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.conversationSpeakerName) at \(run.timeDescription)")
        .accessibilityValue(run.text)
        .accessibilityHint(run.segmentCount > 1 ? "\(run.segmentCount) repeated fragments collapsed" : "")
        .accessibilityIdentifier("transcript-run-\(run.id.uuidString)")
    }

    private var bubble: some View {
        VStack(alignment: run.isUserSpeaker ? .trailing : .leading, spacing: 4) {
            Text(run.timeDescription)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(FlowTheme.textTertiary)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(run.conversationSpeakerName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(run.isUserSpeaker ? FlowTheme.success : FlowTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((run.isUserSpeaker ? FlowTheme.successSubtle : FlowTheme.subtle), in: Capsule())

                    if let source = run.sourceDescription, source != run.conversationSpeakerName {
                        Text(source)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FlowTheme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(FlowTheme.background, in: Capsule())
                    }

                    if isEditable {
                        speakerMenu
                    }

                    if run.segmentCount > 1 {
                        Text("\(run.segmentCount)x")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FlowTheme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(FlowTheme.background, in: Capsule())
                    }
                }

                Text(run.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(run.isUserSpeaker ? FlowTheme.successSubtle : FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(run.isUserSpeaker ? FlowTheme.success.opacity(0.2) : FlowTheme.border, lineWidth: 1)
            )
        }
        .frame(maxWidth: 580, alignment: run.isUserSpeaker ? .trailing : .leading)
        .opacity(highlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || run.text.localizedCaseInsensitiveContains(highlight) ? 1 : 0.55)
    }

    @ViewBuilder
    private var speakerMenu: some View {
        Menu {
            if run.speakerID == nil {
                Button {
                    onAssign()
                } label: {
                    Label("Name speaker", systemImage: "person.badge.plus")
                }
            } else {
                Button {
                    onRename()
                } label: {
                    Label("Rename speaker", systemImage: "pencil")
                }

                Button {
                    onSplit()
                } label: {
                    Label("Split this turn", systemImage: "arrow.branch")
                }

                if !mergeTargets.isEmpty {
                    Menu("Merge into") {
                        ForEach(mergeTargets) { speaker in
                            Button(speaker.displayName) {
                                onMerge(speaker.id)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Edit speaker")
        .accessibilityLabel("Edit speaker")
        .accessibilityIdentifier("transcript-speaker-menu-\(run.id.uuidString)")
    }

    private var mergeTargets: [MeetingSpeakerIdentity] {
        guard let speakerID = run.speakerID else { return [] }
        return speakers.filter { $0.id != speakerID }
    }
}
