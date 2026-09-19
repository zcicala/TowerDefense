//
//  GameState+Abilities.swift
//  TestGame
//
//  Manually-activated castle abilities (spells) cast during combat.
//

import Foundation

extension GameState {

    // MARK: - Activation flow

    /// Begins targeting for an ability (from a HUD button or number-key hotkey). Succeeds only in
    /// combat when the ability is unlocked, off cooldown, and nothing else is pending.
    @discardableResult
    func beginAbility(_ ability: CastleAbility) -> Bool {
        guard phase == .combat,
              pendingAbility == nil,
              abilityUnlocked(ability),
              abilityReady(ability) else { return false }
        pendingAbility = ability
        return true
    }

    /// Cancels an in-progress ability target selection.
    func cancelPendingAbility() {
        pendingAbility = nil
    }

    /// Resolves a cell-targeted pending ability at the tapped coord. No-op for tower-targeted
    /// abilities. Returns true when an ability was cast.
    @discardableResult
    func castPendingAbility(atCell coord: HexCoord) -> Bool {
        guard let ability = pendingAbility, !ability.targetsTower else { return false }
        switch ability {
        case .overcharge:  applyOvercharge(at: coord)
        case .freeze:      applyFreeze(at: coord)
        case .poison:      applyPoisonCloud(at: coord)
        case .gravityWave: applyGravityWave(at: coord)
        case .overchargeHeal: return false
        }
        finishCast(ability)
        return true
    }

    /// Resolves the tower-targeted pending ability (Overcharge Heal) on the tapped tower.
    /// Only a `.healer` tower is a valid target — tapping anything else leaves the ability
    /// pending so the player can pick a different tower instead of silently doing nothing.
    @discardableResult
    func castPendingAbility(onTower tower: Tower) -> Bool {
        guard let ability = pendingAbility, ability.targetsTower else { return false }
        guard tower.type == .healer else { return false }
        applyOverchargeHeal(on: tower)
        finishCast(ability)
        return true
    }

    /// Spends the ability's energy cost and clears the pending selection after a successful cast.
    private func finishCast(_ ability: CastleAbility) {
        castleEnergy = max(0, castleEnergy - ability.energyCost)
        pendingAbility = nil
    }

    // MARK: - Effects

    /// Overcharge: towers on or directly adjacent to `coord` fire twice as fast for the duration.
    private func applyOvercharge(at coord: HexCoord) {
        for tower in towers where tower.coord == coord || tower.coord.distance(to: coord) == 1 {
            tower.overchargeTimer = CastleAbility.overcharge.duration
        }
    }

    /// Freeze: fully stops enemies on `coord` and its six neighbors. Reuses the area-slow system
    /// (2 s duration) with `slowFactor: 0`, which wins over any weaker concurrent slow.
    private func applyFreeze(at coord: HexCoord) {
        let cells = [coord] + (0..<6).map { coord.neighbor($0) }
        applyAreaSlow(cells: cells, slowFactor: 0)
    }

    /// Overcharge Heal: temporarily boosts a healer tower's radius (to 3 tiles, 4 at max level
    /// — see `Tower.effectiveHealRadius`) and lets it heal for free, without spending a charge
    /// (see the healer branch of `update(deltaTime:)`). Duration scales with the tower's own
    /// level — a more-upgraded healer gets a longer window — rather than the fixed constant
    /// every other ability uses.
    private func applyOverchargeHeal(on tower: Tower) {
        tower.overchargeHealTimer = 5 * Float(tower.level)
    }

    /// Gravity Well: pull nearby enemies toward `coord` and hold them there for the duration.
    /// Gravity Wave: opens a field of increased gravity at `coord` for the duration. The field
    /// doesn't move or hold enemies — it's a passive area that changes how hoppers jump, how
    /// high flyers hover, and what can target them while they're standing inside it. See
    /// `updateGravityWaveField`, `triggerHopperJump`, `Enemy.effectiveHoverOffset`, and
    /// `Enemy.immuneTowerTypes`.
    private func applyGravityWave(at coord: HexCoord) {
        gravityWaveCoord = coord
        gravityWaveTimer = CastleAbility.gravityWave.duration
    }

    /// Poison: opens a cloud at `coord` that lasts `CastleAbility.poison.duration` seconds —
    /// see `updatePoisonCloud(deltaTime:)` for how it actually infects enemies each frame.
    private func applyPoisonCloud(at coord: HexCoord) {
        poisonCloudCoord = coord
        poisonCloudTimer = CastleAbility.poison.duration
    }

    /// Existing (already-spawned) cells within the poison cloud's radius of `center`, with their
    /// heights. Purely for placing the visual particle effect — gameplay poisoning below just
    /// compares hex distance directly, without needing to enumerate cells.
    func poisonCloudCells(around center: HexCoord) -> [(coord: HexCoord, height: Float)] {
        var result: [(coord: HexCoord, height: Float)] = []
        let radius = poisonCloudRadius
        for dq in -radius...radius {
            let rLow = max(-radius, -dq - radius)
            let rHigh = min(radius, -dq + radius)
            for dr in rLow...rHigh {
                let coord = HexCoord(q: center.q + dq, r: center.r + dr)
                guard let cell = hexGrid.cell(at: coord) else { continue }
                result.append((coord, cell.height))
            }
        }
        return result
    }

    /// Existing cells within the Gravity Wave field's radius of `center`, with their heights —
    /// for placing the persistent ground-field visual. Mirrors `poisonCloudCells`; gameplay
    /// itself (`updateGravityWaveField`) compares hex distance directly and doesn't need this.
    func gravityWaveCells(around center: HexCoord) -> [(coord: HexCoord, height: Float)] {
        var result: [(coord: HexCoord, height: Float)] = []
        let radius = gravityWaveRadius
        for dq in -radius...radius {
            let rLow = max(-radius, -dq - radius)
            let rHigh = min(radius, -dq + radius)
            for dr in rLow...rHigh {
                let coord = HexCoord(q: center.q + dq, r: center.r + dr)
                guard let cell = hexGrid.cell(at: coord) else { continue }
                result.append((coord, cell.height))
            }
        }
        return result
    }

    // MARK: - Per-frame update (called from update(deltaTime:))

    /// Regenerates castle energy toward its current max.
    func tickCastleEnergy(deltaTime: Float) {
        castleEnergy = min(castleMaxEnergy, castleEnergy + castleEnergyRegenRate * deltaTime)
    }

    /// Poison Cloud: while active, any enemy standing within `poisonCloudRadius` of the cast
    /// center becomes poisoned, refreshing their `poisonTimer` to the full `poisonDOTDuration`
    /// for as long as they keep re-entering. The cloud itself only lasts for the ability's own
    /// `duration` (5s); the poison DOT it applies is free to outlive the cloud (10s).
    func updatePoisonCloud(deltaTime: Float) {
        guard poisonCloudTimer > 0, let center = poisonCloudCoord else { return }
        poisonCloudTimer = max(0, poisonCloudTimer - deltaTime)
        if poisonCloudTimer <= 0 { poisonCloudCoord = nil }

        for enemy in enemies where enemy.active {
            guard let coord = enemyNearestCoord(enemy), coord.distance(to: center) <= poisonCloudRadius else { continue }
            enemy.poisoned = true
            enemy.poisonTimer = poisonDOTDuration
            enemy.poisonDPS = enemy.maxHitPoints * 0.01  // 1% of max HP per second
        }
    }

    /// Ticks the Gravity Wave field's timer and marks every enemy currently standing inside it
    /// (`Enemy.inGravityWave`) — unlike the ability it replaced, the field never moves or holds
    /// enemies; it's a passive area read by `triggerHopperJump` (restricts jump range to 1),
    /// `Enemy.effectiveHoverOffset` (halves flying height), and `Enemy.immuneTowerTypes`
    /// (removes flying units' immunity to ground towers) for as long as an enemy stays in it.
    func updateGravityWaveField(deltaTime: Float) {
        if gravityWaveTimer > 0 {
            gravityWaveTimer = max(0, gravityWaveTimer - deltaTime)
        }
        let center = gravityWaveTimer > 0 ? gravityWaveCoord : nil
        for enemy in enemies where enemy.active {
            guard let center, let coord = enemyNearestCoord(enemy) else {
                enemy.inGravityWave = false
                continue
            }
            enemy.inGravityWave = coord.distance(to: center) <= gravityWaveRadius
        }
    }

    /// Clears all transient ability state (called when a new round starts).
    func resetAbilities() {
        castleEnergy = castleMaxEnergy
        pendingAbility = nil
        gravityWaveCoord = nil
        gravityWaveTimer = 0
        for enemy in enemies {
            enemy.inGravityWave = false
        }
        poisonCloudCoord = nil
        poisonCloudTimer = 0
        for tower in towers {
            tower.overchargeTimer = 0
            tower.overchargeHealTimer = 0
        }
    }
}
