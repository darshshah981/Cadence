import AppKit
import SwiftUI

/// The same guided journey is used in onboarding, Dictation, and Settings.
/// It never opens a second wizard or automatically requests the next permission.
struct PermissionSetupCard: View {
    @ObservedObject var appModel: AppModel
    @State private var showsHelp = false

    private var next: CorePermission? { appModel.permissionSetup.next(in: appModel.permissions) }
    private var completed: Int { CorePermission.allCases.filter { $0.isGranted(in: appModel.permissions) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(next == nil ? "Your Mac is ready" : "Let’s set up your Mac")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(completed) of 3 ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
            }

            VStack(spacing: 8) {
                ForEach(CorePermission.allCases) { permission in
                    HStack(spacing: 8) {
                        Image(systemName: permission.isGranted(in: appModel.permissions)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(permission.isGranted(in: appModel.permissions)
                                             ? FlowTheme.success : FlowTheme.textTertiary)
                        Text(permission.title)
                            .font(.system(size: 12, weight: permission == next ? .semibold : .regular))
                        Spacer()
                        Text(permission.isGranted(in: appModel.permissions) ? "Ready" : permission == next ? "Next" : "Later")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let permission = next {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(permission.purpose)
                        .font(.system(size: 13, weight: .medium))
                    Text(instructions(for: permission))
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)

                    if appModel.permissionSetup.phase == .waiting {
                        Label("Waiting for macOS. We’ll check automatically.", systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.textSecondary)
                    } else if appModel.permissionSetup.phase == .openFailed {
                        Text("System Settings didn’t open. Open it from the Apple menu, then choose Privacy & Security → \(permission.title).")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.error)
                    } else if appModel.permissionSetup.phase == .notDetected {
                        Text("macOS hasn’t reported access yet. You can try again, or open the help below if you already switched it on.")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                CadenceActionButton(
                    title: actionTitle(for: permission),
                    role: .primary
                ) {
                    if appModel.permissionSetup.phase == .waiting {
                        appModel.checkPermissionSetup()
                    } else {
                        appModel.requestCorePermission(permission)
                    }
                }
                .disabled(appModel.permissionSetup.phase == .requesting)
                .accessibilityIdentifier("permission-setup-primary")

                if permission != .microphone {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the app is missing, drag it into the \(permission.title) list in System Settings, then turn its switch on.")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: appModel.permissionAppPath))
                                .resizable()
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appModel.permissionAppName).font(.system(size: 12, weight: .semibold))
                                Text("Drag this app to System Settings").font(.system(size: 11))
                                    .foregroundStyle(FlowTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "hand.draw").foregroundStyle(FlowTheme.textSecondary)
                        }
                        .padding(10)
                        .background(FlowTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FlowTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .overlay(PermissionAppDragSource().accessibilityHidden(true))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(appModel.permissionAppName), draggable app")
                        .accessibilityHint("Use Show this app in Finder below if you prefer not to drag.")
                        .accessibilityIdentifier("permission-setup-drag-app")
                        Button("Show this app in Finder") { appModel.showPermissionAppInFinder() }
                            .font(.system(size: 11))
                        Text("If dropping isn’t accepted, use the + button in Settings and select this app instead. Dropping the app does not confirm access; macOS must report it as enabled.")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DisclosureGroup(isExpanded: $showsHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Look for \(appModel.permissionAppName), the build you’re using now. If it isn’t listed, use the + button when available and choose this app:")
                        Text(appModel.permissionAppPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Show this app in Finder") { appModel.showPermissionAppInFinder() }
                        Text("If macOS asks you to quit, quit and reopen this same app. If the switch is already on but access still isn’t detected, reopen the app before changing more settings. Managed Macs may require your administrator’s help.")
                        Button("Open \(permission.title) settings") { appModel.openPermissionSettings(permission) }
                            .disabled(appModel.permissionSetup.phase == .requesting)
                        Button("Check access again") { appModel.checkPermissionSetup() }
                            .disabled(appModel.permissionSetup.phase == .requesting)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                } label: {
                    Text("Already enabled, or can’t find the app?")
                        .font(.system(size: 11, weight: .medium))
                }
            } else {
                Label("All three permissions are ready. You can dictate now.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(FlowTheme.textPrimary)
        .padding(14)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.border, lineWidth: 1))
        .task { await appModel.refreshPermissions(includeScreenRecording: false) }
        .onChange(of: next) { _, _ in showsHelp = false }
    }

    private func instructions(for permission: CorePermission) -> String {
        if appModel.permissionSetup.phase == .waiting {
            return "Finish the macOS prompt or turn on \(appModel.permissionAppName) in \(permission.title) settings, then return here. If access still isn’t detected, open the help below."
        }
        if permission == .microphone, appModel.canPromptForMicrophone {
            return "Choose Allow Microphone, then Allow in the macOS dialog. You stay in control of when recording starts."
        }
        if permission == .inputMonitoring, appModel.canPromptForInputMonitoring {
            return "Choose Allow shortcut access and follow the macOS prompt. If it opens System Settings, turn on \(appModel.permissionAppName)."
        }
        return "Open \(permission.title) settings, turn on \(appModel.permissionAppName), then return here. We’ll confirm access before the next step."
    }

    private func actionTitle(for permission: CorePermission) -> String {
        if appModel.permissionSetup.phase == .requesting { return "Waiting for macOS…" }
        if appModel.permissionSetup.phase == .waiting { return "Check again" }
        if permission == .microphone, appModel.canPromptForMicrophone { return "Allow Microphone" }
        if permission == .inputMonitoring, appModel.canPromptForInputMonitoring { return "Allow shortcut access" }
        return "Open \(permission.title) settings"
    }
}

/// A native file drag preserves the same payload as dragging the app from Finder.
/// It does not inspect, track, or reposition System Settings windows.
private struct PermissionAppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> PermissionAppDragView { PermissionAppDragView() }
    func updateNSView(_ nsView: PermissionAppDragView, context: Context) {}
}

private final class PermissionAppDragView: NSView, NSDraggingSource {
    private var startPoint: NSPoint?

    // Settings is normally frontmost when the user reaches back for the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { startPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { startPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let startPoint,
              hypot(event.locationInWindow.x - startPoint.x, event.locationInWindow.y - startPoint.y) > 4 else { return }
        self.startPoint = nil
        let writer = PermissionAppDragWriter()
        let item = NSDraggingItem(pasteboardWriter: writer)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40),
            contents: NSWorkspace.shared.icon(forFile: writer.url.path)
        )
        beginDraggingSession(with: [item], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
