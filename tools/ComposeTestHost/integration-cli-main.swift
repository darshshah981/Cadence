import ApplicationServices
import CoreGraphics
import Foundation

/// Runs the same 18 production-service cases as the XCTest suite from an
/// unbundled development process. The actual process performs the preflight;
/// trust inherited by xcodebuild or an installed Cadence app is irrelevant.
@main
struct ComposeInsertionCLIRunner {
    static func main() async {
        guard let reportPath = ProcessInfo.processInfo.environment["CADENCE_COMPOSE_INSERTION_REPORT"],
              reportPath.hasPrefix("/") else {
            fputs("Missing absolute integration report path\n", stderr)
            exit(2)
        }
        guard AXIsProcessTrusted() else {
            writeBlockedReport(path: reportPath, status: "blocked_permission")
            exit(3)
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Int == 1,
              session["kCGSessionLoginDoneKey"] as? Int == 1,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            writeBlockedReport(path: reportPath, status: "blocked_desktop")
            exit(4)
        }

        await ComposeInsertionIntegrationTests().productionInsertionAgainstControlledSyntheticHost()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["status"] as? String == "passed",
              report["accessibilityTrustedInActualTestProcess"] as? Bool == true,
              report["expectedCaseCount"] as? Int == 18,
              report["completedCaseCount"] as? Int == 18,
              report["passedCaseCount"] as? Int == 18,
              report["failedCaseCount"] as? Int == 0 else {
            exit(1)
        }
    }

    private static func writeBlockedReport(path: String, status: String) {
        let report: [String: Any] = [
            "schemaVersion": 1, "syntheticOnly": true, "status": status,
            "accessibilityTrustedInActualTestProcess": AXIsProcessTrusted(),
            "testProcessID": ProcessInfo.processInfo.processIdentifier,
            "testExecutablePath": Bundle.main.executableURL?.path ?? "unavailable",
            "expectedCaseCount": 18, "completedCaseCount": 0,
            "passedCaseCount": 0, "failedCaseCount": 0
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
