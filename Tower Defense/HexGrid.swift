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

enum TerrainType {
    case grass   // 80% — regular farm, damage multiplier
    case rock    // 10% — quarry, accumulates HP for tower
    case gold    // 10% — bank, generates gold each round
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
    case rangeExtender
    case damageAura
    case moveTower

    var displayName: String {
        switch self {
        case .freeUpgrade:   return "Free Upgrades"
        case .invulnerable:  return "Invulnerable"
        case .doubleRing:    return "Spawn Tiles"
        case .goldCache:     return "Gold Cache ($150)"
        case .slowAura:      return "Slow Aura"
        case .repair:        return "Repair (+1 HP)"
        case .moneyDoubler:  return "Money Doubler"
        case .rangeExtender: return "Range Extender"
        case .damageAura:    return "Damage Aura"
        case .moveTower:     return "Move Tower"
        }
    }

    /// True for bonuses that go into the player's inventory or wallet rather than modifying the placed tower.
    var isInventoryBonus: Bool {
        switch self {
        case .doubleRing, .repair, .moveTower, .goldCache, .slowAura, .damageAura: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .freeUpgrade:   return "Place a tower here to instantly gain 3 free upgrade levels!"
        case .invulnerable:  return "Place a tower here to make it immune to exploder damage!"
        case .doubleRing:    return "Place a tower here to add 2 Spawn Tiles items to your inventory!"
        case .goldCache:     return "Place a tower here to receive $150!"
        case .slowAura:      return "Place a tower here to slow enemies on adjacent path tiles by 20%!"
        case .repair:        return "Place a tower here to add a Repair item to your inventory. Use it to restore 1 HP to the Castle Tower!"
        case .moneyDoubler:  return "Place a tower here to earn double money for every enemy it kills!"
        case .rangeExtender: return "Place a tower here to extend its detection and firing range by +1!"
        case .damageAura:    return "Place a tower here to boost all damage dealt to enemies on adjacent path tiles by 40%!"
        case .moveTower:     return "Place a tower here to add a Move Tower item to your inventory. Use it to reposition any placed tower!"
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
    var hasFarm: Bool = false
    var terrainType: TerrainType = .grass
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

// MARK: - Farm

enum FarmType {
    case farm    // on grass — accumulates damage multiplier for tower placed on it
    case bank    // on gold  — generates gold each round
    case quarry  // on rock  — accumulates HP to boost the tower placed on it
}

class Farm {
    let id: UUID = UUID()
    var coord: HexCoord
    var farmType: FarmType
    var roundsGrown: Int = 0

    // Regular farm fields
    var accumulatedBonus: Float = 0.0
    var damageMultiplier: Float { 1.0 + accumulatedBonus }

    // Quarry fields
    var accumulatedHP: Int = 0

    init(coord: HexCoord, farmType: FarmType = .farm) {
        self.coord = coord
        self.farmType = farmType
    }
}

// MARK: - Tower Type-Specific State

struct LaserState {
    var duration: Float
    var dps: Float
    var range: Int
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var lockedTargetID: UUID? = nil
    var rampMultiplier: Float = 1.0  // grows 5% per 0.1s of continuous fire
    var rampTimer: Float = 0          // accumulator for ramp ticks
}

struct LightningState {
    var duration: Float = 0.5
    var range: Int = 3
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var chainTargetIDs: [UUID] = []  // enemies hit this cast, in bolt order
    var chainDamages: [Float] = []   // total damage dealt to each chain target (falloff already applied)
}

struct ConeState {
    var duration: Float
    var dps: Float              // 0 for ice
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var targetCoord: HexCoord? = nil
    var lockedTargetID: UUID? = nil
}

struct SwordState {
    var swingDuration: Float
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var stabTargetCoord: HexCoord? = nil
    var swipeTargets: [(coord: HexCoord, angle: Float)] = []
    var swipeStartAngle: Float = 0
    var swipeEndAngle: Float = 0
    var sweepProgress: Float = 0
    var damagedCoords: Set<HexCoord> = []
    var damageDealt: Bool = false
}

struct HealerState {
    var charges: Int
    var radius: Int
}

struct FireballState {
    var splashRadius: Int
    var burnDuration: Float
    var burnDPS: Float
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
    case antiAir
    case targeting
    case lightning

    var displayName: String {
        switch self {
        case .projectile: return "Projectile"
        case .laser:      return "Laser"
        case .fire:       return "Fire"
        case .ice:        return "Ice"
        case .bowler:     return "Bowler"
        case .sword:      return "Sword"
        case .healer:     return "Healer"
        case .fireball:   return "Fireball"
        case .antiAir:    return "Anti Air"
        case .targeting:  return "Targeting"
        case .lightning:  return "Lightning"
        }
    }
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
    case wisp

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
        case .wisp:         return "Wisp"
        }
    }
}

// MARK: - Wave Themes

enum WaveTheme: CaseIterable {
    case swarm
    case armoredColumn
    case hopperSurge
    case exploderRush
    case shieldWall
    case hiveMind

    var displayName: String {
        switch self {
        case .swarm:          return "Swarm"
        case .armoredColumn:  return "Armored Column"
        case .hopperSurge:    return "Hopper Surge"
        case .exploderRush:   return "Exploder Rush"
        case .shieldWall:     return "Shield Wall"
        case .hiveMind:       return "Hive Mind"
        }
    }

    var flavorText: String {
        switch self {
        case .swarm:          return "Masses of fast enemies converge on the base."
        case .armoredColumn:  return "Heavy units march in tight formation."
        case .hopperSurge:    return "Agile hoppers will leap past your defenses."
        case .exploderRush:   return "Volatile units threaten to destroy your towers."
        case .shieldWall:     return "Shield bearers protect the whole column."
        case .hiveMind:       return "A hive descends, spawning endless hoppers."
        }
    }

    /// Earliest round this theme can appear (keyed to when its star enemy debuts).
    var minRound: Int {
        switch self {
        case .swarm:          return 1
        case .armoredColumn:  return 6
        case .hopperSurge:    return 8
        case .exploderRush:   return 10
        case .shieldWall:     return 15
        case .hiveMind:       return 18
        }
    }

    /// Weight multiplier applied to each enemy type when this theme is active.
    func weightMultiplier(for type: EnemyType) -> Float {
        switch self {
        case .swarm:
            return type == .basic ? 5.0 : 0.4
        case .armoredColumn:
            return (type == .tank || type == .fastTank || type == .mirroid) ? 5.0 : 0.4
        case .hopperSurge:
            return (type == .hopper || type == .superHopper) ? 5.0 : 0.4
        case .exploderRush:
            return (type == .exploder || type == .superExploder) ? 5.0 : 0.4
        case .shieldWall:
            if type == .shield { return 5.0 }
            if type == .tank || type == .mirroid { return 2.5 }
            return 0.4
        case .hiveMind:
            return (type == .hive || type == .wisp) ? 5.0 : 0.4
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

struct SecondTurretState {
    var currentYaw: Float = 0
    var targetYaw: Float = 0
    var hasTarget: Bool = false
    var cooldownRemaining: Float = 0
}

@Observable
class Tower {
    let id: UUID = UUID()
    var coord: HexCoord
    let type: TowerType
    var targetingMode: TargetingMode = .closest
    /// Set by the player via manual attack mode (level 4+ targeting tower in range).
    var manualTargetEnemyID: UUID? = nil
    /// Non-nil for max-level projectile towers — an independently rotating second turret.
    var secondTurret: SecondTurretState? = nil
    var level: Int = 1
    static let maxLevel = 6
    var detectionRadius: Int
    var fireRadius: Int
    var projectileSpeed: Float
    var damage: Float
    var cooldown: Float
    var cooldownRemaining: Float = 0
    var currentYaw: Float = 0
    var targetYaw: Float = 0
    var hasTarget: Bool = false
    let turretRotationSpeed: Float = 3.0
    var hitPoints: Int = 5
    var maxHitPoints: Int = 5
    var isInvulnerable: Bool = false
    var hasSlowAura: Bool = false
    var slowedCoords: Set<HexCoord> = []
    var hasDamageAura: Bool = false
    var damageAuraCoords: Set<HexCoord> = []
    var hasMoneyDoubler: Bool = false
    var moneySpent: Int = 0
    var totalKills: Int = 0
    var totalDamageDealt: Float = 0
    var targetTypeRestrictions: Set<EnemyType> = []
    /// Set via a level-2+ Targeting Tower: this tower prioritises this enemy type when selecting targets.
    var priorityEnemyType: EnemyType? = nil
    /// When set, tower only fires at enemies whose nearest coord matches this cell.
    var lockedTargetCoord: HexCoord? = nil

    // Type-specific state — only the relevant one is non-nil for a given tower
    var laser: LaserState? = nil
    var cone: ConeState? = nil       // fire and ice
    var sword: SwordState? = nil
    var healer: HealerState? = nil
    var fireball: FireballState? = nil
    var lightning: LightningState? = nil

    init(coord: HexCoord, type: TowerType = .projectile,
         detectionRadius: Int = 4, fireRadius: Int = 4,
         projectileSpeed: Float = 6.0, damage: Float = 50, cooldown: Float = 1.0) {
        self.coord = coord
        self.type = type
        self.detectionRadius = detectionRadius
        self.fireRadius = fireRadius
        self.projectileSpeed = projectileSpeed
        self.damage = damage
        self.cooldown = cooldown
    }

    static func makeLaser(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .laser,
                      detectionRadius: 6, fireRadius: 6,
                      projectileSpeed: 0, damage: 0, cooldown: 6.0)
        t.laser = LaserState(duration: 3.0, dps: 180, range: 6)
        return t
    }

    static func makeFire(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .fire,
                      detectionRadius: 2, fireRadius: 2,
                      projectileSpeed: 0, damage: 0, cooldown: 0.5)
        t.cone = ConeState(duration: 3.5, dps: 101.0)
        return t
    }

    static func makeIce(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .ice,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 0, cooldown: 1.0)
        t.cone = ConeState(duration: 3.0, dps: 0)
        return t
    }

    static func makeSword(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .sword,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 90, cooldown: 0.84)
        t.sword = SwordState(swingDuration: 0.28)
        return t
    }

    static func makeBowler(coord: HexCoord) -> Tower {
        return Tower(coord: coord, type: .bowler,
                     detectionRadius: 5, fireRadius: 5,
                     projectileSpeed: 0, damage: 158, cooldown: 4.0)
    }

    static func makeFireball(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .fireball,
                      detectionRadius: 5, fireRadius: 5,
                      projectileSpeed: 5.0, damage: 100, cooldown: 2.5)
        t.fireball = FireballState(splashRadius: 1, burnDuration: 2.0, burnDPS: 40.0)
        return t
    }

    static func makeAntiAir(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .antiAir,
                      detectionRadius: 9, fireRadius: 9,
                      projectileSpeed: 5.5, damage: 260, cooldown: 3.5)
        t.targetTypeRestrictions = [.hive, .wisp]
        return t
    }

    static func makeHealer(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .healer,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 0, cooldown: 5.0)
        t.healer = HealerState(charges: 1, radius: 1)
        return t
    }

    static func makeTargeting(coord: HexCoord) -> Tower {
        return Tower(coord: coord, type: .targeting,
                     detectionRadius: 3, fireRadius: 0,
                     projectileSpeed: 0, damage: 0, cooldown: 999)
    }

    static func makeLightning(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .lightning,
                      detectionRadius: 3, fireRadius: 3,
                      projectileSpeed: 0, damage: 198, cooldown: 2.5)
        t.lightning = LightningState(duration: 0.5, range: 3)
        return t
    }

    var canUpgrade: Bool { level < Tower.maxLevel }

    /// Cost to upgrade to the next level.
    var upgradeCost: Int {
        let base: Int
        switch type {
        case .projectile: base = 22
        case .laser:      base = 33
        case .fire:       base = 28
        case .ice:        base = 44
        case .bowler:     base = 20
        case .sword:      base = 18
        case .healer:     base = 30
        case .fireball:   base = 53
        case .antiAir:    base = 35
        case .targeting:  base = 75
        case .lightning:  base = 32
        }
        return base * level
    }

    /// Applies the next level upgrade, boosting stats by 33%.
    func applyUpgrade() {
        guard canUpgrade else { return }
        level += 1
        let boost: Float = 1.33

        switch type {
        case .projectile:
            damage *= boost
            cooldown *= 0.88
            if level == Tower.maxLevel { secondTurret = SecondTurretState() }
        case .laser:
            laser!.dps *= boost
            cooldown *= 0.80
        case .fire:
            cone!.dps *= boost
            cone!.duration *= 1.15
            cooldown *= 0.88
        case .ice:
            cone!.duration *= 1.2
            cooldown *= 0.82
        case .bowler:
            damage *= boost
            cooldown *= 0.88
        case .sword:
            damage *= boost
            cooldown *= 0.88
        case .healer:
            healer!.charges = level
            cooldown *= 0.90
            if level == Tower.maxLevel { healer!.radius = 2 }
        case .fireball:
            damage *= boost
            fireball!.burnDPS *= boost
            cooldown *= 0.88
            if level == Tower.maxLevel { fireball!.splashRadius += 1 }
        case .antiAir:
            damage *= boost
            cooldown *= 0.88
            if level == Tower.maxLevel {
                detectionRadius += 1
                fireRadius += 1
            }
        case .targeting:
            if level == Tower.maxLevel { detectionRadius += 1 }
        case .lightning:
            damage *= boost
            cooldown *= 0.88
            // Chain jump count is derived directly from `level`, so no extra state to bump here.
        }
    }

    /// Summary of what the next upgrade improves.
    var upgradeDescription: String {
        switch type {
        case .projectile: return level == Tower.maxLevel - 1 ? "+33% dmg, -12% cooldown, +Second Turret" : "+33% dmg, -12% cooldown"
        case .laser:      return "+33% DPS, -20% cooldown"
        case .fire:       return level == Tower.maxLevel - 1 ? "+33% DPS, +15% duration, +Burning DOT" : "+33% DPS, +15% duration"
        case .ice:        return level == Tower.maxLevel - 1 ? "+20% duration, -18% cooldown, +Double Slow" : "+20% duration, -18% cooldown"
        case .bowler:     return level == Tower.maxLevel - 1 ? "+33% dmg, -12% cooldown, +Ball Bounce" : "+33% dmg, -12% cooldown"
        case .sword:      return level == Tower.maxLevel - 1 ? "+33% dmg, -12% cooldown, +Swipe Arc" : "+33% dmg, -12% cooldown"
        case .healer:     return level == Tower.maxLevel - 1 ? "+1 charge, -10% cooldown, +1 radius" : "+1 charge, -10% cooldown"
        case .fireball:   return level == Tower.maxLevel - 1 ? "+33% dmg, +33% burn DPS, -12% cooldown, +Splash Radius" : "+33% dmg, +33% burn DPS, -12% cooldown"
        case .antiAir:    return level == Tower.maxLevel - 1 ? "+33% dmg, -12% cooldown, +Range" : "+33% dmg, -12% cooldown"
        case .targeting:
            switch level {
            case 1: return "+1 detect range for covered towers; filters immune enemies"
            case 2: return "Unlocks priority enemy type selection"
            case 3: return "Unlocks manual attack lock (A key)"
            case 4: return "+1 fire range to all covered towers"
            case 5: return "+1 aura radius"
            default: return ""
            }
        case .lightning:
            return "+33% dmg, -12% cooldown, +1 Chain Jump"
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
    var shieldMaxHP: Float
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
        var immune: Set<TowerType>
        switch enemyType {
        case .hive:    immune = [.fire, .ice, .sword, .bowler, .fireball, .projectile]
        case .mirroid: immune = [.laser]
        case .wisp:    immune = [.fire, .ice, .sword, .bowler, .fireball, .projectile]
        default:       immune = []
        }
        // Hoppers are out of reach of ground-based sword towers while airborne
        if (enemyType == .hopper || enemyType == .superHopper) && (isJumping || isDroppingFromHive) {
            immune.insert(.sword)
        }
        return immune
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
        self.shieldMaxHP = shieldAmount
        self.shieldHP = shieldAmount
        self.explosionRadius = explosionRadius
        self.explosionDamage = explosionDamage
        switch type {
        case .hopper:
            self.hopperJumpRange = 2...5
            self.hopperJumpInterval = 0.3...1.0
            self.hopperJumpTimer = Float.random(in: 0.5...0.8)
        case .superHopper:
            self.hopperJumpRange = 2...4
            self.hopperJumpInterval = 0.3...0.8
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
    let arcHeight: Float        // parabolic arc peak height (0 = straight line)

    init(origin: SIMD3<Float>, target: SIMD3<Float>, totalFlightTime: Float,
         damage: Float, targetEnemyID: UUID, isAoE: Bool = false, sourceTowerID: UUID? = nil,
         burnOnImpact: Bool = false, impactBurnDPS: Float = 0, impactBurnDuration: Float = 0,
         splashRadius: Int = 0, arcHeight: Float = 1.0) {
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
        self.arcHeight = arcHeight
    }

    var currentPosition: SIMD3<Float> {
        let t = min(elapsed / totalFlightTime, 1.0)
        var pos = origin + (target - origin) * t
        // Arc: parabolic height offset peaking at midpoint
        let arc = 4 * t * (1 - t) * arcHeight
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

    func removeAllCells() { cells.removeAll() }

    func removeCell(at coord: HexCoord) {
        cells.removeValue(forKey: coord)
    }
}
