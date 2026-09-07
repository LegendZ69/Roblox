# Roblox co-op island builder — build plan

Date: 7 September 2026
Repository: [LegendZ69/Roblox](https://github.com/LegendZ69/Roblox)
Working title: **Driftwood Isles** — provisional name, not a cleared release title.
Status: Planning draft. The user selected the co-op island builder direction. Other product choices below are proposed defaults.

## Problem statement

Create a playable Roblox game from a repository that currently contains only a README titled “Roblox.” There is no existing game code, Studio place, project configuration, or documented design to extend. The first release needs a complete, understandable activity that works alone and becomes more enjoyable with friends.

## Solution

Players turn a tiny island into a welcoming outpost. Gather wood, construct a campfire, build a bridge to a stone outcrop, and repair a beacon. Invite other players in the same server to help. The beacon unlocks a short cooperative storm challenge that rewards the island with additional supplies.

**Core loop:** gather resources → build a visible improvement → unlock a new activity → cooperate for a reward → return to expand.

The first alpha targets a satisfying 10–15 minute session. This is a design target to validate through playtesting, not a forecast of retention or commercial success. No conclusions from the earlier top-games research were available to substantiate market claims.

## Proposed MVP defaults

| Area | Initial scope |
| --- | --- |
| Audience and controls | Broadly accessible, nonviolent play; desktop and touch controls |
| Multiplayer | Four players per server; solo play supported; up to four players can help on one island |
| World | One authored biome, a compact arrival hub, and up to four player island plots |
| Resources | Wood and stone, held in an island stockpile |
| Construction | Three fixed building sites: campfire, bridge, beacon; visible previews and resource costs |
| Exploration | The bridge opens one stone outcrop; no procedural terrain |
| Cooperative event | One owner-started, approximately 90-second storm repair challenge after the beacon is built |
| Rewards | Supplies deposited into the participating island’s stockpile; no separate currency |
| Progress | Island resources, completed projects, unlocks, tutorial stage, and event cooldown saved |
| Art | Bright stylized islands, clear silhouettes, simple prefabs, restrained effects |
| Monetization | Deferred until the playable loop is validated |

Fixed sites deliberately keep the first build small: the player chooses what to unlock, while the site determines placement. Free placement can be a later feature.

## Ownership and cooperation

Every player owns one persistent island. An owner can invite another player already in the same server to become a temporary helper. The helper accepts before participating; permission expires when either party leaves, and the owner can revoke it immediately.

An accepted helper can harvest into the host island’s stockpile and activate its unfinished, predefined projects. Before accepting, the interface explains: **“You’re helping [owner]. Resources and buildings stay on their island.”** There are no transfers from a helper’s personal island and no duplicated island saves.

Helpers cannot demolish, move, sell, withdraw resources, or grant permission to others. Each project can be purchased once. An uninvited visitor can view an island but cannot change it. Returning home switches the player back to their own island and its stockpile.

If the owner disconnects, the server closes that island to new actions, cancels any unfinished event without a reward, saves the latest valid state, and returns helpers to their own plots or the hub. Ownership is never transferred automatically. Permanent joint ownership and offline editing are outside this MVP.

## First-session experience

1. Arrive on a small island with a clear objective: gather wood for a campfire.
2. Harvest a nearby resource using the same accessible interaction on desktop or touch.
3. See the island stockpile update and the building site show progress toward its cost.
4. Construct the campfire and receive immediate visual and audio feedback.
5. Build a bridge to reach stone deposits and expose the beacon objective.
6. Optionally invite someone from the server to help finish the beacon.
7. Start the storm challenge. Players repair a small set of marked stations; the workload scales to the number of participants at the start.
8. Receive one island reward on success. Failure causes no permanent destruction or resource loss, and a cooldown prevents immediate retries.
9. Leave and later return to the saved island.

Initial pacing targets: first successful interaction within 30 seconds and first building within three minutes. Resource yields, costs, node refresh intervals, and event workload remain tunable configuration, subject to observation.

## User stories

1. As a new player, I want a clear first objective so I know what to do immediately.
2. As a solo player, I want every objective to be achievable alone so I can progress without waiting for friends.
3. As a touch player, I want reachable controls and legible prompts so the core loop works on a phone.
4. As a player, I want immediate harvesting feedback so my actions feel responsive.
5. As an owner, I want building costs and prerequisites shown before purchase so I can choose my next goal.
6. As an owner, I want each completed project to visibly improve my island so progress feels meaningful.
7. As an explorer, I want a bridge to reveal a useful new area so construction changes what I can do.
8. As an owner, I want to invite and remove helpers so I control who changes my island.
9. As a helper, I want to know whose progress I am advancing so collaboration is an informed choice.
10. As a helper, I want to see the same resources and projects as the owner so our actions stay coordinated.
11. As a visitor, I want a simple way to return home so I can resume my own progress.
12. As a late arrival, I want the island’s current state to load correctly so I can understand the ongoing session.
13. As a group, we want a short shared challenge so we have a reason to work together.
14. As a player, I want fair, clearly explained event rewards so success is understandable.
15. As an owner, I want my island restored when I return so my work persists.
16. As an owner, I want load errors handled without resetting my island so temporary failures do not destroy progress.
17. As a helper, I want a clear message when the host leaves so I understand why the session ends.
18. As a developer, I want reproducible builds and behavioral checks so changes can be reviewed and tested.

## Implementation decisions

**Development workflow.** Use Roblox Studio for world editing and runtime testing, typed Luau for scripts, and Rojo 7 to map versioned source into a Studio place. Pin tool versions when implementation begins. Add formatting, static analysis, a reproducible place build, and concise contributor instructions. Rojo’s [installation](https://rojo.space/docs/v7/getting-started/installation/) and [project format](https://rojo.space/docs/v7/project-format/) document this workflow.

**Responsibilities.** Keep authoritative island actions and progression on the server. The client handles controls, presentation, previews, and local feedback. Separate island rules, persistence, participant permissions, and storm lifecycle behind small interfaces. Shared configuration supplies known project IDs and display information; the server supplies trusted costs, yields, and eligibility.

**Action boundary.** Clients request an action against a known resource node, building site, or repair station. They do not supply trusted balances, prices, rewards, or owner identities. The server checks argument shape, known identifiers, current island, permissions, character state, distance, cooldowns, and resource availability. Validate prompts as well as remote calls and rate-limit requests. Apply a purchase’s deduction and completed-project change together, without yielding between them. These choices follow Roblox’s [client-server security guidance](https://create.roblox.com/docs/scripting/security/client-server-boundary).

**Persistence.** Keep an island’s stockpile, projects, unlocks, and relevant progress in one versioned record keyed by its owner. Reconstruct the authored island from stable project identifiers instead of saving arbitrary Instances. Use an exclusive server session lease, atomic acquisition and checked writes, periodic saving, bounded retries, and departure/shutdown handling. Prevent an older session from overwriting a newer one. A failed load must never be treated as a confirmed new player. If ownership of the save cannot be maintained, stop accepting mutations and show a recovery message. Roblox documents [data stores](https://create.roblox.com/docs/cloud-services/data-stores) and [session locking considerations](https://create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing).

**Save limits.** Do not promise zero lost progress after an abrupt server failure. Establish and document an autosave interval during implementation. Keep test data separate from production data. Only show a successful save status after a confirmed write.

**Storm lifecycle.** The server owns start, active, success/failure, and cooldown states. Resolve each event at most once; record its reward receipt and resulting stockpile change in the same island record. Persist the next eligible start time. Do not resume an interrupted event after a server restart. Distinguish a completed event awaiting save from an event still in progress so retries cannot issue the reward twice.

**Content and deployment.** Use original simple geometry and authorized assets. Deliver a reproducible place file plus Studio instructions. Publishing and real client playtests require access to Roblox Studio and the target experience; this planning environment is Linux and has no verified Studio runtime or Roblox publishing connection.

## Draft implementation slices

Each slice delivers a demonstrable player behavior, including the necessary UI, server rules, and relevant checks. These are proposed tickets, not published tracker issues.

| ID | Slice | Blocked by | What it delivers and acceptance criteria |
| --- | --- | --- | --- |
| 1 | Gather wood and build a campfire | None | A reproducible place opens in Studio. One player spawns, harvests wood, sees the stockpile, and builds a campfire on desktop and touch. Invalid, distant, and repeated purchase requests cannot create resources or duplicate buildings. Data is session-only for this initial demonstration. |
| 2 | Leave and resume the island | 1 | The campfire and remaining wood survive a successful save and reload. Load failure cannot overwrite existing data; concurrent sessions cannot both own the record; stale saves are rejected. UI distinguishes loading, playable, saving, and recovery states. |
| 3 | Invite a helper and build together | 2 | Owners invite and revoke helpers. Two clients see matching stockpiles and project state. Uninvited actions fail. Simultaneous requests cannot overspend or duplicate a project. Owner departure closes editing, saves, and returns visitors safely. |
| 4 | Build a bridge and restore the beacon | 2 | A wood-funded bridge unlocks reachable stone nodes; the beacon requires both resources. Costs and prerequisites are shown. Progress persists, and resource amounts needed for every project are obtainable without circular prerequisites. |
| 5 | Complete the cooperative storm challenge | 3, 4 | Solo players and groups can start, finish, fail, and retry after cooldown. Objective progress agrees across clients. Reward is applied once, owner departure cancels an unfinished run, and restart/retry cannot duplicate a completed reward. |
| 6 | Finish the guided first session | 3, 4 | A newcomer can follow objectives through the beacon, understand host/helper ownership, invite a helper, and return home. Tutorial progress survives reload; returning players are not forced through completed steps. Test desktop and touch layouts. |
| 7 | Package and verify the alpha | 5, 6 | Produce the versioned source, built place, setup guide, and a recorded validation report. Run the complete loop with one and four players, test interrupted saving, and check device performance. Any unavailable Studio/device checks are explicitly marked pending. |

Slices 3 and 4 can proceed independently after saving works. Slices 5 and 6 can proceed independently after cooperation and progression are available. Each ticket should be split further if implementation discovery shows it exceeds one focused agent context, especially persistence failure handling.

**First milestone:** slices 1–3. Two people can gather and build together, and the owner can leave and resume the result. This proves the central technical promise before more content is added.

## Testing decisions and acceptance gate

There are no existing test conventions in the repository. The proposed primary test boundary is the server’s public island-action interface: supply a player action and observe the resulting state and event output. Use a controllable clock and persistence adapter to exercise failure conditions; do not test private helper functions simply because they exist.

| Scenario | Required observable behavior |
| --- | --- |
| Two players buy the final affordable project at once | One completion and one deduction; no negative stockpile |
| Two players harvest a nearly depleted node | Only available harvests are rewarded |
| Malformed IDs, out-of-range actions, revoked helpers, request spam | Rejection without state changes |
| Late join or returning home | Correct island, stockpile, permissions, and project state appear |
| Owner leaves during an action | Action finishes before closure or is rejected; no partial deduction |
| Save/load fails, session lease is lost, or an old server retries | No default overwrite, competing active owner, or stale write |
| Reload after normal save | Resources, buildings, unlocks, tutorial state, and cooldown match |
| Storm completion retried | A single reward and a consistent cooldown |
| Four players use desktop/touch controls | No blocked progression, unusable controls, or server errors |

Use [Studio’s multiplayer and device testing modes](https://create.roblox.com/docs/studio/testing-modes) for runtime checks. Emulation checks layout and controls; actual mobile hardware is required to substantiate mobile performance. Proposed alpha target: maintain at least 30 FPS during the four-player storm on the selected test phone, recording the device and conditions. Choose that device before claiming the target passed.

An alpha is ready for an invited playtest when the full loop is completable solo and cooperatively, saved progress reloads correctly, the failure cases above pass, and the validation report separates completed checks from pending checks. Formatting or compilation alone cannot establish gameplay correctness.

## Out of scope

- Free placement, demolition, terrain editing, and procedural islands.
- Permanent co-ownership, offline collaborators, cross-server island discovery, and ownership transfer.
- Trading, cross-island resource transfers, pets, combat, and competitive economies.
- Offline earnings, daily streaks, seasonal content, and a large crafting tree.
- Paid products, game passes, randomized purchases, and marketing spend.
- Public launch, platform-success forecasts, or claims based on unfinished top-games research.

## Workflow notes and remaining choices

This plan uses the spec structure and demoable dependency slices from Matt Pocock’s [to-spec](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-spec/SKILL.md) and [to-tickets](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-tickets/SKILL.md). The repository has no configured Matt Pocock issue-tracker workflow. Run `/setup-matt-pocock-skills` before using its full publication workflow. That workflow reviews the testing boundary and ticket breakdown before publishing; this document is the concrete draft for that review.

Only the game direction is user-confirmed. The working title, four-player limit, owner/helper model, fixed construction sites, event, pacing, and test boundary are recommended defaults. None require guessing account credentials or changing a live experience. The Roblox experience owner and target test devices must be identified before platform testing or publication.

The next implementation task is slice 1: produce a Studio-openable island where a player can gather wood and build the first campfire.
