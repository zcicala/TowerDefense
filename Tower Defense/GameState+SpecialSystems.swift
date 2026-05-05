import Foundation
import simd

extension GameState {

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

    // MARK: - Bowling

    /// Returns the best entry path cell for a bowler — whichever adjacent path direction
    /// has enemies nearest to it in world space. Falls back to most-upstream if no enemies nearby.
    func bowlerEntryCell(for tower: Tower) -> HexCell? {
        let candidates = hexGrid.neighbors(of: tower.coord)
            .filter { $0.type == .path || $0.type == .start }
        guard !candidates.isEmpty else { return nil }

        // Pick the cell whose world position is closest to any active enemy
        return candidates.min { a, b in
            let distA = minEnemyDistance(to: a.coord)
            let distB = minEnemyDistance(to: b.coord)
            // If both have no enemies, prefer most-upstream
            if distA == .infinity && distB == .infinity {
                return pathStepsRemaining(a) > pathStepsRemaining(b)
            }
            return distA < distB
        }
    }

    /// Minimum world-space distance from any active enemy to the given coord.
    private func minEnemyDistance(to coord: HexCoord) -> Float {
        let cellPos = coord.worldPosition(spacing: spacing)
        return enemies.filter(\.active).reduce(Float.infinity) { best, enemy in
            guard let ePos = enemyWorldPosition(enemy) else { return best }
            let dx = ePos.x - cellPos.x
            let dz = ePos.z - cellPos.y
            return min(best, sqrt(dx*dx + dz*dz))
        }
    }

    private func pathStepsRemaining(_ cell: HexCell) -> Int {
        var steps = 0
        var current: HexCell? = cell
        while let c = current { steps += 1; current = c.next }
        return steps
    }

    /// World position of the ball, interpolating Y during the fall-in animation.
    func ballWorldPosition(_ ball: BowlingBall) -> SIMD3<Float> {
        let coord = nearestHexCoord(worldX: ball.position.x, worldZ: ball.position.z)
        let cellHeight = hexGrid.cell(at: coord)?.height ?? 0
        let rollingY = cellHeight + bowlingBallRadius
        if ball.isFalling {
            // Ease-in: slow at top, fast at bottom
            let t = ball.fallProgress
            let easedT = t * t
            let y = ball.startY + (rollingY - ball.startY) * easedT
            return SIMD3(ball.position.x, y, ball.position.z)
        }
        return SIMD3(ball.position.x, rollingY, ball.position.z)
    }

    /// World-space origin and tip for the sword blade this frame.
    /// For the swipe, this returns the current animated position based on sweep progress.
    func bladePositions(for tower: Tower) -> [(origin: SIMD3<Float>, tip: SIMD3<Float>)] {
        guard let towerCell = hexGrid.cell(at: tower.coord) else { return [] }
        let towerPos = tower.coord.worldPosition(spacing: spacing)
        let bladeY = towerCell.height + 0.45
        let origin = SIMD3<Float>(towerPos.x, bladeY, towerPos.y)

        if tower.level == Tower.maxLevel && tower.isFiringBlade {
            // Single blade at current sweep angle
            let currentAngle = tower.bladeSwipeStartAngle + (tower.bladeSwipeEndAngle - tower.bladeSwipeStartAngle) * tower.bladeSweepProgress
            // Scale: extend in first 15%, full during middle, retract in last 15%
            let scaleT: Float
            if tower.bladeSweepProgress < 0.15 {
                scaleT = tower.bladeSweepProgress / 0.15
            } else if tower.bladeSweepProgress > 0.85 {
                scaleT = (1.0 - tower.bladeSweepProgress) / 0.15
            } else {
                scaleT = 1.0
            }
            let len = swordBladeLength * scaleT
            let tip = SIMD3<Float>(
                towerPos.x + sin(currentAngle) * len,
                bladeY,
                towerPos.y + cos(currentAngle) * len
            )
            return [(origin, tip)]
        } else if let coord = tower.bladeTargetCoord {
            guard let cell = hexGrid.cell(at: coord) else { return [] }
            let pos = coord.worldPosition(spacing: spacing)
            let dx = pos.x - towerPos.x
            let dz = pos.y - towerPos.y
            let dist = sqrt(dx*dx + dz*dz)
            guard dist > 0 else { return [] }
            let tip = SIMD3<Float>(
                towerPos.x + (dx/dist) * swordBladeLength,
                cell.height + 0.45,
                towerPos.y + (dz/dist) * swordBladeLength
            )
            return [(origin, tip)]
        }
        return []
    }

    /// Direction vector for a ball: from the tower toward the adjacent path entry cell.
    func bowlerBallDirection(tower: Tower, entry: HexCell) -> SIMD3<Float> {
        let from = tower.coord.worldPosition(spacing: spacing)
        let to   = entry.coord.worldPosition(spacing: spacing)
        let dx = to.x - from.x
        let dz = to.y - from.y
        let len = sqrt(dx*dx + dz*dz)
        guard len > 0 else { return SIMD3(1, 0, 0) }
        return SIMD3(dx / len, 0, dz / len)
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

    /// Computes the world-space beam endpoint — the locked beam target's position.
    func beamEndpoint(for tower: Tower) -> SIMD3<Float> {
        // Use the locked beam target if present — this matches what's actually being damaged.
        if let lockedID = tower.beamTargetID,
           let enemy = enemies.first(where: { $0.id == lockedID && $0.active }),
           let pos = enemyWorldPosition(enemy) {
            return pos
        }

        // Fallback: find closest active enemy in detection radius
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
    func nearestHexCoord(worldX: Float, worldZ: Float) -> HexCoord {
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
}
