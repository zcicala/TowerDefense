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

    /// Fixed HP for a regular (non-boss) enemy type — the same at every round. See
    /// `GameState.baseHP(for:)`; waves are sized by head-count (`buildWave`), not by HP.
    private func debutHP(for type: EnemyType) -> Float {
        GameState.baseHP(for: type)
    }

    func _makeEnemy(type: EnemyType, hp: Float, speed: Float) -> Enemy {
        switch type {
        case .basic:
            let fast = rng.randomBool()
            return Enemy(type: .basic, hitPoints: debutHP(for: .basic), speed: speed * (fast ? 2.0 : 1.0))
        case .tank:
            return Enemy(type: .tank, hitPoints: debutHP(for: .tank), speed: speed * 1, baseDamage: 2)
        case .mirroid:
            let e = Enemy(type: .mirroid, hitPoints: debutHP(for: .mirroid), speed: speed * 1, baseDamage: 3)
            e.resistances[.energy] = 1.0
            return e
        case .fastTank:
            return Enemy(type: .fastTank, hitPoints: debutHP(for: .fastTank), speed: speed * 1.4, baseDamage: 2)
        case .exploder:
            return Enemy(type: .exploder, hitPoints: debutHP(for: .exploder), speed: speed * 1.5,
                         explosionRadius: 1, explosionDamage: 1)
        case .superExploder:
            return Enemy(type: .superExploder, hitPoints: debutHP(for: .superExploder), speed: speed * 1.2,
                         explosionRadius: 2, explosionDamage: 2)
        case .shield:
            let shieldAmt = GameState.shieldBarrier
            let e = Enemy(type: .shield, hitPoints: debutHP(for: .shield), speed: speed * 0.75, shieldAmount: shieldAmt)
            e.resistances[.physical] = 0.5
            return e
        case .hopper:
            return Enemy(type: .hopper, hitPoints: debutHP(for: .hopper), speed: speed)
        case .superHopper:
            return Enemy(type: .superHopper, hitPoints: debutHP(for: .superHopper), speed: speed * 1.2)
        case .boss:
            // Mr Grump is the one enemy that still gets proportionally harder every time he
            // shows up — both HP (unchanged formula) and now baseDamage scale with round.
            // Damage grows gently (+1 roughly every 5 rounds, matching how often he spawns,
            // accelerated a bit in later acts via bossMultiplier) rather than as aggressively
            // as HP, since it chips directly at the player's limited base HP pool.
            let bossHP = GameState.bossHP(forRound: round)
            let bossDamage = 5 + Int((Float(round - 1) / 5.0 * tier(for: round).bossMultiplier).rounded())
            return Enemy(type: .boss, hitPoints: bossHP, speed: speed * 0.5, baseDamage: bossDamage)
        case .hive:
            let e = Enemy(type: .hive, hitPoints: debutHP(for: .hive), speed: speed * 0.6, baseDamage: 2)
            e.additionalHoverOffset = 1.5
            return e
        case .wisp:
            let e = Enemy(type: .wisp, hitPoints: debutHP(for: .wisp), speed: speed * 1.3)
            e.additionalHoverOffset = 0.7
            return e
        case .plated:
            // Act II "Hardened": heavily armored against physical towers.
            let e = Enemy(type: .plated, hitPoints: debutHP(for: .plated), speed: speed * 0.9, baseDamage: 2)
            e.resistances[.physical] = 0.6
            return e
        case .insulated:
            // Act II "Hardened": fractional mirroid successor — resists energy but isn't immune.
            let e = Enemy(type: .insulated, hitPoints: debutHP(for: .insulated), speed: speed * 1.05)
            e.resistances[.energy] = 0.6
            return e
        case .cinder:
            // Act II "Hardened": resists fire damage and shrugs off burning entirely (see `isBurnImmune`).
            let e = Enemy(type: .cinder, hitPoints: debutHP(for: .cinder), speed: speed * 1.1)
            e.resistances[.fire] = 0.7
            return e
        case .nullifier:
            // Act III "Apex": resists everything a little rather than one thing a lot.
            let e = Enemy(type: .nullifier, hitPoints: debutHP(for: .nullifier), speed: speed * 0.85, baseDamage: 2)
            e.resistances[.physical] = 0.4
            e.resistances[.energy] = 0.4
            e.resistances[.fire] = 0.4
            return e
        case .warden:
            // Act III "Apex": support unit — grants nearby enemies a temporary resistance
            // buff while alive (see `applyWardenAura` in GameState+Combat.swift).
            return Enemy(type: .warden, hitPoints: debutHP(for: .warden), speed: speed * 0.8, baseDamage: 2)
        case .brute:
            // Late-game bruiser (~77k HP): no resistances, just a lot of health.
            return Enemy(type: .brute, hitPoints: debutHP(for: .brute), speed: speed * 0.8, baseDamage: 3)
        case .colossus:
            // ~124k HP.
            return Enemy(type: .colossus, hitPoints: debutHP(for: .colossus), speed: speed * 0.7, baseDamage: 4)
        case .titan:
            // ~214k HP.
            return Enemy(type: .titan, hitPoints: debutHP(for: .titan), speed: speed * 0.6, baseDamage: 5)
        }
    }

    /// Roster entries that can spawn this round. Debut types spawn once per intro round; if that
    /// empties the pool (the first round of a new act debuts most of its roster at once), fall
    /// back to the full eligible roster.
    private func spawnCandidates(excludingIntro: [EnemyType]) -> [EnemySpawnConfig] {
        let inRange = tier(for: round).roster.filter { $0.minRound <= round && $0.maxRound >= round }
        let fresh = inRange.filter { !($0.minRound == round && excludingIntro.contains($0.type)) }
        return fresh.isEmpty ? inRange : fresh
    }

    private func weightedPick(_ configs: [EnemySpawnConfig], theme: WaveTheme?) -> EnemyType? {
        let totalWeight = configs.reduce(0.0) {
            $0 + $1.weight * (theme?.weightMultiplier(for: $1.type) ?? 1.0)
        }
        guard totalWeight > 0, !configs.isEmpty else { return nil }
        var roll = rng.randomFloat(in: 0..<totalWeight)
        for config in configs {
            roll -= config.weight * (theme?.weightMultiplier(for: config.type) ?? 1.0)
            if roll <= 0 { return config.type }
        }
        return configs.last?.type
    }

    /// Picks a random enemy type from eligible configs using weighted sampling.
    /// Pass a `theme` to bias the pool toward that wave's featured enemy types.
    func pickSpawnType(excludingIntro: [EnemyType] = [], theme: WaveTheme? = nil) -> EnemyType {
        // Defensive: fall back to basic rather than crashing on an empty pool.
        weightedPick(spawnCandidates(excludingIntro: excludingIntro), theme: theme) ?? .basic
    }

    /// Builds the round's regular wave by spending its HP budget (`targetRegularHP`) on
    /// weighted-random enemies of fixed HP, until nothing affordable is left or the cap is hit.
    /// Total HP follows the smooth budget curve; only the mix and head-count change.
    func buildWave(forRound targetRound: Int, theme: WaveTheme?) -> [EnemyType] {
        var remaining = GameState.targetRegularHP(forRound: targetRound)
        var wave: [EnemyType] = []
        var introUsed: [EnemyType] = []
        let roster = tier(for: targetRound).roster
        while wave.count < GameState.maxEnemiesPerRound {
            let affordable = spawnCandidates(excludingIntro: introUsed)
                .filter { GameState.spawnCost(for: $0.type) <= remaining }
            guard let type = weightedPick(affordable, theme: theme) else { break }
            if roster.first(where: { $0.type == type })?.minRound == targetRound { introUsed.append(type) }
            remaining -= GameState.spawnCost(for: type)
            wave.append(type)
        }
        return wave
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

        // Every 10th round ends by opening a branch path; find its route in the background now.
        if round % 10 == 0 { beginBranchRouteSearch() }

        // Castle abilities start each round ready to cast.
        resetAbilities()

        // Consume the pre-picked theme (or pick one now for round 1, before returnToPlacing has run)
        if round % 3 == 0 && upcomingWaveTheme == nil {
            let eligible = WaveTheme.allCases.filter { $0.minRound <= round }
            upcomingWaveTheme = rng.randomElement(eligible)
        }
        currentWaveTheme = (round % 3 == 0) ? upcomingWaveTheme : nil
        upcomingWaveTheme = nil

        let activeTier = tier(for: round)
        let hp: Float = activeTier.hp(atRound: round)
        let speed: Float = activeTier.speed(atRound: round)

        let wave = buildWave(forRound: round, theme: currentWaveTheme)
        enemiesToSpawn = wave.count
        // Reset every active path's spawn timer for the new round (paths that no longer
        // exist, e.g. after a restart, are simply dropped rather than carried forward).
        // Sorted for a stable RNG draw order — Dictionary.values has no guaranteed iteration
        // order, and without sorting, which start cell gets which random interval (and thus
        // all RNG state downstream) would vary run-to-run even with the same seed.
        let startCoords = spawnCells.map(\.coord)
        spawnTimers = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, Float(0)) })
        spawnIntervals = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, rng.randomFloat(in: 0.3...1.0) * spawnIntervalMultiplier(at: $0)) })
        spawnBlockedFor = Dictionary(uniqueKeysWithValues: startCoords.map { ($0, Float(0)) })

        enemies.removeAll()
        projectiles.removeAll()

        for type in wave {
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
