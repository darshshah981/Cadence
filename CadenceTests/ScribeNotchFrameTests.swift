import AppKit
import SwiftUI
import Testing
@testable import Cadence

@MainActor
struct ScribeNotchFrameTests {
    @Test(arguments: [
        "short-ready-light", "long-ready-dark", "failure-light", "reduced-typing-dark",
        "memory-proposal-dark", "screen-capture-floating", "screen-provider-floating",
        "screen-ready-floating", "screen-unavailable-floating",
        "screen-provider-hardware", "screen-ready-hardware",
        "screen-entry-failure-hardware", "screen-entry-ready-floating",
        "screen-choosing-floating", "screen-drafting-hardware"
    ])
    func mainStatesStayInsideTheNotchCanvas(_ fixture: String) async throws {
        let reduced = fixture.hasPrefix("reduced")
        let dark = fixture.hasSuffix("dark")
        let model = ScribeNotchViewModel()
        model.configureDisplay(hasHardwareNotch: fixture.hasSuffix("hardware"))
        model.setReducedMotion(reduced)

        if fixture.hasPrefix("screen-entry-") {
            model.updateScreenDraftAvailability(true)
            if fixture.contains("failure") {
                model.apply(.init(content: .failure(
                    message: "This reply needs visible context from the original app.",
                    literalTranscript: "Reply to this.", recovery: .none
                ), pill: .failed))
            } else {
                model.apply(.init(content: .ready(ScribeResult(
                    requestID: UUID(), text: "The original synthetic draft is ready."
                )), pill: .scribed))
            }
        } else if fixture.hasPrefix("screen-") {
            model.apply(.init(content: .ready(ScribeResult(
                requestID: UUID(), text: "The original synthetic draft remains available."
            )), pill: .scribed))
            if fixture.hasPrefix("screen-capture") {
                model.updateScreenDraftPhase(.awaitingCaptureApproval)
            } else if fixture.hasPrefix("screen-choosing") {
                model.updateScreenDraftPhase(.choosingAndReading)
            } else if fixture.hasPrefix("screen-provider") {
                model.updateScreenDraftPhase(.awaitingProviderApproval(sourcePreview:
                    String(repeating: "The synthetic support thread asks for an update. ", count: 45)
                ))
            } else if fixture.hasPrefix("screen-ready") {
                model.updateScreenDraftPhase(.ready(
                    String(repeating: "Could you please share an update on the synthetic refund? ", count: 25)
                ))
            } else if fixture.hasPrefix("screen-drafting") {
                model.updateScreenDraftPhase(.drafting)
            } else {
                model.updateScreenDraftPhase(.unavailable)
            }
        } else if fixture.hasPrefix("memory-proposal") {
            model.apply(.init(
                content: .persistentMemoryProposal(.init(
                    requestID: UUID(), proposalID: UUID(),
                    fact: "The synthetic project uses SwiftUI."
                )), pill: .scribed
            ))
        } else if fixture.hasPrefix("failure") {
            model.apply(.init(
                content: .failure(
                    message: "The synthetic draft needs attention. Return to the original editor and try again.",
                    literalTranscript: "Synthetic source text", recovery: .returnToTargetApp
                ), pill: .failed
            ))
        } else if reduced {
            model.apply(.init(
                content: .typingTranscript("Write a concise synthetic reply.", isSlow: false),
                pill: .transcribing
            ))
        } else {
            let text = fixture.hasPrefix("long")
                ? String(repeating: "This is a synthetic paragraph for reviewing a longer draft. ", count: 12)
                : "The synthetic reply is ready."
            model.apply(.init(
                content: .ready(ScribeResult(requestID: UUID(), text: text)), pill: .scribed
            ))
        }
        try? await Task.sleep(for: .milliseconds(180))

        let content = ScribeNotchView(model: model)
            // Match the production NSHostingView: the black notch always asks
            // SwiftUI for dark content, even under a light desktop appearance.
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .darkGray))
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        #expect(abs(size.width - ScribeNotchMotion.canvasSize.width) < 1)
        #expect(abs(size.height - ScribeNotchMotion.canvasSize.height) < 1)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard ProcessInfo.processInfo.environment["CADENCE_EXPORT_NOTCH_FRAMES"] == "1" else { return }
        let directory = try #require(ProcessInfo.processInfo.environment["CADENCE_NOTCH_FRAMES_DIRECTORY"])
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try #require(output.path.hasPrefix("/tmp/"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(fixture + ".png"), options: .atomic)
    }
}
