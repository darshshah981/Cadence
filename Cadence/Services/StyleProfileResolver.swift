import Foundation

enum StyleProfileResolver {
    static func resolve(
        bundleIdentifier: String?,
        profiles: [WritingStyleProfile]
    ) -> WritingStyleProfile? {
        if let bundleIdentifier,
           let exact = profiles.lazy
            .filter({ $0.isEnabled && $0.appBundleIdentifier == bundleIdentifier })
            .min(by: stableOrder) {
            return exact
        }
        return profiles.lazy
            .filter { $0.isEnabled && $0.appBundleIdentifier == nil }
            .min(by: stableOrder)
    }

    private static func stableOrder(_ lhs: WritingStyleProfile, _ rhs: WritingStyleProfile) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}
