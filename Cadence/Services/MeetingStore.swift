import Foundation

enum MeetingStoreError: LocalizedError {
    case missingNote(UUID)

    var errorDescription: String? {
        switch self {
        case .missingNote:
            return "Cadence could not find that meeting note."
        }
    }
}

struct QuarantinedMeetingFile: Equatable, Sendable {
    var originalFileName: String
    var quarantineFileName: String
    var reason: String
}

struct MeetingStoreLoadResult: Equatable, Sendable {
    var notes: [MeetingNote]
    var quarantinedFiles: [QuarantinedMeetingFile]

    static let empty = MeetingStoreLoadResult(notes: [], quarantinedFiles: [])
}

final class MeetingStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directoryURL = try directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func loadNotes() throws -> [MeetingNote] {
        return try loadNotesWithDiagnostics().notes
    }

    func loadNotesWithDiagnostics() throws -> MeetingStoreLoadResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return .empty }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" && !$0.hasDirectoryPath }

        var notes = [MeetingNote]()
        var quarantinedFiles = [QuarantinedMeetingFile]()

        for fileURL in fileURLs {
            do {
                let data = try Data(contentsOf: fileURL)
                var note = try decoder.decode(MeetingNote.self, from: data)
                note = migrated(note)
                if note.schemaVersion != MeetingNote.currentSchemaVersion {
                    note.schemaVersion = MeetingNote.currentSchemaVersion
                }
                notes.append(note)
                try save(note)
            } catch {
                quarantinedFiles.append(try quarantine(fileURL: fileURL, reason: error.localizedDescription))
            }
        }

        let sortedNotes = notes.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        return MeetingStoreLoadResult(notes: sortedNotes, quarantinedFiles: quarantinedFiles)
    }

    func save(_ note: MeetingNote) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var noteToSave = note
        noteToSave.schemaVersion = MeetingNote.currentSchemaVersion
        let data = try encoder.encode(noteToSave)
        try data.write(to: fileURL(for: note.id), options: [.atomic])
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingStoreError.missingNote(id)
        }
        try fileManager.removeItem(at: url)
    }

    func search(_ notes: [MeetingNote], query: String) -> [MeetingNote] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return notes }

        return notes.filter { note in
            let haystack = [
                note.title,
                note.userNotes,
                note.transcriptSegments.map(\.text).joined(separator: " "),
                note.summary?.overview ?? "",
                note.summary?.decisions.joined(separator: " ") ?? "",
                note.summary?.actionItems.map(\.text).joined(separator: " ") ?? ""
            ]
            .joined(separator: " ")
            .lowercased()

            return haystack.contains(normalizedQuery)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString, isDirectory: false).appendingPathExtension("json")
    }

    private func migrated(_ note: MeetingNote) -> MeetingNote {
        var migratedNote = note
        if migratedNote.schemaVersion < 1 {
            migratedNote.schemaVersion = MeetingNote.currentSchemaVersion
        }
        return migratedNote
    }

    private func quarantine(fileURL: URL, reason: String) throws -> QuarantinedMeetingFile {
        let quarantineDirectory = directoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        let originalFileName = fileURL.lastPathComponent
        let quarantineFileName = "\(fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json"
        let quarantineURL = quarantineDirectory.appendingPathComponent(quarantineFileName, isDirectory: false)
        try fileManager.moveItem(at: fileURL, to: quarantineURL)

        return QuarantinedMeetingFile(
            originalFileName: originalFileName,
            quarantineFileName: quarantineFileName,
            reason: reason
        )
    }

    private static func defaultDirectoryURL(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupport
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("MeetingNotes", isDirectory: true)
    }
}
