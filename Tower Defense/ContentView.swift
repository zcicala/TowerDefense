//
//  ContentView.swift
//  TestGame
//
//  Created by Zac on 4/10/26.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @State private var gameState = GameState()
    @State private var renderer: SceneRenderer?
    @State private var cameraEntity: Entity?

    // Camera orbit state
    @State private var cameraYaw: Float = 0
    @State private var cameraPitch: Float = 0.6
    @State private var cameraDistance: Float = 12
    @State private var cameraTarget: SIMD3<Float> = .zero
    @State private var lastDrag: CGPoint?

    // Smooth WASD movement
    @State private var keysPressed: Set<String> = []
    private let cameraMoveSpeed: Float = 8.0

    // UI state
    @State private var showRoundOverMessage: Bool = false
    @State private var showingStats: Bool = false
    @State private var selectedTower: Tower?
    @State private var selectedEnemy: Enemy?
    @State private var selectedBonusCell: HexCell?
    @State private var selectedAuraCell: HexCell?
    @State private var selectedDamageAuraCell: HexCell?
    @State private var dialogRefresh: Int = 0
    @State private var viewSize: CGSize = CGSize(width: 800, height: 600)
    @State private var hoveredPlacementCoord: HexCoord? = nil

    var body: some View {
        ZStack(alignment: .top) {
            RealityView { content in
                gameState.generateMap()

                guard let renderer = SceneRenderer() else { return }
                self.renderer = renderer
                renderer.buildScene(from: gameState, into: content)
                cameraEntity = renderer.createCamera(into: content)

                // Create the base tower at the end cell
                if let endCell = gameState.endCell {
                    let pos = endCell.coord.worldPosition(spacing: gameState.spacing)
                    renderer.createBaseTower(cellHeight: endCell.height, position: pos)
                }

                updateCamera()

                // Game loop
                _ = content.subscribe(to: SceneEvents.Update.self) { event in
                    let dt = Float(event.deltaTime)

                    // Smooth camera movement from held keys
                    if !keysPressed.isEmpty {
                        let forward = SIMD3<Float>(-sin(cameraYaw), 0, -cos(cameraYaw))
                        let right = SIMD3<Float>(cos(cameraYaw), 0, -sin(cameraYaw))
                        var move: SIMD3<Float> = .zero
                        if keysPressed.contains("w") { move += forward }
                        if keysPressed.contains("s") { move -= forward }
                        if keysPressed.contains("a") { move -= right }
                        if keysPressed.contains("d") { move += right }
                        if length(move) > 0 {
                            cameraTarget += normalize(move) * cameraMoveSpeed * dt
                            updateCamera()
                        }
                    }

                    // Update turret rotations every frame so dish spin works outside combat
                    for tower in gameState.towers {
                        renderer.updateTurretRotation(tower)
                    }

                    guard gameState.phase == .combat else {
                        if gameState.phase == .roundOver && !showRoundOverMessage {
                            showRoundOverMessage = true
                            if gameState.baseTowerHP <= 0 { showingStats = true }
                        }
                        return
                    }

                    let events = gameState.update(deltaTime: dt)

                    // Spawn new enemy entities
                    for enemy in events.spawnedEnemies {
                        if let pos = gameState.enemyWorldPosition(enemy) {
                            renderer.createEnemy(enemy, radius: gameState.enemyRadius, at: pos)
                        }
                    }

                    // Update enemy positions and shield domes
                    for enemy in events.movedEnemies {
                        if let pos = gameState.enemyWorldPosition(enemy) {
                            renderer.updateEnemyPosition(enemy, position: pos)
                            if enemy.enemyType == .shield && enemy.shieldActive {
                                renderer.updateShieldDome(for: enemy, position: pos, shieldRatio: enemy.shieldHP / enemy.shieldMaxHP)
                            }
                        }
                    }

                    // Remove shield domes for broken shields
                    for enemy in events.shieldsBroken {
                        renderer.removeShieldDome(for: enemy)
                    }

                    // Remove killed enemies
                    for enemy in events.killedEnemies {
                        renderer.removeShieldDome(for: enemy)
                        renderer.removeEnemy(enemy)
                        if selectedEnemy?.id == enemy.id { selectedEnemy = nil }
                    }

                    // Spawn projectile entities
                    for projectile in events.firedProjectiles {
                        renderer.createProjectile(projectile)
                    }

                    // Update all in-flight projectile positions
                    for projectile in gameState.projectiles {
                        renderer.updateProjectilePosition(projectile)
                    }

                    // Remove completed projectiles
                    for projectile in events.completedProjectiles {
                        renderer.removeProjectile(projectile)
                        if projectile.burnOnImpact {
                            renderer.createFireballExplosion(at: projectile.target)
                        }
                    }

                    // Bowling balls
                    for ball in events.firedBalls {
                        renderer.createBowlingBall(ball, at: gameState.ballWorldPosition(ball))
                    }
                    for ball in events.movedBalls {
                        renderer.updateBowlingBallPosition(ball, position: gameState.ballWorldPosition(ball))
                    }
                    for ball in events.removedBalls {
                        renderer.removeBowlingBall(ball)
                    }
                    for pos in events.poppedBalls {
                        renderer.createBallPop(at: pos)
                    }

                    // Create laser beams
                    for tower in events.beamsStarted {
                        let origin = gameState.beamOrigin(for: tower)
                        let endpoint = gameState.beamEndpoint(for: tower)
                        renderer.createBeam(for: tower, origin: origin, endpoint: endpoint)
                    }

                    // Update tracking beams
                    for tower in events.beamsUpdated {
                        let origin = gameState.beamOrigin(for: tower)
                        let endpoint = gameState.beamEndpoint(for: tower)
                        renderer.updateBeam(for: tower, origin: origin, endpoint: endpoint)
                    }

                    // Remove ended beams
                    for tower in events.beamsEnded {
                        renderer.removeBeam(for: tower)
                    }

                    // Create fire cones
                    for tower in events.conesStarted {
                        let origin = gameState.fireOrigin(for: tower)
                        if let target = gameState.fireTargetPosition(for: tower) {
                            renderer.createCone(for: tower, origin: origin, target: target)
                        }
                    }

                    // Update tracking fire cones
                    for tower in events.conesUpdated {
                        let origin = gameState.fireOrigin(for: tower)
                        if let target = gameState.fireTargetPosition(for: tower) {
                            renderer.updateCone(for: tower, origin: origin, target: target)
                        }
                    }

                    // Remove ended fire cones
                    for tower in events.conesEnded {
                        renderer.removeCone(for: tower)
                    }

                    // Sword blades
                    for tower in events.bladesStarted {
                        let positions = gameState.bladePositions(for: tower)
                        if !positions.isEmpty {
                            renderer.createBlades(for: tower, positions: positions)
                        }
                    }
                    for tower in events.bladesUpdated {
                        renderer.updateBlade(for: tower, positions: gameState.bladePositions(for: tower))
                    }
                    for tower in events.bladesEnded {
                        renderer.removeBlade(for: tower)
                    }

                    // Exploder death explosions
                    for pos in events.explosions {
                        renderer.createExplosion(at: pos)
                    }

                    // Remove destroyed towers
                    var needsAuraRefresh = false
                    for tower in events.destroyedTowers {
                        renderer.removeBeam(for: tower)
                        renderer.removeCone(for: tower)
                        renderer.removeTower(id: tower.id)
                        if tower.hasSlowAura { needsAuraRefresh = true }
                        if tower.hasDamageAura { needsAuraRefresh = true }
                        if selectedTower?.id == tower.id {
                            selectedTower = nil
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                            renderer.removeRangeHighlights()
                        }
                    }
                    if needsAuraRefresh {
                        refreshSlowAuraIndicators()
                        refreshDamageAuraIndicators()
                    }

                    // Base tower block explosions
                    for _ in 0..<events.baseTowerBlocksDestroyed {
                        renderer.explodeTopBlock()
                    }

                    if events.roundOver {
                        renderer.removeAllEnemies()
                        renderer.removeAllProjectiles()
                        renderer.removeAllBeams()
                        renderer.removeAllCones()
                        renderer.removeAllBowlingBalls()
                        renderer.removeAllBlades()
                        selectedEnemy = nil
                    }
                }
            }
            .focusable()
            .onKeyPress(keys: [.init("w"), .init("a"), .init("s"), .init("d")], phases: [.down, .repeat]) { press in
                guard cameraEntity != nil else { return .ignored }
                keysPressed.insert(press.characters)
                return .handled
            }
            .onKeyPress(keys: [.init("w"), .init("a"), .init("s"), .init("d")], phases: .up) { press in
                keysPressed.remove(press.characters)
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                gameState.togglePause()
                return gameState.hasPauseControl ? .handled : .ignored
            }
            .gesture(DragGesture()
                .onChanged { value in
                    if let last = lastDrag {
                        let dx = Float(value.location.x - last.x)
                        let dy = Float(value.location.y - last.y)
                        cameraYaw += dx * 0.005
                        cameraPitch = max(0.1, min(1.5, cameraPitch + dy * 0.005))
                        updateCamera()
                    }
                    lastDrag = value.location
                }
                .onEnded { _ in
                    lastDrag = nil
                }
            )
            .gesture(MagnifyGesture()
                .onChanged { value in
                    cameraDistance = max(3, min(30, cameraDistance / Float(value.magnification)))
                    updateCamera()
                }
            )
            .gesture(
                TapGesture()
                    .targetedToAnyEntity()
                    .onEnded { value in
                        handleTap(entity: value.entity)
                    }
            )
            .background(GeometryReader { geo in
                Color.clear.onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { viewSize = $1 }
            })
            .onContinuousHover { phase in
                handlePlacementHover(phase: phase)
            }

            // HUD overlay
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Text("Round \(gameState.round)")
                    Text("$\(gameState.money)")
                    Text("HP: \(gameState.baseTowerHP)/\(gameState.baseTowerMaxHP)")
                        .foregroundColor(gameState.baseTowerHP <= 3 ? .red : .white)
                    if gameState.isPaused {
                        Text("⏸ PAUSED")
                            .foregroundColor(.yellow)
                            .fontWeight(.bold)
                    } else if gameState.hasPauseControl && gameState.phase == .combat {
                        Text("Space to pause")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Divider().frame(height: 14)
                    Button("Stats") { showingStats = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .foregroundColor(.white.opacity(0.8))
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6))
                .cornerRadius(8)

                if gameState.phase == .placing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attack")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.85))
                        HStack(spacing: 6) {
                            Button("None") { gameState.selectedTowerType = nil }
                                .buttonStyle(.bordered)
                                .tint(gameState.selectedTowerType == nil ? .blue : .gray)
                            ForEach([TowerType.projectile, .laser, .fire, .bowler, .sword, .fireball, .antiAir], id: \.self) { type in
                                Button("\(type.displayName) ($\(gameState.costForTower(type)))") {
                                    gameState.selectedTowerType = gameState.selectedTowerType == type ? nil : type
                                }
                                .buttonStyle(.bordered)
                                .tint(gameState.selectedTowerType == type ? .blue : .gray)
                            }
                        }
                        Text("Support")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.85))
                        HStack(spacing: 6) {
                            ForEach([TowerType.ice, .healer, .targeting], id: \.self) { type in
                                Button("\(type.displayName) ($\(gameState.costForTower(type)))") {
                                    gameState.selectedTowerType = gameState.selectedTowerType == type ? nil : type
                                }
                                .buttonStyle(.bordered)
                                .tint(gameState.selectedTowerType == type ? .blue : .gray)
                            }
                        }
                    }

                    Text(gameState.selectedTowerType == nil ? "Click cells to inspect or select a tower to place" : "Tap terrain cells to place towers")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))

                    let anyPending = gameState.pendingRingBonus
                        || gameState.isPendingSlowAura || gameState.isPendingDamageAura
                        || gameState.isSelectingTowerToMove || gameState.pendingMoveTower != nil
                    HStack(spacing: 10) {
                        Text("Inventory:")
                            .font(.caption)
                            .foregroundColor(.white)

                        Button("Ring ×\(gameState.ringItemCount)") { gameState.activateRingItem() }
                            .buttonStyle(.borderedProminent).tint(.green)
                            .disabled(gameState.ringItemCount == 0 || anyPending)

                        Button("Repair ×\(gameState.repairItemCount)") { gameState.useRepairItem() }
                            .buttonStyle(.borderedProminent).tint(.mint)
                            .disabled(gameState.repairItemCount == 0 || gameState.baseTowerHP >= gameState.baseTowerMaxHP)

                        Button("Slow Aura ×\(gameState.slowAuraItemCount)") { gameState.activateSlowAuraItem() }
                            .buttonStyle(.borderedProminent).tint(.cyan)
                            .disabled(gameState.slowAuraItemCount == 0 || anyPending)

                        Button("Dmg Aura ×\(gameState.damageAuraItemCount)") { gameState.activateDamageAuraItem() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(gameState.damageAuraItemCount == 0 || anyPending)

                        Button("Move Tower ×\(gameState.moveTowerItemCount)") { gameState.activateMoveTower() }
                            .buttonStyle(.borderedProminent).tint(.yellow)
                            .disabled(gameState.moveTowerItemCount == 0 || anyPending)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55))
                    .cornerRadius(8)

                    Button("Start Round") {
                        gameState.cancelPendingSlowAura()
                        gameState.cancelPendingDamageAura()
                        gameState.cancelPendingRingBonus()
                        gameState.cancelPendingMoveTower()
                        gameState.startRound()
                        showRoundOverMessage = false
                    }
                    .buttonStyle(.borderedProminent)

                }

                if gameState.phase == .combat {
                    let active = gameState.enemies.filter { $0.active }.count
                    Text("Enemies: \(active)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if showRoundOverMessage {
                    if gameState.baseTowerHP <= 0 {
                        Text("Game Over!")
                            .font(.title)
                            .foregroundColor(.red)

                        Text("Survived \(gameState.round) rounds")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))

                        Button("Restart") {
                            guard let renderer else { return }
                            let result = gameState.restart()
                            for id in result.towerIDs {
                                renderer.removeTower(id: id)
                            }
                            for coord in result.removedTerrainCoords {
                                renderer.removeTerrainCell(at: coord)
                            }
                            for cell in result.seedCells {
                                renderer.addTerrainCell(cell, spacing: gameState.spacing, hexRadius: gameState.hexRadius)
                            }
                            renderer.removeAllEnemies()
                            renderer.removeAllProjectiles()
                            renderer.removeAllBeams()
                            renderer.removeAllCones()
                            renderer.removeAllBowlingBalls()
                            renderer.removeAllBlades()
                            renderer.removeAllBonusIndicators()
                            renderer.removeAllSlowAuraIndicators()
                            if let endCell = gameState.endCell {
                                let pos = endCell.coord.worldPosition(spacing: gameState.spacing)
                                renderer.rebuildBaseTower(cellHeight: endCell.height, position: pos)
                            }
                            showRoundOverMessage = false
                            renderer.removeRangeHighlights()
                            selectedTower = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Text("Round Complete!")
                            .font(.headline)
                            .foregroundColor(.green)

                        Button("Next Round") {
                            let newCells = gameState.returnToPlacing()
                            showRoundOverMessage = false
                            if let renderer {
                                for cell in newCells {
                                    if cell.type == .path || cell.type == .start {
                                        renderer.addPathCell(cell, spacing: gameState.spacing, hexRadius: gameState.hexRadius)
                                    } else {
                                        renderer.addTerrainCell(cell, spacing: gameState.spacing, hexRadius: gameState.hexRadius)
                                    }
                                }
                                // Show indicators for any bonus tiles (including newly assigned ones)
                                for cell in gameState.bonusCells {
                                    let pos = cell.coord.worldPosition(spacing: gameState.spacing)
                                    renderer.showBonusIndicator(for: cell, at: SIMD3(pos.x, cell.height, pos.y))
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.top, 16)

            // Slow aura — pick target path tile
            if gameState.isPendingSlowAura {
                VStack(spacing: 6) {
                    Text("Slow Aura — Pick a Target")
                        .font(.headline).foregroundColor(.cyan)
                    Text("Click any path tile to slow enemies there and the tiles on either side.")
                        .font(.caption).foregroundColor(.white.opacity(0.85)).multilineTextAlignment(.center)
                    Button("Cancel") { gameState.cancelPendingSlowAura(); refreshSlowAuraIndicators() }
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                .padding(12).background(.black.opacity(0.8)).cornerRadius(10)
                .frame(maxWidth: 300).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 60)
            }

            // Damage aura — pick target path tile
            if gameState.isPendingDamageAura {
                VStack(spacing: 6) {
                    Text("Damage Aura — Pick a Target")
                        .font(.headline).foregroundColor(.orange)
                    Text("Click any path tile to boost damage dealt to enemies there and the tiles on either side by 40%.")
                        .font(.caption).foregroundColor(.white.opacity(0.85)).multilineTextAlignment(.center)
                    Button("Cancel") { gameState.cancelPendingDamageAura(); refreshDamageAuraIndicators() }
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                .padding(12).background(.black.opacity(0.8)).cornerRadius(10)
                .frame(maxWidth: 300).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 60)
            }

            // Ring bonus target pick prompt — center top banner
            if gameState.pendingRingBonus {
                VStack(spacing: 6) {
                    Text("Ring Bonus — Pick a Cell")
                        .font(.headline)
                        .foregroundColor(.green)
                    Text("Click any cell to expand a full ring of terrain around it.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("Cancel") { gameState.cancelPendingRingBonus() }
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(12)
                .background(.black.opacity(0.8))
                .cornerRadius(10)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
            }

            // Move tower — select tower prompt
            if gameState.isSelectingTowerToMove {
                VStack(spacing: 6) {
                    Text("Move Tower — Select a Tower")
                        .font(.headline)
                        .foregroundColor(.yellow)
                    Text("Click any placed tower to pick it up.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("Cancel") { gameState.cancelPendingMoveTower() }
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(12)
                .background(.black.opacity(0.8))
                .cornerRadius(10)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
            }

            // Move tower — pick destination prompt
            if let movingTower = gameState.pendingMoveTower {
                VStack(spacing: 6) {
                    Text("Move Tower — Pick a Destination")
                        .font(.headline)
                        .foregroundColor(.yellow)
                    Text("Click a valid terrain cell to place \(movingTower.type) tower.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("Cancel") { gameState.cancelPendingMoveTower() }
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(12)
                .background(.black.opacity(0.8))
                .cornerRadius(10)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
            }

            // Bonus tile dialog — right side
            if let bonusCell = selectedBonusCell, let bonus = bonusCell.bonusType {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bonus Tile!")
                        .font(.headline)
                        .foregroundColor(.yellow)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Divider().background(.white.opacity(0.3))

                    Text(bonus.displayName)
                        .font(.subheadline)
                        .foregroundColor(.yellow)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(bonus.description)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Close") {
                        selectedBonusCell = nil
                        if let renderer {
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(12)
                .background(.black.opacity(0.75))
                .cornerRadius(10)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16)
                .padding(.trailing, 16)
            }

            // Slow aura path cell dialog — right side
            if selectedAuraCell != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Slow Aura")
                        .font(.headline)
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Divider().background(.white.opacity(0.3))

                    Text("Enemies on this tile are slowed to 80% speed by a nearby tower's Slow Aura.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Close") {
                        selectedAuraCell = nil
                        if let renderer {
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(12)
                .background(.black.opacity(0.75))
                .cornerRadius(10)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16)
                .padding(.trailing, 16)
            }

            // Damage aura path cell dialog — right side
            if selectedDamageAuraCell != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Damage Aura")
                        .font(.headline)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Divider().background(.white.opacity(0.3))

                    Text("All damage dealt to enemies on this tile is boosted by 40% by a nearby tower's Damage Aura.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Close") {
                        selectedDamageAuraCell = nil
                        if let renderer {
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(12)
                .background(.black.opacity(0.75))
                .cornerRadius(10)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16)
                .padding(.trailing, 16)
            }

            // Tower info dialog — right side
            if let tower = selectedTower {
                VStack(alignment: .leading, spacing: 6) {

                    Text("\(towerTypeName(tower.type)) Tower  Lv.\(tower.level)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 4) {
                        Text("HP:")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                        ForEach(0..<tower.maxHitPoints, id: \.self) { i in
                            Image(systemName: i < tower.hitPoints ? "heart.fill" : "heart")
                                .font(.caption2)
                                .foregroundColor(i < tower.hitPoints ? .red : .gray)
                        }
                        if tower.isInvulnerable {
                            Image(systemName: "shield.fill")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Divider().background(.white.opacity(0.3))

                    towerStatsView(tower)

                    Divider().background(.white.opacity(0.3))

                    if tower.canUpgrade {
                        Text(tower.upgradeDescription)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button("Upgrade ($\(tower.upgradeCost))") {
                            if gameState.upgradeTower(tower) {
                                dialogRefresh += 1
                                if tower.level == Tower.maxLevel {
                                    renderer?.addMaxLevelDome(for: tower)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(gameState.money < tower.upgradeCost)
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("Max Level")
                            .font(.caption)
                            .foregroundColor(.yellow)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if tower.hitPoints < tower.maxHitPoints {
                        Button("Repair HP ($75)") {
                            if gameState.repairTower(tower) {
                                dialogRefresh += 1
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .disabled(gameState.money < 75)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Divider().background(.white.opacity(0.3))

                    let tLevel = gameState.targetingLevel(for: tower)
                    if tLevel >= 2 {
                        Divider().background(.white.opacity(0.3))

                        if tLevel >= 3 {
                            Text("Priority Target")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .center)

                            Picker("", selection: Binding(
                                get: { tower.priorityEnemyType },
                                set: { tower.priorityEnemyType = $0; dialogRefresh += 1 }
                            )) {
                                Text("None").tag(EnemyType?.none)
                                ForEach(EnemyType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(Optional(type))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .center)

                            Divider().background(.white.opacity(0.3))
                        }

                        Text("Targeting")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)

                        ForEach(TargetingMode.allCases, id: \.self) { mode in
                            Button(action: {
                                tower.targetingMode = mode
                                dialogRefresh += 1
                            }) {
                                HStack {
                                    Text(mode.rawValue)
                                    Spacer()
                                    if tower.targetingMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(tower.targetingMode == mode ? .blue : .gray)
                        }

                        Divider().background(.white.opacity(0.3))
                    }

                    HStack(spacing: 16) {
                        VStack(spacing: 2) {
                            Text("\(tower.totalKills)")
                                .font(.system(.body, design: .monospaced).bold())
                                .foregroundColor(.yellow)
                            Text("Kills")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                        }
                        VStack(spacing: 2) {
                            Text(formatDamage(tower.totalDamageDealt))
                                .font(.system(.body, design: .monospaced).bold())
                                .foregroundColor(.orange)
                            Text("Damage")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Button("Close") {
                        selectedTower = nil
                        selectedBonusCell = nil
                        if let renderer {
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                            renderer.removeRangeHighlights()
                        }
                    }
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(12)
                .background(.black.opacity(0.75))
                .cornerRadius(10)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16)
                .padding(.trailing, 16)
            }

            // Enemy info panel — top left
            if let enemy = selectedEnemy, enemy.active {
                enemyInfoPanel(enemy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 16)
                    .padding(.leading, 16)
            }
        }
        .onChange(of: gameState.selectedTowerType) { _, _ in
            if let renderer {
                renderer.removeGhostTower()
                renderer.removeRangeHighlights()
            }
            hoveredPlacementCoord = nil
        }
        .onChange(of: gameState.phase) { _, phase in
            if phase != .placing, let renderer {
                renderer.removeGhostTower()
                renderer.removeRangeHighlights()
                hoveredPlacementCoord = nil
            }
        }
        .sheet(isPresented: $showingStats) {
            StatsView(gameState: gameState)
        }
    }

    // MARK: - Placement Preview Hover

    private func handlePlacementHover(phase: HoverPhase) {
        guard let renderer else { return }
        guard gameState.phase == .placing, let towerType = gameState.selectedTowerType else {
            if hoveredPlacementCoord != nil {
                hoveredPlacementCoord = nil
                renderer.removeGhostTower()
                renderer.removeRangeHighlights()
            }
            return
        }

        switch phase {
        case .active(let point):
            guard let coord = hexCoordFromScreenPoint(point) else {
                if hoveredPlacementCoord != nil {
                    hoveredPlacementCoord = nil
                    renderer.removeGhostTower()
                    renderer.removeRangeHighlights()
                }
                return
            }
            // Only update when entering a new cell
            guard coord != hoveredPlacementCoord else { return }

            guard gameState.isValidPlacement(at: coord) else {
                if hoveredPlacementCoord != nil {
                    hoveredPlacementCoord = nil
                    renderer.removeGhostTower()
                    renderer.removeRangeHighlights()
                }
                return
            }

            hoveredPlacementCoord = coord
            let cell = gameState.hexGrid.cell(at: coord)
            renderer.showGhostTower(type: towerType, at: coord, cellHeight: cell?.height ?? 1.0, spacing: gameState.spacing)
            let rangeCells = gameState.allCellsInFireRange(from: coord, type: towerType)
            renderer.showRangeHighlights(coords: rangeCells.map { $0.coord })

        case .ended:
            hoveredPlacementCoord = nil
            renderer.removeGhostTower()
            renderer.removeRangeHighlights()
        @unknown default:
            break
        }
    }

    /// Projects a view-space screen point to the nearest hex coord via ray-plane intersection.
    private func hexCoordFromScreenPoint(_ point: CGPoint) -> HexCoord? {
        // Camera world position (matches updateCamera math)
        let camX = cameraTarget.x + cameraDistance * cos(cameraPitch) * sin(cameraYaw)
        let camY = cameraTarget.y + cameraDistance * sin(cameraPitch)
        let camZ = cameraTarget.z + cameraDistance * cos(cameraPitch) * cos(cameraYaw)
        let camPos = SIMD3<Float>(camX, camY, camZ)

        // Camera basis vectors
        let forward = normalize(cameraTarget - camPos)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = cross(right, forward)

        // NDC coords (-1..1)
        let ndcX =  Float(point.x / viewSize.width)  * 2 - 1
        let ndcY = -Float(point.y / viewSize.height) * 2 + 1  // flip Y

        // Perspective ray (default RealityKit vertical FOV ≈ 60°)
        let tanHalf = tan(Float(60) * .pi / 360)  // tan(30°)
        let aspect  = Float(viewSize.width / viewSize.height)
        let rayDir  = normalize(forward + right * (ndcX * tanHalf * aspect) + up * (ndcY * tanHalf))

        // Intersect with approximate terrain plane (y ≈ 1.0)
        let planeY: Float = 1.0
        guard abs(rayDir.y) > 1e-4 else { return nil }
        let t = (planeY - camPos.y) / rayDir.y
        guard t > 0 else { return nil }

        let worldX = camPos.x + rayDir.x * t
        let worldZ = camPos.z + rayDir.z * t

        // Inverse of HexCoord.worldPosition(spacing:)
        let s = gameState.spacing
        let qF = worldX / (s * 1.5)
        let rF = worldZ / (s * Float(3).squareRoot()) - qF / 2
        return roundedHexCoord(qF: qF, rF: rF)
    }

    /// Rounds fractional axial coordinates to the nearest HexCoord.
    private func roundedHexCoord(qF: Float, rF: Float) -> HexCoord {
        let sF = -qF - rF
        var q = Int(qF.rounded()); var r = Int(rF.rounded()); var s = Int(sF.rounded())
        let dq = abs(Float(q) - qF); let dr = abs(Float(r) - rF); let ds = abs(Float(s) - sF)
        if dq > dr && dq > ds { q = -r - s }
        else if dr > ds        { r = -q - s }
        else                   { s = -q - r }  // s unused but keeps cube coords consistent
        _ = s
        return HexCoord(q: q, r: r)
    }

    private func updateCamera() {
        guard let camera = cameraEntity else { return }
        let x = cameraTarget.x + cameraDistance * cos(cameraPitch) * sin(cameraYaw)
        let y = cameraTarget.y + cameraDistance * sin(cameraPitch)
        let z = cameraTarget.z + cameraDistance * cos(cameraPitch) * cos(cameraYaw)
        camera.look(at: cameraTarget, from: [x, y, z], relativeTo: nil)
    }

    @ViewBuilder
    private func towerStatsView(_ tower: Tower) -> some View {
        let statFont = Font.system(.caption, design: .monospaced)
        let labelColor = Color.white.opacity(0.6)
        let valueColor = Color.white

        VStack(alignment: .leading, spacing: 6) {
            // Type-specific stats
            switch tower.type {
            case .projectile:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Damage", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .laser:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("DPS", "\(String(format: "%.0f", tower.laser?.dps ?? 0))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Duration", "\(String(format: "%.1f", tower.laser?.duration ?? 0))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .fire:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("DPS", "\(String(format: "%.0f", tower.cone?.dps ?? 0))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Duration", "\(String(format: "%.1f", tower.cone?.duration ?? 0))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .ice:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Slow", "50%", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Duration", "\(String(format: "%.1f", tower.cone?.duration ?? 0))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .bowler:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Damage", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .sword:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Damage", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .healer:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Charges", "\(tower.healer?.charges ?? 0)/\(tower.level)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Heal Radius", "\(tower.healer?.radius ?? 0)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .fireball:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Dmg", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Burn DPS", "\(String(format: "%.0f", tower.fireball?.burnDPS ?? 0))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Burn Dur", "\(String(format: "%.1f", tower.fireball?.burnDuration ?? 0))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .antiAir:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Dmg", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                        statRow("Target", "Air only", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    }
                }
            case .targeting:
                VStack(alignment: .leading, spacing: 4) {
                    statRow("Aura Radius", "\(tower.detectionRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    Text("Active Effects:")
                        .font(statFont)
                        .foregroundColor(labelColor)
                    let effects: [(String, Bool)] = [
                        ("+1 Detection Range", tower.level >= 1),
                        ("Targeting Mode", tower.level >= 2),
                        ("Priority Target", tower.level >= 3),
                        ("Skip Immune", tower.level >= 4),
                    ]
                    ForEach(effects, id: \.0) { label, active in
                        HStack(spacing: 4) {
                            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(active ? .green : .gray)
                                .font(statFont)
                            Text(label)
                                .font(statFont)
                                .foregroundColor(active ? valueColor : .gray)
                        }
                    }
                }
            }

            // Fire range and detection range shown for all non-targeting towers
            if tower.type != .targeting {
                let tLevel = gameState.targetingLevel(for: tower)
                let effectiveDetection = tower.detectionRadius + (tLevel >= 1 ? 1 : 0)
                Divider().background(.white.opacity(0.2))
                HStack(spacing: 12) {
                    statRow("Fire Range", "\(tower.fireRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Detect Range", effectiveDetection > tower.detectionRadius
                            ? "\(tower.detectionRadius)+1" : "\(tower.detectionRadius)",
                            label: statFont, labelColor: labelColor,
                            valueColor: effectiveDetection > tower.detectionRadius ? .green : valueColor)
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String, label font: Font, labelColor: Color, valueColor: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(font)
                .foregroundColor(labelColor)
            Text(value)
                .font(font)
                .foregroundColor(valueColor)
        }
    }

    private func formatDamage(_ damage: Float) -> String {
        if damage >= 1_000_000 {
            return String(format: "%.1fM", damage / 1_000_000)
        } else if damage >= 1_000 {
            return String(format: "%.1fk", damage / 1_000)
        } else {
            return String(format: "%.0f", damage)
        }
    }

    @ViewBuilder
    private func enemyInfoPanel(_ enemy: Enemy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(enemy.enemyType.displayName)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // HP bar
            let hpRatio = max(0, enemy.hitPoints / enemy.maxHitPoints)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("HP")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(enemy.hitPoints)) / \(Int(enemy.maxHitPoints))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.15))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(hpRatio > 0.5 ? Color.green : hpRatio > 0.25 ? .yellow : .red)
                            .frame(width: geo.size.width * CGFloat(hpRatio), height: 6)
                    }
                }
                .frame(height: 6)
            }

            Divider().background(.white.opacity(0.3))

            // Speed + status
            HStack(spacing: 12) {
                Label(String(format: "%.1f spd", enemy.speed), systemImage: "hare")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                if enemy.burning {
                    Label(String(format: "%.0fs", enemy.burnTimer), systemImage: "flame.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if enemy.slowed {
                    Label(String(format: "%.0fs", enemy.slowTimer), systemImage: "snowflake")
                        .font(.caption)
                        .foregroundColor(.cyan)
                }
            }

            // Immunities
            let immunities = enemy.immuneTowerTypes
            if !immunities.isEmpty {
                Divider().background(.white.opacity(0.3))
                HStack(spacing: 4) {
                    Text("Immune:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                    Text(immunities.map { towerTypeName($0) }.sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.85))
                }
            }

            Button("Close") { selectedEnemy = nil }
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .background(.black.opacity(0.75))
        .cornerRadius(10)
        .fixedSize()
    }

    private func towerTypeName(_ type: TowerType) -> String { type.displayName }

    private func refreshSlowAuraIndicators() {
        guard let renderer else { return }
        renderer.removeAllSlowAuraIndicators()
        for coord in gameState.slowAuraPathCoords {
            guard let cell = gameState.hexGrid.cell(at: coord) else { continue }
            renderer.showSlowAuraIndicator(at: coord, height: cell.height, spacing: gameState.spacing)
        }
    }

    private func refreshDamageAuraIndicators() {
        guard let renderer else { return }
        renderer.removeAllDamageAuraIndicators()
        for coord in gameState.damageAuraPathCoords {
            guard let cell = gameState.hexGrid.cell(at: coord) else { continue }
            renderer.showDamageAuraIndicator(at: coord, height: cell.height, spacing: gameState.spacing)
        }
    }

    private func handleTap(entity: Entity) {
        guard let renderer else { return }

        // Check if tapping an enemy — show its stats panel
        if let id = renderer.enemyID(for: entity),
           let enemy = gameState.enemies.first(where: { $0.id == id && $0.active }) {
            selectedEnemy = enemy
            return
        }

        guard let coord = renderer.coord(for: entity) else { return }

        // Ring bonus: next tap on any existing cell expands terrain around it
        if gameState.pendingRingBonus {
            if gameState.hexGrid.cell(at: coord) != nil {
                let newCells = gameState.applyRingBonus(at: coord)
                for cell in newCells {
                    renderer.addTerrainCell(cell, spacing: gameState.spacing, hexRadius: gameState.hexRadius)
                    if cell.isBonus {
                        let pos = cell.coord.worldPosition(spacing: gameState.spacing)
                        renderer.showBonusIndicator(for: cell, at: SIMD3(pos.x, cell.height, pos.y))
                    }
                }
                let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                renderer.updateSelection(deselected: deselected, selected: nil)
            }
            // Non-existent cell: ignore, stay in ring mode
            return
        }

        // Move tower — step 1: pick which tower to move
        if gameState.isSelectingTowerToMove {
            if let tower = gameState.tower(at: coord) {
                gameState.selectTowerToMove(tower)
                let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                renderer.updateSelection(deselected: deselected, selected: nil)
            }
            return
        }

        // Move tower — step 2: pick destination
        if let movingTower = gameState.pendingMoveTower {
            if gameState.applyMoveTower(to: coord) {
                if let cell = gameState.hexGrid.cell(at: coord) {
                    renderer.moveTowerEntity(id: movingTower.id, to: coord,
                                            cellHeight: cell.height, spacing: gameState.spacing)
                }
                let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                renderer.updateSelection(deselected: deselected, selected: nil)
            }
            return
        }

        // Slow aura — pick target path tile
        if gameState.isPendingSlowAura {
            let cell = gameState.hexGrid.cell(at: coord)
            if cell?.type == .path || cell?.type == .start {
                gameState.applySlowAuraTarget(pathCoord: coord)
                refreshSlowAuraIndicators()
                let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                renderer.updateSelection(deselected: deselected, selected: nil)
            }
            return
        }

        // Damage aura — pick target path tile
        if gameState.isPendingDamageAura {
            let cell = gameState.hexGrid.cell(at: coord)
            if cell?.type == .path || cell?.type == .start {
                gameState.applyDamageAuraTarget(pathCoord: coord)
                refreshDamageAuraIndicators()
                let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                renderer.updateSelection(deselected: deselected, selected: nil)
            }
            return
        }

        // Check if tapping an existing tower
        if let tower = gameState.tower(at: coord) {
            selectedTower = tower
            selectedBonusCell = nil
            let (deselected, selected) = gameState.selectCell(at: tower.coord)
            renderer.updateSelection(deselected: deselected, selected: selected)
            let rangeCells = gameState.allCellsInFireRange(from: tower.coord, type: tower.type)
            renderer.showRangeHighlights(coords: rangeCells.map { $0.coord })
            return
        }

        // Dismiss any open dialogs
        if selectedTower != nil || selectedBonusCell != nil || selectedAuraCell != nil || selectedDamageAuraCell != nil || selectedEnemy != nil {
            if selectedTower != nil { renderer.removeRangeHighlights() }
            selectedTower = nil
            selectedBonusCell = nil
            selectedAuraCell = nil
            selectedDamageAuraCell = nil
            selectedEnemy = nil
            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
            renderer.updateSelection(deselected: deselected, selected: nil)
        }

        if gameState.phase == .placing {
            // Try to place a tower
            if let (tower, newTerrain) = gameState.placeTower(at: coord) {
                let cell = gameState.hexGrid.cell(at: coord)
                renderer.createTower(tower, cellHeight: cell?.height ?? 1.0, spacing: gameState.spacing)
                renderer.removeBonusIndicator(for: coord)
                selectedBonusCell = nil
                // Add terrain tiles that expanded around the placed tower
                for terrainCell in newTerrain {
                    renderer.addTerrainCell(terrainCell, spacing: gameState.spacing, hexRadius: gameState.hexRadius)
                    if terrainCell.isBonus {
                        let pos = terrainCell.coord.worldPosition(spacing: gameState.spacing)
                        renderer.showBonusIndicator(for: terrainCell, at: SIMD3(pos.x, terrainCell.height, pos.y))
                    }
                }
                // If tower got a free upgrade to max, add the dome
                if tower.level == Tower.maxLevel {
                    renderer.addMaxLevelDome(for: tower)
                }
                hoveredPlacementCoord = nil
                renderer.removeGhostTower()
                renderer.removeRangeHighlights()
                // Don't refresh aura indicators yet — user must pick a target path tile first
                return
            }
        }

        // Check if tapping a bonus tile — show the bonus dialog
        if let cell = gameState.hexGrid.cell(at: coord), cell.isBonus {
            selectedBonusCell = cell
            let (deselected, selected) = gameState.selectCell(at: coord)
            renderer.updateSelection(deselected: deselected, selected: selected)
            return
        }

        // Check if tapping a slowed path tile — show the aura info dialog
        if let cell = gameState.hexGrid.cell(at: coord),
           (cell.type == .path || cell.type == .start),
           gameState.slowAuraPathCoords.contains(coord) {
            selectedAuraCell = cell
            let (deselected, selected) = gameState.selectCell(at: coord)
            renderer.updateSelection(deselected: deselected, selected: selected)
            return
        }

        // Check if tapping a damage aura path tile — show the aura info dialog
        if let cell = gameState.hexGrid.cell(at: coord),
           (cell.type == .path || cell.type == .start),
           gameState.damageAuraPathCoords.contains(coord) {
            selectedDamageAuraCell = cell
            let (deselected, selected) = gameState.selectCell(at: coord)
            renderer.updateSelection(deselected: deselected, selected: selected)
            return
        }

        let (deselected, selected) = gameState.selectCell(at: coord)
        renderer.updateSelection(deselected: deselected, selected: selected)
    }
}

// MARK: - Stats View

struct StatsView: View {
    let gameState: GameState
    @Environment(\.dismiss) private var dismiss

    private let enemyTypes = EnemyType.allCases

    // Column widths
    private let typeW: CGFloat  = 96
    private let numW: CGFloat   = 64
    private let enemyW: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Tower Statistics")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    headerRow
                    Divider()
                    ForEach(gameState.allTowerStats) { stat in
                        dataRow(stat)
                        Divider().opacity(0.25)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 900, minHeight: 280)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            hCell("Tower",    width: typeW)
            hCell("Built",    width: numW)
            hCell("Kills",    width: numW)
            hCell("Avg K",    width: numW)
            hCell("Damage",   width: numW)
            hCell("Avg Dmg",  width: numW)
            ForEach(enemyTypes, id: \.self) { hCell(abbrev($0), width: enemyW) }
        }
        .background(Color.primary.opacity(0.07))
    }

    private func dataRow(_ stat: GameState.TowerTypeStats) -> some View {
        HStack(spacing: 0) {
            dCell(stat.typeName,                              width: typeW, align: .leading, color: .primary)
            dCell("\(stat.built)",                           width: numW)
            dCell("\(stat.kills)",                           width: numW, color: stat.kills > 0 ? .yellow : .secondary)
            dCell(fmtAvg(stat.avgKills),                     width: numW)
            dCell(fmtDmg(stat.damage),                       width: numW, color: stat.damage > 0 ? .orange : .secondary)
            dCell(fmtDmg(stat.avgDamage),                    width: numW)
            ForEach(enemyTypes, id: \.self) { enemyType in
                let n = stat.killsByEnemy[enemyType, default: 0]
                dCell(n > 0 ? "\(n)" : "·", width: enemyW, color: n > 0 ? .primary : .secondary)
            }
        }
    }

    private func hCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .frame(width: width, alignment: .center)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
    }

    private func dCell(_ text: String, width: CGFloat,
                       align: Alignment = .center,
                       color: Color = .primary) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(color)
            .frame(width: width, alignment: align)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
    }

    private func abbrev(_ type: EnemyType) -> String {
        switch type {
        case .basic:        return "Basic"
        case .tank:         return "Tank"
        case .fastTank:     return "F.Tank"
        case .boss:         return "Boss"
        case .exploder:     return "Expl."
        case .superExploder:return "S.Expl"
        case .shield:       return "Shield"
        case .hopper:       return "Hopper"
        case .superHopper:  return "S.Hop"
        case .hive:         return "Hive"
        case .mirroid:      return "Mirroid"
        case .wisp:         return "Wisp"
        }
    }

    private func fmtDmg(_ v: Float) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fk", v / 1_000) }
        return v > 0 ? String(format: "%.0f", v) : "·"
    }

    private func fmtAvg(_ v: Float) -> String {
        v > 0 ? String(format: "%.1f", v) : "·"
    }
}

#Preview {
    ContentView()
}
