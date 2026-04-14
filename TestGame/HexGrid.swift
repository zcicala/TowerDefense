//
//  HexGrid.swift
//  TestGame
//

import Foundation

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

/// Represents a single hex cell with game state (no rendering dependency).
class HexCell {
    let coord: HexCoord
    let height: Float

    var type: HexCellType = .path
    var isSelected: Bool = false
    var isPassable: Bool = true
    var hasTower: Bool = false

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
}

enum TargetingMode: String, CaseIterable {
    case closest = "Closest"
    case furthestAhead = "Furthest Ahead"
    case furthestBehind = "Furthest Behind"
    case mostHealth = "Most Health"
    case leastHealth = "Least Health"
}

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

    init(coord: HexCoord, type: TowerType = .projectile,
         detectionRadius: Int = 6, fireRadius: Int = 5,
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
              detectionRadius: 8, fireRadius: 7,
              projectileSpeed: 0, damage: 0, cooldown: 3.0,
              beamDuration: 3.0, beamDamagePerSecond: 60, beamRange: 7)
    }

    static func makeFire(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .fire,
              detectionRadius: 2, fireRadius: 1,
              projectileSpeed: 0, damage: 0, cooldown: 0.5,
              fireDuration: 3.5, fireDamagePerSecond: 18.0)
    }

    static func makeIce(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .ice,
              detectionRadius: 3, fireRadius: 2,
              projectileSpeed: 0, damage: 0, cooldown: 2.0,
              fireDuration: 3.0, fireDamagePerSecond: 0)
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
            beamDuration *= 1.15
            cooldown *= 0.88
            // Max level bonus: extended range
            if level == Tower.maxLevel {
                fireRadius = 10
                detectionRadius = 11
                beamRange = 10
            }
        case .fire:
            fireDamagePerSecond *= boost
            fireDuration *= 1.15
            cooldown *= 0.88
        case .ice:
            fireDuration *= 1.2
            cooldown *= 0.82
        }
    }

    /// Summary of what the next upgrade improves.
    var upgradeDescription: String {
        switch type {
        case .projectile: return "+25% dmg, -12% cooldown"
        case .laser: return "+25% DPS, +15% duration"
        case .fire: return "+25% DPS, +15% duration"
        case .ice: return "+20% duration, -18% cooldown"
        }
    }
}

// MARK: - Enemy

class Enemy {
    let id: UUID = UUID()
    var currentCell: HexCell?
    var progress: Float = 0       // 0...1 between current and next cell
    var hitPoints: Float
    let maxHitPoints: Float
    let speed: Float              // world units per second
    var active: Bool = true
    var reachedEnd: Bool = false
    var slowed: Bool = false
    let isBoss: Bool
    let isTank: Bool
    let baseDamage: Int  // damage dealt to base tower on reaching end
    var slowTimer: Float = 0  // remaining seconds of slow effect
    var slowFactor: Float = 0.5  // speed multiplier when slowed
    var burning: Bool = false
    var burnTimer: Float = 0  // remaining seconds of burn
    let burnDPS: Float = 10.0  // damage per second while burning

    // Shield emitter properties
    let isShielder: Bool
    var shieldHP: Float = 0
    let shieldMaxHP: Float
    let shieldRegen: Float  // HP per second
    var shieldActive: Bool { shieldHP > 0 }

    init(hitPoints: Float, speed: Float, isBoss: Bool = false, isTank: Bool = false, isShielder: Bool = false, shieldAmount: Float = 100, baseDamage: Int = 1) {
        self.hitPoints = hitPoints
        self.maxHitPoints = hitPoints
        self.speed = speed
        self.isBoss = isBoss
        self.isTank = isTank
        self.isShielder = isShielder
        self.shieldMaxHP = isShielder ? shieldAmount : 0
        self.shieldHP = isShielder ? shieldAmount : 0
        self.shieldRegen = isShielder ? 10 : 0
        self.baseDamage = baseDamage
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

    init(origin: SIMD3<Float>, target: SIMD3<Float>, totalFlightTime: Float,
         damage: Float, targetEnemyID: UUID, isAoE: Bool = false) {
        self.origin = origin
        self.target = target
        self.totalFlightTime = totalFlightTime
        self.damage = damage
        self.targetEnemyID = targetEnemyID
        self.isAoE = isAoE
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
}
