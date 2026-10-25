import Foundation
import simd

extension GameState {

    // MARK: - Map Generation

    func generateMap() {
        generatePath()
        addNoBuildRing()
        pregenerateTerrain()
        ringItemCount = 1
        moveTowerItemCount = 1
    }

    /// Terrain field radius (in hex steps from the origin) pregenerated at startup, so terrain
    /// stays consistent even once new path branches are drawn over these coords later.
    private static let pregenerationRadius = 150

    /// Rolls all coords within `pregenerationRadius` of the origin into `pregeneratedTerrain`,
    /// using the same path-proximity weighting as `rollTerrainType`. Runs once, after the path
    /// is generated (so `nearPath` weighting matches what live spawning would produce), and the
    /// path never changes afterward (even across `restart()`), so this stays valid all session.
    private func pregenerateTerrain() {
        let radius = Self.pregenerationRadius
        pregeneratedTerrain.reserveCapacity(3 * radius * radius + 3 * radius + 1)
        for dq in -radius...radius {
            let rLow = max(-radius, -dq - radius)
            let rHigh = min(radius, -dq + radius)
            for dr in rLow...rHigh {
                let coord = HexCoord(q: dq, r: dr)
                pregeneratedTerrain[coord] = rollTerrainType(at: coord)
            }
        }
    }

    /// Rolls a terrain type for `coord` based on proximity to the path, matching the existing
    /// rarity distribution (rock/gold/energy field are more common near the path).
    private func rollTerrainType(at coord: HexCoord) -> TerrainType {
        let nearPath = hexGrid.cells.values.contains {
            ($0.type == .path || $0.type == .start) && $0.coord.distance(to: coord) <= 2
        }
        let roll = rng.randomFloat(in: 0..<1)
        if nearPath {
            return roll < 0.10 ? .rock : roll < 0.15 ? .gold : roll < 0.18 ? .energyField : .grass
        } else {
            return roll < 0.05 ? .gold : roll < 0.07 ? .energyField : .grass
        }
    }

    /// Adds a terrain tile next to the base tower's no-build ring as the starting board.
    @discardableResult
    func seedTerrainAroundBase() -> [HexCell] {
        guard let endCell = hexGrid.cells.values.first(where: { $0.type == .end }) else { return [] }
        let outer = (0..<6).map { endCell.coord.neighbor($0) }
            .compactMap { hexGrid.cell(at: $0) }
            .filter { $0.type == .noBuild }
            .flatMap { ring in (0..<6).map { ring.coord.neighbor($0) } }
            .filter { hexGrid.cell(at: $0) == nil }
        let candidates = Set(outer).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        guard let coord = rng.randomElement(candidates) else { return [] }
        return [makeTerrainCell(at: coord)]
    }

    private func generatePath() {
        var coord = HexCoord(q: 0, r: 0)
        var dir = rng.randomInt(in: 0..<6)
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

            currentHeight *= rng.randomFloat(in: 0.95...1.05)

            // Look ahead 2 steps in each turn direction to detect curling
            let leftDir = (dir + 5) % 6
            let rightDir = (dir + 1) % 6

            let leftBlocked = isPathAhead(from: coord, direction: leftDir)
            let rightBlocked = isPathAhead(from: coord, direction: rightDir)
            let straightBlocked = isPathAhead(from: coord, direction: dir)

            // Choose turn direction, biasing away from existing path
            if straightBlocked && !leftBlocked && !rightBlocked {
                dir = rng.randomBool() ? leftDir : rightDir
            } else if straightBlocked && leftBlocked {
                dir = rightDir
            } else if straightBlocked && rightBlocked {
                dir = leftDir
            } else if leftBlocked && !rightBlocked {
                // Bias right when left is blocked
                let roll = rng.randomFloat(in: 0..<1)
                if roll < 0.3 { dir = rightDir }
                // else keep straight
            } else if rightBlocked && !leftBlocked {
                // Bias left when right is blocked
                let roll = rng.randomFloat(in: 0..<1)
                if roll < 0.3 { dir = leftDir }
                // else keep straight
            } else {
                // Normal random turning
                let roll = rng.randomFloat(in: 0..<1)
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
            terrainHeight = rng.randomFloat(in: 0.5...2.0)
        } else {
            let avg = neighbors.map(\.height).reduce(0, +) / Float(neighbors.count)
            terrainHeight = avg * rng.randomFloat(in: 0.80...1.20)
        }
        let cell = HexCell(coord: coord, height: terrainHeight, type: .terrain)
        // Use the pregenerated field so terrain stays deterministic once decided;
        // fall back to a fresh roll only if this coord is outside the pregenerated radius.
        cell.terrainType = pregeneratedTerrain[coord] ?? rollTerrainType(at: coord)
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
        guard let coord = rng.randomElement(unique) else { return nil }
        return makeTerrainCell(at: coord)
    }

    /// Adds up to 2 random terrain tiles among the empty neighbours of a coord. Returns new cells.
    func expandTerrainAround(coord: HexCoord, count: Int) -> [HexCell] {
        let shuffled = rng.shuffled((0..<6).map { coord.neighbor($0) }.filter { hexGrid.cell(at: $0) == nil })
        return shuffled.prefix(count).map { makeTerrainCell(at: $0) }
    }

    // MARK: - Tower Placement

    /// Places a tower on a terrain cell. Returns the tower and any new terrain cells added around it.
    func placeTower(at coord: HexCoord) -> (Tower, [HexCell])? {
        guard phase == .placing, let type = selectedTowerType else { return nil }
        guard unlockedTowers.contains(type) else { return nil }
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
        case .lightning:
            tower = Tower.makeLightning(coord: coord)
        }
        tower.moneySpent = cost

        // Apply tech-tree base level bonus (towerBonusLevel returns target level 1-6)
        let startLevel = towerBonusLevel(type)
        for _ in 1..<startLevel { tower.applyUpgrade() }

        // Apply and consume any bonus on this cell
        if let bonus = cell.bonusType {
            switch bonus {
            case .freeUpgrade:
                tower.applyUpgrade()
                tower.applyUpgrade()
                tower.applyUpgrade()
            case .invulnerable:
                tower.isInvulnerable = true
            case .doubleRing, .goldCache, .repair, .moveTower, .slowAura, .damageAura:
                openChest()
            case .moneyDoubler:
                tower.hasMoneyDoubler = true
            case .rangeExtender:
                tower.detectionRadius += 1
                tower.fireRadius += 1
                if tower.type == .laser { tower.laser?.range += 1 }
            }
            cell.bonusType = nil
        }

        // Consume any farm on this cell and apply its benefit to the tower
        if let farmIndex = farms.firstIndex(where: { $0.coord == coord }) {
            let farm = farms[farmIndex]
            switch farm.farmType {
            case .farm:
                let mult = farm.damageMultiplier
                tower.damage            *= mult
                tower.laser?.dps        *= mult
                tower.cone?.dps         *= mult
                tower.fireball?.burnDPS *= mult
            case .bank:
                break  // banks don't benefit towers directly
            case .quarry:
                tower.maxHitPoints += farm.accumulatedHP * Tower.hpPerHeart
                tower.hitPoints = tower.maxHitPoints
            case .crystalStructure:
                break  // no tower bonus — building here simply gives up its energy bonus
            }
            cell.hasFarm = false
            farms.remove(at: farmIndex)
        }

        towers.append(tower)
        let newTerrain = expandTerrainAround(coord: coord, count: 0)
        return (tower, newTerrain)
    }

    func tower(at coord: HexCoord) -> Tower? {
        towers.first(where: { $0.coord == coord })
    }

    /// World position of a tower's base, for status-indicator placement.
    func towerWorldPosition(_ tower: Tower) -> SIMD3<Float>? {
        guard let cell = hexGrid.cell(at: tower.coord) else { return nil }
        let pos = tower.coord.worldPosition(spacing: spacing)
        return SIMD3(pos.x, cell.height, pos.y)
    }

    func farm(at coord: HexCoord) -> Farm? {
        farms.first(where: { $0.coord == coord })
    }

    /// Places a farm on the cell. Returns the new terrain cells spawned around it, or nil on failure.
    func placeFarm(at coord: HexCoord) -> [HexCell]? {
        guard phase == .placing, farmUnlocked else { return nil }
        guard let cell = hexGrid.cell(at: coord),
              cell.type == .terrain, !cell.hasTower, !cell.hasFarm else { return nil }
        guard money >= farmCost else { return nil }
        money -= farmCost
        cell.hasFarm = true
        let farmType: FarmType = cell.terrainType == .gold ? .bank
                               : cell.terrainType == .rock ? .quarry
                               : cell.terrainType == .energyField ? .crystalStructure
                               : .farm
        farms.append(Farm(coord: coord, farmType: farmType))
        return expandTerrainAround(coord: coord, count: 2)
    }

    /// Grows every farm at the end of a round.
    /// Advances all farms at the end of a round.
    func advanceFarms() {
        let farmCoords = Set(farms.map { $0.coord })
        for farm in farms {
            let adjacentFarmCount = hexGrid.neighbors(of: farm.coord)
                .filter { farmCoords.contains($0.coord) }
                .count
            farm.roundsGrown += 1

            switch farm.farmType {
            case .farm:
                // 3% base growth + 2% per adjacent farm, plus 1 gold passive income
                farm.accumulatedBonus += 0.05 + Float(adjacentFarmCount) * 0.03
                money += 1

            case .bank:
                // 60 gold base + 20 per adjacent farm
                money += 20 + adjacentFarmCount * 10

            case .quarry:
                // +1 HP every 4 rounds, reduced by 1 per 2 adjacent farm/quarry/bank (min 1), plus 1 gold passive income
                let interval = max(1, 4 - adjacentFarmCount / 2)
                if farm.roundsGrown % interval == 0 {
                    farm.accumulatedHP += 1
                }
                money += 1

            case .crystalStructure:
                // No per-round accumulation — its castle energy bonus is computed live from
                // crystalStructureCount for as long as it stands.
                break
            }
        }
    }

    /// Grants 2 random inventory items, with a 20% chance of a bonus third item.
    func openChest() {
        var items: [String] = []
        items.append(grantRandomInventoryItem())
        items.append(grantRandomInventoryItem())
        if rng.randomInt(in: 0..<5) == 0 { items.append(grantRandomInventoryItem()) }
        print("[Chest] Opened — contained: \(items.joined(separator: ", "))")
    }

    /// Grants one random inventory item chosen from: ring, repair, tower heal, move tower, slow aura, damage aura, or $75 gold.
    @discardableResult
    func grantRandomInventoryItem() -> String {
        let roll = rng.randomInt(in: 0..<7)
        switch roll {
        case 0: ringItemCount += 1;       return "Ring"
        case 1: repairItemCount += 1;     return "Repair"
        case 2: towerHealItemCount += 1;  return "Tower Heal"
        case 3: moveTowerItemCount += 1;  return "Move Tower"
        case 4: slowAuraItemCount += 1;   return "Slow Aura"
        case 5: damageAuraItemCount += 1; return "Damage Aura"
        default: money += 75;             return "$75 Gold"
        }
    }

    /// Upgrades a tower if affordable. Returns true on success.

    /// Heals a specific tower by 2 HP using a tower heal item. Returns true on success.
    func useTowerHealItem(on tower: Tower) -> Bool {
        guard towerHealItemCount > 0, tower.hitPoints < tower.maxHitPoints else { return false }
        towerHealItemCount -= 1
        tower.hitPoints = min(tower.maxHitPoints, tower.hitPoints + 2 * Tower.hpPerHeart)
        return true
    }

    /// Heals a tower by 1 HP for $75. Returns true on success.
    func repairTower(_ tower: Tower) -> Bool {
        guard tower.hitPoints < tower.maxHitPoints, money >= repairCost else { return false }
        money -= repairCost
        tower.hitPoints = min(tower.maxHitPoints, tower.hitPoints + Tower.hpPerHeart)
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

    func activateTowerHealItem() {
        guard towerHealItemCount > 0, !isPendingTowerHeal else { return }
        isPendingTowerHeal = true
    }

    func cancelPendingTowerHeal() {
        isPendingTowerHeal = false
    }

    func applyPendingTowerHeal(on tower: Tower) -> Bool {
        guard isPendingTowerHeal, tower.hitPoints < tower.maxHitPoints else { return false }
        towerHealItemCount -= 1
        tower.hitPoints = min(tower.maxHitPoints, tower.hitPoints + 2 * Tower.hpPerHeart)
        isPendingTowerHeal = false
        return true
    }

    func activateMoveTower() {
        guard moveTowerItemCount > 0, !isSelectingTowerToMove, pendingMoveTower == nil else { return }
        moveTowerItemCount -= 1
        isSelectingTowerToMove = true
    }

    /// Castle-ability entry point into the same select-tower/select-destination flow
    /// `activateMoveTower()` starts, spending castle energy instead of an inventory item —
    /// this is what lets a tower be relocated mid-round instead of only during placing (the
    /// Move Tower item's own UI only appears while `phase == .placing`). Returns true if the
    /// selection flow actually started.
    @discardableResult
    func beginMoveTowerAbility() -> Bool {
        guard phase == .combat,
              pendingAbility == nil,
              !isSelectingTowerToMove, pendingMoveTower == nil,
              abilityUnlocked(.moveTower),
              abilityReady(.moveTower) else { return false }
        castleEnergy -= CastleAbility.moveTower.energyCost
        moveTowerViaAbility = true
        isSelectingTowerToMove = true
        return true
    }

    func cancelPendingMoveTower() {
        if isSelectingTowerToMove || pendingMoveTower != nil {
            if moveTowerViaAbility {
                castleEnergy = min(castleMaxEnergy, castleEnergy + CastleAbility.moveTower.energyCost)
            } else {
                moveTowerItemCount += 1
            }
        }
        isSelectingTowerToMove = false
        pendingMoveTower = nil
        moveTowerViaAbility = false
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

        // Consume any farm on the destination cell and apply its benefit to the tower
        if let farmIndex = farms.firstIndex(where: { $0.coord == coord }) {
            let farm = farms[farmIndex]
            switch farm.farmType {
            case .farm:
                let mult = farm.damageMultiplier
                tower.damage            *= mult
                tower.laser?.dps        *= mult
                tower.cone?.dps         *= mult
                tower.fireball?.burnDPS *= mult
            case .bank:
                break
            case .quarry:
                let bonusHP = farm.accumulatedHP * Tower.hpPerHeart
                tower.maxHitPoints += bonusHP
                tower.hitPoints = min(tower.hitPoints + bonusHP, tower.maxHitPoints)
            case .crystalStructure:
                break  // no tower bonus — building here simply gives up its energy bonus
            }
            newCell.hasFarm = false
            farms.remove(at: farmIndex)
        }

        // Apply and consume any bonus on the destination cell
        if let bonus = newCell.bonusType {
            switch bonus {
            case .freeUpgrade:
                tower.applyUpgrade()
                tower.applyUpgrade()
                tower.applyUpgrade()
            case .invulnerable:
                tower.isInvulnerable = true
            case .doubleRing, .goldCache, .repair, .moveTower, .slowAura, .damageAura:
                openChest()
            case .moneyDoubler:
                tower.hasMoneyDoubler = true
            case .rangeExtender:
                tower.detectionRadius += 1
                tower.fireRadius += 1
                if tower.type == .laser { tower.laser?.range += 1 }
            }
            newCell.bonusType = nil
        }

        pendingMoveTower = nil
        moveTowerViaAbility = false
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
        guard let cell = rng.randomElement(candidates) else { return }
        cell.bonusType = rng.randomElement(BonusType.allCases)
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

    /// Steps remaining along the path from `coord` to the base (end cell = 0).
    func pathStepsToBase(from coord: HexCoord) -> Int? {
        guard let cell = hexGrid.cell(at: coord),
              cell.type == .path || cell.type == .start || cell.type == .end else { return nil }
        var steps = 0
        var current: HexCell? = cell
        while let c = current { steps += 1; current = c.next }
        return max(0, steps - 1)
    }

    /// Returns path cells within the given tower type's fire range from coord.
    func allCellsInFireRange(from coord: HexCoord, type: TowerType) -> [HexCell] {
        // Use the placed tower's fireRadius when available, otherwise fall back to defaults
        let radius: Int
        if let tower = towers.first(where: { $0.coord == coord }) {
            radius = tower.fireRadius
        } else {
            var base: Int
            switch type {
            case .projectile: base = 4
            case .laser:      base = 6
            case .fire:       base = 2
            case .ice:        base = 1
            case .bowler:     base = 5
            case .sword:      base = 1
            case .healer:     base = 1
            case .fireball:   base = 5
            case .antiAir:    base = 9
            case .targeting:  base = 3
            case .lightning:  base = 3
            }
            if hexGrid.cell(at: coord)?.bonusType == .rangeExtender { base += 1 }
            radius = base
        }

        switch type {
        case .bowler:
            // Ball rolls in a straight line through a path-adjacent neighbour.
            // Show all reachable cells along every possible entry direction.
            return bowlerRangeCells(from: coord, range: radius)

        case .laser, .fireball:
            // Both have a minimum range of >1 tile — exclude adjacent cells.
            return hexGrid.cells.values.filter {
                let d = coord.distance(to: $0.coord)
                return d > 1 && d <= radius
            }

        default:
            return hexGrid.cells.values.filter { coord.distance(to: $0.coord) <= radius }
        }
    }

    /// Returns all cells reachable by a bowling ball rolling in a straight line
    /// through any path-adjacent neighbour of `coord`.
    private func bowlerRangeCells(from coord: HexCoord, range: Int) -> [HexCell] {
        let pathNeighbours = hexGrid.neighbors(of: coord)
            .filter { $0.type == .path || $0.type == .start || $0.type == .end }
        guard !pathNeighbours.isEmpty else { return [] }

        let towerPos = coord.worldPosition(spacing: spacing)
        var visited = Set<HexCoord>()

        for entry in pathNeighbours {
            let ep = entry.coord.worldPosition(spacing: spacing)
            let dx = ep.x - towerPos.x
            let dz = ep.y - towerPos.y
            let len = sqrt(dx * dx + dz * dz)
            guard len > 0 else { continue }
            let dirX = dx / len
            let dirZ = dz / len

            for step in 1...range {
                let sx = towerPos.x + dirX * spacing * 1.5 * Float(step)
                let sz = towerPos.y + dirZ * spacing * 1.5 * Float(step)
                visited.insert(nearestHexCoord(worldX: sx, worldZ: sz))
            }
        }

        return visited.compactMap { hexGrid.cell(at: $0) }
    }

    /// Transitions back to placing phase. Returns any newly added terrain/path cells.
    func returnToPlacing() -> [HexCell] {
        guard phase == .roundOver else { return [] }
        upgradePoints += 1
        // Advance all farms by one round
        advanceFarms()
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
        // Pre-pick theme for the upcoming round so the player can prepare
        pickUpcomingTheme(for: round + 1)

        // Add one terrain tile adjacent to the path each round
        var newCells: [HexCell] = []
        if let cell = addSingleTerrainTileAlongPath() {
            newCells.append(cell)
        }
        // Every 10 rounds add a new branch spawn path — each branch's new .start cell gets
        // its own independent spawn timer (see spawnTimers/spawnIntervals), so this also
        // raises total enemy throughput, not just the number of entrances.
        if round % 10 == 0 && round > 0 {
            newCells.append(contentsOf: addBranchPath())
        }
        return newCells
    }

    // MARK: - Branch Paths

    /// Every cell enemies spawn from: each `.start` cell plus the entry cell of every branch.
    /// A branch shares the original start cell, which only has one `next`, so its enemies
    /// spawn on the branch's first cell (a neighbour of the start). Sorted for stable RNG order.
    var spawnCells: [HexCell] {
        var coords = Set(hexGrid.cells.values.filter { $0.type == .start }.map(\.coord))
        coords.formUnion(branchEntryCoords)
        return coords.compactMap { hexGrid.cell(at: $0) }
            .sorted { ($0.coord.q, $0.coord.r) < ($1.coord.q, $1.coord.r) }
    }

    /// Fills every empty neighbour of the start and end cells with a `.noBuild` cell.
    /// Returns the cells added.
    @discardableResult
    func addNoBuildRing() -> [HexCell] {
        var added: [HexCell] = []
        for hub in hexGrid.cells.values.filter({ $0.type == .start || $0.type == .end }) {
            for dir in 0..<6 {
                let coord = hub.coord.neighbor(dir)
                guard hexGrid.cell(at: coord) == nil else { continue }
                let cell = HexCell(coord: coord, height: hub.height, type: .noBuild)
                hexGrid.addCell(cell)
                added.append(cell)
            }
        }
        return added
    }

    /// Opens a new path from the original start cell to the end cell, winding around the
    /// existing paths. It leaves through one of the start's no-build neighbours (its first
    /// cell becomes a spawn cell) and enters the end through one of the end's. Returns the new
    /// path cells in order, or `[]` if there is no room for a route.
    @discardableResult
    func addBranchPath() -> [HexCell] {
        guard let startCell = spawnCells.first(where: { $0.type == .start }),
              let endCell = hexGrid.cells.values.first(where: { $0.type == .end }),
              let route = takeBranchRoute(), !route.isEmpty else { return [] }

        var cells: [HexCell] = []
        var height = startCell.height
        for coord in route {
            height *= rng.randomFloat(in: 0.92...1.08)
            cells.append(HexCell(coord: coord, height: height, type: .path))
        }
        // Link: entry → ... → last → end
        for i in 0..<(cells.count - 1) {
            cells[i].next = cells[i + 1]
            cells[i + 1].previous = cells[i]
        }
        cells[cells.count - 1].next = endCell
        for cell in cells {
            hexGrid.addCell(cell)   // replaces any no-build cell at that coord
            branchPathCoords.insert(cell.coord)
        }
        branchEntryCoords.append(cells[0].coord)
        branchOpenedRound[cells[0].coord] = round

        // Give the player something to build on: a few terrain tiles beside the new path
        // (empty cells only, so no path / no-build / terrain cell is ever replaced).
        var candidates = Set(cells.flatMap { cell in (0..<6).map { cell.coord.neighbor($0) } })
            .filter { hexGrid.cell(at: $0) == nil }
            .sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        var terrain: [HexCell] = []
        while terrain.count < Self.branchSeedTileCount, let coord = rng.randomElement(candidates) {
            candidates.removeAll { $0 == coord }
            terrain.append(makeTerrainCell(at: coord))
        }

        ringItemCount += Self.branchSpawnTilesGrant
        moveTowerItemCount += Self.branchMoveTowerGrant
        return cells + terrain
    }

    // MARK: Branch spawn ramp

    static let branchSeedTileCount = 3
    static let branchSpawnTilesGrant = 1
    static let branchMoveTowerGrant = 2
    static let branchStartShare: Float = 0.15
    static let branchEndShare: Float = 0.50
    static let branchRampRounds = 10

    /// Fraction of a wave a branch takes, `roundsSinceOpen` full rounds after its first one:
    /// linear from `branchStartShare` to `branchEndShare` over `branchRampRounds`, then flat.
    static func branchSpawnShare(roundsSinceOpen n: Int) -> Float {
        let t = Float(min(max(n, 0), branchRampRounds)) / Float(branchRampRounds)
        return branchStartShare + (branchEndShare - branchStartShare) * t
    }

    /// Spawn-interval multiplier that yields share `s` against one other path: `1/s - 1`.
    static func branchIntervalMultiplier(roundsSinceOpen n: Int) -> Float {
        1 / branchSpawnShare(roundsSinceOpen: n) - 1
    }

    /// Full rounds since the branch entered at `coord` opened (0 in the first round after
    /// opening), or nil for the original start cell.
    func branchRoundsSinceOpen(at coord: HexCoord) -> Int? {
        branchOpenedRound[coord].map { max(round - $0 - 1, 0) }
    }

    /// 1 for the main start cell; the ramp multiplier for a branch entry.
    func spawnIntervalMultiplier(at coord: HexCoord) -> Float {
        branchRoundsSinceOpen(at: coord).map { Self.branchIntervalMultiplier(roundsSinceOpen: $0) } ?? 1
    }

    /// True while a branch is still ramping, during which it may not spawn the boss.
    func isRampingBranch(at coord: HexCoord) -> Bool {
        (branchRoundsSinceOpen(at: coord) ?? Self.branchRampRounds) < Self.branchRampRounds
    }

    /// Snapshot of what the route search needs, safe to hand to a background thread.
    private func makeBranchSearch() -> BranchRouteSearch? {
        guard let startCell = spawnCells.first(where: { $0.type == .start }),
              let endCell = hexGrid.cells.values.first(where: { $0.type == .end }) else { return nil }
        // Target: as many cells as the main path has between its start and end.
        var mainCount = 0
        var walker = startCell.next
        while let c = walker, c.type != .end, mainCount < 10_000 { mainCount += 1; walker = c.next }
        return BranchRouteSearch(types: hexGrid.cells.mapValues(\.type),
                                 start: startCell.coord, end: endCell.coord, mainCount: mainCount)
    }

    /// Starts searching for the next branch route on a background thread, so the result is
    /// ready when the round ends. Called while a round is being fought.
    func beginBranchRouteSearch() {
        guard let search = makeBranchSearch() else { return }
        branchSearchGeneration += 1
        let generation = branchSearchGeneration
        branchSearchFinished = false
        precomputedBranchRoute = nil
        let seed = UInt64(rng.randomInt(in: 1..<Int.max))
        Task.detached(priority: .utility) {
            let route = search.findRoute(seed: seed)
            await MainActor.run {
                guard self.branchSearchGeneration == generation else { return }
                self.precomputedBranchRoute = route
                self.branchSearchFinished = true
            }
        }
    }

    /// Discards any in-flight or finished background search.
    func cancelBranchRouteSearch() {
        branchSearchGeneration += 1
        branchSearchFinished = false
        precomputedBranchRoute = nil
    }

    /// The background result if it finished and still fits the grid; otherwise a search run now.
    private func takeBranchRoute() -> [HexCoord]? {
        guard let search = makeBranchSearch() else { return nil }
        let finished = branchSearchFinished
        let precomputed = precomputedBranchRoute
        cancelBranchRouteSearch()
        if finished {
            guard let precomputed else { return nil }   // searched already: no room
            if search.isValid(route: precomputed) { return precomputed }
        }
        return search.findRoute(seed: UInt64(rng.randomInt(in: 1..<Int.max)))
    }

    /// Resets the entire game. Returns removed tower IDs, removed terrain coords, and the new seed cells around the base.
    func restart() -> (towerIDs: [UUID], removedTerrainCoords: [HexCoord], seedCells: [HexCell]) {
        let towerIDs = towers.map(\.id)
        // Remove terrain and branch cells; path/start/end cells are preserved
        let terrainCoords = hexGrid.cells.values
            .filter { $0.type == .terrain }
            .map { $0.coord }
        for coord in terrainCoords { hexGrid.removeCell(at: coord) }
        let branchCoords = Array(branchPathCoords)
        for coord in branchCoords { hexGrid.removeCell(at: coord) }
        branchPathCoords.removeAll()
        branchEntryCoords.removeAll()
        branchOpenedRound.removeAll()
        cancelBranchRouteSearch()
        addNoBuildRing()   // branches replaced some ring cells; put them back
        phase = .placing
        round = 0
        money = 1000 + startingGoldBonus   // TEMP: testing boost (normally 50)
        // upgradePoints and purchasedTechNodes intentionally preserved across restarts
        selectedTowerType = nil
        baseTowerHP = baseTowerMaxHP
        baseTowerBlocksRemaining = (baseTowerMaxHP + 1) / 2
        baseTowerDamageAccumulated = 0
        baseSentinelTower = nil
        towers.removeAll()
        enemies.removeAll()
        projectiles.removeAll()
        bowlingBalls.removeAll()
        spawnTimers.removeAll()
        spawnIntervals.removeAll()
        towerPlacedCount.removeAll()
        statsTowerBuilt.removeAll()
        statsKills.removeAll()
        statsDamage.removeAll()
        statsKillsByEnemy.removeAll()
        pendingRingBonus = false
        ringItemCount = 1
        repairItemCount = 0
        towerHealItemCount = 0
        slowAuraItemCount = 0
        damageAuraItemCount = 0
        moveTowerItemCount = 1
        isPendingSlowAura = false
        isPendingDamageAura = false
        globalSlowAuraCoords = []
        globalDamageAuraCoords = []
        farms.removeAll()
        isPlacingFarm = false
        isPendingTowerHeal = false
        isSelectingTowerToMove = false
        pendingMoveTower = nil
        moveTowerViaAbility = false
        isPaused = false
        return (towerIDs, terrainCoords + branchCoords, [])
    }
}

/// Minimal binary min-heap for the branch route search, ordered by cost then (q, r) so equal
/// costs pop in a stable, seed-reproducible order.
nonisolated private struct RouteHeap {
    private var items: [(cost: Float, coord: HexCoord)] = []

    private static func less(_ a: (cost: Float, coord: HexCoord), _ b: (cost: Float, coord: HexCoord)) -> Bool {
        (a.cost, a.coord.q, a.coord.r) < (b.cost, b.coord.q, b.coord.r)
    }

    mutating func push(_ cost: Float, _ coord: HexCoord) {
        items.append((cost, coord))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard RouteHeap.less(items[i], items[parent]) else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Float, HexCoord)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < items.count, RouteHeap.less(items[l], items[smallest]) { smallest = l }
                if r < items.count, RouteHeap.less(items[r], items[smallest]) { smallest = r }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
        }
        return (top.cost, top.coord)
    }
}

/// Tiny seeded xorshift generator so the background search never touches `GameState.rng`.
nonisolated private struct SearchRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    private mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(next() >> 40) / 16_777_216.0 * (range.upperBound - range.lowerBound)
    }
    mutating func int(below n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Branch route search over a plain snapshot of the grid (cell types only), so it can run on a
/// background thread while the game keeps going.
nonisolated struct BranchRouteSearch {
    let types: [HexCoord: HexCellType]
    let start: HexCoord
    let end: HexCoord
    /// Cells on the main path between its start and end.
    let mainCount: Int

    private func isOpen(_ coord: HexCoord) -> Bool {
        guard let type = types[coord] else { return true }
        return type == .noBuild
    }

    /// True if `coord` touches a path cell, ignoring the hub and its ring when `hub` is given.
    private func touchesPath(_ coord: HexCoord, hub: HexCoord?) -> Bool {
        for dir in 0..<6 {
            let n = coord.neighbor(dir)
            guard let type = types[n], type == .path || type == .start || type == .end else { continue }
            if let hub, hub.distance(to: n) <= 1 { continue }
            return true
        }
        return false
    }

    private func isValidInterior(_ coord: HexCoord) -> Bool {
        coord.distance(to: start) > 1 && coord.distance(to: end) > 1
            && isOpen(coord) && !touchesPath(coord, hub: nil)
    }

    /// Whether a previously found route still fits the grid: open cells, no touching of other
    /// paths except inside the start/end rings, and a connected chain.
    func isValid(route: [HexCoord]) -> Bool {
        guard let first = route.first, let last = route.last else { return false }
        guard first.distance(to: start) == 1, isOpen(first), !touchesPath(first, hub: start),
              last.distance(to: end) == 1, isOpen(last), !touchesPath(last, hub: end) else { return false }
        for i in 0..<route.count {
            if i > 0 && route[i].distance(to: route[i - 1]) != 1 { return false }
            if i > 0 && i < route.count - 1 && !isValidInterior(route[i]) { return false }
        }
        return true
    }

    /// Finds a route from a free neighbour of `start` to a free neighbour of `end` whose length
    /// is close to the main path's. A plain cheapest-route search would take nearly the
    /// shortest line, so this also tries routes bent through a random waypoint (two searches,
    /// the second walled off from the first) and keeps whichever lands nearest the target length.
    /// Interior cells must be empty and not touch any existing path cell; only the first and
    /// last cells may sit beside other paths, and only inside the start/end rings.
    func findRoute(seed: UInt64) -> [HexCoord]? {
        var rng = SearchRandom(seed: seed)
        let desired = max(mainCount, start.distance(to: end))
        let mid = HexCoord(q: (start.q + end.q) / 2, r: (start.r + end.r) / 2)
        let radius = max(start.distance(to: end), desired / 2) + 10

        // The snapshot doesn't change during a search, so each cell's verdict is computed once.
        var interiorCache: [HexCoord: Bool] = [:]
        func validInterior(_ coord: HexCoord) -> Bool {
            if let cached = interiorCache[coord] { return cached }
            let valid = isValidInterior(coord)
            interiorCache[coord] = valid
            return valid
        }

        let ringSources = Set((0..<6).map { start.neighbor($0) }
            .filter { isOpen($0) && !touchesPath($0, hub: start) })
        let ringTargets = Set((0..<6).map { end.neighbor($0) }
            .filter { isOpen($0) && !touchesPath($0, hub: end) })
        guard !ringSources.isEmpty, !ringTargets.isEmpty else { return nil }

        var costs: [HexCoord: Float] = [:]
        func cost(_ coord: HexCoord) -> Float {
            if let c = costs[coord] { return c }
            let c = rng.float(in: 1.0...2.0)
            costs[coord] = c
            return c
        }

        /// Cheapest route from any of `sources` to any of `targets`. Interior steps avoid
        /// `blocked`; sources and targets are trusted (validated by the caller).
        func search(sources: Set<HexCoord>, targets: Set<HexCoord>, blocked: Set<HexCoord>) -> [HexCoord]? {
            guard !sources.isEmpty, !targets.isEmpty else { return nil }
            var dist: [HexCoord: Float] = [:]
            var prev: [HexCoord: HexCoord] = [:]
            var done = Set<HexCoord>()
            var heap = RouteHeap()
            for s in sources.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }) {
                let d = cost(s)
                dist[s] = d
                heap.push(d, s)
            }
            while let (d, current) = heap.pop() {
                guard done.insert(current).inserted else { continue }   // stale heap entry

                if targets.contains(current) {
                    var route = [current]
                    while let p = prev[route[route.count - 1]] { route.append(p) }
                    return route.reversed()
                }
                for dir in 0..<6 {
                    let n = current.neighbor(dir)
                    guard !done.contains(n), n.distance(to: mid) <= radius else { continue }
                    if !targets.contains(n) {
                        guard validInterior(n), !blocked.contains(n) else { continue }
                    }
                    let nd = d + cost(n)
                    if nd < dist[n, default: .infinity] {
                        dist[n] = nd
                        prev[n] = current
                        heap.push(nd, n)
                    }
                }
            }
            return nil
        }

        var best: [HexCoord]?
        var bestGap = Int.max
        func consider(_ route: [HexCoord]?) {
            guard let route else { return }
            let gap = abs(route.count - desired)
            if gap < bestGap { best = route; bestGap = gap }
        }

        consider(search(sources: ringSources, targets: ringTargets, blocked: []))

        let tolerance = max(2, desired / 10)
        var attempts = 0
        while bestGap > tolerance && attempts < 14 {
            attempts += 1
            let waypoint = HexCoord(q: mid.q + rng.int(below: 2 * radius + 1) - radius,
                                    r: mid.r + rng.int(below: 2 * radius + 1) - radius)
            guard waypoint.distance(to: mid) <= radius, validInterior(waypoint),
                  let first = search(sources: ringSources, targets: [waypoint], blocked: []) else { continue }

            // Wall off the first leg and everything beside it, so the second leg can't touch it.
            let firstSet = Set(first)
            var blocked = firstSet
            for c in first { for d in 0..<6 { blocked.insert(c.neighbor(d)) } }
            // The second leg may only start beside the waypoint (not beside any other first-leg cell).
            let beforeWaypoint = Set(first.dropLast())
            let secondSources = Set((0..<6).map { waypoint.neighbor($0) }.filter { n in
                validInterior(n) && !firstSet.contains(n)
                    && !(0..<6).contains { beforeWaypoint.contains(n.neighbor($0)) }
            })
            let secondTargets = ringTargets.filter { !blocked.contains($0) }
            guard let second = search(sources: secondSources, targets: secondTargets, blocked: blocked) else { continue }
            consider(first + second)
        }
        return best
    }
}
