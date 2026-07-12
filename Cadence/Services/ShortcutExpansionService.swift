import Foundation

enum ShortcutExpansionService {
    private struct Candidate {
        let range: NSRange
        let shortcut: PersonalShortcut
        let scopePriority: Int
    }

    static func expand(
        _ text: String,
        bundleIdentifier: String?,
        shortcuts: [PersonalShortcut],
        protectedValues: [String] = []
    ) -> String {
        let protectedRanges = protectedValues.flatMap { value -> [NSRange] in
            guard !value.isEmpty else { return [] }
            let pattern = NSRegularExpression.escapedPattern(for: value)
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            return expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ).map(\.range)
        }
        let candidates = shortcuts
            .filter { shortcut in
                guard shortcut.isEnabled, shortcut.isValid else { return false }
                switch shortcut.scope {
                case .global:
                    return true
                case let .application(requiredBundleIdentifier):
                    return requiredBundleIdentifier == bundleIdentifier
                }
            }
            .flatMap { shortcut -> [Candidate] in
                let trigger = shortcut.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                let pattern = "(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: trigger))(?![\\p{L}\\p{N}_])"
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return []
                }
                let scopePriority: Int
                switch shortcut.scope {
                case .global:
                    scopePriority = 0
                case .application:
                    scopePriority = 1
                }
                return expression.matches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                ).filter { match in
                    protectedRanges.allSatisfy {
                        NSIntersectionRange($0, match.range).length == 0
                    }
                }.map {
                    Candidate(range: $0.range, shortcut: shortcut, scopePriority: scopePriority)
                }
            }
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                if lhs.range.length != rhs.range.length {
                    return lhs.range.length > rhs.range.length
                }
                if lhs.scopePriority != rhs.scopePriority {
                    return lhs.scopePriority > rhs.scopePriority
                }
                return lhs.shortcut.id.uuidString < rhs.shortcut.id.uuidString
            }

        var selected: [Candidate] = []
        var coveredUntil = 0
        for candidate in candidates {
            guard candidate.range.location >= coveredUntil else { continue }
            selected.append(candidate)
            coveredUntil = NSMaxRange(candidate.range)
        }

        var result = text
        for candidate in selected.reversed() {
            guard let range = Range(candidate.range, in: result) else { continue }
            result.replaceSubrange(range, with: candidate.shortcut.template)
        }
        return result
    }
}
