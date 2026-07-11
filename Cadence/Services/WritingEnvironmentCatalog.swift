import Foundation

struct WritingEnvironmentCatalog: Equatable, Sendable {
    let environments: [WritingEnvironmentDefinition]

    func environment(id: WritingEnvironmentID) -> WritingEnvironmentDefinition? {
        environments.first { $0.id == id }
    }

    static let releaseOne = WritingEnvironmentCatalog(environments: [
        WritingEnvironmentDefinition(
            id: .slack,
            displayName: "Slack",
            definitionVersion: 1,
            defaultBehaviorID: .neutral,
            supportedBehaviorIDs: [.formal, .neutral, .casual],
            behaviorInstructions: [
                .formal: slackBase + "\n" + slackFormal,
                .neutral: slackBase + "\n" + slackNeutral,
                .casual: slackBase + "\n" + slackCasual
            ]
        ),
        WritingEnvironmentDefinition(
            id: .claudeCode,
            displayName: "Claude Code",
            definitionVersion: 1,
            defaultBehaviorID: .precise,
            supportedBehaviorIDs: [.precise],
            behaviorInstructions: [.precise: claudeCodePrecise]
        ),
        WritingEnvironmentDefinition(
            id: .global,
            displayName: "Other apps",
            definitionVersion: 1,
            defaultBehaviorID: .neutral,
            supportedBehaviorIDs: [.neutral],
            behaviorInstructions: [
                .neutral: "Write a clear, concise draft that follows the spoken request without adding unsupported detail."
            ]
        )
    ])

    private static let slackBase = """
    Write a message that can be pasted into a conversational team chat.
    Lead with the point, request, or update; omit a greeting and sign-off unless the spoken request calls for one.
    Keep length proportional; prefer one to four short paragraphs. Use a short bulleted list only when it makes multiple distinct items easier to scan.
    Use plain text by default. Use inline code or a fenced code block only for literal code. Do not use tables or decorative headings.
    Do not add emoji, exclamation marks, slang, urgency, promises, or warmth that the spoken request does not support.
    """

    private static let slackFormal = """
    Use polished, measured wording and complete sentences. Prefer restrained warmth, neutral punctuation, and explicit requests or deadlines. Contractions are allowed when they keep the message natural; do not sound legalistic or ceremonial.
    """

    private static let slackNeutral = """
    Use clear, conversational wording with natural contractions. Be direct without sounding abrupt. Keep warmth moderate and do not add filler.
    """

    private static let slackCasual = """
    Use relaxed, direct wording, natural contractions, and shorter sentences or fragments where clear. Do not force slang, lowercase styling, emoji, or exaggerated enthusiasm.
    """

    private static let claudeCodePrecise = """
    Rewrite the spoken request as one actionable instruction for a coding agent.
    Preserve the user's action boundary: a request to inspect, explain, diagnose, review, plan, implement, test, commit, or publish must not be silently widened into a later stage.
    State the task first. Include provided context, files, code literals, constraints, non-goals, and expected outcome. When several are present, separate them into short paragraphs or bullets.
    For an implementation or fix, include a brief request for focused verification and evidence unless the user explicitly rules it out; do not invent a specific command, file, architecture, or acceptance criterion.
    For a question, explanation, diagnosis, review, or plan, keep the instruction read-only unless the spoken request explicitly authorizes changes.
    Preserve paths, identifiers, flags, commands, error text, and other code literals exactly; format short literals with backticks and use fenced blocks only for multi-line code.
    Remove speech filler and repetition. Do not add politeness padding, a greeting, or a sign-off.
    When essential detail is missing, tell the coding agent to inspect the available repository context and make only the smallest reversible assumption; do not fabricate the missing detail.
    """
}
