import AppKit
import SwiftUI

struct HUDAdaptiveShape: Shape {
    let position: HUDPosition

    func path(in rect: CGRect) -> Path {
        let radii = position.cornerRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        ).path(in: rect)
    }
}

struct HUDContentAttachment {
    let alignment: Alignment
    let anchor: UnitPoint

    static func forPosition(_ position: HUDPosition) -> HUDContentAttachment {
        switch position {
        case .bottomCenter:
            HUDContentAttachment(alignment: .bottom, anchor: .bottom)
        case .topLeft:
            HUDContentAttachment(alignment: .topLeading, anchor: .topLeading)
        case .topRight:
            HUDContentAttachment(alignment: .topTrailing, anchor: .topTrailing)
        case .bottomLeft:
            HUDContentAttachment(alignment: .bottomLeading, anchor: .bottomLeading)
        case .bottomRight:
            HUDContentAttachment(alignment: .bottomTrailing, anchor: .bottomTrailing)
        }
    }

    static func appKitOrigin(
        position: HUDPosition,
        contentSize: NSSize,
        containerSize: NSSize
    ) -> NSPoint {
        switch position {
        case .bottomCenter:
            NSPoint(x: (containerSize.width - contentSize.width) / 2, y: 0)
        case .topLeft:
            NSPoint(x: 0, y: containerSize.height - contentSize.height)
        case .topRight:
            NSPoint(
                x: containerSize.width - contentSize.width,
                y: containerSize.height - contentSize.height
            )
        case .bottomLeft:
            .zero
        case .bottomRight:
            NSPoint(x: containerSize.width - contentSize.width, y: 0)
        }
    }
}

enum HUDForegroundMaskLayout {
    static func frame(
        position: HUDPosition,
        targetWidth: CGFloat,
        renderedWidth: CGFloat
    ) -> CGRect {
        let visibleWidth = max(0, min(targetWidth, renderedWidth))
        let remainingTravel = max(0, targetWidth - visibleWidth)
        let insidePadding = min(HUDContentSizing.horizontalPadding, remainingTravel)
        let paddedWidth = max(0, visibleWidth - insidePadding)
        let visibleOriginX: CGFloat
        switch position {
        case .topLeft, .bottomLeft:
            visibleOriginX = 0
        case .topRight, .bottomRight:
            visibleOriginX = targetWidth - visibleWidth
        case .bottomCenter:
            visibleOriginX = (targetWidth - visibleWidth) / 2
        }

        let x: CGFloat
        switch position {
        case .topLeft, .bottomLeft, .bottomCenter:
            x = visibleOriginX
        case .topRight, .bottomRight:
            x = visibleOriginX + insidePadding
        }

        return CGRect(
            x: x,
            y: (HUDMetrics.panelHeight - HUDMetrics.pillHeight) / 2,
            width: paddedWidth,
            height: HUDMetrics.pillHeight
        )
    }
}

enum HUDRestingMicrophoneLayout {
    static func centerX(position: HUDPosition, containerWidth: CGFloat) -> CGFloat {
        switch position {
        case .topLeft, .bottomLeft:
            return HUDMetrics.idleHitSize.width / 2
        case .topRight, .bottomRight:
            return containerWidth - HUDMetrics.idleHitSize.width / 2
        case .bottomCenter:
            return containerWidth / 2
        }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var scribeHueRotation = 0.0

    var body: some View {
        ZStack(alignment: attachment.alignment) {
            if !model.presentation.isExpanded {
                pillChrome
                    .frame(width: morphWidth, height: HUDMetrics.pillHeight)
                    .frame(width: morphWidth, height: HUDMetrics.panelHeight, alignment: .center)
            }

            if let previous = model.previousPresentation,
               model.isReplacingStatusContent {
                replacingStatusPill(
                    from: previous,
                    to: model.presentation,
                    renderedWidth: morphWidth
                )
            } else {
                if let previous = model.previousPresentation {
                    content(
                        for: previous,
                        isIncoming: false,
                        renderedWidth: morphWidth,
                        hidesApplicationMark: model.isCollapsingToRestingMic
                    )
                        .opacity(outgoingOpacity(for: previous))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                content(
                    for: model.presentation,
                    isIncoming: model.previousPresentation != nil,
                    renderedWidth: morphWidth,
                    hidesApplicationMark: false
                )
                    .opacity(incomingOpacity)
            }

            if let previous = model.previousPresentation,
               model.isCollapsingToRestingMic {
                reverseMorphingApplicationMark(
                    sourceWidth: model.targetWidth(for: previous),
                    renderedWidth: morphWidth
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: attachment.alignment)
        .clipped()
        .modifier(HUDRootAccessibilityModifier(
            presentation: model.presentation,
            application: model.applicationPresentation,
            model: model
        ))
        .onAppear {
            model.setReducedMotion(reduceMotion)
            startScribeHueIfNeeded()
        }
        .onChange(of: reduceMotion) { _, reduced in
            model.setReducedMotion(reduced)
            startScribeHueIfNeeded()
        }
        .onChange(of: model.presentation.visualState) { oldState, newState in
            let wasScribe = isScribePresentation(oldState)
            let isScribe = isScribePresentation(newState)
            if !wasScribe, isScribe {
                startScribeHueIfNeeded()
            } else if wasScribe, !isScribe {
                withAnimation(nil) {
                    scribeHueRotation = 0
                }
            }
        }
    }

    @ViewBuilder
    private func content(
        for presentation: HUDPresentation,
        isIncoming: Bool,
        renderedWidth: CGFloat,
        hidesApplicationMark: Bool
    ) -> some View {
        switch presentation.visualState {
        case .idle:
            if presentation.isExpanded {
                IdleExpandedTray(model: model)
            } else {
                microphonePill(
                    iconOpacity: model.isCollapsingToRestingMic ? 0 : 1
                )
            }
        case .recording(let triggerMode, let showsHint):
            recordingPill(
                triggerMode: triggerMode,
                showsHint: showsHint,
                revealsContent: isIncoming && model.shouldMorphApplicationMark,
                hidesApplicationMark: hidesApplicationMark,
                renderedWidth: renderedWidth
            )
        case .scribeRecording:
            recordingPill(
                triggerMode: .tapToStartStop,
                showsHint: false,
                revealsContent: isIncoming && model.shouldMorphApplicationMark,
                hidesApplicationMark: hidesApplicationMark,
                renderedWidth: renderedWidth
            )
        case .preparingModel:
            statusPill(
                icon: .spinner,
                text: "Setting up speech model…",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .transcribing:
            statusPill(
                icon: .spinner,
                text: "Transcribing",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .scribeTranscribing:
            statusPill(
                icon: .spinner,
                text: "Transcribing",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .scribed:
            statusPill(
                icon: .success,
                text: "Scribed",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .inserting:
            statusPill(
                icon: .spinner,
                text: "Inserting…",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .copying:
            statusPill(
                icon: .spinner,
                text: "Copying…",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .copied:
            statusPill(
                icon: .success,
                text: "Copied",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .success:
            statusPill(
                icon: .success,
                text: "Inserted",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .cancelled:
            statusPill(
                icon: .cancelled,
                text: "Cancelled",
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        case .error(let message):
            statusPill(
                icon: .error,
                text: message,
                targetWidth: model.targetWidth(for: presentation),
                renderedWidth: renderedWidth,
                hidesApplicationMark: hidesApplicationMark
            )
        }
    }

    private var morphWidth: CGFloat {
        model.renderedWidth
    }

    private func outgoingOpacity(for presentation: HUDPresentation) -> Double {
        if model.isCollapsingToRestingMic {
            // The padded mask supplies the physical wipe while this shorter
            // fade prevents text and waveform fragments from looking clipped.
            // The moving app-icon-to-mic crossfade continues after this ends.
            return HUDMotion.collapsingContentOpacity(
                elapsed: model.morphElapsed,
                pillResponse: model.motionTuning.pillResponse
            )
        }
        if model.isReplacingActiveContent {
            return HUDActiveContentTransition.outgoingOpacity(
                elapsed: model.morphElapsed
            )
        }
        guard presentation.visualState == .idle else {
            return 1 - model.morphProgress
        }
        return 1 - HUDMotion.smoothProgress(
            elapsed: model.morphElapsed,
            duration: model.motionTuning.micFadeOutDuration
        )
    }

    private var incomingOpacity: Double {
        if model.isReplacingActiveContent {
            return HUDActiveContentTransition.incomingOpacity(
                elapsed: model.morphElapsed
            )
        }
        return HUDMotion.incomingOpacity(
            for: model.presentation,
            hasPreviousPresentation: model.previousPresentation != nil,
            elapsed: model.morphElapsed,
            duration: min(0.16, model.motionTuning.pillResponse)
        )
    }

    private func microphonePill(iconOpacity: Double) -> some View {
        ZStack {
            Color.clear
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
                .opacity(iconOpacity)
        }
            .frame(width: HUDMetrics.idleHitSize.width, height: HUDMetrics.idleHitSize.height)
            .overlay {
                HUDLogoInteractionSurface(model: model)
            }
            .accessibilityLabel("Cadence microphone")
            .accessibilityHint("Drag to move Cadence, or use an action to move it to a screen corner.")
    }

    @ViewBuilder
    private func applicationMark(size: NSSize) -> some View {
        let presentation = model.applicationPresentation
        Group {
            if presentation.kind == .cadence {
                Image("HUDLogo")
                    .resizable()
                    .interpolation(.high)
                    .accessibilityLabel("Cadence")
            } else if let icon = presentation.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .accessibilityLabel(presentation.displayName)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .accessibilityLabel("\(presentation.displayName) application")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(HUDAdaptiveShape(position: model.position))
    }

    private var attachment: HUDContentAttachment {
        HUDContentAttachment.forPosition(model.position)
    }

    private func recordingPill(
        triggerMode: DictationTriggerMode,
        showsHint: Bool,
        revealsContent: Bool,
        hidesApplicationMark: Bool,
        renderedWidth: CGFloat
    ) -> some View {
        let targetWidth = pillWidth(triggerMode: triggerMode, showsHint: showsHint)
        return ZStack(alignment: horizontalAlignment) {
            HStack(spacing: HUDContentSizing.contentGap) {
                if usesTrailingAttachment {
                    applicationCue(hidesIcon: revealsContent || hidesApplicationMark)
                        .opacity(revealsContent ? applicationCueReveal : 1)

                    recordingActivity(
                        triggerMode: triggerMode,
                        showsHint: showsHint,
                        revealsContent: revealsContent
                    )
                } else {
                    recordingActivity(
                        triggerMode: triggerMode,
                        showsHint: showsHint,
                        revealsContent: revealsContent
                    )

                    applicationCue(hidesIcon: revealsContent || hidesApplicationMark)
                        .opacity(revealsContent ? applicationCueReveal : 1)
                }
            }
            .padding(.horizontal, HUDContentSizing.horizontalPadding)
            .frame(width: targetWidth, height: HUDMetrics.pillHeight)
            .offset(x: foregroundTravelOffset(revealsContent: revealsContent))
            .compositingGroup()
            .mask {
                foregroundMask(targetWidth: targetWidth, renderedWidth: renderedWidth)
            }

            if revealsContent {
                morphingApplicationMark(targetWidth: targetWidth, renderedWidth: renderedWidth)
            }
        }
        .frame(width: targetWidth, height: HUDMetrics.panelHeight, alignment: horizontalAlignment)
    }

    private var horizontalAlignment: Alignment {
        switch model.position {
        case .bottomCenter:
            return .center
        case .topLeft, .bottomLeft:
            return .leading
        case .topRight, .bottomRight:
            return .trailing
        }
    }

    private var usesTrailingAttachment: Bool {
        switch model.position {
        case .topRight, .bottomRight:
            return true
        case .bottomCenter, .topLeft, .bottomLeft:
            return false
        }
    }

    @ViewBuilder
    private func recordingActivity(
        triggerMode: DictationTriggerMode,
        showsHint: Bool,
        revealsContent: Bool
    ) -> some View {
        if triggerMode == .holdToTalk, showsHint {
            Text("Release to stop")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }

        WaveformCanvasView(levels: model.displayBars)
            .frame(width: HUDMetrics.waveformWidth, height: HUDMetrics.waveformHeight)
            .opacity(revealsContent ? waveformReveal : 1)
    }

    private var applicationCueReveal: Double {
        HUDMotion.smoothProgress(
            elapsed: model.morphElapsed,
            duration: model.motionTuning.appCueFadeInDuration
        )
    }

    private var waveformReveal: Double {
        HUDMotion.smoothProgress(
            elapsed: model.morphElapsed,
            duration: model.motionTuning.waveformFadeInDuration
        )
    }

    private func foregroundTravelOffset(revealsContent: Bool) -> CGFloat {
        guard revealsContent, !model.isReducedMotionEnabled else { return 0 }
        let remaining = CGFloat(1 - model.morphProgress)
        switch model.position {
        case .topLeft, .bottomLeft:
            return -HUDMotion.foregroundTravelDistance * remaining
        case .topRight, .bottomRight:
            return HUDMotion.foregroundTravelDistance * remaining
        case .bottomCenter:
            return 0
        }
    }

    private func foregroundMask(
        targetWidth: CGFloat,
        renderedWidth: CGFloat
    ) -> some View {
        let frame = HUDForegroundMaskLayout.frame(
            position: model.position,
            targetWidth: targetWidth,
            renderedWidth: renderedWidth
        )
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(width: targetWidth, height: HUDMetrics.panelHeight)
    }

    private func morphingApplicationMark(
        targetWidth: CGFloat,
        renderedWidth: CGFloat
    ) -> some View {
        let progress = model.morphProgress
        let edgeIconCenter = HUDContentSizing.horizontalPadding
            + HUDContentSizing.iconSize / 2
        let startX: CGFloat
        let endX: CGFloat
        switch model.position {
        case .topRight, .bottomRight:
            startX = targetWidth - HUDMetrics.idleHitSize.width / 2
            endX = edgeIconCenter
        case .topLeft, .bottomLeft:
            startX = HUDMetrics.idleHitSize.width / 2
            endX = targetWidth - edgeIconCenter
        case .bottomCenter:
            startX = targetWidth / 2
            endX = edgeIconCenter
        }
        let iconX = HUDMotion.interpolateWidth(from: startX, to: endX, progress: progress)

        return ZStack(alignment: .topLeading) {
            applicationMark(size: NSSize(width: 16, height: 16))
                .scaleEffect(0.82 + 0.18 * progress)
                .opacity(applicationCueReveal)
                .position(x: iconX, y: HUDMetrics.panelHeight / 2)
        }
        .frame(width: targetWidth, height: HUDMetrics.panelHeight)
        .frame(width: renderedWidth, alignment: horizontalAlignment)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func reverseMorphingApplicationMark(
        sourceWidth: CGFloat,
        renderedWidth: CGFloat
    ) -> some View {
        let progress = model.morphProgress
        let micProgress = HUDMotion.smoothProgress(
            elapsed: model.morphElapsed,
            duration: min(0.22, model.motionTuning.pillResponse * 0.72)
        )
        let edgeIconCenter = HUDContentSizing.horizontalPadding
            + HUDContentSizing.iconSize / 2
        let startX: CGFloat
        let endX = HUDRestingMicrophoneLayout.centerX(
            position: model.position,
            containerWidth: sourceWidth
        )
        switch model.position {
        case .topRight, .bottomRight:
            startX = edgeIconCenter
        case .topLeft, .bottomLeft:
            startX = sourceWidth - edgeIconCenter
        case .bottomCenter:
            startX = sourceWidth - edgeIconCenter
        }
        let iconX = HUDMotion.interpolateWidth(from: startX, to: endX, progress: progress)

        return ZStack(alignment: .topLeading) {
            ZStack {
                applicationMark(size: NSSize(width: 16, height: 16))
                    .opacity(1 - micProgress)

                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .opacity(micProgress)
            }
            .position(x: iconX, y: HUDMetrics.panelHeight / 2)
        }
        .frame(width: sourceWidth, height: HUDMetrics.panelHeight)
        .frame(width: renderedWidth, alignment: horizontalAlignment)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func statusPill(
        icon: StatusIcon,
        text: String,
        targetWidth: CGFloat,
        renderedWidth: CGFloat,
        hidesApplicationMark: Bool
    ) -> some View {
        ZStack(alignment: horizontalAlignment) {
            HStack(spacing: HUDContentSizing.contentGap) {
                if usesTrailingAttachment {
                    applicationCue(hidesIcon: hidesApplicationMark)
                    statusActivity(icon: icon, text: text)
                } else {
                    statusActivity(icon: icon, text: text)
                    applicationCue(hidesIcon: hidesApplicationMark)
                }
            }
            .padding(.horizontal, HUDContentSizing.horizontalPadding)
            .frame(width: targetWidth, height: HUDMetrics.pillHeight)
            .compositingGroup()
            .mask {
                foregroundMask(targetWidth: targetWidth, renderedWidth: renderedWidth)
            }
        }
        .frame(width: targetWidth, height: HUDMetrics.panelHeight, alignment: horizontalAlignment)
    }

    @ViewBuilder
    private func replacingStatusPill(
        from previous: HUDPresentation,
        to current: HUDPresentation,
        renderedWidth: CGFloat
    ) -> some View {
        if let outgoing = statusDescriptor(for: previous.visualState),
           let incoming = statusDescriptor(for: current.visualState) {
            let targetWidth = model.targetWidth(for: current)
            ZStack(alignment: horizontalAlignment) {
                HStack(spacing: HUDContentSizing.contentGap) {
                    if usesTrailingAttachment {
                        applicationCue()
                        replacingStatusActivity(
                            outgoing: outgoing,
                            incoming: incoming
                        )
                    } else {
                        replacingStatusActivity(
                            outgoing: outgoing,
                            incoming: incoming
                        )
                        applicationCue()
                    }
                }
                .padding(.horizontal, HUDContentSizing.horizontalPadding)
                .frame(width: targetWidth, height: HUDMetrics.pillHeight)
                .compositingGroup()
                .mask {
                    foregroundMask(
                        targetWidth: targetWidth,
                        renderedWidth: renderedWidth
                    )
                }
            }
            .frame(
                width: targetWidth,
                height: HUDMetrics.panelHeight,
                alignment: horizontalAlignment
            )
        }
    }

    private func replacingStatusActivity(
        outgoing: StatusDescriptor,
        incoming: StatusDescriptor
    ) -> some View {
        ZStack {
            statusActivity(icon: outgoing.icon, text: outgoing.text)
                .opacity(HUDActiveContentTransition.outgoingOpacity(
                    elapsed: model.morphElapsed
                ))
            statusActivity(icon: incoming.icon, text: incoming.text)
                .opacity(HUDActiveContentTransition.incomingOpacity(
                    elapsed: model.morphElapsed
                ))
        }
        .frame(
            width: HUDMetrics.waveformWidth,
            height: HUDMetrics.waveformHeight,
            alignment: .center
        )
    }

    private func statusDescriptor(for state: HUDVisualState) -> StatusDescriptor? {
        switch state {
        case .idle, .recording, .scribeRecording:
            return nil
        case .preparingModel:
            return StatusDescriptor(icon: .spinner, text: "Setting up speech model…")
        case .transcribing:
            return StatusDescriptor(icon: .spinner, text: "Transcribing")
        case .scribeTranscribing:
            return StatusDescriptor(icon: .spinner, text: "Transcribing")
        case .scribed:
            return StatusDescriptor(icon: .success, text: "Scribed")
        case .inserting:
            return StatusDescriptor(icon: .spinner, text: "Inserting…")
        case .copying:
            return StatusDescriptor(icon: .spinner, text: "Copying…")
        case .copied:
            return StatusDescriptor(icon: .success, text: "Copied")
        case .success:
            return StatusDescriptor(icon: .success, text: "Inserted")
        case .cancelled:
            return StatusDescriptor(icon: .cancelled, text: "Cancelled")
        case .error(let message):
            return StatusDescriptor(icon: .error, text: message)
        }
    }

    @ViewBuilder
    private func statusActivity(icon: StatusIcon, text: String) -> some View {
        Group {
            if icon == .spinner, text == "Transcribing" {
                ScribeTranscribingStatusView(
                    fontSize: 12,
                    spacing: HUDContentSizing.contentGap
                )
            } else {
                HStack(spacing: HUDContentSizing.contentGap) {
                    switch icon {
                    case .spinner:
                        HUDSpinnerView()
                    case .error:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FlowTheme.error)
                    case .success:
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FlowTheme.accent)
                    case .cancelled:
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }

                    if icon == .error {
                        HUDMarqueeText(text: text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                    } else {
                        Text(text)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FlowTheme.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .frame(
            width: HUDMetrics.waveformWidth,
            height: HUDMetrics.waveformHeight,
            alignment: .center
        )
    }

    private func pillWidth(triggerMode: DictationTriggerMode, showsHint: Bool) -> CGFloat {
        HUDContentSizing.width(
            for: HUDPresentation(
                visualState: .recording(triggerMode: triggerMode, showsHint: showsHint),
                isExpanded: false
            ),
            applicationName: model.applicationPresentation.displayName
        )
    }

    private var adaptiveClipShape: HUDAdaptiveShape {
        HUDAdaptiveShape(position: model.position)
    }

    private var pillChrome: some View {
        ZStack {
            HUDChromeSurface(
                shape: adaptiveClipShape,
                isDark: colorScheme == .dark,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
            if isScribePresentation {
                adaptiveClipShape
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.35, green: 0.84, blue: 1),
                                Color(red: 0.66, green: 0.47, blue: 1),
                                Color(red: 1, green: 0.45, blue: 0.74),
                                Color(red: 1, green: 0.68, blue: 0.40),
                                Color(red: 0.35, green: 0.84, blue: 1)
                            ],
                            center: .center,
                            startAngle: .degrees(scribeHueRotation),
                            endAngle: .degrees(scribeHueRotation + 360)
                        ),
                        lineWidth: colorSchemeContrast == .increased ? 2.25 : 1.7
                    )
                    .padding(1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var isScribePresentation: Bool {
        isScribePresentation(model.presentation.visualState)
    }

    private func isScribePresentation(_ state: HUDVisualState) -> Bool {
        switch state {
        case .scribeRecording, .scribeTranscribing, .scribed:
            return true
        default:
            return false
        }
    }

    private func startScribeHueIfNeeded() {
        guard !reduceMotion else {
            scribeHueRotation = 0
            return
        }
        scribeHueRotation = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            scribeHueRotation = 360
        }
    }

    private enum StatusIcon {
        case spinner
        case error
        case success
        case cancelled
    }

    private struct StatusDescriptor {
        let icon: StatusIcon
        let text: String
    }

    private func applicationCue(hidesIcon: Bool = false) -> some View {
        HStack(spacing: HUDContentSizing.iconNameGap) {
            if usesTrailingAttachment {
                applicationMark(size: NSSize(width: 16, height: 16))
                    .opacity(hidesIcon ? 0 : 1)
                applicationName
            } else {
                applicationName
                applicationMark(size: NSSize(width: 16, height: 16))
                    .opacity(hidesIcon ? 0 : 1)
            }
        }
        .accessibilityHidden(true)
    }

    private var applicationName: some View {
        HUDMarqueeText(
            text: model.applicationPresentation.displayName,
            fontSize: 10,
            weight: .medium,
            color: FlowTheme.textTertiary,
            pause: 0.6,
            pointsPerSecond: 28
        )
        .frame(
            width: HUDContentSizing.applicationNameWidth(
                model.applicationPresentation.displayName
            ),
            height: 16
        )
    }

}

struct HUDLockIndicatorView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.accent)
            .frame(
                width: HUDMetrics.lockIndicatorSize.width,
                height: HUDMetrics.lockIndicatorSize.height
            )
            .background {
                HUDChromeSurface(
                    shape: Capsule(),
                    isDark: colorScheme == .dark,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: colorSchemeContrast == .increased
                )
            }
            .accessibilityLabel("Listening locked")
    }
}

private struct HUDChromeSurface<ChromeShape: Shape>: View {
    let shape: ChromeShape
    let isDark: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    var body: some View {
        let style = HUDChromeStyle.resolve(
            isDark: isDark,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast
        )

        ZStack {
            if !reduceTransparency {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(
                Color(nsColor: NSColor(
                    hex: style.surfaceHex,
                    alpha: style.surfaceOpacity
                ))
            )
            shape.stroke(
                Color(nsColor: NSColor(
                    hex: style.borderHex,
                    alpha: style.borderOpacity
                )),
                lineWidth: 0.75
            )
        }
    }
}

private struct HUDMarqueeText: View {
    let text: String
    var fontSize: CGFloat = 12
    var weight: Font.Weight = .medium
    var color: Color = FlowTheme.error
    var pause: TimeInterval = 0.42
    var pointsPerSecond: CGFloat = 42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 120, paused: reduceMotion)) { timeline in
                let availableWidth = geometry.size.width
                let overflow = max(0, measuredTextWidth - availableWidth)
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt) - pause)
                let travel = min(overflow, CGFloat(elapsed) * pointsPerSecond)

                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: reduceMotion ? 0 : -travel)
                    .frame(height: geometry.size.height, alignment: .center)
            }
        }
        .clipped()
        .onAppear { startedAt = Date() }
        .onChange(of: text) { _, _ in startedAt = Date() }
        .accessibilityLabel(text)
    }

    private var measuredTextWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

private struct HUDRootAccessibilityModifier: ViewModifier {
    let presentation: HUDPresentation
    let application: HUDApplicationPresentation
    let model: HUDViewModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if presentation.exposesInteractiveChildren {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(HUDAccessibilityLabelResolver.label(
                    visualState: presentation.visualState,
                    application: application
                ))
                .accessibilityHint(presentation.visualState.accessibilityHint ?? "")
                .accessibilityAction(named: "Move to top left") { model.requestMove(to: .topLeft) }
                .accessibilityAction(named: "Move to top right") { model.requestMove(to: .topRight) }
                .accessibilityAction(named: "Move to bottom left") { model.requestMove(to: .bottomLeft) }
                .accessibilityAction(named: "Move to bottom center") { model.requestMove(to: .bottomCenter) }
                .accessibilityAction(named: "Move to bottom right") { model.requestMove(to: .bottomRight) }
        }
    }
}

enum HUDAccessibilityLabelResolver {
    static func label(
        visualState: HUDVisualState,
        application: HUDApplicationPresentation
    ) -> String {
        let base = visualState.accessibilityLabel
        guard application.kind != .cadence else { return base }
        switch visualState {
        case .idle:
            return base
        default:
            return "\(base) in \(application.displayName)"
        }
    }
}

/// AppKit owns the logo pointer sequence so coordinates remain stable while its
/// panel moves. This surface exists only for the collapsed idle logo; expanded
/// tray buttons therefore never compete with drag recognition.
private struct HUDLogoInteractionSurface: NSViewRepresentable {
    @ObservedObject var model: HUDViewModel

    func makeNSView(context: Context) -> HUDLogoInteractionView {
        let view = HUDLogoInteractionView()
        view.setAccessibilityElement(false)
        configure(view)
        return view
    }

    func updateNSView(_ view: HUDLogoInteractionView, context: Context) {
        configure(view)
    }

    private func configure(_ view: HUDLogoInteractionView) {
        view.onEvent = { [weak model] event in
            model?.handleLogoInteraction(event)
        }
    }
}

final class HUDLogoInteractionView: NSView {
    var onEvent: ((HUDLogoInteractionEvent) -> Void)?
    private var tracker = HUDLogoPointerTracker()

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        tracker.begin(at: point)
        onEvent?(.began(point))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard tracker.update(to: point) else { return }
        onEvent?(.moved(point))
    }

    override func mouseUp(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch tracker.end(at: point) {
        case .click:
            onEvent?(.clicked)
        case .drag:
            onEvent?(.moved(point))
            onEvent?(.ended(point))
        case .none:
            break
        }
    }
}

struct HUDSpinnerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowTheme.accent)
                .rotationEffect(.degrees(
                    reduceMotion
                        ? 0
                        : HUDSpinnerMotion.degrees(
                            at: context.date.timeIntervalSinceReferenceDate
                        )
                ))
                .frame(width: 14, height: 14)
        }
    }
}

struct ScribeTranscribingStatusView: View {
    var fontSize: CGFloat = 12
    var spacing: CGFloat = HUDContentSizing.contentGap

    var body: some View {
        HStack(spacing: spacing) {
            HUDSpinnerView()
            Text("Transcribing")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing")
    }
}

enum HUDSpinnerMotion {
    static let cycleDuration: TimeInterval = 0.9

    static func degrees(at time: TimeInterval) -> Double {
        guard time.isFinite else { return 0 }
        let phase = time.truncatingRemainder(dividingBy: cycleDuration)
        return (phase / cycleDuration) * 360
    }
}

private struct WaveformCanvasView: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let barCount = levels.count
            guard barCount > 0 else { return }

            let barWidth = HUDMetrics.waveformBarWidth
            let barGap = HUDMetrics.waveformBarGap
            let maxHeight = max(22, size.height - 2)
            // The resting stroke and the pulse's first frame share this visual
            // baseline, avoiding a hairline that suddenly thickens on start.
            let minHeight: CGFloat = 6
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
            let startX = max(0, (size.width - totalWidth) / 2)

            for (index, level) in levels.enumerated() {
                let clamped = max(0, min(1, level))
            // Preserve more contrast between neighboring envelope samples than
            // a square-root curve, which made quiet speech look nearly flat.
            let boosted = pow(clamped, 0.72)
                let barHeight = minHeight + CGFloat(boosted) * (maxHeight - minHeight)
                let x = startX + CGFloat(index) * (barWidth + barGap)
                let y = (size.height - barHeight) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(FlowTheme.accent.opacity(0.96)))
            }
        }
    }
}

struct HUDControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
