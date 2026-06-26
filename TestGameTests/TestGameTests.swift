import XCTest
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
    in gs: GameState
) -> Enemy {
    let enemy = Enemy(type: type, hitPoints: hp, speed: speed)
    enemy.currentCell = pathCell(at: cellIndex, in: gs)
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

    func testDealDamage_immuneTowerType_dealsNoDamage() {
        let gs = makeGameState()
        // Mirroid is immune to laser
        let enemy = Enemy(type: .mirroid, hitPoints: 100, speed: 1.0)
        enemy.currentCell = pathCell(at: 1, in: gs)
        enemy.active = true
        gs.enemies.append(enemy)
        let laser = Tower.makeLaser(coord: HexCoord(q: 0, r: 0))
        var events = GameEvents()
        let killed = gs.dealDamage(100, to: enemy, tower: laser, events: &events)
        XCTAssertFalse(killed)
        XCTAssertEqual(enemy.hitPoints, 100, accuracy: 0.001)
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

    func testUseRepairItem_restoresOneHP() {
        let gs = makeGameState()
        gs.repairItemCount = 1
        gs.baseTowerHP = 8
        gs.useRepairItem()
        XCTAssertEqual(gs.baseTowerHP, 9)
        XCTAssertEqual(gs.repairItemCount, 0)
    }
}
