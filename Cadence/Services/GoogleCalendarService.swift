import AppKit
import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

private let googleCalendarLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "GoogleCalendar"
)

struct GoogleCalendarConnectionState: Codable, Equatable, Sendable {
    var isConfigured: Bool
    var isConnected: Bool
    var accountEmail: String?
    var errorMessage: String?

    static let disconnected = GoogleCalendarConnectionState(
        isConfigured: false,
        isConnected: false,
        accountEmail: nil,
        errorMessage: nil
    )
}

struct GoogleCalendarEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var meetingURL: URL?
    var calendarURL: URL?
    var attendeeEmails: [String]
    var calendarTitle: String? = nil

    var isMeetingCandidate: Bool {
        meetingURL != nil || attendeeEmails.count > 1
    }

    func startsWithin(_ interval: TimeInterval, from date: Date = Date()) -> Bool {
        startDate.timeIntervalSince(date) >= 0 && startDate.timeIntervalSince(date) <= interval
    }

    var meetingProvider: GoogleMeetingProvider? {
        meetingURL.flatMap(GoogleMeetingProvider.init(url:))
    }
}

enum GoogleMeetingProvider: String, Equatable, Sendable {
    case googleMeet
    case zoom
    case microsoftTeams
    case other

    init(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        if host == "meet.google.com" {
            self = .googleMeet
        } else if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            self = .zoom
        } else if host == "teams.microsoft.com" || host == "teams.live.com" {
            self = .microsoftTeams
        } else {
            self = .other
        }
    }

    var displayName: String {
        switch self {
        case .googleMeet:
            return "Google Meet"
        case .zoom:
            return "Zoom"
        case .microsoftTeams:
            return "Microsoft Teams"
        case .other:
            return "meeting"
        }
    }

    var assetName: String? {
        switch self {
        case .googleMeet:
            return "GoogleMeet"
        case .zoom:
            return "Zoom"
        case .microsoftTeams:
            return nil
        case .other:
            return nil
        }
    }
}

struct GoogleCalendarOAuthConfiguration: Equatable, Sendable {
    static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let profileScope = "openid email profile"

    var clientID: String
    var clientSecret: String?
    var redirectScheme: String

    init(clientID: String, clientSecret: String? = nil, redirectScheme: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.redirectScheme = redirectScheme ?? Self.defaultRedirectScheme(clientID: clientID)
    }

    var redirectURI: String {
        "\(redirectScheme):/oauth2redirect"
    }

    static func defaultRedirectScheme(clientID: String) -> String {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClientID.hasSuffix(".apps.googleusercontent.com") {
            return "com.googleusercontent.apps." + trimmedClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        }
        return trimmedClientID
    }
}

struct GoogleCalendarOAuthSession: Equatable, Sendable {
    var authURL: URL
    var codeVerifier: String
    var state: String
    var redirectURI: String
}

struct GoogleCalendarTokenSet: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var idToken: String?
    var accountEmail: String?

    var hasUsableAccessToken: Bool {
        expiresAt.timeIntervalSinceNow > 60 && !accessToken.isEmpty
    }
}

protocol GoogleCalendarTokenStoring: Sendable {
    func loadTokenSet() throws -> GoogleCalendarTokenSet?
    func saveTokenSet(_ tokenSet: GoogleCalendarTokenSet) throws
    func deleteTokenSet() throws
}

final class KeychainGoogleCalendarTokenStore: GoogleCalendarTokenStoring, @unchecked Sendable {
    private let service = "com.darshshah.Cadence.google-calendar"
    private let account = "primary"

    func loadTokenSet() throws -> GoogleCalendarTokenSet? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GoogleCalendarError.keychainLoadFailed(status)
        }
        return try JSONDecoder().decode(GoogleCalendarTokenSet.self, from: data)
    }

    func saveTokenSet(_ tokenSet: GoogleCalendarTokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)
        var query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GoogleCalendarError.keychainSaveFailed(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw GoogleCalendarError.keychainSaveFailed(status)
        }
    }

    func deleteTokenSet() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleCalendarError.keychainDeleteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum GoogleCalendarError: LocalizedError, Equatable {
    case missingClientID
    case invalidAuthorizationCallback
    case authorizationStateMismatch
    case authenticationSessionFailed
    case browserOpenFailed
    case loopbackListenerFailed
    case authorizationTimedOut
    case tokenExchangeFailed
    case tokenRequestFailed(String)
    case calendarRequestFailed(String)
    case keychainLoadFailed(OSStatus)
    case keychainSaveFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Google Sign-In is not configured in this build."
        case .invalidAuthorizationCallback:
            return "Google did not return a usable authorization code."
        case .authorizationStateMismatch:
            return "Google sign-in returned an unexpected state."
        case .authenticationSessionFailed:
            return "Cadence could not open Google sign-in."
        case .browserOpenFailed:
            return "Cadence could not open Google sign-in in your browser."
        case .loopbackListenerFailed:
            return "Cadence could not prepare Google sign-in. Please try again."
        case .authorizationTimedOut:
            return "Google sign-in timed out. Please try again."
        case .tokenExchangeFailed:
            return "Cadence could not finish Google sign-in."
        case .tokenRequestFailed(let message):
            return "Google could not finish sign-in: \(message)"
        case .calendarRequestFailed(let message):
            return "Calendar refresh failed: \(message)"
        case .keychainLoadFailed:
            return "Cadence could not read Google Calendar credentials from Keychain."
        case .keychainSaveFailed:
            return "Cadence could not save Google Calendar credentials to Keychain."
        case .keychainDeleteFailed:
            return "Cadence could not remove Google Calendar credentials from Keychain."
        }
    }
}

final class GoogleCalendarService: NSObject, @unchecked Sendable {
    private let tokenStore: GoogleCalendarTokenStoring
    private let urlSession: URLSession

    init(
        tokenStore: GoogleCalendarTokenStoring = KeychainGoogleCalendarTokenStore(),
        urlSession: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.urlSession = urlSession
    }

    func connectionState(configuration: GoogleCalendarOAuthConfiguration?) -> GoogleCalendarConnectionState {
        guard configuration != nil else {
            return .disconnected
        }

        do {
            let tokenSet = try tokenStore.loadTokenSet()
            return GoogleCalendarConnectionState(
                isConfigured: true,
                isConnected: tokenSet?.hasUsableAccessToken == true || tokenSet?.refreshToken != nil,
                accountEmail: tokenSet?.accountEmail ?? tokenSet?.idToken.flatMap(Self.accountEmail(fromIDToken:)),
                errorMessage: nil
            )
        } catch {
            return GoogleCalendarConnectionState(
                isConfigured: true,
                isConnected: false,
                accountEmail: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    func makeAuthorizationSession(
        configuration: GoogleCalendarOAuthConfiguration,
        redirectURI: String? = nil
    ) throws -> GoogleCalendarOAuthSession {
        let resolvedRedirectURI = redirectURI ?? configuration.redirectURI
        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let state = Self.randomURLSafeString(byteCount: 24)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: resolvedRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "\(GoogleCalendarOAuthConfiguration.calendarReadonlyScope) \(GoogleCalendarOAuthConfiguration.profileScope)"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = components?.url else {
            throw GoogleCalendarError.missingClientID
        }
        return GoogleCalendarOAuthSession(
            authURL: authURL,
            codeVerifier: codeVerifier,
            state: state,
            redirectURI: resolvedRedirectURI
        )
    }

    @MainActor
    func signIn(configuration: GoogleCalendarOAuthConfiguration) async throws {
        let redirectReceiver = try GoogleOAuthLoopbackRedirectReceiver.start()
        let oauthSession = try makeAuthorizationSession(
            configuration: configuration,
            redirectURI: redirectReceiver.redirectURI.absoluteString
        )
        googleCalendarLogger.info("Opening Google sign-in redirectURI=\(oauthSession.redirectURI, privacy: .public)")
        guard openAuthorizationURL(oauthSession.authURL) else {
            redirectReceiver.cancel()
            googleCalendarLogger.error("Failed to open Google sign-in URL")
            throw GoogleCalendarError.browserOpenFailed
        }
        let callbackURL: URL
        do {
            callbackURL = try await Self.waitForGoogleCallback(from: redirectReceiver)
        } catch {
            redirectReceiver.cancel()
            throw error
        }
        googleCalendarLogger.info("Received Google sign-in callback")
        let authorizationCode = try Self.authorizationCode(from: callbackURL, expectedState: oauthSession.state)
        let tokenSet = try await exchangeCode(
            authorizationCode,
            codeVerifier: oauthSession.codeVerifier,
            configuration: configuration,
            redirectURI: oauthSession.redirectURI
        )
        try tokenStore.saveTokenSet(tokenSet)
    }

    private static func waitForGoogleCallback(
        from redirectReceiver: GoogleOAuthLoopbackRedirectReceiver,
        timeout: Duration = .seconds(180)
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await redirectReceiver.waitForCallback()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoogleCalendarError.authorizationTimedOut
            }

            guard let callbackURL = try await group.next() else {
                throw GoogleCalendarError.authorizationTimedOut
            }
            group.cancelAll()
            return callbackURL
        }
    }

    @MainActor
    private func openAuthorizationURL(_ url: URL) -> Bool {
        if NSWorkspace.shared.open(url) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            googleCalendarLogger.error("open command failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func signOut() throws {
        try tokenStore.deleteTokenSet()
    }

    func upcomingEvents(
        limit: Int = 10,
        now: Date = Date(),
        timeMax: Date? = nil,
        configuration: GoogleCalendarOAuthConfiguration? = nil
    ) async throws -> [GoogleCalendarEvent] {
        guard var tokenSet = try tokenStore.loadTokenSet() else {
            return []
        }

        if !tokenSet.hasUsableAccessToken,
           let refreshToken = tokenSet.refreshToken,
           let configuration {
            tokenSet = try await refreshAccessToken(refreshToken, currentTokenSet: tokenSet, configuration: configuration)
            try tokenStore.saveTokenSet(tokenSet)
        }

        guard tokenSet.hasUsableAccessToken else { return [] }

        let resolvedTimeMax = timeMax ?? Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        let calendars = try await calendarList(accessToken: tokenSet.accessToken)
        var eventsByID = [String: GoogleCalendarEvent]()

        for calendar in calendars {
            let payload = try await events(
                calendarID: calendar.id,
                limit: limit,
                now: now,
                timeMax: resolvedTimeMax,
                accessToken: tokenSet.accessToken
            )
            for event in payload.items.compactMap({ GoogleCalendarEvent(responseItem: $0, sourceCalendar: calendar) }) {
                eventsByID[event.id] = eventsByID[event.id] ?? event
            }
        }

        return Array(eventsByID.values)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    private func calendarList(accessToken: String) async throws -> [GoogleCalendarListItem] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")
        components?.queryItems = [
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "showHidden", value: "false"),
            URLQueryItem(name: "maxResults", value: "250")
        ]
        guard let url = components?.url else { return [GoogleCalendarListItem.primaryFallback] }
        let payload: GoogleCalendarListResponse = try await googleCalendarGET(url: url, accessToken: accessToken)
        return payload.items.isEmpty ? [GoogleCalendarListItem.primaryFallback] : payload.items
    }

    private func events(
        calendarID: String,
        limit: Int,
        now: Date,
        timeMax: Date,
        accessToken: String
    ) async throws -> GoogleCalendarEventsResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(Self.urlPathSegment(calendarID))/events"
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "\(limit)"),
            URLQueryItem(name: "timeMin", value: Self.rfc3339String(from: now)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339String(from: timeMax))
        ]
        guard let url = components.url else { return GoogleCalendarEventsResponse(items: []) }
        return try await googleCalendarGET(url: url, accessToken: accessToken)
    }

    private func googleCalendarGET<Response: Decodable>(url: URL, accessToken: String) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let message = Self.googleErrorMessage(from: data)
            googleCalendarLogger.error("Google Calendar request failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public) message=\(message, privacy: .public)")
            throw GoogleCalendarError.calendarRequestFailed(message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func exchangeCode(
        _ code: String,
        codeVerifier: String,
        configuration: GoogleCalendarOAuthConfiguration,
        redirectURI: String? = nil
    ) async throws -> GoogleCalendarTokenSet {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI ?? configuration.redirectURI
        ]
        if let clientSecret = configuration.clientSecret {
            body["client_secret"] = clientSecret
        }
        request.httpBody = body
        .map { "\($0.key)=\(Self.formEncoded($0.value))" }
        .joined(separator: "&")
        .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let message = Self.googleErrorMessage(from: data)
            googleCalendarLogger.error("Google token exchange failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public) message=\(message, privacy: .public)")
            throw GoogleCalendarError.tokenRequestFailed(message)
        }
        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return GoogleCalendarTokenSet(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            idToken: tokenResponse.idToken,
            accountEmail: tokenResponse.idToken.flatMap(Self.accountEmail(fromIDToken:))
        )
    }

    private func refreshAccessToken(
        _ refreshToken: String,
        currentTokenSet: GoogleCalendarTokenSet,
        configuration: GoogleCalendarOAuthConfiguration
    ) async throws -> GoogleCalendarTokenSet {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let clientSecret = configuration.clientSecret {
            body["client_secret"] = clientSecret
        }
        request.httpBody = body
        .map { "\($0.key)=\(Self.formEncoded($0.value))" }
        .joined(separator: "&")
        .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let message = Self.googleErrorMessage(from: data)
            googleCalendarLogger.error("Google token refresh failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public) message=\(message, privacy: .public)")
            throw GoogleCalendarError.tokenRequestFailed(message)
        }
        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return GoogleCalendarTokenSet(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? currentTokenSet.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            idToken: tokenResponse.idToken ?? currentTokenSet.idToken,
            accountEmail: tokenResponse.idToken.flatMap(Self.accountEmail(fromIDToken:)) ?? currentTokenSet.accountEmail
        )
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleCalendarError.invalidAuthorizationCallback
        }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GoogleCalendarError.authorizationStateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleCalendarError.invalidAuthorizationCallback
        }
        return code
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func accountEmail(fromIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let email = payload["email"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func urlPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=:")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func rfc3339String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func googleErrorMessage(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data),
           let message = payload.error.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return message
        }
        if let payload = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data) {
            return [payload.error, payload.errorDescription]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
                .joined(separator: ": ")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Unexpected response from Google."
    }
}

final class GoogleOAuthLoopbackRedirectReceiver: @unchecked Sendable {
    private static let callbackPath = "/oauth2redirect"

    let redirectURI: URL

    private let socketFD: Int32
    private let queue = DispatchQueue(label: "com.darshshah.Cadence.google-oauth-loopback")
    private var readSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completedResult: Result<URL, Error>?
    private var didCloseSocket = false

    private init(socketFD: Int32, redirectURI: URL) {
        self.socketFD = socketFD
        self.redirectURI = redirectURI
    }

    static func start() throws -> GoogleOAuthLoopbackRedirectReceiver {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            googleCalendarLogger.error("Google sign-in loopback socket failed errno=\(errno, privacy: .public)")
            throw GoogleCalendarError.loopbackListenerFailed
        }

        var reuseAddress: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            googleCalendarLogger.error("Google sign-in loopback bind failed errno=\(errno, privacy: .public)")
            close(socketFD)
            throw GoogleCalendarError.loopbackListenerFailed
        }

        guard listen(socketFD, 1) == 0 else {
            googleCalendarLogger.error("Google sign-in loopback listen failed errno=\(errno, privacy: .public)")
            close(socketFD)
            throw GoogleCalendarError.loopbackListenerFailed
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &boundAddressLength)
            }
        }
        guard getsocknameResult == 0,
              let redirectURI = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))\(callbackPath)") else {
            googleCalendarLogger.error("Google sign-in loopback port lookup failed errno=\(errno, privacy: .public)")
            close(socketFD)
            throw GoogleCalendarError.loopbackListenerFailed
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        }

        let receiver = GoogleOAuthLoopbackRedirectReceiver(socketFD: socketFD, redirectURI: redirectURI)
        receiver.startAccepting()
        return receiver
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let completedResult = self.completedResult {
                        continuation.resume(with: completedResult)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        queue.async {
            self.complete(.failure(GoogleCalendarError.browserOpenFailed))
        }
    }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            self?.closeSocketIfNeeded()
        }
        readSource = source
        source.resume()
    }

    private func acceptConnection() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else {
            let currentErrno = errno
            if currentErrno != EWOULDBLOCK && currentErrno != EAGAIN {
                googleCalendarLogger.error("Google sign-in loopback accept failed errno=\(currentErrno, privacy: .public)")
                complete(.failure(GoogleCalendarError.loopbackListenerFailed))
            }
            return
        }
        handleClient(socketFD: clientFD)
    }

    private func handleClient(socketFD clientFD: Int32) {
        let flags = fcntl(clientFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
        }

        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
            recv(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        let data = byteCount > 0 ? Data(buffer.prefix(byteCount)) : nil

        guard let callbackURL = callbackURL(from: data) else {
            sendResponse(
                socketFD: clientFD,
                status: "400 Bad Request",
                title: "Cadence could not read the Google sign-in response.",
                body: "You can close this tab and try again from Cadence."
            )
            close(clientFD)
            complete(.failure(GoogleCalendarError.invalidAuthorizationCallback))
            return
        }

        sendResponse(
            socketFD: clientFD,
            status: "200 OK",
            title: "Cadence is connected to Google.",
            body: "You can close this tab and return to Cadence."
        )
        close(clientFD)
        complete(.success(callbackURL))
    }

    private func callbackURL(from data: Data?) -> URL? {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let target = parts[1]
        guard target.hasPrefix(Self.callbackPath) else { return nil }
        return URL(string: "http://127.0.0.1:\(redirectURI.port ?? 0)\(target)")
    }

    private func sendResponse(socketFD clientFD: Int32, status: String, title: String, body: String) {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 40px;">
        <h1>\(title)</h1>
        <p>\(body)</p>
        </body>
        </html>
        """
        let payload = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r
        """
        var response = Data(header.utf8)
        response.append(payload)
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sentByteCount = 0
            while sentByteCount < response.count {
                let result = send(
                    clientFD,
                    baseAddress.advanced(by: sentByteCount),
                    response.count - sentByteCount,
                    0
                )
                guard result > 0 else { break }
                sentByteCount += result
            }
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        guard completedResult == nil else { return }
        completedResult = result
        readSource?.cancel()
        readSource = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func closeSocketIfNeeded() {
        guard !didCloseSocket else {
            return
        }
        didCloseSocket = true
        close(socketFD)
    }
}

private struct GoogleTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
    var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct GoogleAPIErrorEnvelope: Decodable {
    var error: GoogleAPIError
}

private struct GoogleAPIError: Decodable {
    var message: String
}

private struct GoogleCalendarListResponse: Decodable {
    var items: [GoogleCalendarListItem]
}

private struct GoogleCalendarListItem: Decodable {
    var id: String
    var summary: String? = nil

    static let primaryFallback = GoogleCalendarListItem(id: "primary")
}

private struct GoogleCalendarEventsResponse: Decodable {
    var items: [GoogleCalendarEventResponseItem]
}

private struct GoogleCalendarEventResponseItem: Decodable {
    var id: String
    var summary: String?
    var htmlLink: String?
    var hangoutLink: String?
    var location: String?
    var description: String?
    var start: GoogleCalendarEventDate
    var end: GoogleCalendarEventDate
    var attendees: [GoogleCalendarEventAttendee]?
}

private struct GoogleCalendarEventDate: Decodable {
    var dateTime: Date?
    var date: Date?

    enum CodingKeys: String, CodingKey {
        case dateTime
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        dateTime = try container.decodeIfPresent(String.self, forKey: .dateTime)
            .flatMap { formatter.date(from: $0) }
        if let dateString = try container.decodeIfPresent(String.self, forKey: .date) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            date = dateFormatter.date(from: dateString)
        } else {
            date = nil
        }
    }
}

private struct GoogleCalendarEventAttendee: Decodable {
    var email: String?
}

private extension GoogleCalendarEvent {
    init?(responseItem: GoogleCalendarEventResponseItem, sourceCalendar: GoogleCalendarListItem? = nil) {
        guard let startDate = responseItem.start.dateTime,
              let endDate = responseItem.end.dateTime else {
            return nil
        }

        let detectedMeetingURL = [
            responseItem.hangoutLink,
            responseItem.location,
            responseItem.description
        ]
        .compactMap { $0 }
        .compactMap(Self.firstMeetingURL)
        .first

        let calendarTitle = sourceCalendar?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let title = responseItem.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (detectedMeetingURL == nil ? "Calendar event" : "Video meeting")

        self.init(
            id: responseItem.id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            meetingURL: detectedMeetingURL,
            calendarURL: responseItem.htmlLink.flatMap(URL.init(string:)),
            attendeeEmails: responseItem.attendees?.compactMap(\.email) ?? [],
            calendarTitle: calendarTitle
        )
    }

    private static func firstMeetingURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?
            .matches(in: text, range: range)
            .compactMap(\.url)
            .first { url in
                let host = url.host()?.lowercased() ?? ""
                return host.contains("meet.google.com") ||
                    host.contains("zoom.us") ||
                    host.contains("teams.microsoft.com")
            }
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
