//
//  GameState.swift
//  TestGame

import Foundation
import Observation
import simd

enum GamePhase {
    case placing   // Player places towers
    case combat    // Enemies are spawning/moving, towers firing
    case roundOver // All enemies defeated or escaped
}

/// Owns the hex grid and all game logic.
@Observable
class GameState {
    let hexGrid = HexGrid()

    let hexRadius: Float = 0.5
    let gap: Float = 0.05
    let pathLength = 25
    let terrainRings = 2

    var spacing: Float { hexRadius + gap / 2 }

    // MARK: - Game Phase

    private(set) var phase: GamePhase = .placing
    private(set) var round: Int = 0
    private(set) var money: Int = 100
    let killReward: Int = 5
    var selectedTowerType: TowerType = .projectile

    private var towerPlacedCount: [TowerType: Int] = [:]

    func costForTower(_ type: TowerType) -> Int {
        let base: Int
        switch type {
        case .projectile: base = 25
        case .laser: base = 40
        case .fire: base = 60
        case .ice: base = 100
        }
        let count = towerPlacedCount[type, default: 0]
        return Int(Double(base) * pow(1.1, Double(count)))
    }

    // MARK: - Towers

    private(set) var towers: [Tower] = []

    // MARK: - Enemies

    let enemyRadius: Float = 0.1
    let enemyHoverOffset: Float = 0.05
    private(set) var enemies: [Enemy] = []

    private var enemiesToSpawn: Int = 0
    private var spawnInterval: Float = 0.5  // seconds between spawns
    private var spawnTimer: Float = 0

    // MARK: - Base Tower

    let baseTowerMaxHP: Int = 10
    private(set) var baseTowerHP: Int = 10
    /// Number of visual blocks remaining (starts at 5, loses one every 2 HP lost)
    private(set) var baseTowerBlocksRemaining: Int = 5
    /// Tracks cumulative damage for block destruction threshold
    private var baseTowerDamageAccumulated: Int = 0

    // MARK: - Projectiles

    private(set) var projectiles: [Projectile] = []

    // MARK: - Map Generation

    func generateMap() {
        generatePath()
        generateTerrain()
    }

    private func generatePath() {
        var coord = HexCoord(q: 0, r: 0)
        var dir = Int.random(in: 0..<6)
        var currentHeight: Float = 1.0
        var previousCell: HexCell?

        var placed = 0
        while placed < pathLength {
            let cellType: HexCellType = placed == 0 ? .start : .path
            let cell = HexCell(coord: coord, height: currentHeight, type: cellType)
            cell.previous = previousCell
            previousCell?.next = cell
            hexGrid.addCell(cell)
            previousCell = cell
            placed += 1

            currentHeight *= Float.random(in: 0.95...1.05)

            // Look ahead 2 steps in each turn direction to detect curling
            let leftDir = (dir + 5) % 6
            let rightDir = (dir + 1) % 6

            let leftBlocked = isPathAhead(from: coord, direction: leftDir)
            let rightBlocked = isPathAhead(from: coord, direction: rightDir)
            let straightBlocked = isPathAhead(from: coord, direction: dir)

            // Choose turn direction, biasing away from existing path
            if straightBlocked && !leftBlocked && !rightBlocked {
                dir = Bool.random() ? leftDir : rightDir
            } else if straightBlocked && leftBlocked {
                dir = rightDir
            } else if straightBlocked && rightBlocked {
                dir = leftDir
            } else if leftBlocked && !rightBlocked {
                // Bias right when left is blocked
                let roll = Float.random(in: 0..<1)
                if roll < 0.3 { dir = rightDir }
                // else keep straight
            } else if rightBlocked && !leftBlocked {
                // Bias left when right is blocked
                let roll = Float.random(in: 0..<1)
                if roll < 0.3 { dir = leftDir }
                // else keep straight
            } else {
                // Normal random turning
                let roll = Float.random(in: 0..<1)
                if roll < 0.20 {
                    dir = leftDir
                } else if roll < 0.4 {
                    dir = rightDir
                }
            }

            var next = coord.neighbor(dir)
            if hexGrid.cell(at: next) != nil {
                // Fallback: try other directions
                var found = false
                for offset in 1...5 {
                    let tryDir = (dir + offset) % 6
                    next = coord.neighbor(tryDir)
                    if hexGrid.cell(at: next) == nil {
                        dir = tryDir
                        found = true
                        break
                    }
                }
                if !found { break }
            }
            coord = next
        }

        previousCell?.type = .end
    }

    /// Checks if there's an existing path cell within 2 steps in the given direction.
    private func isPathAhead(from coord: HexCoord, direction: Int) -> Bool {
        let step1 = coord.neighbor(direction)
        if hexGrid.cell(at: step1) != nil { return true }
        let step2 = step1.neighbor(direction)
        if hexGrid.cell(at: step2) != nil { return true }
        return false
    }

    private func generateTerrain() {
        for _ in 0..<terrainRings {
            var frontier: [HexCoord] = []
            for existingCoord in hexGrid.cells.keys {
                for dir in 0..<6 {
                    let adj = existingCoord.neighbor(dir)
                    if hexGrid.cell(at: adj) == nil && !frontier.contains(adj) {
                        frontier.append(adj)
                    }
                }
            }

            for terrainCoord in frontier {
                let adjacentTerrain = (0..<6).compactMap { dir -> HexCell? in
                    guard let cell = hexGrid.cell(at: terrainCoord.neighbor(dir)) else { return nil }
                    return cell.type == .terrain ? cell : nil
                }

                let terrainHeight: Float
                if adjacentTerrain.isEmpty {
                    let allAdjacent = hexGrid.neighbors(of: terrainCoord)
                    if allAdjacent.isEmpty {
                        terrainHeight = Float.random(in: 0.5...2.0)
                    } else {
                        let avg = allAdjacent.map(\.height).reduce(0, +) / Float(allAdjacent.count)
                        terrainHeight = avg * Float.random(in: 0.80...1.20)
                    }
                } else {
                    let avg = adjacentTerrain.map(\.height).reduce(0, +) / Float(adjacentTerrain.count)
                    terrainHeight = avg * Float.random(in: 0.80...1.20)
                }

                let cell = HexCell(coord: terrainCoord, height: terrainHeight, type: .terrain)
                hexGrid.addCell(cell)
            }
        }
    }

    // MARK: - Tower Placement

    /// Places a tower on a terrain cell. Returns the tower if successful.
    func placeTower(at coord: HexCoord) -> Tower? {
        guard phase == .placing else { return nil }
        let cost = costForTower(selectedTowerType)
        guard money >= cost else { return nil }
        guard let cell = hexGrid.cell(at: coord) else { return nil }
        guard cell.type == .terrain && !cell.hasTower else { return nil }

        money -= cost
        towerPlacedCount[selectedTowerType, default: 0] += 1
        cell.hasTower = true
        let tower: Tower
        switch selectedTowerType {
        case .projectile:
            tower = Tower(coord: coord)
        case .laser:
            tower = Tower.makeLaser(coord: coord)
        case .fire:
            tower = Tower.makeFire(coord: coord)
        case .ice:
            tower = Tower.makeIce(coord: coord)
        }
        towers.append(tower)
        return tower
    }

    func tower(at coord: HexCoord) -> Tower? {
        towers.first(where: { $0.coord == coord })
    }

    /// Upgrades a tower if affordable. Returns true on success.
    func upgradeTower(_ tower: Tower) -> Bool {
        guard tower.canUpgrade else { return false }
        let cost = tower.upgradeCost
        guard money >= cost else { return false }
        money -= cost
        tower.applyUpgrade()
        return true
    }

    // MARK: - Round Management

    func startRound() {
        guard phase == .placing else { return }
        round += 1
        phase = .combat

        let enemyCount = 2 + Int(Float(round) * 1.5)
        let hp: Float = 25 + Float(round) * 15
        let speed: Float = 0.4 + Float(round) / 10

        enemiesToSpawn = enemyCount
        spawnInterval = max(0.1, 0.6 - floorf(Float(round)/5) * 0.1)
        spawnTimer = 0

        enemies.removeAll()
        projectiles.removeAll()

        // Pre-create enemies for this round
        for i in 0..<enemyCount {
            let idx = i + 1
            if round >= 10 && idx % 7 == 0 {
                // Shield emitter: normal HP, half speed, shield scales with round
                let shieldAmt = Float(150 + 50 * round)
                enemies.append(Enemy(hitPoints: hp, speed: speed * 0.75, isShielder: true, shieldAmount: shieldAmt))
            } else if round > 5 && idx % 5 == 0 {
                // Tank enemy: 3x HP, half speed, bigger
                enemies.append(Enemy(hitPoints: hp * 4, speed: speed * 0.5, isTank: true, baseDamage: 2))
            } else {
                enemies.append(Enemy(hitPoints: hp, speed: speed))
            }
        }

        // Boss every 5 rounds — spawns last
        if round % 5 == 0 {
            let bossHP = hp * Float(round)
            let bossSpeed = speed * 0.5
            enemies.append(Enemy(hitPoints: bossHP, speed: bossSpeed, isBoss: true, baseDamage: 5))
        }

        // Deactivate all — they'll be activated by the spawner
        for enemy in enemies {
            enemy.active = false
        }
    }

    // MARK: - Game Loop

    /// Main update called each frame. Returns events for the renderer.
    func update(deltaTime: Float) -> GameEvents {
        guard phase == .combat else { return GameEvents() }

        var events = GameEvents()

        // Spawn enemies
        spawnTimer += deltaTime
        let spawnedCount = enemies.filter { $0.currentCell != nil }.count
        let startCell = hexGrid.cells.values.first(where: { $0.type == .start })

        if spawnedCount < enemies.count && spawnTimer >= spawnInterval {
            spawnTimer -= spawnInterval
            if let enemy = enemies.first(where: { $0.currentCell == nil && $0.hitPoints > 0 }) {
                enemy.currentCell = startCell
                enemy.progress = 0
                enemy.active = true
                events.spawnedEnemies.append(enemy)
            }
        }

        // Regenerate shields
        for enemy in enemies where enemy.active && enemy.isShielder && enemy.shieldHP > 0 {
            enemy.shieldHP = min(enemy.shieldMaxHP, enemy.shieldHP + enemy.shieldRegen * deltaTime)
        }

        // Move enemies and apply burn DOT
        for enemy in enemies where enemy.active {
            // Burn damage tick
            if enemy.burning {
                enemy.burnTimer -= deltaTime
                if enemy.burnTimer <= 0 {
                    enemy.burning = false
                    enemy.burnTimer = 0
                } else {
                    if dealDamage(enemy.burnDPS * deltaTime, to: enemy, events: &events) {
                        continue
                    }
                }
            }

            moveEnemy(enemy, deltaTime: deltaTime)
            if enemy.reachedEnd {
                damageBaseTower(damage: enemy.baseDamage, events: &events)
                events.killedEnemies.append(enemy)
            } else {
                events.movedEnemies.append(enemy)
            }
        }

        // Update tower aiming and firing
        for tower in towers {
            tower.cooldownRemaining = max(0, tower.cooldownRemaining - deltaTime)

            // Fire/Ice cone: track enemies and apply effects
            if (tower.type == .fire || tower.type == .ice) && tower.isFiringCone {
                tower.fireTimeRemaining -= deltaTime
                if tower.fireTimeRemaining <= 0 {
                    tower.isFiringCone = false
                    tower.fireTargetCoord = nil
                    tower.beamTargetID = nil
                    tower.cooldownRemaining = tower.cooldown
                    events.conesEnded.append(tower)
                    continue
                } else {
                    let coneCells = fireConeCoords(for: tower)
                    if tower.type == .fire {
                        applyAreaDamage(cells: coneCells, dps: tower.fireDamagePerSecond, deltaTime: deltaTime, events: &events)
                        // Max-level fire tower applies burning DOT
                        if tower.level == Tower.maxLevel {
                            applyBurning(cells: coneCells)
                        }
                    } else if tower.type == .ice, let target = tower.fireTargetCoord {
                        applyAreaSlow(cells: [target], slowFactor: tower.level == Tower.maxLevel ? 0.25 : 0.5)
                    }
                    // Falls through to enemy detection and rotation below
                }
            }

            // Find target enemy — use locked target if actively firing, otherwise select new
            let towerPos2D = tower.coord.worldPosition(spacing: spacing)
            let closestEnemy: Enemy?

            let isFiring = tower.isFiringCone || tower.isFiringBeam
            if isFiring, let lockedID = tower.beamTargetID,
               let locked = enemies.first(where: { $0.id == lockedID && $0.active }) {
                closestEnemy = locked
            } else {
                closestEnemy = selectTarget(for: tower)
            }

            if let target = closestEnemy, let targetPos = enemyWorldPosition(target) {
                let dx = targetPos.x - towerPos2D.x
                let dz = targetPos.z - towerPos2D.y
                tower.targetYaw = atan2(dx, dz) + .pi
                tower.hasTarget = true
            } else {
                tower.hasTarget = false
            }

            // Smoothly rotate turret toward target
            if tower.hasTarget {
                var diff = tower.targetYaw - tower.currentYaw
                while diff > .pi { diff -= 2 * .pi }
                while diff < -.pi { diff += 2 * .pi }

                let maxStep = tower.turretRotationSpeed * deltaTime
                if abs(diff) <= maxStep {
                    tower.currentYaw = tower.targetYaw
                } else {
                    tower.currentYaw += copysign(maxStep, diff)
                }
            }

            // Update fire/ice cone target tracking locked enemy
            if (tower.type == .fire || tower.type == .ice) && tower.isFiringCone {
                if let target = closestEnemy, let coord = enemyNearestCoord(target) {
                    tower.fireTargetCoord = coord
                }
                events.conesUpdated.append(tower)
                continue
            }

            // Laser beam: lock onto target, track it, end on kill/loss/timeout
            if tower.type == .laser && tower.isFiringBeam {
                tower.beamTimeRemaining -= deltaTime

                // Check if locked target is still valid
                let lockedTarget = tower.beamTargetID.flatMap { id in
                    enemies.first(where: { $0.id == id && $0.active })
                }

                if tower.beamTimeRemaining <= 0 || lockedTarget == nil {
                    // Beam ends: timeout or target lost/killed
                    tower.isFiringBeam = false
                    tower.beamTimeRemaining = 0
                    tower.beamTargetID = nil
                    tower.cooldownRemaining = tower.cooldown
                    tower.hasTarget = false
                    events.beamsEnded.append(tower)
                } else {
                    // Track the locked target for turret aiming
                    if let target = lockedTarget, let targetPos = enemyWorldPosition(target) {
                        let towerPos2D = tower.coord.worldPosition(spacing: spacing)
                        let dx = targetPos.x - towerPos2D.x
                        let dz = targetPos.z - towerPos2D.y
                        tower.targetYaw = atan2(dx, dz) + .pi
                        tower.hasTarget = true
                    }

                    let beamCells = beamCellCoords(for: tower)
                    let killCountBefore = events.killedEnemies.count
                    applyAreaDamage(cells: beamCells, dps: tower.beamDamagePerSecond, deltaTime: deltaTime, events: &events)

                    if events.killedEnemies.count > killCountBefore {
                        // Target killed — end beam, enter cooldown
                        tower.isFiringBeam = false
                        tower.beamTimeRemaining = 0
                        tower.beamTargetID = nil
                        tower.cooldownRemaining = tower.cooldown
                        tower.hasTarget = false
                        events.beamsEnded.append(tower)
                    } else {
                        events.beamsUpdated.append(tower)
                    }
                }
                continue
            }

            // Laser in cooldown — don't track new targets
            if tower.type == .laser && tower.cooldownRemaining > 0 {
                tower.hasTarget = false
                continue
            }

            // Only fire when turret is aimed close enough
            let aimThreshold: Float = 0.15
            var aimDiff = tower.targetYaw - tower.currentYaw
            while aimDiff > .pi { aimDiff -= 2 * .pi }
            while aimDiff < -.pi { aimDiff += 2 * .pi }
            let isAimed = tower.hasTarget && abs(aimDiff) < aimThreshold

            if tower.cooldownRemaining <= 0 && isAimed {
                if tower.type == .laser {
                    tower.isFiringBeam = true
                    tower.beamTimeRemaining = tower.beamDuration
                    tower.beamTargetID = closestEnemy?.id
                    events.beamsStarted.append(tower)
                } else if tower.type == .fire || tower.type == .ice {
                    // Find the target enemy's nearest coord for the cone center
                    if let target = closestEnemy, let coord = enemyNearestCoord(target) {
                        tower.isFiringCone = true
                        tower.fireTimeRemaining = tower.fireDuration
                        tower.fireTargetCoord = coord
                        tower.beamTargetID = target.id
                        events.conesStarted.append(tower)
                    }
                } else {
                    if let projectile = tryFire(tower: tower) {
                        projectiles.append(projectile)
                        tower.cooldownRemaining = tower.cooldown
                        events.firedProjectiles.append(projectile)
                    }
                }
            }
        }

        // Update projectiles
        var completedProjectiles: [Projectile] = []
        for projectile in projectiles {
            projectile.elapsed += deltaTime
            if projectile.isComplete {
                completedProjectiles.append(projectile)
            }
        }

        // Apply damage from completed projectiles
        for projectile in completedProjectiles {
            if let enemy = enemies.first(where: { $0.id == projectile.targetEnemyID && $0.active }) {
                dealDamage(projectile.damage, to: enemy, events: &events)

                // Max-level projectile tower: AoE explosion hits all enemies on same tile
                if projectile.isAoE, let coord = enemyNearestCoord(enemy) {
                    for other in enemies where other.active && other.id != enemy.id {
                        guard let otherCoord = enemyNearestCoord(other) else { continue }
                        if otherCoord == coord {
                            dealDamage(projectile.damage, to: other, events: &events)
                        }
                    }
                }
            }
            events.completedProjectiles.append(projectile)
        }
        projectiles.removeAll { $0.isComplete }

        // Check game over
        if events.gameOver {
            phase = .roundOver
            events.roundOver = true
            return events
        }

        // Check round over: all enemies dead or escaped
        let allDone = enemies.allSatisfy { !$0.active }
        if allDone && spawnedCount == enemies.count {
            phase = .roundOver
            events.roundOver = true
        }

        return events
    }

    // MARK: - Enemy Movement

    /// Called when an enemy reaches the end tile and hits the base tower.
    private func damageBaseTower(damage: Int, events: inout GameEvents) {
        baseTowerHP = max(0, baseTowerHP - damage)
        baseTowerDamageAccumulated += damage
        events.baseTowerHit = true

        // Every 2 HP lost, destroy a block
        while baseTowerDamageAccumulated >= 2 && baseTowerBlocksRemaining > 0 {
            baseTowerDamageAccumulated -= 2
            baseTowerBlocksRemaining -= 1
            events.baseTowerBlocksDestroyed += 1
        }

        if baseTowerHP <= 0 {
            events.gameOver = true
        }
    }

    private func moveEnemy(_ enemy: Enemy, deltaTime: Float) {
        guard let current = enemy.currentCell else { return }

        guard let nextCell = current.next else {
            // Reached the end — enemy hits the base tower
            enemy.active = false
            enemy.reachedEnd = true
            return
        }

        // Tick down slow timer
        if enemy.slowed {
            enemy.slowTimer -= deltaTime
            if enemy.slowTimer <= 0 {
                enemy.slowed = false
                enemy.slowTimer = 0
                enemy.slowFactor = 0.5
            }
        }

        let currentPos = current.coord.worldPosition(spacing: spacing)
        let nextPos = nextCell.coord.worldPosition(spacing: spacing)
        let distance = simd_distance(currentPos, nextPos)

        let effectiveSpeed = enemy.slowed ? enemy.speed * enemy.slowFactor : enemy.speed
        enemy.progress += (effectiveSpeed * deltaTime) / distance

        if enemy.progress >= 1.0 {
            enemy.progress -= 1.0
            enemy.currentCell = nextCell
            if let nextNext = nextCell.next {
                let nextNextPos = nextNext.coord.worldPosition(spacing: spacing)
                let nextDistance = simd_distance(nextPos, nextNextPos)
                enemy.progress *= distance / nextDistance
            }
        }
    }

    /// Computes world position for an enemy using Catmull-Rom interpolation.
    func enemyWorldPosition(_ enemy: Enemy) -> SIMD3<Float>? {
        guard let current = enemy.currentCell else { return nil }
        let t = enemy.progress

        let p1Pos = current.coord.worldPosition(spacing: spacing)
        let p1Y = current.height + enemyRadius + enemyHoverOffset

        if let nextCell = current.next {
            let p2Pos = nextCell.coord.worldPosition(spacing: spacing)
            let p2Y = nextCell.height + enemyRadius + enemyHoverOffset

            let p0Pos: SIMD2<Float>
            let p0Y: Float
            if let prev = current.previous {
                p0Pos = prev.coord.worldPosition(spacing: spacing)
                p0Y = prev.height + enemyRadius + enemyHoverOffset
            } else {
                p0Pos = p1Pos * 2 - p2Pos
                p0Y = p1Y * 2 - p2Y
            }

            let p3Pos: SIMD2<Float>
            let p3Y: Float
            if let nextNext = nextCell.next {
                p3Pos = nextNext.coord.worldPosition(spacing: spacing)
                p3Y = nextNext.height + enemyRadius + enemyHoverOffset
            } else {
                p3Pos = p2Pos * 2 - p1Pos
                p3Y = p2Y * 2 - p1Y
            }

            let x = catmullRom(p0Pos.x, p1Pos.x, p2Pos.x, p3Pos.x, t)
            let z = catmullRom(p0Pos.y, p1Pos.y, p2Pos.y, p3Pos.y, t)
            let y = catmullRom(p0Y, p1Y, p2Y, p3Y, t)

            return [x, y, z]
        } else {
            return [p1Pos.x, p1Y, p1Pos.y]
        }
    }

    // MARK: - Tower Firing Logic

    /// Returns the hex coord the enemy is closest to.
    private func enemyNearestCoord(_ enemy: Enemy) -> HexCoord? {
        guard let cell = enemy.currentCell else { return nil }
        if enemy.progress < 0.5 {
            return cell.coord
        }
        return cell.next?.coord ?? cell.coord
    }

    /// How far along the path an enemy is (higher = closer to end).
    private func enemyPathProgress(_ enemy: Enemy) -> Int {
        var steps = 0
        var cell = hexGrid.cells.values.first(where: { $0.type == .start })
        while let c = cell {
            if c === enemy.currentCell { return steps }
            cell = c.next
            steps += 1
        }
        return steps
    }

    /// Selects the best enemy target for a tower based on its targeting mode.
    private func selectTarget(for tower: Tower) -> Enemy? {
        // Gather enemies in detection radius
        var candidates: [(enemy: Enemy, dist: Int)] = []
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            let dist = tower.coord.distance(to: enemyCoord)
            if dist <= tower.detectionRadius {
                candidates.append((enemy, dist))
            }
        }
        guard !candidates.isEmpty else { return nil }

        switch tower.targetingMode {
        case .closest:
            return candidates.min(by: { $0.dist < $1.dist })?.enemy
        case .furthestAhead:
            return candidates.max(by: { enemyPathProgress($0.enemy) < enemyPathProgress($1.enemy) })?.enemy
        case .furthestBehind:
            return candidates.min(by: { enemyPathProgress($0.enemy) < enemyPathProgress($1.enemy) })?.enemy
        case .mostHealth:
            return candidates.max(by: { $0.enemy.hitPoints < $1.enemy.hitPoints })?.enemy
        case .leastHealth:
            return candidates.min(by: { $0.enemy.hitPoints < $1.enemy.hitPoints })?.enemy
        }
    }

    /// Predicts the world position of an enemy after `time` seconds.
    private func predictEnemyPosition(_ enemy: Enemy, afterTime time: Float) -> (position: SIMD3<Float>, coord: HexCoord)? {
        guard var cell = enemy.currentCell else { return nil }
        var progress = enemy.progress
        var remaining = time

        // Simulate the enemy moving forward in time
        while remaining > 0 {
            guard let nextCell = cell.next else {
                // Enemy will reach end before projectile arrives
                let pos = cell.coord.worldPosition(spacing: spacing)
                return (SIMD3<Float>(pos.x, cell.height + enemyRadius + enemyHoverOffset, pos.y), cell.coord)
            }

            let cellPos = cell.coord.worldPosition(spacing: spacing)
            let nextPos = nextCell.coord.worldPosition(spacing: spacing)
            let distance = simd_distance(cellPos, nextPos)
            let progressPerSecond = enemy.speed / distance
            let timeToNextCell = (1.0 - progress) / progressPerSecond

            if remaining < timeToNextCell {
                progress += progressPerSecond * remaining
                remaining = 0
            } else {
                remaining -= timeToNextCell
                cell = nextCell
                progress = 0
            }
        }

        // Compute world position at predicted cell/progress
        let cellPos = cell.coord.worldPosition(spacing: spacing)
        if let nextCell = cell.next {
            let nextPos = nextCell.coord.worldPosition(spacing: spacing)
            let x = cellPos.x + (nextPos.x - cellPos.x) * progress
            let z = cellPos.y + (nextPos.y - cellPos.y) * progress
            let y = cell.height + (nextCell.height - cell.height) * progress + enemyRadius + enemyHoverOffset
            let nearestCoord = progress < 0.5 ? cell.coord : nextCell.coord
            return (SIMD3<Float>(x, y, z), nearestCoord)
        } else {
            return (SIMD3<Float>(cellPos.x, cell.height + enemyRadius + enemyHoverOffset, cellPos.y), cell.coord)
        }
    }

    /// Tries to fire a projectile from the tower. Returns a projectile if targeting succeeds.
    private func tryFire(tower: Tower) -> Projectile? {
        let towerCell = hexGrid.cell(at: tower.coord)
        let towerWorldPos2D = tower.coord.worldPosition(spacing: spacing)
        let towerHeight = (towerCell?.height ?? 1.0) + 0.62 // turret height
        let towerOrigin = SIMD3<Float>(towerWorldPos2D.x, towerHeight, towerWorldPos2D.y)

        // Find enemies within detection radius
        var candidates: [(enemy: Enemy, distance: Int)] = []
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            let dist = tower.coord.distance(to: enemyCoord)
            if dist <= tower.detectionRadius {
                candidates.append((enemy, dist))
            }
        }

        // Sort by distance (closest first)
        candidates.sort { $0.distance < $1.distance }

        for (enemy, _) in candidates {
            guard let enemyPos = enemyWorldPosition(enemy) else { continue }

            // Estimate time of flight to current enemy position
            let dist3D = simd_distance(towerOrigin, enemyPos)
            let estimatedFlightTime = dist3D / tower.projectileSpeed

            // Predict where enemy will be when projectile arrives
            guard let prediction = predictEnemyPosition(enemy, afterTime: estimatedFlightTime) else { continue }

            // Check if predicted position is within fire radius
            let predictedHexDist = tower.coord.distance(to: prediction.coord)
            if predictedHexDist > tower.fireRadius { continue }

            // Refine: compute actual flight time to predicted position
            let actualDist = simd_distance(towerOrigin, prediction.position)
            let actualFlightTime = actualDist / tower.projectileSpeed

            return Projectile(
                origin: towerOrigin,
                target: prediction.position,
                totalFlightTime: actualFlightTime,
                damage: tower.damage,
                targetEnemyID: enemy.id,
                isAoE: tower.level == Tower.maxLevel
            )
        }

        return nil
    }

    // MARK: - Damage Helpers

    /// Finds a nearby active shielder protecting the given coord (within 1 hex).
    private func findShielder(near coord: HexCoord) -> Enemy? {
        for enemy in enemies where enemy.active && enemy.isShielder && enemy.shieldActive {
            guard let shielderCoord = enemyNearestCoord(enemy) else { continue }
            if shielderCoord.distance(to: coord) <= 1 {
                return enemy
            }
        }
        return nil
    }

    /// Deals damage to an enemy, routing through a nearby shield if one exists.
    /// Returns true if the enemy was killed.
    @discardableResult
    private func dealDamage(_ amount: Float, to enemy: Enemy, events: inout GameEvents) -> Bool {
        guard enemy.active else { return false }
        guard let coord = enemyNearestCoord(enemy) else {
            enemy.hitPoints -= amount
            if enemy.hitPoints <= 0 {
                enemy.active = false
                money += enemy.isBoss ? 5 * round : killReward
                events.killedEnemies.append(enemy)
                return true
            }
            return false
        }

        var remaining = amount
        if let shielder = findShielder(near: coord) {
            let absorbed = min(shielder.shieldHP, remaining)
            shielder.shieldHP -= absorbed
            remaining -= absorbed
            if shielder.shieldHP <= 0 {
                events.shieldsBroken.append(shielder)
            }
        }

        if remaining > 0 {
            enemy.hitPoints -= remaining
        }
        if enemy.hitPoints <= 0 {
            enemy.active = false
            money += enemy.isBoss ? 5 * round : killReward
            events.killedEnemies.append(enemy)
            return true
        }
        return false
    }

    private func applyAreaDamage(cells: [HexCoord], dps: Float, deltaTime: Float, events: inout GameEvents) {
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            if cells.contains(enemyCoord) {
                dealDamage(dps * deltaTime, to: enemy, events: &events)
            }
        }
    }

    private func applyBurning(cells: [HexCoord]) {
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            if cells.contains(enemyCoord) {
                enemy.burning = true
                enemy.burnTimer = 3.0
            }
        }
    }

    private func applyAreaSlow(cells: [HexCoord], slowFactor: Float = 0.5) {
        let slowDuration: Float = 2.0
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            if cells.contains(enemyCoord) {
                enemy.slowed = true
                enemy.slowTimer = max(enemy.slowTimer, slowDuration)
                // Use the strongest slow (lowest factor)
                enemy.slowFactor = min(enemy.slowFactor, slowFactor)
            }
        }
    }

    // MARK: - Fire Cone

    /// Returns the target cell and all its neighbors as the fire cone area.
    func fireConeCoords(for tower: Tower) -> [HexCoord] {
        guard let target = tower.fireTargetCoord else { return [] }
        var coords = [target]
        for dir in 0..<6 {
            coords.append(target.neighbor(dir))
        }
        return coords
    }

    /// World positions of the fire cone cells for rendering.
    func fireConeWorldPositions(for tower: Tower) -> [SIMD3<Float>] {
        let coords = fireConeCoords(for: tower)
        return coords.compactMap { coord in
            guard let cell = hexGrid.cell(at: coord) else { return nil }
            let pos = coord.worldPosition(spacing: spacing)
            return SIMD3<Float>(pos.x, cell.height + 0.05, pos.y)
        }
    }

    /// Barrel tip position for the fire tower.
    func fireOrigin(for tower: Tower) -> SIMD3<Float> {
        beamOrigin(for: tower)
    }

    /// World position of the fire cone's target cell center.
    func fireTargetPosition(for tower: Tower) -> SIMD3<Float>? {
        guard let targetCoord = tower.fireTargetCoord,
              let cell = hexGrid.cell(at: targetCoord) else { return nil }
        let pos = targetCoord.worldPosition(spacing: spacing)
        return SIMD3<Float>(pos.x, cell.height + 0.05, pos.y)
    }

    // MARK: - Laser Beam

    /// Returns the hex coords along the beam's straight line from the tower.
    func beamCellCoords(for tower: Tower) -> [HexCoord] {
        // The beam fires in the direction the turret is facing.
        // Convert yaw to a world direction, then walk hex cells in that direction.
        let yaw = tower.currentYaw + .pi // undo the barrel offset
        let dirX = sin(yaw)
        let dirZ = cos(yaw)

        var coords: [HexCoord] = []
        let towerPos = tower.coord.worldPosition(spacing: spacing)

        for step in 1...tower.beamRange {
            // Sample a world point along the beam line
            let sampleX = towerPos.x + dirX * spacing * 1.5 * Float(step)
            let sampleZ = towerPos.y + dirZ * spacing * 1.5 * Float(step)
            // Convert world position back to nearest hex coord
            let coord = nearestHexCoord(worldX: sampleX, worldZ: sampleZ)
            if !coords.contains(coord) {
                coords.append(coord)
            }
        }
        return coords
    }

    /// Computes the barrel tip position in world space.
    func beamOrigin(for tower: Tower) -> SIMD3<Float> {
        let towerCell = hexGrid.cell(at: tower.coord)
        let towerPos = tower.coord.worldPosition(spacing: spacing)
        let towerHeight = (towerCell?.height ?? 1.0) + 0.62

        // Barrel tip offset: barrel center (0.25) + half barrel height (0.1) = 0.35
        let yaw = tower.currentYaw + .pi
        let dirX = sin(yaw)
        let dirZ = cos(yaw)
        let barrelLength: Float = 0.35

        return SIMD3<Float>(
            towerPos.x + dirX * barrelLength,
            towerHeight,
            towerPos.y + dirZ * barrelLength
        )
    }

    /// Computes the world-space beam endpoint — the closest tracked enemy position.
    func beamEndpoint(for tower: Tower) -> SIMD3<Float> {
        // Find the closest active enemy in detection radius
        var closestEnemy: Enemy?
        var closestDist: Int = Int.max

        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            let dist = tower.coord.distance(to: enemyCoord)
            if dist <= tower.detectionRadius && dist < closestDist {
                closestDist = dist
                closestEnemy = enemy
            }
        }

        if let enemy = closestEnemy, let pos = enemyWorldPosition(enemy) {
            return pos
        }

        // Fallback: project beam forward from barrel
        let origin = beamOrigin(for: tower)
        let yaw = tower.currentYaw + .pi
        let beamLength = spacing * 1.5 * Float(tower.beamRange)
        return SIMD3<Float>(
            origin.x + sin(yaw) * beamLength,
            origin.y,
            origin.z + cos(yaw) * beamLength
        )
    }

    /// Converts a world XZ position to the nearest hex coord.
    private func nearestHexCoord(worldX: Float, worldZ: Float) -> HexCoord {
        // Reverse the flat-top hex layout formula
        let q = worldX / (spacing * 1.5)
        let r = (worldZ - spacing * sqrt(3.0) / 2.0 * q) / (spacing * sqrt(3.0))

        // Round to nearest hex using cube coordinate rounding
        let s = -q - r
        var rq = Darwin.round(q)
        var rr = Darwin.round(r)
        let rs = Darwin.round(s)

        let dq = abs(rq - q)
        let dr = abs(rr - r)
        let ds = abs(rs - s)

        if dq > dr && dq > ds {
            rq = -rr - rs
        } else if dr > ds {
            rr = -rq - rs
        }

        return HexCoord(q: Int(rq), r: Int(rr))
    }

    // MARK: - Base Tower Position

    /// Returns the end cell where the base tower is placed.
    var endCell: HexCell? {
        hexGrid.cells.values.first(where: { $0.type == .end })
    }

    // MARK: - Return to Placing Phase

    func returnToPlacing() {
        guard phase == .roundOver else { return }
        phase = .placing
        enemies.removeAll()
        projectiles.removeAll()
        for tower in towers {
            tower.isFiringBeam = false
            tower.beamTimeRemaining = 0
            tower.beamTargetID = nil
            tower.isFiringCone = false
            tower.fireTimeRemaining = 0
            tower.fireTargetCoord = nil
        }
    }

    /// Resets the entire game to its initial state. Returns removed tower IDs for cleanup.
    func restart() -> [UUID] {  
        let towerIDs = towers.map(\.id)
        phase = .placing
        round = 0
        money = 100
        baseTowerHP = baseTowerMaxHP
        baseTowerBlocksRemaining = 5
        baseTowerDamageAccumulated = 0
        towers.removeAll()
        enemies.removeAll()
        projectiles.removeAll()
        towerPlacedCount.removeAll()
        // Clear hasTower flags
        for cell in hexGrid.cells.values {
            cell.hasTower = false
        }
        return towerIDs
    }

    // MARK: - Selection

    func selectCell(at coord: HexCoord) -> (deselected: [HexCell], selected: HexCell?) {
        var deselected: [HexCell] = []
        for cell in hexGrid.cells.values where cell.isSelected {
            cell.isSelected = false
            deselected.append(cell)
        }

        guard let cell = hexGrid.cell(at: coord) else {
            return (deselected, nil)
        }
        cell.isSelected = true
        return (deselected, cell)
    }

    // MARK: - Catmull-Rom

    private func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1) +
                       (-p0 + p2) * t +
                       (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                       (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
}

// MARK: - Game Events

/// Events produced by a single game update frame, consumed by the renderer.
struct GameEvents {
    var spawnedEnemies: [Enemy] = []
    var movedEnemies: [Enemy] = []
    var killedEnemies: [Enemy] = []
    var firedProjectiles: [Projectile] = []
    var completedProjectiles: [Projectile] = []
    var beamsStarted: [Tower] = []
    var beamsUpdated: [Tower] = []
    var beamsEnded: [Tower] = []
    var conesStarted: [Tower] = []
    var conesUpdated: [Tower] = []
    var conesEnded: [Tower] = []
    var baseTowerHit: Bool = false
    var baseTowerBlocksDestroyed: Int = 0
    var gameOver: Bool = false
    var roundOver: Bool = false
    var shieldsBroken: [Enemy] = []  // shielders whose shield just hit 0
}
