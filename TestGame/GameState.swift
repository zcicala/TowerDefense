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
    let pathLength = 50
    let terrainRings = 2

    var spacing: Float { hexRadius + gap / 2 }

    // MARK: - Game Phase

    private(set) var phase: GamePhase = .placing
    private(set) var round: Int = 0
    private(set) var money: Int = 100
    let killReward: Int = 5
    var selectedTowerType: TowerType = .projectile

    func costForTower(_ type: TowerType) -> Int {
        switch type {
        case .projectile: return 20
        case .laser: return 50
        case .fire: return 35
        }
    }

    // MARK: - Towers

    private(set) var towers: [Tower] = []

    // MARK: - Enemies

    let enemyRadius: Float = 0.1
    let enemyHoverOffset: Float = 0.05
    private(set) var enemies: [Enemy] = []

    private var enemiesToSpawn: Int = 0
    private var spawnInterval: Float = 1.0  // seconds between spawns
    private var spawnTimer: Float = 0

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

            let roll = Float.random(in: 0..<1)
            if roll < 0.20 {
                dir = (dir + 5) % 6
            } else if roll < 0.4 {
                dir = (dir + 1) % 6
            }

            var next = coord.neighbor(dir)
            if hexGrid.cell(at: next) != nil {
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
        cell.hasTower = true
        let tower: Tower
        switch selectedTowerType {
        case .projectile:
            tower = Tower(coord: coord)
        case .laser:
            tower = Tower.makeLaser(coord: coord)
        case .fire:
            tower = Tower.makeFire(coord: coord)
        }
        towers.append(tower)
        return tower
    }

    // MARK: - Round Management

    func startRound() {
        guard phase == .placing else { return }
        round += 1
        phase = .combat

        let enemyCount = 10 + round * 4
        let hp: Float = 50 + Float(round) * 15
        let speed: Float = 1.5 + Float(round )/2

        enemiesToSpawn = enemyCount
        spawnInterval = max(0.4, 1.2 - floorf(Float(round)/5) * 0.1)
        spawnTimer = 0

        enemies.removeAll()
        projectiles.removeAll()

        // Pre-create enemies for this round
        for _ in 0..<enemyCount {
            enemies.append(Enemy(hitPoints: hp, speed: speed))
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

        // Move enemies
        for enemy in enemies where enemy.active {
            moveEnemy(enemy, deltaTime: deltaTime)
            events.movedEnemies.append(enemy)
        }

        // Update tower aiming and firing
        for tower in towers {
            tower.cooldownRemaining = max(0, tower.cooldownRemaining - deltaTime)

            // Fire cone: locked rotation, apply AoE damage
            if tower.type == .fire && tower.isFiringCone {
                tower.fireTimeRemaining -= deltaTime
                if tower.fireTimeRemaining <= 0 {
                    tower.isFiringCone = false
                    tower.fireTargetCoord = nil
                    tower.cooldownRemaining = tower.cooldown
                    events.conesEnded.append(tower)
                } else {
                    let coneCells = fireConeCoords(for: tower)
                    applyAreaDamage(cells: coneCells, dps: tower.fireDamagePerSecond, deltaTime: deltaTime, events: &events)
                }
                continue
            }

            // Find closest enemy in detection radius for aiming
            let towerPos2D = tower.coord.worldPosition(spacing: spacing)
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

            // Laser beam: track and apply damage while firing
            if tower.type == .laser && tower.isFiringBeam {
                tower.beamTimeRemaining -= deltaTime
                if tower.beamTimeRemaining <= 0 {
                    tower.isFiringBeam = false
                    tower.cooldownRemaining = tower.cooldown
                    events.beamsEnded.append(tower)
                } else {
                    let beamCells = beamCellCoords(for: tower)
                    applyAreaDamage(cells: beamCells, dps: tower.beamDamagePerSecond, deltaTime: deltaTime, events: &events)
                    events.beamsUpdated.append(tower)
                }
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
                    events.beamsStarted.append(tower)
                } else if tower.type == .fire {
                    // Find the target enemy's nearest coord for the cone center
                    if let target = closestEnemy, let coord = enemyNearestCoord(target) {
                        tower.isFiringCone = true
                        tower.fireTimeRemaining = tower.fireDuration
                        tower.fireTargetCoord = coord
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
                enemy.hitPoints -= projectile.damage
                if enemy.hitPoints <= 0 {
                    enemy.active = false
                    money += killReward
                    events.killedEnemies.append(enemy)
                }
            }
            events.completedProjectiles.append(projectile)
        }
        projectiles.removeAll { $0.isComplete }

        // Check round over: all enemies dead or escaped
        let allDone = enemies.allSatisfy { !$0.active }
        if allDone && spawnedCount == enemies.count {
            phase = .roundOver
            events.roundOver = true
        }

        return events
    }

    // MARK: - Enemy Movement

    private func moveEnemy(_ enemy: Enemy, deltaTime: Float) {
        guard let current = enemy.currentCell else { return }

        guard let nextCell = current.next else {
            // Reached the end — enemy escapes
            enemy.active = false
            return
        }

        let currentPos = current.coord.worldPosition(spacing: spacing)
        let nextPos = nextCell.coord.worldPosition(spacing: spacing)
        let distance = simd_distance(currentPos, nextPos)

        enemy.progress += (enemy.speed * deltaTime) / distance

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
        let towerHeight = (towerCell?.height ?? 1.0) + 0.65 // top of tower
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
                targetEnemyID: enemy.id
            )
        }

        return nil
    }

    // MARK: - Area Damage Helper

    private func applyAreaDamage(cells: [HexCoord], dps: Float, deltaTime: Float, events: inout GameEvents) {
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            if cells.contains(enemyCoord) {
                enemy.hitPoints -= dps * deltaTime
                if enemy.hitPoints <= 0 {
                    enemy.active = false
                    money += killReward
                    events.killedEnemies.append(enemy)
                }
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
        let towerHeight = (towerCell?.height ?? 1.0) + 0.65

        // Barrel tip offset: 0.25 units in the direction the turret faces
        let yaw = tower.currentYaw + .pi
        let dirX = sin(yaw)
        let dirZ = cos(yaw)
        let barrelLength: Float = 0.25

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

    // MARK: - Return to Placing Phase

    func returnToPlacing() {
        guard phase == .roundOver else { return }
        phase = .placing
        enemies.removeAll()
        projectiles.removeAll()
        for tower in towers {
            tower.isFiringBeam = false
            tower.beamTimeRemaining = 0
            tower.isFiringCone = false
            tower.fireTimeRemaining = 0
            tower.fireTargetCoord = nil
        }
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
    var conesEnded: [Tower] = []
    var roundOver: Bool = false
}
