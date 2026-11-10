extension AuthCoreService {
    /// Pinned Node requireAuth -> requireVerified -> requireProfileSetupComplete.
    /// The current row, rather than a token claim or completion timestamp,
    /// determines whether this human can enter the protected route.
    public func admitHuman(
        authorization: String?,
        requirement: HumanAdmissionRequirement = .verifiedProfile
    ) throws -> HumanAdmissionIdentity {
        let userId: String
        do {
            userId = try authenticate(authorization)
        } catch AuthCoreError.missingAuthorization {
            throw HumanAdmissionError.missingAuthorization
        } catch AuthCoreError.invalidToken {
            throw HumanAdmissionError.invalidToken
        }
        guard let account = store.account(userId: userId), account.retiredAt == nil else {
            throw HumanAdmissionError.invalidToken
        }
        if requirement != .profileOnly && !account.emailVerified {
            throw HumanAdmissionError.emailVerificationRequired
        }
        if requirement == .verifiedAccount {
            return HumanAdmissionIdentity(userId: userId)
        }
        // shared/accountNeedsIdentitySetup: a real handle with a NULL stamp is
        // complete; a stamped pending_ handle is still incomplete. Do not trim:
        // the pinned shared rule checks the actual missing/empty/prefix fact.
        let name: String? = account.name
        guard let name, !name.isEmpty, !name.lowercased().hasPrefix("pending_") else {
            throw HumanAdmissionError.profileSetupRequired
        }
        return HumanAdmissionIdentity(userId: userId)
    }
}
