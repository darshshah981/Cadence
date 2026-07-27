import Foundation

enum ScribeProviderDisclosure {
    /// Version 2 removes the retired selection/intent contract. Stored
    /// receipts at an older version deliberately fail closed and require the
    /// person configuring the provider to review this narrower contract.
    static let currentVersion = 2
    static let deepSeekTitle = "Use DeepSeek for Compose"
    static let deepSeekPrivacyPolicyURL = URL(
        string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"
    )!
    static let deepSeekPolicyReviewedOn = "2026-07-10"
    static let openAIPolicyReviewedOn = "2026-07-11"
    static let openRouterPolicyReviewedOn = "2026-07-11"

    static let openAIDirect = """
    Cadence transcribes your voice on this Mac. When you use Compose, Cadence sends only Processed dictation, the compiled preset, optional normalized Custom guidance, and literal metadata directly to OpenAI at https://api.openai.com using one exact model. Literal metadata means the exact protected terms and positions Cadence needs the provider to preserve.

    Cadence does not send app identity, selected text, clipboard contents, window titles, screen content, files, prior turns, ambient context, audio, transcript history, meetings, or your Cadence analytics ID.

    Cadence sets store to false and does not use server-side conversation state. OpenAI's approved API data controls say API data is not used for model training by default, while limited abuse-monitoring data may be retained under OpenAI's policy and account controls. OpenAI controls processing and retention; review its current API data-usage policy before continuing.
    """

    static let openRouter = """
    Cadence transcribes your voice on this Mac. When you use Compose, Cadence sends only Processed dictation, the compiled preset, optional normalized Custom guidance, and literal metadata directly to OpenRouter at https://openrouter.ai using one exact model. Literal metadata means the exact protected terms and positions Cadence needs the provider to preserve.

    Cadence does not send app identity, selected text, clipboard contents, window titles, screen content, files, prior turns, ambient context, audio, transcript history, meetings, or your Cadence analytics ID.

    Every request requires Zero Data Retention routing and sets data collection to deny for request content. OpenRouter may still retain limited router metadata under its policy. OpenRouter and the selected model provider control processing; review their current policies before continuing.
    """

    static let deepSeek = """
    Cadence transcribes your voice on this Mac. When you use Compose, Cadence sends only Processed dictation, the compiled preset, optional normalized Custom guidance, and literal metadata directly to DeepSeek at api.deepseek.com using one exact model. Literal metadata means the exact protected terms and positions Cadence needs the provider to preserve.

    Cadence does not send app identity, selected text, clipboard contents, window titles, screen content, files, prior turns, ambient context, audio, transcript history, meetings, or your Cadence analytics ID.

    DeepSeek—not Cadence—controls how it processes and retains requests. DeepSeek's published policy says it may collect inputs, use personal data to improve or train its technology, retain inputs for as long as an account is active in some circumstances, and process/store personal data in the People's Republic of China. DeepSeek also publishes privacy rights including training opt-out and deletion requests. Removing DeepSeek from Cadence does not delete data already sent.

    Only send content you are allowed to share. Review the DeepSeek Privacy Policy.
    """

    static func advanced(origin: String) -> String {
        """
        Cadence transcribes your voice on this Mac. When you use Compose, Cadence sends only Processed dictation, the compiled preset, optional normalized Custom guidance, and literal metadata directly to \(origin) using one exact model. Literal metadata means the exact protected terms and positions Cadence needs the provider to preserve.

        Cadence does not send app identity, selected text, clipboard contents, window titles, screen content, files, prior turns, ambient context, audio, transcript history, meetings, or your Cadence analytics ID.

        “OpenAI-compatible” describes the request format only. It does not mean OpenAI operates this service or that OpenAI's privacy rules apply. Cadence cannot verify this endpoint's operator, training use, retention, security, or deletion practices. Review the endpoint operator's policy and continue only if you trust it. Removing this provider from Cadence does not delete data already sent.
        """
    }

    static let directDictationSummary = "Cadence sends only Processed dictation, the compiled preset, optional normalized Custom guidance, and literal metadata. It does not send app identity, selected text, clipboard contents, window titles, screen content, files, prior turns, ambient context, audio, transcript history, meetings, or the analytics ID."

    static func removal(provider: String) -> String {
        "This removes the API key and provider settings from this Mac and stops new Compose requests. It does not revoke the key at \(provider), delete data the provider already received, or delete your local transcripts, meetings, or writing profiles."
    }
}
