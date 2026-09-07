# Contribution standards

Keep changes within the approved game plan unless a new product decision is documented.

- Server code owns economic and shared-world state. Treat every client request and prompt as untrusted.
- Island actions must not yield between validation and mutation. Apply resource deduction and project completion together.
- Persist an island as one record. Preserve session and revision checks; never default over a failed or malformed load.
- Test behavior through the public island-action and persistence interfaces, using a controllable clock and storage adapter. Avoid implementation-mirroring tests.
- Use strict Luau for pure modules where possible. Runtime scripts use Roblox APIs and require Studio Script Analysis in addition to CLI compilation.
- Keep player-facing messages understandable; put implementation details in logs and developer documentation.
- Use stable IDs in saved data. Change the schema deliberately and supply migration/recovery behavior before shipping incompatible records.
- Use original geometry or assets with verified rights. Do not introduce opaque free-model scripts.
- Run `python3 scripts/dev.py format`, then `python3 scripts/dev.py all` before submitting. Report unavailable Studio checks honestly.
- Keep code review focused on correctness, conformance to the plan, and changes that materially simplify the implementation.
