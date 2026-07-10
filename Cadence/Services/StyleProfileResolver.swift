import Foundation

enum StyleProfileResolver {
    static func resolve(
        bundleIdentifier: String?,
        profiles: [WritingStyleProfile]
    ) -> WritingStyleProfile? {
        let enabled = profiles.filter { $0.isEnabled }
        if let bundleIdentifier,
           let exact = enabled
            .filter({ $0.appBundleIdentifier == bundleIdentifier })
            .sorted(by: stableOrder)
            .first {
            return exact
        }
        return enabled
            .filter { $0.appBundleIdentifier == nil }
            .sorted(by: stableOrder)
            .first
    }

    private static func stableOrder(_ lhs: WritingStyleProfile, _ rhs: WritingStyleProfile) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}
