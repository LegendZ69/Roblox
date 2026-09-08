# Implementation validation

Date: 8 September 2026. Target: Driftwood Isles `0.1.0-alpha.3`.

## Automated checks

The final local gate is `python3 scripts/dev.py all --tools-dir ../tools` using checksum-verified Rojo 7.7.0, Luau 0.737, and StyLua 2.5.2. The override locates tools downloaded for this workspace; normal checkouts use `.tools` by default.

| Check | Result |
| --- | --- |
| Luau syntax compilation | Passed for all 16 source/test files |
| Strict analysis of Config, ClientPolicy, Guidance, Island, Persistence, Session, and their tests | Passed with zero diagnostics |
| StyLua formatting | Passed |
| Island public-action suite | 10 behavior groups passed |
| Persistence public-interface suite | 20 scenarios passed |
| Session public-request integration suite | 12 behavior groups passed |
| Client action-eligibility policy suite | 8 behavior groups passed |
| Bridge/beacon progression acceptance | 4 behavior groups passed |
| Cooperative storm acceptance | 8 behavior groups passed, including all 1–4-player crew sizes |
| Production HUD guidance | 9 behavior groups passed |
| Rojo place build | Passed; generated `build/DriftwoodIsles.rbxlx` |
| Built-place verification | Passed; 19 instances, 9 exact source embeddings, configured properties including release version |
| Release packaging suite | 15 cases passed, including deterministic archives, tested-source provenance, complete guides, and required current evidence |
| Release publication suite | 17 cases passed, including draft upload, interrupted resume, and conflict refusal |
| Reviewed release-commit selector suite | 8 cases passed |
| Place-verifier regression suite | 8 cases passed |
| Cloud validation report suite | 17 cases passed, including failed-stage invalidation, changed inputs/place, exact report structure, deterministic bytes, and nonempty Python discovery |

Game-rule scenarios cover resource depletion, no-overspend construction, unauthorized/distant/dead/malformed actions, helper revocation, closure, solo/group event work, cooldowns, reward replay, reload, invalid records, and detached state. Persistence scenarios cover exclusive ownership, expiry, takeover, revision conflicts, retry callbacks, release, uncertain results, snapshots across yields, concurrent operations, and Studio IDs.

The 12 session groups run the production request coordinator with the real Island and Persistence modules, controlled clocks and character facts, an in-memory storage adapter, and recorded transport effects. They verify two-player invitation-to-build-to-save behavior; host/helper stockpile isolation; revocation and stale host prompts; unknown/malformed/forged requests; invite expiry/decline/replay; owner and helper departures/rejoins; four-player storm scaling and one-time persisted rewards; participant eligibility; shared prompt/remote throttling; detached views with Studio IDs; pause behavior after lease expiry or an unconfirmed save; and invited cooperation when the helper's own profile is unavailable, without creating a replacement profile. ClientPolicy adds eight groups for the actual HUD's startup, loading/recovery, owner/helper/visitor, frozen-state, social-target, save-state, and malformed-action decisions. Alpha.3 adds four progression groups, eight storm groups, and nine Guidance groups. Total: **71 behavior groups across 7 Luau suites**. This does not run Roblox clients or GUI events.

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

### Versioned release review

An audit against the approved alpha scope found no missing cloud-verifiable gameplay implementation. Version `0.1.0-alpha.1` adds embedded version identity, deterministic release packaging, source/tool manifests, checksums, and a GitHub workflow that publishes a new version after validation. Repeated Rojo builds produced identical place bytes.

Release review found and fixed two issues: ignored or index-hidden source edits could otherwise enter a package without belonging to its recorded commit, and SemVer build metadata was accepted by packaging but initially rejected by publication. The packager now compares the project and every mapped source byte-for-byte with the commit, and the publisher accepts the same safe version filenames. All **27 release-tool tests** pass. They exercise real temporary Git/package inputs and controlled API responses; the live workflow is the publication record. No release blocker remained after review.

### Alpha.2 recovery and handoff review

Independent game and release reviews found no blocking correctness issues in the changes against `173241f`. Both HUD buttons and outgoing requests now use the tested ClientPolicy. Loading/unavailable profiles retain safe social controls while economic and owner-only actions stay restricted. The server rechecks shutdown/departure after waits and preserves a chosen visit when personal loading finishes. Those small Main lifecycle changes are source-reviewed and compile-checked; Roblox scheduling and teleport effects are not executed by the cloud tests.

Release retries now select an exact commit from reviewed main history before running that commit's scripts, and publication receives the selected identity. ZIP tests check all local Markdown links in the actual setup guides. Verifier regressions reject unsupported root settings, Boolean/numeric substitutions, and rounded large integer values. **45 Python tests pass** across packaging, publication, commit selection, and place verification. The remaining milestones require Studio/device/runtime access; no additional approved cloud implementation gap was identified after this review.

### Alpha.3 milestones 2–5

The explicit [milestone acceptance map](milestones.md) follows the remaining approved slices. Progression and storm code was already present; new suites execute it through public production interfaces, including fresh lease acquisition after saved checkpoints, host-only shared construction, all supported storm crew sizes, timeout/retry, changing permissions, owner departure, and committed-but-unacknowledged reward recovery. Storage assertions reload through Persistence rather than inspecting its private envelopes.

The actual HUD now consumes Guidance for objectives, cards, event captions, and save labels. This fixes visitor repair instructions during storms, paused-helper invitation instructions, and hidden Studio loading/recovery information. Exact mixed-resource deficits and role-appropriate completed-tutorial guidance are covered by the new presentation suite. Text height changes are compiled, not visually verified.

The full pipeline runs **65 Python tests** and emits deterministic `cloud-validation.json` only after seven successful check stages with stable inputs. The report fingerprints tested sources, tests, tooling, project/configuration, and documentation, plus the verified place. Later edits, changed place bytes, failed stages, incomplete reports, ignored/index-hidden tested files absent from the commit, and type-substituted metadata are rejected. The ZIP includes this evidence and the milestone guide. The report is not a signed attestation; CI and release verification establish the execution and published artifact record.

All four milestones have cloud-implemented behavior and acceptance coverage. Their engine, networking, device, performance, and pacing acceptance is still pending, as listed above and in the Studio checklist.

#### Standards review

One finding against the alpha.2 baseline: Python 3.10–3.11 can report success for empty unittest discovery. The full pipeline now checks the discovered count explicitly and verifies both empty and failed suites are rejected. Follow-up review confirmed the finding is resolved. No other substantive standards breach or actionable smell was found.

#### Spec review

No blocking spec findings. Milestones 2–5 match approved slices 4–7 without additional product scope. Production HUD updates preserve visitor/recovery guidance, acceptance suites use the real public interfaces, and release evidence binds tested bytes to the package. Engine/device limitations remain correctly separated from cloud acceptance.
