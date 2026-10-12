import Foundation

extension GameState {

    // MARK: - Enemy Spawning

    /// Creates an enemy of the given type. `hp`/`speed` are the shared, round-scaled values
    /// computed by the caller from `EnemyTier` — every regular (non-boss) type now ignores the
    /// `hp` it's handed and uses `debutHP(for:multiplier:)` instead (round scaling for HP is
    /// gone except for the boss, which keeps its own dedicated formula below). `speed` still
    /// scales with round for everyone, unchanged.
    /// (The old universal "every enemy gets a personal shield at round 25" wall has been
    /// removed — that difficulty spike is now handled by the shield/Plated archetypes
    /// themselves via `resistances` and the Act II/III tier rosters.)
    func makeEnemy(type: EnemyType, hp: Float, speed: Float) -> Enemy {
        _makeEnemy(type: type, hp: hp, speed: speed)
    }

    /// Fixed HP for a regular (non-boss) enemy type: `multiplier` applied to
    /// `EnemyTier.hp(atRound:)` evaluated at the type's earliest possible round (see
    /// `GameState.debutRound(for:)`), then bumped by 20%. This is what pins each type's HP to
    /// what it would have been under the old always-scaling-with-round formula the moment it
    /// first became eligible to spawn, rather than letting it keep growing every round after.
    private func debutHP(for type: EnemyType, multiplier: Float) -> Float {
        let debut = GameState.debutRound(for: type)
        return tier(for: debut).hp(atRound: debut) * multiplier * 1.2
    }

    func _makeEnemy(type: EnemyType, hp: Float, speed: Float) -> Enemy {
        switch type {
        case .basic:
            let fast = rng.randomBool()
            return Enemy(type: .basic, hitPoints: debutHP(for: .basic, multiplier: 1.0), speed: speed * (fast ? 2.0 : 1.0))
        case .tank:
            return Enemy(type: .tank, hitPoints: debutHP(for: .tank, multiplier: 4.0), speed: speed * 1, baseDamage: 2)
        case .mirroid:
            let e = Enemy(type: .mirroid, hitPoints: debutHP(for: .mirroid, multiplier: 4.0), speed: speed * 1, baseDamage: 3)
            e.resistances[.energy] = 1.0
            return e
        case .fastTank:
            return Enemy(type: .fastTank, hitPoints: debutHP(for: .fastTank, multiplier: 8.0), speed: speed * 1.4, baseDamage: 2)
        case .exploder:
            return Enemy(type: .exploder, hitPoints: debutHP(for: .exploder, multiplier: 0.8), speed: speed * 1.5,
                         explosionRadius: 1, explosionDamage: 1)
        case .superExploder:
            return Enemy(type: .superExploder, hitPoints: debutHP(for: .superExploder, multiplier: 2.4), speed: speed * 1.2,
                         explosionRadius: 2, explosionDamage: 2)
        case .shield:
            let shieldAmt = Float(270 + 120 * round)
            let e = Enemy(type: .shield, hitPoints: debutHP(for: .shield, multiplier: 2.0), speed: speed * 0.75, shieldAmount: shieldAmt)
            e.resistances[.physical] = 0.5
            return e
        case .hopper:
            return Enemy(type: .hopper, hitPoints: debutHP(for: .hopper, multiplier: 0.35), speed: speed)
        case .superHopper:
            return Enemy(type: .superHopper, hitPoints: debutHP(for: .superHopper, multiplier: 1.5), speed: speed * 1.2)
        case .boss:
            // Mr Grump is the one enemy that still gets proportionally harder every time he
            // shows up — both HP (unchanged formula) and now baseDamage scale with round.
            // Damage grows gently (+1 roughly every 5 rounds, matching how often he spawns,
            // accelerated a bit in later acts via bossMultiplier) rather than as aggressively
            // as HP, since it chips directly at the player's limited base HP pool.
            let bossHP = 100 + hp * Float(round) * tier(for: round).bossMultiplier
            let bossDamage = 5 + Int((Float(round - 1) / 5.0 * tier(for: round).bossMultiplier).rounded())
            return Enemy(type: .boss, hitPoints: bossHP, speed: speed * 0.5, baseDamage: bossDamage)
        case .hive:
            let e = Enemy(type: .hive, hitPoints: debutHP(for: .hive, multiplier: 6.3), speed: speed * 0.6, baseDamage: 2)
            e.additionalHoverOffset = 1.5
            return e
        case .wisp:
            let e = Enemy(type: .wisp, hitPoints: debutHP(for: .wisp, multiplier: 1.0), speed: speed * 1.3)
            e.additionalHoverOffset = 0.7
            return e
        case .plated:
            // Act II "Hardened": heavily armored against physical towers.
            let e = Enemy(type: .plated, hitPoints: debutHP(for: .plated, multiplier: 4.4), speed: speed * 0.9, baseDamage: 2)
            e.resistances[.physical] = 0.6
            return e
        case .insulated:
            // Act II "Hardened": fractional mirroid successor — resists energy but isn't immune.
            let e = Enemy(type: .insulated, hitPoints: debutHP(for: .insulated, multiplier: 3.2), speed: speed * 1.05)
            e.resistances[.energy] = 0.6
            return e
        case .cinder:
            // Act II "Hardened": resists fire damage and shrugs off burning entirely (see `isBurnImmune`).
            let e = Enemy(type: .cinder, hitPoints: debutHP(for: .cinder, multiplier: 2.8), speed: speed * 1.1)
            e.resistances[.fire] = 0.7
            return e
        case .nullifier:
            // Act III "Apex": resists everything a little rather than one thing a lot.
            let e = Enemy(type: .nullifier, hitPoints: debutHP(for: .nullifier, multiplier: 4.0), speed: speed * 0.85, baseDamage: 2)
            e.resistances[.physical] = 0.4
            e.resistances[.energy] = 0.4
            e.resistances[.fire] = 0.4
            return e
        case .warden:
            // Act III "Apex": support unit — grants nearby enemies a temporary resistance
            // buff while alive (see `applyWardenAura` in GameState+Combat.swift).
            return Enemy(type: .warden, hitPoints: debutHP(for: .warden, multiplier: 3.6), speed: speed * 0.8, baseDamage: 2)
        case .brute:
            // Late-game bruiser (~49k HP): no resistances, just a lot of health.
            return Enemy(type: .brute, hitPoints: debutHP(for: .brute, multiplier: 7.7), speed: speed * 0.8, baseDamage: 3)
        case .colossus:
            // ~91k HP.
            return Enemy(type: .colossus, hitPoints: debutHP(for: .colossus, multiplier: 11.0), speed: speed * 0.7, baseDamage: 4)
        case .titan:
            // ~179k HP.
            return Enemy(type: .titan, hitPoints: debutHP(for: .titan, multiplier: 20.0), speed: speed * 0.6, baseDamage: 5)
        }
    }

    /// Picks a random enemy type from eligible configs using weighted sampling.
    /// Pass a `theme` to bias the pool toward that wave's featured enemy types.
    func pickSpawnType(excludingIntro: [EnemyType] = [], theme: WaveTheme? = nil) -> EnemyType {
        let eligible = tier(for: round).roster.filter {
            $0.minRound <= round && $0.maxRound >= round &&
            !($0.minRound == round && excludingIntro.contains($0.type))
        }
        let totalWeight = eligible.reduce(0.0) {
            $0 + $1.weight * (theme?.weightMultiplier(for: $1.type) ?? 1.0)
        }
        // Defensive: if the intro-exclusion filter emptied the pool (e.g. a mis-tuned roster
        // where a round's only eligible type is also its debut), fall back to basic rather
        // than crashing on an empty random range.
        guard totalWeight > 0, !eligible.isEmpty else { return .basic }
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

        // Castle abilities start each round ready to cast.
        resetAbilities()

        // Consume the pre-picked theme (or pick one now for round 1, before returnToPlacing has run)
        if round % 3 == 0 && upcomingWaveTheme == nil {
            let eligible = WaveTheme.allCases.filter { $0.minRound <= round }
            upcomingWaveTheme = rng.randomElement(eligible)
        }
        currentWaveTheme = (round % 3 == 0) ? upcomingWaveTheme : nil
        upcomingWaveTheme = nil

        let enemyCount = GameState.enemyCount(forRound: round)
        let activeTier = tier(for: round)
        let hp: Float = activeTier.hp(atRound: round)
        let speed: Float = activeTier.speed(atRound: round)

        enemiesToSpawn = enemyCount
        // Reset every active path's spawn timer for the new round (paths that no longer
        // exist, e.g. after a restart, are simply dropped rather than carried forward).
        // Sorted for a stable RNG draw order — Dictionary.values has no guaranteed iteration
        // order, and without sorting, which start cell gets which random interval (and thus
        // all RNG state downstream) would vary run-to-run even with the same seed.
        let startCoords = hexGrid.cells.values.filter { $0.type == .start }
            .map(\.coord).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        spawnTimers = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, Float(0)) })
        spawnIntervals = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, rng.randomFloat(in: 0.3...1.0)) })
        spawnBlockedFor = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, Float(0)) })

        enemies.removeAll()
        projectiles.removeAll()

        // Weighted random pool of regular enemies — debut types spawn only once per intro round
        var introTypesUsed: [EnemyType] = []
        for _ in 0..<enemyCount {
            let type = pickSpawnType(excludingIntro: introTypesUsed, theme: currentWaveTheme)
            if activeTier.roster.first(where: { $0.type == type })?.minRound == round {
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
