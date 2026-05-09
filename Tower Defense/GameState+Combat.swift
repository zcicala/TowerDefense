import Foundation
import simd

extension GameState {

    // MARK: - Game Loop

    /// Main update called each frame. Returns events for the renderer.
    func togglePause() {
        guard hasPauseControl && phase == .combat else { return }
        isPaused.toggle()
    }

    func update(deltaTime: Float) -> GameEvents {
        guard phase == .combat && !isPaused else { return GameEvents() }

        var events = GameEvents()

        // Spawn enemies
        spawnTimer += deltaTime
        let spawnedCount = enemies.filter { $0.currentCell != nil }.count
        let startCells = hexGrid.cells.values.filter { $0.type == .start }

        if spawnedCount < enemies.count && spawnTimer >= spawnInterval {
            spawnTimer = 0
            spawnInterval = Float.random(in: 0.5...1.5)
            if let enemy = enemies.first(where: { $0.currentCell == nil && $0.hitPoints > 0 }) {
                enemy.currentCell = startCells.randomElement()
                enemy.progress = 0
                enemy.active = true
                events.spawnedEnemies.append(enemy)
            }
        }

        // Regenerate shields
        for enemy in enemies where enemy.active && enemy.enemyType == .shield && enemy.shieldHP > 0 {
            enemy.shieldHP = min(enemy.shieldMaxHP, enemy.shieldHP + enemy.shieldRegen * deltaTime)
        }

        // Apply slow aura from towers and global inventory aura zones
        for tower in towers where !tower.slowedCoords.isEmpty {
            applyAreaSlow(cells: Array(tower.slowedCoords), slowFactor: 0.8)
        }
        if !globalSlowAuraCoords.isEmpty {
            applyAreaSlow(cells: Array(globalSlowAuraCoords), slowFactor: 0.8)
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

            if enemy.enemyType == .hopper || enemy.enemyType == .superHopper {
                updateHopper(enemy, deltaTime: deltaTime)
            } else {
                moveEnemy(enemy, deltaTime: deltaTime)
            }
            // Hive periodically drops a hopper while alive
            if enemy.enemyType == .hive {
                enemy.hiveSpawnTimer -= deltaTime
                if enemy.hiveSpawnTimer <= 0 {
                    enemy.hiveSpawnTimer = 4.0
                    let hiveWorldY = enemyWorldPosition(enemy)?.y ?? 0
                    let hp: Float = 20 + Float(round) * 15
                    let hopper = makeEnemy(type: .hopper, hp: hp, speed: 1.2)
                    hopper.currentCell = enemy.currentCell
                    hopper.progress = enemy.progress
                    hopper.isDroppingFromHive = true
                    hopper.hiveDropFromY = hiveWorldY
                    hopper.hiveDropProgress = 0
                    let angle = Float.random(in: 0..<(2 * .pi))
                    hopper.hiveDropLateralOffset = SIMD2<Float>(cos(angle) * 0.35, sin(angle) * 0.35)
                    hopper.active = true
                    enemies.append(hopper)
                    events.spawnedEnemies.append(hopper)
                }
            }

            if enemy.reachedEnd {
                print("[BaseDamage] \(enemy.enemyType) dealt \(enemy.baseDamage) damage to base tower (HP: \(baseTowerHP) → \(max(0, baseTowerHP - enemy.baseDamage)))")
                damageBaseTower(damage: enemy.baseDamage, events: &events)
                events.killedEnemies.append(enemy)
            } else {
                events.movedEnemies.append(enemy)
            }
        }

        // Update bowling balls
        updateBowlingBalls(deltaTime: deltaTime, events: &events)

        // Base tower shoots like a projectile tower
        ensureBaseSentinel()
        if let sentinel = baseSentinelTower {
            sentinel.cooldownRemaining = max(0, sentinel.cooldownRemaining - deltaTime)
            if sentinel.cooldownRemaining <= 0 {
                if let projectile = tryFire(tower: sentinel) {
                    sentinel.cooldownRemaining = sentinel.cooldown
                    projectiles.append(projectile)
                    events.firedProjectiles.append(projectile)
                }
            }
        }

        // Update tower aiming and firing
        for tower in towers {
            tower.cooldownRemaining = max(0, tower.cooldownRemaining - deltaTime)

            // Sword: stabs to an adjacent path tile when an enemy is on it
            if tower.type == .sword {
                if tower.isFiringBlade {
                    tower.bladeTimeRemaining -= deltaTime
                    tower.bladeSweepProgress = 1.0 - max(0, tower.bladeTimeRemaining / tower.fireDuration)

                    if tower.level == Tower.maxLevel {
                        // Apply damage as sweep angle passes each target
                        let currentAngle = tower.bladeSwipeStartAngle + (tower.bladeSwipeEndAngle - tower.bladeSwipeStartAngle) * tower.bladeSweepProgress
                        for target in tower.bladeSwipeTargets where !tower.bladeDamagedCoords.contains(target.coord) {
                            let angleDiff = tower.bladeSwipeEndAngle > tower.bladeSwipeStartAngle
                                ? target.angle <= currentAngle
                                : target.angle >= currentAngle
                            if angleDiff {
                                let victim = enemies
                                    .filter { $0.active && enemyNearestCoord($0) == target.coord }
                                    .max { enemyPathProgress($0) < enemyPathProgress($1) }
                                if let enemy = victim {
                                    dealDamage(tower.damage, to: enemy, tower: tower, events: &events)
                                }
                                tower.bladeDamagedCoords.insert(target.coord)
                            }
                        }
                        events.bladesUpdated.append(tower)
                    } else if !tower.bladeDamageDealt, let target = tower.bladeTargetCoord {
                        // Single stab: deal damage once
                        let victim = enemies
                            .filter { $0.active && enemyNearestCoord($0) == target }
                            .max { enemyPathProgress($0) < enemyPathProgress($1) }
                        if let enemy = victim { dealDamage(tower.damage, to: enemy, tower: tower, events: &events) }
                        tower.bladeDamageDealt = true
                    }

                    if tower.bladeTimeRemaining <= 0 {
                        tower.isFiringBlade = false
                        tower.bladeTargetCoord = nil
                        tower.bladeSwipeTargets = []
                        tower.bladeDamagedCoords = []
                        tower.bladeDamageDealt = false
                        tower.bladeSweepProgress = 0
                        tower.cooldownRemaining = tower.cooldown
                        events.bladesEnded.append(tower)
                    }
                } else if tower.cooldownRemaining <= 0 {
                    let adjacent = hexGrid.neighbors(of: tower.coord)
                        .filter { $0.type == .path || $0.type == .start }

                    if tower.level == Tower.maxLevel {
                        // Swipe arc: gather all adjacent path cells and compute their angles
                        let towerPos = tower.coord.worldPosition(spacing: spacing)
                        let swipeTargets: [(coord: HexCoord, angle: Float)] = adjacent.compactMap { cell in
                            let cellPos = cell.coord.worldPosition(spacing: spacing)
                            let angle = atan2(cellPos.x - towerPos.x, cellPos.y - towerPos.y)
                            return (cell.coord, angle)
                        }.sorted { $0.angle < $1.angle }

                        if !swipeTargets.isEmpty {
                            // Add padding so blade starts before and ends after outermost cells
                            let pad: Float = 0.25
                            tower.bladeSwipeStartAngle = swipeTargets.first!.angle - pad
                            tower.bladeSwipeEndAngle   = swipeTargets.last!.angle + pad
                            tower.isFiringBlade = true
                            tower.bladeTimeRemaining = tower.fireDuration
                            tower.bladeSwipeTargets = swipeTargets
                            tower.bladeSweepProgress = 0
                            tower.bladeDamagedCoords = []
                            events.bladesStarted.append(tower)
                        }
                    } else {
                        let target = adjacent.first { cell in
                            enemies.contains { $0.active && enemyNearestCoord($0) == cell.coord }
                        }
                        if let targetCell = target {
                            tower.isFiringBlade = true
                            tower.bladeTimeRemaining = tower.fireDuration
                            tower.bladeTargetCoord = targetCell.coord
                            tower.bladeSwipeTargets = []
                            tower.bladeDamageDealt = false
                            events.bladesStarted.append(tower)
                        }
                    }
                }
                continue
            }

            // Bowler: fires when an enemy is detected in range
            if tower.type == .bowler {
                if tower.cooldownRemaining <= 0 {
                    let hasEnemyInRange = enemies.contains { enemy in
                        guard enemy.active, let coord = enemyNearestCoord(enemy) else { return false }
                        return tower.coord.distance(to: coord) <= tower.detectionRadius
                    }
                    if hasEnemyInRange, let entry = bowlerEntryCell(for: tower) {
                        let entryPos = entry.coord.worldPosition(spacing: spacing)
                        let towerCell = hexGrid.cell(at: tower.coord)
                        let towerTopY = (towerCell?.height ?? 1.0) + 0.85  // top of tower stack + resting ball
                        let pathY = (entry.height) + bowlingBallRadius
                        // Ball starts at tower top (XZ = entry cell), falls to path level
                        let startPos = SIMD3<Float>(entryPos.x, towerTopY, entryPos.y)
                        let dir = bowlerBallDirection(tower: tower, entry: entry)
                        let bounces = tower.level == Tower.maxLevel ? 1 : 0
                        let ball = BowlingBall(startPosition: startPos, direction: dir, speed: 3.0, damage: tower.damage, targetY: pathY, bouncesRemaining: bounces, sourceTowerID: tower.id)
                        bowlingBalls.append(ball)
                        events.firedBalls.append(ball)
                        tower.cooldownRemaining = tower.cooldown
                    }
                }
                continue
            }

            // Healer: automatically heals a nearby damaged tower each cooldown
            if tower.type == .healer {
                if tower.cooldownRemaining <= 0 && tower.healCharges > 0 {
                    let target = towers.first {
                        $0.id != tower.id &&
                        $0.hitPoints < $0.maxHitPoints &&
                        $0.coord.distance(to: tower.coord) <= tower.healRadius
                    }
                    if let target {
                        target.hitPoints = min(target.hitPoints + 1, target.maxHitPoints)
                        tower.healCharges -= 1
                        tower.cooldownRemaining = tower.cooldown
                        events.healedTowers.append(target)
                    }
                }
                continue
            }

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
                        applyAreaDamage(cells: coneCells, dps: tower.fireDamagePerSecond, deltaTime: deltaTime, tower: tower, events: &events)
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

                    let killCountBefore = events.killedEnemies.count
                    if let target = lockedTarget {
                        _ = dealDamage(tower.beamDamagePerSecond * deltaTime, to: target, tower: tower, events: &events)
                    }

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
            let sourceTower = projectile.sourceTowerID.flatMap { id in towers.first { $0.id == id } }
            if let enemy = enemies.first(where: { $0.id == projectile.targetEnemyID && $0.active }) {
                if projectile.burnOnImpact {
                    // Fireball: AoE damage + burn to all enemies within splash radius of target
                    if let targetCoord = enemyNearestCoord(enemy) {
                        for splashTarget in enemies where splashTarget.active {
                            guard let splashCoord = enemyNearestCoord(splashTarget) else { continue }
                            if splashCoord.distance(to: targetCoord) <= projectile.splashRadius {
                                let hit = dealDamage(projectile.damage, to: splashTarget, tower: sourceTower, events: &events)
                                if hit {
                                    splashTarget.burning = true
                                    splashTarget.burnDPS = projectile.impactBurnDPS
                                    splashTarget.burnTimer = max(splashTarget.burnTimer, projectile.impactBurnDuration)
                                }
                            }
                        }
                    }
                } else {
                    dealDamage(projectile.damage, to: enemy, tower: sourceTower, events: &events)

                    // Max-level projectile tower: AoE explosion hits all enemies on same tile
                    if projectile.isAoE, let coord = enemyNearestCoord(enemy) {
                        for other in enemies where other.active && other.id != enemy.id {
                            guard let otherCoord = enemyNearestCoord(other) else { continue }
                            if otherCoord == coord {
                                dealDamage(projectile.damage, to: other, tower: sourceTower, events: &events)
                            }
                        }
                    }
                }
            }
            events.completedProjectiles.append(projectile)
        }
        projectiles.removeAll { $0.isComplete }

        // Process hive deaths — spawn 5 hoppers that drop from hive's elevated position
        for enemy in events.killedEnemies where enemy.enemyType == .hive {
            let spawnCell = enemy.currentCell
            let hiveWorldY = enemyWorldPosition(enemy)?.y ?? 0
            let hp: Float = 25 + Float(round) * 20
            let scatterRadius: Float = 0.4
            for i in 0..<5 {
                let hopper = makeEnemy(type: .hopper, hp: hp, speed: 1.2)
                hopper.currentCell = spawnCell
                hopper.progress = enemy.progress + Float(i) * 0.06
                hopper.isDroppingFromHive = true
                hopper.hiveDropFromY = hiveWorldY
                hopper.hiveDropProgress = 0
                let angle = Float(i) * (2 * .pi / 5)
                hopper.hiveDropLateralOffset = SIMD2<Float>(
                    cos(angle) * scatterRadius,
                    sin(angle) * scatterRadius
                )
                hopper.active = true
                enemies.append(hopper)
                events.spawnedEnemies.append(hopper)
            }
        }

        // Process exploder deaths — damage nearby towers
        for enemy in events.killedEnemies where enemy.explosionRadius > 0 {
            guard let coord = enemyNearestCoord(enemy) ?? enemy.currentCell?.coord else { continue }
            if let pos = enemyWorldPosition(enemy) {
                events.explosions.append(pos)
            }
            for tower in towers {
                if tower.coord.distance(to: coord) <= enemy.explosionRadius && !tower.isInvulnerable {
                    tower.hitPoints -= enemy.explosionDamage
                    if tower.hitPoints <= 0 {
                        events.destroyedTowers.append(tower)
                    } else {
                        events.damagedTowers.append(tower)
                    }
                }
            }
        }

        // Remove destroyed towers
        for tower in events.destroyedTowers {
            if let cell = hexGrid.cell(at: tower.coord) {
                cell.hasTower = false
            }
            // Stop any active effects
            if tower.isFiringBeam { events.beamsEnded.append(tower) }
            if tower.isFiringCone { events.conesEnded.append(tower) }
        }
        towers.removeAll { t in events.destroyedTowers.contains(where: { $0.id == t.id }) }

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
            for tower in towers where tower.type == .healer {
                tower.healCharges = tower.level
            }
        }

        return events
    }

    // MARK: - Enemy Movement

    /// Called when an enemy reaches the end tile and hits the base tower.
    private func updateBowlingBalls(deltaTime: Float, events: inout GameEvents) {
        for ball in bowlingBalls where ball.active {
            // Fall-in animation: hold position, just tick the timer
            if ball.isFalling {
                ball.fallTimer += deltaTime
                if ball.fallTimer >= ball.fallDuration {
                    ball.isFalling = false
                }
                events.movedBalls.append(ball)
                continue
            }

            // Move straight in world space
            ball.position.x += ball.direction.x * ball.speed * deltaTime
            ball.position.z += ball.direction.z * ball.speed * deltaTime

            // Check if current position is still over a path cell
            let coord = nearestHexCoord(worldX: ball.position.x, worldZ: ball.position.z)
            if let cell = hexGrid.cell(at: coord), cell.type == .path || cell.type == .start {
                ball.lastPathCell = cell
            } else {
                // Ball rolled off the path
                if ball.bouncesRemaining > 0, let lastCell = ball.lastPathCell {
                    // Bounce: reverse direction and snap back to last valid cell center
                    ball.direction = SIMD3(-ball.direction.x, 0, -ball.direction.z)
                    let cellPos = lastCell.coord.worldPosition(spacing: spacing)
                    ball.position.x = cellPos.x
                    ball.position.z = cellPos.y
                    ball.bouncesRemaining -= 1
                    ball.hitEnemyIDs.removeAll()  // can hit enemies again on the return
                } else {
                    ball.active = false
                    events.poppedBalls.append(ballWorldPosition(ball))
                    events.removedBalls.append(ball)
                    continue
                }
            }

            // Collide with nearby enemies
            let ballPos = ballWorldPosition(ball)
            let ballSourceTower = ball.sourceTowerID.flatMap { id in towers.first { $0.id == id } }
            for enemy in enemies where enemy.active && !ball.hitEnemyIDs.contains(enemy.id) {
                guard let enemyPos = enemyWorldPosition(enemy) else { continue }
                let dx = ballPos.x - enemyPos.x
                let dz = ballPos.z - enemyPos.z
                let dist = sqrt(dx * dx + dz * dz)
                if dist < (bowlingBallRadius + enemyRadius) * 1.5 {
                    dealDamage(ball.damage, to: enemy, tower: ballSourceTower, events: &events)
                    ball.hitEnemyIDs.insert(enemy.id)
                }
            }

            events.movedBalls.append(ball)
        }
        bowlingBalls.removeAll { !$0.active }
    }

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
        let distanceMoved = effectiveSpeed * deltaTime
        enemy.progress += distanceMoved / distance

        // Rolling: angular velocity = linear speed / visual radius
        let visualRadius = enemyVisualRadius(for: enemy.enemyType)
        enemy.rollDeltaAngle = distanceMoved / visualRadius
        // Roll axis is perpendicular to movement direction in XZ plane
        let dx = nextPos.x - currentPos.x
        let dz = nextPos.y - currentPos.y   // worldPosition .y is world Z
        let dirLen = sqrt(dx * dx + dz * dz)
        if dirLen > 0.001 {
            enemy.rollAxis = SIMD3(dz / dirLen, 0, -dx / dirLen)
        }

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

    /// Returns the visual sphere/box radius used when rendering this enemy type.
    private func enemyVisualRadius(for type: EnemyType) -> Float {
        switch type {
        case .basic:         return enemyRadius
        case .hopper:        return enemyRadius * 1.1
        case .tank:          return enemyRadius * 2.0
        case .mirroid:       return enemyRadius * 2.0
        case .wisp:          return enemyRadius * 0.9
        case .fastTank:      return enemyRadius * 2.0
        case .shield:        return enemyRadius * 1.5
        case .superHopper:   return enemyRadius * 1.5
        case .boss:          return enemyRadius * 1.5   // half of box width (3r)
        case .exploder:      return enemyRadius * 1.1   // half of box width (2.2r)
        case .superExploder: return enemyRadius * 1.5   // half of box width (3r)
        case .hive:          return enemyRadius * 2.5
        }
    }

    private func updateHopper(_ enemy: Enemy, deltaTime: Float) {
        if enemy.isDroppingFromHive {
            let dropDuration: Float = 0.55
            enemy.hiveDropProgress = min(1.0, enemy.hiveDropProgress + deltaTime / dropDuration)
            if enemy.hiveDropProgress >= 1.0 {
                enemy.isDroppingFromHive = false
                enemy.hopperJumpTimer = Float.random(in: enemy.hopperJumpInterval)
            }
            return
        }

        if enemy.isJumping {
            // Spin during the jump arc based on horizontal distance
            if let from = enemy.jumpFromPos, let to = enemy.jumpToPos {
                let dx = to.x - from.x
                let dz = to.z - from.z
                let horizDist = sqrt(dx * dx + dz * dz)
                let horizSpeed = horizDist / enemy.jumpDuration
                let visualRadius = enemyVisualRadius(for: enemy.enemyType)
                enemy.rollDeltaAngle = (horizSpeed * deltaTime) / visualRadius
                if horizDist > 0.001 {
                    enemy.rollAxis = SIMD3(dz / horizDist, 0, -dx / horizDist)
                }
            }
            enemy.jumpProgress = min(1.0, enemy.jumpProgress + deltaTime / enemy.jumpDuration)
            if enemy.jumpProgress >= 1.0 {
                // Landed — clear jump state and set next timer
                enemy.isJumping = false
                enemy.jumpProgress = 0
                enemy.jumpFromPos = nil
                enemy.jumpToPos = nil
                enemy.hopperJumpTimer = Float.random(in: enemy.hopperJumpInterval)
                // If landed on end cell (no next), reach end
                if enemy.currentCell?.next == nil {
                    enemy.reachedEnd = true
                    enemy.active = false
                }
            }
        } else {
            enemy.hopperJumpTimer -= deltaTime
            if enemy.hopperJumpTimer <= 0 {
                triggerHopperJump(enemy)
            }
        }
    }

    private func triggerHopperJump(_ enemy: Enemy) {
        guard let current = enemy.currentCell else { return }
        let jumpRadius = Int.random(in: enemy.hopperJumpRange)

        let fromPos = enemyWorldPosition(enemy) ?? {
            let p = current.coord.worldPosition(spacing: spacing)
            return SIMD3(p.x, current.height + enemyRadius + enemyHoverOffset, p.y)
        }()

        let landCell: HexCell?

        if enemy.enemyType == .superHopper {
            // Super hopper: search all path cells within hex radius, jump to the
            // one furthest ahead on the path toward the end tower.
            let currentDepth = pathDepth(of: current)
            var best: HexCell? = nil
            var bestDepth = currentDepth

            for cell in hexGrid.cells.values {
                guard cell.type == .path || cell.type == .end else { continue }
                guard cell.coord.distance(to: current.coord) <= jumpRadius else { continue }
                guard cell.coord != current.coord else { continue }
                let depth = pathDepth(of: cell)
                if depth > bestDepth {
                    bestDepth = depth
                    best = cell
                }
            }
            landCell = best
        } else {
            // Normal hopper: walk forward along path by jumpRadius steps.
            var target: HexCell? = current
            for _ in 0..<jumpRadius { target = target?.next }
            landCell = target

            if landCell == nil {
                // Walked past the end
                enemy.reachedEnd = true
                enemy.active = false
                return
            }
        }

        guard let landCell else {
            // Super hopper found no valid target — skip this jump
            enemy.hopperJumpTimer = Float.random(in: enemy.hopperJumpInterval)
            return
        }

        // Advance the enemy to the target cell immediately
        enemy.currentCell = landCell
        enemy.progress = 0
        let toPos = enemyWorldPosition(enemy) ?? fromPos
        enemy.jumpFromPos = fromPos
        enemy.jumpToPos = toPos
        enemy.isJumping = true
        enemy.jumpProgress = 0
    }

    /// Returns the number of steps from the start of the path to this cell
    /// by walking the `.previous` chain.
    private func pathDepth(of cell: HexCell) -> Int {
        var depth = 0
        var walker: HexCell? = cell
        while let prev = walker?.previous {
            depth += 1
            walker = prev
        }
        return depth
    }

    /// Computes world position for an enemy using Catmull-Rom interpolation.
    func enemyWorldPosition(_ enemy: Enemy) -> SIMD3<Float>? {
        // Hopper arc override while mid-jump
        if (enemy.enemyType == .hopper || enemy.enemyType == .superHopper), enemy.isJumping,
           let from = enemy.jumpFromPos, let to = enemy.jumpToPos {
            let t = enemy.jumpProgress
            let x = from.x + (to.x - from.x) * t
            let z = from.z + (to.z - from.z) * t
            let arcHeight: Float = 1.8
            let y = from.y + (to.y - from.y) * t + arcHeight * sin(.pi * t)
            return [x, y, z]
        }

        // Drop-from-hive animation: scatter outward from hive, converge to path on land
        if enemy.isDroppingFromHive, let current = enemy.currentCell {
            let pos = current.coord.worldPosition(spacing: spacing)
            let targetY = current.height + enemyRadius + enemyHoverOffset
            let t = enemy.hiveDropProgress * enemy.hiveDropProgress  // ease-in (gravity feel)
            let y = enemy.hiveDropFromY + (targetY - enemy.hiveDropFromY) * t
            let fade = 1 - enemy.hiveDropProgress  // lateral offset fades to zero as they land
            let ox = enemy.hiveDropLateralOffset.x * fade
            let oz = enemy.hiveDropLateralOffset.y * fade
            return [pos.x + ox, y, pos.y + oz]
        }

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

            return [x, y + enemy.additionalHoverOffset, z]
        } else {
            return [p1Pos.x, p1Y + enemy.additionalHoverOffset, p1Pos.y]
        }
    }

    // MARK: - Tower Firing Logic

    /// Returns the hex coord the enemy is closest to.
    func enemyNearestCoord(_ enemy: Enemy) -> HexCoord? {
        guard let cell = enemy.currentCell else { return nil }
        if enemy.progress < 0.5 {
            return cell.coord
        }
        return cell.next?.coord ?? cell.coord
    }

    /// How far along the path an enemy is (higher = closer to end).
    /// Counts remaining steps to end, negated so that further ahead = higher value.
    private func enemyPathProgress(_ enemy: Enemy) -> Int {
        var steps = 0
        var cell = enemy.currentCell?.next
        while let c = cell { steps += 1; cell = c.next }
        return -steps
    }

    /// Selects the best enemy target for a tower based on its targeting mode.
    private func selectTarget(for tower: Tower) -> Enemy? {
        // Gather enemies in detection radius
        var candidates: [(enemy: Enemy, dist: Int)] = []
        for enemy in enemies where enemy.active {
            if !tower.targetTypeRestrictions.isEmpty && !tower.targetTypeRestrictions.contains(enemy.enemyType) { continue }
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            let dist = tower.coord.distance(to: enemyCoord)
            if dist <= tower.detectionRadius {
                candidates.append((enemy, dist))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Laser max-level: if a priority enemy type is set, target it first.
        // If multiple match, the normal targeting mode breaks the tie.
        // If none are in range, fall through to standard logic.
        if let priorityType = tower.priorityEnemyType {
            let priorityMatches = candidates.filter { $0.enemy.enemyType == priorityType }
            if !priorityMatches.isEmpty {
                switch tower.targetingMode {
                case .closest:
                    return priorityMatches.min(by: { $0.dist < $1.dist })?.enemy
                case .furthestAhead:
                    return priorityMatches.max(by: { enemyPathProgress($0.enemy) < enemyPathProgress($1.enemy) })?.enemy
                case .furthestBehind:
                    return priorityMatches.min(by: { enemyPathProgress($0.enemy) < enemyPathProgress($1.enemy) })?.enemy
                case .mostHealth:
                    return priorityMatches.max(by: { $0.enemy.hitPoints < $1.enemy.hitPoints })?.enemy
                case .leastHealth:
                    return priorityMatches.min(by: { $0.enemy.hitPoints < $1.enemy.hitPoints })?.enemy
                }
            }
        }

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
                return (SIMD3<Float>(pos.x, cell.height + enemyRadius + enemyHoverOffset + enemy.additionalHoverOffset, pos.y), cell.coord)
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
            let y = cell.height + (nextCell.height - cell.height) * progress + enemyRadius + enemyHoverOffset + enemy.additionalHoverOffset
            let nearestCoord = progress < 0.5 ? cell.coord : nextCell.coord
            return (SIMD3<Float>(x, y, z), nearestCoord)
        } else {
            return (SIMD3<Float>(cellPos.x, cell.height + enemyRadius + enemyHoverOffset + enemy.additionalHoverOffset, cellPos.y), cell.coord)
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
            if !tower.targetTypeRestrictions.isEmpty && !tower.targetTypeRestrictions.contains(enemy.enemyType) { continue }
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

            // Check if predicted position is within fire radius (and outside minimum range for fireball)
            let predictedHexDist = tower.coord.distance(to: prediction.coord)
            if predictedHexDist > tower.fireRadius { continue }
            if tower.type == .fireball && predictedHexDist < 2 { continue }

            // Refine: compute actual flight time to predicted position
            let actualDist = simd_distance(towerOrigin, prediction.position)
            let actualFlightTime = actualDist / tower.projectileSpeed

            let isFireball = tower.type == .fireball
            let isAntiAir = tower.type == .antiAir
            return Projectile(
                origin: towerOrigin,
                target: prediction.position,
                totalFlightTime: actualFlightTime,
                damage: tower.damage,
                targetEnemyID: enemy.id,
                isAoE: !isFireball && tower.level == Tower.maxLevel,
                sourceTowerID: tower.id,
                burnOnImpact: isFireball,
                impactBurnDPS: isFireball ? tower.fireDamagePerSecond : 0,
                impactBurnDuration: isFireball ? tower.fireDuration : 0,
                splashRadius: isFireball ? tower.splashRadius : 0,
                arcHeight: isAntiAir ? 0.0 : 1.0
            )
        }

        return nil
    }

    // MARK: - Damage Helpers

    /// Finds a nearby active shielder protecting the given coord (within 1 hex).
    private func findShielder(near coord: HexCoord) -> Enemy? {
        for enemy in enemies where enemy.active && enemy.enemyType == .shield && enemy.shieldActive {
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
    private func dealDamage(_ amount: Float, to enemy: Enemy, tower: Tower? = nil, events: inout GameEvents) -> Bool {
        guard enemy.active else { return false }
        if let tower, enemy.immuneTowerTypes.contains(tower.type) { return false }
        let baseReward = enemy.enemyType == .boss ? 5 * round : killReward
        let reward = tower?.hasMoneyDoubler == true ? baseReward * 2 : baseReward

        guard let coord = enemyNearestCoord(enemy) else {
            let actualDamage = min(amount, max(0, enemy.hitPoints))
            tower?.totalDamageDealt += actualDamage
            if let t = tower { statsDamage[t.type, default: 0] += actualDamage }
            enemy.hitPoints -= amount
            if enemy.hitPoints <= 0 {
                enemy.active = false
                tower?.totalKills += 1
                if let t = tower {
                    statsKills[t.type, default: 0] += 1
                    statsKillsByEnemy[t.type, default: [:]][enemy.enemyType, default: 0] += 1
                    print("[Kill] \(t.type) killed \(enemy.enemyType)")
                } else {
                    print("[Kill] (no tower) killed \(enemy.enemyType)")
                }
                money += reward
                events.killedEnemies.append(enemy)
                return true
            }
            return false
        }

        var remaining = amount
        if damageAuraPathCoords.contains(coord) {
            remaining *= 1.4
        }
        if let shielder = findShielder(near: coord) {
            let absorbed = min(shielder.shieldHP, remaining)
            shielder.shieldHP -= absorbed
            remaining -= absorbed
            if shielder.shieldHP <= 0 {
                events.shieldsBroken.append(shielder)
            }
        }

        if remaining > 0 {
            let actualDamage = min(remaining, max(0, enemy.hitPoints))
            tower?.totalDamageDealt += actualDamage
            if let t = tower { statsDamage[t.type, default: 0] += actualDamage }
            enemy.hitPoints -= remaining
        }
        if enemy.hitPoints <= 0 {
            enemy.active = false
            tower?.totalKills += 1
            if let t = tower {
                statsKills[t.type, default: 0] += 1
                statsKillsByEnemy[t.type, default: [:]][enemy.enemyType, default: 0] += 1
                print("[Kill] \(t.type) killed \(enemy.enemyType)")
            } else {
                print("[Kill] (no tower) killed \(enemy.enemyType)")
            }
            money += reward
            events.killedEnemies.append(enemy)
            return true
        }
        return false
    }

    private func applyAreaDamage(cells: [HexCoord], dps: Float, deltaTime: Float, tower: Tower? = nil, events: inout GameEvents) {
        for enemy in enemies where enemy.active {
            guard let enemyCoord = enemyNearestCoord(enemy) else { continue }
            if cells.contains(enemyCoord) {
                dealDamage(dps * deltaTime, to: enemy, tower: tower, events: &events)
            }
        }
    }

    private func applyBurning(cells: [HexCoord]) {
        for enemy in enemies where enemy.active {
            guard !enemy.immuneTowerTypes.contains(.fire) else { continue }
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

    // MARK: - Base Tower Position

    /// Returns the end cell where the base tower is placed.
    var endCell: HexCell? {
        hexGrid.cells.values.first(where: { $0.type == .end })
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
