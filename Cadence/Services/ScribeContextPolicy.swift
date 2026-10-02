import Foundation

/// Pure, deny-by-default checks. Production adapters remain disabled until
/// their owners enforce this policy at capture, use, storage, and final egress.
/// Provider availability, existing consent verification, and capability checks
/// remain independently required; an authorization here never replaces them.
enum ScribeContextPolicy {
    static func authorize(
        _ request: ScribeContextPolicyRequest,
        using policy: ScribeContextPolicySnapshot,
        permissions: ScribeContextPlatformPermissions,
        at now: Date
    ) throws -> ScribeContextAccessAuthorization {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ScribeContextPolicyRejection.invalidRequest
        }
        guard policy.isEnabled else { throw ScribeContextPolicyRejection.disabled }
        guard request.action.eligibility == .eligible else {
            throw ScribeContextPolicyRejection.ineligibleSurface
        }
        guard let bundleID = request.action.target.bundleIdentifier, !bundleID.isEmpty else {
            throw ScribeContextPolicyRejection.unknownApplication
        }
        guard !policy.excludedScopes.contains(where: {
            matches($0, action: request.action) || exclusionCouldMatchUnresolvedSurface($0, action: request.action)
        }) else {
            throw ScribeContextPolicyRejection.excludedScope
        }

        var grantIDs: Set<UUID> = []
        switch request.operation {
        case .capture(let category):
            grantIDs.insert(try captureGrant(
                category, action: request.action, policy: policy, permissions: permissions, now: now
            ).id)

        case .retain(let categories, let destination, let until):
            guard !categories.isEmpty, until.timeIntervalSinceReferenceDate.isFinite, until > now else {
                throw ScribeContextPolicyRejection.invalidRequest
            }
            // Persistence needs an identified surface. App-wide consent is a
            // permission scope, never a key under which to combine conversations.
            if destination == .persistentMemory {
                guard let surfaceID = request.action.opaqueSurfaceID, !surfaceID.isEmpty else {
                    throw ScribeContextPolicyRejection.invalidRequest
                }
            }
            for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
                try checkExclusion(category, policy: policy)
                grantIDs.insert(try captureGrant(
                    category.captureCategory, action: request.action, policy: policy,
                    permissions: permissions, now: now
                ).id)
                guard let grant = policy.retentionGrants.first(where: {
                    !policy.revokedGrantIDs.contains($0.id)
                        && matches($0.scope, action: request.action)
                        && $0.categories.contains(category)
                        && $0.destination == destination
                        && isCurrent($0.window, at: now)
                        && $0.maximumRetentionInterval.isFinite
                        && $0.maximumRetentionInterval > 0
                        && until.timeIntervalSince(now) <= $0.maximumRetentionInterval
                        && until <= $0.window.expiresAt
                }) else { throw ScribeContextPolicyRejection.missingRetentionGrant }
                grantIDs.insert(grant.id)
            }

        case .transmit(let categories, let provider):
            guard !categories.isEmpty, !provider.recipientOrigin.isEmpty,
                  provider.providerDisclosureRevision > 0 else {
                throw ScribeContextPolicyRejection.invalidRequest
            }
            for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
                try checkExclusion(category, policy: policy)
                grantIDs.insert(try captureGrant(
                    category.captureCategory, action: request.action, policy: policy,
                    permissions: permissions, now: now
                ).id)
                guard let grant = policy.transmissionGrants.first(where: {
                    !policy.revokedGrantIDs.contains($0.id)
                        && matches($0.scope, action: request.action)
                        && $0.provider == provider
                        && $0.categories.contains(category)
                        && $0.contextDisclosureRevision
                            == ScribeContextTransmissionGrant.currentContextDisclosureRevision
                        && isCurrent($0.window, at: now)
                }) else { throw ScribeContextPolicyRejection.missingTransmissionGrant }
                grantIDs.insert(grant.id)
            }
        }
        return ScribeContextAccessAuthorization(
            request: request, policyRevision: policy.revision, grantIDs: grantIDs
        )
    }

    static func revalidate(
        _ authorization: ScribeContextAccessAuthorization,
        for currentRequest: ScribeContextPolicyRequest,
        using currentPolicy: ScribeContextPolicySnapshot,
        permissions: ScribeContextPlatformPermissions,
        at now: Date
    ) throws {
        guard authorization.request == currentRequest else {
            throw ScribeContextPolicyRejection.actionOrOperationChanged
        }
        guard authorization.policyRevision == currentPolicy.revision else {
            throw ScribeContextPolicyRejection.policyChanged
        }
        // Re-run even if the owner forgot to advance its revision. Revocation,
        // exclusions, expiry, and OS permission loss must still deny new work.
        let current = try authorize(currentRequest, using: currentPolicy, permissions: permissions, at: now)
        guard current.grantIDs == authorization.grantIDs else {
            throw ScribeContextPolicyRejection.policyChanged
        }
    }

    private static func captureGrant(
        _ category: ScribeContextCaptureCategory,
        action: ScribeContextActionBinding,
        policy: ScribeContextPolicySnapshot,
        permissions: ScribeContextPlatformPermissions,
        now: Date
    ) throws -> ScribeContextCaptureGrant {
        // Excluding an image also excludes its derived OCR text, and excluding
        // OCR prevents a capture authorization from bypassing that decision.
        let relatedData = ScribeContextDataCategory.allCases.filter { $0.captureCategory == category }
        guard relatedData.allSatisfy({ !policy.excludedCategories.contains($0) }) else {
            throw ScribeContextPolicyRejection.excludedCategory
        }
        switch category {
        case .selectedText, .surroundingText:
            guard permissions.accessibility else {
                throw ScribeContextPolicyRejection.missingPlatformPermission
            }
        case .screenshot:
            guard permissions.screenRecording else {
                throw ScribeContextPolicyRejection.missingPlatformPermission
            }
        case .sessionMemory, .persistentMemory, .priorDraft:
            break
        }
        guard let grant = policy.captureGrants.first(where: {
            !policy.revokedGrantIDs.contains($0.id)
                && matches($0.scope, action: action)
                && $0.categories.contains(category)
                && isCurrent($0.window, at: now)
        }) else { throw ScribeContextPolicyRejection.missingCaptureGrant }
        return grant
    }

    private static func checkExclusion(
        _ category: ScribeContextDataCategory, policy: ScribeContextPolicySnapshot
    ) throws {
        guard !policy.excludedCategories.contains(category) else {
            throw ScribeContextPolicyRejection.excludedCategory
        }
    }

    private static func matches(
        _ scope: ScribeContextAccessScope, action: ScribeContextActionBinding
    ) -> Bool {
        switch scope {
        case .application(let bundleID):
            return !bundleID.isEmpty && action.target.bundleIdentifier == bundleID
        case .surface(let bundleID, let surfaceID):
            return !bundleID.isEmpty && !surfaceID.isEmpty
                && action.target.bundleIdentifier == bundleID
                && action.opaqueSurfaceID == surfaceID
        }
    }

    private static func exclusionCouldMatchUnresolvedSurface(
        _ scope: ScribeContextAccessScope, action: ScribeContextActionBinding
    ) -> Bool {
        guard case .surface(let bundleID, _) = scope,
              !bundleID.isEmpty, action.target.bundleIdentifier == bundleID else { return false }
        // An app-wide grant cannot bypass a narrower exclusion merely because
        // its adapter failed to identify which conversation is now visible.
        return action.opaqueSurfaceID?.isEmpty != false
    }

    private static func isCurrent(_ window: ScribeContextGrantWindow, at now: Date) -> Bool {
        window.acceptedAt.timeIntervalSinceReferenceDate.isFinite
            && window.expiresAt.timeIntervalSinceReferenceDate.isFinite
            && window.acceptedAt <= now && now < window.expiresAt
    }
}
