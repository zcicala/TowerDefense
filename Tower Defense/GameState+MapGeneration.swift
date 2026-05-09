import Foundation

extension GameState {

    // MARK: - Map Generation

    func generateMap() {
        generatePath()
        ringItemCount = 1
        moveTowerItemCount = 1
    }

    /// Adds a ring of terrain tiles around the base tower (end cell) as the starting board.
    @discardableResult
    func seedTerrainAroundBase() -> [HexCell] {
        guard let endCell = hexGrid.cells.values.first(where: { $0.type == .end }) else { return [] }
        return expandTerrainAround(coord: endCell.coord)
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
            if hexGrid.cell(at: next) != nil || wouldTouchPath(at: next, except: coord) {
                // Fallback: try other directions
                var found = false
                for offset in 1...5 {
                    let tryDir = (dir + offset) % 6
                    let candidate = coord.neighbor(tryDir)
                    if hexGrid.cell(at: candidate) == nil && !wouldTouchPath(at: candidate, except: coord) {
                        dir = tryDir
                        next = candidate
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

    /// Returns true if placing a path cell at `candidate` would make it adjacent to any existing
    /// path cell other than `predecessor` (the cell we're stepping from).
    private func wouldTouchPath(at candidate: HexCoord, except predecessor: HexCoord) -> Bool {
        for dir in 0..<6 {
            let neighbor = candidate.neighbor(dir)
            guard neighbor != predecessor else { continue }
            if let cell = hexGrid.cell(at: neighbor),
               cell.type == .path || cell.type == .start || cell.type == .end {
                return true
            }
        }
        return false
    }

    /// Creates a terrain cell at the given coord (using neighbour heights) and adds it to the grid.
    @discardableResult
    private func makeTerrainCell(at coord: HexCoord) -> HexCell {
        let neighbors = hexGrid.neighbors(of: coord)
        let terrainHeight: Float
        if neighbors.isEmpty {
            terrainHeight = Float.random(in: 0.5...2.0)
        } else {
            let avg = neighbors.map(\.height).reduce(0, +) / Float(neighbors.count)
            terrainHeight = avg * Float.random(in: 0.80...1.20)
        }
        let cell = HexCell(coord: coord, height: terrainHeight, type: .terrain)
        hexGrid.addCell(cell)
        return cell
    }

    /// Picks a random empty neighbor of a random path cell and adds a terrain tile there.
    func addSingleTerrainTileAlongPath() -> HexCell? {
        let pathCells = hexGrid.cells.values.filter { $0.type == .path || $0.type == .start }
        // Shuffle path cells so we pick randomly along the whole path
        var candidates: [HexCoord] = []
        for cell in pathCells {
            for dir in 0..<6 {
                let n = cell.coord.neighbor(dir)
                if hexGrid.cell(at: n) == nil { candidates.append(n) }
            }
        }
        // Deduplicate
        let unique = Array(Set(candidates))
        guard let coord = unique.randomElement() else { return nil }
        return makeTerrainCell(at: coord)
    }

    /// Adds up to 2 random terrain tiles among the empty neighbours of a coord. Returns new cells.
    func expandTerrainAround(coord: HexCoord) -> [HexCell] {
        let emptyNeighbors = (0..<6)
            .map { coord.neighbor($0) }
            .filter { hexGrid.cell(at: $0) == nil }
            .shuffled()
            .prefix(2)
        return emptyNeighbors.map { makeTerrainCell(at: $0) }
    }

    // MARK: - Tower Placement

    /// Places a tower on a terrain cell. Returns the tower and any new terrain cells added around it.
    func placeTower(at coord: HexCoord) -> (Tower, [HexCell])? {
        guard phase == .placing, let type = selectedTowerType else { return nil }
        let cost = costForTower(type)
        guard money >= cost else { return nil }
        guard let cell = hexGrid.cell(at: coord) else { return nil }
        guard cell.type == .terrain && !cell.hasTower else { return nil }

        if type == .bowler || type == .sword {
            let hasPathNeighbor = hexGrid.neighbors(of: coord).contains {
                $0.type == .path || $0.type == .start
            }
            guard hasPathNeighbor else { return nil }
        }

        money -= cost
        towerPlacedCount[type, default: 0] += 1
        statsTowerBuilt[type, default: 0] += 1
        cell.hasTower = true
        let tower: Tower
        switch type {
        case .projectile:
            tower = Tower(coord: coord)
        case .laser:
            tower = Tower.makeLaser(coord: coord)
        case .fire:
            tower = Tower.makeFire(coord: coord)
        case .ice:
            tower = Tower.makeIce(coord: coord)
        case .bowler:
            tower = Tower.makeBowler(coord: coord)
        case .sword:
            tower = Tower.makeSword(coord: coord)
        case .healer:
            tower = Tower.makeHealer(coord: coord)
        case .fireball:
            tower = Tower.makeFireball(coord: coord)
        case .antiAir:
            tower = Tower.makeAntiAir(coord: coord)
        case .targeting:
            tower = Tower.makeTargeting(coord: coord)
        }
        tower.moneySpent = cost

        // Apply and consume any bonus on this cell
        if let bonus = cell.bonusType {
            switch bonus {
            case .freeUpgrade:
                tower.applyUpgrade()
                tower.applyUpgrade()
                tower.applyUpgrade()
            case .invulnerable:
                tower.isInvulnerable = true
            case .doubleRing:
                ringItemCount += 2
            case .goldCache:
                money += 150
            case .slowAura:
                slowAuraItemCount += 1
            case .damageAura:
                damageAuraItemCount += 1
            case .repair:
                repairItemCount += 1
            case .moveTower:
                moveTowerItemCount += 1
            case .moneyDoubler:
                tower.hasMoneyDoubler = true
            case .rangeExtender:
                tower.detectionRadius += 1
                tower.fireRadius += 1
                if tower.type == .laser { tower.laser?.range += 1 }
            case .pauseControl:
                hasPauseControl = true
            }
            cell.bonusType = nil
        }

        towers.append(tower)
        let newTerrain = expandTerrainAround(coord: coord)
        return (tower, newTerrain)
    }

    func tower(at coord: HexCoord) -> Tower? {
        towers.first(where: { $0.coord == coord })
    }

    /// Upgrades a tower if affordable. Returns true on success.

    /// Heals a tower by 1 HP for $75. Returns true on success.
    func repairTower(_ tower: Tower) -> Bool {
        guard tower.hitPoints < tower.maxHitPoints, money >= repairCost else { return false }
        money -= repairCost
        tower.hitPoints += 1
        return true
    }

    func upgradeTower(_ tower: Tower) -> Bool {
        guard tower.canUpgrade else { return false }
        let cost = tower.upgradeCost
        guard money >= cost else { return false }
        money -= cost
        tower.moneySpent += cost
        tower.applyUpgrade()
        return true
    }

    /// Expands a full ring of terrain around the chosen coord and clears ring-bonus mode.
    /// Returns all newly created cells.
    @discardableResult
    func applyRingBonus(at coord: HexCoord) -> [HexCell] {
        let newCells = (0..<6)
            .map { coord.neighbor($0) }
            .filter { hexGrid.cell(at: $0) == nil }
            .map { makeTerrainCell(at: $0) }
        pendingRingBonus = false
        return newCells
    }

    func cancelPendingRingBonus() {
        if pendingRingBonus { ringItemCount += 1 }
        pendingRingBonus = false
    }

    // MARK: - Inventory Actions

    func activateRingItem() {
        guard ringItemCount > 0, !pendingRingBonus else { return }
        ringItemCount -= 1
        pendingRingBonus = true
    }

    func useRepairItem() {
        guard repairItemCount > 0 else { return }
        repairItemCount -= 1
        baseTowerHP = min(baseTowerMaxHP, baseTowerHP + 1)
    }

    func activateSlowAuraItem() {
        guard slowAuraItemCount > 0, !isPendingSlowAura else { return }
        slowAuraItemCount -= 1
        isPendingSlowAura = true
    }

    func activateDamageAuraItem() {
        guard damageAuraItemCount > 0, !isPendingDamageAura else { return }
        damageAuraItemCount -= 1
        isPendingDamageAura = true
    }

    func activateMoveTower() {
        guard moveTowerItemCount > 0, !isSelectingTowerToMove, pendingMoveTower == nil else { return }
        moveTowerItemCount -= 1
        isSelectingTowerToMove = true
    }

    func cancelPendingMoveTower() {
        if isSelectingTowerToMove || pendingMoveTower != nil {
            moveTowerItemCount += 1
        }
        isSelectingTowerToMove = false
        pendingMoveTower = nil
    }

    func selectTowerToMove(_ tower: Tower) {
        guard isSelectingTowerToMove else { return }
        isSelectingTowerToMove = false
        pendingMoveTower = tower
    }

    /// Moves `pendingMoveTower` to `coord`. Returns true on success.
    @discardableResult
    func applyMoveTower(to coord: HexCoord) -> Bool {
        guard let tower = pendingMoveTower else { return false }
        guard let oldCell = hexGrid.cell(at: tower.coord) else { return false }
        guard let newCell = hexGrid.cell(at: coord),
              newCell.type == .terrain, !newCell.hasTower else { return false }
        if tower.type == .bowler || tower.type == .sword {
            guard hexGrid.neighbors(of: coord).contains(where: { $0.type == .path || $0.type == .start }) else { return false }
        }
        oldCell.hasTower = false
        newCell.hasTower = true
        tower.coord = coord
        pendingMoveTower = nil
        return true
    }

    // MARK: - Return to Placing Phase

    /// All terrain cells that currently have a bonus.
    var bonusCells: [HexCell] {
        hexGrid.cells.values.filter { $0.isBonus }
    }

    /// All path cell coords currently under a slow aura effect.
    var slowAuraPathCoords: Set<HexCoord> {
        var coords = towers.reduce(into: Set<HexCoord>()) { $0.formUnion($1.slowedCoords) }
        coords.formUnion(globalSlowAuraCoords)
        return coords
    }

    /// Applies a slow aura to the picked path tile and its neighbours, then clears the pending state.
    func applySlowAuraTarget(pathCoord: HexCoord) {
        guard isPendingSlowAura, let cell = hexGrid.cell(at: pathCoord) else { return }
        globalSlowAuraCoords.insert(pathCoord)
        if let prev = cell.previous { globalSlowAuraCoords.insert(prev.coord) }
        if let next = cell.next     { globalSlowAuraCoords.insert(next.coord) }
        isPendingSlowAura = false
    }

    func cancelPendingSlowAura() {
        if isPendingSlowAura { slowAuraItemCount += 1 }
        isPendingSlowAura = false
    }

    /// All path cell coords currently under a damage aura effect.
    var damageAuraPathCoords: Set<HexCoord> {
        var coords = towers.reduce(into: Set<HexCoord>()) { $0.formUnion($1.damageAuraCoords) }
        coords.formUnion(globalDamageAuraCoords)
        return coords
    }

    /// Applies a damage aura to the picked path tile and its neighbours, then clears the pending state.
    func applyDamageAuraTarget(pathCoord: HexCoord) {
        guard isPendingDamageAura, let cell = hexGrid.cell(at: pathCoord) else { return }
        globalDamageAuraCoords.insert(pathCoord)
        if let prev = cell.previous { globalDamageAuraCoords.insert(prev.coord) }
        if let next = cell.next     { globalDamageAuraCoords.insert(next.coord) }
        isPendingDamageAura = false
    }

    func cancelPendingDamageAura() {
        if isPendingDamageAura { damageAuraItemCount += 1 }
        isPendingDamageAura = false
    }

    /// Assigns a random bonus to a random unoccupied terrain cell.
    private func assignBonusTile() {
        let candidates = hexGrid.cells.values.filter {
            $0.type == .terrain && !$0.hasTower && $0.bonusType == nil
        }
        guard let cell = candidates.randomElement() else { return }
        cell.bonusType = BonusType.allCases.randomElement()
    }

    /// Returns true if the currently selected tower type can be placed at coord (without consuming resources).
    func isValidPlacement(at coord: HexCoord) -> Bool {
        guard phase == .placing, let type = selectedTowerType else { return false }
        guard money >= costForTower(type) else { return false }
        guard let cell = hexGrid.cell(at: coord) else { return false }
        guard cell.type == .terrain && !cell.hasTower else { return false }
        if type == .bowler || type == .sword {
            return hexGrid.neighbors(of: coord).contains { $0.type == .path || $0.type == .start }
        }
        return true
    }

    /// Returns path cells within the given tower type's fire range from coord.
    func allCellsInFireRange(from coord: HexCoord, type: TowerType) -> [HexCell] {
        var radius: Int
        switch type {
        case .projectile: radius = 4
        case .laser:      radius = 7
        case .fire:       radius = 1
        case .ice:        radius = 2
        case .bowler:     radius = 5
        case .sword:      radius = 1
        case .healer:     radius = 1
        case .fireball:   radius = 4
        case .antiAir:    radius = 9
        case .targeting:  radius = 3
        }
        if hexGrid.cell(at: coord)?.bonusType == .rangeExtender { radius += 1 }
        return hexGrid.cells.values.filter { coord.distance(to: $0.coord) <= radius }
    }

    /// Transitions back to placing phase. Returns any newly added terrain/path cells.
    func returnToPlacing() -> [HexCell] {
        guard phase == .roundOver else { return [] }
        // After the first boss (round 5), give 2 bonus tiles every 5 rounds
        if round % 5 == 0 && round >= 5 {
            assignBonusTile()
            assignBonusTile()
        }
        phase = .placing
        selectedTowerType = nil
        enemies.removeAll()
        projectiles.removeAll()
        bowlingBalls.removeAll()
        for tower in towers {
            if tower.laser?.isFiring == true {
                tower.laser!.isFiring = false
                tower.laser!.timeRemaining = 0
                tower.laser!.lockedTargetID = nil
            }
            if tower.cone?.isFiring == true {
                tower.cone!.isFiring = false
                tower.cone!.timeRemaining = 0
                tower.cone!.targetCoord = nil
                tower.cone!.lockedTargetID = nil
            }
            if tower.sword?.isFiring == true {
                tower.sword = SwordState(swingDuration: tower.sword!.swingDuration)
            }
        }
        // Add one terrain tile adjacent to the path each round
        var newCells: [HexCell] = []
        if let cell = addSingleTerrainTileAlongPath() {
            newCells.append(cell)
        }
        // Every 15 rounds add a new branch spawn path
        if round % 10 == 0 && round > 0 {
            newCells.append(contentsOf: addBranchPath())
        }
        return newCells
    }

    // MARK: - Branch Paths

    /// Grows a new 10-cell branch path off a random existing path cell. Returns the new cells (path + start).
    @discardableResult
    func addBranchPath() -> [HexCell] {
        let pathCells = hexGrid.cells.values.filter { $0.type == .path }.shuffled()
        for junction in pathCells {
            if let cells = tryGenerateBranch(from: junction, length: 10) {
                for cell in cells { hexGrid.addCell(cell) }
                return cells
            }
        }
        return []
    }

    private func tryGenerateBranch(from junction: HexCell, length: Int) -> [HexCell]? {
        let freeDirs = (0..<6).filter { hexGrid.cell(at: junction.coord.neighbor($0)) == nil }
        guard let startDir = freeDirs.randomElement() else { return nil }
        var dir = startDir
        var current = junction.coord
        var placedCoords: [HexCoord] = []
        for _ in 0..<length {
            var placed = false
            for offset in 0..<6 {
                let tryDir = (dir + offset) % 6
                let candidate = current.neighbor(tryDir)
                // Reject occupied cells, self-touching branch cells, or cells adjacent to
                // existing path cells other than the direct predecessor.
                let touchesGrid = wouldTouchPath(at: candidate, except: current)
                let touchesSelf = placedCoords.dropLast().contains(candidate)
                if hexGrid.cell(at: candidate) == nil && !placedCoords.contains(candidate)
                    && !touchesGrid && !touchesSelf {
                    if offset > 0 { dir = tryDir }
                    placedCoords.append(candidate)
                    current = candidate
                    placed = true
                    break
                }
            }
            if !placed { return nil }
            if Float.random(in: 0..<1) < 0.3 { dir = (dir + (Bool.random() ? 1 : 5)) % 6 }
        }
        var cells: [HexCell] = []
        var height = junction.height
        for (i, coord) in placedCoords.enumerated() {
            height *= Float.random(in: 0.92...1.08)
            let isStart = i == placedCoords.count - 1
            let cell = HexCell(coord: coord, height: height, type: isStart ? .start : .path)
            cells.append(cell)
        }
        // Link: outermost (new .start) → ... → innermost → junction
        for i in 0..<(cells.count - 1) {
            cells[i + 1].next = cells[i]
            cells[i].previous = cells[i + 1]
        }
        cells[0].next = junction
        return cells
    }

    /// Resets the entire game. Returns removed tower IDs, removed terrain coords, and the new seed cells around the base.
    func restart() -> (towerIDs: [UUID], removedTerrainCoords: [HexCoord], seedCells: [HexCell]) {
        let towerIDs = towers.map(\.id)
        // Remove all terrain cells — they'll be re-grown gradually each round
        let terrainCoords = hexGrid.cells.values
            .filter { $0.type == .terrain }
            .map { $0.coord }
        for coord in terrainCoords { hexGrid.removeCell(at: coord) }
        phase = .placing
        round = 0
        money = 100
        selectedTowerType = nil
        baseTowerHP = baseTowerMaxHP
        baseTowerBlocksRemaining = 5
        baseTowerDamageAccumulated = 0
        baseSentinelTower = nil
        towers.removeAll()
        enemies.removeAll()
        projectiles.removeAll()
        bowlingBalls.removeAll()
        towerPlacedCount.removeAll()
        statsTowerBuilt.removeAll()
        statsKills.removeAll()
        statsDamage.removeAll()
        statsKillsByEnemy.removeAll()
        pendingRingBonus = false
        ringItemCount = 1
        repairItemCount = 0
        slowAuraItemCount = 0
        damageAuraItemCount = 0
        moveTowerItemCount = 1
        isPendingSlowAura = false
        isPendingDamageAura = false
        globalSlowAuraCoords = []
        globalDamageAuraCoords = []
        isSelectingTowerToMove = false
        pendingMoveTower = nil
        hasPauseControl = false
        isPaused = false
        return (towerIDs, terrainCoords, [])
    }
}
