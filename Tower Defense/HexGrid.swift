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
    case grass       // regular farm, damage multiplier
    case rock        // quarry, accumulates HP for tower
    case gold        // bank, generates gold each round
    case energyField // crystal structure, boosts castle energy
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
    case farm             // on grass       — accumulates damage multiplier for tower placed on it
    case bank             // on gold        — generates gold each round
    case quarry           // on rock        — accumulates HP to boost the tower placed on it
    case crystalStructure // on energyField — boosts castle max energy and energy regen while it stands
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
    /// Snapshotted at the start of a firing cycle: 2.0 while Overcharge is active, else 1.0.
    var overchargeDPSMultiplier: Float = 1.0
}

struct LightningState {
    var duration: Float = 0.5
    var range: Int = 3
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var chainTargetIDs: [UUID] = []  // enemies hit this cast, in bolt order
    var chainDamages: [Float] = []   // total damage dealt to each chain target (falloff already applied)
    /// Snapshotted at the start of a firing cycle: 2.0 while Overcharge is active, else 1.0.
    var overchargeDPSMultiplier: Float = 1.0
}

struct ConeState {
    var duration: Float
    var dps: Float              // 0 for ice
    var isFiring: Bool = false
    var timeRemaining: Float = 0
    var targetCoord: HexCoord? = nil
    var lockedTargetID: UUID? = nil
    /// Snapshotted at the start of a firing cycle: 2.0 while Overcharge is active (fire tower only), else 1.0.
    var overchargeDPSMultiplier: Float = 1.0
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

// MARK: - Damage Types

/// Broad damage-type families used by the enemy resistance system.
enum DamageType {
    case physical
    case energy
    case fire
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

    /// The damage-type family this tower's attacks belong to, for the enemy resistance system.
    /// `nil` for towers that deal no direct damage (ice, healer, targeting).
    var damageType: DamageType? {
        switch self {
        case .projectile, .bowler, .sword, .antiAir: return .physical
        case .laser, .lightning: return .energy
        case .fire, .fireball: return .fire
        case .ice, .healer, .targeting: return nil
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
    // Act II "Hardened" archetypes
    case plated
    case insulated
    case cinder
    // Act III "Apex" archetypes
    case nullifier
    case warden

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
        case .plated:       return "Plated"
        case .insulated:    return "Insulated"
        case .cinder:       return "Cinder"
        case .nullifier:    return "Nullifier"
        case .warden:       return "Warden"
        }
    }

    /// Body half-width as a multiple of `GameState.enemyRadius` (0.1). SINGLE SOURCE OF
    /// TRUTH for gameplay physics (corridor collision, roll rate), the rendered mesh size,
    /// and the RealityKit tap-collision sphere — previously three separate, disagreeing
    /// tables. For a box mesh, this is half its width (the box's horizontal extent is what
    /// the corridor solver treats as the enemy's footprint; a taller/shallower box like the
    /// boss is an intentional visual exception the collider does not need to track).
    var bodyRadiusScale: Float {
        switch self {
        case .basic:         return 1.0
        case .hopper:        return 1.1
        case .tank:          return 2.0
        case .mirroid:       return 2.0
        case .wisp:          return 0.9
        case .fastTank:      return 2.0
        case .shield:        return 1.5
        case .superHopper:   return 1.5
        case .boss:          return 1.5   // half of box width (3r); box is 4r tall
        case .exploder:      return 1.1   // half of box width (2.2r)
        case .superExploder: return 1.5   // half of box width (3r)
        case .hive:          return 2.5
        case .plated:        return 2.0
        case .insulated:     return 1.7
        case .cinder:        return 1.6
        case .nullifier:     return 2.2
        case .warden:        return 1.9
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
    /// While > 0, this tower's firing cooldown recovers at 2× (Castle "Overcharge" ability).
    var overchargeTimer: Float = 0
    /// While > 0, this (healer) tower's heal radius is boosted and its heals cost no charge —
    /// the Castle "Overcharge Heal" ability. Set to `5 * level` seconds when cast; see
    /// `effectiveHealRadius` for the radius bump and `GameState+Abilities.applyOverchargeHeal`.
    var overchargeHealTimer: Float = 0
    /// The heal radius this tower is currently using: boosted to 3 (4 at max level) while
    /// `overchargeHealTimer` is active, otherwise its normal upgrade-driven `healer.radius`.
    /// Only meaningful for `.healer` towers (returns 0 for everyone else).
    var effectiveHealRadius: Int {
        guard let healer else { return 0 }
        guard overchargeHealTimer > 0 else { return healer.radius }
        return level == Tower.maxLevel ? 4 : 3
    }
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
         projectileSpeed: Float = 6.0, damage: Float = 62.5, cooldown: Float = 1.0) {
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
                      projectileSpeed: 0, damage: 0, cooldown: 6.0 * 1.15)
        t.laser = LaserState(duration: 3.0, dps: 180 * 1.2, range: 6)
        return t
    }

    static func makeFire(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .fire,
                      detectionRadius: 2, fireRadius: 2,
                      projectileSpeed: 0, damage: 0, cooldown: 0.5)
        t.cone = ConeState(duration: 3.5, dps: 157.8125 * 1.1)
        return t
    }

    static func makeIce(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .ice,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 0, cooldown: 0.6)
        t.cone = ConeState(duration: 3.0, dps: 0)
        return t
    }

    /// Ice tower's slow strength, scaling linearly from 20% at level 1 to 60% at max level.
    var iceSlowPercent: Float {
        0.20 + (0.60 - 0.20) * Float(level - 1) / Float(Tower.maxLevel - 1)
    }

    /// Chance per second a max-level ice tower freezes an enemy solid while in its cone.
    static let iceFreezeChancePerSecond: Float = 0.10
    static let iceFreezeDuration: Float = 5.0

    static func makeSword(coord: HexCoord) -> Tower {
        let t = Tower(coord: coord, type: .sword,
                      detectionRadius: 1, fireRadius: 1,
                      projectileSpeed: 0, damage: 112.5 * 1.15 * 1.5, cooldown: 0.84)
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
                      projectileSpeed: 5.0, damage: 375, cooldown: 2.5)
        t.fireball = FireballState(splashRadius: 1, burnDuration: 2.0, burnDPS: 50.0)
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
                      projectileSpeed: 0, damage: 198 * 1.2, cooldown: 2.5)
        t.lightning = LightningState(duration: 0.5, range: 3)
        return t
    }

    var canUpgrade: Bool { level < Tower.maxLevel }

    /// Cost to upgrade to the next level.
    var upgradeCost: Int {
        let base: Int
        switch type {
        case .projectile: base = 22
        case .laser:      base = 50
        case .fire:       base = 28
        case .ice:        base = 44
        case .bowler:     base = 20
        case .sword:      base = 18
        case .healer:     base = 30
        case .fireball:   base = 53
        case .antiAir:    base = 35
        case .targeting:  base = 75
        case .lightning:  base = 48
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
            // Reaching level 4 grants a permanent extra heart of life (levels 5/6 don't add
            // another — this fires exactly once, on the level 3 -> 4 transition, whether
            // purchased one level at a time or applied retroactively via a tech node).
            if level == 4 {
                hitPoints += 1
                maxHitPoints += 1
            }
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
        case .ice:        return level == Tower.maxLevel - 1 ? "+20% duration, -18% cooldown, +8% slow, +10%/s Freeze Chance" : "+20% duration, -18% cooldown, +8% slow"
        case .bowler:     return level == Tower.maxLevel - 1 ? "+33% dmg, -12% cooldown, +Ball Bounce" : "+33% dmg, -12% cooldown"
        case .sword:
            if level == Tower.maxLevel - 1 { return "+33% dmg, -12% cooldown, +Swipe Arc" }
            if level == 3 { return "+33% dmg, -12% cooldown, +1 Heart" }
            return "+33% dmg, -12% cooldown"
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
    var frozen: Bool = false      // fully immobilized (max-level Ice tower proc)
    var frozenTimer: Float = 0    // remaining seconds of freeze
    var burning: Bool = false
    var burnTimer: Float = 0      // remaining seconds of burn
    var burnDPS: Float = 10.0     // damage per second while burning
    var poisoned: Bool = false
    var poisonTimer: Float = 0    // remaining seconds of poison (Poison castle ability)
    var poisonDPS: Float = 0      // damage per second while poisoned — 1% of maxHitPoints

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

    /// Whether this enemy is currently standing inside an active Castle "Gravity Wave" field —
    /// updated every frame for every active enemy by `GameState.updateGravityWaveField`. Read by
    /// `triggerHopperJump` (restricts jump range to 1), `effectiveHoverOffset` (halves flying
    /// height), and `immuneTowerTypes` (strips flying units' immunity to ground towers).
    var inGravityWave: Bool = false

    /// `additionalHoverOffset`, halved while caught in a Gravity Wave field — see `inGravityWave`.
    var effectiveHoverOffset: Float { inGravityWave ? additionalHoverOffset * 0.5 : additionalHoverOffset }

    /// Tower types that cannot *target* this enemy at all — purely positional/targetability rules
    /// (airborne units out of reach of ground-only towers). Damage-type resistance is handled
    /// separately by `resistances`/`resistanceMultiplier(for:)`.
    var immuneTowerTypes: Set<TowerType> {
        // A Gravity Wave field drags flyers down into range of every tower, ground included.
        if inGravityWave { return [] }
        var immune: Set<TowerType>
        switch enemyType {
        case .hive:    immune = [.fire, .ice, .sword, .bowler, .fireball, .projectile]
        case .wisp:    immune = [.fire, .ice, .sword, .bowler, .fireball, .projectile]
        default:       immune = []
        }
        // Hoppers are out of reach of ground-based sword towers while airborne
        if (enemyType == .hopper || enemyType == .superHopper) && (isJumping || isDroppingFromHive) {
            immune.insert(.sword)
        }
        return immune
    }

    /// Fractional damage-type resistances, in `-1.0...1.0` (positive = resist, `1.0` = full
    /// immunity, negative = vulnerability). Set at spawn time in `_makeEnemy`.
    var resistances: [DamageType: Float] = [:]

    /// Temporary all-type resistance bonus granted by a nearby living Warden. Recomputed every
    /// frame by `GameState.applyWardenAura()` — zero the instant the enemy leaves aura range or
    /// the warden dies. Stacks additively on top of `resistances` in `resistanceMultiplier(for:)`.
    var wardenAuraBonus: Float = 0

    /// Multiplier applied to incoming damage of the given type: `1 - (resistances[type] + wardenAuraBonus)`.
    /// Defaults to `1.0` (no reduction) when the enemy has no entry for that type, or when
    /// `type` is `nil` (the attacking tower deals no typed damage).
    func resistanceMultiplier(for type: DamageType?) -> Float {
        guard let type else { return 1.0 }
        return 1.0 - (resistances[type] ?? 0) - wardenAuraBonus
    }

    /// Cinder is immune to the burning DOT status effect entirely (on top of its fractional
    /// fire resistance, which still reduces direct fire-tower/fireball hits).
    var isBurnImmune: Bool { enemyType == .cinder }

    // Hopper-specific state
    var hopperJumpTimer: Float = 0      // countdown to next jump
    var isJumping: Bool = false         // currently mid-air
    var jumpProgress: Float = 0         // 0→1 during arc
    let jumpDuration: Float = 0.28      // seconds in the air
    let hopperJumpRange: ClosedRange<Int>   // cells skipped per jump
    let hopperJumpInterval: ClosedRange<Float>  // seconds between jumps
    var jumpFromPos: SIMD3<Float>? = nil
    var jumpToPos: SIMD3<Float>? = nil

    // MARK: - Corridor / crowd state (GameState+Crowd.swift)

    /// Signed offset from the path centerline, in world units, perpendicular to the path
    /// tangent in XZ (positive = left of travel). Rotates with the frame automatically at
    /// corners and cell transitions — never needs conversion. Physical and cosmetic only;
    /// never a targeting input (see `GameState.enemyNearestCoord`).
    var lateralOffset: Float = 0
    /// Latched avoidance side chosen by the corridor solver: -1 right, 0 none, +1 left.
    /// Not re-evaluated while `avoidHold > 0`, which prevents side-to-side oscillation.
    var avoidSide: Int8 = 0
    /// Seconds the latched `avoidSide` stays locked in before it can be re-evaluated.
    var avoidHold: Float = 0
    /// Seconds this enemy has been continuously unblocked; gates recentring back to `avoidSide = 0`.
    var clearTimer: Float = 0
    /// Exponential moving average of actual along-path world speed, seeded to `speed`. Feeds
    /// `predictEnemyPosition` so projectile lead accounts for enemies slowed/stopped by traffic.
    var observedSpeed: Float
    /// Previous frame's world position; used to derive `rollDeltaAngle`/`rollAxis` from actual
    /// displacement rather than intended speed, so a blocked enemy doesn't visually keep rolling.
    var lastWorldPos: SIMD3<Float>? = nil
    /// Monotonic creation index — deterministic tiebreak when two enemies share a sort key
    /// (e.g. pinned at the same gravity-well tile). Not a UUID: needs to be `Comparable`
    /// and cheap to compare in the solver's inner loop.
    let seq: Int
    private static var nextSeq: Int = 0

    init(type: EnemyType, hitPoints: Float, speed: Float, baseDamage: Int = 1,
         shieldAmount: Float = 0, explosionRadius: Int = 0, explosionDamage: Int = 0) {
        self.enemyType = type
        self.hitPoints = hitPoints
        self.maxHitPoints = hitPoints
        self.speed = speed
        self.observedSpeed = speed
        Enemy.nextSeq += 1
        self.seq = Enemy.nextSeq
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

    /// Bumped on every topology change (cell add/remove). Lets callers cache derived
    /// path data (e.g. GameState.cachedStepsToEnd) and cheaply detect when it's stale,
    /// without having to hook every individual call site that mutates the grid.
    private(set) var pathVersion: Int = 0

    func addCell(_ cell: HexCell) {
        cells[cell.coord] = cell
        pathVersion += 1
    }

    func cell(at coord: HexCoord) -> HexCell? {
        cells[coord]
    }

    func neighbors(of coord: HexCoord) -> [HexCell] {
        (0..<6).compactMap { cells[coord.neighbor($0)] }
    }

    func removeAllCells() {
        cells.removeAll()
        pathVersion += 1
    }

    func removeCell(at coord: HexCoord) {
        cells.removeValue(forKey: coord)
        pathVersion += 1
    }
}
