import Foundation

enum ScribeDiagnosticsExportService {
    static func makeExport(
        events: [ScribeDiagnosticEvent],
        generatedAt: Date,
        appVersion: String,
        build: String,
        macOSMajorVersion: Int,
        readiness: ScribeDiagnosticReadiness,
        permissions: ScribeDiagnosticPermissionSnapshot,
        provider: ScribeDiagnosticProvider,
        appAdaptationEnabled: Bool
    ) async throws -> Data {
        let export = ScribeDiagnosticsExport(
            schemaVersion: ScribeDiagnosticsExport.currentSchemaVersion,
            generatedAt: ScribeDiagnosticsService.roundedToMinute(generatedAt),
            appVersion: appVersion,
            build: build,
            macOSMajorVersion: macOSMajorVersion,
            readiness: readiness,
            permissions: permissions,
            provider: provider,
            appAdaptationEnabled: appAdaptationEnabled,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}
