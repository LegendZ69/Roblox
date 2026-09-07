# Implementation validation

Date: 7 September 2026. Target: the Driftwood Isles alpha implementation on `feat/driftwood-isles`.

## Automated checks

The final local gate is `python3 scripts/dev.py all --tools-dir ../tools` using checksum-verified Rojo 7.7.0, Luau 0.737, and StyLua 2.5.2. The override locates tools downloaded for this workspace; normal checkouts use `.tools` by default.

| Check | Result |
| --- | --- |
| Luau syntax compilation | Passed for all 10 source/test files |
| Strict analysis of Config, Island, Persistence, Session, and their tests | Passed with zero diagnostics |
| StyLua formatting | Passed |
| Island public-action suite | 10 behavior groups passed |
| Persistence public-interface suite | 20 scenarios passed |
| Session public-request integration suite | 11 behavior groups passed |
| Rojo place build | Passed; generated `build/DriftwoodIsles.rbxlx` |
| Built-place verification | Passed; 16 instances, 7 exact source embeddings, configured properties |

Game-rule scenarios cover resource depletion, no-overspend construction, unauthorized/distant/dead/malformed actions, helper revocation, closure, solo/group event work, cooldowns, reward replay, reload, invalid records, and detached state. Persistence scenarios cover exclusive ownership, expiry, takeover, revision conflicts, retry callbacks, release, uncertain results, snapshots across yields, concurrent operations, and Studio IDs.

The 11 session groups run the production request coordinator with the real Island and Persistence modules, controlled clocks and character facts, an in-memory storage adapter, and recorded transport effects. They verify two-player invitation-to-build-to-save behavior; host/helper stockpile isolation; revocation and stale host prompts; unknown/malformed/forged requests; invite expiry/decline/replay; owner and helper departures/rejoins; four-player storm scaling and one-time persisted rewards; participant eligibility; shared prompt/remote throttling; detached views with Studio IDs; and pause behavior after lease expiry or an unconfirmed save. Total: **41 behavior groups across 3 suites**. This is server coordinator integration testing, not a running Roblox multiplayer session.

The build verifier derives instance paths and script classes from the project mappings, checks the embedded source against current files, enforces server/shared/client service placement, and checks configured primitive properties. It rejects unexpected instances and test scripts. Five intentionally corrupted artifacts were rejected during verification; a temporary added module was discovered automatically, and invalid test/server source mappings were rejected.

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
- Extracted multiplayer coordination into the production `Session` module so its behavior can run under the standalone Luau VM.
- Unsupported action kinds can no longer trigger a full-state broadcast; incoming extra fields cannot override authority, distance, rewards, or participation.
- Remote/prompt dispatch and departure cleanup check Player instance identity before touching the active session.
- Pausing an island now also clears its outgoing invitations immediately.

## Checks requiring Roblox Studio or a device

No Roblox Studio runtime is available in this Linux environment. The following have **not** been performed:

- Engine-aware Script Analysis for the Roblox service integration, world, and client scripts.
- Launching the generated world, rendering the interface, and observing physics/collisions.
- Two/four-client Roblox playtests, engine lifecycle scheduling, and actual DataStore network behavior.
- Touch layout verification in Studio and performance measurements on a real phone.
- Publishing or changing a live Roblox experience.

Use [studio-validation.md](studio-validation.md) before an external playtest. A successful place build packages source; it does not prove runtime or visual correctness. The 30 FPS phone target and first-session pacing are unmeasured design targets.

## Current scope limitations

The island uses three fixed projects and one repeatable event. There is no free placement, trading, monetization, permanent co-ownership, offline editing, or cross-server discovery. Studio defaults to session-only data; live saves require a published experience. Unexpected server termination can lose progress since the last successful save. An ambiguous save result pauses the island and requires rejoining, potentially after the previous lease expires.

## Independent review

**Standards:** The review found one plan-conformance gap (construction audio) plus optional duplicated-display and unused-lookup concerns. The unused lookup was removed. World signs now show resource progress while the HUD retains total costs, so their different presentation remains local.

**Spec:** The review found two small omissions: construction audio and building-site resource progress. Both are implemented. No additional high/medium ownership, economy, saving, or storm correctness defect was reported. Studio validation remains an explicit external gate.

The completion cue uses `rbxasset://sounds/action_jump.mp3`, referenced in [Roblox's packaged character-sound code](https://github.com/Roblox/Core-Scripts/blob/425d2d641bdc4b6c1104a9d5f6c53c9ea758c5cb/PlayerScripts/StarterCharacterScripts/Sound.server.lua#L93), at reduced volume and increased playback speed. Confirm audibility in Studio along with the rest of runtime presentation.

### Cloud continuation review

Two independent reviews compared the coordinator extraction and build verifier against commit `52207bd`. The standards and spec reviews found no high or medium correctness or conformance issue. Both confirmed that production remote/prompt dispatch uses the tested coordinator and preserves server authority and host-only progress.

The departure scenarios compose `Session.remove`, `Island.close`, and `Persistence.release` through public interfaces. They do not execute Main's yielding join/save/shutdown orchestration or actual RemoteEvent transport. Those remain part of the Studio gate.
