# Proposal

## Why

Every 10 rounds a new branch path opens, from the start tile to the end tower, with no towers on it and no terrain beside it to build on. Because all spawn cells draw from one shared wave queue, the branch immediately takes about half of every wave, including bosses, so the player faces half the wave on a bare path with nowhere to build a defense.

## What Changes

- When a branch path is created, place a few random buildable terrain tiles next to it, so towers can be placed on the branch right away.
- When a branch path is created, also grant the player one **Spawn Tiles** item and two **Move Tower** items, so they can open more build space beside the new path and relocate towers onto it.
- Throttle the branch's spawn share. Each branch's spawn interval is stretched so it takes a small share of each wave (about 15%) in the first round after it opens, then ramps linearly to an equal share with the main path (50%) over about 10 rounds. Because the wave queue is shared, enemies the branch does not take spawn on the other paths, so wave size is unchanged.
- Track the round each branch opened so every branch ramps independently (a second branch opened at round 20 starts its own ramp at 15%).
- While a branch is ramping, it does not spawn the boss; the boss spawns on another path instead.
- Clear the new per-branch state on restart.

## Capabilities

### New Capabilities
- `branch-paths`: How branch paths are opened and brought online: the items granted when one opens, and the gradual ramp of its spawn share and boss guard.

### Modified Capabilities
<!-- None: openspec/specs is empty; branch path generation itself is unchanged. -->

## Impact

- `Tower Defense/GameState+MapGeneration.swift`: branch creation (`addBranchPath` and its call site at the end of round) seeds terrain tiles beside the branch, grants the items and records the opening round; `restart()` clears the new state.
- `Tower Defense/GameState.swift`: new per-branch state (round opened, keyed by branch entry coord).
- `Tower Defense/GameState+Combat.swift`: the spawn loop stretches the branch interval and skips the boss for ramping branches.
- `TestGameTests/TestGameTests.swift`: tests for the share ramp, the boss guard, the item grants, and restart.
- No change to wave HP budget, wave composition, or branch route generation.
