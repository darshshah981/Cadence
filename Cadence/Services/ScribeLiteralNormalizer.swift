import Foundation

enum ScribeLiteralNormalizer {
    private enum CasingMode {
        case camel
        case pascal
        case snake
        case kebab
        case lower
        case upper
        case flag
    }

    private struct WordUnit {
        var value: String
        var preservesCase: Bool
    }

    private enum LiteralComponent {
        case word(WordUnit)
        case symbol(String)
    }

    private struct Candidate {
        let range: NSRange
        let value: String
        let source: ScribeLiteralSource
    }

    static func normalize(
        _ spoken: String,
        environmentID: WritingEnvironmentID
    ) -> NormalizedScribeTranscript {
        guard let explicit = normalizeExplicitSpans(spoken) else {
            return NormalizedScribeTranscript(
                text: spoken,
                exactLiterals: [],
                parseStatus: .needsLocalRepair
            )
        }

        guard environmentID == .claudeCode else {
            return explicit
        }
        let automatic = normalizeAutomaticPatterns(
            explicit.text,
            protectedValues: explicit.exactLiterals.map(\.value)
        )
        let literals = explicit.exactLiterals + automatic.literals.enumerated().map { offset, candidate in
            ScribeExactLiteral(
                id: explicit.exactLiterals.count + offset + 1,
                value: candidate.value,
                source: candidate.source,
                sourceRange: ScribeSourceRange(
                    utf16Location: candidate.range.location,
                    utf16Length: candidate.range.length
                )
            )
        }

        return NormalizedScribeTranscript(
            text: automatic.text,
            exactLiterals: literals,
            parseStatus: .clean
        )
    }

    private static func normalizeExplicitSpans(_ spoken: String) -> NormalizedScribeTranscript? {
        guard (spoken as NSString).range(
            of: "literal",
            options: .caseInsensitive
        ).location != NSNotFound else {
            return NormalizedScribeTranscript(
                text: spoken,
                exactLiterals: [],
                parseStatus: .clean
            )
        }
        var cursor = spoken.startIndex
        var output = ""
        var values: [(value: String, range: ScribeSourceRange)] = []

        while let openingRange = spoken[cursor...].range(
            of: "\\bliteral\\b",
            options: [.regularExpression, .caseInsensitive]
        ) {
            output += spoken[cursor..<openingRange.lowerBound]
            let contentStart = openingRange.upperBound
            guard let closingRange = spoken[contentStart...].range(
                of: "\\bend\\s+literal\\b",
                options: [.regularExpression, .caseInsensitive]
            ) else {
                return nil
            }

            let body = String(spoken[contentStart..<closingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty,
                  body.range(
                    of: "\\bliteral\\b",
                    options: [.regularExpression, .caseInsensitive]
                  ) == nil,
                  let value = parseExplicitBody(body) else {
                return nil
            }

            output += value
            let nsRange = NSRange(openingRange.lowerBound..<closingRange.upperBound, in: spoken)
            values.append((
                value,
                ScribeSourceRange(
                    utf16Location: nsRange.location,
                    utf16Length: nsRange.length
                )
            ))
            cursor = closingRange.upperBound
        }
        output += spoken[cursor...]

        if output.range(
            of: "\\bend\\s+literal\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return nil
        }

        return NormalizedScribeTranscript(
            text: output,
            exactLiterals: values.enumerated().map { index, item in
                ScribeExactLiteral(
                    id: index + 1,
                    value: item.value,
                    source: .explicitGrammar,
                    sourceRange: item.range
                )
            },
            parseStatus: .clean
        )
    }

    private static func parseExplicitBody(_ body: String) -> String? {
        let originalTokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = originalTokens.map { $0.lowercased() }
        guard !tokens.isEmpty else { return nil }

        if tokens[0] == "quoted" || tokens[0] == "verbatim" {
            guard originalTokens.count > 1 else { return nil }
            return originalTokens.dropFirst().joined(separator: " ")
        }

        let mode: CasingMode
        let bodyStart: Int
        if tokens.count >= 2, tokens[1] == "case" {
            switch tokens[0] {
            case "camel": mode = .camel
            case "pascal": mode = .pascal
            case "snake": mode = .snake
            case "kebab": mode = .kebab
            case "lower": mode = .lower
            case "upper": mode = .upper
            default: return nil
            }
            bodyStart = 2
        } else if tokens[0] == "flag" {
            mode = .flag
            bodyStart = 1
        } else {
            return nil
        }
        guard bodyStart < tokens.count else { return nil }

        guard let components = parseComponents(
            originalTokens: originalTokens,
            normalizedTokens: tokens,
            start: bodyStart
        ) else {
            return nil
        }
        return render(components: components, mode: mode)
    }

    private static func parseComponents(
        originalTokens: [String],
        normalizedTokens: [String],
        start: Int
    ) -> [LiteralComponent]? {
        var components: [LiteralComponent] = []
        var index = start
        var delimiterStack: [String] = []

        while index < normalizedTokens.count {
            let token = normalizedTokens[index]
            if token == "capital" || token == "lower" {
                guard index + 1 < normalizedTokens.count else { return nil }
                let value = originalTokens[index + 1]
                guard value.count == 1, value.unicodeScalars.allSatisfy(\.properties.isAlphabetic) else {
                    return nil
                }
                components.append(.word(WordUnit(
                    value: token == "capital" ? value.uppercased() : value.lowercased(),
                    preservesCase: true
                )))
                index += 2
                continue
            }

            if token == "double", index + 1 < normalizedTokens.count,
               normalizedTokens[index + 1] == "dash" {
                components.append(.symbol("--"))
                index += 2
                continue
            }

            if let paired = pairedSymbol(
                token: token,
                next: index + 1 < normalizedTokens.count ? normalizedTokens[index + 1] : nil
            ) {
                if paired.consumesNext { index += 1 }
                if let opening = paired.opening {
                    delimiterStack.append(opening)
                } else if let closing = paired.closing {
                    guard delimiterStack.popLast() == closing else { return nil }
                }
                components.append(.symbol(paired.value))
                index += 1
                continue
            }

            if let symbol = symbols[token] {
                components.append(.symbol(symbol))
                index += 1
                continue
            }

            let value = spokenDigits[token] ?? originalTokens[index]
            guard value.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
                return nil
            }
            components.append(.word(WordUnit(value: value, preservesCase: false)))
            index += 1
        }

        guard delimiterStack.isEmpty,
              components.contains(where: {
                  if case .word = $0 { return true }
                  return false
              }) else {
            return nil
        }
        let merged = mergeSpelledLetters(components)
        let requiresOperands: Set<String> = [".", "/", "\\", "_", "-", "--", ":", "="]
        if let first = merged.first, case let .symbol(value) = first, requiresOperands.contains(value) {
            return nil
        }
        if let last = merged.last, case let .symbol(value) = last, requiresOperands.contains(value) {
            return nil
        }
        return merged
    }

    private static func mergeSpelledLetters(_ components: [LiteralComponent]) -> [LiteralComponent] {
        var merged: [LiteralComponent] = []
        for component in components {
            if case let .word(current) = component,
               current.preservesCase,
               current.value.count == 1,
               case let .word(previous)? = merged.last,
               previous.preservesCase,
               previous.value.count >= 1 {
                merged[merged.count - 1] = .word(WordUnit(
                    value: previous.value + current.value,
                    preservesCase: true
                ))
            } else {
                merged.append(component)
            }
        }
        return merged
    }

    private static func render(components: [LiteralComponent], mode: CasingMode) -> String? {
        if mode == .flag {
            guard components.allSatisfy({
                if case .word = $0 { return true }
                return false
            }) else {
                return nil
            }
            let words = components.compactMap { component -> WordUnit? in
                guard case let .word(word) = component else { return nil }
                return word
            }
            return "--" + words.map { $0.value.lowercased() }.joined(separator: "-")
        }

        var result = ""
        var words: [WordUnit] = []
        var segmentIndex = 0

        func flush() {
            guard !words.isEmpty else { return }
            result += renderWords(words, mode: mode, afterSymbol: segmentIndex > 0)
            words.removeAll(keepingCapacity: true)
        }

        for component in components {
            switch component {
            case let .word(word):
                words.append(word)
            case let .symbol(symbol):
                flush()
                result += symbol
                segmentIndex += 1
            }
        }
        flush()
        return result.isEmpty ? nil : result
    }

    private static func renderWords(
        _ words: [WordUnit],
        mode: CasingMode,
        afterSymbol: Bool
    ) -> String {
        switch mode {
        case .snake:
            return words.map { $0.value.lowercased() }.joined(separator: "_")
        case .kebab:
            return words.map { $0.value.lowercased() }.joined(separator: "-")
        case .lower:
            return words.map { $0.value.lowercased() }.joined()
        case .upper:
            return words.map { $0.value.uppercased() }.joined()
        case .camel, .pascal:
            return words.enumerated().map { index, word in
                if word.preservesCase { return word.value }
                if afterSymbol {
                    return index == 0 ? word.value.lowercased() : capitalizedIdentifierWord(word.value)
                }
                if mode == .camel, index == 0 {
                    return word.value.lowercased()
                }
                return capitalizedIdentifierWord(word.value)
            }.joined()
        case .flag:
            return ""
        }
    }

    private static func capitalizedIdentifierWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    private static func normalizeAutomaticPatterns(
        _ text: String,
        protectedValues: [String]
    ) -> (text: String, literals: [Candidate]) {
        let source = text as NSString
        guard source.range(of: ".").location != NSNotFound
                || source.range(of: "--").location != NSNotFound
                || automaticSpokenSignals.contains(where: {
                    source.range(of: $0, options: .caseInsensitive).location != NSNotFound
                }) else {
            return (text, [])
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [Candidate] = []
        let protectedRanges = protectedValues.flatMap { value -> [NSRange] in
            guard !value.isEmpty,
                  let expression = try? NSRegularExpression(
                    pattern: NSRegularExpression.escapedPattern(for: value)
                  ) else {
                return []
            }
            return expression.matches(in: text, range: fullRange).map(\.range)
        }

        for match in automaticFlagPattern.matches(in: text, range: fullRange) {
            let token = source.substring(with: match.range(at: 1)).lowercased()
            candidates.append(Candidate(
                range: match.range,
                value: "--\(token)",
                source: .safeAutomaticPattern
            ))
        }

        for match in automaticPathPattern.matches(in: text, range: fullRange) {
            let spokenPath = source.substring(with: match.range)
            let tokens = spokenPath.split(whereSeparator: \.isWhitespace).map(String.init)
            let structuralWords: Set<String> = [
                "slash", "underscore", "dash", "colon", "equals", "dot"
            ]
            guard tokens.count >= 3,
                  tokens.count.isMultiple(of: 2) == false,
                  tokens.enumerated().allSatisfy({ index, token in
                      let normalized = token.lowercased()
                      return index.isMultiple(of: 2)
                          ? !structuralWords.contains(normalized)
                          : structuralWords.contains(normalized)
                  }) else {
                continue
            }
            let value = tokens.map { token in
                switch token.lowercased() {
                case "slash": return "/"
                case "underscore": return "_"
                case "dash": return "-"
                case "colon": return ":"
                case "equals": return "="
                case "dot": return "."
                default: return token
                }
            }.joined()
            candidates.append(Candidate(
                range: match.range,
                value: value,
                source: .safeAutomaticPattern
            ))
        }

        for match in automaticFilePattern.matches(in: text, range: fullRange) {
            let stem = source.substring(with: match.range(at: 1))
            let ext = source.substring(with: match.range(at: 2)).lowercased()
            candidates.append(Candidate(
                range: match.range,
                value: "\(stem).\(ext)",
                source: .safeAutomaticPattern
            ))
        }

        for match in alreadyExactPattern.matches(in: text, range: fullRange) {
            candidates.append(Candidate(
                range: match.range,
                value: source.substring(with: match.range),
                source: .alreadyExact
            ))
        }

        candidates.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location { return lhs.range.length > rhs.range.length }
            return lhs.range.location < rhs.range.location
        }
        var accepted: [Candidate] = []
        for candidate in candidates {
            guard protectedRanges.allSatisfy({
                NSIntersectionRange($0, candidate.range).length == 0
            }) else {
                continue
            }
            guard accepted.allSatisfy({ NSIntersectionRange($0.range, candidate.range).length == 0 }) else {
                continue
            }
            accepted.append(candidate)
        }

        let mutable = NSMutableString(string: text)
        for candidate in accepted.reversed() {
            mutable.replaceCharacters(in: candidate.range, with: candidate.value)
        }
        return (mutable as String, accepted)
    }

    private static let knownExtensions: Set<String> = [
        "c", "cpp", "css", "go", "h", "hpp", "html", "js", "json", "jsx", "md",
        "pbxproj", "plist", "py", "rb", "rs", "sh", "swift", "toml", "ts", "tsx",
        "txt", "xcconfig", "xcodeproj", "xml", "yaml", "yml", "zsh"
    ]

    private static let automaticSpokenSignals = [
        "dash", "double", "slash", "underscore", "colon", "equals", "dot"
    ]

    private static let extensionAlternation = knownExtensions.sorted().joined(separator: "|")
    private static let automaticFlagPattern = try! NSRegularExpression(
        pattern: "\\b(?:dash\\s+dash|double\\s+dash)\\s+([A-Za-z0-9][A-Za-z0-9-]*)\\b",
        options: .caseInsensitive
    )
    private static let automaticPathPattern = try! NSRegularExpression(
        pattern: "\\b[A-Za-z0-9]+(?:\\s+(?:slash|underscore|dash|colon|equals)\\s+[A-Za-z0-9]+)+(?:\\s+dot\\s+(?:\(extensionAlternation)))?\\b",
        options: .caseInsensitive
    )
    private static let automaticFilePattern = try! NSRegularExpression(
        pattern: "\\b([A-Za-z0-9][A-Za-z0-9_-]*)\\s+dot\\s+(\(extensionAlternation))\\b",
        options: .caseInsensitive
    )
    private static let alreadyExactPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])(?:--[A-Za-z0-9-]+|[A-Za-z0-9][A-Za-z0-9_/-]*(?:\\.[A-Za-z0-9_/-]+)+)(?![A-Za-z0-9_])"
    )

    private static let spokenDigits: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"
    ]

    private static let symbols: [String: String] = [
        "dot": ".", "slash": "/", "backslash": "\\", "underscore": "_", "dash": "-",
        "colon": ":", "semicolon": ";", "comma": ",", "equals": "=", "at": "@", "hash": "#"
    ]

    private static func pairedSymbol(
        token: String,
        next: String?
    ) -> (value: String, opening: String?, closing: String?, consumesNext: Bool)? {
        let compound: [String: (String, String?, String?)] = [
            "open parenthesis": ("(", "(", nil),
            "close parenthesis": (")", nil, "("),
            "open bracket": ("[", "[", nil),
            "close bracket": ("]", nil, "["),
            "open brace": ("{", "{", nil),
            "close brace": ("}", nil, "{")
        ]
        if let next, let match = compound["\(token) \(next)"] {
            return (match.0, match.1, match.2, true)
        }
        return nil
    }
}
