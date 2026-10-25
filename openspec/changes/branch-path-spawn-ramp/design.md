# Design

## Context

Spawning draws from one shared wave queue. In `GameState+Combat.swift` (`update`), every spawn cell (`spawnCells`: the start cell plus each branch entry) has its own timer and interval (a random 0.5-1.5s, re-rolled after each spawn and at round start in `startRound`). Whichever timer fires first takes the next unspawned enemy. With two cells each path gets roughly half the wave. Branches are tracked as `branchEntryCoords` and `branchPathCoords`, created by `addBranchPath()` at the end of every 10th round and cleared in `restart()`. Inventory items are plain counters (`ringItemCount` for Spawn Tiles, `moveTowerItemCount`). See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- A newly opened branch receives a small share of each wave and ramps to an equal share, with one tunable curve.
- Wave size, composition and HP budget stay untouched; only which path an enemy spawns on changes.
- The share logic is a pure function so it can be unit tested without running a round.

**Non-Goals:**
- Reserving heavy enemy types (brutes, colossi) for the main path. Only the boss is guarded; per-enemy path assignment can follow later if needed.
- Auto-building towers on the branch (only a few terrain tiles are seeded).
- Exposing ramp numbers in the UI or settings.

## Decisions

**Share via spawn-interval stretch.** The branch's randomly drawn interval is multiplied by `k = 1/s - 1`, where `s` is the target share. With the main path spawning at rate 1/I and the branch at 1/(kI), the branch's share is `1/(k+1) = s`. The multiplier is applied after the RNG draw, so the seeded draw order is unchanged. Alternative considered: assigning each enemy a path when the wave is built. It gives exact shares and per-type control, but touches wave building and the spawn loop, and breaks the simple shared-queue model; deferred as a possible follow-up. Another alternative was a probabilistic skip at spawn time, which adds RNG draws and makes the share noisy.

**Linear ramp from 15% to 50% over 10 rounds.** `s(n) = 0.15 + 0.35 * min(n, 10) / 10`, where `n` is the number of full rounds since the branch opened (0 in the first round after opening, since the branch opens at the end of round 10 and `n = round - openedRound - 1` in round 11). `k` goes from about 5.7 to 1. The constants live as named statics next to the function so they are easy to tune.

**Per-branch opening round.** A new dictionary `branchOpenedRound: [HexCoord: Int]` keyed by branch entry coord, filled in `addBranchPath()` with the current `round`. A dictionary (not one global value) lets later branches ramp independently. It is cleared in `restart()`. The start cell has no entry and always uses `k = 1`.

**Boss guard in candidate selection.** For a ramping branch (`n < 10`) the spawn loop picks the first unspawned enemy that is not a boss. If only the boss remains, that branch skips this tick and the other paths spawn it. This keeps the guard local to candidate selection, with no change to wave order.

**Item grant inside `addBranchPath()`.** Granting on successful creation, rather than at the round-end call site, keeps behavior consistent for any caller and is directly testable, since tests already call `addBranchPath()`. The failure path (no route) returns before granting. The grant is 1 Spawn Tiles and 2 Move Tower.

**Terrain seeding inside `addBranchPath()`.** After the path cells are added, collect the empty cells (`hexGrid.cell(at:) == nil`) adjacent to branch path cells, sort them for a stable order (as `seedTerrainAroundBase()` does), and pick up to 3 at random with the seeded `rng`, creating each with the existing `makeTerrainCell(at:)` (which sets height from neighbours and a random terrain type). Only empty cells are used, so path, start, end and no-build cells are never replaced. The new terrain cells are appended to the array `addBranchPath()` returns, which the round-end call site already passes to the renderer as `newCells`; implementation must confirm the renderer handles terrain cells there. Candidates come from the whole branch, not just its start, so tiles are spread along the route. Alternative considered: always seeding next to the branch's entry. Rejected, since the entry is next to the start's no-build ring and has little free space. Alternative: relying only on the Spawn Tiles item. Rejected, since the player would have nowhere to build for the first moves.

## Risks / Trade-offs

- [Two or more branches make the share formula approximate, since it assumes one other path spawning at rate 1/I] → Accept; the ramp is a difficulty curve, not an exact allocation. Revisit with per-enemy assignment if it matters.
- [Slow branch plus boss guard could leave the boss as the last unspawned enemy waiting for the main path's timer] → The main path keeps spawning every 0.5-1.5s, so the delay is at most one interval; round end already waits for all enemies to spawn.
- [Heavy enemies can still land on a bare ramping branch] → At 15-25% share early on this is a smaller exposure than today's 50%; heavier guards are an explicit non-goal.
- [Existing tests that count items or branch state] → Update where they construct branches via `addBranchPath()`.

## Migration Plan

No data migration: state is in-memory and reset by `restart()`. Rollback is reverting the change.
