import SwiftUI

struct IdleExpandedTray: View {
    @ObservedObject var model: HUDViewModel

    var body: some View {
        HStack(spacing: 6) {
            copyButton
            dictionaryButton
            DividerView()
            visibilityMenu
            DividerView()
            contractButton
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(trayBackground)
        .overlay(trayStroke)
    }

    private var copyButton: some View {
        Button(action: { model.onCopyLast?() }) {
            Group {
                if model.showCopyConfirmation {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.success)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(HUDControlButtonStyle())
        .disabled(!model.canCopyLast)
        .opacity(model.canCopyLast ? 1.0 : 0.4)
        .accessibilityLabel("Copy last transcription")
        .accessibilityHint(model.canCopyLast ? "Copies the most recent transcript to clipboard" : "No transcripts available")
    }

    @ViewBuilder
    private var dictionaryButton: some View {
        Button(action: { model.onAddToDictionary?() }) {
            dictionaryButtonContent
        }
        .buttonStyle(HUDControlButtonStyle())
        .disabled(model.dictionaryFeedback == .capturing)
        .accessibilityLabel("Add selected text to dictionary")
        .accessibilityHint("Captures the selected text in the frontmost app and adds it to vocabulary")
    }

    @ViewBuilder
    private var dictionaryButtonContent: some View {
        switch model.dictionaryFeedback {
        case .idle:
            Image(systemName: "text.book.closed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 28, height: 28)
        case .capturing:
            HUDSpinnerView()
                .frame(width: 28, height: 28)
        case .added:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.success)
                .frame(width: 28, height: 28)
        case .nothingSelected:
            Image(systemName: "text.book.closed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textTertiary)
                .frame(width: 28, height: 28)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.error)
                .frame(width: 28, height: 28)
        }
    }

    private var visibilityMenu: some View {
        Menu {
            ForEach(HUDHideDuration.allCases, id: \.self) { duration in
                Button(duration.displayName) {
                    model.onHide?(duration)
                }
            }
        } label: {
            Image(systemName: "eye.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Visibility options")
        .accessibilityHint("Hide the Cadence bar temporarily")
    }

    private var contractButton: some View {
        Button(action: { model.setExpanded(false) }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(HUDControlButtonStyle())
        .accessibilityLabel("Collapse")
        .accessibilityHint("Collapse the action tray back to the logo")
    }

    private var trayBackground: some View {
        let radii = model.position.cornerRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
        .fill(FlowTheme.elevated)
    }

    private var trayStroke: some View {
        let radii = model.position.cornerRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
        .stroke(FlowTheme.border, lineWidth: 1)
    }
}

private struct DividerView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(FlowTheme.border)
            .frame(width: 1, height: 20)
    }
}
