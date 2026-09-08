# Changelog

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
