import Foundation

enum ScribeProviderDisclosure {
    static let currentVersion = 1
    static let deepSeekTitle = "Use DeepSeek for Scribe"
    static let deepSeekPrivacyPolicyURL = URL(
        string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"
    )!
    static let deepSeekPolicyReviewedOn = "2026-07-10"

    static let deepSeek = """
    Cadence transcribes your voice on this Mac. When you use Scribe, Cadence sends the text you dictated, the selected writing environment and its saved instructions, and—only when you choose Respond or Edit—the text you explicitly selected, directly to DeepSeek at api.deepseek.com.

    Cadence does not send audio, window titles, nearby text, general clipboard contents, screen content, transcript history, meetings, or your Cadence analytics ID.

    DeepSeek—not Cadence—controls how it processes and retains requests. DeepSeek's published policy says it may collect inputs, use personal data to improve or train its technology, retain inputs for as long as an account is active in some circumstances, and process/store personal data in the People's Republic of China. DeepSeek also publishes privacy rights including training opt-out and deletion requests. Removing DeepSeek from Cadence does not delete data already sent.

    Only send content you are allowed to share. Review the DeepSeek Privacy Policy.
    """

    static func advanced(origin: String) -> String {
        """
        Cadence transcribes your voice on this Mac. When you use Scribe, Cadence sends the text you dictated, the selected writing environment and its saved instructions, and—only when you choose Respond or Edit—the text you explicitly selected, directly to \(origin).

        Cadence does not send audio, window titles, nearby text, general clipboard contents, screen content, transcript history, meetings, or your Cadence analytics ID.

        “OpenAI-compatible” describes the request format only. It does not mean OpenAI operates this service or that OpenAI's privacy rules apply. Cadence cannot verify this endpoint's operator, training use, retention, security, or deletion practices. Review the endpoint operator's policy and continue only if you trust it. Removing this provider from Cadence does not delete data already sent.
        """
    }

    static func selectedTextRecipient(_ recipient: String) -> String {
        "Selected text will be sent to \(recipient) when you choose Respond or Edit."
    }

    static func removal(provider: String) -> String {
        "This removes the API key and provider settings from this Mac and stops new Scribe requests. It does not revoke the key at \(provider), delete data the provider already received, or delete your local transcripts, meetings, or writing profiles."
    }
}
