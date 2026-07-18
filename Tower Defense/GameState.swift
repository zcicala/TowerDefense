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
            (.lightning,  4, [.towerUnlock(.projectile)]),
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
        // Cost for level N = N - 1 points (Lv2 = 1pt, Lv3 = 2pts, … Lv6 = 5pts).
        let allTowers: [TowerType] = [
            .sword, .projectile, .bowler, .laser, .fire,
            .fireball, .ice, .antiAir, .healer, .lightning
        ]
        for type in allTowers {
            for level in 2...Tower.maxLevel {
                let prereqs: [TechNodeID] = level == 2
                    ? (type == .sword ? [] : [.towerUnlock(type)])
                    : [.towerLevel(type, level - 1)]
                nodes.append(.init(
                    id: .towerLevel(type, level),
                    title: "\(type.displayName) Lv\(level)",
                    description: "New \(type.displayName) towers start at level \(level).",
                    cost: level - 1,
                    prerequisites: prereqs))
            }
        }

        // Base tower upgrades — each level costs 1 pt (final level costs 3), grants +1 HP, +30% damage, +1 range
        for level in 2...6 {
            let prereqs: [TechNodeID] = level == 2 ? [] : [.baseTowerLevel(level - 1)]
            nodes.append(.init(
                id: .baseTowerLevel(level),
                title: "Castle Lv\(level)",
                description: "+1 HP, +2x dmg, +1 range",
                cost: level == 6 ? 3 : 1,
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
        case .laser: base = 80
        case .fire: base = 80
        case .ice: base = 100
        case .bowler: base = 60
        case .sword: base = 25
        case .healer: base = 150
        case .fireball: base = 300
        case .antiAir:   base = 150
        case .targeting: base = 75
        case .lightning: base = 130
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
        let dmg = 60.0 * pow(2.0 as Float, Float(lvl - 1))
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
    var spawnInterval: Float = 0.5  // seconds between spawns
    var spawnTimer: Float = 0

    // MARK: - Base Tower

    var baseTowerMaxHP: Int { 8 + (baseTowerTechLevel - 1) }
    var baseTowerHP: Int = 8
    /// True when a ring item is being used and the user must pick a cell to expand around.
    var pendingRingBonus: Bool = false
    /// True when a slow aura item is active and the player is picking a path tile target.
    var isPendingSlowAura: Bool = false
    /// True when a damage aura item is active and the player is picking a path tile target.
    var isPendingDamageAura: Bool = false

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

    let spawnConfigs: [EnemySpawnConfig] = [
        .init(type: .basic,         minRound: 0,  maxRound: 18, weight: 10),
        .init(type: .tank,          minRound: 6,  maxRound: 20, weight: 4),
        .init(type: .mirroid,       minRound: 14,               weight: 3),
        .init(type: .wisp,          minRound: 12,               weight: 2),
        .init(type: .hopper,        minRound: 8,  maxRound: 25, weight: 5),
        .init(type: .exploder,      minRound: 10, maxRound: 30, weight: 3),
        .init(type: .shield,        minRound: 15, maxRound: 25, weight: 3),
        .init(type: .fastTank,      minRound: 20,               weight: 3),
        .init(type: .superHopper,   minRound: 25,               weight: 3),
        .init(type: .superExploder, minRound: 30,               weight: 2),
        .init(type: .hive,          minRound: 18,               weight: 2),
    ]
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
        Float(next() >> 8) / 16_777_216.0  // 2^24
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
