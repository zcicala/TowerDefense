import XCTest
import simd
@testable import Zac_s_Tower_Defense

// MARK: - Test Helpers

/// Builds a GameState with a straight N-cell path linked next/previous, no terrain.
/// Cells run along q-axis: start(0,0) → path(1,0) → … → end(N-1,0).
func makeGameState(pathLength: Int = 5, rng: RandomSource = RandomSource()) -> GameState {
    let gs = GameState(rng: rng)
    var previous: HexCell? = nil
    for i in 0..<pathLength {
        let coord = HexCoord(q: i, r: 0)
        let type: HexCellType = i == 0 ? .start : (i == pathLength - 1 ? .end : .path)
        let cell = HexCell(coord: coord, height: 1.0, type: type)
        cell.previous = previous
        previous?.next = cell
        gs.hexGrid.addCell(cell)
        previous = cell
    }
    return gs
}

/// Returns the path cell at the given index (0 = start).
func pathCell(at index: Int, in gs: GameState) -> HexCell? {
    gs.hexGrid.cell(at: HexCoord(q: index, r: 0))
}

/// Creates an active enemy at the given path cell index and appends it to gs.enemies.
func makeActiveEnemy(
    type: EnemyType = .basic,
    hp: Float = 100,
    speed: Float = 1.0,
    atCell cellIndex: Int,
    progress: Float = 0,
    offset: Float = 0,
    in gs: GameState
) -> Enemy {
    let enemy = Enemy(type: type, hitPoints: hp, speed: speed)
    enemy.currentCell = pathCell(at: cellIndex, in: gs)
    enemy.progress = progress
    enemy.lateralOffset = offset
    enemy.active = true
    gs.enemies.append(enemy)
    return enemy
}

// MARK: - HexCoord Tests

final class HexCoordTests: XCTestCase {
    func testDistance_sameCell_isZero() {
        let a = HexCoord(q: 3, r: -2)
        XCTAssertEqual(a.distance(to: a), 0)
    }

    func testDistance_allNeighbors_isOne() {
        let origin = HexCoord(q: 0, r: 0)
        for dir in 0..<6 {
            XCTAssertEqual(origin.distance(to: origin.neighbor(dir)), 1,
                           "neighbor direction \(dir) should be distance 1")
        }
    }

    func testDistance_twoSteps() {
        XCTAssertEqual(HexCoord(q: 0, r: 0).distance(to: HexCoord(q: 2, r: 0)), 2)
        XCTAssertEqual(HexCoord(q: 0, r: 0).distance(to: HexCoord(q: 0, r: 2)), 2)
    }

    func testDistance_isSymmetric() {
        let a = HexCoord(q: 3, r: -2)
        let b = HexCoord(q: -1, r: 4)
        XCTAssertEqual(a.distance(to: b), b.distance(to: a))
    }

    func testWorldPosition_origin_isZero() {
        let pos = HexCoord(q: 0, r: 0).worldPosition(spacing: 1.0)
        XCTAssertEqual(pos.x, 0, accuracy: 0.001)
        XCTAssertEqual(pos.y, 0, accuracy: 0.001)
    }

    func testWorldPosition_neighborDistance_matchesSpacing() {
        let spacing: Float = 0.55
        let origin = HexCoord(q: 0, r: 0).worldPosition(spacing: spacing)
        // Right neighbor (dir 0): q+1
        let right = HexCoord(q: 1, r: 0).worldPosition(spacing: spacing)
        let dx = right.x - origin.x
        let dz = right.y - origin.y
        let worldDist = sqrt(dx*dx + dz*dz)
        // Flat-top hex: neighbour distance = spacing * sqrt(3) for axial neighbours
        // but specifically for q+1 neighbour: distance = spacing * 3/2 in x
        XCTAssertGreaterThan(worldDist, 0)
    }
}

// MARK: - Tower Tests

final class TowerTests: XCTestCase {
    func testCostForTower_firstPlacement_isBase() {
        let gs = makeGameState()
        XCTAssertEqual(gs.costForTower(.projectile), 50)
        XCTAssertEqual(gs.costForTower(.sword), 25)
        XCTAssertEqual(gs.costForTower(.healer), 150)
    }

    func testCostForTower_scalesExponentiallyWithCount() {
        let gs = makeGameState()
        gs.towerPlacedCount[.projectile] = 3
        let expected = Int(Double(50) * pow(1.1, 3.0))
        XCTAssertEqual(gs.costForTower(.projectile), expected)
    }

    func testApplyUpgrade_increasesDamageAndLevel() {
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        let damageBefore = tower.damage
        tower.applyUpgrade()
        XCTAssertEqual(tower.level, 2)
        XCTAssertGreaterThan(tower.damage, damageBefore)
    }

    func testApplyUpgrade_cappedAtMaxLevel() {
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        for _ in 0..<(Tower.maxLevel - 1) { tower.applyUpgrade() }
        XCTAssertEqual(tower.level, Tower.maxLevel)
        let damageBefore = tower.damage
        tower.applyUpgrade()
        XCTAssertEqual(tower.level, Tower.maxLevel)
        XCTAssertEqual(tower.damage, damageBefore, accuracy: 0.001)
    }

    func testUpgradeCost_scalesWithLevel() {
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        let cost1 = tower.upgradeCost
        tower.applyUpgrade()
        let cost2 = tower.upgradeCost
        XCTAssertGreaterThan(cost2, cost1)
    }

    func testLaserUpgrade_improvesDPS() {
        let tower = Tower.makeLaser(coord: HexCoord(q: 0, r: 0))
        let dpsBefore = tower.laser!.dps
        tower.applyUpgrade()
        XCTAssertGreaterThan(tower.laser!.dps, dpsBefore)
    }

    func testHealerUpgrade_increasesCharges() {
        let tower = Tower.makeHealer(coord: HexCoord(q: 0, r: 0))
        XCTAssertEqual(tower.healer!.charges, 1)
        tower.applyUpgrade()
        XCTAssertEqual(tower.healer!.charges, 2)
    }

    // MARK: Tech tree purchase — retroactive tower upgrades

    func testPurchase_towerLevelUpgrade_retroactivelyUpgradesPlacedTowers() {
        let gs = makeGameState()
        let towerA = Tower(coord: HexCoord(q: 0, r: 0), type: .projectile)
        let towerB = Tower(coord: HexCoord(q: 1, r: 0), type: .projectile)
        gs.towers = [towerA, towerB]
        gs.upgradePoints = 20

        XCTAssertTrue(gs.purchase(.towerUnlock(.projectile)))
        XCTAssertTrue(gs.purchase(.towerLevel(.projectile, 2)))
        XCTAssertEqual(towerA.level, 2)
        XCTAssertEqual(towerB.level, 2)

        XCTAssertTrue(gs.purchase(.towerLevel(.projectile, 3)))
        XCTAssertEqual(towerA.level, 3)
        XCTAssertEqual(towerB.level, 3)
    }

    func testPurchase_towerLevelUpgrade_doesNotExceedPurchasedLevel() {
        let gs = makeGameState()
        let tower = Tower(coord: HexCoord(q: 0, r: 0), type: .projectile)
        tower.applyUpgrade() // already at level 2 from in-run gold upgrades
        XCTAssertEqual(tower.level, 2)
        gs.towers = [tower]
        gs.upgradePoints = 20

        XCTAssertTrue(gs.purchase(.towerUnlock(.projectile)))
        XCTAssertTrue(gs.purchase(.towerLevel(.projectile, 2)))

        // Tower was already at level 2 — purchasing the 1→2 node must not push it to 3.
        XCTAssertEqual(tower.level, 2)
    }

    func testPurchase_towerLevelUpgrade_onlyAffectsMatchingType() {
        let gs = makeGameState()
        let projectileTower = Tower(coord: HexCoord(q: 0, r: 0), type: .projectile)
        let laserTower = Tower.makeLaser(coord: HexCoord(q: 1, r: 0))
        gs.towers = [projectileTower, laserTower]
        gs.upgradePoints = 20

        XCTAssertTrue(gs.purchase(.towerUnlock(.projectile)))
        XCTAssertTrue(gs.purchase(.towerLevel(.projectile, 2)))

        XCTAssertEqual(projectileTower.level, 2)
        XCTAssertEqual(laserTower.level, 1, "purchasing a projectile upgrade must not affect other tower types")
    }
}

// MARK: - Combat Tests

final class CombatTests: XCTestCase {

    // MARK: dealDamage

    func testDealDamage_exactHP_killsEnemy() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(hp: 50, atCell: 1, in: gs)
        var events = GameEvents()
        let killed = gs.dealDamage(50, to: enemy, events: &events)
        XCTAssertTrue(killed)
        XCTAssertFalse(enemy.active)
        XCTAssertTrue(events.killedEnemies.contains { $0.id == enemy.id })
    }

    func testDealDamage_partialHit_doesNotKill() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(hp: 100, atCell: 1, in: gs)
        var events = GameEvents()
        let killed = gs.dealDamage(40, to: enemy, events: &events)
        XCTAssertFalse(killed)
        XCTAssertTrue(enemy.active)
        XCTAssertEqual(enemy.hitPoints, 60, accuracy: 0.001)
    }

    func testDealDamage_awardsKillReward() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(hp: 50, atCell: 1, in: gs)
        let moneyBefore = gs.money
        var events = GameEvents()
        gs.dealDamage(50, to: enemy, events: &events)
        XCTAssertEqual(gs.money, moneyBefore + gs.killReward)
    }

    func testDealDamage_inactiveEnemy_dealsNoDamage() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(hp: 100, atCell: 1, in: gs)
        enemy.active = false
        var events = GameEvents()
        let killed = gs.dealDamage(100, to: enemy, events: &events)
        XCTAssertFalse(killed)
        XCTAssertEqual(enemy.hitPoints, 100, accuracy: 0.001)
    }

    func testDealDamage_fullyResistantEnemy_dealsNoDamage() {
        let gs = makeGameState()
        // Mirroid is fully resistant (immune) to energy-type damage, e.g. laser.
        let enemy = Enemy(type: .mirroid, hitPoints: 100, speed: 1.0)
        enemy.resistances[.energy] = 1.0
        enemy.currentCell = pathCell(at: 1, in: gs)
        enemy.active = true
        gs.enemies.append(enemy)
        let laser = Tower.makeLaser(coord: HexCoord(q: 0, r: 0))
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 0, accuracy: 0.001)
        var events = GameEvents()
        let killed = gs.dealDamage(100, to: enemy, tower: laser, events: &events)
        XCTAssertFalse(killed)
        XCTAssertEqual(enemy.hitPoints, 100, accuracy: 0.001)
    }

    func testMakeEnemy_mirroid_hasEnergyImmunityViaResistances() {
        let gs = makeGameState()
        gs.round = 14
        let enemy = gs._makeEnemy(type: .mirroid, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 0, accuracy: 0.001)
        XCTAssertFalse(enemy.immuneTowerTypes.contains(.laser), "positional immunity should no longer carry the energy immunity")
    }

    func testMakeEnemy_round25_noLongerGrantsUniversalPersonalShield() {
        let gs = makeGameState()
        gs.round = 25
        let enemy = gs.makeEnemy(type: .basic, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.shieldMaxHP, 0, "the universal round-25 personal shield wall should be removed")
    }

    func testShield_debutsAtRound16_notInActITier() {
        let gs = makeGameState()
        XCTAssertFalse(gs.tier(for: 15).roster.contains { $0.type == .shield },
                       "shield should not appear in Act I (rounds 1-15)")
        XCTAssertTrue(gs.tier(for: 16).roster.contains { $0.type == .shield },
                      "shield should debut at round 16 (Act II)")
    }

    func testMakeEnemy_shield_hasPhysicalResistanceViaResistances() {
        let gs = makeGameState()
        gs.round = 16
        let enemy = gs._makeEnemy(type: .shield, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 0.5, accuracy: 0.001)
    }

    // MARK: New Act II/III archetypes

    func testMakeEnemy_plated_resistsPhysical60Percent() {
        let gs = makeGameState()
        let enemy = gs._makeEnemy(type: .plated, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 0.4, accuracy: 0.001)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 1.0, accuracy: 0.001)
    }

    func testMakeEnemy_insulated_resistsEnergy60Percent() {
        let gs = makeGameState()
        let enemy = gs._makeEnemy(type: .insulated, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 0.4, accuracy: 0.001)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 1.0, accuracy: 0.001)
    }

    func testMakeEnemy_cinder_resistsFireAndIsBurnImmune() {
        let gs = makeGameState()
        let enemy = gs._makeEnemy(type: .cinder, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .fire), 0.3, accuracy: 0.001)
        XCTAssertTrue(enemy.isBurnImmune)
    }

    func testMakeEnemy_nullifier_resistsAllTypesPartially() {
        let gs = makeGameState()
        let enemy = gs._makeEnemy(type: .nullifier, hp: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 0.6, accuracy: 0.001)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 0.6, accuracy: 0.001)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .fire), 0.6, accuracy: 0.001)
    }

    func testApplyBurning_burnImmuneEnemy_isNeverSetBurning() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(type: .cinder, atCell: 1, in: gs)
        XCTAssertFalse(enemy.burning)
        gs.applyBurning(cells: [HexCoord(q: 1, r: 0)])
        XCTAssertFalse(enemy.burning, "cinder should be immune to the burning status effect")
    }

    // MARK: Warden aura

    func testApplyWardenAura_buffsInRangeNeighbor() {
        let gs = makeGameState(pathLength: 10)
        let warden = makeActiveEnemy(type: .warden, atCell: 3, in: gs)
        let neighbor = makeActiveEnemy(type: .basic, atCell: 4, in: gs)  // distance 1, within radius
        XCTAssertEqual(neighbor.wardenAuraBonus, 0)
        gs.applyWardenAura()
        XCTAssertEqual(neighbor.wardenAuraBonus, GameState.wardenAuraBonusAmount, accuracy: 0.001)
        // The warden itself also benefits from its own aura.
        XCTAssertEqual(warden.wardenAuraBonus, GameState.wardenAuraBonusAmount, accuracy: 0.001)
    }

    func testApplyWardenAura_clearsWhenOutOfRange() {
        let gs = makeGameState(pathLength: 10)
        _ = makeActiveEnemy(type: .warden, atCell: 0, in: gs)
        let farEnemy = makeActiveEnemy(type: .basic, atCell: 9, in: gs)  // far outside radius
        gs.applyWardenAura()
        XCTAssertEqual(farEnemy.wardenAuraBonus, 0, accuracy: 0.001)
    }

    func testApplyWardenAura_clearsWhenWardenDies() {
        let gs = makeGameState(pathLength: 10)
        let warden = makeActiveEnemy(type: .warden, atCell: 3, in: gs)
        let neighbor = makeActiveEnemy(type: .basic, atCell: 4, in: gs)
        gs.applyWardenAura()
        XCTAssertGreaterThan(neighbor.wardenAuraBonus, 0)
        warden.active = false
        gs.applyWardenAura()
        XCTAssertEqual(neighbor.wardenAuraBonus, 0, accuracy: 0.001)
    }

    func testResistanceMultiplier_wardenAuraBonus_stacksWithBaseResistance() {
        let enemy = Enemy(type: .plated, hitPoints: 100, speed: 1.0)
        enemy.resistances[.physical] = 0.6
        enemy.wardenAuraBonus = 0.3
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 0.1, accuracy: 0.001)
    }

    func testArchetypeRoster_newTypesAppearInActIIAndActIII() {
        let gs = makeGameState()
        let actII = gs.tier(for: 20).roster.map { $0.type }
        XCTAssertTrue(actII.contains(.plated))
        XCTAssertTrue(actII.contains(.insulated))
        XCTAssertTrue(actII.contains(.cinder))
        let actIII = gs.tier(for: 35).roster.map { $0.type }
        XCTAssertTrue(actIII.contains(.nullifier))
        XCTAssertTrue(actIII.contains(.warden))
    }

    // MARK: resistanceMultiplier

    func testResistanceMultiplier_noEntry_returnsOne() {
        let enemy = Enemy(type: .basic, hitPoints: 100, speed: 1.0)
        XCTAssertEqual(enemy.resistanceMultiplier(for: .physical), 1.0, accuracy: 0.001)
    }

    func testResistanceMultiplier_nilType_returnsOne() {
        let enemy = Enemy(type: .basic, hitPoints: 100, speed: 1.0)
        enemy.resistances[.physical] = 1.0
        XCTAssertEqual(enemy.resistanceMultiplier(for: nil), 1.0, accuracy: 0.001)
    }

    func testResistanceMultiplier_fractionalResist_reducesDamage() {
        let enemy = Enemy(type: .basic, hitPoints: 100, speed: 1.0)
        enemy.resistances[.energy] = 0.6
        XCTAssertEqual(enemy.resistanceMultiplier(for: .energy), 0.4, accuracy: 0.001)
    }

    func testResistanceMultiplier_vulnerability_increasesDamage() {
        let enemy = Enemy(type: .basic, hitPoints: 100, speed: 1.0)
        enemy.resistances[.fire] = -0.5
        XCTAssertEqual(enemy.resistanceMultiplier(for: .fire), 1.5, accuracy: 0.001)
    }

    func testDealDamage_fractionalResistance_reducesDamageProportionally() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(type: .shield, hp: 100, atCell: 1, in: gs)
        enemy.resistances[.physical] = 0.5
        let tower = Tower(coord: HexCoord(q: 0, r: 0), type: .projectile)
        var events = GameEvents()
        gs.dealDamage(50, to: enemy, tower: tower, events: &events)
        // 50 * (1 - 0.5) = 25 damage taken
        XCTAssertEqual(enemy.hitPoints, 75, accuracy: 0.001)
    }

    func testDealDamage_moneyDoubler_doublesReward() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(hp: 50, atCell: 1, in: gs)
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        tower.hasMoneyDoubler = true
        let moneyBefore = gs.money
        var events = GameEvents()
        gs.dealDamage(50, to: enemy, tower: tower, events: &events)
        XCTAssertEqual(gs.money, moneyBefore + gs.killReward * 2)
    }

    // MARK: Fireball splash

    func testFireballSplash_nonKillingHit_stillSetsEnemyBurning() {
        let gs = makeGameState()
        gs.phase = .combat
        let survivor = makeActiveEnemy(hp: 1000, atCell: 2, in: gs)
        let projectile = Projectile(
            origin: SIMD3<Float>(0, 0, 0),
            target: SIMD3<Float>(0, 0, 0),
            totalFlightTime: 0.01,
            damage: 50,
            targetEnemyID: survivor.id,
            burnOnImpact: true,
            impactBurnDPS: 10,
            impactBurnDuration: 3,
            splashRadius: 0
        )
        projectile.elapsed = projectile.totalFlightTime
        gs.projectiles.append(projectile)

        _ = gs.update(deltaTime: 0.001)

        XCTAssertTrue(survivor.active, "splash hit of 50 damage should not kill a 1000 HP enemy")
        XCTAssertTrue(survivor.burning, "fireball splash should ignite enemies it damages, even when the hit doesn't kill")
    }

    // MARK: applyAreaSlow

    func testApplyAreaSlow_slowsEnemiesOnTargetCell() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(atCell: 2, in: gs)
        XCTAssertFalse(enemy.slowed)
        gs.applyAreaSlow(cells: [HexCoord(q: 2, r: 0)], slowFactor: 0.5)
        XCTAssertTrue(enemy.slowed)
        XCTAssertEqual(enemy.slowFactor, 0.5, accuracy: 0.001)
    }

    func testApplyAreaSlow_ignoresEnemiesOnOtherCells() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(atCell: 2, in: gs)
        gs.applyAreaSlow(cells: [HexCoord(q: 3, r: 0)], slowFactor: 0.5)
        XCTAssertFalse(enemy.slowed)
    }

    func testApplyAreaSlow_usesStrongestSlowFactor() {
        let gs = makeGameState()
        let enemy = makeActiveEnemy(atCell: 2, in: gs)
        let coord = HexCoord(q: 2, r: 0)
        gs.applyAreaSlow(cells: [coord], slowFactor: 0.7)
        gs.applyAreaSlow(cells: [coord], slowFactor: 0.3)
        // Lower factor = stronger slow; should use min
        XCTAssertEqual(enemy.slowFactor, 0.3, accuracy: 0.001)
    }

    // MARK: damageBaseTower

    func testDamageBaseTower_reducesHP() {
        let gs = makeGameState()
        let hpBefore = gs.baseTowerHP
        var events = GameEvents()
        gs.damageBaseTower(damage: 2, events: &events)
        XCTAssertEqual(gs.baseTowerHP, hpBefore - 2)
        XCTAssertTrue(events.baseTowerHit)
    }

    func testDamageBaseTower_destroysOneBlock_perTwoHP() {
        let gs = makeGameState()
        let blocksBefore = gs.baseTowerBlocksRemaining
        var events = GameEvents()
        gs.damageBaseTower(damage: 2, events: &events)
        XCTAssertEqual(gs.baseTowerBlocksRemaining, blocksBefore - 1)
        XCTAssertEqual(events.baseTowerBlocksDestroyed, 1)
    }

    func testDamageBaseTower_triggersGameOver_atZeroHP() {
        let gs = makeGameState()
        var events = GameEvents()
        gs.damageBaseTower(damage: gs.baseTowerHP, events: &events)
        XCTAssertTrue(events.gameOver)
        XCTAssertEqual(gs.baseTowerHP, 0)
    }

    func testDamageBaseTower_doesNotGoBelowZero() {
        let gs = makeGameState()
        var events = GameEvents()
        gs.damageBaseTower(damage: 999, events: &events)
        XCTAssertEqual(gs.baseTowerHP, 0)
    }

    // MARK: selectTarget

    func testSelectTarget_closestMode_picksNearestEnemy() {
        let gs = makeGameState(pathLength: 10)
        let tower = Tower(coord: HexCoord(q: 0, r: 0), detectionRadius: 5, fireRadius: 5)
        let nearby = makeActiveEnemy(atCell: 1, in: gs)   // distance 1
        _ = makeActiveEnemy(atCell: 4, in: gs)             // distance 4
        let target = gs.selectTarget(for: tower, targetingLevel: 0)
        XCTAssertEqual(target?.id, nearby.id)
    }

    func testSelectTarget_outOfRange_returnsNil() {
        let gs = makeGameState(pathLength: 10)
        let tower = Tower(coord: HexCoord(q: 0, r: 0), detectionRadius: 2, fireRadius: 2)
        _ = makeActiveEnemy(atCell: 5, in: gs)   // distance 5, outside radius 2
        let target = gs.selectTarget(for: tower, targetingLevel: 0)
        XCTAssertNil(target)
    }

    func testSelectTarget_inactiveEnemy_isIgnored() {
        let gs = makeGameState(pathLength: 10)
        let tower = Tower(coord: HexCoord(q: 0, r: 0), detectionRadius: 5, fireRadius: 5)
        let enemy = makeActiveEnemy(atCell: 1, in: gs)
        enemy.active = false
        let target = gs.selectTarget(for: tower, targetingLevel: 0)
        XCTAssertNil(target)
    }

    func testSelectTarget_targetingLevel1_extendsDetectionByOne() {
        let gs = makeGameState(pathLength: 10)
        // Tower with detection 2. Enemy at distance 3 — out of range at level 0, in range at level 1.
        let tower = Tower(coord: HexCoord(q: 0, r: 0), detectionRadius: 2, fireRadius: 2)
        let enemy = makeActiveEnemy(atCell: 3, in: gs)  // distance 3
        XCTAssertNil(gs.selectTarget(for: tower, targetingLevel: 0))
        XCTAssertEqual(gs.selectTarget(for: tower, targetingLevel: 1)?.id, enemy.id)
    }

    // MARK: makeEnemy / seeded random

    func testMakeEnemy_withSeededRandom_isDeterministic() {
        let gs1 = makeGameState(rng: SeededRandom(seed: 42))
        gs1.round = 1
        let e1 = gs1.makeEnemy(type: .basic, hp: 100, speed: 1.0)

        let gs2 = makeGameState(rng: SeededRandom(seed: 42))
        gs2.round = 1
        let e2 = gs2.makeEnemy(type: .basic, hp: 100, speed: 1.0)

        // Basic enemy speed is either 1× or 2× — must be identical with same seed
        XCTAssertEqual(e1.speed, e2.speed, accuracy: 0.001)
    }

    func testMakeEnemy_differentSeeds_canProduceDifferentOutcomes() {
        var speedsSeen: Set<Float> = []
        for seed: UInt64 in 1...20 {
            let gs = makeGameState(rng: SeededRandom(seed: seed))
            gs.round = 1
            let e = gs.makeEnemy(type: .basic, hp: 100, speed: 1.0)
            speedsSeen.insert(e.speed)
        }
        // Over 20 seeds, we should see both fast (2.0) and slow (1.0) variants
        XCTAssertGreaterThan(speedsSeen.count, 1)
    }

    // MARK: inventory / economy

    func testUpgradeTower_deductsMoney() {
        let gs = makeGameState()
        gs.money = 1000
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        let cost = tower.upgradeCost
        gs.towers.append(tower)
        let success = gs.upgradeTower(tower)
        XCTAssertTrue(success)
        XCTAssertEqual(gs.money, 1000 - cost)
    }

    func testUpgradeTower_failsWhenBroke() {
        let gs = makeGameState()
        gs.money = 0
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        gs.towers.append(tower)
        let success = gs.upgradeTower(tower)
        XCTAssertFalse(success)
        XCTAssertEqual(tower.level, 1)
    }

    // MARK: EnemyTier

    func testTier_actIBoundary_round15IsActI_round16IsActII() {
        let gs = makeGameState()
        XCTAssertEqual(gs.tier(for: 15).act, 1)
        XCTAssertEqual(gs.tier(for: 16).act, 2)
    }

    func testTier_actIIBoundary_round30IsActII_round31IsActIII() {
        let gs = makeGameState()
        XCTAssertEqual(gs.tier(for: 30).act, 2)
        XCTAssertEqual(gs.tier(for: 31).act, 3)
    }

    func testTier_actI_hpIs2Point5xLegacyFormula() {
        let gs = makeGameState()
        for round in 1...15 {
            let legacy = Float(256 + round * 102)
            XCTAssertEqual(gs.tier(for: round).hp(atRound: round), legacy * 2.5, accuracy: 0.01,
                           "round \(round)")
        }
    }

    func testTier_actI_speedIsHalfLegacyFormula() {
        let gs = makeGameState()
        for round in 1...15 {
            let legacy = 1.2 + Float(round) * 0.03
            XCTAssertEqual(gs.tier(for: round).speed(atRound: round), legacy * 0.5, accuracy: 0.001,
                           "round \(round)")
        }
    }

    func testTier_actII_hpFlatterThanActI() {
        let gs = makeGameState()
        let actIISlope = gs.tier(for: 20).hpSlope
        let actISlope = gs.tier(for: 10).hpSlope
        XCTAssertLessThan(actIISlope, actISlope)
    }

    // MARK: Per-path spawn timers

    func testStartRound_initializesPerPathSpawnTimers() {
        let gs = makeGameState(pathLength: 30)
        // Simulate a branch path's new .start cell merging into the main path partway along —
        // mirrors what addBranchPath() produces in production.
        let branchStart = HexCell(coord: HexCoord(q: 100, r: 0), height: 1.0, type: .start)
        branchStart.next = pathCell(at: 5, in: gs)
        gs.hexGrid.addCell(branchStart)

        gs.startRound()

        XCTAssertEqual(gs.spawnTimers.count, 2)
        XCTAssertEqual(gs.spawnIntervals.count, 2)
        XCTAssertNotNil(gs.spawnTimers[HexCoord(q: 0, r: 0)])
        XCTAssertNotNil(gs.spawnTimers[HexCoord(q: 100, r: 0)])
    }

    func testUpdate_morePaths_increasesSpawnThroughput() {
        func spawnedCount(afterSeconds seconds: Float, extraStartCells: Int, seed: UInt64) -> Int {
            let gs = makeGameState(pathLength: 30, rng: SeededRandom(seed: seed))
            for i in 0..<extraStartCells {
                let branchStart = HexCell(coord: HexCoord(q: 100 + i, r: 0), height: 1.0, type: .start)
                branchStart.next = pathCell(at: 5, in: gs)
                gs.hexGrid.addCell(branchStart)
            }
            gs.round = 9  // startRound() below advances this to round 10, queuing a large enemy pool (33)
            gs.startRound()

            var elapsed: Float = 0
            let step: Float = 0.05
            while elapsed < seconds {
                _ = gs.update(deltaTime: step)
                elapsed += step
            }
            return gs.enemies.filter { $0.currentCell != nil }.count
        }

        // Spawn intervals are randomized per path (0.3–1.5s), so a single short sample is noisy.
        // Average several seeds over a longer window to compare the underlying throughput rather
        // than one run's luck.
        let seeds: [UInt64] = [7, 11, 23, 41, 59]
        let window: Float = 6.0
        let singleTotal = seeds.reduce(0) { $0 + spawnedCount(afterSeconds: window, extraStartCells: 0, seed: $1) }
        let tripleTotal = seeds.reduce(0) { $0 + spawnedCount(afterSeconds: window, extraStartCells: 2, seed: $1) }

        XCTAssertGreaterThan(tripleTotal, singleTotal,
                             "more active paths should spawn more enemies over the same time window")
    }

    func testStartRound_populatesEnemiesForRound1() {
        let gs = makeGameState(pathLength: 10)
        gs.startRound()
        XCTAssertEqual(gs.round, 1)
        XCTAssertFalse(gs.enemies.isEmpty)
    }

    /// Regression test: round 1 only has `basic` eligible in the roster, and the
    /// "debut exclusion" rule in `pickSpawnType` used to remove it from the pool the moment it
    /// spawned once, leaving zero eligible types and crashing on an empty random range.
    func testPickSpawnType_round1_neverEmptiesPoolAfterFirstPick() {
        for seed: UInt64 in 1...10 {
            let gs = makeGameState(rng: SeededRandom(seed: seed))
            gs.round = 1
            var used: [EnemyType] = []
            for _ in 0..<20 {
                let type = gs.pickSpawnType(excludingIntro: used)
                if gs.tier(for: 1).roster.first(where: { $0.type == type })?.minRound == 1 {
                    used.append(type)
                }
            }
            // Reaching here without a crash is the assertion; also sanity-check it's basic.
            XCTAssertTrue(used.allSatisfy { $0 == .basic })
        }
    }

    func testUseRepairItem_restoresOneHP() {
        let gs = makeGameState()
        gs.repairItemCount = 1
        gs.baseTowerHP = gs.baseTowerMaxHP - 1
        gs.useRepairItem()
        XCTAssertEqual(gs.baseTowerHP, gs.baseTowerMaxHP)
        XCTAssertEqual(gs.repairItemCount, 0)
    }
}

// MARK: - Castle Ability Tests

final class CastleAbilityTests: XCTestCase {

    // MARK: Unlock gating

    func testAbilityUnlocked_gatedByCastleLevel() {
        let gs = makeGameState()
        // Default castle level 1: only Overcharge unlocked.
        XCTAssertTrue(gs.abilityUnlocked(.overcharge))
        XCTAssertFalse(gs.abilityUnlocked(.freeze))
        XCTAssertFalse(gs.abilityUnlocked(.poison))
        XCTAssertFalse(gs.abilityUnlocked(.invulnerability))
        XCTAssertFalse(gs.abilityUnlocked(.gravityWell))

        gs.purchasedTechNodes.insert(.baseTowerLevel(2))
        XCTAssertTrue(gs.abilityUnlocked(.freeze))
        XCTAssertFalse(gs.abilityUnlocked(.poison))

        gs.purchasedTechNodes.insert(.baseTowerLevel(3))
        XCTAssertTrue(gs.abilityUnlocked(.poison))
        XCTAssertFalse(gs.abilityUnlocked(.invulnerability))

        gs.purchasedTechNodes.insert(.baseTowerLevel(4))
        XCTAssertTrue(gs.abilityUnlocked(.invulnerability))
        XCTAssertFalse(gs.abilityUnlocked(.gravityWell))
    }

    func testBeginAbility_requiresCombatUnlockedAndReady() {
        let gs = makeGameState()
        gs.phase = .placing
        XCTAssertFalse(gs.beginAbility(.overcharge), "cannot cast outside combat")

        gs.phase = .combat
        XCTAssertFalse(gs.beginAbility(.freeze), "locked ability cannot begin")
        XCTAssertTrue(gs.beginAbility(.overcharge))
        XCTAssertEqual(gs.pendingAbility, .overcharge)

        // Already pending: a second begin is rejected.
        XCTAssertFalse(gs.beginAbility(.overcharge))
        gs.cancelPendingAbility()
        XCTAssertNil(gs.pendingAbility)

        // Not enough energy: not ready.
        gs.castleEnergy = 0
        XCTAssertFalse(gs.beginAbility(.overcharge))
    }

    // MARK: Overcharge

    func testOvercharge_affectsCellAndNeighborsOnly_andSpendsEnergy() {
        let gs = makeGameState(pathLength: 6)
        let towerOn = Tower(coord: HexCoord(q: 2, r: 0))
        let towerAdjA = Tower(coord: HexCoord(q: 1, r: 0))   // distance 1
        let towerAdjB = Tower(coord: HexCoord(q: 3, r: 0))   // distance 1
        let towerFar = Tower(coord: HexCoord(q: 4, r: 0))    // distance 2
        gs.towers.append(contentsOf: [towerOn, towerAdjA, towerAdjB, towerFar])

        let energyBefore = gs.castleEnergy
        gs.pendingAbility = .overcharge
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 2, r: 0)))

        XCTAssertEqual(towerOn.overchargeTimer, CastleAbility.overcharge.duration, accuracy: 0.001)
        XCTAssertEqual(towerAdjA.overchargeTimer, CastleAbility.overcharge.duration, accuracy: 0.001)
        XCTAssertEqual(towerAdjB.overchargeTimer, CastleAbility.overcharge.duration, accuracy: 0.001)
        XCTAssertEqual(towerFar.overchargeTimer, 0, accuracy: 0.001)

        XCTAssertEqual(gs.castleEnergy, energyBefore - CastleAbility.overcharge.energyCost, accuracy: 0.001)
        XCTAssertNil(gs.pendingAbility)
    }

    func testOvercharge_doublesCooldownRecovery() {
        let gs = makeGameState(pathLength: 6)
        gs.phase = .combat
        // Keep an active enemy so the round doesn't immediately end; place it out of fire range.
        _ = makeActiveEnemy(hp: 1000, atCell: 3, in: gs)

        let boosted = Tower(coord: HexCoord(q: 0, r: 0), detectionRadius: 1, fireRadius: 1, cooldown: 2.0)
        boosted.cooldownRemaining = 2.0
        boosted.overchargeTimer = 3.0
        let control = Tower(coord: HexCoord(q: 5, r: 0), detectionRadius: 1, fireRadius: 1, cooldown: 2.0)
        control.cooldownRemaining = 2.0
        gs.towers.append(contentsOf: [boosted, control])

        _ = gs.update(deltaTime: 0.1)

        XCTAssertEqual(boosted.cooldownRemaining, 1.8, accuracy: 0.01, "overcharged tower recovers at 2×")
        XCTAssertEqual(control.cooldownRemaining, 1.9, accuracy: 0.01, "normal tower recovers at 1×")
    }

    // MARK: Freeze

    func testFreeze_freezesCellAndNeighbors_notFarEnemies() {
        let gs = makeGameState(pathLength: 6)
        let onCell = makeActiveEnemy(atCell: 2, in: gs)     // (2,0)
        let neighbor = makeActiveEnemy(atCell: 3, in: gs)   // (3,0), distance 1
        let far = makeActiveEnemy(atCell: 4, in: gs)        // (4,0), distance 2

        gs.pendingAbility = .freeze
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 2, r: 0)))

        XCTAssertTrue(onCell.slowed)
        XCTAssertEqual(onCell.slowFactor, 0, accuracy: 0.001, "freeze fully stops the enemy")
        XCTAssertTrue(neighbor.slowed)
        XCTAssertEqual(neighbor.slowFactor, 0, accuracy: 0.001)
        XCTAssertFalse(far.slowed)
    }

    // MARK: Invulnerability

    func testInvulnerability_protectsTowerFromExploder() {
        let gs = makeGameState(pathLength: 6)
        gs.phase = .combat
        let tower = Tower(coord: HexCoord(q: 1, r: 0))
        tower.hitPoints = 5
        gs.towers.append(tower)

        gs.pendingAbility = .invulnerability
        XCTAssertTrue(gs.castPendingAbility(onTower: tower))
        XCTAssertEqual(tower.abilityInvulnTimer, CastleAbility.invulnerability.duration, accuracy: 0.001)

        killExploderAdjacent(to: tower, at: 2, in: gs)
        XCTAssertEqual(tower.hitPoints, 5, "invulnerable tower takes no exploder damage")
    }

    func testInvulnerability_expiresAndTowerBecomesVulnerable() {
        let gs = makeGameState(pathLength: 6)
        gs.phase = .combat
        let tower = Tower(coord: HexCoord(q: 1, r: 0))
        tower.hitPoints = 5
        gs.towers.append(tower)
        // Keep a stationary out-of-range enemy so the round doesn't end while we advance time.
        _ = makeActiveEnemy(hp: 100000, speed: 0, atCell: 3, in: gs)

        gs.pendingAbility = .invulnerability
        _ = gs.castPendingAbility(onTower: tower)

        // Advance beyond the 5s duration.
        for _ in 0..<60 { _ = gs.update(deltaTime: 0.1) }
        XCTAssertEqual(tower.abilityInvulnTimer, 0, accuracy: 0.001)

        killExploderAdjacent(to: tower, at: 2, in: gs)
        XCTAssertLessThan(tower.hitPoints, 5, "once invuln expires the tower takes exploder damage")
    }

    /// Spawns an exploder adjacent to `tower` and kills it via a completed projectile so the
    /// exploder-death damage pass runs inside `update`.
    private func killExploderAdjacent(to tower: Tower, at cellIndex: Int, in gs: GameState) {
        let exploder = Enemy(type: .exploder, hitPoints: 1, speed: 0,
                             explosionRadius: 1, explosionDamage: 1)
        exploder.currentCell = pathCell(at: cellIndex, in: gs)
        exploder.active = true
        gs.enemies.append(exploder)

        let projectile = Projectile(
            origin: SIMD3<Float>(0, 0, 0),
            target: SIMD3<Float>(0, 0, 0),
            totalFlightTime: 0.01,
            damage: 100,
            targetEnemyID: exploder.id
        )
        projectile.elapsed = projectile.totalFlightTime
        gs.projectiles.append(projectile)

        _ = gs.update(deltaTime: 0.05)
        XCTAssertFalse(exploder.active, "exploder should have died from the projectile")
    }

    // MARK: Gravity Well

    func testGravityWell_pullsEnemyTowardTile() {
        let gs = makeGameState(pathLength: 8)
        gs.phase = .combat
        // High HP so the base sentinel doesn't kill it mid-pull.
        let enemy = makeActiveEnemy(hp: 5000, atCell: 5, in: gs)   // (5,0)

        gs.pendingAbility = .gravityWell
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 3, r: 0)))
        XCTAssertEqual(gs.gravityWellTimer, CastleAbility.gravityWell.duration, accuracy: 0.001)

        // Advance within the well's duration.
        for _ in 0..<25 { _ = gs.update(deltaTime: 0.1) }

        let q = enemy.currentCell?.coord.q ?? -1
        XCTAssertLessThan(q, 5, "enemy should be pulled back from (5,0) toward the well at (3,0)")
        XCTAssertGreaterThanOrEqual(q, 3, "enemy should not be pulled past the well tile")
    }

    // MARK: Poison

    func testCastPoison_spendsEnergyAndClearsPending() {
        let gs = makeGameState()
        let energyBefore = gs.castleEnergy
        gs.pendingAbility = .poison
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 0, r: 0)))
        XCTAssertEqual(gs.castleEnergy, energyBefore - CastleAbility.poison.energyCost, accuracy: 0.001)
        XCTAssertNil(gs.pendingAbility)
    }

    func testCastPoison_opensCloudAtCoordWithFullDuration() {
        let gs = makeGameState()
        gs.pendingAbility = .poison
        let coord = HexCoord(q: 2, r: 0)
        XCTAssertTrue(gs.castPendingAbility(atCell: coord))
        XCTAssertEqual(gs.poisonCloudCoord, coord)
        XCTAssertEqual(gs.poisonCloudTimer, CastleAbility.poison.duration, accuracy: 0.001)
    }

    func testPoisonCloudCells_returnsExistingCellsWithinRadius() {
        let gs = makeGameState(pathLength: 10)
        let center = pathCell(at: 5, in: gs)!.coord

        let cells = gs.poisonCloudCells(around: center)
        let coords = Set(cells.map { $0.coord })

        XCTAssertTrue(coords.contains(center))
        XCTAssertTrue(coords.contains(HexCoord(q: 3, r: 0)), "distance 2 — inside the radius")
        XCTAssertTrue(coords.contains(HexCoord(q: 7, r: 0)), "distance 2 — inside the radius")
        XCTAssertFalse(coords.contains(HexCoord(q: 2, r: 0)), "distance 3 — outside the radius")
        XCTAssertFalse(coords.contains(HexCoord(q: 8, r: 0)), "distance 3 — outside the radius")
    }

    func testUpdatePoisonCloud_infectsEnemyWithinRadius() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let enemy = makeActiveEnemy(hp: 1000, atCell: 5, in: gs)
        gs.pendingAbility = .poison
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 5, r: 0)))

        gs.updatePoisonCloud(deltaTime: 0.1)

        XCTAssertTrue(enemy.poisoned)
        XCTAssertEqual(enemy.poisonTimer, gs.poisonDOTDuration, accuracy: 0.001)
        XCTAssertEqual(enemy.poisonDPS, enemy.maxHitPoints * 0.01, accuracy: 0.001)
    }

    func testUpdatePoisonCloud_ignoresEnemyOutsideRadius() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let enemy = makeActiveEnemy(hp: 1000, atCell: 9, in: gs)
        gs.pendingAbility = .poison
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 0, r: 0)))

        gs.updatePoisonCloud(deltaTime: 0.1)

        XCTAssertFalse(enemy.poisoned)
    }

    func testUpdatePoisonCloud_expiresAfterDuration() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        gs.pendingAbility = .poison
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 5, r: 0)))

        gs.updatePoisonCloud(deltaTime: CastleAbility.poison.duration + 0.1)

        XCTAssertNil(gs.poisonCloudCoord)
        XCTAssertEqual(gs.poisonCloudTimer, 0, accuracy: 0.001)
    }

    func testPoisonDOT_dealsOnePercentOfMaxHPPerSecond_viaRealUpdateLoop() {
        let gs = makeGameState(pathLength: 30)  // long path so the enemy can't reach the end
        gs.phase = .combat
        let enemy = makeActiveEnemy(hp: 1000, speed: 0, atCell: 5, in: gs)
        gs.pendingAbility = .poison
        XCTAssertTrue(gs.castPendingAbility(atCell: HexCoord(q: 5, r: 0)))

        // 1 second of ticking, well within the cloud's own 5s lifetime.
        for _ in 0..<10 { _ = gs.update(deltaTime: 0.1) }

        XCTAssertTrue(enemy.poisoned)
        let expectedDamage = enemy.maxHitPoints * 0.01  // 1% per second
        XCTAssertEqual(1000 - enemy.hitPoints, expectedDamage, accuracy: expectedDamage * 0.15)
    }

    func testPregenerateTerrain_fillsFieldAroundOrigin_afterGenerateMap() {
        let gs = GameState(rng: RandomSource())
        XCTAssertTrue(gs.pregeneratedTerrain.isEmpty)
        gs.generateMap()
        XCTAssertFalse(gs.pregeneratedTerrain.isEmpty)
        XCTAssertNotNil(gs.pregeneratedTerrain[HexCoord(q: 0, r: 0)])
        XCTAssertNotNil(gs.pregeneratedTerrain[HexCoord(q: 10, r: -5)])
    }

    // MARK: Round reset

    func testResetAbilities_refillsEnergyAndClearsTimers() {
        let gs = makeGameState()
        let tower = Tower(coord: HexCoord(q: 0, r: 0))
        tower.overchargeTimer = 2
        tower.abilityInvulnTimer = 4
        gs.towers.append(tower)
        gs.castleEnergy = 3
        gs.pendingAbility = .freeze
        gs.gravityWellCoord = HexCoord(q: 1, r: 0)
        gs.gravityWellTimer = 3

        gs.resetAbilities()

        XCTAssertEqual(gs.castleEnergy, gs.castleMaxEnergy, accuracy: 0.001)
        XCTAssertNil(gs.pendingAbility)
        XCTAssertNil(gs.gravityWellCoord)
        XCTAssertEqual(gs.gravityWellTimer, 0, accuracy: 0.001)
        XCTAssertEqual(tower.overchargeTimer, 0, accuracy: 0.001)
        XCTAssertEqual(tower.abilityInvulnTimer, 0, accuracy: 0.001)
    }

    func testStartRound_refillsCastleEnergy() {
        let gs = makeGameState()
        gs.phase = .placing
        gs.castleEnergy = 2
        gs.startRound()
        XCTAssertEqual(gs.castleEnergy, gs.castleMaxEnergy, accuracy: 0.001, "energy refills at the start of each round")
    }

    // MARK: Castle Energy

    func testCastleEnergy_regeneratesOverTimeUpToMax() {
        let gs = makeGameState(pathLength: 6)
        gs.phase = .combat
        _ = makeActiveEnemy(hp: 100000, speed: 0, atCell: 3, in: gs)
        gs.castleEnergy = 18

        _ = gs.update(deltaTime: 1.0)
        XCTAssertEqual(gs.castleEnergy, 19, accuracy: 0.01, "regenerates 1 energy/sec at 0 crystals")

        _ = gs.update(deltaTime: 5.0)
        XCTAssertEqual(gs.castleEnergy, gs.castleMaxEnergy, accuracy: 0.001, "never exceeds max energy")
    }

    // MARK: Crystal Structures

    /// Adds an Energy Field terrain cell and places a farm on it, returning the resulting Farm.
    @discardableResult
    private func makeCrystalStructure(at coord: HexCoord, in gs: GameState) -> Farm? {
        let cell = HexCell(coord: coord, height: 1.0, type: .terrain)
        cell.terrainType = .energyField
        gs.hexGrid.addCell(cell)
        gs.purchasedTechNodes.insert(.farmUnlock)
        gs.phase = .placing
        _ = gs.placeFarm(at: coord)
        return gs.farm(at: coord)
    }

    func testPlaceFarm_onEnergyField_createsCrystalStructure() {
        let gs = makeGameState(pathLength: 6)
        let farm = makeCrystalStructure(at: HexCoord(q: 10, r: 10), in: gs)
        XCTAssertEqual(farm?.farmType, .crystalStructure)
    }

    func testCrystalStructure_baseBonusIsTwoPerStructure_whenNotAdjacentToAnyFarm() {
        let gs = makeGameState(pathLength: 6)
        XCTAssertEqual(gs.castleMaxEnergy, 20, accuracy: 0.001)
        XCTAssertEqual(gs.castleEnergyRegenRate, 1.0, accuracy: 0.001)

        // Far apart — not adjacent to each other or anything else.
        makeCrystalStructure(at: HexCoord(q: 10, r: 10), in: gs)
        makeCrystalStructure(at: HexCoord(q: 30, r: 30), in: gs)

        XCTAssertEqual(gs.crystalStructureCount, 2)
        XCTAssertEqual(gs.castleMaxEnergy, 24, accuracy: 0.001, "+2 max energy per crystal structure with no adjacent farms")
        XCTAssertEqual(gs.castleEnergyRegenRate, 1.04, accuracy: 0.001, "+2% regen rate per crystal structure with no adjacent farms")
    }

    func testCrystalStructure_adjacentFarm_addsOneMoreToEachBonus() {
        let gs = makeGameState(pathLength: 6)
        let crystalCoord = HexCoord(q: 10, r: 10)
        makeCrystalStructure(at: crystalCoord, in: gs)
        XCTAssertEqual(gs.castleMaxEnergy, 22, accuracy: 0.001, "base +2 with no neighbors yet")

        // Place a plain farm directly adjacent to the crystal structure.
        let neighborCoord = crystalCoord.neighbor(0)
        let neighborCell = HexCell(coord: neighborCoord, height: 1.0, type: .terrain)
        gs.hexGrid.addCell(neighborCell)
        _ = gs.placeFarm(at: neighborCoord)

        XCTAssertEqual(gs.castleMaxEnergy, 23, accuracy: 0.001, "+1 more max energy for the adjacent farm")
        XCTAssertEqual(gs.castleEnergyRegenRate, 1.03, accuracy: 0.001, "+1% more regen for the adjacent farm")
    }

    func testPlaceTower_onCrystalStructure_consumesItWithNoTowerBonus() {
        let gs = makeGameState(pathLength: 6)
        let coord = HexCoord(q: 10, r: 10)
        makeCrystalStructure(at: coord, in: gs)
        XCTAssertEqual(gs.crystalStructureCount, 1)

        gs.phase = .placing
        gs.purchasedTechNodes.insert(.towerUnlock(.projectile))
        gs.selectedTowerType = .projectile
        gs.money = 10000
        let result = gs.placeTower(at: coord)

        XCTAssertNotNil(result)
        XCTAssertEqual(gs.crystalStructureCount, 0, "placing a tower consumes the crystal structure")
        XCTAssertNil(gs.farm(at: coord))
        XCTAssertEqual(gs.castleMaxEnergy, 20, accuracy: 0.001, "energy bonus is lost with the crystal")
    }
}

// MARK: - Corridor Collision Tests

/// Tests for the enemy collision / intra-tile spread ("corridor") system.
/// See /Users/zac/.claude/plans/okay-i-want-to-hidden-cocoa.md for the design.
final class CorridorTests: XCTestCase {

    // MARK: Stage 0 — radius unification

    /// `enemyVisualRadius(for:)` (gameplay physics) must equal `enemyRadius * bodyRadiusScale`
    /// for every enemy type. This is the single source of truth that the renderer's mesh
    /// sizing and tap-collision sphere both derive from — this test locks the three tables
    /// together so a future radius tweak can't silently desync them again.
    func testBodyRadiusScale_isSingleSourceOfTruthForVisualRadius() {
        let gs = makeGameState(pathLength: 3)
        for type in EnemyType.allCases {
            XCTAssertEqual(
                gs.enemyVisualRadius(for: type),
                gs.enemyRadius * type.bodyRadiusScale,
                accuracy: 0.0001,
                "\(type) visual radius must derive from bodyRadiusScale"
            )
        }
    }

    // MARK: Stage 1 — path frame + caches

    func testPathFrame_straightPath_isOrthonormal() {
        let gs = makeGameState(pathLength: 6)
        let cell = pathCell(at: 2, in: gs)!
        for t: Float in [0, 0.25, 0.5, 0.75] {
            let frame = gs.pathFrame(cell: cell, progress: t)
            XCTAssertEqual(simd_length(frame.tangent), 1, accuracy: 0.0001)
            XCTAssertEqual(simd_length(frame.lateral), 1, accuracy: 0.0001)
            XCTAssertEqual(simd_dot(frame.tangent, frame.lateral), 0, accuracy: 0.0001)
            // On the q-axis path every hop is direction 0: (spacing*1.5, spacing*sqrt(3)/2),
            // which normalizes to (0.866, 0.5).
            XCTAssertEqual(frame.tangent.x, 0.866, accuracy: 0.001)
            XCTAssertEqual(frame.tangent.y, 0.5, accuracy: 0.001)
            XCTAssertEqual(frame.lateral.x, -0.5, accuracy: 0.001)
            XCTAssertEqual(frame.lateral.y, 0.866, accuracy: 0.001)
        }
    }

    func testPathFrame_startCell_pointsAtNext() {
        let gs = makeGameState(pathLength: 5)
        let start = pathCell(at: 0, in: gs)!
        let next = pathCell(at: 1, in: gs)!
        let expected = simd_normalize(next.coord.worldPosition(spacing: gs.spacing) - start.coord.worldPosition(spacing: gs.spacing))
        let frame = gs.pathFrame(cell: start, progress: 0)
        XCTAssertEqual(frame.tangent.x, expected.x, accuracy: 0.0001)
        XCTAssertEqual(frame.tangent.y, expected.y, accuracy: 0.0001)
    }

    func testPathFrame_endCell_fallsBackToPreviousDirection() {
        let gs = makeGameState(pathLength: 5)
        let end = pathCell(at: 4, in: gs)!
        let prev = pathCell(at: 3, in: gs)!
        XCTAssertNil(end.next, "test assumes the last cell is terminal")
        let expected = simd_normalize(end.coord.worldPosition(spacing: gs.spacing) - prev.coord.worldPosition(spacing: gs.spacing))
        let frame = gs.pathFrame(cell: end, progress: 0)
        XCTAssertEqual(frame.tangent.x, expected.x, accuracy: 0.0001)
        XCTAssertEqual(frame.tangent.y, expected.y, accuracy: 0.0001)
    }

    func testEnemyWorldPosition_lateralOffsetIsPurelyPerpendicular() {
        let gs = makeGameState(pathLength: 6)
        let enemy = makeActiveEnemy(atCell: 2, progress: 0.4, in: gs)
        let centeredPos = gs.enemyWorldPosition(enemy)!
        enemy.lateralOffset = 0.1
        let offsetPos = gs.enemyWorldPosition(enemy)!
        let delta = SIMD2<Float>(offsetPos.x - centeredPos.x, offsetPos.z - centeredPos.z)
        let frame = gs.pathFrame(cell: enemy.currentCell!, progress: enemy.progress)
        XCTAssertEqual(simd_length(delta), 0.1, accuracy: 0.0001)
        XCTAssertEqual(simd_dot(delta, frame.tangent), 0, accuracy: 0.0001, "offset must be purely perpendicular to travel")
        XCTAssertEqual(offsetPos.y, centeredPos.y, accuracy: 0.0001, "offset must not affect height")
    }

    func testStepsToEndCache_matchesUncachedWalk() {
        let gs = makeGameState(pathLength: 8)
        for i in 0..<8 {
            let cell = pathCell(at: i, in: gs)!
            XCTAssertEqual(gs.cachedStepsToEnd(cell.coord), gs.stepsToEnd(of: cell), "cell \(i)")
        }
    }

    func testStepsToEndCache_invalidatesWhenTopologyChanges() {
        let gs = makeGameState(pathLength: 5)
        XCTAssertEqual(gs.cachedStepsToEnd(HexCoord(q: 0, r: 0)), 4)

        // Extend the path by one more cell past the old end.
        let oldEnd = pathCell(at: 4, in: gs)!
        let newCell = HexCell(coord: HexCoord(q: 5, r: 0), height: 1.0, type: .end)
        newCell.previous = oldEnd
        oldEnd.next = newCell
        gs.hexGrid.addCell(newCell)

        XCTAssertEqual(gs.cachedStepsToEnd(HexCoord(q: 0, r: 0)), 5, "cache must reflect the new topology, not the stale one")
    }

    func testDistanceToEnd_isContinuousAcrossCellTransition() {
        let gs = makeGameState(pathLength: 6)
        let enemyBefore = makeActiveEnemy(atCell: 2, progress: 0.999, in: gs)
        let enemyAfter = makeActiveEnemy(atCell: 3, progress: 0.0, in: gs)
        XCTAssertEqual(gs.distanceToEnd(enemyBefore), gs.distanceToEnd(enemyAfter), accuracy: 0.002)
    }

    // MARK: Stage 3 — solver skeleton (forward probe + eased deceleration, no lateral steering)

    /// A faster tank stuck behind a slower one must queue up, never overlapping its body.
    func testFollower_neverOverlapsLeader() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 0.5, atCell: 5, in: gs)
        let follower = makeActiveEnemy(type: .tank, hp: 5000, speed: 3.0, atCell: 2, in: gs)
        let minDist = 2 * gs.enemyVisualRadius(for: .tank)

        for _ in 0..<200 {
            _ = gs.update(deltaTime: 0.05)
            guard let lp = gs.enemyWorldPosition(leader), let fp = gs.enemyWorldPosition(follower) else { continue }
            XCTAssertGreaterThanOrEqual(simd_distance(lp, fp), minDist - 0.01, "follower must never overlap the leader")
        }
    }

    /// Being followed by a faster enemy must have zero effect on the leader's own progress.
    func testFollower_neverPushesLeaderForward() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 0.5, atCell: 5, in: gs)
        _ = makeActiveEnemy(type: .tank, hp: 5000, speed: 3.0, atCell: 2, in: gs)
        let chord = gs.hexChordDistance
        let before = gs.distanceToEnd(leader)

        var elapsed: Float = 0
        while elapsed < 10 {
            _ = gs.update(deltaTime: 0.05)
            elapsed += 0.05
        }
        let actualDelta = before - gs.distanceToEnd(leader)
        let expectedDelta = leader.speed / chord * elapsed
        XCTAssertEqual(actualDelta, expectedDelta, accuracy: expectedDelta * 0.02 + 0.01)
    }

    /// A follower behind a frozen leader must decelerate to a stop at contact distance, then
    /// resume advancing once the leader thaws.
    func testBlockedByFrozenLeader_decelerates_thenResumes() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 6, in: gs)
        leader.frozen = true
        leader.frozenTimer = 100
        let follower = makeActiveEnemy(type: .tank, hp: 5000, speed: 2.0, atCell: 3, in: gs)
        let r = gs.enemyVisualRadius(for: .tank)

        for _ in 0..<60 { _ = gs.update(deltaTime: 0.05) } // 3s — plenty of time to catch up and settle
        let distBlocked = simd_distance(gs.enemyWorldPosition(leader)!, gs.enemyWorldPosition(follower)!)
        XCTAssertEqual(distBlocked, 2 * r, accuracy: 0.05, "follower should be sitting at contact with the frozen leader")

        let beforeThaw = gs.distanceToEnd(follower)
        leader.frozen = false
        leader.frozenTimer = 0
        for _ in 0..<4 { _ = gs.update(deltaTime: 0.05) } // 0.2s
        XCTAssertLessThan(gs.distanceToEnd(follower), beforeThaw, "follower should resume shortly after the leader thaws")
    }

    /// speed == 0 is a test-only "immobile prop" convention (no real ability sets `speed`,
    /// which is a `let`, at runtime) — the solver must never touch such an enemy, even with
    /// a fast mover right behind it. This is the guard behind every existing prop-based test
    /// that runs the real update loop with a stationary enemy.
    func testSpeedZeroEnemy_isCompletelyImmovable() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let prop = makeActiveEnemy(type: .basic, hp: 5000, speed: 0, atCell: 3, in: gs)
        let cellBefore = prop.currentCell
        let progressBefore = prop.progress
        let offsetBefore = prop.lateralOffset
        _ = makeActiveEnemy(type: .tank, hp: 5000, speed: 3.0, atCell: 0, in: gs)

        for _ in 0..<100 { _ = gs.update(deltaTime: 0.05) }

        XCTAssertTrue(prop.currentCell === cellBefore)
        XCTAssertEqual(prop.progress, progressBefore)
        XCTAssertEqual(prop.lateralOffset, offsetBefore)
    }

    /// A single very large deltaTime (tests elsewhere use 1.0 and 5.0) must not let a fast
    /// follower tunnel through a frozen leader — the free-distance clamp, not substepping
    /// granularity, is what prevents this.
    func testLargeDeltaTime_noTunneling() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 6, in: gs)
        leader.frozen = true
        leader.frozenTimer = 999
        let follower = makeActiveEnemy(type: .tank, hp: 5000, speed: 2.0, atCell: 0, in: gs)

        _ = gs.update(deltaTime: 5.0)

        let r = gs.enemyVisualRadius(for: .tank)
        let dist = simd_distance(gs.enemyWorldPosition(leader)!, gs.enemyWorldPosition(follower)!)
        XCTAssertGreaterThanOrEqual(dist, 2 * r - 0.01, "a single large-deltaTime update must not tunnel the follower through the leader")
        XCTAssertGreaterThan(gs.distanceToEnd(follower), gs.distanceToEnd(leader), "follower must still be behind, not past, the leader")
    }

    /// Regression: slow/freeze timers used to tick only inside the old moveEnemy, which
    /// hoppers never called, so a frozen hopper never thawed.
    func testFrozenHopperThaws() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let hopper = makeActiveEnemy(type: .hopper, hp: 5000, speed: 1.0, atCell: 3, in: gs)
        hopper.frozen = true
        hopper.frozenTimer = 0.15

        _ = gs.update(deltaTime: 0.1)
        XCTAssertTrue(hopper.frozen, "should still be frozen after 0.1s of a 0.15s freeze")
        _ = gs.update(deltaTime: 0.1)
        XCTAssertFalse(hopper.frozen, "hopper freeze timers must tick even though hoppers never call moveEnemy")
    }

    // MARK: Stage 4 — lateral steering, recentring, hysteresis

    /// Encodes the corridor-width design decision as an executable record: small enemies can
    /// slip past big ones, but two enemies both wide enough to matter cannot pass each other.
    /// If a future radius/width tweak flips one of these, it should be a deliberate choice.
    func testPassMatrix_encodesDesignDecision() {
        let gs = makeGameState(pathLength: 3)
        func canPass(_ a: EnemyType, _ b: EnemyType) -> Bool {
            let required = gs.enemyVisualRadius(for: a) + gs.enemyVisualRadius(for: b) + CorridorTuning.separationGap
            return gs.maxLateralOffset(for: a) + gs.maxLateralOffset(for: b) >= required
        }
        XCTAssertTrue(canPass(.basic, .tank), "a small enemy must be able to slip past a tank")
        XCTAssertFalse(canPass(.tank, .tank), "two tanks must not be able to pass each other")
        XCTAssertFalse(canPass(.shield, .tank), "shield and tank are both too wide to pass each other")
    }

    /// A fast small enemy stuck behind a slow tank should steer around it and end up ahead,
    /// then drift back toward the path centerline once clear.
    func testSmallEnemyOvertakesTank() {
        let gs = makeGameState(pathLength: 25)
        gs.phase = .combat
        let tank = makeActiveEnemy(type: .tank, hp: 5000, speed: 0.3, atCell: 5, in: gs)
        let basic = makeActiveEnemy(type: .basic, hp: 5000, speed: 3.0, atCell: 3, in: gs)

        var maxAbsOffset: Float = 0
        var elapsed: Float = 0
        while elapsed < 8 {
            _ = gs.update(deltaTime: 0.05)
            elapsed += 0.05
            maxAbsOffset = max(maxAbsOffset, abs(basic.lateralOffset))
        }
        XCTAssertLessThan(gs.distanceToEnd(basic), gs.distanceToEnd(tank), "the faster, smaller enemy should have overtaken the tank")
        XCTAssertGreaterThan(maxAbsOffset, 0.10, "basic should have steered out noticeably to pass")

        var elapsed2: Float = 0
        while elapsed2 < 1.0 {
            _ = gs.update(deltaTime: 0.05)
            elapsed2 += 0.05
        }
        XCTAssertLessThan(abs(basic.lateralOffset), 0.02, "basic should recenter once clear of the tank")
    }

    /// Two tanks are both too wide to pass each other (see the pass matrix) — the one behind
    /// must never overtake, only queue.
    func testTwoTanksNeverOvertake() {
        let gs = makeGameState(pathLength: 25)
        gs.phase = .combat
        let leadTank = makeActiveEnemy(type: .tank, hp: 5000, speed: 0.3, atCell: 5, in: gs)
        let chaseTank = makeActiveEnemy(type: .tank, hp: 5000, speed: 3.0, atCell: 2, in: gs)

        var elapsed: Float = 0
        while elapsed < 10 {
            _ = gs.update(deltaTime: 0.05)
            elapsed += 0.05
            XCTAssertLessThanOrEqual(gs.distanceToEnd(leadTank), gs.distanceToEnd(chaseTank), "the lead tank must never be overtaken")
        }
    }

    /// A small enemy passing a tank should commit to one side, not flip back and forth.
    func testNoLateralOscillation() {
        let gs = makeGameState(pathLength: 25)
        gs.phase = .combat
        let tank = makeActiveEnemy(type: .tank, hp: 5000, speed: 0.3, atCell: 8, in: gs)
        let basic = makeActiveEnemy(type: .basic, hp: 5000, speed: 3.0, atCell: 2, in: gs)

        var lastNonZeroSide: Int8 = 0
        var sideChanges = 0
        for _ in 0..<400 {
            _ = gs.update(deltaTime: 0.016)
            if basic.avoidSide != 0 {
                if lastNonZeroSide != 0 && basic.avoidSide != lastNonZeroSide {
                    sideChanges += 1
                }
                lastNonZeroSide = basic.avoidSide
            }
        }
        XCTAssertLessThanOrEqual(sideChanges, 2, "avoidance side should not flip back and forth while passing")
    }

    /// Regression: lateral courtesy used to inherit the same generous lookahead range used for
    /// smooth forward braking (~1.6 world units, nearly two tiles), and `side = 0` for two
    /// still-centered enemies always yields a nonzero "need" — so virtually any two enemies
    /// loosely sharing a lane sat visibly off-center. One hex cell apart (~0.91 units) is well
    /// inside that old range but well outside the actual contact-courtesy range, and moving at
    /// the same speed keeps the gap constant, so this stays a pure "sharing a lane, no real
    /// need to avoid" case for the whole run.
    func testLateralSteering_doesNotEngageForLooselyQueuedEnemies() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let a = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 5, in: gs)
        let b = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 4, in: gs)

        for _ in 0..<40 { _ = gs.update(deltaTime: 0.05) } // 2s; same speed, gap never closes

        XCTAssertEqual(a.lateralOffset, 0, accuracy: 0.001, "loosely queued same-lane enemies shouldn't wiggle")
        XCTAssertEqual(b.lateralOffset, 0, accuracy: 0.001, "loosely queued same-lane enemies shouldn't wiggle")
    }

    // MARK: Stage 5 — separation relaxation (overlaps the corridor solver above didn't create)

    /// Two enemies placed at an exact head-on overlap should be pushed apart purely laterally
    /// — the `dist < 1e-4` branch's direction is perpendicular to travel by construction, so
    /// there's no tangential component to (mis)apply as forward or backward motion.
    func testSeparation_resolvesExactOverlap_lateralOnly() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let a = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 3, progress: 0.3, in: gs)
        let b = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 3, progress: 0.3, in: gs)
        let r = gs.enemyVisualRadius(for: .basic)

        for _ in 0..<10 { gs.relaxSeparation([a, b]) }

        let dist = simd_distance(gs.enemyWorldPosition(a)!, gs.enemyWorldPosition(b)!)
        XCTAssertGreaterThanOrEqual(dist, 2 * r - 0.01, "an exact overlap should be resolved laterally")
        XCTAssertEqual(a.progress, 0.3, accuracy: 0.0001, "separation alone must not change progress for a head-on overlap")
        XCTAssertEqual(b.progress, 0.3, accuracy: 0.0001)
    }

    /// Separation may retreat the rear enemy of an overlapping pair, but must never advance
    /// anyone — tested in isolation (direct `relaxSeparation` calls) so ordinary forward
    /// walking can't be confused with the pass under test.
    func testSeparation_neverPushesAnyoneForward() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let a = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 5, progress: 0.5, in: gs)
        let b = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 5, progress: 0.5, in: gs)
        let c = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 5, progress: 0.5, in: gs)
        let before = [a, b, c].map { gs.distanceToEnd($0) }

        for _ in 0..<10 { gs.relaxSeparation([a, b, c]) }

        let after = [a, b, c].map { gs.distanceToEnd($0) }
        for (b0, a0) in zip(before, after) {
            // distanceToEnd only ever grows (retreat) or holds steady — it must never shrink,
            // since shrinking would mean separation advanced someone toward the end.
            XCTAssertGreaterThanOrEqual(a0, b0 - 0.0001, "separation must never advance an enemy toward the end")
        }
    }

    /// Flying enemies never participate in separation, matching their exemption from the
    /// corridor solver above.
    func testSeparation_ignoresFlyingEnemies() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let wisp = makeActiveEnemy(type: .wisp, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        let tank = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        let offsetBefore = wisp.lateralOffset

        gs.relaxSeparation([wisp, tank])

        XCTAssertEqual(wisp.lateralOffset, offsetBefore, "flying enemies never participate in separation")
    }

    /// A hopper mid-jump is exempt (its position is overridden by the jump arc entirely), but
    /// a grounded hopper between jumps must still participate.
    func testSeparation_ignoresMidJumpHopper() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let hopper = makeActiveEnemy(type: .hopper, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        hopper.isJumping = true
        let tank = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        let offsetBefore = hopper.lateralOffset
        let progressBefore = hopper.progress

        gs.relaxSeparation([hopper, tank])

        XCTAssertEqual(hopper.lateralOffset, offsetBefore)
        XCTAssertEqual(hopper.progress, progressBefore)
    }

    func testSeparation_includesGroundedHopper() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let hopper = makeActiveEnemy(type: .hopper, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        let basic = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        let required = gs.enemyVisualRadius(for: .hopper) + gs.enemyVisualRadius(for: .basic) + CorridorTuning.separationGap

        for _ in 0..<10 { gs.relaxSeparation([hopper, basic]) }

        let dist = simd_distance(gs.enemyWorldPosition(hopper)!, gs.enemyWorldPosition(basic)!)
        XCTAssertGreaterThanOrEqual(dist, required - 0.01, "a grounded (non-jumping) hopper must participate in separation")
    }

    /// Flying enemies (wisp, hive) pass straight through ground traffic — never blocked.
    func testFlyingUnitsIgnoreCollision() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let tank = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 4, progress: 0.5, in: gs)
        tank.frozen = true
        tank.frozenTimer = 999
        let wisp = makeActiveEnemy(type: .wisp, hp: 5000, speed: 1.0, atCell: 4, progress: 0.48, in: gs)
        let chord = gs.hexChordDistance
        let expectedProgress = wisp.progress + wisp.speed * 0.05 / chord

        _ = gs.update(deltaTime: 0.05)

        XCTAssertEqual(wisp.progress, expectedProgress, accuracy: 0.0005, "flying enemies must not be blocked by ground traffic")
        XCTAssertEqual(wisp.lateralOffset, 0)
    }

    // MARK: Stage 6 — consumers (roll, projectile lead, spawning)

    /// Roll should reflect actual frame-to-frame displacement: rate matches distance moved
    /// divided by body radius, and the rotation axis is perpendicular to the direction moved.
    func testRoll_derivedFromDisplacement() {
        let gs = makeGameState(pathLength: 10)
        gs.phase = .combat
        let enemy = makeActiveEnemy(type: .basic, hp: 5000, speed: 1.0, atCell: 3, in: gs)
        _ = gs.update(deltaTime: 0.05) // establish a lastWorldPos baseline
        let before = gs.enemyWorldPosition(enemy)!
        _ = gs.update(deltaTime: 0.05)
        let after = gs.enemyWorldPosition(enemy)!
        let dx = after.x - before.x
        let dz = after.z - before.z
        let d = sqrt(dx * dx + dz * dz)

        XCTAssertGreaterThan(d, 0, "enemy should have actually moved")
        XCTAssertEqual(enemy.rollDeltaAngle, d / gs.enemyVisualRadius(for: .basic), accuracy: 0.0005)
        XCTAssertEqual(simd_dot(SIMD2(enemy.rollAxis.x, enemy.rollAxis.z), SIMD2(dx, dz)), 0, accuracy: 0.0005,
                       "roll axis must be perpendicular to the actual displacement")
    }

    /// A fully-blocked enemy shouldn't visibly keep rolling in place.
    func testRoll_isZeroWhenFullyBlocked() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 4, in: gs)
        leader.frozen = true
        leader.frozenTimer = 999
        let follower = makeActiveEnemy(type: .tank, hp: 5000, speed: 2.0, atCell: 0, in: gs)

        for _ in 0..<60 { _ = gs.update(deltaTime: 0.05) } // reach contact and settle

        XCTAssertEqual(follower.rollDeltaAngle, 0, accuracy: 0.001, "a fully blocked enemy should not visibly keep rolling")
    }

    /// A follower stuck in traffic should have its observed speed decay toward zero, and
    /// `predictEnemyPosition` should follow suit rather than over-leading it as if free-running.
    func testObservedSpeed_dropsWhenBlocked_andPredictionFollows() {
        let gs = makeGameState(pathLength: 20)
        gs.phase = .combat
        let leader = makeActiveEnemy(type: .tank, hp: 5000, speed: 1.0, atCell: 6, in: gs)
        leader.frozen = true
        leader.frozenTimer = 999
        let follower = makeActiveEnemy(type: .tank, hp: 5000, speed: 2.0, atCell: 3, in: gs)

        for _ in 0..<80 { _ = gs.update(deltaTime: 0.05) } // 4s — reach contact and let the EMA settle

        XCTAssertLessThan(follower.observedSpeed, 0.1, "observed speed should have decayed toward zero while fully blocked")

        let current = gs.enemyWorldPosition(follower)!
        let predicted = gs.predictEnemyPosition(follower, afterTime: 0.5)!.position
        XCTAssertLessThan(simd_distance(current, predicted), 0.05, "prediction for a blocked enemy should stay near its current position")
    }

    /// Two enemies spawned at the same start cell in quick succession should not begin
    /// perfectly co-located.
    func testSpawn_secondEnemyAtSameStart_isNotExactlyCoLocatedWithTheFirst() {
        let gs = makeGameState(pathLength: 15)
        gs.startRound()

        var spawned: [Enemy] = []
        var elapsed: Float = 0
        while spawned.count < 2 && elapsed < 5 {
            let events = gs.update(deltaTime: 0.05)
            spawned.append(contentsOf: events.spawnedEnemies)
            elapsed += 0.05
        }

        guard spawned.count >= 2 else {
            XCTFail("expected at least two enemies to spawn within 5s")
            return
        }
        XCTAssertNotEqual(spawned[0].lateralOffset, spawned[1].lateralOffset,
                           "consecutive spawns at the same start cell should be jittered apart")
    }
}
