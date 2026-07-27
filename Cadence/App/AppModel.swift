import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

private let preferencesLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Preferences"
)

enum MenuScreen: Equatable {
    case home
    case settings
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ModelReadinessSummary {
    enum Tone {
        case ready
        case working
        case attention
    }

    let title: String
    let detail: String
    let tone: Tone
}

@MainActor
final class AppModel: ObservableObject {
    private enum PreferenceKey {
        static let whisperModel = "FlowState.whisperModel"
        static let decodingMode = "FlowState.decodingMode"
        static let fillerWordPolicy = "FlowState.fillerWordPolicy"
        static let keepContext = "FlowState.keepContext"
        static let trimSilence = "FlowState.trimSilence"
        static let normalizeAudio = "FlowState.normalizeAudio"
        static let waveformSensitivity = "Cadence.waveformSensitivity"
        static let hudPillResponse = "Cadence.debug.hudMotion.pillResponse"
        static let hudMicFadeOutDuration = "Cadence.debug.hudMotion.micFadeOutDuration"
        static let hudAppCueFadeInDuration = "Cadence.debug.hudMotion.appCueFadeInDuration"
        static let hudWaveformFadeInDuration = "Cadence.debug.hudMotion.waveformFadeInDuration"
        static let livePreviewEnabled = "FlowState.livePreviewEnabled"
        static let tapStopsOnNextKeyPress = "FlowState.tapStopsOnNextKeyPress"
        static let appAwarePolishingEnabled = "Cadence.appAwarePolishingEnabled"
        static let pressEnterCommandEnabled = "Cadence.pressEnterCommandEnabled"
        static let pressEnterCommandPhrase = "Cadence.pressEnterCommandPhrase"
        static let vocabularyText = "FlowState.vocabularyText"
        static let analyticsEnabled = "Cadence.analyticsEnabled"
        static let googleOAuthClientID = "Cadence.googleOAuthClientID"
        static let googleOAuthClientSecret = "Cadence.googleOAuthClientSecret"
        static let googleOAuthRedirectScheme = "Cadence.googleOAuthRedirectScheme"
        static let holdEnabled = "FlowState.holdEnabled"
        static let holdKeyCode = "FlowState.holdKeyCode"
        static let holdModifiers = "FlowState.holdModifiers"
        static let holdKeyDisplay = "FlowState.holdKeyDisplay"
        static let holdSidedModifierKeyCodes = "Cadence.holdSidedModifierKeyCodes"
        static let tapEnabled = "FlowState.tapEnabled"
        static let tapKeyCode = "FlowState.tapKeyCode"
        static let tapModifiers = "FlowState.tapModifiers"
        static let tapKeyDisplay = "FlowState.tapKeyDisplay"
        static let tapSidedModifierKeyCodes = "Cadence.tapSidedModifierKeyCodes"
        static let scribeEnabled = "Cadence.scribeEnabled"
        static let scribeKeyCode = "Cadence.scribeKeyCode"
        static let scribeModifiers = "Cadence.scribeModifiers"
        static let scribeKeyDisplay = "Cadence.scribeKeyDisplay"
        static let scribeSidedModifierKeyCodes = "Cadence.scribeSidedModifierKeyCodes"
        static let transcriptHistory = "FlowState.transcriptHistory"
        static let showsShortcutDock = "Cadence.showsShortcutDock"
        static let meetingCaptureSource = "Cadence.meetingCaptureSource"
        static let acknowledgedOrphanRecordingIDs = "Cadence.acknowledgedOrphanRecordingIDs"
        static let appearancePreference = "Cadence.appearancePreference"
        static let firstSuccessfulDictationTracked = "Cadence.firstSuccessfulDictationTracked"
        static let didMigrateToFastDefaults = "FlowState.didMigrateToFastDefaults"
        static let didMigrateToLivePreviewDefault = "FlowState.didMigrateToLivePreviewDefault"
        static let didMigrateToLivePreviewDefaultV2 = "FlowState.didMigrateToLivePreviewDefault.v2"
        static let didUndoLivePreviewDefault = "FlowState.didUndoLivePreviewDefault.v1"
        static let hudPosition = "Cadence.hudPosition"
    }

    private enum AnalyticsTuning {
        static let followUpWindow: TimeInterval = 10
    }

    private enum WaveformSensitivityTuning {
        static let defaultValue = 1.0
        static let closedRange = 0.1...1.6
    }

    private enum MeetingTranscriptionTuning {
        static let rollingWindowDuration: TimeInterval = 5
        static let audioStopTimeout: Duration = .seconds(8)
        static let finalizationTimeout: Duration = .seconds(45)
    }

    @Published private(set) var permissions: PermissionsSnapshot
    @Published private(set) var state: DictationSessionState = .idle
    @Published private(set) var scribeState: ScribeSessionState = .idle
    @Published private(set) var scribeProviderReadiness: ScribeProviderReadiness = .setupRequired
    @Published private(set) var adaptiveScribeV2Availability: AdaptiveScribeAvailability = .setupRequired
    @Published private(set) var showsLegacyWritingProfileNotice = false
    @Published private(set) var scribeAppAdaptationEnabled = true
    @Published private(set) var writingEnvironmentPreferenceState: WritingEnvironmentPreferenceLoadResult = .absent
    @Published var isScribeProviderSetupPresented = false
    @Published private(set) var hudState = HUDState.idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var transcriptHistory: [TranscriptHistoryItem]
    @Published private(set) var meetingNotes: [MeetingNote]
    @Published private(set) var selectedMeetingNoteID: UUID?
    @Published private(set) var recoverableOrphanedRecordings: [OrphanedMeetingRecording] = []
    @Published private(set) var systemAudioCaptureState: SystemAudioCaptureState = .idle
    @Published private(set) var systemAudioCaptureLevel = 0.0
    @Published private(set) var systemAudioCapturedFrameCount = 0
    @Published private(set) var meetingCaptureSource: MeetingCaptureSource
    @Published private(set) var googleCalendarConnectionState: GoogleCalendarConnectionState
    @Published private(set) var upcomingCalendarMeetings: [GoogleCalendarEvent]
    @Published private(set) var detectedCalendarMeeting: GoogleCalendarEvent?
    @Published private(set) var isRefreshingCalendar = false
    @Published private(set) var isConnectingGoogleCalendar = false
    @Published private(set) var googleOAuthClientID: String
    @Published private(set) var googleOAuthClientSecret: String
    @Published private(set) var googleOAuthRedirectScheme: String
    @Published private(set) var livePreviewConfirmedText = ""
    @Published private(set) var livePreviewUnconfirmedText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var shortcutValidationMessage: String?
    @Published private(set) var copiedTranscriptID: UUID?
    @Published private(set) var backendDescription = "Loading transcription backend"
    @Published private(set) var transcriptionConfiguration: TranscriptionConfiguration
    @Published private(set) var analyticsEnabled: Bool
    @Published private(set) var showsShortcutDock: Bool
    @Published private(set) var dictationActivationSoundEnabled: Bool
    @Published private(set) var dictationCompletionSoundEnabled: Bool
    @Published private(set) var waveformSensitivity: Double
    @Published private(set) var hudMotionTuning: HUDMotionTuning
    @Published private(set) var appearancePreference: AppearancePreference
    @Published private(set) var personalizationLibrary: PersonalizationLibrary
    @Published private(set) var spokenShortcutsEnabled: Bool
    @Published private(set) var onboardingProgress: OnboardingProgress
    @Published private(set) var hudVisibility: HUDVisibilityState
    @Published var menuScreen: MenuScreen = .home
    @Published private(set) var installedApplications: [InstalledApplicationDescriptor] = []
    @Published private(set) var settingsPresentationState: SettingsPresentationState
    @Published private(set) var applicationConfigurations: [ApplicationConfiguration] = []

    @Published private(set) var holdToTalkBinding: HotkeyBinding
    @Published private(set) var tapToStartStopBinding: HotkeyBinding
    @Published private(set) var scribeBinding: HotkeyBinding
    let featureFlags: CadenceFeatureFlags

    private let permissionsService: PermissionsService
    private let permissionGuideWindowController = PermissionGuideWindowController()
    private let hotkeyService: HotkeyService
    private let coordinator: DictationCoordinator
    private let scribeCoordinator: ScribeCoordinator
    private let scribeTranscriptionEngine: TranscriptionEngine
    private let scribeProviderV2Controller: ScribeProviderV2Controller
    private let scribeProviderRuntime: ScribeProviderRuntime
    private let scribeProviderV2ConnectionManager: ScribeProviderV2ConnectionManager
    private let scribeProviderSetupSession: ScribeProviderSetupSession
    private let scribeModelCatalogService: ScribeModelCatalogService
    private let scribeConsentAuthority: ScribeProviderConsentAuthority
    private let adaptiveScribeLiveReaderService: AdaptiveScribeLiveReaderService
    private let adaptiveScribeReaderMonitor: AdaptiveScribeReaderMonitor
    private let writingEnvironmentStore: WritingEnvironmentStore
    private let settingsPresentationStore: SettingsPresentationStore
    private let applicationConfigurationStore: ApplicationConfigurationStore
    private let applicationConfigurationWriter: ApplicationConfigurationWriter
    private let installedApplicationSnapshotStore: InstalledApplicationCatalogSnapshotStore
    private let installedApplicationCatalogService: InstalledApplicationCatalogService
    private let installedApplicationLifecycleSource: WorkspaceInstalledApplicationLifecycleSource
    private let scribeDiagnosticsService: ScribeDiagnosticsService
    private let scribePanelWindowController = ScribePanelWindowController()
    private let scribeNotchWindowController = ScribeNotchWindowController()
    private let voiceSessionArbiter: VoiceSessionArbiter
    let onboardingMicrophoneMonitor: OnboardingMicrophoneMonitor
    private let hudController: HUDWindowController
    private let hudVisibilityController: HUDVisibilityController
    private var scribeReplacementCompleted = false
    private var activeScribeTriggerMode: DictationTriggerMode?
    private var scribeShortcutReleasePending = false
    private var scribeRecoveryApplication: ApplicationProcessIdentity?
    private var scribeAudioLevel = 0.0
    private var scribeWaveformLevels = Array(repeating: 0.0, count: 16)
    private let focusedApplicationSource: WorkspaceFocusedApplicationSource
    private let focusedApplicationMonitor: FocusedApplicationMonitor
    private let applicationTargetAuthority: ApplicationTargetAuthority
    private let applicationIconResolver: ApplicationIconResolver
    private let applicationPresentationArbiter: ApplicationPresentationArbiter
    private let selectionCaptureService: SelectionCaptureService
    private let feedbackService: SoundFeedbackService
    private let analytics: AnalyticsService
    private let mainWindowController = MainWindowController()
    private let meetingStore: MeetingStore
    private let meetingAudioStore: MeetingAudioStore
    private let systemAudioCaptureService: SystemAudioCaptureServing
    private let meetingMicrophoneCaptureService: AudioCaptureServing
    private var meetingTranscriptionService: MeetingRollingTranscriptionService
    private let meetingFinalTranscriptionService: MeetingFinalTranscriptionService
    private let meetingSummaryService: MeetingSummaryService
    private let googleCalendarService: GoogleCalendarService
    private let calendarEventCacheStore: CalendarEventCacheStore
    private let meetingDetectionService = MeetingDetectionService()
    private var googleCalendarConfiguration: GoogleCalendarOAuthConfiguration?
    private let defaults: UserDefaults
    private let personalizationStore: PersonalizationStore
    private let onboardingProgressStore: OnboardingProgressStore
    private var cancellables = Set<AnyCancellable>()
    private var installedApplicationIconSnapshot = InstalledApplicationCatalogSnapshot.empty
    private var transcriptionConfigurationTask: Task<Void, Never>?
    private var lastTrackedCorrectionTranscriptID: UUID?
    private var lastTrackedCorrectionSessionID: String?
    private var meetingMicrophoneCaptureActive = false
    private var meetingSystemAudioCaptureActive = false
    private var activeMeetingCaptureNoteID: UUID?
    private var activeMeetingRecordingID: UUID?
    private var activeMeetingAudioRecorder: MeetingAudioRecorder?
    private var activeMeetingCaptureChunkQueue: MeetingCaptureChunkQueue?
    @Published private var activeMeetingCaptureStartedAt: Date?
    private var meetingCaptureStopTask: Task<Void, Never>?
    private var meetingVoiceSessionLease: VoiceSessionLease?
    private var calendarDetectionTimer: Timer?
    private var promptedCalendarEventIDs = Set<String>()
    #if DEBUG
    private var hudMotionPreviewTask: Task<Void, Never>?
    #endif

    init() {
        #if DEBUG
        let defaults = ScribeLaunchFixtures.runtimeDefaults()
        #else
        let defaults = UserDefaults.standard
        #endif
        #if DEBUG
        ScribeLaunchFixtures.apply(to: defaults)
        #endif
        let featureFlags = CadenceFeatureFlags.resolve(defaults: defaults)
        let hudVisibilityController = HUDVisibilityController(
            store: HUDVisibilityStore(defaults: defaults)
        )
        let initialHoldBinding = AppModel.loadBinding(defaults: defaults, action: .holdToTalk)
        let initialTapBinding = AppModel.loadBinding(defaults: defaults, action: .tapToStartStop)
        var initialScribeBinding = AppModel.loadBinding(defaults: defaults, action: .scribe)
        if !featureFlags.scribeEnabled {
            initialScribeBinding.isEnabled = false
        }
        self.defaults = defaults
        self.featureFlags = featureFlags
        self.hudVisibilityController = hudVisibilityController
        self.hudVisibility = hudVisibilityController.state
        self.selectionCaptureService = SelectionCaptureService()
        let initialTranscriptionConfiguration = AppModel.loadConfiguration(defaults: defaults)
        self.transcriptionConfiguration = initialTranscriptionConfiguration
        let analyticsEnabled = defaults.bool(forKey: PreferenceKey.analyticsEnabled)
        let showsShortcutDock = (defaults.object(forKey: PreferenceKey.showsShortcutDock) as? Bool) ?? true
        let dictationActivationSoundEnabled = DictationSoundFeedbackPreference.loadActivation(from: defaults)
        let dictationCompletionSoundEnabled = DictationSoundFeedbackPreference.loadCompletion(from: defaults)
        let waveformSensitivity = Self.loadWaveformSensitivity(defaults: defaults)
        let hudMotionTuning = Self.loadHUDMotionTuning(defaults: defaults)
        let appearancePreference = Self.loadAppearancePreference(defaults: defaults)
        let personalizationStore = PersonalizationStore(defaults: defaults)
        let onboardingProgressStore = OnboardingProgressStore(defaults: defaults)
        let onboardingProgress = onboardingProgressStore.load()
        self.analyticsEnabled = analyticsEnabled
        self.showsShortcutDock = showsShortcutDock
        self.dictationActivationSoundEnabled = dictationActivationSoundEnabled
        self.dictationCompletionSoundEnabled = dictationCompletionSoundEnabled
        self.waveformSensitivity = waveformSensitivity
        self.hudMotionTuning = hudMotionTuning
        self.appearancePreference = appearancePreference
        self.personalizationStore = personalizationStore
        self.personalizationLibrary = personalizationStore.load()
        self.spokenShortcutsEnabled = personalizationStore.areSpokenShortcutsEnabled()
        self.onboardingProgressStore = onboardingProgressStore
        self.onboardingProgress = onboardingProgress
        self.meetingCaptureSource = AppModel.loadMeetingCaptureSource(defaults: defaults)
        let googleOAuthClientID = AppModel.loadGoogleOAuthClientID(defaults: defaults)
        let googleOAuthClientSecret = AppModel.loadGoogleOAuthClientSecret(defaults: defaults)
        let googleOAuthRedirectScheme = AppModel.loadGoogleOAuthRedirectScheme(defaults: defaults)
        let googleCalendarConfiguration = AppModel.makeGoogleCalendarConfiguration(
            clientID: googleOAuthClientID,
            clientSecret: googleOAuthClientSecret,
            redirectScheme: googleOAuthRedirectScheme
        )
        let googleCalendarService = GoogleCalendarService()
        let calendarEventCacheStore = CalendarEventCacheStore()
        self.googleOAuthClientID = googleOAuthClientID
        self.googleOAuthClientSecret = googleOAuthClientSecret
        self.googleOAuthRedirectScheme = googleOAuthRedirectScheme
        self.googleCalendarConfiguration = googleCalendarConfiguration
        self.googleCalendarService = googleCalendarService
        self.calendarEventCacheStore = calendarEventCacheStore
        self.googleCalendarConnectionState = googleCalendarService.connectionState(configuration: googleCalendarConfiguration)
        self.upcomingCalendarMeetings = (try? calendarEventCacheStore.load()?.events) ?? []
        self.detectedCalendarMeeting = nil
        self.analytics = AnalyticsService(isEnabled: analyticsEnabled)
        self.holdToTalkBinding = initialHoldBinding
        self.tapToStartStopBinding = initialTapBinding
        self.scribeBinding = initialScribeBinding
        self.transcriptHistory = AppModel.loadTranscriptHistory(defaults: defaults)
        let meetingStore = AppModel.makeMeetingStore()
        let meetingAudioStore = AppModel.makeMeetingAudioStore()
        self.meetingStore = meetingStore
        self.meetingAudioStore = meetingAudioStore
        let meetingLoadResult: MeetingStoreLoadResult
        let loadedMeetingNotes: [MeetingNote]
        let visibleRecoverableOrphans: [OrphanedMeetingRecording]
        if featureFlags.granolaEnabled {
            meetingLoadResult = (try? meetingStore.loadNotesWithDiagnostics()) ?? .empty
            let recovery = meetingAudioStore.recover(notes: meetingLoadResult.notes)
            loadedMeetingNotes = recovery.notes
            let acknowledgedOrphanIDs = OrphanRecordingAcknowledgements.load(
                defaults.stringArray(forKey: PreferenceKey.acknowledgedOrphanRecordingIDs)
            )
            let activeAcknowledgements = OrphanRecordingAcknowledgements.reconcile(
                acknowledgedOrphanIDs,
                detectedOrphans: recovery.recoverableOrphans
            )
            defaults.set(
                activeAcknowledgements.map(\.uuidString),
                forKey: PreferenceKey.acknowledgedOrphanRecordingIDs
            )
            visibleRecoverableOrphans = recovery.recoverableOrphans.filter {
                !activeAcknowledgements.contains($0.id)
            }
        } else {
            meetingLoadResult = .empty
            loadedMeetingNotes = []
            visibleRecoverableOrphans = []
        }
        self.meetingNotes = loadedMeetingNotes
        self.selectedMeetingNoteID = loadedMeetingNotes.first?.id
        self.recoverableOrphanedRecordings = visibleRecoverableOrphans
        self.systemAudioCaptureService = SystemAudioCaptureService()
        self.meetingMicrophoneCaptureService = AudioCaptureService()
        self.meetingTranscriptionService = Self.makeMeetingTranscriptionService()
        self.meetingFinalTranscriptionService = MeetingFinalTranscriptionService(audioStore: meetingAudioStore)
        self.meetingSummaryService = MeetingSummaryService()
        for note in loadedMeetingNotes {
            try? meetingStore.save(note)
        }

        let permissionsService = PermissionsService()
        self.permissionsService = permissionsService
        self.permissions = permissionsService.snapshot()

        let hudController = HUDWindowController(
            defaults: defaults,
            appearancePreference: appearancePreference
        )
        hudController.viewModel.setMotionTuning(hudMotionTuning)
        self.hudController = hudController
        let focusedApplicationSource = WorkspaceFocusedApplicationSource()
        let focusedApplicationMonitor = FocusedApplicationMonitor(
            source: focusedApplicationSource,
            cadenceBundleIdentifiers: ["com.darshshah.Cadence", "com.darshshah.Cadence.debug"]
        )
        let applicationTargetAuthority = ApplicationTargetAuthority(monitor: focusedApplicationMonitor)
        let applicationIconResolver = ApplicationIconResolver()
        let applicationPresentationArbiter = ApplicationPresentationArbiter(
            resolver: applicationIconResolver
        )
        self.focusedApplicationSource = focusedApplicationSource
        self.focusedApplicationMonitor = focusedApplicationMonitor
        self.applicationTargetAuthority = applicationTargetAuthority
        self.applicationIconResolver = applicationIconResolver
        self.applicationPresentationArbiter = applicationPresentationArbiter
        let transcriptionEngine = WhisperKitTranscriptionEngine()
        let scribeTranscriptionEngine = WhisperKitTranscriptionEngine()
        let audioCaptureService = AudioCaptureService()
        let scribeAudioCaptureService = AudioCaptureService()
        let scribeProvider = Self.makeScribeProvider()
        let legacyScribeProvider: (any ScribeProvider)?
        #if DEBUG
        legacyScribeProvider = ScribeLaunchFixtures.disablesLegacyProvider
            ? nil
            : (scribeProvider.capabilities.contains(.semanticGeneration) ? scribeProvider : nil)
        #else
        legacyScribeProvider = scribeProvider.capabilities.contains(.semanticGeneration)
            ? scribeProvider
            : nil
        #endif
        let scribeConfigurationStore = ScribeProviderConfigurationStore(defaults: defaults)
        let scribeProviderLibraryStore = ScribeProviderLibraryStore(defaults: defaults)
        let scribeCredentialVault = KeychainScribeCredentialVault()
        let scribeCleanupLedgerStore = ScribeCredentialCleanupLedgerStore(defaults: defaults)
        let scribeProviderRuntime = ScribeProviderRuntime(
            libraryStore: scribeProviderLibraryStore,
            legacyStore: scribeConfigurationStore,
            ledgerStore: scribeCleanupLedgerStore,
            vault: scribeCredentialVault,
            legacyLocalProvider: legacyScribeProvider
        )
        let scribeProviderV2Controller = scribeProviderRuntime.controller
        let scribeProviderV2ConnectionManager = scribeProviderRuntime.manager
        let scribeProviderSetupSession = scribeProviderRuntime.setupSession
        let scribeModelCatalogService = scribeProviderRuntime.modelCatalog
        let scribeConsentAuthority = scribeProviderRuntime.consentAuthority
        let writingEnvironmentStore = WritingEnvironmentStore(defaults: defaults)
        let settingsPresentationStore = SettingsPresentationStore(defaults: defaults)
        let settingsPresentationState: SettingsPresentationState
        switch settingsPresentationStore.loadNormalizingCategories(
            scribeEnabled: featureFlags.scribeEnabled,
            granolaEnabled: featureFlags.granolaEnabled
        ) {
        case let .valid(state):
            settingsPresentationState = state
        case .absent:
            settingsPresentationState = .init(selectedCategory: .general, isAdvancedExpanded: false)
        case .rejected:
            // A stale presentation preference must never disable Scribe or the
            // rest of Settings. It is safe to discard and start at General.
            settingsPresentationStore.clear()
            settingsPresentationState = .init(selectedCategory: .general, isAdvancedExpanded: false)
        }
        let applicationConfigurationStore = ApplicationConfigurationStore(defaults: defaults)
        let applicationConfigurationWriter = ApplicationConfigurationWriter(store: applicationConfigurationStore)
        let installedApplicationSnapshotStore = InstalledApplicationCatalogSnapshotStore()
        let rememberedApplicationURLs: Set<URL>
        if case let .valid(library) = applicationConfigurationStore.load() {
            rememberedApplicationURLs = Set(library.configurations.map(\.application.lastKnownBundleURL))
        } else {
            rememberedApplicationURLs = []
        }
        let installedApplicationCatalogService = InstalledApplicationCatalogService(
            cadenceBundleIdentifiers: ["com.darshshah.Cadence", "com.darshshah.Cadence.debug"],
            currentBundleURL: Bundle.main.bundleURL,
            snapshotStore: installedApplicationSnapshotStore,
            rememberedURLs: rememberedApplicationURLs
        )
        let installedApplicationLifecycleSource = WorkspaceInstalledApplicationLifecycleSource()
        let scribeDiagnosticsService = ScribeDiagnosticsService()
        let migrationResult = try? AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: personalizationStore
        ).migrate(
            scribeEnabled: initialScribeBinding.isEnabled,
            legacyLocalAvailable: legacyScribeProvider != nil,
            providerConfiguration: scribeConfigurationStore.load()
        )
        let v2MigrationResult = try? AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: personalizationStore
        ).migrateV2Domains(
            providerConfiguration: scribeConfigurationStore.load(),
            writingEnvironmentPreferences: writingEnvironmentStore.load()
        )
        let adaptiveScribeFeatureGateStore = AdaptiveScribeFeatureGateStore(defaults: defaults)
        if v2MigrationResult != nil {
            try? adaptiveScribeFeatureGateStore.promoteMigrationBaselineIfScribeEnabled(
                featureFlags.scribeEnabled
            )
        }
        let adaptiveScribeLiveReaderService = AdaptiveScribeLiveReaderService(
            providerStore: scribeProviderLibraryStore,
            applicationStore: applicationConfigurationStore,
            presetStore: ScribePresetCatalogStateStore(defaults: defaults),
            settingsStore: SettingsPresentationStore(defaults: defaults),
            featureGateStore: adaptiveScribeFeatureGateStore,
            markerStore: AdaptiveScribeMigrationMarkerStore(defaults: defaults),
            polishedDictationRuntimeAvailable: true
        )
        let adaptiveScribeReaderMonitor = AdaptiveScribeReaderMonitor(
            defaults: defaults,
            readerService: adaptiveScribeLiveReaderService
        )
        let textInsertionService = TextInsertionService()
        let voiceSessionArbiter = VoiceSessionArbiter()
        self.voiceSessionArbiter = voiceSessionArbiter
        self.onboardingMicrophoneMonitor = OnboardingMicrophoneMonitor(sessionArbiter: voiceSessionArbiter)
        self.scribeTranscriptionEngine = scribeTranscriptionEngine
        self.scribeProviderV2Controller = scribeProviderV2Controller
        self.scribeProviderRuntime = scribeProviderRuntime
        self.scribeProviderV2ConnectionManager = scribeProviderV2ConnectionManager
        self.scribeProviderSetupSession = scribeProviderSetupSession
        self.scribeModelCatalogService = scribeModelCatalogService
        self.scribeConsentAuthority = scribeConsentAuthority
        self.adaptiveScribeLiveReaderService = adaptiveScribeLiveReaderService
        self.adaptiveScribeReaderMonitor = adaptiveScribeReaderMonitor
        self.writingEnvironmentStore = writingEnvironmentStore
        self.settingsPresentationStore = settingsPresentationStore
        self.settingsPresentationState = settingsPresentationState
        self.applicationConfigurationStore = applicationConfigurationStore
        self.applicationConfigurationWriter = applicationConfigurationWriter
        if case let .valid(library) = applicationConfigurationStore.load() {
            self.applicationConfigurations = library.configurations
        }
        self.installedApplicationSnapshotStore = installedApplicationSnapshotStore
        self.installedApplicationCatalogService = installedApplicationCatalogService
        self.installedApplicationLifecycleSource = installedApplicationLifecycleSource
        self.scribeDiagnosticsService = scribeDiagnosticsService
        self.scribeProviderReadiness = scribeProviderV2Controller.readiness
        self.adaptiveScribeV2Availability = v2MigrationResult == nil
            ? .setupRequired
            : adaptiveScribeLiveReaderService.load().scribeAvailability
        self.showsLegacyWritingProfileNotice = migrationResult?.shouldShowLegacyProfileNotice ?? false
        self.scribeAppAdaptationEnabled = (
            defaults.object(forKey: AdaptiveScribeMigrationService.adaptationEnabledKey) as? Bool
        ) ?? true
        self.writingEnvironmentPreferenceState = writingEnvironmentStore.load()
        let hotkeyService = HotkeyService(
            bindings: Self.currentHotkeyBindings(
                hold: initialHoldBinding,
                tap: initialTapBinding,
                scribe: initialScribeBinding
            )
        )
        self.hotkeyService = hotkeyService

        let feedbackService = SoundFeedbackService(
            isActivationEnabled: dictationActivationSoundEnabled,
            isCompletionEnabled: dictationCompletionSoundEnabled
        )
        self.feedbackService = feedbackService

        self.coordinator = DictationCoordinator(
            hotkeyService: hotkeyService,
            permissionsService: permissionsService,
            audioCaptureService: audioCaptureService,
            transcriptionEngine: transcriptionEngine,
            textInsertionService: textInsertionService,
            hudController: hudController,
            analytics: analytics,
            feedbackService: feedbackService,
            sessionArbiter: voiceSessionArbiter,
            targetAuthority: applicationTargetAuthority,
            personalizationStore: personalizationStore,
            waveformSensitivity: waveformSensitivity
        )
        self.scribeCoordinator = ScribeCoordinator(
            audioCaptureService: scribeAudioCaptureService,
            transcriptionEngine: scribeTranscriptionEngine,
            provider: scribeProvider,
            providerActionResolver: { try await scribeProviderV2Controller.actionForNewRequest() },
            contextService: ScribeContextService(targetAuthority: applicationTargetAuthority),
            sessionArbiter: voiceSessionArbiter,
            personalizationStore: personalizationStore,
            applicationGuidanceResolver: { target, signature in
                let descriptor = InstalledApplicationDescriptor(
                    bundleURL: target.process.bundleURL,
                    bundleIdentifier: target.process.bundleIdentifier,
                    displayName: target.displayName
                        ?? target.process.bundleURL.deletingPathExtension().lastPathComponent,
                    version: nil,
                    build: nil,
                    isInstalled: true,
                    isRunning: true
                )
                return ScribeGuidanceResolver.resolve(
                    application: .exact(descriptor),
                    adaptationEnabled: (
                        defaults.object(
                            forKey: AdaptiveScribeMigrationService.adaptationEnabledKey
                        ) as? Bool
                    ) ?? true,
                    configurationLoadResult: applicationConfigurationStore.load(),
                    presetState: ScribePresetCatalogStateStore(defaults: defaults).load(),
                    targetSignature: signature
                )
            },
            writingEnvironmentPreferences: { writingEnvironmentStore.load() },
            adaptationEnabled: {
                (defaults.object(forKey: AdaptiveScribeMigrationService.adaptationEnabledKey) as? Bool) ?? true
            },
            providerDispatchAuthorization: { action in
                guard adaptiveScribeReaderMonitor.authorizeProviderDispatch() else { return false }
                return await scribeProviderV2Controller.authorizeDispatch(action.actionIdentity)
            },
            transcriptionConfiguration: initialTranscriptionConfiguration
        )

        focusedApplicationMonitor.onChange = { identity in
            applicationPresentationArbiter.updateLive(identity)
        }
        focusedApplicationMonitor.onLaunch = { processIdentifier, bundleURL in
            applicationIconResolver.invalidate(
                processIdentifier: processIdentifier,
                bundleURL: bundleURL
            )
        }
        focusedApplicationMonitor.onTermination = { identity, processIdentifier, bundleURL, launchDate in
            if let identity {
                applicationIconResolver.invalidate(identity: identity)
            } else {
                applicationIconResolver.invalidate(
                    processIdentifier: processIdentifier,
                    bundleURL: bundleURL
                )
            }
            applicationPresentationArbiter.markTerminated(
                identity: identity,
                processIdentifier: processIdentifier,
                bundleURL: bundleURL,
                launchDate: launchDate
            )
        }
        applicationPresentationArbiter.onChange = { presentation in
            hudController.viewModel.applyApplicationPresentation(presentation)
        }
        coordinator.onTargetPin = { capture, name in
            applicationPresentationArbiter.pin(capture, displayName: name)
        }
        coordinator.onTargetClear = { id in
            applicationPresentationArbiter.clearPin(id)
        }
        scribeCoordinator.onTargetPin = { capture, name in
            applicationPresentationArbiter.pin(capture, displayName: name)
        }
        scribeCoordinator.onTargetClear = { id in
            applicationPresentationArbiter.clearPin(id)
        }

        adaptiveScribeReaderMonitor.onInvalidation = { [weak self] in
            self?.invalidateAdaptiveScribeRuntime()
        }
        if featureFlags.scribeEnabled {
            adaptiveScribeReaderMonitor.start()
        }
        focusedApplicationMonitor.start()
        installedApplicationSnapshotStore.onPublish = { [weak self] snapshot in
            self?.handleInstalledApplicationSnapshot(snapshot)
        }
        applyAppearancePreference()
        bindCoordinator()
        bindHUDVisibility()
        bindScribeCoordinator()
        bindHotkeyDiagnostics()
        bindPermissionRefresh()
        AppDelegate.openMainWindow = { [weak self] in
            #if DEBUG
            guard !ScribeLaunchFixtures.usesNotchPresentation else { return }
            #endif
            self?.showMainWindow()
        }
        AppDelegate.shutdownApplicationServices = {
            installedApplicationLifecycleSource.stop()
            focusedApplicationMonitor.stop()
            applicationPresentationArbiter.stop()
            Task { await installedApplicationCatalogService.stop() }
        }
        showMainWindow()
        #if DEBUG
        presentScribeLaunchFixtureIfNeeded()
        #endif
        Task {
            if featureFlags.scribeEnabled {
                await scribeDiagnosticsService.load()
                try? await scribeProviderV2Controller.reconcileAtStartup()
                scribeProviderReadiness = scribeProviderV2Controller.readiness
            }
            await installedApplicationCatalogService.start(
                lifecycleSource: installedApplicationLifecycleSource
            )
            await refreshPermissions()
            await applyTranscriptionConfiguration(prewarm: false)
            await warmBackend()
            if featureFlags.granolaEnabled {
                await refreshTodayTomorrowCalendarEvents()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            #if DEBUG
            guard !ScribeLaunchFixtures.usesNotchPresentation else { return }
            #endif
            guard self?.mainWindowController.hasVisibleWindow != true else { return }
            self?.showMainWindow()
        }
        if let resultPath = Self.systemAudioSmokeResultPath() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.showMainWindow()
                try? await Task.sleep(for: .milliseconds(500))
                await self?.runSystemAudioSmoke(resultPath: resultPath)
            }
        }
        if featureFlags.granolaEnabled {
            startCalendarDetectionLoop()
        }
        analytics.track(
            "app_launched",
            properties: [
                "model": transcriptionConfiguration.model.rawValue,
                "decoding": transcriptionConfiguration.decodingMode.rawValue
            ]
        )
        if !meetingLoadResult.quarantinedFiles.isEmpty {
            lastError = Self.meetingQuarantineMessage(count: meetingLoadResult.quarantinedFiles.count)
        }
    }

    var menuBarSymbolName: String {
        switch state {
        case .idle:
            return "waveform.and.mic"
        case .listening:
            return "mic.fill"
        case .finalizing:
            return "ellipsis.message.fill"
        case .inserting:
            return "keyboard.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var isActivelyRecording: Bool {
        state == .listening || meetingCaptureSession?.phase == .recording
    }

    var activeShortcutSummary: String {
        currentHotkeyBindings
            .filter(\.isEnabled)
            .map { "\($0.action.displayName): \($0.shortcut.displayName)" }
            .joined(separator: " • ")
    }

    var scribeProviderStatus: String {
        switch scribeProviderReadiness {
        case .disabled: return "Compose is disabled · provider key retained"
        case .setupRequired: return "Provider setup required · literal Dictation remains available"
        case .validating: return "Validating the selected provider…"
        case let .ready(kind): return "\(kind.displayName) connected · review before insert"
        case let .temporarilyUnavailable(kind): return "\(kind.displayName) is temporarily unavailable"
        case .configurationInvalid: return "Provider configuration needs repair"
        case let .needsAttention(kind): return "\(kind.displayName) needs attention"
        case let .deprecated(kind): return "\(kind.displayName) needs a Cadence update"
        case .removed: return "Provider removed · provider setup required"
        }
    }

    var scribeReadiness: ScribeReadiness {
        let capabilities: ScribeProviderCapabilities
        if case .ready = scribeProviderReadiness {
            capabilities = [.semanticGeneration, .cancellation]
        } else {
            capabilities = []
        }
        return ScribeReadiness(
            privacyMode: Self.scribePrivacyMode,
            providerCapabilities: capabilities,
            permissionsGranted: permissions.allRequiredGranted
        )
    }

    var isOnboardingPresented: Bool {
        !onboardingProgress.isComplete && !onboardingProgress.wasSkipped
    }

    func savePersonalShortcut(_ shortcut: PersonalShortcut) {
        guard shortcut.isValid else {
            lastError = "Shortcut name and replacement text are required."
            return
        }
        if let index = personalizationLibrary.shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            personalizationLibrary.shortcuts[index] = shortcut
        } else {
            personalizationLibrary.shortcuts.append(shortcut)
        }
        persistPersonalizationLibrary()
    }

    func setSpokenShortcutsEnabled(_ enabled: Bool) {
        guard spokenShortcutsEnabled != enabled else { return }
        spokenShortcutsEnabled = enabled
        personalizationStore.setSpokenShortcutsEnabled(enabled)
    }

    func setPersonalShortcutEnabled(id: UUID, enabled: Bool) {
        guard let index = personalizationLibrary.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        personalizationLibrary.shortcuts[index].isEnabled = enabled
        persistPersonalizationLibrary()
    }

    func deletePersonalShortcut(id: UUID) {
        personalizationLibrary.shortcuts.removeAll { $0.id == id }
        persistPersonalizationLibrary()
    }

    func saveWritingStyleProfile(_ profile: WritingStyleProfile) {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Style profile name is required."
            return
        }
        if let index = personalizationLibrary.styleProfiles.firstIndex(where: { $0.id == profile.id }) {
            personalizationLibrary.styleProfiles[index] = profile
        } else {
            personalizationLibrary.styleProfiles.append(profile)
        }
        persistPersonalizationLibrary()
    }

    func setWritingStyleProfileEnabled(id: UUID, enabled: Bool) {
        guard let index = personalizationLibrary.styleProfiles.firstIndex(where: { $0.id == id }) else { return }
        personalizationLibrary.styleProfiles[index].isEnabled = enabled
        persistPersonalizationLibrary()
    }

    func deleteWritingStyleProfile(id: UUID) {
        personalizationLibrary.styleProfiles.removeAll { $0.id == id }
        persistPersonalizationLibrary()
    }

    var availableOnboardingSteps: [OnboardingStep] {
        OnboardingStep.availableSteps(scribeEnabled: featureFlags.scribeEnabled)
    }

    var currentOnboardingStep: OnboardingStep {
        let storedStep = onboardingProgress.currentStep
        if availableOnboardingSteps.contains(storedStep) {
            return storedStep
        }
        let storedIndex = OnboardingStep.allCases.firstIndex(of: storedStep) ?? 0
        return availableOnboardingSteps.first {
            (OnboardingStep.allCases.firstIndex(of: $0) ?? 0) > storedIndex
        } ?? .ready
    }

    var currentOnboardingVisibleIndex: Int {
        availableOnboardingSteps.firstIndex(of: currentOnboardingStep) ?? 0
    }

    func advanceOnboarding() {
        let nextVisibleIndex = currentOnboardingVisibleIndex + 1
        guard nextVisibleIndex < availableOnboardingSteps.count else {
            completeOnboarding()
            return
        }
        let nextStep = availableOnboardingSteps[nextVisibleIndex]
        onboardingProgress.stepIndex = OnboardingStep.allCases.firstIndex(of: nextStep) ?? 0
        saveOnboardingProgress()
    }

    func moveBackInOnboarding() {
        let previousVisibleIndex = currentOnboardingVisibleIndex - 1
        guard previousVisibleIndex >= 0 else { return }
        let previousStep = availableOnboardingSteps[previousVisibleIndex]
        onboardingProgress.stepIndex = OnboardingStep.allCases.firstIndex(of: previousStep) ?? 0
        saveOnboardingProgress()
    }

    func skipOnboarding() {
        onboardingProgress.wasSkipped = true
        saveOnboardingProgress()
    }

    func completeOnboarding() {
        onboardingProgress.stepIndex = OnboardingStep.allCases.count - 1
        onboardingProgress.isComplete = true
        onboardingProgress.wasSkipped = false
        saveOnboardingProgress()
    }

    func replayOnboarding() {
        onboardingProgress = .fresh
        saveOnboardingProgress()
    }

    func resumeOnboarding() {
        guard !onboardingProgress.isComplete else { return }
        onboardingProgress.wasSkipped = false
        saveOnboardingProgress()
    }

    private func saveOnboardingProgress() {
        do {
            try onboardingProgressStore.save(onboardingProgress)
        } catch {
            lastError = "Cadence could not save onboarding progress on this Mac."
        }
    }

    private func persistPersonalizationLibrary() {
        do {
            try personalizationStore.save(personalizationLibrary)
            lastError = nil
        } catch {
            lastError = "Cadence could not save personalization on this Mac."
        }
    }

    var primaryTriggerMode: DictationTriggerMode {
        if tapToStartStopBinding.isEnabled, !holdToTalkBinding.isEnabled {
            return .tapToStartStop
        }
        return .holdToTalk
    }

    var dictationQualityPreset: DictationQualityPreset {
        DictationQualityPreset.matching(transcriptionConfiguration)
    }

    var hotkeyConflictMessage: String? {
        let enabled = currentHotkeyBindings.filter(\.isEnabled)
        for index in enabled.indices {
            for otherIndex in enabled.indices where otherIndex > index {
                if enabled[index].shortcut.conflicts(with: enabled[otherIndex].shortcut) {
                    return "\(enabled[index].action.displayName) and \(enabled[otherIndex].action.displayName) need different shortcuts."
                }
            }
        }
        return nil
    }

    var setupProgressLabel: String {
        let completed = [permissions.microphoneGranted, permissions.accessibilityGranted, permissions.inputMonitoringGranted]
            .filter { $0 }
            .count
        return "\(completed)/3 permissions ready"
    }

    var setupSummaryTitle: String {
        permissions.allRequiredGranted ? "Mac setup complete" : "Finish setup"
    }

    var setupSummaryDetail: String {
        if permissions.allRequiredGranted {
            return "Cadence has microphone, accessibility, and shortcut access."
        }

        let missing = missingPermissionNames
        if missing.count == 1, let item = missing.first {
            return "Grant \(item.lowercased()) to start dictating anywhere."
        }
        return "Grant \(missing.joined(separator: ", ").lowercased()) to finish setup."
    }

    var modelReadinessSummary: ModelReadinessSummary {
        if let error = userFacingErrorMessage {
            return ModelReadinessSummary(
                title: "Model setup needs attention",
                detail: error,
                tone: .attention
            )
        }

        let lowercasedSummary = backendDescription.lowercased()
        let presetName = dictationQualityPreset.displayName

        if lowercasedSummary.contains("ready to load") || lowercasedSummary.contains("loading transcription backend") {
            return ModelReadinessSummary(
                title: "\(presetName) is ready when you are",
                detail: "Cadence will finish loading this model the first time you dictate.",
                tone: .ready
            )
        }

        if lowercasedSummary.contains("unavailable") {
            return ModelReadinessSummary(
                title: "Model setup needs attention",
                detail: "Cadence could not prepare the selected model yet.",
                tone: .attention
            )
        }

        if lowercasedSummary.contains("download") || lowercasedSummary.contains("prepare") {
            return ModelReadinessSummary(
                title: "Preparing \(presetName.lowercased())",
                detail: "Cadence may need a moment to finish local model setup.",
                tone: .working
            )
        }

        return ModelReadinessSummary(
            title: "\(presetName) is ready",
            detail: "Using \(transcriptionConfiguration.model.shortLabel) for \(primaryTriggerMode.shortDescription.lowercased())",
            tone: .ready
        )
    }

    var userFacingErrorMessage: String? {
        guard let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty else {
            return nil
        }

        return Self.humanizedErrorMessage(lastError)
    }

    var selectedMeetingNote: MeetingNote? {
        guard let selectedMeetingNoteID else { return nil }
        return meetingNotes.first { $0.id == selectedMeetingNoteID }
    }

    var googleOAuthRedirectURI: String {
        GoogleCalendarOAuthConfiguration(
            clientID: googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "cadence-placeholder.apps.googleusercontent.com",
            redirectScheme: googleOAuthRedirectScheme.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? Self.defaultGoogleOAuthRedirectScheme()
        ).redirectURI
    }

    var isGoogleCalendarSignInAvailable: Bool {
        googleCalendarConfiguration != nil
    }

    var meetingCaptureSession: MeetingCaptureSessionSummary? {
        guard let activeMeetingCaptureNoteID,
              let phase = meetingCapturePhase(for: systemAudioCaptureState) else {
            return nil
        }

        return MeetingCaptureSessionSummary(
            noteID: activeMeetingCaptureNoteID,
            noteTitle: meetingNotes.first { $0.id == activeMeetingCaptureNoteID }?.displayTitle ?? "Meeting note",
            source: meetingCaptureSource,
            phase: phase,
            startedAt: activeMeetingCaptureStartedAt,
            capturedFrameCount: systemAudioCapturedFrameCount,
            level: systemAudioCaptureLevel
        )
    }

    func refreshPermissions() async {
        let previousPermissions = permissions
        permissions = permissionsService.snapshot()
        permissionGuideWindowController.updatePermissions(permissions)
        if permissions != previousPermissions {
            analytics.track(
                "permissions_granted_changed",
                properties: [
                    "microphone": String(permissions.microphoneGranted),
                    "accessibility": String(permissions.accessibilityGranted),
                    "inputMonitoring": String(permissions.inputMonitoringGranted)
                ]
            )
            if !previousPermissions.allRequiredGranted, permissions.allRequiredGranted {
                analytics.track("setup_completed")
            }
        }
        analytics.track(
            "permissions_refreshed",
            properties: [
                "microphone": String(permissions.microphoneGranted),
                "accessibility": String(permissions.accessibilityGranted),
                "inputMonitoring": String(permissions.inputMonitoringGranted)
            ]
        )

        applyHUDIdleVisibilityPolicy()
        if permissions.allRequiredGranted, hudVisibility.showsIdleBar, isDictationIdle {
            coordinator.presentLogoIdle()
        }
    }

    func requestMicrophoneAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "microphone"])
        Task {
            _ = await permissionsService.requestMicrophoneAccess()
            await refreshPermissions()
            schedulePermissionRefreshBurst()
        }
    }

    func requestAccessibilityAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "accessibility"])
        permissionsService.requestAccessibilityAccess()
        schedulePermissionRefreshBurst()
    }

    func requestInputMonitoringAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "inputMonitoring"])
        permissionsService.requestInputMonitoringAccess()
        schedulePermissionRefreshBurst()
    }

    func openPermissionsWizard() {
        analytics.track("permissions_wizard_opened")
        NSApp.activate()
        permissionGuideWindowController.show(
            permissions: permissions,
            appURL: Bundle.main.bundleURL,
            onRequestMicrophone: { [weak self] in
                self?.requestMicrophoneAccess()
            },
            onRequestAccessibility: { [weak self] in
                self?.requestAccessibilityAccess()
            },
            onRequestInputMonitoring: { [weak self] in
                self?.requestInputMonitoringAccess()
            },
            onRefresh: { [weak self] in
                Task { await self?.refreshPermissions() }
            }
        )
        schedulePermissionRefreshBurst()
    }

    func showSettingsScreen() {
        analytics.track("screen_opened", properties: ["screen": "settings"])
        menuScreen = .settings
    }

    func showSettingsWindow() {
        NSApp.activate()
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func showMainWindow() {
        preferencesLogger.info("Cadence main window requested")
        analytics.track("main_window_opened")
        mainWindowController.show(appModel: self)
    }

    func showHomeScreen() {
        analytics.track("screen_opened", properties: ["screen": "home"])
        menuScreen = .home
    }

    func showMeetingNotesWindow() {
        guard featureFlags.granolaEnabled else { return }
        refreshDerivedMeetingTitles()
        pruneBlankMeetingDrafts(keepingMostRecentIfOnlyDrafts: true)
        if selectedMeetingNoteID == nil {
            selectedMeetingNoteID = meetingNotes.first?.id
        }
        analytics.track("meeting_notes_window_opened")
        mainWindowController.show(appModel: self)
    }

    @discardableResult
    func createMeetingNote(openWindow: Bool = true) -> MeetingNote? {
        guard featureFlags.granolaEnabled else { return nil }
        pruneBlankMeetingDrafts(keepingMostRecentIfOnlyDrafts: false)
        var note = MeetingNote()
        note.updatedAt = note.createdAt
        meetingNotes.insert(note, at: 0)
        selectedMeetingNoteID = note.id
        persistMeetingNote(note)
        analytics.track("meeting_note_created")
        if openWindow {
            showMeetingNotesWindow()
        }
        return note
    }

    private func pruneBlankMeetingDrafts(keepingMostRecentIfOnlyDrafts: Bool) {
        let blankDrafts = meetingNotes
            .filter(\.isBlankDraft)
            .sorted { $0.updatedAt > $1.updatedAt }
        let hasRealNotes = meetingNotes.contains { !$0.isBlankDraft }
        let shouldKeepOneDraft = keepingMostRecentIfOnlyDrafts && !hasRealNotes
        let draftIDsToKeep = Set(shouldKeepOneDraft ? blankDrafts.prefix(1).map(\.id) : [])
        let blankDraftIDs = blankDrafts
            .map(\.id)
            .filter { !draftIDsToKeep.contains($0) }
        guard !blankDraftIDs.isEmpty else { return }

        meetingNotes.removeAll { blankDraftIDs.contains($0.id) }
        if let selectedMeetingNoteID, blankDraftIDs.contains(selectedMeetingNoteID) {
            self.selectedMeetingNoteID = meetingNotes.first?.id
        }
        for id in blankDraftIDs {
            try? meetingStore.delete(id: id)
        }
    }

    func selectMeetingNote(id: UUID?) {
        selectedMeetingNoteID = id
    }

    func openMeetingNote(id: UUID) {
        guard featureFlags.granolaEnabled else { return }
        selectedMeetingNoteID = id
        showMeetingNotesWindow()
    }

    /// Dismisses a recovery item while preserving its audio on disk.
    func keepOrphanedRecording(_ orphan: OrphanedMeetingRecording) {
        var acknowledged = OrphanRecordingAcknowledgements.load(
            defaults.stringArray(forKey: PreferenceKey.acknowledgedOrphanRecordingIDs)
        )
        acknowledged.insert(orphan.id)
        defaults.set(acknowledged.map(\.uuidString), forKey: PreferenceKey.acknowledgedOrphanRecordingIDs)
        recoverableOrphanedRecordings.removeAll { $0.id == orphan.id }
    }

    /// User-triggered discard of an unrecoverable orphaned recording.
    func discardOrphanedRecording(_ orphan: OrphanedMeetingRecording) {
        if meetingAudioStore.discardOrphanedRecording(orphan) {
            var acknowledged = OrphanRecordingAcknowledgements.load(
                defaults.stringArray(forKey: PreferenceKey.acknowledgedOrphanRecordingIDs)
            )
            acknowledged.remove(orphan.id)
            defaults.set(acknowledged.map(\.uuidString), forKey: PreferenceKey.acknowledgedOrphanRecordingIDs)
            recoverableOrphanedRecordings.removeAll { $0.id == orphan.id }
        } else {
            lastError = "Cadence could not discard that recovered recording."
        }
    }

    func updateMeetingNote(id: UUID, title: String?, userNotes: String?) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == id }) else { return }

        if let title {
            meetingNotes[index].title = title
        }
        if let userNotes {
            meetingNotes[index].userNotes = userNotes
        }
        if meetingNotes[index].usesDefaultTitle, let suggestedTitle = meetingNotes[index].suggestedTitle {
            meetingNotes[index].title = suggestedTitle
        }
        meetingNotes[index].updatedAt = Date()

        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        selectedMeetingNoteID = updatedNote.id
        persistMeetingNote(updatedNote)
    }

    func deleteMeetingNote(id: UUID) {
        if activeMeetingCaptureNoteID == id, systemAudioCaptureState.isCaptureBusy {
            lastError = "Stop recording before deleting this meeting note."
            return
        }

        guard let index = meetingNotes.firstIndex(where: { $0.id == id }) else { return }
        let note = meetingNotes[index]
        meetingNotes.remove(at: index)
        do {
            meetingAudioStore.deleteRecordings(for: note)
            try meetingStore.delete(id: id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        if selectedMeetingNoteID == id {
            selectedMeetingNoteID = meetingNotes.first?.id
        }
        analytics.track("meeting_note_deleted")
    }

    private func refreshDerivedMeetingTitles() {
        var changedNotes = [MeetingNote]()
        for index in meetingNotes.indices {
            guard meetingNotes[index].usesDefaultTitle,
                  let suggestedTitle = meetingNotes[index].suggestedTitle else {
                continue
            }
            meetingNotes[index].title = suggestedTitle
            changedNotes.append(meetingNotes[index])
        }
        for note in changedNotes {
            persistMeetingNote(note)
        }
    }

    func filteredMeetingNotes(query: String) -> [MeetingNote] {
        meetingStore.search(meetingNotes, query: query)
    }

    func generateSummaryForSelectedMeetingNote() {
        guard let noteID = selectedMeetingNoteID else { return }
        generateSummary(for: noteID)
    }

    func copySelectedMeetingNoteMarkdown() {
        guard let note = selectedMeetingNote else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingMarkdownFormatter.markdown(for: note), forType: .string)
        analytics.track("meeting_note_markdown_copied")
    }

    func exportSelectedMeetingNoteMarkdown() {
        guard let note = selectedMeetingNote else { return }

        let panel = NSSavePanel()
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.nameFieldStringValue = "\(Self.sanitizedFilename(note.displayTitle)).md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try MeetingMarkdownFormatter.markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
            lastError = nil
            analytics.track("meeting_note_markdown_exported")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connectGoogleCalendar() {
        guard featureFlags.granolaEnabled else { return }
        guard let googleCalendarConfiguration else {
            googleCalendarConnectionState = GoogleCalendarConnectionState(
                isConfigured: false,
                isConnected: false,
                accountEmail: nil,
                errorMessage: GoogleCalendarError.missingClientID.localizedDescription
            )
            lastError = GoogleCalendarError.missingClientID.localizedDescription
            return
        }

        guard !isConnectingGoogleCalendar else { return }
        isConnectingGoogleCalendar = true
        googleCalendarConnectionState.errorMessage = nil
        analytics.track("google_calendar_connect_clicked")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isConnectingGoogleCalendar = false }
            do {
                try await self.googleCalendarService.signIn(configuration: googleCalendarConfiguration)
                self.googleCalendarConnectionState = self.googleCalendarService.connectionState(configuration: googleCalendarConfiguration)
                await self.refreshTodayTomorrowCalendarEvents()
                self.lastError = nil
                self.showMainWindow()
                NSApp.activate()
                self.analytics.track("google_calendar_connected")
            } catch {
                self.googleCalendarConnectionState = GoogleCalendarConnectionState(
                    isConfigured: true,
                    isConnected: false,
                    accountEmail: nil,
                    errorMessage: error.localizedDescription
                )
                self.lastError = error.localizedDescription
                self.analytics.track("google_calendar_connect_failed")
            }
        }
    }

    func disconnectGoogleCalendar() {
        do {
            try googleCalendarService.signOut()
            try? calendarEventCacheStore.delete()
            upcomingCalendarMeetings = []
            isConnectingGoogleCalendar = false
            googleCalendarConnectionState = googleCalendarService.connectionState(configuration: googleCalendarConfiguration)
            lastError = nil
            analytics.track("google_calendar_disconnected")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setGoogleOAuthClientID(_ clientID: String) {
        googleOAuthClientID = clientID
        defaults.set(clientID, forKey: PreferenceKey.googleOAuthClientID)
        reloadGoogleCalendarConfiguration()
    }

    func setGoogleOAuthRedirectScheme(_ redirectScheme: String) {
        googleOAuthRedirectScheme = redirectScheme
        defaults.set(redirectScheme, forKey: PreferenceKey.googleOAuthRedirectScheme)
        reloadGoogleCalendarConfiguration()
    }

    func copyGoogleOAuthRedirectURI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(googleOAuthRedirectURI, forType: .string)
        analytics.track("google_oauth_redirect_uri_copied")
    }

    func openGoogleOAuthCredentialsSetup() {
        if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
            analytics.track("google_oauth_credentials_setup_opened")
        }
    }

    func refreshUpcomingCalendarMeetings() async {
        await refreshTodayTomorrowCalendarEvents()
    }

    func refreshTodayTomorrowCalendarEvents() async {
        guard featureFlags.granolaEnabled else {
            upcomingCalendarMeetings = []
            detectedCalendarMeeting = nil
            isRefreshingCalendar = false
            return
        }
        googleCalendarConnectionState = googleCalendarService.connectionState(configuration: googleCalendarConfiguration)
        guard googleCalendarConnectionState.isConnected else {
            isRefreshingCalendar = false
            return
        }

        isRefreshingCalendar = true
        do {
            let now = Date()
            let windowEnd = CalendarEventDashboard.endOfTomorrow(now: now)
            let events = try await googleCalendarService.upcomingEvents(
                limit: 30,
                now: now,
                timeMax: windowEnd,
                configuration: googleCalendarConfiguration
            )
            upcomingCalendarMeetings = events
            try? calendarEventCacheStore.save(
                CalendarEventCache(
                    generatedAt: Date(),
                    windowStart: now,
                    windowEnd: windowEnd,
                    events: events
                )
            )
            lastError = nil
            analytics.track("google_calendar_events_refreshed", properties: ["count": .int(upcomingCalendarMeetings.count)])
            evaluateCalendarMeetingDetection()
        } catch {
            if let cachedEvents = try? calendarEventCacheStore.load()?.events {
                upcomingCalendarMeetings = cachedEvents
            }
            googleCalendarConnectionState.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            analytics.track("google_calendar_events_refresh_failed")
        }
        isRefreshingCalendar = false
    }

    func refreshUpcomingCalendarMeetingsFromUI() {
        Task { @MainActor [weak self] in
            await self?.refreshUpcomingCalendarMeetings()
        }
    }

    func calendarMeetingCandidates(startingWithin interval: TimeInterval = 5 * 60, from date: Date = Date()) -> [GoogleCalendarEvent] {
        guard featureFlags.granolaEnabled else { return [] }
        return upcomingCalendarMeetings.filter {
            $0.isMeetingCandidate && $0.startsWithin(interval, from: date)
        }
    }

    func startDetectedCalendarMeetingCapture() {
        guard featureFlags.granolaEnabled else { return }
        guard let event = detectedCalendarMeeting else { return }
        _ = startCalendarEventCapture(event)
        detectedCalendarMeeting = nil
        analytics.track("calendar_meeting_capture_started")
    }

    @discardableResult
    func startCalendarEventCapture(_ event: GoogleCalendarEvent) -> MeetingNote? {
        guard featureFlags.granolaEnabled else { return nil }
        guard let note = prepareMeetingNote(for: event) else { return nil }
        selectedMeetingNoteID = note.id

        if let meetingURL = event.meetingURL {
            NSWorkspace.shared.open(meetingURL)
        } else if let calendarURL = event.calendarURL {
            NSWorkspace.shared.open(calendarURL)
        }

        showMainWindow()
        startMeetingCaptureForSelectedMeeting()
        analytics.track("calendar_event_join_record_clicked")
        return note
    }

    func openCalendarEvent(_ event: GoogleCalendarEvent) {
        if let url = event.calendarURL ?? event.meetingURL {
            NSWorkspace.shared.open(url)
            analytics.track("calendar_event_opened")
        }
    }

    func joinCalendarEvent(_ event: GoogleCalendarEvent) {
        guard let meetingURL = event.meetingURL else { return }
        NSWorkspace.shared.open(meetingURL)
        analytics.track(
            "calendar_event_join_clicked",
            properties: ["provider": .string(event.meetingProvider?.rawValue ?? GoogleMeetingProvider.other.rawValue)]
        )
    }

    private func prepareMeetingNote(for event: GoogleCalendarEvent) -> MeetingNote? {
        var note: MeetingNote
        if let existingIndex = meetingNotes.firstIndex(where: { $0.calendarEventID == event.id }) {
            note = meetingNotes[existingIndex]
            selectedMeetingNoteID = note.id
        } else {
            guard let createdNote = createMeetingNote(openWindow: false) else { return nil }
            note = createdNote
        }

        if note.usesDefaultTitle || note.title == "Untitled Meeting" {
            note.title = CalendarEventDashboard.calendarMeetingNoteTitle(for: event)
        }
        if note.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.userNotes = Self.calendarMeetingNoteTemplate(for: event)
        }
        note.calendarEventID = event.id
        note.updatedAt = Date()

        if let index = meetingNotes.firstIndex(where: { $0.id == note.id }) {
            meetingNotes[index] = note
            meetingNotes.remove(at: index)
            meetingNotes.insert(note, at: 0)
            selectedMeetingNoteID = note.id
            persistMeetingNote(note)
        }

        return note
    }

    func requestScreenRecordingAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "screenRecording"])
        _ = permissionsService.requestScreenRecordingAccess()
        schedulePermissionRefreshBurst()
    }

    func requestMeetingCaptureSourcePermissions() {
        guard featureFlags.granolaEnabled else { return }
        if meetingCaptureSource.requiresMicrophone, !permissions.microphoneGranted {
            requestMicrophoneAccess()
        }
        if meetingCaptureSource.requiresScreenRecording, !permissions.screenRecordingGranted {
            requestScreenRecordingAccess()
        }
    }

    func setMeetingCaptureSource(_ source: MeetingCaptureSource) {
        guard meetingCaptureSource != source else { return }
        guard !systemAudioCaptureState.isCaptureBusy else { return }
        meetingCaptureSource = source
        defaults.set(source.rawValue, forKey: PreferenceKey.meetingCaptureSource)
        analytics.track("setting_changed", properties: ["setting": "meetingCaptureSource", "value": source.rawValue])
    }

    func cycleAppearancePreference() {
        setAppearancePreference(appearancePreference.next)
    }

    func setAppearancePreference(_ preference: AppearancePreference) {
        guard appearancePreference != preference else { return }
        appearancePreference = preference
        defaults.set(preference.rawValue, forKey: PreferenceKey.appearancePreference)
        applyAppearancePreference()
        hudController.setAppearancePreference(preference)
        analytics.track("setting_changed", properties: ["setting": "appearancePreference", "value": preference.rawValue])
    }

    func toggleMeetingCaptureForSelectedMeeting() {
        if systemAudioCaptureState.isCapturing || systemAudioCaptureState == .stopping {
            stopMeetingCapture()
        } else if systemAudioCaptureState == .starting {
            return
        } else {
            startMeetingCaptureForSelectedMeeting()
        }
    }

    func toggleSystemAudioCaptureForSelectedMeeting() {
        toggleMeetingCaptureForSelectedMeeting()
    }

    func selectActiveMeetingCaptureNote() {
        guard let activeMeetingCaptureNoteID else { return }
        selectedMeetingNoteID = activeMeetingCaptureNoteID
    }

    func startMeetingCaptureForSelectedMeeting() {
        guard featureFlags.granolaEnabled else { return }
        guard meetingCaptureStopTask == nil else { return }
        guard !systemAudioCaptureState.isCaptureBusy else { return }
        if selectedMeetingNoteID == nil {
            _ = createMeetingNote(openWindow: false)
        }
        guard let targetNoteID = selectedMeetingNoteID else { return }

        if meetingCaptureSource.requiresMicrophone, !permissions.microphoneGranted {
            systemAudioCaptureState = .failed("Microphone permission is required for \(meetingCaptureSource.displayName).")
            activeMeetingCaptureNoteID = nil
            activeMeetingCaptureStartedAt = nil
            requestMicrophoneAccess()
            return
        }

        if meetingCaptureSource.requiresScreenRecording, !permissions.screenRecordingGranted {
            systemAudioCaptureState = .failed(SystemAudioCaptureError.screenRecordingPermissionRequired.localizedDescription)
            activeMeetingCaptureNoteID = nil
            activeMeetingCaptureStartedAt = nil
            requestScreenRecordingAccess()
            return
        }

        do {
            meetingVoiceSessionLease = try voiceSessionArbiter.acquire(for: .meeting)
        } catch let VoiceSessionArbiterError.busy(activeKind) {
            systemAudioCaptureState = .failed("Stop the active \(activeKind.displayName) session before recording a meeting.")
            return
        } catch {
            systemAudioCaptureState = .failed("Cadence could not reserve audio capture for this meeting.")
            return
        }

        let captureSource = meetingCaptureSource
        let recordingID = UUID()
        let audioRecorder: MeetingAudioRecorder
        do {
            audioRecorder = try meetingAudioStore.makeRecorder(
                noteID: targetNoteID,
                recordingID: recordingID,
                source: captureSource
            )
        } catch {
            releaseMeetingVoiceSessionLease()
            systemAudioCaptureState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return
        }

        activeMeetingCaptureNoteID = targetNoteID
        activeMeetingRecordingID = recordingID
        activeMeetingAudioRecorder = audioRecorder
        let chunkQueue = MeetingCaptureChunkQueue()
        activeMeetingCaptureChunkQueue = chunkQueue
        activeMeetingCaptureStartedAt = Date()
        let ledgerEntry = MeetingAudioRecordingMetadata(
            id: recordingID,
            fileName: MeetingAudioStore.recordingFileName(noteID: targetNoteID, recordingID: recordingID),
            source: captureSource,
            createdAt: activeMeetingCaptureStartedAt ?? Date(),
            state: .recording
        )
        appendMeetingAudioRecording(ledgerEntry, noteID: targetNoteID)
        systemAudioCaptureState = .starting
        systemAudioCaptureLevel = 0
        systemAudioCapturedFrameCount = 0
        let transcriptionService = meetingTranscriptionService
        updateMeetingTranscriptState(
            noteID: targetNoteID,
            state: .liveDraft,
            message: "Recording live draft"
        )
        let chunkHandler = makeMeetingCaptureChunkHandler(
            noteID: targetNoteID,
            source: captureSource,
            service: transcriptionService,
            recorder: audioRecorder,
            recordingID: recordingID,
            queue: chunkQueue
        )
        analytics.track("meeting_capture_started", properties: ["source": .string(meetingCaptureSource.rawValue)])

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.meetingTranscriptionService.start(
                    configuration: Self.meetingCaptureTranscriptionConfiguration(from: self.transcriptionConfiguration)
                )
                if self.meetingCaptureSource.requiresMicrophone {
                    try self.meetingMicrophoneCaptureService.startCapture(chunkHandler: chunkHandler)
                    self.meetingMicrophoneCaptureActive = true
                }

                if self.meetingCaptureSource.requiresScreenRecording {
                    try await self.systemAudioCaptureService.startCapture(chunkHandler: chunkHandler)
                    self.meetingSystemAudioCaptureActive = true
                }
                self.systemAudioCaptureState = .capturing
                self.lastError = nil
            } catch {
                _ = await self.stopActiveMeetingCaptureServices()
                await chunkQueue.drain()
                await transcriptionService.cancel()
                do {
                    let preservedRecording = try await audioRecorder.finishAfterCaptureStartFailure()
                    if let preservedRecording {
                        self.appendMeetingAudioRecording(preservedRecording, noteID: targetNoteID)
                        self.updateMeetingTranscriptState(
                            noteID: targetNoteID,
                            state: .finalizationFailed,
                            message: "Recording was interrupted while starting. Your audio and draft transcript are saved — run the final transcript when ready."
                        )
                    } else {
                        self.removeEmptyMeetingRecordingLedger(
                            recordingID: recordingID,
                            noteID: targetNoteID
                        )
                    }
                } catch {
                    self.setMeetingRecordingState(.finalizationFailed, recordingID: recordingID, noteID: targetNoteID)
                    self.updateMeetingTranscriptState(
                        noteID: targetNoteID,
                        state: .finalizationFailed,
                        message: "Recording could not start, and Cadence could not clean up its empty audio file."
                    )
                }
                self.activeMeetingCaptureNoteID = nil
                self.activeMeetingRecordingID = nil
                self.activeMeetingAudioRecorder = nil
                self.activeMeetingCaptureChunkQueue = nil
                self.activeMeetingCaptureStartedAt = nil
                self.releaseMeetingVoiceSessionLease()
                self.systemAudioCaptureState = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
                self.analytics.track(
                    "meeting_capture_failed",
                    properties: [
                        "source": .string(self.meetingCaptureSource.rawValue),
                        "reason": .string(Self.analyticsErrorReason(for: error))
                    ]
                )
            }
        }
    }

    func startSystemAudioCaptureForSelectedMeeting() {
        startMeetingCaptureForSelectedMeeting()
    }

    func stopMeetingCapture() {
        guard meetingCaptureStopTask == nil else { return }
        guard systemAudioCaptureState.isCaptureBusy ||
            activeMeetingCaptureNoteID != nil ||
            meetingMicrophoneCaptureActive ||
            meetingSystemAudioCaptureActive else { return }
        systemAudioCaptureState = .stopping
        systemAudioCaptureLevel = 0
        analytics.track("meeting_capture_stopped", properties: ["source": .string(meetingCaptureSource.rawValue)])
        meetingCaptureStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.meetingCaptureStopTask = nil }
            let noteID = self.activeMeetingCaptureNoteID
            let recordingID = self.activeMeetingRecordingID
            let recorder = self.activeMeetingAudioRecorder
            let chunkQueue = self.activeMeetingCaptureChunkQueue
            let source = self.meetingCaptureSource
            let service = self.meetingTranscriptionService
            self.systemAudioCaptureLevel = 0
            let metrics = await self.stopActiveMeetingCaptureServicesWithTimeout()
            self.releaseMeetingVoiceSessionLease()
            await chunkQueue?.drain()
            self.systemAudioCapturedFrameCount = metrics.frameCount
            var recording = await recorder?.finish(fallbackMetrics: metrics)
            recording?.state = .recorded

            if self.meetingTranscriptionService === service {
                self.meetingTranscriptionService = Self.makeMeetingTranscriptionService()
            }
            self.activeMeetingCaptureNoteID = nil
            self.activeMeetingRecordingID = nil
            self.activeMeetingAudioRecorder = nil
            self.activeMeetingCaptureChunkQueue = nil
            self.activeMeetingCaptureStartedAt = nil
            self.systemAudioCaptureState = .idle

            if let noteID, let recording {
                self.appendMeetingAudioRecording(recording, noteID: noteID)
                self.updateMeetingTranscriptState(
                    noteID: noteID,
                    state: .finalizing,
                    message: "Creating final transcript from saved audio"
                )
            }

            _ = await self.finalizeMeetingTranscription(
                for: noteID,
                source: source,
                service: service,
                recordingID: recordingID,
                origin: .liveDraft
            )

            if let noteID, let recording {
                await self.runFinalTranscriptionPass(
                    noteID: noteID,
                    recording: recording
                )
            }
        }
    }

    func stopSystemAudioCapture() {
        stopMeetingCapture()
    }

    /// Re-runs the final pass for a previously failed recording, straight from
    /// its saved audio. Idempotent and unlimited — re-running replaces that
    /// recording's segments rather than duplicating them.
    func retryFinalTranscriptionPass(noteID: UUID, recordingID: UUID) {
        guard let note = meetingNotes.first(where: { $0.id == noteID }),
              let recording = note.effectiveAudioRecordings.first(where: { $0.id == recordingID }),
              recording.effectiveState != .finalizing else {
            return
        }
        setMeetingRecordingState(.finalizing, recordingID: recordingID, noteID: noteID)
        updateMeetingTranscriptState(
            noteID: noteID,
            state: .finalizing,
            message: "Retrying final transcript from saved audio"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFinalTranscriptionPass(noteID: noteID, recording: recording)
        }
    }

    /// Restores the retained live-draft segments for a recording, discarding its
    /// final pass. The user's explicit "revert" action from the lineage affordance.
    func revertFinalPass(noteID: UUID, recordingID: UUID) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        guard meetingNotes[index].effectiveAudioRecordings
            .first(where: { $0.id == recordingID })?.effectiveState != .finalizing else { return }
        meetingNotes[index].revertFinalPass(for: recordingID)
        if var recordings = meetingNotes[index].audioRecordings,
           let recordingIndex = recordings.firstIndex(where: { $0.id == recordingID }) {
            recordings[recordingIndex].state = .recorded
            meetingNotes[index].audioRecordings = recordings
        }
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    /// Accepts the final pass for a recording, clearing the retained draft so the
    /// lineage affordance dismisses.
    func acceptFinalPass(noteID: UUID, recordingID: UUID) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        guard meetingNotes[index].effectiveAudioRecordings
            .first(where: { $0.id == recordingID })?.effectiveState != .finalizing else { return }
        meetingNotes[index].acceptFinalPass(for: recordingID)
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    func renameSpeaker(noteID: UUID, speakerID: UUID, displayName: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        commitSpeakerEdit(noteID: noteID) { note in
            note.renameSpeaker(id: speakerID, to: trimmedName)
        }
    }

    func mergeSpeakers(noteID: UUID, sourceID: UUID, targetID: UUID) {
        guard sourceID != targetID else { return }
        commitSpeakerEdit(noteID: noteID) { note in
            note.mergeSpeakers(from: sourceID, into: targetID)
        }
    }

    func splitSpeaker(noteID: UUID, sourceID: UUID, displayName: String, segmentIDs: [UUID]) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !segmentIDs.isEmpty else { return }
        commitSpeakerEdit(noteID: noteID) { note in
            note.splitSpeaker(from: sourceID, named: trimmedName, turnSegmentIDs: segmentIDs)
        }
    }

    func assignSpeaker(noteID: UUID, displayName: String, segmentIDs: [UUID]) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !segmentIDs.isEmpty else { return }
        commitSpeakerEdit(noteID: noteID) { note in
            note.assignSpeaker(named: trimmedName, turnSegmentIDs: segmentIDs)
        }
    }

    private func commitSpeakerEdit(noteID: UUID, mutate: (inout MeetingNote) -> Void) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        let originalNote = meetingNotes[index]
        mutate(&meetingNotes[index])
        guard meetingNotes[index] != originalNote else { return }
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        selectedMeetingNoteID = updatedNote.id
        persistMeetingNote(updatedNote)
    }

    func startStopDemoInsert() {
        Task {
            do {
                if focusedApplicationMonitor.activateMostRecentValidatedExternal() {
                    try? await Task.sleep(for: .milliseconds(180))
                }
                try await coordinator.insertPreviewText()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func runSetupCheck() {
        analytics.track("setup_check_started")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPermissions()
            await self.warmBackend()
        }
    }

    func warmBackend() async {
        let startedAt = Date()
        let properties = backendAnalyticsProperties()
        analytics.track("engine_prepare_started", properties: properties)
        do {
            let summary = try await coordinator.prewarmBackend()
            lastError = nil
            backendDescription = summary
            var completedProperties = properties
            completedProperties["durationMs"] = .int(Self.analyticsMilliseconds(Date().timeIntervalSince(startedAt)))
            completedProperties["backend"] = .string("whisperkit")
            analytics.track("engine_prepare_completed", properties: completedProperties)
        } catch {
            guard !Self.isBenignModelLoadCancellation(error) else {
                preferencesLogger.info("Ignored canceled background model load")
                return
            }
            lastError = error.localizedDescription
            backendDescription = "Transcription backend unavailable"
            var failureProperties = properties
            failureProperties["durationMs"] = .int(Self.analyticsMilliseconds(Date().timeIntervalSince(startedAt)))
            failureProperties["reason"] = .string(Self.analyticsErrorReason(for: error))
            analytics.track("engine_prepare_failed", properties: failureProperties)
            analytics.track("model_load_failed", properties: failureProperties)
        }
    }

    func setWhisperModel(_ model: WhisperModelOption) {
        analytics.track("setting_changed", properties: ["setting": "model", "value": model.rawValue])
        updateTranscriptionConfiguration { $0.model = model }
    }

    func setDecodingMode(_ decodingMode: WhisperDecodingMode) {
        analytics.track("setting_changed", properties: ["setting": "decoding", "value": decodingMode.rawValue])
        updateTranscriptionConfiguration { $0.decodingMode = decodingMode }
    }

    func setFillerWordPolicy(_ fillerWordPolicy: FillerWordPolicy) {
        analytics.track("setting_changed", properties: ["setting": "fillers", "value": fillerWordPolicy.rawValue])
        updateTranscriptionConfiguration { $0.fillerWordPolicy = fillerWordPolicy }
    }

    func setKeepContext(_ keepContext: Bool) {
        analytics.track("setting_changed", properties: ["setting": "keepContext", "value": String(keepContext)])
        updateTranscriptionConfiguration { $0.keepContext = keepContext }
    }

    func setTrimSilence(_ trimSilence: Bool) {
        analytics.track("setting_changed", properties: ["setting": "trimSilence", "value": String(trimSilence)])
        updateTranscriptionConfiguration { $0.trimSilence = trimSilence }
    }

    func setNormalizeAudio(_ normalizeAudio: Bool) {
        analytics.track("setting_changed", properties: ["setting": "normalizeAudio", "value": String(normalizeAudio)])
        updateTranscriptionConfiguration { $0.normalizeAudio = normalizeAudio }
    }

    func setWaveformSensitivity(_ sensitivity: Double) {
        let sanitizedSensitivity = Self.sanitizedWaveformSensitivity(sensitivity)
        guard waveformSensitivity != sanitizedSensitivity else { return }
        waveformSensitivity = sanitizedSensitivity
        defaults.set(sanitizedSensitivity, forKey: PreferenceKey.waveformSensitivity)
        coordinator.updateWaveformSensitivity(sanitizedSensitivity)
        analytics.track(
            "setting_changed",
            properties: [
                "setting": "waveformSensitivity",
                "value": String(format: "%.1f", sanitizedSensitivity)
            ]
        )
    }

    #if DEBUG
    func setHUDMotionTuning(_ tuning: HUDMotionTuning) {
        let sanitized = Self.sanitizedHUDMotionTuning(tuning)
        guard hudMotionTuning != sanitized else { return }
        hudMotionTuning = sanitized
        defaults.set(sanitized.pillResponse, forKey: PreferenceKey.hudPillResponse)
        defaults.set(sanitized.micFadeOutDuration, forKey: PreferenceKey.hudMicFadeOutDuration)
        defaults.set(sanitized.appCueFadeInDuration, forKey: PreferenceKey.hudAppCueFadeInDuration)
        defaults.set(sanitized.waveformFadeInDuration, forKey: PreferenceKey.hudWaveformFadeInDuration)
        hudController.viewModel.setMotionTuning(sanitized)
    }

    func resetHUDMotionTuning() {
        setHUDMotionTuning(.default)
    }

    private var canPreviewHUDMotion: Bool {
        if state == .idle { return true }
        if case .error = state { return true }
        return false
    }

    func previewHUDMotionTransition() {
        guard canPreviewHUDMotion else { return }
        hudMotionPreviewTask?.cancel()
        let previewBars = [
            0.10, 0.22, 0.38, 0.58, 0.76, 0.92, 0.68, 0.48,
            0.34, 0.62, 0.86, 0.72, 0.52, 0.32, 0.20, 0.12
        ]
        hudController.update(with: .logoIdle)
        hudMotionPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let self,
                  self.canPreviewHUDMotion else { return }
            self.hudController.update(with: HUDState(
                visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
                subtitle: "",
                level: 0.7,
                waveformLevels: previewBars,
                isVisible: true,
                showsSubtitle: false
            ))
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled, self.canPreviewHUDMotion else { return }
            self.hudController.update(with: HUDState(
                visualState: .transcribing,
                subtitle: "",
                level: 0,
                waveformLevels: Array(repeating: 0, count: 16),
                isVisible: true,
                showsSubtitle: false
            ))
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, self.canPreviewHUDMotion else { return }
            self.hudController.update(with: HUDState(
                visualState: .copied,
                subtitle: "",
                level: 0,
                waveformLevels: Array(repeating: 0, count: 16),
                isVisible: true,
                showsSubtitle: false
            ))
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, self.canPreviewHUDMotion else { return }
            let previewError = "Nothing was captured. Check your microphone and try again."
            self.hudController.update(with: HUDState(
                visualState: .error(message: previewError),
                subtitle: "",
                level: 0,
                waveformLevels: Array(repeating: 0, count: 16),
                isVisible: true,
                showsSubtitle: false
            ))
            try? await Task.sleep(for: .milliseconds(
                HUDTerminalTiming.displayMilliseconds(for: .error(message: previewError))
            ))
            guard !Task.isCancelled, self.canPreviewHUDMotion else { return }
            self.hudController.update(with: .logoIdle)
        }
    }
    #endif

    func setLivePreviewEnabled(_ livePreviewEnabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "livePreviewEnabled", "value": String(livePreviewEnabled)])
        updateTranscriptionConfiguration { $0.livePreviewEnabled = livePreviewEnabled }
    }

    func setTapStopsOnNextKeyPress(_ enabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "tapStopsOnNextKeyPress", "value": String(enabled)])
        updateTranscriptionConfiguration { $0.tapStopsOnNextKeyPress = enabled }
    }

    func setAppAwarePolishingEnabled(_ enabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "appAwarePolishingEnabled", "value": String(enabled)])
        updateTranscriptionConfiguration { $0.appAwarePolishingEnabled = enabled }
    }

    func setPressEnterCommandEnabled(_ enabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "pressEnterCommandEnabled", "value": String(enabled)])
        updateTranscriptionConfiguration { $0.pressEnterCommandEnabled = enabled }
    }

    func setPressEnterCommandPhrase(_ phrase: String) {
        let sanitized = DictationCommandPhrase.sanitizedForStorage(phrase)
        analytics.track(
            "setting_changed",
            properties: [
                "setting": "pressEnterCommandPhrase",
                "value": sanitized.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "empty"
                    : (sanitized == DictationCommandPhrase.defaultValue ? "default" : "custom")
            ]
        )
        updateTranscriptionConfiguration { $0.pressEnterCommandPhrase = sanitized }
    }

    func setVocabularyText(_ vocabularyText: String) {
        analytics.track(
            "setting_changed",
            properties: [
                "setting": "vocabularyText",
                "value": vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "custom"
            ]
        )
        updateTranscriptionConfiguration { $0.vocabularyText = vocabularyText }
    }

    func setDictationQualityPreset(_ preset: DictationQualityPreset) {
        guard dictationQualityPreset != preset else { return }
        analytics.track("setting_changed", properties: ["setting": "qualityPreset", "value": preset.rawValue])
        updateTranscriptionConfiguration {
            $0.model = preset.model
            $0.decodingMode = preset.decodingMode
        }
    }

    func resetToRecommendedPreset() {
        analytics.track("recommended_preset_reset")
        transcriptionConfiguration = TranscriptionConfiguration()
        persist(configuration: transcriptionConfiguration)

        Task {
            await applyTranscriptionConfiguration(prewarm: true)
        }
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        setHotkeyEnabled(isEnabled, for: .holdToTalk)
    }

    func setTapToStartStopEnabled(_ isEnabled: Bool) {
        setHotkeyEnabled(isEnabled, for: .tapToStartStop)
    }

    func setScribeEnabled(_ isEnabled: Bool) {
        guard featureFlags.scribeEnabled else { return }
        setHotkeyEnabled(isEnabled, for: .scribe)
    }

    func setPrimaryTriggerMode(_ mode: DictationTriggerMode) {
        guard primaryTriggerMode != mode || holdToTalkBinding.isEnabled == tapToStartStopBinding.isEnabled else { return }
        analytics.track("shortcut_mode_changed", properties: ["mode": mode.rawValue])

        switch mode {
        case .holdToTalk:
            holdToTalkBinding.isEnabled = true
            tapToStartStopBinding.isEnabled = false
        case .tapToStartStop:
            holdToTalkBinding.isEnabled = false
            tapToStartStopBinding.isEnabled = true
        }

        persist(binding: holdToTalkBinding)
        persist(binding: tapToStartStopBinding)
        refreshRegisteredHotkeys()
    }

    func setShortcut(_ shortcut: HotkeyConfiguration, for action: HotkeyAction) {
        guard action != .scribe || featureFlags.scribeEnabled else { return }
        guard action.supports(shortcut) else {
            shortcutValidationMessage = "\(action.displayName) shortcut rejected. \(action.shortcutRuleDescription)"
            return
        }

        var binding = hotkeyBinding(for: action)
        guard binding.shortcut != shortcut else { return }
        binding.shortcut = shortcut
        guard validateHotkeyCandidate(binding, stage: "change") else { return }
        shortcutValidationMessage = nil
        analytics.track("shortcut_changed", properties: ["shortcut": action.rawValue])
        assignHotkeyBinding(binding)
        persist(binding: binding)
        refreshRegisteredHotkeys()
    }

    private func setHotkeyEnabled(_ isEnabled: Bool, for action: HotkeyAction) {
        var binding = hotkeyBinding(for: action)
        guard binding.isEnabled != isEnabled else { return }
        binding.isEnabled = isEnabled
        guard validateHotkeyCandidate(binding, stage: "enable") else { return }
        shortcutValidationMessage = nil
        analytics.track(
            "shortcut_enabled_changed",
            properties: ["shortcut": action.rawValue, "enabled": String(isEnabled)]
        )
        assignHotkeyBinding(binding)
        persist(binding: binding)
        refreshRegisteredHotkeys()
    }

    private func validateHotkeyCandidate(_ candidate: HotkeyBinding, stage: String) -> Bool {
        var bindings = currentHotkeyBindings
        guard let index = bindings.firstIndex(where: { $0.action == candidate.action }) else { return false }
        bindings[index] = candidate
        let enabled = bindings.filter(\.isEnabled)
        for leftIndex in enabled.indices {
            for rightIndex in enabled.indices where rightIndex > leftIndex {
                guard enabled[leftIndex].shortcut.conflicts(with: enabled[rightIndex].shortcut) else { continue }
                shortcutValidationMessage = "\(enabled[leftIndex].action.displayName) and \(enabled[rightIndex].action.displayName) need different shortcuts."
                analytics.track(
                    "shortcut_conflict_detected",
                    properties: ["shortcut": candidate.action.rawValue, "stage": stage]
                )
                return false
            }
        }
        return true
    }

    private func hotkeyBinding(for action: HotkeyAction) -> HotkeyBinding {
        switch action {
        case .holdToTalk: return holdToTalkBinding
        case .tapToStartStop: return tapToStartStopBinding
        case .scribe: return scribeBinding
        }
    }

    private func assignHotkeyBinding(_ binding: HotkeyBinding) {
        switch binding.action {
        case .holdToTalk: holdToTalkBinding = binding
        case .tapToStartStop: tapToStartStopBinding = binding
        case .scribe: scribeBinding = binding
        }
    }

    func setShortcutRecordingActive(_ isActive: Bool) {
        coordinator.setHotkeysPaused(isActive)
    }

    @discardableResult
    func copyTranscript(_ item: TranscriptHistoryItem) -> Bool {
        TranscriptCopyCommit.perform(item.text) { [self] in
            if !item.isComposeResult {
                let wordCount = Self.wordCount(in: item.text)
                analytics.track(
                    "transcript_copied",
                    properties: [
                        "sessionID": .string(item.analyticsSessionID ?? "history-only"),
                        "charactersBucket": .string(Self.countBucket(item.text.count)),
                        "characterCount": .int(item.text.count),
                        "wordsBucket": .string(Self.countBucket(wordCount)),
                        "wordCount": .int(wordCount)
                    ]
                )
                if Date().timeIntervalSince(item.createdAt) <= AnalyticsTuning.followUpWindow {
                    analytics.track(
                        "manual_copy_after_dictation",
                        properties: [
                            "sessionID": .string(item.analyticsSessionID ?? "history-only"),
                            "secondsSinceTranscript": .double(Self.analyticsSeconds(Date().timeIntervalSince(item.createdAt))),
                            "characterCount": .int(item.text.count),
                            "wordCount": .int(wordCount)
                        ]
                    )
                }
            }
            copiedTranscriptID = item.id

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                if self?.copiedTranscriptID == item.id {
                    self?.copiedTranscriptID = nil
                }
            }
        }
    }

    func exportTranscriptHistory() {
        guard !transcriptHistory.isEmpty else { return }

        let panel = NSSavePanel()
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.nameFieldStringValue = "Cadence-Dictation-History.md"
        panel.message = "This export is saved only where you choose. Cadence does not upload it."
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptHistoryMarkdownFormatter.markdown(for: transcriptHistory)
                .write(to: url, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "Cadence could not save your dictation history."
        }
    }

    func setAnalyticsEnabled(_ isEnabled: Bool) {
        guard analyticsEnabled != isEnabled else { return }
        analyticsEnabled = isEnabled
        defaults.set(isEnabled, forKey: PreferenceKey.analyticsEnabled)
        analytics.setEnabled(isEnabled)
    }

    func setShowsShortcutDock(_ isVisible: Bool) {
        guard showsShortcutDock != isVisible else { return }
        showsShortcutDock = isVisible
        defaults.set(isVisible, forKey: PreferenceKey.showsShortcutDock)
        analytics.track("shortcut_dock_visibility_changed", properties: ["visible": String(isVisible)])
    }

    private func refreshHUDCanCopyLast() {
        hudController.viewModel.canCopyLast = !transcriptHistory.isEmpty
    }

    private func captureSelectedTextForDictionary() {
        hudController.viewModel.dictionaryFeedback = .capturing
        do {
            guard let capture = try selectionCaptureService.capture() else {
                finishDictionaryCapture(.nothingSelected)
                return
            }
            guard let updatedVocabulary = VocabularyTextAppender.appending(
                capture.text,
                to: transcriptionConfiguration.vocabularyText
            ) else {
                finishDictionaryCapture(.nothingSelected)
                return
            }
            setVocabularyText(updatedVocabulary)
            finishDictionaryCapture(.added)
        } catch {
            finishDictionaryCapture(.failed)
        }
    }

    private func finishDictionaryCapture(_ outcome: DictionaryCaptureOutcome) {
        switch outcome {
        case .added:
            hudController.viewModel.dictionaryFeedback = .added
        case .nothingSelected:
            hudController.viewModel.dictionaryFeedback = .nothingSelected
        case .failed:
            hudController.viewModel.dictionaryFeedback = .failed
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.hudController.viewModel.dictionaryFeedback = .idle
        }
        analytics.track("dictionary_capture_completed", properties: outcome.analyticsProperties)
    }

    private func hideHUD(for duration: HUDHideDuration) {
        hudVisibilityController.hide(for: duration)
        analytics.track("hud_visibility_changed", properties: ["action": duration.rawValue])
    }

    var isCadenceBarHidden: Bool {
        !hudVisibility.showsIdleBar
    }

    func showCadenceBar() {
        hudVisibilityController.show()
        analytics.track("hud_visibility_changed", properties: ["action": "show"])
        if permissions.allRequiredGranted, isDictationIdle {
            coordinator.presentLogoIdle()
        }
    }

    private func bindHUDVisibility() {
        hudVisibilityController.onChange = { [weak self] visibility in
            guard let self else { return }
            self.hudVisibility = visibility
            self.applyHUDIdleVisibilityPolicy()
            if visibility.showsIdleBar, self.permissions.allRequiredGranted, self.isDictationIdle {
                self.coordinator.presentLogoIdle()
            }
        }
        applyHUDIdleVisibilityPolicy()
    }

    private func applyHUDIdleVisibilityPolicy() {
        let showsIdleBar = HUDIdleVisibilityPolicy.showsIdleBar(
            visibility: hudVisibility,
            permissionsGranted: permissions.allRequiredGranted
        )
        hudController.setIdleSuppressed(!showsIdleBar)
    }

    private var isDictationIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    func setDictationActivationSoundEnabled(_ enabled: Bool) {
        guard dictationActivationSoundEnabled != enabled else { return }
        dictationActivationSoundEnabled = enabled
        DictationSoundFeedbackPreference.setActivation(
            enabled,
            defaults: defaults,
            service: feedbackService
        )
    }

    func setDictationCompletionSoundEnabled(_ enabled: Bool) {
        guard dictationCompletionSoundEnabled != enabled else { return }
        dictationCompletionSoundEnabled = enabled
        DictationSoundFeedbackPreference.setCompletion(
            enabled,
            defaults: defaults,
            service: feedbackService
        )
    }

    private var currentHotkeyBindings: [HotkeyBinding] {
        Self.currentHotkeyBindings(
            hold: holdToTalkBinding,
            tap: tapToStartStopBinding,
            scribe: scribeBinding
        )
    }

    private func bindCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            self?.state = state
            if case .listening = state {
                self?.clearTransientCaptureErrorIfNeeded()
            }
        }

        coordinator.onHUDChange = { [weak self] hudState in
            self?.hudState = hudState
        }

        coordinator.onTranscript = { [weak self] transcript, sessionID in
            self?.clearTransientCaptureErrorIfNeeded()
            self?.lastTranscript = transcript
            self?.appendTranscriptToHistory(transcript, sessionID: sessionID)
            self?.livePreviewConfirmedText = ""
            self?.livePreviewUnconfirmedText = ""
        }

        coordinator.onPreviewTranscript = { [weak self] preview in
            if !preview.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !preview.unconfirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self?.clearTransientCaptureErrorIfNeeded()
            }
            self?.livePreviewConfirmedText = preview.confirmedText
            self?.livePreviewUnconfirmedText = preview.unconfirmedText
        }

        coordinator.onError = { [weak self] message in
            self?.lastError = message
        }

        coordinator.onBackendStatus = { [weak self] summary in
            self?.backendDescription = summary
        }

        hudController.onCopyLast = { [weak self] in
            guard let self else { return }
            if HUDCopyLastAction.perform(history: self.transcriptHistory, copy: self.copyTranscript) {
                self.hudController.showCopyConfirmation()
            }
        }

        hudController.onAddToDictionary = { [weak self] in
            guard let self else { return }
            self.captureSelectedTextForDictionary()
        }

        hudController.onHide = { [weak self] duration in
            guard let self else { return }
            self.hideHUD(for: duration)
        }

        hudController.viewModel.canCopyLast = !transcriptHistory.isEmpty
    }

    private func bindHotkeyDiagnostics() {
        hotkeyService.onDiagnosticsEvent = { [weak self] name, properties in
            self?.analytics.track(name, properties: properties)
        }

        hotkeyService.onObservedKeyEvent = { [weak self] event in
            self?.handleObservedKeyEvent(event)
        }
    }

    private func bindPermissionRefresh() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.refreshPermissions() }
            }
            .store(in: &cancellables)

    }

    private func schedulePermissionRefreshBurst() {
        Task {
            for nanoseconds in [300_000_000, 1_000_000_000, 2_500_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
                await refreshPermissions()
            }
        }
    }

    private func startCalendarDetectionLoop() {
        guard featureFlags.granolaEnabled else { return }
        calendarDetectionTimer?.invalidate()
        calendarDetectionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshUpcomingCalendarMeetings()
                self.evaluateCalendarMeetingDetection()
            }
        }
    }

    private func evaluateCalendarMeetingDetection(now: Date = Date()) {
        guard featureFlags.granolaEnabled else {
            detectedCalendarMeeting = nil
            return
        }
        guard detectedCalendarMeeting == nil,
              let event = meetingDetectionService.nextPrompt(
                from: upcomingCalendarMeetings,
                now: now,
                promptedEventIDs: promptedCalendarEventIDs
              )
        else {
            return
        }

        promptedCalendarEventIDs.insert(event.id)
        detectedCalendarMeeting = event
        deliverMeetingDetectionNotification(for: event)
        analytics.track("calendar_meeting_detected")
    }

    private func deliverMeetingDetectionNotification(for event: GoogleCalendarEvent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Meeting starting"
            content.body = event.title
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "calendar-meeting-\(event.id)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func refreshRegisteredHotkeys() {
        coordinator.updateHotkeyBindings(sanitizedHotkeyBindings())
    }

    var configuredScribeProviderKind: ScribeProviderKind? {
        scribeProviderV2Controller.configuredKind
    }

    var configuredScribeProviderIsEnabled: Bool {
        scribeProviderV2Controller.configuredProviderIsEnabled
    }

    var configuredScribeRecipient: String? {
        scribeProviderV2Controller.configuredRecipient
    }

    private var activeConfiguredScribeConfigurationID: UUID? {
        scribeProviderV2Controller.activeConfigurationID
    }

    func presentScribeProviderSetup() {
        guard featureFlags.scribeEnabled else { return }
        scribePanelWindowController.close()
        scribeNotchWindowController.close()
        restoreIdleHUDAfterScribe()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scribeCoordinator.cancel()
            self.isScribeProviderSetupPresented = true
            self.showMainWindow()
        }
    }

    func dismissScribeProviderSetup() {
        isScribeProviderSetupPresented = false
        Task { [scribeProviderSetupSession] in await scribeProviderSetupSession.dismiss() }
    }

    /// Makes the session-memory catalog available only after the caller has
    /// explicitly accepted the recipient disclosure. The candidate credential
    /// remains in the setup session and is cleared on cancellation/dismissal.
    func discoverScribeModels(
        for provider: ScribeProviderKind,
        credential: String,
        disclosureAccepted: Bool,
        matching query: String
    ) async -> [ScribeSearchableModelEntry] {
        guard disclosureAccepted,
              provider == .openAIDirect || provider == .openRouter,
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let origin = provider == .openAIDirect ? "https://api.openai.com" : "https://openrouter.ai"
        guard let receipt = await scribeProviderSetupSession.authorizedReceipt(for: provider, origin: origin) else {
            return []
        }
        let revision = scribeProviderSetupSession.prepareAttempt(
            providerKind: provider,
            credential: credential
        )
        scribeProviderSetupSession.setModelSearchQuery(query)
        let discoverySentinel = "cadence-discovery-only"
        if provider == .openAIDirect {
            _ = await scribeModelCatalogService.refreshOpenAI(
                selectedModelID: discoverySentinel,
                consentReceipt: receipt
            )
        } else {
            _ = await scribeModelCatalogService.refreshOpenRouter(
                selectedModelID: discoverySentinel,
                consentReceipt: receipt
            )
        }
        guard scribeProviderSetupSession.acceptsCallback(revision: revision) else { return [] }
        return await scribeModelCatalogService.searchModels(
            for: provider,
            matching: query
        )
    }

    func switchScribeProviderSetup(to kind: ScribeProviderKind) {
        Task { [scribeProviderSetupSession] in
            await scribeProviderSetupSession.providerSwitched(to: kind)
        }
    }

    /// Records an affirmative acknowledgement of the currently visible setup
    /// disclosure. Connect and model-discovery calls require this session-only
    /// receipt, so callers cannot turn a boolean parameter into egress.
    func acceptScribeProviderSetupDisclosure(
        for kind: ScribeProviderKind,
        advancedBaseURL: String? = nil
    ) async throws {
        // Bind the setup session to this provider before authorizing. Choosing
        // a card fires an asynchronous switch; accepting disclosure must not
        // race that Task and must never authorize a mismatched recipient.
        if scribeProviderSetupSession.providerKind != kind {
            await scribeProviderSetupSession.providerSwitched(to: kind)
        }
        let recipient: (origin: String, routing: ScribeProviderRoutingPolicy, retention: ScribeProviderRetentionPolicy, data: ScribeProviderDataPolicy)
        switch kind {
        case .deepSeek:
            recipient = ("https://api.deepseek.com", .providerControlledSingleModel, .providerControlled, .providerControlled)
        case .openAIDirect:
            recipient = ("https://api.openai.com", .directSingleModel, .requestStorageDisabled, .providerPolicyApplies)
        case .openRouter:
            recipient = ("https://openrouter.ai", .zeroDataRetentionSingleModel, .zeroDataRetentionRequired, .collectionDenied)
        case .advanced:
            guard let advancedBaseURL else { throw ScribeProviderConnectionError.consentRequired }
            let endpoint = try AdvancedScribeEndpoint(advancedBaseURL)
            recipient = (endpoint.normalizedOrigin, .providerControlledSingleModel, .providerControlled, .providerControlled)
        case .legacyLocal:
            throw ScribeProviderConnectionError.consentRequired
        }
        let receipt = await scribeConsentAuthority.issueEphemeral(
            providerKind: kind,
            recipientOrigin: recipient.origin,
            routingPolicy: recipient.routing,
            retentionPolicy: recipient.retention,
            dataPolicy: recipient.data
        )
        guard await scribeProviderSetupSession.authorizeDisclosure(receipt) else {
            throw ScribeProviderConnectionError.consentRequired
        }
    }

    func connectDeepSeekForScribe(credential: String, confirmed: Bool = false) async throws {
        await recordScribeDiagnostic(
            kind: .validationStarted,
            phase: .validation,
            provider: .deepSeek,
            outcome: .success
        )
        do {
            guard let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries.first else {
                throw ScribeProviderConnectionError.validationFailed
            }
            guard let receipt = await scribeProviderSetupSession.authorizedReceipt(
                for: .deepSeek, origin: "https://api.deepseek.com"
            ) else { throw ScribeProviderConnectionError.consentRequired }
            let candidate = ScribeProviderConnectionCandidate(
                id: UUID(),
                kind: .deepSeek,
                displayName: ScribeProviderKind.deepSeek.displayName,
                normalizedOrigin: "https://api.deepseek.com",
                baseURL: URL(string: "https://api.deepseek.com")!,
                requestURL: entry.endpoint,
                selectedModelID: entry.modelID,
                catalogID: entry.catalogID,
                consentReceipt: receipt,
                acceptedAt: receipt.acceptedAt
            )
            try await connectV2(candidate: candidate, credential: credential, confirmed: confirmed) { candidate, key in
                try await DeepSeekScribeProvider(
                    credentialLoader: { key }
                ).validateConnection()
            }
            await recordScribeDiagnostic(
                kind: .validationCompleted,
                phase: .validation,
                provider: .deepSeek,
                outcome: .success
            )
        } catch {
            await recordScribeDiagnostic(
                kind: .validationCompleted,
                phase: .validation,
                provider: .deepSeek,
                outcome: Self.diagnosticOutcome(for: error)
            )
            throw error
        }
    }

    func connectAdvancedScribeProvider(
        baseURL: String,
        model: String,
        credential: String,
        confirmed: Bool = false
    ) async throws {
        await recordScribeDiagnostic(
            kind: .validationStarted,
            phase: .validation,
            provider: .advanced,
            outcome: .success
        )
        do {
            let endpoint = try AdvancedScribeEndpoint(baseURL)
            let modelID = try ScribeModelIdentifier(model)
            guard let receipt = await scribeProviderSetupSession.authorizedReceipt(
                for: .advanced, origin: endpoint.normalizedOrigin
            ) else { throw ScribeProviderConnectionError.consentRequired }
            let candidate = ScribeProviderConnectionCandidate(
                id: UUID(),
                kind: .advanced,
                displayName: "Custom OpenAI-compatible",
                normalizedOrigin: endpoint.normalizedOrigin,
                baseURL: endpoint.normalizedBaseURL,
                requestURL: endpoint.requestURL,
                selectedModelID: modelID.rawValue,
                catalogID: nil,
                consentReceipt: receipt,
                acceptedAt: receipt.acceptedAt
            )
            try await connectV2(candidate: candidate, credential: credential, confirmed: confirmed) { candidate, key in
                try await OpenAICompatibleScribeProvider(
                    endpoint: try AdvancedScribeEndpoint(candidate.baseURL.absoluteString),
                    model: try ScribeModelIdentifier(candidate.selectedModelID),
                    credentialLoader: { key }
                ).validateConnection()
            }
            await recordScribeDiagnostic(
                kind: .validationCompleted,
                phase: .validation,
                provider: .advanced,
                outcome: .success
            )
        } catch {
            await recordScribeDiagnostic(
                kind: .validationCompleted,
                phase: .validation,
                provider: .advanced,
                outcome: Self.diagnosticOutcome(for: error)
            )
            throw error
        }
    }

    func connectOpenAIForScribe(model: String, credential: String, confirmed: Bool = false) async throws {
        let modelID = try ScribeModelIdentifier(model)
        guard let receipt = await scribeProviderSetupSession.authorizedReceipt(
            for: .openAIDirect, origin: "https://api.openai.com"
        ) else { throw ScribeProviderConnectionError.consentRequired }
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openAIDirect, displayName: ScribeProviderKind.openAIDirect.displayName,
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: modelID.rawValue, catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )
        try await connectCatalogV2(candidate: candidate, credential: credential, confirmed: confirmed)
    }

    func connectOpenRouterForScribe(model: String, credential: String, confirmed: Bool = false) async throws {
        let modelID = try ScribeModelIdentifier(model)
        guard let receipt = await scribeProviderSetupSession.authorizedReceipt(
            for: .openRouter, origin: "https://openrouter.ai"
        ) else { throw ScribeProviderConnectionError.consentRequired }
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openRouter, displayName: ScribeProviderKind.openRouter.displayName,
            normalizedOrigin: "https://openrouter.ai",
            baseURL: URL(string: "https://openrouter.ai")!,
            requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            selectedModelID: modelID.rawValue, catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )
        try await connectCatalogV2(candidate: candidate, credential: credential, confirmed: confirmed)
    }

    private func connectCatalogV2(
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        confirmed: Bool
    ) async throws {
        try await confirmActiveProviderMutation(confirmed: confirmed)
        _ = try await scribeProviderRuntime.connectCatalogValidated(
            candidate: candidate,
            credential: credential
        )
        scribeProviderReadiness = scribeProviderV2Controller.readiness
    }

    private func connectV2(
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        confirmed: Bool,
        validate: @escaping ScribeProviderV2ConnectionManager.Validator
    ) async throws {
        try await confirmActiveProviderMutation(confirmed: confirmed)
        let revision = scribeProviderSetupSession.prepareAttempt(
            providerKind: candidate.kind,
            credential: credential
        )
        let fence: @Sendable () async -> Bool = { [weak scribeProviderSetupSession] in
            guard let scribeProviderSetupSession else { return false }
            return await scribeProviderSetupSession.acceptsCallback(revision: revision)
        }
        do {
            _ = try await scribeProviderV2ConnectionManager.connect(
                candidate: candidate,
                credential: credential,
                attemptFence: fence,
                validate: validate
            )
            scribeProviderSetupSession.completeAttempt(revision: revision)
            scribeProviderReadiness = scribeProviderV2Controller.readiness
        } catch {
            scribeProviderSetupSession.completeAttempt(revision: revision)
            scribeProviderReadiness = scribeProviderV2Controller.readiness
            throw error
        }
    }

    private func confirmActiveProviderMutation(confirmed: Bool) async throws {
        guard ScribeProviderMutationPolicy.activationDecision(
            activeAction: scribeCoordinator.activeProviderActionIdentity
        ) == .confirmationRequired else { return }
        guard confirmed else { throw ScribeProviderConnectionError.activeActionConfirmationRequired }
        await scribeCoordinator.cancel()
        guard scribeCoordinator.activeProviderActionIdentity == nil else {
            throw ScribeProviderConnectionError.activeActionConfirmationRequired
        }
    }

    func generateScribePracticeDraft() async throws -> String {
        let action = try await scribeProviderV2Controller.actionForNewRequest()
        try action.validateForAcquisition()
        let environment = WritingEnvironmentResolver.resolve(
            recognizedEnvironmentID: .global,
            adaptationEnabled: true,
            preferenceLoadResult: .absent
        )
        // This synthetic, review-only exercise has no target, selected text,
        // insertion path, or persistence path. It uses the same direct-only
        // request construction and egress policy as a live Scribe draft.
        let request = ScribeRequest.directDictation(
            processedDictation: "Write one short update confirming that the Cadence Compose practice check is complete.",
            resolvedEnvironment: environment
        )
        let providerRequest = ScribeProviderRequest(
            id: request.id,
            input: try ScribeRequestPolicy.providerSafeInput(
                for: request,
                destination: action.destination
            )
        )
        guard await scribeProviderV2Controller.authorizeDispatch(action.actionIdentity) else {
            throw ScribeProviderFailure(
                phase: .generation,
                category: .configurationInvalid,
                retryDisposition: .reconnect
            )
        }
        let result = try await action.provider.generate(providerRequest)
        guard result.requestID == request.id else { throw ScribeProviderError.invalidResult }
        return try ScribeRequestPolicy.validateOutput(
            result.text,
            requiredLiterals: [],
            spokenRequest: request.spokenTranscript
        )
    }

    func setConfiguredScribeProviderEnabled(_ enabled: Bool, confirmed: Bool = false) {
        guard let configurationID = activeConfiguredScribeConfigurationID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let decision = try await self.scribeProviderV2Controller.setEnabled(
                    configurationID: configurationID,
                    enabled: enabled,
                    activeAction: self.scribeCoordinator.activeProviderActionIdentity,
                    confirmed: confirmed,
                    cancelActiveAction: { await self.scribeCoordinator.cancel() }
                )
                if decision == .confirmationRequired {
                    self.lastError = "Cancel the active Compose action before changing its provider."
                }
                self.scribeProviderReadiness = self.scribeProviderV2Controller.readiness
            } catch {
                self.lastError = "Cadence could not update the Compose provider state."
            }
        }
    }

    func removeConfiguredScribeProvider(confirmed: Bool = false) {
        guard let configurationID = activeConfiguredScribeConfigurationID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let decision = try await self.scribeProviderV2Controller.remove(
                    configurationID: configurationID,
                    activeAction: self.scribeCoordinator.activeProviderActionIdentity,
                    confirmed: confirmed,
                    cancelActiveAction: { await self.scribeCoordinator.cancel() }
                )
                guard decision == .allowed else {
                    self.lastError = "Cancel the active Compose action before removing its provider."
                    return
                }
                self.scribeProviderReadiness = self.scribeProviderV2Controller.readiness
            Task { [scribeDiagnosticsService] in
                await scribeDiagnosticsService.record(ScribeDiagnosticEvent(
                    kind: .providerRemoved,
                    phase: .readiness,
                    provider: .none,
                    outcome: .success
                ))
            }
            } catch {
                self.lastError = "Cadence could not remove the Compose provider from this Mac."
            }
        }
    }

    func setScribeAppAdaptationEnabled(_ enabled: Bool) {
        scribeAppAdaptationEnabled = enabled
        defaults.set(enabled, forKey: AdaptiveScribeMigrationService.adaptationEnabledKey)
    }

    func selectSettingsCategory(_ category: SettingsCategoryID) {
        let category = category.normalized(
            scribeEnabled: featureFlags.scribeEnabled,
            granolaEnabled: featureFlags.granolaEnabled
        )
        updateSettingsPresentation(.init(
            selectedCategory: category,
            isAdvancedExpanded: settingsPresentationState.isAdvancedExpanded
        ))
    }

    func setAdvancedSettingsExpanded(_ isExpanded: Bool) {
        updateSettingsPresentation(.init(
            selectedCategory: settingsPresentationState.selectedCategory,
            isAdvancedExpanded: isExpanded
        ))
    }

    func resetSettingsPresentation() {
        settingsPresentationStore.clear()
        settingsPresentationState = .init(selectedCategory: .general, isAdvancedExpanded: false)
    }

    func upsertApplicationConfiguration(
        for application: InstalledApplicationDescriptor,
        familyID: ScribeEnvironmentFamilyID,
        presetSelection: ScribePresetSelection = .familyDefault,
        customGuidance: ScribeCustomGuidance? = nil,
        promptOverride: ScribeCustomGuidance? = nil,
        isEnabled: Bool = true
    ) async throws -> ApplicationConfiguration {
        let configuration = try await applicationConfigurationWriter.upsert(
            application: application,
            familyID: familyID,
            presetSelection: presetSelection,
            customGuidance: customGuidance,
            promptOverride: promptOverride,
            isEnabled: isEnabled
        )
        refreshApplicationConfigurationState()
        if case let .valid(library) = applicationConfigurationStore.load() {
            await installedApplicationCatalogService.updateRememberedURLs(
                Set(library.configurations.map(\.application.lastKnownBundleURL))
            )
        }
        return configuration
    }

    func setApplicationConfigurationEnabled(_ id: UUID, enabled: Bool) async throws -> ApplicationConfiguration {
        guard case let .valid(library) = applicationConfigurationStore.load(),
              let current = library.configurations.first(where: { $0.id == id }) else {
            throw ApplicationConfigurationWriterError.missingConfiguration
        }
        return try await updateApplicationConfiguration(
            current,
            in: library,
            isEnabled: enabled,
            familyID: current.familyID,
            presetSelection: current.presetSelection,
            customGuidance: current.customGuidance,
            promptOverride: current.promptOverride
        )
    }

    func updateApplicationConfiguration(
        _ id: UUID,
        isEnabled: Bool,
        familyID: ScribeEnvironmentFamilyID,
        presetSelection: ScribePresetSelection,
        customGuidance: ScribeCustomGuidance?,
        promptOverride: ScribeCustomGuidance? = nil
    ) async throws -> ApplicationConfiguration {
        guard case let .valid(library) = applicationConfigurationStore.load(),
              let current = library.configurations.first(where: { $0.id == id }) else {
            throw ApplicationConfigurationWriterError.missingConfiguration
        }
        return try await updateApplicationConfiguration(
            current,
            in: library,
            isEnabled: isEnabled,
            familyID: familyID,
            presetSelection: presetSelection,
            customGuidance: customGuidance,
            promptOverride: promptOverride
        )
    }

    private func updateApplicationConfiguration(
        _ current: ApplicationConfiguration,
        in library: ApplicationConfigurationLibrary,
        isEnabled: Bool,
        familyID: ScribeEnvironmentFamilyID,
        presetSelection: ScribePresetSelection,
        customGuidance: ScribeCustomGuidance?,
        promptOverride: ScribeCustomGuidance?
    ) async throws -> ApplicationConfiguration {
        let updated = try ApplicationConfiguration(
            id: current.id,
            application: current.application,
            isEnabled: isEnabled,
            familyID: familyID,
            presetSelection: presetSelection,
            customGuidance: customGuidance,
            promptOverride: promptOverride,
            revision: current.revision + 1
        )
        try await applicationConfigurationWriter.replaceConfiguration(
            updated,
            expectedLibraryRevision: library.revision,
            expectedConfigurationRevision: current.revision
        )
        refreshApplicationConfigurationState()
        return updated
    }

    func setWritingEnvironmentBehavior(
        _ behaviorID: WritingBehaviorID,
        for environmentID: WritingEnvironmentID
    ) {
        guard environmentID != .global,
              let definition = WritingEnvironmentCatalog.releaseOne.environment(id: environmentID),
              definition.supportedBehaviorIDs.contains(behaviorID) else { return }
        guard case let .valid(existing) = normalizedWritingEnvironmentPreferences() else {
            lastError = "Restore writing environment defaults before changing this setting."
            return
        }
        var preferences = existing.filter { $0.environmentID != environmentID }
        let current = existing.first { $0.environmentID == environmentID }
        preferences.append(WritingEnvironmentPreference(
            environmentID: environmentID,
            isEnabled: current?.isEnabled ?? true,
            selectedBehaviorID: behaviorID,
            definitionVersion: definition.definitionVersion
        ))
        saveWritingEnvironmentPreferences(preferences)
    }

    func setWritingEnvironmentEnabled(
        _ enabled: Bool,
        for environmentID: WritingEnvironmentID
    ) {
        guard environmentID != .global,
              let definition = WritingEnvironmentCatalog.releaseOne.environment(id: environmentID) else { return }
        guard case let .valid(existing) = normalizedWritingEnvironmentPreferences() else {
            lastError = "Restore writing environment defaults before changing this setting."
            return
        }
        var preferences = existing.filter { $0.environmentID != environmentID }
        let current = existing.first { $0.environmentID == environmentID }
        preferences.append(WritingEnvironmentPreference(
            environmentID: environmentID,
            isEnabled: enabled,
            selectedBehaviorID: current?.selectedBehaviorID ?? definition.defaultBehaviorID,
            definitionVersion: definition.definitionVersion
        ))
        saveWritingEnvironmentPreferences(preferences)
    }

    func resetWritingEnvironment(_ environmentID: WritingEnvironmentID) {
        guard case let .valid(existing) = normalizedWritingEnvironmentPreferences() else { return }
        saveWritingEnvironmentPreferences(existing.filter { $0.environmentID != environmentID })
    }

    func restoreWritingEnvironmentDefaults() {
        resetAllApplicationSettings()
    }

    func resetApplicationConfiguration(_ id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AdaptiveScribeMigrationService(
                    defaults: self.defaults,
                    personalizationStore: self.personalizationStore
                ).resetApplicationConfiguration(
                    id,
                    writer: self.applicationConfigurationWriter
                )
                self.adaptiveScribeV2Availability = self.adaptiveScribeLiveReaderService.load().scribeAvailability
            } catch {
                self.lastError = "Cadence could not reset this application setting."
            }
        }
    }

    func resetAllApplicationSettings() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.performResetAllApplicationSettings(
                    defaults: self.defaults,
                    writer: self.applicationConfigurationWriter,
                    personalizationStore: self.personalizationStore
                )
                self.scribeAppAdaptationEnabled = true
                self.adaptiveScribeV2Availability = self.adaptiveScribeLiveReaderService.load().scribeAvailability
                self.lastError = nil
            } catch {
                self.lastError = "Cadence could not reset application settings."
            }
        }
    }

    static func performResetAllApplicationSettings(
        defaults: UserDefaults,
        writer: ApplicationConfigurationWriter,
        personalizationStore: PersonalizationStore
    ) async throws {
        try await AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: personalizationStore
        ).resetAllApplicationSettings(
            writer: writer
        )
    }

    func refreshInstalledApplications() {
        Task { await installedApplicationCatalogService.pageAppeared() }
    }

    func chooseInstalledApplication(at url: URL) async -> InstalledApplicationDescriptor? {
        await installedApplicationCatalogService.chooseApplication(at: url)
    }

    private func updateSettingsPresentation(_ state: SettingsPresentationState) {
        do {
            try settingsPresentationStore.save(state)
            settingsPresentationState = state
        } catch {
            lastError = "Cadence could not save the Settings view preference."
        }
    }

    private func refreshApplicationConfigurationState() {
        applicationConfigurations = {
            guard case let .valid(library) = applicationConfigurationStore.load() else { return [] }
            return library.configurations
        }()
    }

    private func handleInstalledApplicationSnapshot(_ snapshot: InstalledApplicationCatalogSnapshot) {
        let affectedIconURLs = InstalledApplicationIconInvalidation.affectedBundleURLs(
            previous: installedApplicationIconSnapshot,
            next: snapshot
        )
        installedApplicationIconSnapshot = snapshot
        applicationIconResolver.invalidate(bundleURLs: affectedIconURLs)
        if installedApplications != snapshot.applications {
            installedApplications = snapshot.applications
        }
        guard case let .valid(library) = applicationConfigurationStore.load() else { return }
        let configurationIDs = library.configurations.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            for configurationID in configurationIDs {
                guard case let .valid(currentLibrary) = self.applicationConfigurationStore.load(),
                      let configuration = currentLibrary.configurations.first(where: {
                          $0.id == configurationID
                      }) else { continue }
                let savedURLExists = FileManager.default.fileExists(
                    atPath: configuration.application.lastKnownBundleURL.path
                )
                guard ApplicationIdentityResolver.resolve(
                    reference: configuration.application,
                    applications: snapshot.applications,
                    savedURLExists: savedURLExists
                ).isUniqueRebind else { continue }
                do {
                    _ = try await self.applicationConfigurationWriter.rebind(
                        configurationID: configuration.id,
                        expectedLibraryRevision: currentLibrary.revision,
                        expectedConfigurationRevision: configuration.revision,
                        expectedReferenceID: configuration.application.id,
                        expectedOldURL: configuration.application.lastKnownBundleURL,
                        snapshot: snapshot,
                        newestSnapshot: {
                            await MainActor.run { self.installedApplicationSnapshotStore.snapshot }
                        },
                        savedURLExists: {
                            FileManager.default.fileExists(
                                atPath: configuration.application.lastKnownBundleURL.path
                            )
                        },
                        onCommittedRememberedURLs: { urls in
                            await self.installedApplicationCatalogService.updateRememberedURLs(urls)
                        }
                    )
                } catch {
                    continue
                }
            }
        }
    }

    func dismissLegacyWritingProfileNotice() {
        AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: personalizationStore
        ).dismissLegacyProfileNotice()
        showsLegacyWritingProfileNotice = false
    }

    func removeLegacyWritingProfiles() {
        personalizationLibrary.styleProfiles = []
        persistPersonalizationLibrary()
        dismissLegacyWritingProfileNotice()
    }

    func clearScribeDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scribeDiagnosticsService.clear()
            self.lastError = nil
        }
    }

    func exportScribeDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data: Data
            do {
                data = try await ScribeDiagnosticsExportService.makeExport(
                    events: await self.scribeDiagnosticsService.events(),
                    generatedAt: Date(),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    readiness: Self.diagnosticReadiness(self.scribeProviderReadiness),
                    permissions: ScribeDiagnosticPermissionSnapshot(
                        microphone: self.permissions.microphoneGranted,
                        accessibility: self.permissions.accessibilityGranted,
                        inputMonitoring: self.permissions.inputMonitoringGranted
                    ),
                    provider: self.diagnosticProvider,
                    appAdaptationEnabled: self.scribeAppAdaptationEnabled
                )
            } catch {
                self.lastError = "Cadence could not prepare the Compose diagnostics export."
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Cadence-Compose-Diagnostics.json"
            panel.message = "This content-free export is saved only where you choose. Cadence does not upload it."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.lastError = nil
            } catch {
                self.lastError = "Cadence could not save the Compose diagnostics export."
            }
        }
    }

    private func normalizedWritingEnvironmentPreferences() -> WritingEnvironmentPreferenceLoadResult {
        switch writingEnvironmentPreferenceState {
        case .absent:
            return .valid([])
        case .valid, .rejected:
            return writingEnvironmentPreferenceState
        }
    }

    private func saveWritingEnvironmentPreferences(_ preferences: [WritingEnvironmentPreference]) {
        do {
            try writingEnvironmentStore.save(preferences)
            writingEnvironmentPreferenceState = .valid(preferences)
            lastError = nil
        } catch {
            lastError = "Cadence could not save writing environment settings."
        }
    }

    func showScribe() {
        guard featureFlags.scribeEnabled else { return }
        guard revalidateAdaptiveScribeReaders() else { return }
        switch scribeState {
        case .idle, .succeeded, .cancelled, .failed:
            beginScribe(triggerMode: .tapToStartStop)
        case .listening:
            stopScribeRecording()
        default:
            updateScribePresentation(scribeState)
        }
    }

    private func handleScribeShortcutPress() {
        switch scribeState {
        case .idle, .succeeded, .cancelled, .failed:
            beginScribe(triggerMode: .holdToTalk)
        case .listening where activeScribeTriggerMode == .tapToStartStop:
            activeScribeTriggerMode = nil
            stopScribeRecording()
        default:
            break
        }
    }

    private func handleScribeShortcutRelease() {
        guard activeScribeTriggerMode == .holdToTalk else { return }
        if case .listening = scribeState {
            activeScribeTriggerMode = nil
            stopScribeRecording()
        } else {
            // Provider resolution and microphone startup are asynchronous. If
            // the user releases during startup, finish immediately once the
            // listening state is established instead of leaving Scribe latched.
            scribeShortcutReleasePending = true
        }
    }

    private func handleScribeShortcutDoublePress() {
        switch scribeState {
        case .idle, .succeeded, .cancelled, .failed:
            if activeScribeTriggerMode == .holdToTalk {
                activeScribeTriggerMode = .tapToStartStop
                scribeShortcutReleasePending = false
            } else {
                beginScribe(triggerMode: .tapToStartStop)
            }
        case .listening where activeScribeTriggerMode == .holdToTalk:
            activeScribeTriggerMode = .tapToStartStop
            scribeShortcutReleasePending = false
        case .listening where activeScribeTriggerMode == .tapToStartStop:
            activeScribeTriggerMode = nil
            stopScribeRecording()
        default:
            break
        }
    }

    private func beginScribe(triggerMode: DictationTriggerMode) {
        guard revalidateAdaptiveScribeReaders() else { return }

        scribeRecoveryApplication = focusedApplicationMonitor.currentExternal?.process
        activeScribeTriggerMode = triggerMode
        scribeShortcutReleasePending = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentPermissions = await ScribePermissionGate.evaluate(using: self.permissionsService)
            self.permissions = currentPermissions
            self.permissionGuideWindowController.updatePermissions(currentPermissions)
            if let permissionMessage = currentPermissions.scribePermissionMessage {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                self.presentScribeStartFailure(
                    permissionMessage,
                    failureRecovery: .openPermissions
                )
                return
            }

            do {
                try await self.scribeTranscriptionEngine.updateConfiguration(self.transcriptionConfiguration)
                try await self.scribeCoordinator.beginDirectDictation()
                self.feedbackService.playScribeActivationSound()
                self.lastError = nil
                if self.activeScribeTriggerMode == .holdToTalk,
                   self.scribeShortcutReleasePending {
                    self.activeScribeTriggerMode = nil
                    self.scribeShortcutReleasePending = false
                    await self.scribeCoordinator.finishRecording()
                }
            } catch let error as ScribeProviderFailure {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                await self.scribeProviderV2Controller.reloadReadiness()
                self.scribeProviderReadiness = self.scribeProviderV2Controller.readiness
                self.presentScribeStartFailure(
                    error.userMessage,
                    failureRecovery: .providerRecovery(for: error)
                )
            } catch let error as ScribeContextError {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                self.presentScribeStartFailure(
                    error.userMessage,
                    failureRecovery: .contextRecovery(for: error)
                )
            } catch let VoiceSessionArbiterError.busy(activeKind) {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                self.presentScribeStartFailure("Stop the active \(activeKind.displayName) session before starting Compose.")
            } catch is CancellationError {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                return
            } catch {
                self.activeScribeTriggerMode = nil
                self.scribeShortcutReleasePending = false
                self.presentScribeStartFailure("Compose could not start recording. Try again.")
            }
        }
    }

    private func presentScribeStartFailure(
        _ message: String,
        failureRecovery: ScribeNotchFailureRecovery? = nil
    ) {
        lastError = message
        scribeState = .failed(requestID: nil, error: .unavailable)
        updateScribePresentation(
            scribeState,
            failureMessageOverride: message,
            failureRecoveryOverride: failureRecovery
        )
    }

    private func stopScribeRecording() {
        activeScribeTriggerMode = nil
        scribeShortcutReleasePending = false
        Task { @MainActor [weak self] in
            await self?.scribeCoordinator.finishRecording()
        }
    }

    private func cancelScribe(dismissImmediately: Bool = false) {
        activeScribeTriggerMode = nil
        scribeShortcutReleasePending = false
        if dismissImmediately {
            scribePanelWindowController.close()
            restoreIdleHUDAfterScribe()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scribeCoordinator.cancel()
            try? await Task.sleep(for: .milliseconds(500))
            guard case .cancelled = self.scribeState else { return }
            self.scribeState = .idle
            self.scribePanelWindowController.close()
            self.scribeNotchWindowController.close()
            self.restoreIdleHUDAfterScribe()
        }
    }

    private func retryScribe() {
        if !scribeCoordinator.canRetryGeneration {
            showScribe()
            return
        }
        Task { @MainActor [weak self] in
            await self?.scribeCoordinator.retryGeneration()
        }
    }

    private func insertScribeResult() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let historyDraft = self.scribeCoordinator.reviewedHistoryDraft()
            do {
                try await self.scribeCoordinator.insertReviewedResult()
                if let historyDraft {
                    self.appendComposeDraftToHistory(historyDraft)
                }
            } catch let error as ScribeContextError {
                self.updateScribePresentation(
                    self.scribeState,
                    failureMessageOverride: error.userMessage
                )
            } catch {
                self.lastError = "Cadence could not safely insert that draft. Copy it instead."
            }
        }
    }

    private func insertUnpolishedScribeResult() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let historyDraft = self.scribeCoordinator.unpolishedHistoryDraft()
            do {
                try await self.scribeCoordinator.insertUnpolishedResult()
                if let historyDraft {
                    self.appendComposeDraftToHistory(historyDraft)
                }
            } catch let error as ScribeContextError {
                self.updateScribePresentation(
                    self.scribeState,
                    failureMessageOverride: error.userMessage
                )
            } catch {
                self.lastError = "Cadence could not safely insert the unpolished dictation. Copy it instead."
            }
        }
    }

    private func reRecordScribe() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.scribeCoordinator.reRecord()
            } catch let error as ScribeContextError {
                self.presentScribeStartFailure(
                    error.userMessage,
                    failureRecovery: .contextRecovery(for: error)
                )
            } catch {
                self.presentScribeStartFailure(
                    "Compose could not start a new recording.",
                    failureRecovery: .retryGeneration
                )
            }
        }
    }

    private func copyPolishedScribeResult() {
        guard let text = scribeCoordinator.takeReviewedDraftForCopy(),
              let historyDraft = scribeCoordinator.reviewedHistoryDraft() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            appendComposeDraftToHistory(historyDraft)
            scribeNotchWindowController.showCopyFeedback("Copied to clipboard")
        }
    }

    private func copyUnpolishedScribeResult() {
        guard let text = scribeCoordinator.takeUnpolishedDraftForCopy(),
              let historyDraft = scribeCoordinator.unpolishedHistoryDraft() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            appendComposeDraftToHistory(historyDraft)
            scribeNotchWindowController.showCopyFeedback("Copied to clipboard")
        }
    }

    private var scribeFailureMessage: String? {
        switch scribeCoordinator.failure {
        case let .provider(error):
            return error.userMessage
        case let .context(error):
            return error.userMessage
        case let .voiceSessionBusy(kind):
            return "Stop the active \(kind.displayName) session before starting Compose."
        case .transcriptionEmpty:
            return "Cadence did not hear a request. Record the request again or use Dictation."
        case .transcription:
            return "Cadence could not transcribe that request. Try again or use Dictation."
        case .literalRepair:
            return "Cadence could not resolve an exact literal. Use the spoken words, record the request again, or cancel Compose."
        case nil:
            return nil
        }
    }

    private func updateScribePresentation(
        _ state: ScribeSessionState,
        failureMessageOverride: String? = nil,
        failureRecoveryOverride: ScribeNotchFailureRecovery? = nil
    ) {
        switch state {
        case .listening, .transcribing, .generating, .generatingSlow:
            scribeReplacementCompleted = false
        default:
            break
        }

        let resolvedFailureMessage = failureMessageOverride ?? scribeFailureMessage
        let presentation = ScribeNotchPresentation.project(
            state: state,
            literalTranscript: scribeCoordinator.literalTranscript,
            failureMessage: resolvedFailureMessage,
            canRetryGeneration: scribeCoordinator.canRetryGeneration,
            failureRecovery: failureRecoveryOverride
                ?? .providerRecovery(for: scribeCoordinator.providerFailure)
        )

        #if DEBUG
        if ScribeLaunchFixtures.current != nil,
           !ScribeLaunchFixtures.usesNotchPresentation {
            scribeNotchWindowController.close()
            scribePanelWindowController.update(
                state: state,
                failureMessage: failureMessageOverride ?? scribeFailureMessage,
                literalTranscript: scribeCoordinator.literalTranscript,
                environmentCue: scribeCoordinator.resolvedEnvironment?.cue,
                targetDisplayName: scribeCoordinator.targetDisplayName,
                exactLiterals: scribeCoordinator.exactLiterals,
                canRetryGeneration: scribeCoordinator.canRetryGeneration
            )
        } else {
            scribePanelWindowController.close()
            scribeNotchWindowController.update(presentation)
        }
        #else
        scribePanelWindowController.close()
        scribeNotchWindowController.update(presentation)
        #endif

        updateScribeHUD(for: state, failureMessage: resolvedFailureMessage)
    }

    private func updateScribeHUD(
        for state: ScribeSessionState,
        failureMessage: String? = nil
    ) {
        let visualState = ScribeHUDProjection.visualState(
            for: state,
            replacementCompleted: scribeReplacementCompleted,
            failureMessage: failureMessage
        )

        guard visualState != .idle else {
            if case .succeeded = state {
                hudController.update(with: .idle)
            } else {
                restoreIdleHUDAfterScribe()
            }
            return
        }

        hudController.update(with: HUDState(
            visualState: visualState,
            subtitle: "",
            level: scribeAudioLevel,
            waveformLevels: scribeWaveformLevels,
            isVisible: true,
            showsSubtitle: false
        ))
    }

    private func updateScribeAudioLevel(_ level: Double) {
        let normalized = max(0, min(1, level))
        scribeAudioLevel = normalized
        if !scribeWaveformLevels.isEmpty {
            scribeWaveformLevels.removeFirst()
        }
        scribeWaveformLevels.append(normalized)
        guard case .listening = scribeState else { return }
        updateScribeHUD(for: scribeState)
    }

    private func restoreIdleHUDAfterScribe() {
        scribeAudioLevel = 0
        scribeWaveformLevels = Array(repeating: 0, count: 16)
        switch ScribeHUDRestorationAction.resolve(
            requiredPermissionsGranted: permissions.allRequiredGranted,
            isDictationIdle: isDictationIdle
        ) {
        case .leaveCurrentHUD:
            return
        case .showIdle:
            hudController.update(with: .idle)
        case .showReadyLogo:
            coordinator.presentLogoIdle()
        }
    }

    private func bindScribeCoordinator() {
        coordinator.onScribeRequested = { [weak self] in
            self?.handleScribeShortcutPress()
        }
        coordinator.onScribeReleased = { [weak self] in
            self?.handleScribeShortcutRelease()
        }
        coordinator.onScribeDoublePressed = { [weak self] in
            self?.handleScribeShortcutDoublePress()
        }
        scribeCoordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.scribeState = state
            if case .transcribing = state {
                self.playScribeProcessingFeedback()
            }
            self.updateScribePresentation(state)
            Task { @MainActor [weak self] in
                await self?.recordScribeState(state)
            }
        }
        scribeCoordinator.onAudioLevel = { [weak self] level in
            self?.updateScribeAudioLevel(level)
        }

        let viewModel = scribePanelWindowController.viewModel
        viewModel.onStop = { [weak self] in self?.stopScribeRecording() }
        viewModel.onCancel = { [weak self] in self?.cancelScribe() }
        viewModel.onRetry = { [weak self] in self?.retryScribe() }
        viewModel.onReRecord = { [weak self] in self?.reRecordScribe() }
        viewModel.onUseLiteral = { [weak self] in self?.scribeCoordinator.useLiteralTranscript() }
        viewModel.onInsert = { [weak self] in self?.insertScribeResult() }
        viewModel.onInsertUnpolished = { [weak self] in self?.insertUnpolishedScribeResult() }
        viewModel.onCopyPolished = { [weak self] in self?.copyPolishedScribeResult() }
        viewModel.onCopyUnpolished = { [weak self] in self?.copyUnpolishedScribeResult() }
        viewModel.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scribeCoordinator.dismissPanel()
                self.scribePanelWindowController.close()
                self.scribeNotchWindowController.close()
                self.restoreIdleHUDAfterScribe()
            }
        }

        let notchViewModel = scribeNotchWindowController.viewModel
        notchViewModel.onInsert = { [weak self] in self?.insertScribeResult() }
        notchViewModel.onCopy = { [weak self] in
            guard let self else { return }
            if case .failed = self.scribeState {
                self.copyUnpolishedScribeResult()
            } else {
                self.copyPolishedScribeResult()
            }
        }
        notchViewModel.onDiscard = { [weak self] in self?.cancelScribe() }
        notchViewModel.onRetry = { [weak self] in self?.retryScribe() }
        notchViewModel.onConfigureProvider = { [weak self] in
            self?.presentScribeProviderSetup()
        }
        notchViewModel.onReturnToTargetApp = { [weak self] in
            guard let self else { return }
            let didActivate = self.scribeRecoveryApplication.map {
                self.focusedApplicationMonitor.activateValidatedExternal($0)
            } ?? self.focusedApplicationMonitor.activateMostRecentValidatedExternal()
            if didActivate {
                self.cancelScribe(dismissImmediately: true)
            } else {
                self.scribeNotchWindowController.showCopyFeedback(
                    "Open the app where you want to write, place the cursor, and try again."
                )
            }
        }
        notchViewModel.onOpenPermissions = { [weak self] in
            self?.cancelScribe(dismissImmediately: true)
            self?.openPermissionsWizard()
        }
        notchViewModel.onReplacementCompleted = { [weak self] in
            guard let self,
                  case .reviewing = self.scribeState,
                  !self.scribeReplacementCompleted else { return }
            self.scribeReplacementCompleted = true
            self.playScribeCompletionFeedback()
            self.updateScribeHUD(for: self.scribeState)
        }
        scribeNotchWindowController.onOutsideClickAfterCopy = { [weak self] in
            self?.cancelScribe(dismissImmediately: true)
        }
    }

    private func playScribeProcessingFeedback() {
        #if DEBUG
        guard !ScribeLaunchFixtures.usesIsolatedRuntimeStorage else { return }
        #endif
        feedbackService.playScribeProcessingSound()
    }

    private func playScribeCompletionFeedback() {
        #if DEBUG
        guard !ScribeLaunchFixtures.usesIsolatedRuntimeStorage else { return }
        #endif
        feedbackService.playScribeCompletionSound()
    }

    @discardableResult
    private func revalidateAdaptiveScribeReaders() -> Bool {
        _ = adaptiveScribeReaderMonitor.revalidate()
        let availability = adaptiveScribeReaderMonitor.state.scribeAvailability
        adaptiveScribeV2Availability = availability
        return Self.enforceAdaptiveScribeEntry(
            availability: availability,
            cancelActiveCoordinator: { [weak self] in
                guard let self else { return }
                self.scribePanelWindowController.close()
                self.scribeNotchWindowController.close()
                self.restoreIdleHUDAfterScribe()
                Task { @MainActor [weak self] in
                    await self?.scribeCoordinator.cancel()
                }
            },
            presentSetup: { [weak self] in
                self?.isScribeProviderSetupPresented = true
                self?.showMainWindow()
            }
        )
    }

    private func invalidateAdaptiveScribeRuntime() {
        #if DEBUG
        guard ScribeLaunchFixtures.current == nil else { return }
        #endif
        adaptiveScribeV2Availability = .setupRequired
        scribePanelWindowController.close()
        scribeNotchWindowController.close()
        restoreIdleHUDAfterScribe()
        scribeCoordinator.invalidateProviderWork()
        Task { @MainActor [weak self] in
            await self?.scribeCoordinator.cancel()
        }
    }

    static func enforceAdaptiveScribeEntry(
        availability: AdaptiveScribeAvailability,
        cancelActiveCoordinator: () -> Void,
        presentSetup: () -> Void
    ) -> Bool {
        guard availability == .enabled else {
            cancelActiveCoordinator()
            presentSetup()
            return false
        }
        return true
    }

    private func recordScribeState(_ state: ScribeSessionState) async {
        let event: ScribeDiagnosticEvent?
        switch state {
        case .listening:
            event = ScribeDiagnosticEvent(
                kind: .captureCompleted,
                phase: .capture,
                provider: diagnosticProvider,
                outcome: .success,
                appAdaptationEnabled: scribeAppAdaptationEnabled
            )
        case .transcribing:
            event = ScribeDiagnosticEvent(
                kind: .transcriptionStarted,
                phase: .transcription,
                provider: diagnosticProvider,
                outcome: .success
            )
        case .generating:
            event = ScribeDiagnosticEvent(
                kind: .generationStarted,
                phase: .generation,
                provider: diagnosticProvider,
                outcome: .success,
                attempt: .first,
                appAdaptationEnabled: scribeAppAdaptationEnabled
            )
        case .generatingSlow:
            event = nil
        case .reviewing:
            event = ScribeDiagnosticEvent(
                kind: .generationCompleted,
                phase: .generation,
                provider: diagnosticProvider,
                outcome: .success,
                attempt: .first
            )
        case .insertionRecovery:
            event = ScribeDiagnosticEvent(
                kind: .insertionVerificationCompleted,
                phase: .insertion,
                provider: diagnosticProvider,
                outcome: .targetChanged
            )
        case .succeeded:
            event = ScribeDiagnosticEvent(
                kind: .insertionVerificationCompleted,
                phase: .insertion,
                provider: diagnosticProvider,
                outcome: .success
            )
        case .cancelled:
            event = ScribeDiagnosticEvent(
                kind: .reviewFallbackChosen,
                phase: .review,
                provider: diagnosticProvider,
                outcome: .cancelled
            )
        case .failed:
            event = ScribeDiagnosticEvent(
                kind: .generationCompleted,
                phase: .generation,
                provider: diagnosticProvider,
                outcome: Self.diagnosticOutcome(
                    for: scribeCoordinator.providerFailure,
                    fallback: scribeCoordinator.failure
                )
            )
        case .idle, .inserting:
            event = nil
        }
        if let event { await scribeDiagnosticsService.record(event) }
    }

    private func recordScribeDiagnostic(
        kind: ScribeDiagnosticKind,
        phase: ScribeDiagnosticPhase,
        provider: ScribeDiagnosticProvider,
        outcome: ScribeDiagnosticOutcome
    ) async {
        await scribeDiagnosticsService.record(ScribeDiagnosticEvent(
            kind: kind,
            phase: phase,
            provider: provider,
            outcome: outcome
        ))
    }

    private var diagnosticProvider: ScribeDiagnosticProvider {
        switch configuredScribeProviderKind {
        case .openAIDirect, .openRouter: return .none
        case .deepSeek: return .deepSeek
        case .advanced: return .advanced
        case .legacyLocal: return .legacyLocal
        case nil:
            if case .ready(.legacyLocal) = scribeProviderReadiness { return .legacyLocal }
            return .none
        }
    }

    private static func diagnosticOutcome(for error: Error) -> ScribeDiagnosticOutcome {
        if let failure = error as? ScribeProviderFailure {
            return diagnosticOutcome(for: failure, fallback: nil)
        }
        if error is CancellationError { return .cancelled }
        if error is ScribeProviderConfigurationError { return .configurationInvalid }
        return .otherSafeCategory
    }

    private static func diagnosticOutcome(
        for failure: ScribeProviderFailure?,
        fallback: ScribeSessionFailure?
    ) -> ScribeDiagnosticOutcome {
        if let failure {
            switch failure.category {
            case .setupRequired: return .setupRequired
            case .configurationInvalid: return .configurationInvalid
            case .credentialRejected: return .credentialRejected
            case .balanceRequired: return .balanceRequired
            case .rateLimited: return .rateLimited
            case .transportUnavailable, .unsafeConnection: return .transportUnavailable
            case .timedOut: return .timedOut
            case .providerUnavailable: return .providerUnavailable
            case .providerRejected, .incompatibleRequest, .endpointNotFound: return .providerRejected
            case .invalidResponse: return .invalidResponse
            case .cancelled: return .cancelled
            }
        }
        switch fallback {
        case .transcriptionEmpty: return .transcriptionEmpty
        case .transcription: return .transcriptionFailed
        case .context(.targetChanged): return .targetChanged
        case .context: return .insertionFailed
        case .provider(.offline): return .transportUnavailable
        case .provider(.timedOut): return .timedOut
        case .provider(.cancelled): return .cancelled
        case .provider: return .providerUnavailable
        case .voiceSessionBusy, .literalRepair, nil: return .otherSafeCategory
        }
    }

    private static func diagnosticReadiness(
        _ readiness: ScribeProviderReadiness
    ) -> ScribeDiagnosticReadiness {
        switch readiness {
        case .disabled: return .disabled
        case .setupRequired: return .setupRequired
        case .validating: return .validating
        case .ready: return .ready
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .configurationInvalid: return .configurationInvalid
        case .needsAttention: return .needsAttention
        case .deprecated: return .deprecated
        case .removed: return .removed
        }
    }

    #if DEBUG
    private func presentScribeLaunchFixtureIfNeeded() {
        guard let fixture = ScribeLaunchFixtures.current else { return }
        let result = ScribeResult(
            requestID: UUID(),
            text: "Update `parseID` after reviewing this synthetic fixture draft."
        )
        if ScribeLaunchFixtures.usesNotchPresentation {
            presentScribeNotchLaunchFixture(fixture, result: result)
            return
        }
        let width = ScribeLaunchFixtures.panelWidth
        switch fixture {
        case .directReady:
            scribeState = .idle
            scribePanelWindowController.presentFixture(
                state: .idle,
                fixtureIdentifier: "scribe-fixture-direct-ready",
                width: width
            )
        case .listening:
            scribeState = .listening(requestID: result.requestID)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                targetDisplayName: "Slack",
                fixtureIdentifier: "scribe-fixture-listening",
                width: width
            )
        case .transcribing:
            scribeState = .transcribing(requestID: result.requestID)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                fixtureIdentifier: "scribe-fixture-transcribing",
                width: width
            )
        case .generating:
            scribeState = .generating(requestID: result.requestID)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                fixtureIdentifier: "scribe-fixture-generating",
                width: width
            )
        case .generatingSlow:
            scribeState = .generatingSlow(requestID: result.requestID)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                fixtureIdentifier: "scribe-fixture-generating-slow",
                width: width
            )
        case .slackReview:
            scribeState = .reviewing(result)
            scribePanelWindowController.presentFixture(
                state: .reviewing(result),
                literalTranscript: "Synthetic spoken request",
                environmentCue: "Slack · Neutral",
                targetDisplayName: "Slack",
                exactLiterals: [ScribeExactLiteral(
                    id: 1,
                    value: "parseID",
                    source: .explicitGrammar
                )],
                canRetryGeneration: true,
                fixtureIdentifier: "scribe-fixture-slack-review",
                width: width
            )
        case .claudeReview:
            scribeState = .reviewing(result)
            scribePanelWindowController.presentFixture(
                state: .reviewing(result),
                environmentCue: "Claude · Coding",
                targetDisplayName: "Claude",
                exactLiterals: [ScribeExactLiteral(
                    id: 1,
                    value: "parseID",
                    source: .explicitGrammar
                )],
                canRetryGeneration: true,
                fixtureIdentifier: "scribe-fixture-claude-review",
                width: width
            )
        case .insertionRecovery:
            scribeState = .insertionRecovery(result)
            scribePanelWindowController.presentFixture(
                state: .insertionRecovery(result),
                failureMessage: "Return to the original app and insertion point. Your draft is still here.",
                literalTranscript: "Synthetic spoken request",
                environmentCue: "Claude · Coding",
                targetDisplayName: "Claude",
                exactLiterals: [ScribeExactLiteral(
                    id: 1,
                    value: "parseID",
                    source: .explicitGrammar
                )],
                canRetryGeneration: true,
                fixtureIdentifier: "scribe-fixture-insertion-recovery",
                width: width
            )
        case .literalFailure:
            scribeState = .failed(requestID: result.requestID, error: .invalidResult)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                failureMessage: "Cadence could not resolve the exact literal `parseID`.",
                literalTranscript: "Update parse I D",
                exactLiterals: [ScribeExactLiteral(
                    id: 1,
                    value: "parseID",
                    source: .explicitGrammar
                )],
                fixtureIdentifier: "scribe-fixture-literal-failure",
                width: width
            )
        case .retryableFailure:
            scribeState = .failed(requestID: result.requestID, error: .offline)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                failureMessage: "The provider is temporarily offline.",
                literalTranscript: "Synthetic spoken request",
                canRetryGeneration: true,
                fixtureIdentifier: "scribe-fixture-retryable-failure",
                width: width
            )
        case .nonRetryableFailure:
            scribeState = .failed(requestID: result.requestID, error: .invalidResult)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                failureMessage: "This request cannot be retried safely.",
                literalTranscript: "Synthetic spoken request",
                canRetryGeneration: false,
                fixtureIdentifier: "scribe-fixture-nonretryable-failure",
                width: width
            )
        case .success:
            scribeState = .succeeded(requestID: result.requestID)
            scribePanelWindowController.presentFixture(
                state: scribeState,
                fixtureIdentifier: "scribe-fixture-success",
                width: width
            )
        case .controlSemantics:
            scribeState = .idle
            scribePanelWindowController.presentFixture(
                state: .idle,
                fixtureIdentifier: "scribe-fixture-control-semantics",
                width: width
            )
        case .setup, .settings:
            break
        }
    }

    private func presentScribeNotchLaunchFixture(
        _ fixture: ScribeLaunchFixture,
        result: ScribeResult
    ) {
        let literal = "Update parse I D after reviewing this synthetic fixture draft."
        let presentation: ScribeNotchPresentation

        switch fixture {
        case .listening:
            scribeState = .listening(requestID: result.requestID)
            presentation = .project(
                state: scribeState,
                literalTranscript: nil,
                failureMessage: nil
            )
        case .transcribing:
            scribeState = .transcribing(requestID: result.requestID)
            presentation = .project(
                state: scribeState,
                literalTranscript: nil,
                failureMessage: nil
            )
        case .generating, .generatingSlow:
            scribeState = fixture == .generating
                ? .generating(requestID: result.requestID)
                : .generatingSlow(requestID: result.requestID)
            presentation = .project(
                state: scribeState,
                literalTranscript: literal,
                failureMessage: nil
            )
        case .slackReview, .claudeReview, .insertionRecovery:
            scribeState = fixture == .insertionRecovery
                ? .insertionRecovery(result)
                : .reviewing(result)
            presentation = .project(
                state: scribeState,
                literalTranscript: literal,
                failureMessage: nil
            )
        case .literalFailure, .retryableFailure, .nonRetryableFailure:
            scribeState = .failed(requestID: result.requestID, error: .invalidResult)
            presentation = .project(
                state: scribeState,
                literalTranscript: literal,
                failureMessage: "Compose could not finish this draft. Your spoken words are still available."
            )
        case .directReady, .success, .controlSemantics, .setup, .settings:
            return
        }

        scribePanelWindowController.close()
        scribeNotchWindowController.update(presentation)
        updateScribeHUD(for: scribeState)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.mainWindowController.window?.orderOut(nil)
        }
    }
    #endif

    private func releaseMeetingVoiceSessionLease() {
        guard let meetingVoiceSessionLease else { return }
        voiceSessionArbiter.release(meetingVoiceSessionLease)
        self.meetingVoiceSessionLease = nil
    }

    private func appendTranscriptToHistory(_ transcript: String, sessionID: String?) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let wordCount = Self.wordCount(in: cleaned)
        let item = TranscriptHistoryItem(text: cleaned, analyticsSessionID: sessionID)
        analytics.track(
            "transcript_created",
            properties: [
                "sessionID": .string(sessionID ?? "unknown"),
                "charactersBucket": .string(Self.countBucket(cleaned.count)),
                "characterCount": .int(cleaned.count),
                "wordsBucket": .string(Self.countBucket(wordCount)),
                "wordCount": .int(wordCount)
            ]
        )
        trackFirstSuccessfulDictationIfNeeded(item: item, wordCount: wordCount)
        transcriptHistory = TranscriptHistoryPolicy.inserting(item, into: transcriptHistory)
        lastTrackedCorrectionTranscriptID = nil
        lastTrackedCorrectionSessionID = nil
        persistTranscriptHistory()
        refreshHUDCanCopyLast()
    }

    private func appendComposeDraftToHistory(_ draft: ComposeHistoryDraft) {
        guard let item = TranscriptHistoryPolicy.historyItem(
            for: draft,
            existing: transcriptHistory
        ) else { return }
        transcriptHistory = TranscriptHistoryPolicy.upserting(item, into: transcriptHistory)
        persistTranscriptHistory()
        refreshHUDCanCopyLast()
    }

    private func persistMeetingNote(_ note: MeetingNote) {
        do {
            try meetingStore.save(note)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateMeetingTranscriptState(
        noteID: UUID,
        state: MeetingTranscriptState,
        message: String?
    ) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        meetingNotes[index].transcriptState = state
        meetingNotes[index].transcriptStatusMessage = message
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    private func appendMeetingAudioRecording(_ recording: MeetingAudioRecordingMetadata, noteID: UUID) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        var recordings = meetingNotes[index].effectiveAudioRecordings
        if let existingIndex = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[existingIndex] = recording
        } else {
            recordings.append(recording)
        }
        meetingNotes[index].audioRecordings = recordings
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    private func removeEmptyMeetingRecordingLedger(recordingID: UUID, noteID: UUID) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        meetingNotes[index].audioRecordings?.removeAll { $0.id == recordingID }
        let currentRecordingSegments = meetingNotes[index].transcriptSegments.filter { $0.recordingID == recordingID }
        if currentRecordingSegments.isEmpty {
            if meetingNotes[index].transcriptSegments.isEmpty {
                meetingNotes[index].transcriptState = .empty
            } else if meetingNotes[index].transcriptSegments.allSatisfy({ $0.effectiveOrigin == .final }) {
                meetingNotes[index].transcriptState = .final
            } else {
                meetingNotes[index].transcriptState = .liveDraft
            }
        } else {
            meetingNotes[index].transcriptState = .liveDraft
        }
        meetingNotes[index].transcriptStatusMessage = "Recording could not start, and no audio was captured."
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    private func setMeetingRecordingState(
        _ state: MeetingRecordingState,
        recordingID: UUID,
        noteID: UUID
    ) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        var recordings = meetingNotes[index].effectiveAudioRecordings
        guard let recordingIndex = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        guard recordings[recordingIndex].state != state else { return }
        recordings[recordingIndex].state = state
        meetingNotes[index].audioRecordings = recordings
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    private func runFinalTranscriptionPass(
        noteID: UUID,
        recording: MeetingAudioRecordingMetadata
    ) async {
        setMeetingRecordingState(.finalizing, recordingID: recording.id, noteID: noteID)
        do {
            let finalSegments = try await meetingFinalTranscriptionService.transcribe(
                recording: recording,
                configuration: Self.meetingCaptureTranscriptionConfiguration(from: transcriptionConfiguration)
            )
            guard !finalSegments.isEmpty else {
                throw WhisperEngineError.noTranscript
            }
            applyFinalTranscriptSegments(finalSegments, noteID: noteID, recordingID: recording.id)
            generateSummary(for: noteID, preserveSelection: true)
            analytics.track("meeting_final_transcription_completed")
        } catch {
            setMeetingRecordingState(.finalizationFailed, recordingID: recording.id, noteID: noteID)
            updateMeetingTranscriptState(
                noteID: noteID,
                state: .finalizationFailed,
                message: error.localizedDescription
            )
            lastError = error.localizedDescription
            analytics.track("meeting_final_transcription_failed")
        }
    }

    private func applyFinalTranscriptSegments(
        _ segments: [TranscriptSegment],
        noteID: UUID,
        recordingID: UUID
    ) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        meetingNotes[index].applyFinalSegments(segments, forRecording: recordingID)
        if var recordings = meetingNotes[index].audioRecordings,
           let recordingIndex = recordings.firstIndex(where: { $0.id == recordingID }) {
            recordings[recordingIndex].state = .final
            meetingNotes[index].audioRecordings = recordings
        }
        if meetingNotes[index].usesDefaultTitle, let suggestedTitle = meetingNotes[index].suggestedTitle {
            meetingNotes[index].title = suggestedTitle
        }
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        persistMeetingNote(updatedNote)
    }

    private func makeMeetingCaptureChunkHandler(
        noteID: UUID,
        source: MeetingCaptureSource,
        service: MeetingRollingTranscriptionService,
        recorder: MeetingAudioRecorder,
        recordingID: UUID,
        queue: MeetingCaptureChunkQueue
    ) -> @Sendable (AudioChunk, Double) -> Void {
        { [weak self, service, recorder, queue] chunk, level in
            queue.enqueue { [weak self, recorder] in
                await self?.recordMeetingCaptureProgress(chunk, level: level, noteID: noteID)
                do {
                    try await recorder.append(chunk, level: level)
                } catch {
                    await self?.handleMeetingAudioRecordingError(error, noteID: noteID)
                }
            }

            Task { [weak self, service] in
                do {
                    let segments = try await service.append(chunk, level: level)
                    await self?.appendMeetingTranscriptSegments(
                        segments,
                        noteID: noteID,
                        source: source,
                        origin: .liveDraft,
                        recordingID: recordingID
                    )
                } catch {
                    await self?.handleMeetingTranscriptionError(error)
                }
            }
        }
    }

    private func recordMeetingCaptureProgress(_ chunk: AudioChunk, level: Double, noteID: UUID) {
        guard activeMeetingCaptureNoteID == noteID || systemAudioCaptureState == .stopping else { return }
        systemAudioCaptureLevel = max(systemAudioCaptureLevel * 0.72, level)
        systemAudioCapturedFrameCount += chunk.frameCount
    }

    private func appendMeetingTranscriptSegments(
        _ segments: [TranscriptSegment],
        noteID: UUID,
        source: MeetingCaptureSource,
        origin: TranscriptSegmentOrigin,
        recordingID: UUID?
    ) {
        guard !segments.isEmpty else { return }
        for segment in segments {
            appendTranscriptSegment(
                labeledMeetingSegment(segment, source: source)
                    .attributed(origin: origin, recordingID: recordingID),
                noteID: noteID
            )
        }
    }

    private func handleMeetingAudioRecordingError(_ error: Error, noteID: UUID) {
        updateMeetingTranscriptState(
            noteID: noteID,
            state: .finalizationFailed,
            message: "Saved audio failed: \(error.localizedDescription)"
        )
        lastError = error.localizedDescription
    }

    private func handleMeetingTranscriptionError(_ error: Error) {
        guard !Self.isBenignMeetingTranscriptionError(error) else { return }
        if systemAudioCaptureState.isCaptureBusy {
            systemAudioCaptureState = .failed(error.localizedDescription)
        }
        lastError = error.localizedDescription
    }

    private func finalizeMeetingTranscription(
        for noteID: UUID?,
        source: MeetingCaptureSource,
        service: MeetingRollingTranscriptionService,
        recordingID: UUID?,
        origin: TranscriptSegmentOrigin
    ) async -> Bool {
        switch await MeetingTranscriptionFinalizer.finish(
            service: service,
            timeout: MeetingTranscriptionTuning.finalizationTimeout
        ) {
        case .completed(let segments):
            for segment in segments {
                appendTranscriptSegment(
                    labeledMeetingSegment(segment, source: source)
                        .attributed(origin: origin, recordingID: recordingID),
                    noteID: noteID
                )
            }
            return true
        case .failed(let message):
            lastError = message
            appendTranscriptionProblemSegment(message, noteID: noteID, source: source, recordingID: recordingID)
            return false
        case .timedOut:
            let message = "Meeting transcription took too long, so Cadence reset recording. Any completed transcript segments were kept."
            lastError = message
            appendTranscriptionProblemSegment(message, noteID: noteID, source: source, recordingID: recordingID)
            if meetingTranscriptionService === service {
                meetingTranscriptionService = Self.makeMeetingTranscriptionService()
            }
            Task {
                await service.cancel()
            }
            analytics.track("meeting_transcription_timed_out")
            return false
        }
    }

    private func appendTranscriptionProblemSegment(
        _ message: String,
        noteID: UUID?,
        source: MeetingCaptureSource,
        recordingID: UUID?
    ) {
        guard let noteID else { return }
        let segment = TranscriptSegment(
            text: message,
            startTime: 0,
            endTime: 0,
            speaker: .unknown,
            captureSource: source,
            origin: .liveDraft,
            recordingID: recordingID
        )
        appendTranscriptSegment(segment, noteID: noteID)
        selectedMeetingNoteID = noteID
    }

    private func labeledMeetingSegment(_ segment: TranscriptSegment) -> TranscriptSegment {
        labeledMeetingSegment(segment, source: meetingCaptureSource)
    }

    private func labeledMeetingSegment(_ segment: TranscriptSegment, source: MeetingCaptureSource) -> TranscriptSegment {
        segment.labeled(speaker: transcriptSpeaker(for: source), captureSource: source)
    }

    private func transcriptSpeaker(for source: MeetingCaptureSource) -> TranscriptSpeaker {
        switch source {
        case .systemAudio:
            return .systemAudio
        case .microphone:
            return .user
        case .microphoneAndSystemAudio:
            return .mixedAudio
        }
    }

    private func meetingCapturePhase(for state: SystemAudioCaptureState) -> MeetingCapturePhase? {
        switch state {
        case .starting:
            return .starting
        case .capturing:
            return .recording
        case .stopping:
            return .finalizing
        case .idle, .failed:
            return nil
        }
    }

    private func appendTranscriptSegment(_ segment: TranscriptSegment, noteID explicitNoteID: UUID? = nil) {
        guard let noteID = explicitNoteID ?? activeMeetingCaptureNoteID ?? selectedMeetingNoteID,
              let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else {
            return
        }

        if let lastSegmentIndex = meetingNotes[index].transcriptSegments.indices.last,
           Self.shouldMergeAdjacentTranscript(
            meetingNotes[index].transcriptSegments[lastSegmentIndex],
            with: segment
           ) {
            meetingNotes[index].transcriptSegments[lastSegmentIndex].endTime = max(
                meetingNotes[index].transcriptSegments[lastSegmentIndex].endTime,
                segment.endTime
            )
        } else {
            meetingNotes[index].transcriptSegments.append(segment)
        }
        if meetingNotes[index].usesDefaultTitle, let suggestedTitle = meetingNotes[index].suggestedTitle {
            meetingNotes[index].title = suggestedTitle
        }
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        if explicitNoteID == nil {
            selectedMeetingNoteID = updatedNote.id
        }
        persistMeetingNote(updatedNote)
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

    private func generateSummary(for noteID: UUID, preserveSelection: Bool = false) {
        guard let index = meetingNotes.firstIndex(where: { $0.id == noteID }) else { return }
        meetingNotes[index].summary = meetingSummaryService.generateSummary(for: meetingNotes[index])
        meetingNotes[index].updatedAt = Date()
        let updatedNote = meetingNotes[index]
        meetingNotes.remove(at: index)
        meetingNotes.insert(updatedNote, at: 0)
        if !preserveSelection {
            selectedMeetingNoteID = updatedNote.id
        }
        persistMeetingNote(updatedNote)
        analytics.track("meeting_summary_generated")
    }

    private func stopActiveMeetingCaptureServices() async -> AudioCaptureSessionMetrics {
        var metrics = [AudioCaptureSessionMetrics]()

        if meetingMicrophoneCaptureActive {
            metrics.append(meetingMicrophoneCaptureService.stopCapture())
            meetingMicrophoneCaptureActive = false
        }

        if meetingSystemAudioCaptureActive {
            metrics.append(await systemAudioCaptureService.stopCapture())
            meetingSystemAudioCaptureActive = false
        }

        guard !metrics.isEmpty else {
            return AudioCaptureSessionMetrics(
                duration: 0,
                frameCount: systemAudioCapturedFrameCount,
                sampleRate: 16_000,
                speechDetected: systemAudioCapturedFrameCount > 0,
                speechFrameCount: systemAudioCapturedFrameCount,
                peakLevel: systemAudioCaptureLevel
            )
        }

        return AudioCaptureSessionMetrics(
            duration: metrics.map(\.duration).max() ?? 0,
            frameCount: metrics.map(\.frameCount).reduce(0, +),
            sampleRate: 16_000,
            speechDetected: metrics.contains { $0.speechDetected },
            speechFrameCount: metrics.map(\.speechFrameCount).reduce(0, +),
            peakLevel: metrics.map(\.peakLevel).max() ?? 0
        )
    }

    private func stopActiveMeetingCaptureServicesWithTimeout() async -> AudioCaptureSessionMetrics {
        let result = await withCheckedContinuation { continuation in
            let gate = MeetingAudioStopGate()

            Task { @MainActor [weak self] in
                guard let self else {
                    gate.resume(continuation, with: .timedOut)
                    return
                }
                let metrics = await self.stopActiveMeetingCaptureServices()
                gate.resume(continuation, with: .completed(metrics))
            }

            Task {
                try? await Task.sleep(for: MeetingTranscriptionTuning.audioStopTimeout)
                gate.resume(continuation, with: .timedOut)
            }
        }

        switch result {
        case .completed(let metrics):
            return metrics
        case .timedOut:
            meetingMicrophoneCaptureActive = false
            meetingSystemAudioCaptureActive = false
            analytics.track("meeting_capture_stop_timed_out")
            return fallbackMeetingCaptureMetrics()
        }
    }

    private func fallbackMeetingCaptureMetrics() -> AudioCaptureSessionMetrics {
        AudioCaptureSessionMetrics(
            duration: activeMeetingCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0,
            frameCount: systemAudioCapturedFrameCount,
            sampleRate: 16_000,
            speechDetected: systemAudioCapturedFrameCount > 0,
            speechFrameCount: systemAudioCapturedFrameCount,
            peakLevel: systemAudioCaptureLevel
        )
    }

    private func runSystemAudioSmoke(resultPath: String) async {
        do {
            try await systemAudioCaptureService.startCapture { _, _ in }

            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/bin/zsh")
            player.arguments = [
                "-lc",
                "for _ in 1 2 3 4; do /usr/bin/afplay /System/Library/Sounds/Glass.aiff; done"
            ]
            try player.run()
            player.waitUntilExit()
            try await Task.sleep(for: .milliseconds(700))

            let metrics = await systemAudioCaptureService.stopCapture()
            try "frames=\(metrics.frameCount) speechDetected=\(metrics.speechDetected)\n"
                .write(toFile: resultPath, atomically: true, encoding: .utf8)
        } catch {
            try? "error=\(error.localizedDescription)\n"
                .write(toFile: resultPath, atomically: true, encoding: .utf8)
        }

        NSApp.terminate(nil)
    }

    private func clearTransientCaptureErrorIfNeeded() {
        guard let lastError, Self.isTransientCaptureError(lastError) else { return }
        self.lastError = nil
    }

    private func sanitizedHotkeyBindings() -> [HotkeyBinding] {
        var sanitized = currentHotkeyBindings
        var acceptedShortcuts: [HotkeyConfiguration] = []
        for index in sanitized.indices where sanitized[index].isEnabled {
            if acceptedShortcuts.contains(where: { $0.conflicts(with: sanitized[index].shortcut) }) {
                sanitized[index].isEnabled = false
            } else {
                acceptedShortcuts.append(sanitized[index].shortcut)
            }
        }
        return sanitized
    }

    private func updateTranscriptionConfiguration(_ mutate: (inout TranscriptionConfiguration) -> Void) {
        var next = transcriptionConfiguration
        mutate(&next)
        guard next != transcriptionConfiguration else { return }

        let shouldPrewarm = next.model != transcriptionConfiguration.model
        transcriptionConfiguration = next
        scribeCoordinator.updateLocalTextConfiguration(next)
        persist(configuration: next)
        lastError = nil

        transcriptionConfigurationTask?.cancel()
        transcriptionConfigurationTask = Task { @MainActor [weak self] in
            await self?.applyTranscriptionConfiguration(prewarm: shouldPrewarm)
        }
    }

    private func applyTranscriptionConfiguration(prewarm: Bool) async {
        do {
            let summary = try await coordinator.updateTranscriptionConfiguration(transcriptionConfiguration)
            lastError = nil
            backendDescription = summary
            if prewarm {
                await warmBackend()
            }
        } catch {
            guard !Self.isBenignModelLoadCancellation(error) else {
                preferencesLogger.info("Ignored canceled transcription configuration apply")
                return
            }
            lastError = error.localizedDescription
            backendDescription = "Transcription backend unavailable"
        }
    }

    private func handleObservedKeyEvent(_ event: ObservedKeyEvent) {
        guard event.isDeleteOrUndo else { return }
        guard let latestTranscript = transcriptHistory.first else { return }
        guard latestTranscript.id != lastTrackedCorrectionTranscriptID else { return }
        guard latestTranscript.analyticsSessionID != lastTrackedCorrectionSessionID else { return }

        let secondsSinceTranscript = Date().timeIntervalSince(latestTranscript.createdAt)
        guard secondsSinceTranscript <= AnalyticsTuning.followUpWindow else { return }

        lastTrackedCorrectionTranscriptID = latestTranscript.id
        lastTrackedCorrectionSessionID = latestTranscript.analyticsSessionID
        let wordCount = Self.wordCount(in: latestTranscript.text)
        analytics.track(
            "backspace_or_replace_soon_after_insert",
            properties: [
                "sessionID": .string(latestTranscript.analyticsSessionID ?? "history-only"),
                "signal": .string(event.keyCode == 6 ? "undo" : "delete"),
                "secondsSinceTranscript": .double(Self.analyticsSeconds(secondsSinceTranscript)),
                "characterCount": .int(latestTranscript.text.count),
                "wordCount": .int(wordCount)
            ]
        )
    }

    private func trackFirstSuccessfulDictationIfNeeded(item: TranscriptHistoryItem, wordCount: Int) {
        guard !defaults.bool(forKey: PreferenceKey.firstSuccessfulDictationTracked) else { return }
        defaults.set(true, forKey: PreferenceKey.firstSuccessfulDictationTracked)
        analytics.track(
            "first_successful_dictation",
            properties: [
                "sessionID": .string(item.analyticsSessionID ?? "unknown"),
                "characterCount": .int(item.text.count),
                "wordCount": .int(wordCount)
            ]
        )
    }

    private func backendAnalyticsProperties() -> [String: AnalyticsValue] {
        [
            "backend": .string("whisperkit"),
            "model": .string(transcriptionConfiguration.model.rawValue),
            "decoding": .string(transcriptionConfiguration.decodingMode.rawValue),
            "preset": .string(dictationQualityPreset.rawValue)
        ]
    }

    private static func isBenignModelLoadCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        let message = [
            nsError.localizedDescription,
            String(describing: error),
            nsError.userInfo.description
        ]
        .joined(separator: " ")
        .lowercased()

        return message.contains("nsurlerrordomain") &&
            message.contains("code=-999") &&
            message.contains("cancel")
    }

    private static func makeMeetingStore() -> MeetingStore {
        do {
            return try MeetingStore()
        } catch {
            preferencesLogger.error("Failed to create default meeting store: \(error.localizedDescription, privacy: .public)")
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Cadence", isDirectory: true)
                .appendingPathComponent("MeetingNotes", isDirectory: true)
            return try! MeetingStore(directoryURL: fallbackURL)
        }
    }

    private static func makeMeetingAudioStore() -> MeetingAudioStore {
        do {
            return try MeetingAudioStore()
        } catch {
            preferencesLogger.error("Failed to create default meeting audio store: \(error.localizedDescription, privacy: .public)")
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Cadence", isDirectory: true)
                .appendingPathComponent("MeetingAudio", isDirectory: true)
            return try! MeetingAudioStore(directoryURL: fallbackURL)
        }
    }

    private static func meetingQuarantineMessage(count: Int) -> String {
        if count == 1 {
            return "Cadence found one unreadable meeting note and moved it to Quarantine."
        }
        return "Cadence found \(count) unreadable meeting notes and moved them to Quarantine."
    }

    private static func loadMeetingCaptureSource(defaults: UserDefaults) -> MeetingCaptureSource {
        if let rawValue = defaults.string(forKey: PreferenceKey.meetingCaptureSource),
           let source = MeetingCaptureSource(rawValue: rawValue) {
            return source
        }
        return .systemAudio
    }

    private static func loadAppearancePreference(defaults: UserDefaults) -> AppearancePreference {
        if let rawValue = defaults.string(forKey: PreferenceKey.appearancePreference),
           let preference = AppearancePreference(rawValue: rawValue) {
            return preference
        }
        return .system
    }

    private func applyAppearancePreference() {
        NSApp.appearance = appearancePreference.nsAppearance
    }

    private func reloadGoogleCalendarConfiguration() {
        googleCalendarConfiguration = Self.makeGoogleCalendarConfiguration(
            clientID: googleOAuthClientID,
            clientSecret: googleOAuthClientSecret,
            redirectScheme: googleOAuthRedirectScheme
        )
        googleCalendarConnectionState = googleCalendarService.connectionState(configuration: googleCalendarConfiguration)
        if !googleCalendarConnectionState.isConnected {
            try? calendarEventCacheStore.delete()
            upcomingCalendarMeetings = []
            detectedCalendarMeeting = nil
        }
    }

    private static func loadGoogleOAuthClientID(defaults: UserDefaults) -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment["GOOGLE_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? bundledInfoString("CadenceGoogleOAuthClientID")
            ?? defaults.string(forKey: PreferenceKey.googleOAuthClientID)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""
    }

    private static func loadGoogleOAuthClientSecret(defaults: UserDefaults) -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment["GOOGLE_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? bundledInfoString("CadenceGoogleOAuthClientSecret")
            ?? defaults.string(forKey: PreferenceKey.googleOAuthClientSecret)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""
    }

    private static func loadGoogleOAuthRedirectScheme(defaults: UserDefaults) -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment["GOOGLE_OAUTH_REDIRECT_SCHEME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? bundledInfoString("CadenceGoogleOAuthRedirectScheme")
            ?? defaults.string(forKey: PreferenceKey.googleOAuthRedirectScheme)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? defaultGoogleOAuthRedirectScheme()
    }

    private static func makeGoogleCalendarConfiguration(clientID: String, clientSecret: String, redirectScheme: String) -> GoogleCalendarOAuthConfiguration? {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            return nil
        }
        return GoogleCalendarOAuthConfiguration(
            clientID: trimmedClientID,
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            redirectScheme: redirectScheme.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultGoogleOAuthRedirectScheme()
        )
    }

    private static func defaultGoogleOAuthRedirectScheme() -> String {
        bundledInfoString("CadenceGoogleOAuthRedirectScheme")
            ?? Bundle.main.bundleIdentifier
            ?? "com.darshshah.Cadence"
    }

    private static func bundledInfoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, !trimmedValue.hasPrefix("$(") else {
            return nil
        }
        return trimmedValue
    }

    private static func makeMeetingTranscriptionService() -> MeetingRollingTranscriptionService {
        MeetingRollingTranscriptionService(
            engine: WhisperKitTranscriptionEngine(),
            windowDuration: MeetingTranscriptionTuning.rollingWindowDuration
        )
    }

    static func meetingCaptureTranscriptionConfiguration(from configuration: TranscriptionConfiguration) -> TranscriptionConfiguration {
        var meetingConfiguration = configuration
        meetingConfiguration.model = .baseEnglish
        meetingConfiguration.decodingMode = .greedy
        meetingConfiguration.keepContext = false
        meetingConfiguration.trimSilence = true
        meetingConfiguration.normalizeAudio = true
        return meetingConfiguration
    }

    private static func systemAudioSmokeResultPath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--cadence-system-audio-smoke") else {
            return nil
        }
        let resultIndex = arguments.index(after: index)
        guard arguments.indices.contains(resultIndex) else {
            return nil
        }
        return arguments[resultIndex]
    }

    private func persist(configuration: TranscriptionConfiguration) {
        defaults.set(configuration.model.rawValue, forKey: PreferenceKey.whisperModel)
        defaults.set(configuration.decodingMode.rawValue, forKey: PreferenceKey.decodingMode)
        defaults.set(configuration.fillerWordPolicy.rawValue, forKey: PreferenceKey.fillerWordPolicy)
        defaults.set(configuration.keepContext, forKey: PreferenceKey.keepContext)
        defaults.set(configuration.trimSilence, forKey: PreferenceKey.trimSilence)
        defaults.set(configuration.normalizeAudio, forKey: PreferenceKey.normalizeAudio)
        defaults.set(configuration.livePreviewEnabled, forKey: PreferenceKey.livePreviewEnabled)
        defaults.set(configuration.tapStopsOnNextKeyPress, forKey: PreferenceKey.tapStopsOnNextKeyPress)
        defaults.set(configuration.appAwarePolishingEnabled, forKey: PreferenceKey.appAwarePolishingEnabled)
        defaults.set(configuration.pressEnterCommandEnabled, forKey: PreferenceKey.pressEnterCommandEnabled)
        defaults.set(configuration.pressEnterCommandPhrase, forKey: PreferenceKey.pressEnterCommandPhrase)
        defaults.set(configuration.vocabularyText, forKey: PreferenceKey.vocabularyText)
    }

    private func persist(binding: HotkeyBinding) {
        let keys = Self.preferenceKeys(for: binding.action)
        defaults.set(binding.isEnabled, forKey: keys.enabled)
        defaults.set(binding.shortcut.keyCode, forKey: keys.keyCode)
        defaults.set(binding.shortcut.carbonModifiers, forKey: keys.modifiers)
        defaults.set(binding.shortcut.keyDisplay, forKey: keys.keyDisplay)
        defaults.set(
            HotkeyConfiguration.encodedSidedModifierKeyCodes(binding.shortcut.sidedModifierKeyCodes),
            forKey: keys.sidedModifierKeyCodes
        )
    }

    private func persistTranscriptHistory() {
        guard let data = try? JSONEncoder().encode(transcriptHistory) else { return }
        defaults.set(data, forKey: PreferenceKey.transcriptHistory)
    }

    private static func loadConfiguration(defaults: UserDefaults) -> TranscriptionConfiguration {
        var configuration = TranscriptionConfiguration()

        if let rawValue = defaults.string(forKey: PreferenceKey.whisperModel),
           let model = WhisperModelOption(rawValue: rawValue) {
            configuration.model = model
        }

        if let rawValue = defaults.string(forKey: PreferenceKey.decodingMode),
           let decodingMode = WhisperDecodingMode(rawValue: rawValue) {
            configuration.decodingMode = decodingMode
        }

        if let rawValue = defaults.string(forKey: PreferenceKey.fillerWordPolicy),
           let fillerWordPolicy = FillerWordPolicy(rawValue: rawValue) {
            configuration.fillerWordPolicy = fillerWordPolicy
        }

        if defaults.object(forKey: PreferenceKey.keepContext) != nil {
            configuration.keepContext = defaults.bool(forKey: PreferenceKey.keepContext)
        }

        if defaults.object(forKey: PreferenceKey.trimSilence) != nil {
            configuration.trimSilence = defaults.bool(forKey: PreferenceKey.trimSilence)
        }

        if defaults.object(forKey: PreferenceKey.normalizeAudio) != nil {
            configuration.normalizeAudio = defaults.bool(forKey: PreferenceKey.normalizeAudio)
        }

        if defaults.object(forKey: PreferenceKey.livePreviewEnabled) != nil {
            configuration.livePreviewEnabled = defaults.bool(forKey: PreferenceKey.livePreviewEnabled)
        }

        if defaults.object(forKey: PreferenceKey.tapStopsOnNextKeyPress) != nil {
            configuration.tapStopsOnNextKeyPress = defaults.bool(forKey: PreferenceKey.tapStopsOnNextKeyPress)
        }

        if defaults.object(forKey: PreferenceKey.appAwarePolishingEnabled) != nil {
            configuration.appAwarePolishingEnabled = defaults.bool(forKey: PreferenceKey.appAwarePolishingEnabled)
        }

        if defaults.object(forKey: PreferenceKey.pressEnterCommandEnabled) != nil {
            configuration.pressEnterCommandEnabled = defaults.bool(forKey: PreferenceKey.pressEnterCommandEnabled)
        }

        if let pressEnterCommandPhrase = defaults.string(
            forKey: PreferenceKey.pressEnterCommandPhrase
        ) {
            configuration.pressEnterCommandPhrase = DictationCommandPhrase.sanitizedForStorage(
                pressEnterCommandPhrase
            )
        }

        if let vocabularyText = defaults.string(forKey: PreferenceKey.vocabularyText) {
            configuration.vocabularyText = vocabularyText
        }

        if !defaults.bool(forKey: PreferenceKey.didMigrateToFastDefaults) {
            configuration.model = .baseEnglish
            configuration.decodingMode = .greedy
            configuration.livePreviewEnabled = false
            defaults.set(true, forKey: PreferenceKey.didMigrateToFastDefaults)
            defaults.set(configuration.model.rawValue, forKey: PreferenceKey.whisperModel)
            defaults.set(configuration.decodingMode.rawValue, forKey: PreferenceKey.decodingMode)
            defaults.set(configuration.livePreviewEnabled, forKey: PreferenceKey.livePreviewEnabled)
        }

        if !defaults.bool(forKey: PreferenceKey.didUndoLivePreviewDefault) {
            let hasStaleLivePreviewMigration =
                defaults.bool(forKey: PreferenceKey.didMigrateToLivePreviewDefault) ||
                defaults.bool(forKey: PreferenceKey.didMigrateToLivePreviewDefaultV2)

            if hasStaleLivePreviewMigration {
                configuration.livePreviewEnabled = false
                defaults.set(false, forKey: PreferenceKey.livePreviewEnabled)
                preferencesLogger.info("Reset stale live preview default from earlier migration")
            }

            defaults.set(true, forKey: PreferenceKey.didUndoLivePreviewDefault)
        }

        return configuration
    }

    private static func loadWaveformSensitivity(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: PreferenceKey.waveformSensitivity) != nil else {
            return WaveformSensitivityTuning.defaultValue
        }
        return sanitizedWaveformSensitivity(defaults.double(forKey: PreferenceKey.waveformSensitivity))
    }

    private static func loadHUDMotionTuning(defaults: UserDefaults) -> HUDMotionTuning {
        let fallback = HUDMotionTuning.default
        return sanitizedHUDMotionTuning(HUDMotionTuning(
            pillResponse: defaults.object(forKey: PreferenceKey.hudPillResponse) == nil
                ? fallback.pillResponse
                : defaults.double(forKey: PreferenceKey.hudPillResponse),
            micFadeOutDuration: defaults.object(forKey: PreferenceKey.hudMicFadeOutDuration) == nil
                ? fallback.micFadeOutDuration
                : defaults.double(forKey: PreferenceKey.hudMicFadeOutDuration),
            appCueFadeInDuration: defaults.object(forKey: PreferenceKey.hudAppCueFadeInDuration) == nil
                ? fallback.appCueFadeInDuration
                : defaults.double(forKey: PreferenceKey.hudAppCueFadeInDuration),
            waveformFadeInDuration: defaults.object(forKey: PreferenceKey.hudWaveformFadeInDuration) == nil
                ? fallback.waveformFadeInDuration
                : defaults.double(forKey: PreferenceKey.hudWaveformFadeInDuration)
        ))
    }

    private static func sanitizedHUDMotionTuning(_ tuning: HUDMotionTuning) -> HUDMotionTuning {
        HUDMotionTuning(
            pillResponse: min(0.60, max(0.18, tuning.pillResponse)),
            micFadeOutDuration: min(0.30, max(0.04, tuning.micFadeOutDuration)),
            appCueFadeInDuration: min(0.40, max(0.04, tuning.appCueFadeInDuration)),
            waveformFadeInDuration: min(0.50, max(0.06, tuning.waveformFadeInDuration))
        )
    }

    private static func sanitizedWaveformSensitivity(_ sensitivity: Double) -> Double {
        min(
            WaveformSensitivityTuning.closedRange.upperBound,
            max(WaveformSensitivityTuning.closedRange.lowerBound, sensitivity)
        )
    }

    static func loadBinding(defaults: UserDefaults, action: HotkeyAction) -> HotkeyBinding {
        var binding: HotkeyBinding
        switch action {
        case .holdToTalk:
            binding = .defaultHoldToTalk
        case .tapToStartStop:
            binding = .defaultTapToStartStop
        case .scribe:
            binding = .defaultScribe
        }

        let keys = Self.preferenceKeys(for: action)
        if defaults.object(forKey: keys.enabled) != nil {
            binding.isEnabled = defaults.bool(forKey: keys.enabled)
        }

        if defaults.object(forKey: keys.keyCode) != nil {
            binding.shortcut.keyCode = UInt32(defaults.integer(forKey: keys.keyCode))
        }

        if defaults.object(forKey: keys.modifiers) != nil {
            binding.shortcut.carbonModifiers = UInt32(defaults.integer(forKey: keys.modifiers))
        }

        if let keyDisplay = defaults.string(forKey: keys.keyDisplay), !keyDisplay.isEmpty {
            binding.shortcut.keyDisplay = keyDisplay
        }

        if let sidedModifierKeyCodes = defaults.string(forKey: keys.sidedModifierKeyCodes) {
            binding.shortcut.sidedModifierKeyCodes = HotkeyConfiguration.sidedModifierKeyCodes(
                from: sidedModifierKeyCodes
            )
        }

        return binding
    }

    private static func currentHotkeyBindings(
        hold: HotkeyBinding,
        tap: HotkeyBinding,
        scribe: HotkeyBinding
    ) -> [HotkeyBinding] {
        [hold, tap, scribe]
    }

    private static func loadTranscriptHistory(defaults: UserDefaults) -> [TranscriptHistoryItem] {
        guard let data = defaults.data(forKey: PreferenceKey.transcriptHistory),
              let history = try? JSONDecoder().decode([TranscriptHistoryItem].self, from: data) else {
            return []
        }
        return history
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case 0..<50:
            return "0-49"
        case 50..<200:
            return "50-199"
        case 200..<800:
            return "200-799"
        default:
            return "800+"
        }
    }

    private static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = raw.components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Meeting Note" : sanitized
    }

    private static func calendarMeetingNoteTemplate(for event: GoogleCalendarEvent) -> String {
        var lines = [
            "Calendar event: \(event.title)",
            "Starts: \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let meetingURL = event.meetingURL {
            lines.append("Meeting URL: \(meetingURL.absoluteString)")
        }
        if !event.attendeeEmails.isEmpty {
            lines.append("Attendees: \(event.attendeeEmails.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func analyticsMilliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(seconds, 0) * 1000).rounded())
    }

    private static func analyticsSeconds(_ seconds: TimeInterval) -> Double {
        (max(seconds, 0) * 100).rounded() / 100
    }

    private static func analyticsErrorReason(for error: Error) -> String {
        switch error {
        case WhisperEngineError.contextInitializationFailed:
            return "contextInitializationFailed"
        case WhisperEngineError.emptyAudio:
            return "emptyAudio"
        case WhisperEngineError.noTranscript:
            return "noTranscript"
        case SystemAudioCaptureError.screenRecordingPermissionRequired:
            return "screenRecordingPermissionRequired"
        case SystemAudioCaptureError.noDisplayAvailable:
            return "noDisplayAvailable"
        case SystemAudioCaptureError.audioOutputUnavailable:
            return "audioOutputUnavailable"
        default:
            return "other"
        }
    }

    private var missingPermissionNames: [String] {
        var missing = [String]()
        if !permissions.microphoneGranted {
            missing.append("Microphone")
        }
        if !permissions.accessibilityGranted {
            missing.append("Accessibility")
        }
        if !permissions.inputMonitoringGranted {
            missing.append("Input Monitoring")
        }
        return missing
    }

    private static func isTransientCaptureError(_ raw: String) -> Bool {
        let lowercased = raw.lowercased()
        return lowercased.contains("no speech audio was captured") ||
            lowercased.contains("whisper did not return any transcript text")
    }

    private static func isBenignMeetingTranscriptionError(_ error: Error) -> Bool {
        switch error {
        case WhisperEngineError.emptyAudio, WhisperEngineError.noTranscript:
            return true
        default:
            return isTransientCaptureError(error.localizedDescription)
        }
    }

    static func humanizedErrorMessage(_ raw: String) -> String {
        if raw.contains("No speech audio was captured.") {
            return "Nothing was picked up. Try speaking a little louder or closer to the mic."
        }
        if raw.contains("Whisper did not return any transcript text") {
            return "Nothing was picked up. Try speaking a little louder or closer to the mic."
        }
        if raw.contains("Press To Start/Stop shortcut rejected") {
            return "Toggle Recording needs 2 or more keys. Try Control + Option."
        }
        if raw.contains("Hold To Talk shortcut rejected") {
            return "Hold To Talk works best with 1 or 2 modifier keys."
        }

        let lowercased = raw.lowercased()
        if lowercased.contains("nsurlerrordomain") && lowercased.contains("code=-999") {
            return "Model download was interrupted. Try the quality mode again in a moment."
        }
        if lowercased.contains("model not found") || lowercased.contains("repo name") {
            return "Cadence could not find that model yet. Try again while connected to the internet."
        }
        if lowercased.contains("internet") || lowercased.contains("offline") || lowercased.contains("timed out") {
            return "Cadence needs internet once to finish downloading this model."
        }

        return raw
    }

    private static func preferenceKeys(
        for action: HotkeyAction
    ) -> (enabled: String, keyCode: String, modifiers: String, keyDisplay: String, sidedModifierKeyCodes: String) {
        switch action {
        case .holdToTalk:
            return (
                enabled: PreferenceKey.holdEnabled,
                keyCode: PreferenceKey.holdKeyCode,
                modifiers: PreferenceKey.holdModifiers,
                keyDisplay: PreferenceKey.holdKeyDisplay,
                sidedModifierKeyCodes: PreferenceKey.holdSidedModifierKeyCodes
            )
        case .tapToStartStop:
            return (
                enabled: PreferenceKey.tapEnabled,
                keyCode: PreferenceKey.tapKeyCode,
                modifiers: PreferenceKey.tapModifiers,
                keyDisplay: PreferenceKey.tapKeyDisplay,
                sidedModifierKeyCodes: PreferenceKey.tapSidedModifierKeyCodes
            )
        case .scribe:
            return (
                enabled: PreferenceKey.scribeEnabled,
                keyCode: PreferenceKey.scribeKeyCode,
                modifiers: PreferenceKey.scribeModifiers,
                keyDisplay: PreferenceKey.scribeKeyDisplay,
                sidedModifierKeyCodes: PreferenceKey.scribeSidedModifierKeyCodes
            )
        }
    }

    private static var scribePrivacyMode: ScribePrivacyMode {
        return .approvedProvider
    }

    private static func makeScribeProvider() -> any ScribeProvider {
        #if DEBUG
        return MockScribeProvider(responses: [
            .success("This is a local preview draft from Cadence. Review it before inserting.")
        ])
        #else
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let provider = FoundationModelsScribeProvider()
            if provider.capabilities.contains(.semanticGeneration) {
                return provider
            }
        }
        #endif
        return UnavailableScribeProvider()
        #endif
    }
}

private enum MeetingAudioStopResult: Sendable {
    case completed(AudioCaptureSessionMetrics)
    case timedOut
}

private final class MeetingAudioStopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<MeetingAudioStopResult, Never>,
        with result: MeetingAudioStopResult
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}
