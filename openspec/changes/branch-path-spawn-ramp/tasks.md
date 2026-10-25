# Tasks

## 1. Ramp state and share function

- [x] 1.1 Add `branchOpenedRound: [HexCoord: Int]` to `GameState.swift`, and clear it in `restart()`; verify with a test that it is empty after restart
- [x] 1.2 Add named static constants (start share 0.15, end share 0.50, ramp rounds 10) and a pure `branchSpawnShare(roundsSinceOpen:)` plus an interval multiplier `k = 1/s - 1`; verify with tests for n=0 (15%), n=5, n>=10 (50%, k=1)

## 2. Branch creation

- [x] 2.1 In `addBranchPath()` (`GameState+MapGeneration.swift`), record `branchOpenedRound` for the new entry coord and grant `ringItemCount += 1` and `moveTowerItemCount += 2` only on success; verify with tests that Spawn Tiles rises by 1 and Move Tower by 2 on success, and both are unchanged when no route exists
- [x] 2.1a In `addBranchPath()`, seed up to 3 random terrain tiles on empty cells adjacent to the branch path using `makeTerrainCell(at:)` and a sorted candidate list, and return them with the path cells; verify with tests that 3 new terrain cells appear adjacent to the branch, none replaces an existing cell, fewer are added when space is short, and none are added when no route exists
- [x] 2.1b Verify the round-end call site renders the seeded terrain cells (check the renderer handles terrain cells in `newCells`); confirm by launching the game and seeing tiles beside the new branch at round 10
- [x] 2.2 Verify a second branch opened later gets its own opening round and ramps independently, with a test covering two branches

## 3. Spawn loop

- [x] 3.1 In `GameState+Combat.swift` `update`, multiply the branch cell's spawn interval by `k` (both where the interval is first set and where it is re-rolled), leaving the start cell at k=1 and the RNG draw order unchanged; verify with a test that a ramping branch spawns fewer enemies than the main path over a simulated round
- [x] 3.2 Make a ramping branch (fewer than 10 rounds since opening) skip boss enemies when choosing the next enemy, so the boss spawns on another path; verify with a boss-round test that the boss never spawns on the ramping branch and still spawns in the wave
- [x] 3.3 Verify wave size is preserved: every enemy of a wave with a ramping branch still spawns, and the existing wave and branch tests still pass

## 4. Final check

- [x] 4.1 Run the full test suite and confirm it passes; build and launch the game to confirm items are granted when the branch opens at round 10
