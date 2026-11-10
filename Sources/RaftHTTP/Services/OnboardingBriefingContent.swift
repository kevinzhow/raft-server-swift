import Foundation

/// Exact upstream owner-onboarding briefing text.
///
/// Sources (pinned `v1.21.23-source.1`):
/// - `buildOwnerOpenerV2Messages` (`services/onboardingService.ts:463-487`)
/// - `buildOwnerOpenerV2LedgerInstruction` (`:489-531`)
/// - `deliverOwnerFactsContext` (`:1164-1214`)
///
/// The legacy `buildOnboardingInstruction` path is intentionally NOT emitted
/// here: the pinned deployment's `onboarding_opener_v2` default is ON
/// (migration 0144), so the opener-v2 branch is the default path. A flag that is
/// explicitly off is a documented boundary (`OnboardingBriefingOutcome.openerDisabled`).
enum OnboardingBriefingContent {
    static let openerV2Version = "owner-opener-v2.0"
    static let openerV2Topics = [
        "language_preference",
        "team_mode_artifact",
        "message_like_teammates",
        "workflow_migration_or_create_agent_card",
    ]

    static let signupRoles: [(id: String, label: String)] = [
        ("software_engineer", "Software engineer"),
        ("engineering_leader", "Tech lead"),
        ("founder", "Founder"),
        ("product", "Product manager"),
        ("design", "Designer"),
        ("data_ml", "Data / ML"),
        ("devops_it", "DevOps / IT"),
        ("student", "Student or learner"),
        ("other", "Other"),
    ]

    static let referralSources: [(id: String, label: String)] = [
        ("twitter_x", "Twitter / X"),
        ("linkedin", "LinkedIn"),
        ("friend_colleague", "A friend or colleague"),
        ("search", "Search"),
        ("hn_reddit", "Hacker News / Reddit"),
        ("podcast_blog_newsletter", "Podcast / blog / newsletter"),
        ("other", "Other"),
    ]

    /// Upstream `signupRoleLabel`: unknown ids read as no line.
    static func roleLabel(_ id: String?) -> String? {
        guard let id else { return nil }
        return signupRoles.first { $0.id == id }?.label
    }

    /// Upstream `referralSourceLabel`: unknown ids read as no line.
    static func referralLabel(_ id: String?) -> String? {
        guard let id else { return nil }
        return referralSources.first { $0.id == id }?.label
    }

    /// `buildOwnerOpenerV2Messages`. The `hosted` variant is unreachable in this
    /// port (no hosted provider); it is kept so the content contract is complete.
    static func openerMessages(userName: String, hosted: Bool = false) -> [(topic: String, content: String)] {
        let displayName = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "there" : userName
        return [
            (openerV2Topics[0],
             "Hi \(displayName), I'm Cindy. I help you turn this server into a working agent team. Anything you need here, just ask me. I know Raft inside out."),
            (openerV2Topics[1],
             "Raft is where your agents go into team mode. I dropped a short example in the thread right here — open it."),
            (openerV2Topics[2],
             "Message them like teammates — any channel, anytime, half-formed is fine."),
            (openerV2Topics[3],
             hosted
                ? "Tell me what you're working on and I'll propose a starter team for it."
                : "Would you want me to look at your current agents setup on this computer and propose you a starter team? Or just tell me what you're working on."),
        ]
    }

    /// `buildOwnerOpenerV2LedgerInstruction`. The blank line after the ledger
    /// lines is part of the text; the artifact line is conditional upstream and
    /// is omitted while the Team-Mode artifact is deferred in this port.
    static func ledgerInstruction(
        userName: String,
        locationHint: String,
        messageIds: [String],
        artifactAttachmentId: String? = nil,
        roleLabel: String? = nil,
        referralLabel: String? = nil
    ) -> String {
        var lines = [
            "Owner opener v2 ledger:",
            "opener_v2_sent=true",
            "opener_v2_version=\(openerV2Version)",
            "opener_v2_message_ids=\(messageIds.joined(separator: ","))",
            "opener_v2_topics=\(openerV2Topics.joined(separator: ","))",
        ]
        if let artifactAttachmentId {
            lines.append("team_mode_artifact_attachment_id=\(artifactAttachmentId)")
        }
        lines.append("")
        lines.append("The system has already posted those visible opener messages as you. Do not repeat, rephrase, or send another opener on your first real wake.")
        lines.append("Continue onboarding @\(userName) in \(locationHint) from the owner's reply.")
        if let roleLabel {
            lines.append("They told us their role is: \(roleLabel). Pitch Raft and pick a starting point that fits that.")
        }
        if let referralLabel {
            lines.append("They found Raft via: \(referralLabel).")
        }
        lines.append("If the owner answers with a language preference, continue in that language.")
        lines.append("If the owner wants to migrate existing workflows, start from that workflow instead of giving a product tour.")
        lines.append("If the owner has no clear workflow yet, suggest one simple starter path and help them create an initial agent team.")
        lines.append("Your internal objectives/practices file is `notes/onboarding_objectives.md`. Read it before continuing and keep its per-item statuses current.")
        lines.append("That file is the durable objectives state store: preserve and update each objective's status/updated_at/refusal_note fields rather than relying on chat memory.")
        lines.append("Allowed objective statuses are exactly: todo, done, skipped, later, blocked.")
        lines.append("`skipped` is persistent refusal-memory: if the owner declines setup scan or another ask, mark it skipped and do not re-ask after restart unless the owner explicitly reopens it.")
        lines.append("`later` means the owner asked to postpone; `blocked` means a missing permission/tool/decision. Neither status upgrades a hard no into another ask.")
        lines.append("When stuck, use the embedded seeded practices in `notes/onboarding_objectives.md`; then try `raft manual get recipes/seeded --intent \"Choose a safe Raft workflow\" --reason \"Need the core recipe map now\"`, `raft manual search \"preview before merge\" --scope recipes --intent \"Safely preview a change before merge\" --reason \"Need the recommended preview workflow now\"`, or `raft manual get recipes/technique/preview-env --intent \"Safely preview a change before merge\" --reason \"Need exact preview setup steps now\"` if Manual recipes are available.")
        lines.append("When a new agent or channel is needed, use `raft action prepare` to prepare a quick-commit action card. The human must review and commit it; never auto-create agents/channels and do not pretend a pre-generated card exists.")
        lines.append("The action-card flow is documented in `notes/onboarding_playbook.md` (Starter Plan Output) and `notes/onboarding_knowledge_faq.md` (FAQ 15). Follow that human-commit contract.")
        return lines.joined(separator: "\n")
    }

    /// `deliverOwnerFactsContext`. Recomputed from the retained account on every
    /// wake; nothing is stamped because a dropped context is retried by the next.
    static func ownerFacts(ownerName: String, displayName: String?,
                           roleLabel: String?, referralLabel: String?) -> String {
        var lines = [
            "Onboarding context for this server (re-sent on every start; not a message to reply to):",
            "owner_name=\(ownerName)",
        ]
        if let displayName, !displayName.isEmpty {
            lines.append("owner_display_name=\(displayName)")
        }
        if let roleLabel {
            lines.append("owner_role=\(roleLabel)")
        }
        if let referralLabel {
            lines.append("owner_found_us_via=\(referralLabel)")
        }
        lines.append("")
        lines.append("This is what the owner told us about themselves when they signed up. Use it. If they ask")
        lines.append("what they told you, you know — do not say you were never told.")
        return lines.joined(separator: "\n")
    }
}
