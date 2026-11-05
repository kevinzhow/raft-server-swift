# Remaining parity gaps (2026-11-05)

route locked: 214/219 modules, 1829/2000 cases (91.5%, portable 82.5%).
overall: 401/406 modules (98.8%), 4461/4632 cases (96.3%).

| module | cases | state / blocker | next |
| --- | --- | --- | --- |
| `channels.api` | 37 | message-display/unread/read-all/visibility covered; missing Activity All/Done/Restore facet matrix (6), unfollow-blocks-ordinary-replies (1), resume-all skipped count (1); query spies / push kill-switch / socket frames excluded | implement unified activity facets + resume-all; lock with 5 query-spy + 2 push + 2 socket exclusions |
| `agents.api` | 87 | identity/create/runtime/lifecycle/migrations largely covered; missing ≈20 groups: preset catalog scope matrix (6), skills/workspace-files/activity-log (9), onboarding Cindy (3), DM-task (4), RFC071 breaker (1), v2 field-pointing (2) | 2–3 slices; each group is HTTP-reachable |
| `internalAgentKnowledge.api` | 24 | `/internal/agent-api/knowledge/*` route family absent; only payload projection exists | implement knowledge corpus/aliases/search/telemetry from `manual/agent-knowledge` |
| `internalComputer.agentMigration` | 22 | control/chunks/cancel/admission covered; ≈11 typed transport-lost/idempotency/legacy groups missing | in progress by teammate `r1-auth` |
| `socketMembershipRevocation.api` | 4 | needs guest join/resume visibility, task events, membership-revocation room cleanup, sync:resume | realtime hub work; not a route module |

## Exclusion candidates (contract-valid)

- `channels.api`: five query-count/query-shape spies, push kill-switch / missing-io-mount, self join/leave socket frames.
- `agents.api`: trace acceptance / runtime trace rows; failpoint/orchestrator injection cases.
- `internalAgentKnowledge.api`: none — route family is executable HTTP, not injectable.
- `agentMigration`: DB/outbox-internal assertions only if they cannot be reached black-box.
- `socketMembershipRevocation`: none — all four are real socket frames.
