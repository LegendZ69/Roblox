# Studio and device validation checklist

This checklist requires Roblox Studio on Windows or macOS and access to a dedicated test experience. It is not marked complete by automated CLI tests.

## Single-player loop

- [ ] Open the built place and press Play; an island and the HUD appear without errors in Output or Script Analysis.
- [ ] Harvest using keyboard and touch emulation. Confirm prompt visibility, cooldown feedback, resource counts, and harvest distance.
- [ ] Build the campfire, bridge, and beacon in order without developer grants. Record time to first harvest, first building, and beacon.
- [ ] Confirm building-site signs show current/required resources and newly completed projects play one quiet sound cue. Loading or visiting an already-built island should not replay the cue.
- [ ] Walk across the bridge in both directions. Check collision edges, tree obstruction, repair station access, and fall recovery.
- [ ] Complete, fail, and retry a storm. Observe objectives, one reward, cooldown, and no permanent destruction on failure.
- [ ] Reset the character and confirm the player returns to the active island with correct UI state.
- [ ] While the personal profile is loading or unavailable, use Crew to visit, accept/decline an invitation, and return to the hub. Confirm personal load completion does not interrupt a chosen visit and that editing still requires host permission.
- [ ] Visit a storm without helper permission: the objective remains read-only and the event control says it is being watched. Pause the host island: both owner and helper see recovery directions, not repair or invitation instructions.
- [ ] Confirm exact wood/stone deficits and completed-tutorial guidance after reload. Check that longer directions scroll without clipping and Studio save labels retain loading/recovery status.

## Two and four clients

- [ ] Launch Server & Clients with two clients, then repeat the full loop with four.
- [ ] Visit another island before an invitation: view works, gathering/building/repair do not.
- [ ] Invite, decline, expire, re-invite, and accept. Confirm ownership disclosure and correct helper access.
- [ ] Two helpers act on the same final affordable project and resource node. Confirm no duplicate project or negative stockpile.
- [ ] Revoke a helper during activity. Confirm return home and immediate loss of permissions.
- [ ] Owner leaves while helpers are building or repairing. Confirm no partially charged project, no unfinished event reward, and helpers return home.
- [ ] Reconnect a player and test late arrival, current-island switching, and character respawn.

## Persistent storage in a dedicated test experience

- [ ] Enable `ServerScriptService.EnableStudioPersistence` before running. Studio API access must be enabled. Confirm use of the `_Studio` store.
- [ ] Harvest, build, wait for a confirmed save, stop the server, and start again. Compare resources, projects, tutorial stage, and event cooldown.
- [ ] Leave normally immediately after a valid action; verify the final write on a later join.
- [ ] Attempt concurrent sessions against the same test island. Only one may obtain ownership; stale sessions cannot save over it.
- [ ] Disable or fault the store in a controlled test. Confirm failure/recovery UI and no silent reset. The pure adapter suite provides deterministic retry/lease-failure coverage.
- [ ] Complete a storm and reconnect during its cooldown. No duplicate reward or immediate cooldown bypass.
- [ ] Record the last confirmed autosave, then forcibly end the test server. Quantify any lost unsaved progress; do not promise zero loss after crashes.

## Controls and performance

- [ ] Portrait and landscape phone emulation: core actions remain reachable, text is legible, and Crew/objective panels do not cover essential movement controls.
- [ ] Verify gamepad prompt activation if adding gamepad support to the release claim; desktop/touch are the current target.
- [ ] Test an actual phone with four active players during a storm. Record model, graphics level, frame rate, memory, and visible stutters.
- [ ] Meet or revise the proposed 30 FPS device target based on recorded observations. Emulation alone does not establish mobile performance.
- [ ] Confirm exactly four island slots and set the experience maximum player count to four.

## Playtest handoff

- [ ] Record the tested commit and place build.
- [ ] Clear all runtime errors and critical interaction failures.
- [ ] Keep unresolved checks and known issues visible in `docs/validation.md`.
- [ ] Choose the intended Roblox audience and publish from the authorized account only after the test result is reviewable.
