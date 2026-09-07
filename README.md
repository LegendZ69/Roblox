# Driftwood Isles

A cooperative Roblox island builder for one to four players. Gather wood, light a campfire, bridge to a stone outcrop, restore a beacon, and complete a short storm challenge with your crew.

Each player owns one saved island. Invited helpers work with that island’s shared supplies; all progress stays with its owner. Owners can revoke access, and helpers return home when the owner leaves. Visitors can look around without editing.

## Play in Roblox Studio

1. Download `DriftwoodIsles.rbxlx` from this branch’s **Actions → Validate and build → DriftwoodIsles** artifact, or build it using the instructions below.
2. Open the place in Roblox Studio on Windows or macOS.
3. Press **Play**. The authored world is constructed by server code when the simulation starts; the edit viewport initially contains no island geometry.
4. Walk to a tree and use its interaction prompt (keyboard **E**, or the prompt’s touch button). Collect 12 wood and build the campfire, then follow the objectives.
5. Open **Crew** to visit other players, invite helpers, or accept an invitation. The invite explains that resources and buildings remain on the host’s island.

For cooperation, use Studio’s **Server & Clients** testing mode with two to four clients. Session-only saving is enabled by default in Studio: progress exists only for the running test server and is lost when that server stops. This is explicitly labeled in the interface.

## Build from source

Requires Python 3.10+ and network access to GitHub for the first tool download. The bootstrap supports Windows x64, Linux x64, and macOS (see the tool manifest for architectures).

```sh
python3 scripts/bootstrap_tools.py
python3 scripts/dev.py all
```

On Windows, use `python` instead of `python3` if needed. Tools are downloaded from their official release assets, verified against pinned SHA-256 hashes, and kept in the ignored `.tools` directory. No Roblox account credentials are needed to compile or run the game-rule, persistence, and multiplayer coordinator tests.

Output: `build/DriftwoodIsles.rbxlx`.

Individual commands:

```sh
python3 scripts/dev.py check   # Luau compiler + core strict analysis + formatting
python3 scripts/dev.py test    # Behavioral tests using the official Luau VM
python3 scripts/dev.py build   # Rojo build + embedded source/hierarchy verification
python3 scripts/dev.py format  # Format Luau source
python3 scripts/dev.py serve   # Live source sync through the Rojo Studio plugin
```

Pinned tool versions: Rojo 7.7.0, Luau 0.737, StyLua 2.5.2. The matching Rojo plugin is required only for live sync. Source can also be rebuilt and reopened without a plugin. Python is the canonical verified bootstrap; `rokit.toml` provides equivalent convenience pins for Rokit users.

## Persistent saves

Published Roblox servers use `DataStoreService` automatically. The production store is `DriftwoodIsles_v1`. An island’s resources, projects, unlocks, tutorial stage, event reward receipt, and cooldown share one versioned record.

- Autosave attempts run every 30 seconds, with a 120-second exclusive session lease.
- Saves and final departure writes recheck session identity, revision, and lease expiry.
- A failed load never creates a replacement profile. An uncertain save stops ownership rather than allowing a stale writer to continue.
- Graceful departure/shutdown attempts a final save; an abrupt server failure can lose progress since the last confirmed write.
- The UI separates unsaved changes, saving, confirmed saves, and recovery.

To test real saving in Studio:

1. Publish the place to a dedicated **test experience** you own.
2. In its settings, enable Studio access to API services.
3. Add a Boolean attribute named `EnableStudioPersistence` to **ServerScriptService** and set it to `true` before starting the test.
4. Confirm the session-only label disappears, build a project, stop, and start a fresh test session.

Studio persistence uses `DriftwoodIsles_v1_Studio`, separate from the live store. Do not rename stores or edit saved records casually. See [the validation checklist](docs/studio-validation.md) for recovery and competing-session tests.

## Project layout

| Area | Responsibility |
| --- | --- |
| `src/shared/Config.luau` | Resource yields, costs, coordinates, event timings, and limits |
| `src/server/Island.luau` | Non-yielding island actions and event rules |
| `src/server/Persistence.luau` | Session ownership and conditional saves |
| `src/server/Session.luau` | Request validation, crew invitations, visiting, routing, and request limits |
| `src/server/Main.server.luau` | Roblox services, character facts, player lifecycle, and scheduling |
| `src/server/World.luau` | Original island geometry, prompts, project models, and lighting |
| `src/client/Main.client.luau` | Responsive HUD, objectives, event display, and crew interface |
| `tests/` | Game rules, save failures, and two/four-player coordinator scenarios |
| `scripts/verify_place.py` | Built-place service placement, current source, and configured property checks |

The client submits intentions; the server checks permissions, location, character state, cooldowns, stockpile balance, and prerequisites. No client-submitted reward, balance, or price is trusted. Construction uses fixed sites, with no demolition, resource withdrawals, trading, or cross-island transfers.

## Validation and release status

The automated pipeline compiles all Luau, strictly analyzes the pure core and tests, checks formatting, runs 41 behavior groups, and builds the Studio place. The build gate verifies that the place embeds the exact current source in the correct services, preserves configured properties, and contains no test scripts.

The multiplayer scenarios run the same `Session` coordinator used by the live server together with the real `Island` and `Persistence` modules. They cover invitations, host-only progress, revocation and departures, four-player storm rewards, request limits, and lost save sessions using controlled clocks, character facts, and storage. These checks do not run Roblox clients, simulate physics, render the UI, exercise real DataStore networking, or substitute for engine-aware Script Analysis.

See [validation results](docs/validation.md) and [the Studio checklist](docs/studio-validation.md). Studio multiplayer, phone layout, real-device performance, and live persistence must be checked before inviting external players. Set the experience’s maximum server size to **4**; the server also enforces the four-island limit.

The game has no paid products or external asset dependencies. The working title is provisional. Public publishing is a separate Roblox Studio action and has not been performed by this implementation.

## Design and development

- [Game plan](docs/game-plan.md)
- [Domain glossary](CONTEXT.md)
- [Contribution standards](CONTRIBUTING.md)
- [Runtime integration contract](docs/implementation-contract.md)

Implementation follows the approved spec’s playable slices. Additional content should be added only after the core loop has been playtested.
