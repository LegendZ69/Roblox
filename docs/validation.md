# Implementation validation

Date: 7 September 2026. Target: the Driftwood Isles alpha implementation on `feat/driftwood-isles`.

## Automated checks

The final local gate is `python3 scripts/dev.py all --tools-dir ../tools` using checksum-verified Rojo 7.7.0, Luau 0.737, and StyLua 2.5.2. The override locates tools downloaded for this workspace; normal checkouts use `.tools` by default.

| Check | Result |
| --- | --- |
| Luau syntax compilation | Passed for all 8 source/test files |
| Strict analysis of Config, Island, Persistence, and their tests | Passed with zero diagnostics |
| StyLua formatting | Passed |
| Island public-action suite | 10 behavior groups passed |
| Persistence public-interface suite | 20 scenarios passed |
| Rojo place build | Passed; generated `build/DriftwoodIsles.rbxlx` |

Game-rule scenarios cover resource depletion, no-overspend construction, unauthorized/distant/dead/malformed actions, helper revocation, closure, solo/group event work, cooldowns, reward replay, reload, invalid records, and detached state. Persistence scenarios cover exclusive ownership, expiry, takeover, revision conflicts, retry callbacks, release, uncertain results, snapshots across yields, concurrent operations, and Studio IDs.

## Review fixes

- Reconnecting players wait for the prior Player instance’s closing runtime instead of remaining permanently uninitialized.
- New arrivals wait briefly for a departing island slot rather than receiving an incorrect server-full rejection.
- A transient in-flight persistence operation receives a bounded load retry.
- Frozen or closing islands disable their prompts and clear the unfinished storm presentation.
- Switching islands invalidates the Crew panel’s cached state, including which Visit button is enabled.
- Save recovery messaging distinguishes unsaved changes from confirmed writes and directs paused owners to rejoin.
- Unfinished building-site signs display current/required supplies.
- Construction completion plays a quiet packaged Roblox sound only after a new project appears in a server snapshot; loading or changing islands does not replay it.
- Removed an unused spatial ownership lookup; the authoritative active-island mapping remains the source of truth.

## Checks requiring Roblox Studio or a device

No Roblox Studio runtime is available in this Linux environment. The following have **not** been performed:

- Engine-aware Script Analysis for the Roblox service integration, world, and client scripts.
- Launching the generated world, rendering the interface, and observing physics/collisions.
- Two/four-client integration playtests and actual Roblox DataStore network behavior.
- Touch layout verification in Studio and performance measurements on a real phone.
- Publishing or changing a live Roblox experience.

Use [studio-validation.md](studio-validation.md) before an external playtest. A successful place build packages source; it does not prove runtime or visual correctness. The 30 FPS phone target and first-session pacing are unmeasured design targets.

## Current scope limitations

The island uses three fixed projects and one repeatable event. There is no free placement, trading, monetization, permanent co-ownership, offline editing, or cross-server discovery. Studio defaults to session-only data; live saves require a published experience. Unexpected server termination can lose progress since the last successful save. An ambiguous save result pauses the island and requires rejoining, potentially after the previous lease expires.

## Independent review

**Standards:** The review found one plan-conformance gap (construction audio) plus optional duplicated-display and unused-lookup concerns. The unused lookup was removed. World signs now show resource progress while the HUD retains total costs, so their different presentation remains local.

**Spec:** The review found two small omissions: construction audio and building-site resource progress. Both are implemented. No additional high/medium ownership, economy, saving, or storm correctness defect was reported. Studio validation remains an explicit external gate.

The completion cue uses `rbxasset://sounds/action_jump.mp3`, referenced in [Roblox's packaged character-sound code](https://github.com/Roblox/Core-Scripts/blob/425d2d641bdc4b6c1104a9d5f6c53c9ea758c5cb/PlayerScripts/StarterCharacterScripts/Sound.server.lua#L93), at reduced volume and increased playback speed. Confirm audibility in Studio along with the rest of runtime presentation.
