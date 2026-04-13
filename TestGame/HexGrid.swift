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
}

class Tower {
    let id: UUID = UUID()
    let coord: HexCoord
    let type: TowerType
    let detectionRadius: Int   // hex steps to detect enemies
    let fireRadius: Int        // hex steps projectile can reach
    let projectileSpeed: Float // world units per second (projectile tower only)
    let damage: Float
    let cooldown: Float        // seconds between shots
    var cooldownRemaining: Float = 0
    var currentYaw: Float = 0      // current turret facing angle (radians)
    var targetYaw: Float = 0       // desired turret facing angle
    var hasTarget: Bool = false     // whether the turret is tracking an enemy
    let turretRotationSpeed: Float = 3.0 // radians per second

    // Laser-specific state
    let beamDuration: Float        // how long the beam fires
    let beamDamagePerSecond: Float // DPS to enemies in beam path
    let beamRange: Int             // cells the beam extends
    var isFiringBeam: Bool = false
    var beamTimeRemaining: Float = 0

    // Fire-specific state
    let fireDuration: Float        // how long the fire cone lasts
    let fireDamagePerSecond: Float // DPS to enemies in affected cells
    var isFiringCone: Bool = false
    var fireTimeRemaining: Float = 0
    var fireTargetCoord: HexCoord? // the cell the cone is aimed at

    init(coord: HexCoord, type: TowerType = .projectile,
         detectionRadius: Int = 3, fireRadius: Int = 2,
         projectileSpeed: Float = 6.0, damage: Float = 25, cooldown: Float = 2,
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
              detectionRadius: 6, fireRadius: 5,
              projectileSpeed: 0, damage: 0, cooldown: 3.0,
              beamDuration: 3.0, beamDamagePerSecond: 30, beamRange: 5)
    }

    static func makeFire(coord: HexCoord) -> Tower {
        Tower(coord: coord, type: .fire,
              detectionRadius: 1, fireRadius: 1,
              projectileSpeed: 0, damage: 0, cooldown: 2.0,
              fireDuration: 3.0, fireDamagePerSecond: 25.0)
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

    init(hitPoints: Float, speed: Float) {
        self.hitPoints = hitPoints
        self.maxHitPoints = hitPoints
        self.speed = speed
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

    init(origin: SIMD3<Float>, target: SIMD3<Float>, totalFlightTime: Float,
         damage: Float, targetEnemyID: UUID) {
        self.origin = origin
        self.target = target
        self.totalFlightTime = totalFlightTime
        self.damage = damage
        self.targetEnemyID = targetEnemyID
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
