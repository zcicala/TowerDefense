# Spec Delta

## Purpose

Defines how a newly opened branch path is brought online fairly: the player is given the means to defend it, and enemies reach it gradually instead of taking half of every wave at once.

## ADDED Requirements

### Requirement: Opening a branch seeds buildable terrain
When a branch path is successfully opened, the system SHALL add a few random terrain tiles (three, if there is room) on empty cells adjacent to the new branch path, so towers can be placed beside it. The tiles SHALL NOT replace any existing cell, including path and no-build cells. The tiles SHALL be shown to the player like other terrain.

#### Scenario: Branch opened
- **WHEN** a branch path is opened at the end of a round
- **THEN** about three new terrain tiles exist next to the branch path
- **AND** each is a buildable terrain tile adjacent to a branch path cell

#### Scenario: Little free space
- **WHEN** fewer than three empty cells are adjacent to the branch
- **THEN** only the available empty cells are filled

#### Scenario: Existing cells untouched
- **WHEN** terrain is seeded beside a branch
- **THEN** no existing path, start, end, no-build or terrain cell is replaced

### Requirement: Opening a branch grants build items
When a branch path is successfully opened, the system SHALL grant the player one Spawn Tiles item and two Move Tower items. No items SHALL be granted when no branch could be opened.

#### Scenario: Branch opened
- **WHEN** a branch path is opened at the end of a round
- **THEN** the player's Spawn Tiles count increases by 1
- **AND** the player's Move Tower count increases by 2

#### Scenario: No room for a branch
- **WHEN** a branch is due but no valid route exists
- **THEN** no branch is opened, no terrain is seeded and no items are granted

### Requirement: Branch spawn share ramps up over time
A branch's share of each wave SHALL start at 15% in the first round after it opens and increase linearly to 50% (an equal share with the main path) ten rounds later, then stay at 50%. The share is realized by stretching the branch's spawn interval; enemies the branch does not take SHALL spawn on the other paths, so the total number of enemies in a wave is unchanged.

#### Scenario: First round after opening
- **WHEN** a branch opened at the end of round 10 and round 11 begins
- **THEN** the branch's spawn share is 15%

#### Scenario: Fully ramped
- **WHEN** ten or more rounds have passed since a branch opened
- **THEN** the branch's spawn share is 50%

#### Scenario: Wave size is preserved
- **WHEN** a wave is fought with a ramping branch
- **THEN** every enemy of the wave still spawns, split between the available paths

### Requirement: Branches ramp independently
Each branch SHALL ramp from the round it opened, regardless of other branches.

#### Scenario: Second branch
- **WHEN** a second branch opens ten rounds after the first
- **THEN** the first branch is at 50% share and the second is at 15%

### Requirement: Bosses avoid a ramping branch
While a branch is still ramping (fewer than ten rounds since it opened), the system SHALL NOT spawn the boss on it. The boss SHALL spawn on another path instead.

#### Scenario: Boss round during ramp
- **WHEN** a boss round occurs while a branch is ramping
- **THEN** the boss spawns on the main path (or a fully ramped branch), not on the ramping branch

#### Scenario: Fully ramped branch
- **WHEN** a branch is at its full share
- **THEN** it may spawn the boss like any other path

### Requirement: Restart clears branch ramp state
Starting a new game SHALL remove all branches' ramp state, so branches opened in a later game ramp from the start.

#### Scenario: Restart
- **WHEN** the game is restarted
- **THEN** no branch has an opening round recorded and no branch spawn cells remain
