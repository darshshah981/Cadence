import SwiftUI
import OSLog

private let scribeSourceControlLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeSourceControl")

/// Progressive disclosure of the source behind the current draft. This view
/// cannot capture, choose a provider, change consent or write a memory record.
struct ScribeSelectedTextSourceControl: View {
    let source: ScribeSelectedTextReviewSource
    let identifier: String
    let canInspect: () -> Bool
    let onExclude: (UUID) -> Void
    let onRecordNewMessage: (UUID) -> Void
    let onRefresh: (UUID) -> Void
    let onPresentationChange: (Bool) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            guard canInspect() else { return }
            onPresentationChange(true)
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(source.status).lineLimit(1)
                Image(systemName: "info.circle")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(FlowTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Inspect the selection used by this draft")
        .accessibilityLabel("Inspect selected-text source")
        .accessibilityValue(source.status)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScribeSelectedTextSourceInspector(source: source, identifier: identifier,
                onDone: { isPresented = false }, onExclude: onExclude,
                onRecordNewMessage: { id in isPresented = false; onRecordNewMessage(id) },
                onRefresh: { id in isPresented = false; onRefresh(id) })
        }
        .onChange(of: isPresented) { onPresentationChange($0) }
        .onChange(of: source.id) { _ in isPresented = false }
        .onDisappear { onPresentationChange(false) }
    }
}


/// Shared content keeps the native popover and offscreen layout fixtures on the
/// same view. Offscreen rendering does not certify WindowServer focus behavior.
struct ScribeSelectedTextSourceInspector: View {
    let source: ScribeSelectedTextReviewSource
    let identifier: String
    let onDone: () -> Void
    let onExclude: (UUID) -> Void
    let onRecordNewMessage: (UUID) -> Void
    let onRefresh: (UUID) -> Void

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Source for this draft").font(.headline)
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                }
                Text(source.isExcluded ? source.exclusionMessage : "This complete selection was processed on this Mac. It is not saved to history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(source.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(identifier + "-source")
                }
                .frame(maxHeight: 180)
                HStack {
                    Text("Complete selection")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if source.isExcluded {
                        Button("Record new message") { onRecordNewMessage(source.id) }
                            .help("Discard this draft and record the complete replacement message. This recording will not read selected text.")
                            .accessibilityHint("Discards this draft. Selected-text capture is off for the new recording.")
                            .accessibilityIdentifier(identifier + "-record-new-message")
                    } else {
                        Button("Exclude from request") { onExclude(source.id) }
                            .accessibilityIdentifier(identifier + "-exclude")
                    }
                }
                if !source.isExcluded {
                    Button("Refresh selection") { onRefresh(source.id) }
                        .help("Discard this draft, read the current selection in the original field, and apply the same spoken edit again.")
                        .accessibilityHint("Discards this draft and creates a new draft from the current selection. Does not record your voice.")
                        .accessibilityIdentifier(identifier + "-refresh")
                }
            }
            .padding(16)
            .frame(width: 340)
    }
}

/// Shows only the frozen fact set that was supplied to the local model for the
/// current draft. It has no save, lookup, or provider side effects.
struct ScribeSessionFactsControl: View {
    let source: ScribeSessionFactsReviewSource
    let identifier: String
    let onRegenerateWithoutFacts: (UUID) -> Void
    let onRegenerateWithoutFact: (UUID, UUID) -> Void
    let onPresentationChange: (Bool) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            onPresentationChange(true)
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(source.status).lineLimit(1)
                Image(systemName: "info.circle")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(FlowTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Inspect the facts used by this draft")
        .accessibilityLabel("Inspect facts used by this draft")
        .accessibilityValue(source.status)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScribeSessionFactsInspector(
                source: source, identifier: identifier,
                onDone: { isPresented = false },
                onRegenerateWithoutFacts: { id in
                    isPresented = false
                    onRegenerateWithoutFacts(id)
                },
                onRegenerateWithoutFact: { sourceID, recordID in
                    isPresented = false
                    onRegenerateWithoutFact(sourceID, recordID)
                }
            )
        }
        .onChange(of: isPresented) { onPresentationChange($0) }
        .onChange(of: source.id) { _ in isPresented = false }
        .onDisappear { onPresentationChange(false) }
    }
}

struct ScribeSessionFactsInspector: View {
    let source: ScribeSessionFactsReviewSource
    let identifier: String
    let onDone: () -> Void
    let onRegenerateWithoutFacts: (UUID) -> Void
    let onRegenerateWithoutFact: (UUID, UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Facts used for this draft").font(.headline)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            Text("These explicitly saved facts from the current TextEdit document were used by the writing model on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if source.facts.count > 3 {
                Text("\(source.facts.count) facts included. Scroll to inspect each one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if source.facts.count == 1,
                      source.facts[0].utf8.count > 500 {
                Text("Scroll to read the full fact.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(source.facts.enumerated()), id: \.offset) { index, fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(identifier + "-fact-\(index)")
                            if source.allowsRegeneration, source.facts.count > 1,
                               source.recordIDs.count == source.facts.count {
                                Button("Regenerate without this fact") {
                                    onRegenerateWithoutFact(source.id, source.recordIDs[index])
                                }
                                .font(.caption)
                                .help("Discard this draft and use the same speech with the other facts.")
                                .accessibilityHint("Discards this draft. Other included facts can still inform the new one.")
                                .accessibilityIdentifier(identifier + "-exclude-fact-\(index)")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            if source.allowsRegeneration {
                Text("This discards the current draft. Saved facts stay in memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Regenerate without facts") {
                    onRegenerateWithoutFacts(source.id)
                }
                .help("Discard this draft and write a new one from the same speech without these facts.")
                .accessibilityHint("Discards this draft. The new draft will not use the facts shown here.")
                .accessibilityIdentifier(identifier + "-regenerate-without-facts")
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
