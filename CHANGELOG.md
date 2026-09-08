# Changelog

## 0.1.0-alpha.3 — 2026-09-08

Milestones 2–5: progression, storm acceptance, guided first session, and verified alpha handoff.

- Add end-to-end bridge/stone/beacon acceptance scenarios, including fresh-session reloads at every project checkpoint and owner-plus-two-helper construction.
- Verify storms with every supported crew size, failure/deadline/retry paths, changing participants, departure cancellation, and ambiguous reward-save recovery.
- Move actual HUD objectives, project cards, event captions, and save messages into the tested Guidance presenter. Preserve read-only and paused-state instructions during storms, display exact resource deficits, and keep loading/recovery visible in Studio.
- Let objective detail text grow inside its scroll panel; desktop/touch rendering still needs Studio verification.
- Emit deterministic cloud-validation evidence only after all game, build, and tooling checks pass. Package it with the milestone handoff guide; reject missing/stale reports, changed place bytes, and tested files that differ from the release commit.
- Verify 71 Luau behavior groups and 65 Python tooling tests, with an explicit empty-discovery guard for all supported Python versions. Studio, live DataStore, device performance, and Roblox experience publication checks remain explicitly pending.

## 0.1.0-alpha.2 — 2026-09-08

Recovery controls and release handoff fixes.

- Keep Visit, invitation responses, and Home available after a snapshot when the player's own profile is loading or unavailable. Building and owner-only controls remain gated by server-granted permissions.
- Label Home as a hub return when the personal island is unavailable; preserve a chosen host when the personal profile finishes loading.
- Recheck shutdown after waiting for a previous player runtime, and cancel delayed load retries when shutdown, departure, or closure occurred during the wait.
- Support retrying an earlier release commit from reviewed `main` history instead of accidentally packaging newer `main` contents.
- Include all setup-guide link targets in the ZIP and test actual repository documentation links.
- Reject unverified root directives and incompatible property types in the place verifier; preserve exact large integer values.
- Verify 50 Luau behavior groups and 45 Python tooling tests. Studio/device checks remain pending.

## 0.1.0-alpha.1 — 2026-09-07

First packaged Driftwood Isles alpha.

- Gather wood and stone, build the campfire, bridge, and beacon, and complete the repeatable storm challenge.
- Invite up to three helpers, visit other islands, revoke permissions, and keep every contribution on the host's island.
- Save island progress with exclusive session ownership, checked revisions, and recovery behavior that avoids overwriting progress after uncertain writes.
- Use a desktop/touch HUD with objectives, project costs, crew controls, and save status.
- Run 41 cloud-executable behavior groups, strict core analysis, formatting, and exact built-place source verification.
- Package versioned place files and a setup ZIP with source commit information and SHA-256 checksums. Publish new versions only after the release workflow passes.

Roblox Studio rendering, physics, actual multiplayer transport, live DataStore behavior, phone controls/performance, and pacing remain unverified. This is a downloadable alpha for further validation, not a published Roblox experience.
