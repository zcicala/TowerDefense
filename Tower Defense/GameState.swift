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

// MARK: - Castle Abilities

/// Manually-activated spells cast from the castle during combat. One is unlocked per castle level
/// (`baseTowerTechLevel`); level 1 is the default so the first ability is available on a fresh run.
/// The `rawValue` doubles as both the required castle level and the number-key hotkey.
enum CastleAbility: Int, CaseIterable {
    case overcharge = 1      // towers on/adjacent to a cell fire 2× as fast
    case freeze = 2          // freeze enemies in a cell and its neighbors
    case poison = 3          // green cloud in a radius; enemies that walk through it get poisoned
    case invulnerability = 4 // make a tower invulnerable
    case gravityWell = 5     // pull nearby enemies toward a tile and hold them

    /// Castle level required to have unlocked this ability.
    var requiredLevel: Int { rawValue }

    /// Number-key hotkey used to activate the ability.
    var hotkey: Character { Character("\(rawValue)") }

    var displayName: String {
        switch self {
        case .overcharge:      return "Overcharge"
        case .freeze:          return "Freeze"
        case .poison:          return "Poison"
        case .invulnerability: return "Invuln"
        case .gravityWell:     return "Gravity Well"
        }
    }

    /// Energy cost to cast, drawn from the shared castle energy pool.
    var energyCost: Float {
        switch self {
        case .overcharge:      return 8
        case .freeze:          return 10
        case .poison:          return 6
        case .invulnerability: return 15
        case .gravityWell:     return 18
        }
    }

    /// How long the ability's effect lasts once cast. For Poison this is the cloud's own
    /// lifetime — how long it keeps infecting enemies that walk through it — not how long the
    /// poison DOT lingers on an enemy afterward (see `GameState.poisonDOTDuration`).
    var duration: Float {
        switch self {
        case .overcharge:      return 3
        case .freeze:          return 2
        case .poison:          return 5
        case .invulnerability: return 5
        case .gravityWell:     return 3
        }
    }

    /// True when the ability targets a tower (Invulnerability); false when it targets a cell.
    var targetsTower: Bool { self == .invulnerability }

    /// Short instruction shown while selecting a target.
    var targetPrompt: String {
        if targetsTower { return "Click a tower to protect it." }
        if self == .poison { return "Click a cell to release poison gas." }
        return "Click a cell to cast."
    }
}

// MARK: - Tech Tree Types

enum TechNodeID: Hashable {
    case towerUnlock(TowerType)
    case farmUnlock
    case towerLevel(TowerType, Int)  // target starting level (2 – Tower.maxLevel)
    case baseTowerLevel(Int)         // base/center tower upgrade level (2 – 6)
    case targetingFeature(Int)       // global targeting upgrade (1 – 5)
    case startingGold(Int)           // starting gold upgrade (1 – 5), +50 gold each
}

struct TechNodeDef {
    let id: TechNodeID
    let title: String
    let description: String
    let cost: Int
    let prerequisites: [TechNodeID]
}

/// Owns the hex grid and all game logic.
@Observable
class GameState {
    let hexGrid = HexGrid()
    let rng: RandomSource

    let hexRadius: Float = 0.5
    let gap: Float = 0.05
    let pathLength = 30
    let terrainRings = 2

    init(rng: RandomSource = RandomSource()) {
        self.rng = rng
    }

    var spacing: Float { hexRadius + gap / 2 }

    // MARK: - Meta Progression (persists across restarts)

    /// Points earned by completing rounds; spent in the tech tree between runs.
    var upgradePoints: Int = 0
    /// Nodes the player has purchased in the tech tree.
    var purchasedTechNodes: Set<TechNodeID> = []

    // MARK: - Tech Node Definitions

    static let techNodes: [TechNodeDef] = {
        // Tower unlock nodes (Sword is always free — no unlock node needed)
        let unlockDefs: [(TowerType, Int, [TechNodeID])] = [
            (.projectile, 2, []),
            (.bowler,     2, [.towerUnlock(.projectile)]),
            (.laser,      3, [.towerUnlock(.projectile)]),
            (.fire,       3, [.towerUnlock(.projectile)]),
            (.fireball,   5, [.towerUnlock(.laser), .towerUnlock(.fire)]),
            (.ice,        3, [.farmUnlock]),
            (.antiAir,    3, [.farmUnlock]),
            (.healer,     4, [.targetingFeature(1)]),
            (.lightning,  6, [.towerUnlock(.projectile)]),
        ]

        func unlockDescription(_ type: TowerType) -> String {
            switch type {
            case .projectile: return "Balanced ranged tower. Moderate damage and range; gains a second turret at max level."
            case .bowler:     return "Rolls a heavy ball down the path, hitting every enemy it passes through. Bounces to a second lane at max level."
            case .laser:      return "Fires a continuous beam, dealing steady damage per second to a single target."
            case .fire:       return "Blankets a cone in flame, damaging every enemy inside over time. Applies a burning DOT at max level."
            case .fireball:   return "Launches an explosive shell that splashes nearby enemies and sets them burning. Splash radius grows at max level."
            case .ice:        return "Blasts a cone that slows enemies caught inside, without dealing direct damage. Slows twice as hard at max level."
            case .antiAir:    return "Very long range, high-damage tower that fires only at Hive and Wisp enemies."
            case .healer:     return "Repairs nearby damaged towers instead of attacking. Gains extra charges and radius as it levels up."
            case .targeting:  return "Grants global targeting options to all towers."
            case .sword:      return "Always-unlocked melee tower. Short range but hits hard, and swipes multiple enemies at max level."
            case .lightning:  return "Strikes an enemy then chains to nearby foes, losing 20% damage per jump. Gains an extra jump every level."
            }
        }

        var nodes: [TechNodeDef] = []

        for (type, cost, prereqs) in unlockDefs {
            nodes.append(.init(id: .towerUnlock(type),
                               title: "Unlock \(type.displayName)",
                               description: unlockDescription(type),
                               cost: cost, prerequisites: prereqs))
        }

        nodes.append(.init(id: .farmUnlock, title: "Unlock Farm",
                           description: "Lets you place Farms on terrain tiles, which generate passive gold income each round.",
                           cost: 1, prerequisites: []))

        // Level upgrade chain for every tower type including Sword.
        // Cost for level N = (N - 1) * costMultiplier points (Lv2 = 1pt, Lv3 = 2pts, … Lv6 = 5pts
        // at the default 1x multiplier). Laser/Fireball/Lightning use 2x — their individual
        // in-game upgradeCost (50/53/48 gold per level) runs roughly double the typical tower's
        // (~25.5 avg for projectile/fire/bowler/sword/healer/antiAir), so their tech-tree cost
        // is scaled to match.
        let allTowers: [TowerType] = [
            .sword, .projectile, .bowler, .laser, .fire,
            .fireball, .ice, .antiAir, .healer, .lightning
        ]
        let towerCostMultiplier: [TowerType: Int] = [.laser: 2, .fireball: 2, .lightning: 2]
        for type in allTowers {
            let costMultiplier = towerCostMultiplier[type] ?? 1
            for level in 2...Tower.maxLevel {
                let prereqs: [TechNodeID] = level == 2
                    ? (type == .sword ? [] : [.towerUnlock(type)])
                    : [.towerLevel(type, level - 1)]
                nodes.append(.init(
                    id: .towerLevel(type, level),
                    title: "\(type.displayName) Lv\(level)",
                    description: "New \(type.displayName) towers start at level \(level).",
                    cost: (level - 1) * costMultiplier,
                    prerequisites: prereqs))
            }
        }

        // Base tower upgrades — Lv2 costs 1pt, Lv3-4 cost 2pt, Lv5-6 cost 3pt. Grants +1 HP, +75% damage, +1 range.
        for level in 2...6 {
            let prereqs: [TechNodeID] = level == 2 ? [] : [.baseTowerLevel(level - 1)]
            let cost: Int = level == 2 ? 1 : (level <= 4 ? 2 : 3)
            nodes.append(.init(
                id: .baseTowerLevel(level),
                title: "Castle Lv\(level)",
                description: "+1 HP, +75% dmg, +1 range",
                cost: cost,
                prerequisites: prereqs))
        }

        // Starting gold upgrades — +50 gold per level
        let goldCosts = [1, 2, 2, 3, 3]
        for level in 1...5 {
            let prereqs: [TechNodeID] = level == 1 ? [] : [.startingGold(level - 1)]
            nodes.append(.init(
                id: .startingGold(level),
                title: "+\(level * 50)g Start",
                description: "Start each run with \(100 + level * 50) gold",
                cost: goldCosts[level - 1],
                prerequisites: prereqs))
        }

        // Global targeting upgrades — apply to all towers once purchased
        let targetingDefs: [(Int, String, String, Int, [TechNodeID])] = [
            (1, "Advanced Targeting",  "All towers: choose priority target type, +1 detect range, +50% turret turn speed", 3, []),
            (2, "Target Lock",         "All towers: lock fire to a specific path cell",     2, [.targetingFeature(1)]),
            (3, "Priority Type",       "All towers: set a preferred enemy type, skip immune enemies", 2, [.targetingFeature(2)]),
            (4, "Manual Lock",         "All towers: manually lock attack target (X)",        3, [.targetingFeature(3)]),
            (5, "Fire Range Boost",    "All towers: +1 fire range",                         3, [.targetingFeature(4)]),
        ]
        for (feat, title, desc, cost, prereqs) in targetingDefs {
            nodes.append(.init(id: .targetingFeature(feat), title: title, description: desc,
                               cost: cost, prerequisites: prereqs))
        }

        return nodes
    }()

    // MARK: - Computed Tech State

    /// Tower types the player has unlocked. Sword is always free.
    var unlockedTowers: Set<TowerType> {
        var result: Set<TowerType> = [.sword]
        for node in purchasedTechNodes {
            if case .towerUnlock(let type) = node { result.insert(type) }
        }
        return result
    }

    var farmUnlocked: Bool { purchasedTechNodes.contains(.farmUnlock) }

    /// Highest purchased base tower tech level (1 = none purchased).
    var baseTowerTechLevel: Int {
        for level in stride(from: 6, through: 2, by: -1) {
            if purchasedTechNodes.contains(.baseTowerLevel(level)) { return level }
        }
        return 1
    }

    /// Starting level for newly placed towers of this type (1 if no upgrades purchased).
    func towerBonusLevel(_ type: TowerType) -> Int {
        for level in stride(from: Tower.maxLevel, through: 2, by: -1) {
            if purchasedTechNodes.contains(.towerLevel(type, level)) { return level }
        }
        return 1
    }

    func canPurchase(_ nodeID: TechNodeID) -> Bool {
        guard !purchasedTechNodes.contains(nodeID) else { return false }
        guard let def = GameState.techNodes.first(where: { $0.id == nodeID }) else { return false }
        guard upgradePoints >= def.cost else { return false }
        return def.prerequisites.allSatisfy { purchasedTechNodes.contains($0) }
    }

    @discardableResult
    func purchase(_ nodeID: TechNodeID) -> Bool {
        guard canPurchase(nodeID) else { return false }
        let cost = GameState.techNodes.first(where: { $0.id == nodeID })!.cost
        upgradePoints -= cost
        purchasedTechNodes.insert(nodeID)

        // Retroactively bring already-placed towers of this type up to the purchased level —
        // towers already at or above it are left alone (this only ever raises a tower to
        // exactly the newly-purchased level, never beyond).
        if case .towerLevel(let type, let level) = nodeID {
            for tower in towers where tower.type == type {
                while tower.level < level { tower.applyUpgrade() }
            }
        }
        return true
    }

    // MARK: - Game Phase

    var phase: GamePhase = .placing
    var round: Int = 0
    var money: Int = 100
    let killReward: Int = 8
    var selectedTowerType: TowerType? = nil
    var isPlacingFarm: Bool = false
    let farmCost: Int = 40

    // MARK: - Farms

    var farms: [Farm] = []

    var towerPlacedCount: [TowerType: Int] = [:]

    // MARK: - Lifetime Stats (never reset mid-game, only on restart)

    /// Total towers ever built of each type (not decremented on sell).
    var statsTowerBuilt: [TowerType: Int] = [:]
    /// Total enemy kills attributed to each tower type.
    var statsKills: [TowerType: Int] = [:]
    /// Total damage attributed to each tower type.
    var statsDamage: [TowerType: Float] = [:]
    /// Kills broken down by tower type → enemy type.
    var statsKillsByEnemy: [TowerType: [EnemyType: Int]] = [:]

    struct TowerTypeStats: Identifiable {
        let id: TowerType
        let typeName: String
        let built: Int
        let kills: Int
        let avgKills: Float
        let damage: Float
        let avgDamage: Float
        let killsByEnemy: [EnemyType: Int]
    }

    var allTowerStats: [TowerTypeStats] {
        let allTypes: [TowerType] = [.projectile, .laser, .fire, .ice, .bowler, .sword, .healer, .fireball, .antiAir, .targeting, .lightning]
        let names: [TowerType: String] = [
            .projectile: "Projectile", .laser: "Laser", .fire: "Fire", .ice: "Ice",
            .bowler: "Bowler", .sword: "Sword", .healer: "Healer", .fireball: "Fireball",
            .antiAir: "Anti Air", .targeting: "Targeting", .lightning: "Lightning"
        ]
        return allTypes.map { type in
            let built  = statsTowerBuilt[type, default: 0]
            let kills  = statsKills[type, default: 0]
            let damage = statsDamage[type, default: 0]
            return TowerTypeStats(
                id: type,
                typeName: names[type] ?? "",
                built: built,
                kills: kills,
                avgKills: built > 0 ? Float(kills) / Float(built) : 0,
                damage: damage,
                avgDamage: built > 0 ? damage / Float(built) : 0,
                killsByEnemy: statsKillsByEnemy[type, default: [:]]
            )
        }
    }

    func costForTower(_ type: TowerType) -> Int {
        let base: Int
        switch type {
        case .projectile: base = 50
        case .laser: base = 120
        case .fire: base = 80
        case .ice: base = 100
        case .bowler: base = 60
        case .sword: base = 25
        case .healer: base = 150
        case .fireball: base = 300
        case .antiAir:   base = 150
        case .targeting: base = 75
        case .lightning: base = 180
        }
        let count = towerPlacedCount[type, default: 0]
        return Int(Double(base) * pow(1.1, Double(count)))
    }

    // MARK: - Towers

    var towers: [Tower] = []

    /// A hidden Tower used to drive base tower shooting — not in the towers array.
    var baseSentinelTower: Tower?

    func ensureBaseSentinel() {
        guard baseSentinelTower == nil, let end = endCell else { return }
        let lvl = baseTowerTechLevel
        let dmg = 125.0 * pow(1.75 as Float, Float(lvl - 1))
        let range = 2 + (lvl - 1)
        let t = Tower(coord: end.coord, type: .projectile,
                      detectionRadius: range, fireRadius: range,
                      projectileSpeed: 6.0, damage: dmg, cooldown: 1.5)
        baseSentinelTower = t
    }

    /// Bonus starting gold from tech upgrades (50 per level purchased).
    var startingGoldBonus: Int {
        for level in stride(from: 5, through: 1, by: -1) {
            if purchasedTechNodes.contains(.startingGold(level)) { return level * 50 }
        }
        return 0
    }

    /// Highest purchased global targeting feature level (0 = none purchased).
    var globalTargetingLevel: Int {
        for feat in stride(from: 5, through: 1, by: -1) {
            if purchasedTechNodes.contains(.targetingFeature(feat)) { return feat }
        }
        return 0
    }

    // MARK: - Enemies

    let enemyRadius: Float = 0.1
    let enemyHoverOffset: Float = 0.05
    var enemies: [Enemy] = []

    var enemiesToSpawn: Int = 0
    /// Per-start-cell spawn state, keyed by that path's `.start` coord — each active path
    /// (the original entrance plus any branch paths added every 10 rounds) spawns independently,
    /// so more open paths directly means more total enemies spawned per second.
    var spawnTimers: [HexCoord: Float] = [:]
    var spawnIntervals: [HexCoord: Float] = [:]

    // MARK: - Base Tower

    var baseTowerMaxHP: Int { 8 + (baseTowerTechLevel - 1) }
    var baseTowerHP: Int = 8
    /// True when a ring item is being used and the user must pick a cell to expand around.
    var pendingRingBonus: Bool = false
    /// True when a slow aura item is active and the player is picking a path tile target.
    var isPendingSlowAura: Bool = false
    /// True when a damage aura item is active and the player is picking a path tile target.
    var isPendingDamageAura: Bool = false

    // MARK: - Castle Abilities

    /// The ability awaiting a target tap, or nil. Mirrors the other `isPending…` selection flags.
    var pendingAbility: CastleAbility? = nil
    /// Current castle energy, spent on ability casts and regenerated over time. Refilled to
    /// `castleMaxEnergy` at the start of each round.
    var castleEnergy: Float = 20
    /// Center of the active Gravity Well, or nil when inactive.
    var gravityWellCoord: HexCoord? = nil
    /// Remaining seconds the Gravity Well pulls enemies.
    var gravityWellTimer: Float = 0
    /// Radius (in hex steps) of the Gravity Well's pull.
    let gravityWellRadius = 2
    /// Ids of enemies currently held by the Gravity Well, as of the last `update(deltaTime:)` call.
    /// Exposed so the renderer can show a per-enemy pull indicator.
    var lastGravityWellPulledIDs: Set<UUID> = []
    /// Center of the active Poison cloud, or nil when inactive.
    var poisonCloudCoord: HexCoord? = nil
    /// Remaining seconds the Poison cloud keeps infecting enemies that walk through it.
    var poisonCloudTimer: Float = 0
    /// Radius (in hex steps) of the Poison cloud.
    let poisonCloudRadius = 2
    /// How long the poison DOT lingers on an enemy once infected (refreshed while still inside
    /// an active cloud) — distinct from the cloud's own `CastleAbility.poison.duration` lifetime.
    let poisonDOTDuration: Float = 10

    /// Terrain types pregenerated at startup for a large hex region around the map origin. This
    /// is the authoritative source for a cell's terrain once it actually spawns (`makeTerrainCell`
    /// looks it up instead of rolling fresh randomness), so terrain stays consistent even once
    /// new path branches are drawn over these coords.
    var pregeneratedTerrain: [HexCoord: TerrainType] = [:]

    /// Number of Crystal Structures on the board (farms placed on Energy Field tiles).
    var crystalStructureCount: Int {
        farms.filter { $0.farmType == .crystalStructure }.count
    }

    /// Summed castle-energy bonus units across all Crystal Structures. Each contributes 2 base
    /// units plus 1 per adjacent farm (of any type). Used as both a flat max-energy bonus and a
    /// percentage-point energy-regen bonus.
    var crystalStructureEnergyBonus: Int {
        let farmCoords = Set(farms.map { $0.coord })
        return farms.filter { $0.farmType == .crystalStructure }.reduce(0) { total, crystal in
            let adjacentFarmCount = hexGrid.neighbors(of: crystal.coord)
                .filter { farmCoords.contains($0.coord) }
                .count
            return total + 2 + adjacentFarmCount
        }
    }

    /// Maximum castle energy: base 20, +2 per Crystal Structure, +1 more per farm adjacent to it.
    var castleMaxEnergy: Float { 20 + Float(crystalStructureEnergyBonus) }

    /// Energy regenerated per second: base 1, +2% per Crystal Structure, +1% more per adjacent farm.
    var castleEnergyRegenRate: Float { 1.0 * (1 + 0.01 * Float(crystalStructureEnergyBonus)) }

    /// True when the given ability has been unlocked by the current castle level.
    func abilityUnlocked(_ ability: CastleAbility) -> Bool {
        baseTowerTechLevel >= ability.requiredLevel
    }

    /// True when there's enough castle energy to cast the given ability.
    func abilityReady(_ ability: CastleAbility) -> Bool {
        castleEnergy >= ability.energyCost
    }

    // MARK: - Inventory

    var ringItemCount: Int = 0
    var repairItemCount: Int = 0
    var towerHealItemCount: Int = 0
    var slowAuraItemCount: Int = 0
    var damageAuraItemCount: Int = 0
    var moveTowerItemCount: Int = 0
    /// Slow aura zones applied via inventory items (not tied to any tower).
    var globalSlowAuraCoords: Set<HexCoord> = []
    /// Damage aura zones applied via inventory items (not tied to any tower).
    var globalDamageAuraCoords: Set<HexCoord> = []
    /// Coords of branch path cells added during gameplay (tracked so they can be removed on restart).
    var branchPathCoords: Set<HexCoord> = []
    /// True when the player has activated a Tower Heal item and is selecting which tower to heal.
    var isPendingTowerHeal: Bool = false
    /// True when the player has activated a Move Tower item and is selecting which tower to move.
    var isSelectingTowerToMove: Bool = false
    /// Non-nil when a tower has been selected for moving and the player is choosing a destination.
    var pendingMoveTower: Tower? = nil
    /// True while the game is paused (only possible if hasPauseControl).
    var isPaused: Bool = false
    /// Number of visual blocks remaining (= ceil(maxHP/2), loses one every 2 HP lost)
    var baseTowerBlocksRemaining: Int = 4  // ceil(8/2) for base HP of 8
    /// Tracks cumulative damage for block destruction threshold
    var baseTowerDamageAccumulated: Int = 0

    // MARK: - Projectiles

    var projectiles: [Projectile] = []
    var bowlingBalls: [BowlingBall] = []

    // MARK: - Bowling Ball / Sword constants (stored properties used across extension files)

    let bowlingBallRadius: Float = 0.18
    let swordBladeLength: Float = 0.55   // shorter than a full cell spacing

    // MARK: - Tower Cost

    let repairCost: Int = 75

    // MARK: - Wave Themes

    /// Theme active during the current combat round (nil = normal wave).
    var currentWaveTheme: WaveTheme? = nil
    /// Theme pre-picked for the next round so the player can prepare during placing phase.
    var upcomingWaveTheme: WaveTheme? = nil

    // MARK: - Enemy Spawning

    /// Defines a weighted spawn entry for a non-boss enemy type.
    struct EnemySpawnConfig {
        let type: EnemyType
        let minRound: Int
        let maxRound: Int
        let weight: Float
        init(type: EnemyType, minRound: Int, maxRound: Int = Int.max, weight: Float) {
            self.type = type; self.minRound = minRound; self.maxRound = maxRound; self.weight = weight
        }
    }

    // MARK: - Enemy Difficulty Tiers

    /// A named "act" of the difficulty curve. HP/speed scale linearly with the round *within*
    /// the tier (round 0 of the tier = `hpBase`/`speedBase`), and only the tier's own roster
    /// can be picked while it's active — see `tier(for:)` and `pickSpawnType`.
    struct EnemyTier {
        let act: Int
        let name: String
        let rounds: ClosedRange<Int>
        let hpBase: Float
        let hpSlope: Float
        let speedBase: Float
        let speedSlope: Float
        /// Extra multiplier stacked on top of the standard boss formula so bosses stay
        /// threatening even as `hpSlope` flattens out in later acts.
        let bossMultiplier: Float
        let roster: [EnemySpawnConfig]

        /// Enemy HP for the given round (expected to fall within `rounds`).
        func hp(atRound round: Int) -> Float {
            hpBase + hpSlope * Float(round - rounds.lowerBound)
        }

        /// Enemy speed for the given round (expected to fall within `rounds`).
        func speed(atRound round: Int) -> Float {
            speedBase + speedSlope * Float(round - rounds.lowerBound)
        }
    }

    /// Source of truth for the round-by-round difficulty curve and roster.
    /// Every tier's `hpBase`/`hpSlope` is 2.5x and `speedBase`/`speedSlope` is 0.5x the values
    /// that originally reproduced the legacy `256 + 102·round` / `1.2 + 0.03·round` formulas —
    /// enemies now have 2.5x HP (2x, then a further +25% pass) and half speed across every act.
    static let tiers: [EnemyTier] = [
        EnemyTier(
            act: 1, name: "Vanguard", rounds: 1...15,
            hpBase: 895, hpSlope: 255,
            speedBase: 0.615, speedSlope: 0.015,
            bossMultiplier: 1.0,
            roster: [
                // basic's minRound is 0 (not 1) so it never collides with the round-1 "debut
                // exclusion" rule in pickSpawnType — at round 1 it's the only eligible type,
                // and excluding it after the first pick would leave the pool empty.
                // Stops spawning after round 9 (maxRound 9) — basic is retired from round 10 on.
                .init(type: .basic,    minRound: 0,  maxRound: 9, weight: 10),
                .init(type: .tank,     minRound: 6,  weight: 4),
                .init(type: .hopper,   minRound: 8,  weight: 5),
                .init(type: .exploder, minRound: 10, weight: 3),
                .init(type: .wisp,     minRound: 12, weight: 2),
                .init(type: .mirroid,  minRound: 14, weight: 3),
            ]
        ),
        EnemyTier(
            act: 2, name: "Hardened", rounds: 16...30,
            hpBase: 4875, hpSlope: 112.5,
            speedBase: 0.875, speedSlope: 0.0125,
            bossMultiplier: 1.3,
            roster: [
                .init(type: .tank,        minRound: 16, weight: 4),
                .init(type: .hopper,      minRound: 16, weight: 4),
                .init(type: .exploder,    minRound: 16, weight: 3),
                .init(type: .wisp,        minRound: 16, weight: 2),
                .init(type: .mirroid,     minRound: 16, weight: 3),
                .init(type: .shield,      minRound: 16, weight: 3),
                .init(type: .fastTank,    minRound: 20, weight: 3),
                .init(type: .superHopper, minRound: 25, weight: 3),
                .init(type: .plated,      minRound: 16, weight: 4),
                .init(type: .insulated,   minRound: 18, weight: 4),
                .init(type: .cinder,      minRound: 20, weight: 4),
            ]
        ),
        EnemyTier(
            act: 3, name: "Apex", rounds: 31...Int.max,
            hpBase: 6875, hpSlope: 37.5,
            speedBase: 1.2, speedSlope: 0.02,
            bossMultiplier: 1.6,
            roster: [
                .init(type: .tank,          minRound: 31, weight: 3),
                .init(type: .hopper,        minRound: 31, weight: 3),
                .init(type: .exploder,      minRound: 31, weight: 2),
                .init(type: .wisp,          minRound: 31, weight: 2),
                .init(type: .mirroid,       minRound: 31, weight: 2),
                .init(type: .shield,        minRound: 31, weight: 3),
                .init(type: .fastTank,      minRound: 31, weight: 3),
                .init(type: .superHopper,   minRound: 31, weight: 3),
                .init(type: .superExploder, minRound: 31, weight: 3),
                .init(type: .hive,          minRound: 31, weight: 2),
                .init(type: .plated,        minRound: 31, weight: 3),
                .init(type: .insulated,     minRound: 31, weight: 3),
                .init(type: .cinder,        minRound: 31, weight: 3),
                .init(type: .nullifier,     minRound: 31, weight: 3),
                .init(type: .warden,        minRound: 33, weight: 2),
            ]
        ),
    ]

    /// The active difficulty tier for the given round (falls back to Act I for round ≤ 0).
    func tier(for round: Int) -> EnemyTier {
        GameState.tiers.first(where: { $0.rounds.contains(round) }) ?? GameState.tiers[0]
    }
}

// MARK: - Random Source

/// Wraps random-number generation so tests can inject a deterministic source.
class RandomSource {
    func randomBool() -> Bool { Bool.random() }
    func randomFloat(in range: ClosedRange<Float>) -> Float { Float.random(in: range) }
    func randomFloat(in range: Range<Float>) -> Float { Float.random(in: range) }
    func randomInt(in range: ClosedRange<Int>) -> Int { Int.random(in: range) }
    func randomInt(in range: Range<Int>) -> Int { Int.random(in: range) }
    func randomElement<T>(_ array: [T]) -> T? { array.randomElement() }
    func shuffled<T>(_ array: [T]) -> [T] { array.shuffled() }
}

/// Xorshift64-based seeded RNG. Same seed → identical sequence every run.
class SeededRandom: RandomSource {
    private var state: UInt64

    init(seed: UInt64 = 42) {
        self.state = seed == 0 ? 1 : seed
    }

    private func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    private func unitFloat() -> Float {
        // Keep only the top 24 bits (64 - 24 = 40) so the result actually lands in [0, 1) —
        // shifting by just 8 (the old code) still left up to 56 significant bits, so dividing
        // by 2^24 could produce values many orders of magnitude outside the intended range.
        Float(next() >> 40) / 16_777_216.0  // 2^24
    }

    override func randomBool() -> Bool { next() & 1 == 0 }

    override func randomFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + unitFloat() * (range.upperBound - range.lowerBound)
    }

    override func randomFloat(in range: Range<Float>) -> Float {
        range.lowerBound + unitFloat() * (range.upperBound - range.lowerBound)
    }

    override func randomInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    override func randomInt(in range: Range<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound)
        return range.lowerBound + Int(next() % span)
    }

    override func randomElement<T>(_ array: [T]) -> T? {
        guard !array.isEmpty else { return nil }
        return array[Int(next() % UInt64(array.count))]
    }

    override func shuffled<T>(_ array: [T]) -> [T] {
        var result = array
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
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
    var damagedTowers: [Tower] = []    // towers that took damage but survived
    var healedTowers: [Tower] = []     // towers that received a heal this frame
    var destroyedTowers: [Tower] = []  // towers reduced to 0 HP
    var explosions: [SIMD3<Float>] = []  // world positions of exploder death blasts
    var bladesStarted: [Tower] = []
    var bladesUpdated: [Tower] = []
    var bladesEnded: [Tower] = []
    var boltsStarted: [Tower] = []
    var boltsUpdated: [Tower] = []
    var boltsEnded: [Tower] = []
    var firedBalls: [BowlingBall] = []
    var movedBalls: [BowlingBall] = []
    var removedBalls: [BowlingBall] = []
    var poppedBalls: [SIMD3<Float>] = []  // positions of balls that hit non-path
}
