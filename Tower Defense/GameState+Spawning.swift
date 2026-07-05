import Foundation

extension GameState {

    // MARK: - Enemy Spawning

    /// Creates an enemy of the given type using scaled base HP and speed for the round.
    func makeEnemy(type: EnemyType, hp: Float, speed: Float) -> Enemy {
        let enemy = _makeEnemy(type: type, hp: hp, speed: speed)
        if round >= 25 && type != .shield {
            let personalShield = hp * 0.5
            enemy.shieldMaxHP = personalShield
            enemy.shieldHP = personalShield
        }
        return enemy
    }

    func _makeEnemy(type: EnemyType, hp: Float, speed: Float) -> Enemy {
        switch type {
        case .basic:
            let fast = rng.randomBool()
            return Enemy(type: .basic, hitPoints: hp, speed: speed * (fast ? 2.0 : 1.0))
        case .tank:
            return Enemy(type: .tank, hitPoints: hp * 4, speed: speed * 1, baseDamage: 2)
        case .mirroid:
            return Enemy(type: .mirroid, hitPoints: hp * 4, speed: speed * 1, baseDamage: 2)
        case .fastTank:
            return Enemy(type: .fastTank, hitPoints: hp * 4, speed: speed * 1.4, baseDamage: 2)
        case .exploder:
            return Enemy(type: .exploder, hitPoints: hp * 0.8, speed: speed * 1.5,
                         explosionRadius: 1, explosionDamage: 1)
        case .superExploder:
            return Enemy(type: .superExploder, hitPoints: hp * 1.2, speed: speed * 1.2,
                         explosionRadius: 2, explosionDamage: 2)
        case .shield:
            let shieldAmt = Float(270 + 120 * round)
            return Enemy(type: .shield, hitPoints: hp, speed: speed * 0.75, shieldAmount: shieldAmt)
        case .hopper:
            return Enemy(type: .hopper, hitPoints: hp * 0.7, speed: speed)
        case .superHopper:
            return Enemy(type: .superHopper, hitPoints: hp * 1.5, speed: speed * 1.2)
        case .boss:
            let bossHP = 100 + hp * Float(round)
            return Enemy(type: .boss, hitPoints: bossHP, speed: speed * 0.5, baseDamage: 5)
        case .hive:
            let e = Enemy(type: .hive, hitPoints: hp * 6.3, speed: speed * 0.6, baseDamage: 2)
            e.additionalHoverOffset = 1.5
            return e
        case .wisp:
            let e = Enemy(type: .wisp, hitPoints: hp * 1.0, speed: speed * 1.3)
            e.additionalHoverOffset = 0.7
            return e
        }
    }

    /// Picks a random enemy type from eligible configs using weighted sampling.
    /// Pass a `theme` to bias the pool toward that wave's featured enemy types.
    func pickSpawnType(excludingIntro: [EnemyType] = [], theme: WaveTheme? = nil) -> EnemyType {
        let eligible = spawnConfigs.filter {
            $0.minRound <= round && $0.maxRound >= round &&
            !($0.minRound == round && excludingIntro.contains($0.type))
        }
        let totalWeight = eligible.reduce(0.0) {
            $0 + $1.weight * (theme?.weightMultiplier(for: $1.type) ?? 1.0)
        }
        var roll = rng.randomFloat(in: 0..<totalWeight)
        for config in eligible {
            roll -= config.weight * (theme?.weightMultiplier(for: config.type) ?? 1.0)
            if roll <= 0 { return config.type }
        }
        return eligible.last?.type ?? .basic
    }

    /// Pre-picks and stores the wave theme for `targetRound`, if it's a theme round.
    func pickUpcomingTheme(for targetRound: Int) {
        guard targetRound % 3 == 0 else { upcomingWaveTheme = nil; return }
        let eligible = WaveTheme.allCases.filter { $0.minRound <= targetRound }
        upcomingWaveTheme = rng.randomElement(eligible)
    }

    // MARK: - Round Management

    func startRound() {
        guard phase == .placing else { return }
        round += 1
        phase = .combat

        // Consume the pre-picked theme (or pick one now for round 1, before returnToPlacing has run)
        if round % 3 == 0 && upcomingWaveTheme == nil {
            let eligible = WaveTheme.allCases.filter { $0.minRound <= round }
            upcomingWaveTheme = rng.randomElement(eligible)
        }
        currentWaveTheme = (round % 3 == 0) ? upcomingWaveTheme : nil
        upcomingWaveTheme = nil

        let enemyCount = 3 + round * 3
        let hp: Float = Float(256 + round * 102)
        let speed: Float = 1.2 + Float(round) * 0.03

        enemiesToSpawn = enemyCount
        spawnInterval = rng.randomFloat(in: 0.3...1.0)
        spawnTimer = 0

        enemies.removeAll()
        projectiles.removeAll()

        // Weighted random pool of regular enemies — debut types spawn only once per intro round
        var introTypesUsed: [EnemyType] = []
        for _ in 0..<enemyCount {
            let type = pickSpawnType(excludingIntro: introTypesUsed, theme: currentWaveTheme)
            if spawnConfigs.first(where: { $0.type == type })?.minRound == round {
                introTypesUsed.append(type)
            }
            enemies.append(makeEnemy(type: type, hp: hp, speed: speed))
        }

        // Boss every 5 rounds — spawns in the middle of the wave
        if round % 5 == 0 {
            let midIndex = enemies.count / 2
            enemies.insert(makeEnemy(type: .boss, hp: hp, speed: speed), at: midIndex)
        }

        // Deactivate all — they'll be activated by the spawner
        for enemy in enemies {
            enemy.active = false
        }
    }
}
