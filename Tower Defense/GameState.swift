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
    let pathLength = 30
    let terrainRings = 2

    var spacing: Float { hexRadius + gap / 2 }

    // MARK: - Game Phase

    var phase: GamePhase = .placing
    var round: Int = 0
    var money: Int = 140
    let killReward: Int = 8
    var selectedTowerType: TowerType? = nil

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
        let allTypes: [TowerType] = [.projectile, .laser, .fire, .ice, .bowler, .sword, .healer, .fireball, .antiAir]
        let names: [TowerType: String] = [
            .projectile: "Projectile", .laser: "Laser", .fire: "Fire", .ice: "Ice",
            .bowler: "Bowler", .sword: "Sword", .healer: "Healer", .fireball: "Fireball", .antiAir: "Anti Air"
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
        case .antiAir:  base = 150
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
        let t = Tower(coord: end.coord, type: .projectile,
                      detectionRadius: 4, fireRadius: 4,
                      projectileSpeed: 6.0, damage: 50, cooldown: 1.5)
        baseSentinelTower = t
    }

    // MARK: - Enemies

    let enemyRadius: Float = 0.1
    let enemyHoverOffset: Float = 0.05
    var enemies: [Enemy] = []

    var enemiesToSpawn: Int = 0
    var spawnInterval: Float = 0.5  // seconds between spawns
    var spawnTimer: Float = 0

    // MARK: - Base Tower

    let baseTowerMaxHP: Int = 10
    var baseTowerHP: Int = 10
    /// Tower that just received a slow aura bonus and is waiting for the user to pick a target path tile.
    var pendingSlowAuraTower: Tower? = nil
    /// Tower that just received a damage aura bonus and is waiting for the user to pick a target path tile.
    var pendingDamageAuraTower: Tower? = nil
    /// True when a ring item is being used and the user must pick a cell to expand around.
    var pendingRingBonus: Bool = false
    /// True once the player has claimed the pause control bonus.
    var hasPauseControl: Bool = false

    // MARK: - Inventory

    var ringItemCount: Int = 0
    var repairItemCount: Int = 0
    var slowAuraItemCount: Int = 0
    var damageAuraItemCount: Int = 0
    var moveTowerItemCount: Int = 0
    /// True when selecting a tower to apply a slow aura to.
    var isSelectingTowerForSlowAura: Bool = false
    /// True when selecting a tower to apply a damage aura to.
    var isSelectingTowerForDamageAura: Bool = false
    /// True when the player has activated a Move Tower item and is selecting which tower to move.
    var isSelectingTowerToMove: Bool = false
    /// Non-nil when a tower has been selected for moving and the player is choosing a destination.
    var pendingMoveTower: Tower? = nil
    /// True while the game is paused (only possible if hasPauseControl).
    var isPaused: Bool = false
    /// Number of visual blocks remaining (starts at 5, loses one every 2 HP lost)
    var baseTowerBlocksRemaining: Int = 5
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
        .init(type: .shield,        minRound: 15,               weight: 3),
        .init(type: .fastTank,      minRound: 20,               weight: 3),
        .init(type: .superHopper,   minRound: 25,               weight: 3),
        .init(type: .superExploder, minRound: 30,               weight: 2),
        .init(type: .hive,          minRound: 18,               weight: 2),
    ]
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
    var firedBalls: [BowlingBall] = []
    var movedBalls: [BowlingBall] = []
    var removedBalls: [BowlingBall] = []
    var poppedBalls: [SIMD3<Float>] = []  // positions of balls that hit non-path
}
