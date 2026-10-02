import AppKit
import SwiftUI
import Testing
@testable import Cadence

@MainActor
struct ScribeSourceInspectorLayoutTests {
    @Test(arguments: [
        "fact-short-light", "fact-short-dark", "fact-six-light", "fact-six-dark",
        "fact-long-light", "fact-long-dark", "fact-accessibility-light", "fact-accessibility-dark"
    ])
    func sessionFactsInspectorFitsShortLongAndAccessibleContent(_ fixture: String) throws {
        let long = fixture.hasPrefix("fact-long")
        let many = fixture.hasPrefix("fact-six")
        let accessible = fixture.hasPrefix("fact-accessibility")
        let dark = fixture.hasSuffix("dark")
        let facts: [String]
        if long {
            facts = [String(repeating: "The synthetic refund remains delayed; ask for an update. ", count: 45)]
        } else if many {
            facts = (1...6).map { "Synthetic issue \($0) is waiting for an update." }
        } else {
            facts = ["The synthetic refund is delayed."]
        }
        let source = ScribeSessionFactsReviewSource(
            id: UUID(), facts: facts, recordIDs: facts.map { _ in UUID() }
        )
        let content = ScribeSessionFactsInspector(
            source: source, identifier: "fixture-facts", onDone: {},
            onRegenerateWithoutFacts: { _ in },
            onRegenerateWithoutFact: { _, _ in }
        )
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, accessible ? .accessibility2 : .large)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        #expect(abs(size.width - 340) < 1)
        #expect(size.height >= 100 && size.height <= 450)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard ProcessInfo.processInfo.environment["CADENCE_EXPORT_SESSION_FACTS_INSPECTOR"] == "1" else { return }
        let directory = try #require(ProcessInfo.processInfo.environment["CADENCE_SESSION_FACTS_INSPECTOR_DIRECTORY"])
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try #require(output.path.hasPrefix("/tmp/"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(fixture + ".png"), options: .atomic)
    }

    @Test(arguments: ["short-light", "short-dark", "long-light", "long-dark", "excluded-light", "excluded-dark"])
    func sourceInspectorHasBoundedNativeLayout(_ fixture: String) throws {
        let isLong = fixture.hasPrefix("long")
        let text = isLong
            ? String(repeating: "Review the synthetic draft and retain the quoted phrase “cafe\u{301}”.\n", count: 30)
            : "Maya, the preview is ready for review."
        let source = ScribeSelectedTextReviewSource(
            id: UUID(), text: text, includedUTF8Bytes: text.utf8.count, isExcluded: fixture.hasPrefix("excluded")
        )
        let dark = fixture.hasSuffix("dark")
        let content = ScribeSelectedTextSourceInspector(source: source, identifier: "fixture-source", onDone: {}, onExclude: { _ in }, onRecordNewMessage: { _ in }, onRefresh: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        #expect(abs(size.width - 340) < 1)
        #expect(size.height >= 100 && size.height <= 450)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard ProcessInfo.processInfo.environment["CADENCE_EXPORT_SOURCE_INSPECTOR"] == "1" else { return }
        let directory = try #require(ProcessInfo.processInfo.environment["CADENCE_SOURCE_INSPECTOR_DIRECTORY"])
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try #require(output.path.hasPrefix("/tmp/"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(fixture + ".png"), options: .atomic)
    }
}
