//
//  HexGrid.swift
//  TestGame
//

import Foundation
import Observation

/// Axial hex coordinate.
struct HexCoord: Hashable {
    let q: Int
    let r: Int
    var s: Int { -q - r }

    /// The 6 neighbor offsets for flat-top hex layout.
    static let directions: [HexCoord] = [
        HexCoord(q: +1, r:  0), // 0: right
        HexCoord(q: +1, r: -1), // 1: upper-right
        HexCoord(q:  0, r: -1), // 2: upper-left
        HexCoord(q: -1, r:  0), // 3: left
        HexCoord(q: -1, r: +1), // 4: lower-left
        HexCoord(q:  0, r: +1), // 5: lower-right
    ]

    func neighbor(_ direction: Int) -> HexCoord {
        let d = HexCoord.directions[direction % 6]
        return HexCoord(q: q + d.q, r: r + d.r)
    }

    /// Hex distance (number of steps between two coords).
    func distance(to other: HexCoord) -> Int {
        max(abs(q - other.q), abs(r - other.r), abs(s - other.s))
    }

    /// World position for flat-top hex layout with given spacing.
    func worldPosition(spacing: Float) -> SIMD2<Float> {
        let x = spacing * (3.0 / 2.0) * Float(q)
        let z = spacing * (sqrt(3.0) / 2.0 * Float(q) + sqrt(3.0) * Float(r))
        return SIMD2<Float>(x, z)
    }
}

enum HexCellType {
    case path
    case start
    case end
    case terrain
}



enum BonusType: CaseIterable {
    case freeUpgrade
    case invulnerable
    case doubleRing
    case goldCache
    case slowAura
    case repair
    case moneyDoubler
    case sell
    case rangeExtender

    var displayName: String {
        switch self {
        case .freeUpgrade: return "Free Upgrades"
        case .invulnerable: return "Invulnerable"
        case .doubleRing: return "Ring Bonus"
        case .goldCache: return "Gold Cache ($150)"
        case .slowAura: return "Slow Aura"
        case .repair: return "Repair (+1 HP) to Main Tower"
        case .moneyDoubler: return "Money Doubler"
        case .sell: return "Resale Deed"
        case .rangeExtender: return "Range Extender"
        }
    }

    var description: String {
        switch self {
        case .freeUpgrade: return "Place a tower here to instantly gain 3 free upgrade levels!"
        case .invulnerable: return "Place a tower here to make it immune to exploder damage!"
        case .doubleRing: return "Place a tower here, then pick any cell to expand a full ring of terrain around it!"
        case .goldCache: return "Place a tower here to receive $150!"
        case .slowAura: return "Place a tower here to slow enemies on adjacent path tiles by 20%!"
        case .repair: return "Place a tower here to restore 1 HP to the base tower!"
        case .moneyDoubler: return "Place a tower here to earn double money for every enemy it kills!"
        case .sell: return "Place a tower here to unlock selling it for a full refund at any time!"
        case .rangeExtender: return "Place a tower here to extend its detection and firing range by +1!"
        }
    }
}

/// Represents a single hex cell with game state (no rendering dependency).
class HexCell {
    let coord: HexCoord
    let height: Float

    var type: HexCellType = .path
    var isSelected: Bool = false
    var isPassable: Bool = true
    var hasTower: Bool = false
    var bonusType: BonusType? = nil
    var isBonus: Bool { bonusType != nil }
    /// The next cell along the path (toward the end).
    weak var next: HexCell?
    /// The previous cell along the path (toward the start).
    weak var previous: HexCell?

    init(coord: HexCoord, height: Float, type: HexCellType = .path) {
        self.coord = coord
        self.height = height
        self.type = type
    }
}

// MARK: - Tower

enum TowerType {
    case projectile
    case laser
    case fire
    case ice
    case bowler
    case sword
    case healer
    case fireball
}

enum EnemyType: CaseIterable {
    case basic
    case tank
    case fastTank
    case boss
    case exploder
    case superExploder
    case shield
    case hopper
    case superHopper
    case hive
    case mirroid

    var displayName: String {
        switch self {
        case .basic:        return "Basic"
        case .tank:         return "Tank"
        case .fastTank:     return "Fast Tank"
        case .boss:         return "Mr Grump"
        case .exploder:     return "Exploder"
        case .superExploder: return "Super Exploder"
        case .shield:       return "Shield"
        case .hopper:       return "Hopper"
        case .superHopper:  return "Super Hopper"
        case .hive:         return "Hive"
        case .mirroid:      return "Mirroid"
        }
    }
}

enum TargetingMode: String, CaseIterable {
    case closest = "Closest"
    case furthestAhead = "Furthest Ahead"
    case furthestBehind = "Furthest Behind"
    case mostHealth = "Most Health"
    case leastHealth = "Least Health"
}

@Observable
class Tower {
    let id: UUID = UUID()
    let coord: HexCoord
    let type: TowerType
    var targetingMode: TargetingMode = .closest
    var level: Int = 1
    static let maxLevel = 6
    var detectionRadius: Int       // hex steps to detect enemies
    var fireRadius: Int            // hex steps projectile can reach
    var projectileSpeed: Float     // world units per second (projectile tower only)
    var damage: Float
    var cooldown: Float            // seconds between shots
    var cooldownRemaining: Float = 0
    var currentYaw: Float = 0      // current turret facing angle (radians)
    var targetYaw: Float = 0       // desired turret facing angle
    var hasTarget: Bool = false     // whether the turret is tracking an enemy
    let turretRotationSpeed: Float = 3.0 // radians per second
    var hitPoints: Int = 5
    let maxHitPoints: Int = 5
    var isInvulnerable: Bool = false
    var hasSlowAura: Bool = false   // tower has slow aura bonus; slowedCoords stores the chosen tiles
    var slowedCoords: Set<HexCoord> = []  // the 3 path tiles this tower slows
    var hasMoneyDoubler: Bool = false    // kills by this tower earn 2× the normal reward
    var moneySpent: Int = 0             // total money spent on this tower (placement + upgrades)
    var totalKills: Int = 0             // enemies killed by this tower
    var totalDamageDealt: Float = 0     // total damage dealt to enemies (not shields)
    /// Max-level laser only: when set, prioritises this enemy type for targeting.
    var priorityEnemyType: EnemyType? = nil

    // Healer-specific state
    var healCharges: Int = 1      // remaining heal charges this round
    var healRadius: Int = 1       // hex distance to reach damaged towers

    // Laser-specific state
    var beamDuration: Float        // how long the beam fires
    var beamDamagePerSecond: Float // DPS to enemies in beam path
    var beamRange: Int             // cells the beam extends
    var isFiringBeam: Bool = false
    var beamTimeRemaining: Float = 0
    var beamTargetID: UUID?  // locked-on enemy ID while firing

    // Fire-specific state
    var fireDuration: Float        // how long the fire cone lasts
    var fireDamagePerSecond: Float // DPS to enemies in affected cells
    var isFiringCone: Bool = false
    var fireTimeRemaining: Float = 0
    var fireTargetCoord: HexCoord? // the cell the cone is aimed at

    // Fireball-specific state
    var splashRadius: Int = 0   // hex radius of AoE on impact

    // Sword-specific state
    var isFiringBlade: Bool = false
    var bladeTimeRemaining: Float = 0
    var bladeTargetCoord: HexCoord?                     // single-stab target
    var bladeSwipeTargets: [(coord: HexCoord, angle: Float)] = []  // max-level swipe: coord + angle
    var bladeSwipeStartAngle: Float = 0
    var bladeSwipeEndAngle: Float = 0
    var bladeSweepProgress: Float = 0                   // 0...1 over fireDuration
    var bladeDamagedCoords: Set<HexCoord> = []          // coords already hit this swipe
    var bladeDamageDealt: Bool = false                  // for single stab

    init(coord: HexCoord, type: TowerType = .projectile,
         detectionRadius: Int = 5, fireRadius: Int = 4,
         projectileSpeed: Float = 6.0, damage: Float = 40, cooldown: Float = 1.0,
         beamDuration: Float = 2.0, beamDamagePerSecond: Float = 1.0, beamRange: Int = 5,
         fireDuration: Float = 3.0, fireDamagePerSecond: Float = 15.0) {
        self.coord = coord
        self.type = type
        self.detectionRadius = detectionRadius
        self.fireRadius = fireRadius
        self.projectileSpeed = projectileSpeed
        self.damage = damage
        self.cooldown = cooldown
        self.beamDuration = beamDuration
        self.beamDamagePerSecond = beamDamagePerSecond
        self.beamRange = beamRange
        self.fireDuration = fireDuration
        self.fireDamagePerSecond = fireDamagePerSecond
    }

    static func makeLaser(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .laser,
              detectionRadius: 7, fireRadius: 6,
              projectileSpeed: 0, damage: 0, cooldown: 3.0,
              beamDuration: 3.0, beamDamagePerSecond: 60, beamRange: 6)
    }

    static func makeFire(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .fire,
              detectionRadius: 2, fireRadius: 1,
              projectileSpeed: 0, damage: 0, cooldown: 0.5,
              fireDuration: 3.5, fireDamagePerSecond: 33.0)
    }

    static func makeIce(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .ice,
              detectionRadius: 2, fireRadius: 1,
              projectileSpeed: 0, damage: 0, cooldown: 2.0,
              fireDuration: 3.0, fireDamagePerSecond: 0)
    }

    static func makeSword(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .sword,
              detectionRadius: 1, fireRadius: 1,
              projectileSpeed: 0, damage: 74, cooldown: 0.84,
              beamDuration: 0, beamDamagePerSecond: 0, beamRange: 0,
              fireDuration: 0.28, fireDamagePerSecond: 0)
    }

    static func makeBowler(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .bowler,
              detectionRadius: 5, fireRadius: 5,
              projectileSpeed: 0, damage: 40, cooldown: 4.0,
              beamDuration: 0, beamDamagePerSecond: 0, beamRange: 0,
              fireDuration: 0, fireDamagePerSecond: 0)
    }

    static func makeFireball(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .fireball,
                      detectionRadius: 5, fireRadius: 5,
                      projectileSpeed: 5.0, damage: 100, cooldown: 2.5,
                      beamDuration: 0, beamDamagePerSecond: 0, beamRange: 0,
                      fireDuration: 2.0, fireDamagePerSecond: 40.0)
        t.splashRadius = 1
        return t
    }

    static func makeHealer(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .healer,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 0, cooldown: 5.0,
                      beamDuration: 0, beamDamagePerSecond: 0, beamRange: 0,
                      fireDuration: 0, fireDamagePerSecond: 0)
        t.healCharges = 1
        t.healRadius = 1
        return t
    }

    var canUpgrade: Bool { level < Tower.maxLevel }

    /// Cost to upgrade to the next level.
    var upgradeCost: Int {
        let base: Int
        switch type {
        case .projectile: base = 22
        case .laser: base = 33
        case .fire: base = 28
        case .ice: base = 44
        case .bowler: base = 20
        case .sword: base = 18
        case .healer: base = 30
        case .fireball: base = 35
        }
        return base * level
    }

    /// Applies the next level upgrade, boosting stats by ~25%.
    func applyUpgrade() {
        guard canUpgrade else { return }
        level += 1
        let boost: Float = 1.25

        switch type {
        case .projectile:
            damage *= boost
            cooldown *= 0.88
        case .laser:
            beamDamagePerSecond *= boost
            cooldown *= 0.80
            // Max level bonus: target priority targeting unlocked (priorityEnemyType becomes available)
        case .fire:
            fireDamagePerSecond *= boost
            fireDuration *= 1.15
            cooldown *= 0.88
        case .ice:
            fireDuration *= 1.2
            cooldown *= 0.82
        case .bowler:
            damage *= boost
            cooldown *= 0.88
        case .sword:
            damage *= boost
            cooldown *= 0.88
        case .healer:
            healCharges = level  // charges equal to new level
            cooldown *= 0.90
            if level == Tower.maxLevel {
                healRadius = 2
            }
        case .fireball:
            damage *= boost
            fireDamagePerSecond *= boost
            cooldown *= 0.88
            if level == Tower.maxLevel {
                splashRadius += 1
            }
        }
    }

    /// Summary of what the next upgrade improves.
    var upgradeDescription: String {
        switch type {
        case .projectile: return level == Tower.maxLevel - 1 ? "+25% dmg, -12% cooldown, +AoE Shots" : "+25% dmg, -12% cooldown"
        case .laser: return level == Tower.maxLevel - 1 ? "+25% DPS, -20% cooldown, +Target Priority" : "+25% DPS, -20% cooldown"
        case .fire: return level == Tower.maxLevel - 1 ? "+25% DPS, +15% duration, +Burning DOT" : "+25% DPS, +15% duration"
        case .ice: return level == Tower.maxLevel - 1 ? "+20% duration, -18% cooldown, +Double Slow" : "+20% duration, -18% cooldown"
        case .bowler: return level == Tower.maxLevel - 1 ? "+25% dmg, -12% cooldown, +Ball Bounce" : "+25% dmg, -12% cooldown"
        case .sword: return level == Tower.maxLevel - 1 ? "+25% dmg, -12% cooldown, +Swipe Arc" : "+25% dmg, -12% cooldown"
        case .healer: return level == Tower.maxLevel - 1 ? "+1 charge, -10% cooldown, +1 radius" : "+1 charge, -10% cooldown"
        case .fireball: return level == Tower.maxLevel - 1 ? "+25% dmg, +25% burn DPS, -12% cooldown, +Splash Radius" : "+25% dmg, +25% burn DPS, -12% cooldown"
        }
    }
}

// MARK: - Enemy

@Observable
class Enemy {
    let id: UUID = UUID()
    let enemyType: EnemyType
    var currentCell: HexCell?
    var progress: Float = 0       // 0...1 between current and next cell
    var hitPoints: Float
    let maxHitPoints: Float
    let speed: Float              // world units per second
    var active: Bool = true
    var reachedEnd: Bool = false
    var slowed: Bool = false
    let baseDamage: Int           // damage dealt to base tower on reaching end
    var slowTimer: Float = 0      // remaining seconds of slow effect
    var slowFactor: Float = 0.5   // speed multiplier when slowed
    var burning: Bool = false
    var burnTimer: Float = 0      // remaining seconds of burn
    var burnDPS: Float = 10.0     // damage per second while burning

    // Shield properties (only used when enemyType == .shield)
    var shieldHP: Float
    let shieldMaxHP: Float
    let shieldRegen: Float = 10   // HP per second

    var shieldActive: Bool { shieldHP > 0 }
    let explosionRadius: Int   // 0 = no explosion
    let explosionDamage: Int

    // Rolling animation state (updated each frame by GameState, read by SceneRenderer)
    var rollDeltaAngle: Float = 0       // rotation to apply this frame (radians)
    var rollAxis: SIMD3<Float> = [1, 0, 0]  // axis to rotate around

    var additionalHoverOffset: Float = 0  // extra Y offset above normal hover height
    var hiveSpawnTimer: Float = 4.0       // seconds until next hopper drop (hive only)

    // Drop-from-hive animation state (hoppers spawned by hive death)
    var isDroppingFromHive: Bool = false
    var hiveDropProgress: Float = 0           // 0 = at hive height, 1 = at path height
    var hiveDropFromY: Float = 0              // world Y the drop starts from
    var hiveDropLateralOffset: SIMD2<Float> = .zero  // random XZ scatter, fades to zero on land

    /// Tower types that cannot damage this enemy.
    var immuneTowerTypes: Set<TowerType> {
        switch enemyType {
        case .hive:    return [.fire, .ice, .sword, .bowler, .fireball]
        case .mirroid: return [.laser]
        default: return []
        }
    }

    // Hopper-specific state
    var hopperJumpTimer: Float = 0      // countdown to next jump
    var isJumping: Bool = false         // currently mid-air
    var jumpProgress: Float = 0         // 0→1 during arc
    let jumpDuration: Float = 0.28      // seconds in the air
    let hopperJumpRange: ClosedRange<Int>   // cells skipped per jump
    let hopperJumpInterval: ClosedRange<Float>  // seconds between jumps
    var jumpFromPos: SIMD3<Float>? = nil
    var jumpToPos: SIMD3<Float>? = nil

    init(type: EnemyType, hitPoints: Float, speed: Float, baseDamage: Int = 1,
         shieldAmount: Float = 0, explosionRadius: Int = 0, explosionDamage: Int = 0) {
        self.enemyType = type
        self.hitPoints = hitPoints
        self.maxHitPoints = hitPoints
        self.speed = speed
        self.baseDamage = baseDamage
        self.shieldMaxHP = type == .shield ? shieldAmount : 0
        self.shieldHP = type == .shield ? shieldAmount : 0
        self.explosionRadius = explosionRadius
        self.explosionDamage = explosionDamage
        switch type {
        case .hopper:
            self.hopperJumpRange = 2...5
            self.hopperJumpInterval = 0.6...1.6
            self.hopperJumpTimer = Float.random(in: 0.5...1.2)
        case .superHopper:
            self.hopperJumpRange = 2...6
            self.hopperJumpInterval = 0.5...1.0
            self.hopperJumpTimer = Float.random(in: 0.4...0.8)
        default:
            self.hopperJumpRange = 2...5
            self.hopperJumpInterval = 1.2...2.2
            self.hopperJumpTimer = 0
        }
    }
}

// MARK: - Projectile

class Projectile {
    let id: UUID = UUID()
    let origin: SIMD3<Float>
    let target: SIMD3<Float>
    let totalFlightTime: Float
    var elapsed: Float = 0
    let damage: Float
    let targetEnemyID: UUID
    let isAoE: Bool  // max-level projectile tower explodes on impact
    let sourceTowerID: UUID?
    let burnOnImpact: Bool      // fireball: apply burn on hit
    let impactBurnDPS: Float    // burn damage per second
    let impactBurnDuration: Float   // burn duration in seconds
    let splashRadius: Int       // hex radius of AoE (0 = same tile only)

    init(origin: SIMD3<Float>, target: SIMD3<Float>, totalFlightTime: Float,
         damage: Float, targetEnemyID: UUID, isAoE: Bool = false, sourceTowerID: UUID? = nil,
         burnOnImpact: Bool = false, impactBurnDPS: Float = 0, impactBurnDuration: Float = 0,
         splashRadius: Int = 0) {
        self.origin = origin
        self.target = target
        self.totalFlightTime = totalFlightTime
        self.damage = damage
        self.targetEnemyID = targetEnemyID
        self.isAoE = isAoE
        self.sourceTowerID = sourceTowerID
        self.burnOnImpact = burnOnImpact
        self.impactBurnDPS = impactBurnDPS
        self.impactBurnDuration = impactBurnDuration
        self.splashRadius = splashRadius
    }

    var currentPosition: SIMD3<Float> {
        let t = min(elapsed / totalFlightTime, 1.0)
        var pos = origin + (target - origin) * t
        // Arc: parabolic height offset peaking at midpoint
        let arc = 4 * t * (1 - t) * 1.0 // 1.0 unit arc height
        pos.y += arc
        return pos
    }

    var isComplete: Bool {
        elapsed >= totalFlightTime
    }
}

// MARK: - Bowling Ball

class BowlingBall {
    let id: UUID = UUID()
    var position: SIMD3<Float>
    var direction: SIMD3<Float>  // normalized XZ travel direction (mutable for bounce)
    let speed: Float
    let damage: Float
    var active: Bool = true
    var hitEnemyIDs: Set<UUID> = []  // enemies already struck by this ball
    var bouncesRemaining: Int        // >0 allows path-following on bend
    var lastPathCell: HexCell?       // last valid path cell, used for bounce redirect

    // Fall-in animation
    let fallDuration: Float = 0.35
    var fallTimer: Float = 0
    var isFalling: Bool = true
    let startY: Float       // Y at top of tower
    let targetY: Float      // Y at path level

    var fallProgress: Float { min(fallTimer / fallDuration, 1.0) }

    let sourceTowerID: UUID?

    init(startPosition: SIMD3<Float>, direction: SIMD3<Float>, speed: Float, damage: Float, targetY: Float, bouncesRemaining: Int = 0, sourceTowerID: UUID? = nil) {
        self.position = startPosition
        self.direction = direction
        self.speed = speed
        self.damage = damage
        self.startY = startPosition.y
        self.targetY = targetY
        self.bouncesRemaining = bouncesRemaining
        self.sourceTowerID = sourceTowerID
    }
}

/// Manages the collection of hex cells.
class HexGrid {
    private(set) var cells: [HexCoord: HexCell] = [:]

    func addCell(_ cell: HexCell) {
        cells[cell.coord] = cell
    }

    func cell(at coord: HexCoord) -> HexCell? {
        cells[coord]
    }

    func neighbors(of coord: HexCoord) -> [HexCell] {
        (0..<6).compactMap { cells[coord.neighbor($0)] }
    }

    func removeCell(at coord: HexCoord) {
        cells.removeValue(forKey: coord)
    }
}
