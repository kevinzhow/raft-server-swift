import Testing
@testable import RaftHTTP

/// The shared upstream `validateName` contract (pinned
/// `packages/shared/src/index.ts:4401-4446`), used by register and
/// complete-profile here and by the account username-available precheck.
@Test func accountNamingValidatesHandlesLikeTheSharedUpstreamHelper() {
    // A letter first, then letters / numbers / `_` / `-`; Unicode categories.
    for valid in ["abcde", "final-handle", "over_here", "a1_-x", String(repeating: "a", count: 32)] {
        #expect(AccountNaming.validateName(valid, "Name", minLength: 5) == nil)
        #expect(AccountNaming.validateNameReason(valid, minLength: 5) == nil)
    }
    // The default minimum is one character, and Unicode letters count.
    for valid in ["a", "Über", "日本語", "a1_-"] {
        #expect(AccountNaming.validateName(valid) == nil)
        #expect(AccountNaming.validateNameReason(valid) == nil)
    }

    #expect(AccountNaming.validateName("   ", "Name", minLength: 5) == "Name is required")
    #expect(AccountNaming.validateName("abcd", "Name", minLength: 5) == "Name must be at least 5 characters")
    #expect(AccountNaming.validateName(String(repeating: "a", count: 33), "Name", minLength: 5)
        == "Name must be at most 32 characters")
    #expect(AccountNaming.validateName("1invalid", "Name", minLength: 5)
        == "Name must start with a letter and can only contain letters, numbers, hyphens, and underscores")
    #expect(AccountNaming.validateName("bad name", "Name", minLength: 5)
        == "Name must start with a letter and can only contain letters, numbers, hyphens, and underscores")
    #expect(AccountNaming.validateName("-leading", "Name", minLength: 5)
        == "Name must start with a letter and can only contain letters, numbers, hyphens, and underscores")

    // The label is part of the published sentence, which is how the
    // username-available precheck shares this validator.
    #expect(AccountNaming.validateName("abc", "Username", minLength: 5)
        == "Username must be at least 5 characters")

    // The pinned check counts JavaScript UTF-16 units, not grapheme clusters:
    // 30 letters + one 2-unit emoji is 32 units (pattern), 31 letters + the emoji
    // is 33 units (too long) even though both read as 31/32 characters.
    #expect(AccountNaming.validateNameReason(String(repeating: "a", count: 30) + "🎉", minLength: 5)
        == .pattern)
    #expect(AccountNaming.validateNameReason(String(repeating: "a", count: 31) + "🎉", minLength: 5)
        == .tooLong(maxLength: 32))
}

@Test func accountNamingReservedRefusalIgnoresCaseAndLeadingAt() {
    #expect(AccountNaming.isReservedAgentName("Reminders"))
    #expect(AccountNaming.isReservedAgentName(" @HUMANS "))
    #expect(!AccountNaming.isReservedAgentName("reminder"))
}
