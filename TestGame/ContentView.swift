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
    @State private var selectedTower: Tower?
    @State private var selectedBonusCell: HexCell?
    @State private var dialogRefresh: Int = 0

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

                    guard gameState.phase == .combat else {
                        if gameState.phase == .roundOver && !showRoundOverMessage {
                            showRoundOverMessage = true
                        }
                        return
                    }

                    let events = gameState.update(deltaTime: dt)

                    // Update turret rotations
                    for tower in gameState.towers {
                        renderer.updateTurretRotation(tower)
                    }

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

                    // Refresh dialog if selected tower took damage or was healed
                    if let selected = selectedTower,
                       events.damagedTowers.contains(where: { $0.id == selected.id }) ||
                       events.healedTowers.contains(where: { $0.id == selected.id }) {
                        dialogRefresh += 1
                    }
                    // Also refresh if selected tower is a healer that used a charge
                    if let selected = selectedTower, selected.type == .healer,
                       !events.healedTowers.isEmpty {
                        dialogRefresh += 1
                    }

                    // Remove destroyed towers
                    for tower in events.destroyedTowers {
                        renderer.removeBeam(for: tower)
                        renderer.removeCone(for: tower)
                        renderer.removeTower(id: tower.id)
                        if selectedTower?.id == tower.id {
                            selectedTower = nil
                            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
                            renderer.updateSelection(deselected: deselected, selected: nil)
                        }
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

            // HUD overlay
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Text("Round \(gameState.round)")
                    Text("$\(gameState.money)")
                    Text("HP: \(gameState.baseTowerHP)/\(gameState.baseTowerMaxHP)")
                        .foregroundColor(gameState.baseTowerHP <= 3 ? .red : .white)
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6))
                .cornerRadius(8)

                if gameState.phase == .placing {
                    Picker("Tower", selection: $gameState.selectedTowerType) {
                        Text("None").tag(TowerType?.none)
                        Text("Projectile ($\(gameState.costForTower(.projectile)))").tag(TowerType?.some(.projectile))
                        Text("Laser ($\(gameState.costForTower(.laser)))").tag(TowerType?.some(.laser))
                        Text("Fire ($\(gameState.costForTower(.fire)))").tag(TowerType?.some(.fire))
                        Text("Ice ($\(gameState.costForTower(.ice)))").tag(TowerType?.some(.ice))
                        Text("Bowler ($\(gameState.costForTower(.bowler)))").tag(TowerType?.some(.bowler))
                        Text("Sword ($\(gameState.costForTower(.sword)))").tag(TowerType?.some(.sword))
                        Text("Healer ($\(gameState.costForTower(.healer)))").tag(TowerType?.some(.healer))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 560)

                    Text(gameState.selectedTowerType == nil ? "Click cells to inspect or select a tower to place" : "Tap terrain cells to place towers")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))

                    Button("Start Round") {
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
                            let removedIDs = gameState.restart()
                            for id in removedIDs {
                                renderer.removeTower(id: id)
                            }
                            renderer.removeAllEnemies()
                            renderer.removeAllProjectiles()
                            renderer.removeAllBeams()
                            renderer.removeAllCones()
                            renderer.removeAllBowlingBalls()
                            renderer.removeAllBlades()
                            renderer.removeAllBonusIndicators()
                            if let endCell = gameState.endCell {
                                let pos = endCell.coord.worldPosition(spacing: gameState.spacing)
                                renderer.rebuildBaseTower(cellHeight: endCell.height, position: pos)
                            }
                            showRoundOverMessage = false
                            selectedTower = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Text("Round Complete!")
                            .font(.headline)
                            .foregroundColor(.green)

                        Button("Next Round") {
                            gameState.returnToPlacing()
                            showRoundOverMessage = false
                            // Show indicators for any bonus tiles (including newly assigned ones)
                            if let renderer {
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

            // Tower info dialog — right side
            if let tower = selectedTower {
                VStack(alignment: .leading, spacing: 6) {
                    let _ = dialogRefresh  // trigger re-render

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

                    Button("Close") {
                        selectedTower = nil
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
        }
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

        switch tower.type {
        case .projectile:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Damage", "\(String(format: "%.0f", tower.damage))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Range", "\(tower.fireRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Detect", "\(tower.detectionRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
            }
        case .laser:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statRow("DPS", "\(String(format: "%.0f", tower.beamDamagePerSecond))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Duration", "\(String(format: "%.1f", tower.beamDuration))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Range", "\(tower.beamRange)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
            }
        case .fire:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statRow("DPS", "\(String(format: "%.0f", tower.fireDamagePerSecond))", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Duration", "\(String(format: "%.1f", tower.fireDuration))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Detect", "\(tower.detectionRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
            }
        case .ice:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Slow", "50%", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Duration", "\(String(format: "%.1f", tower.fireDuration))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Detect", "\(tower.detectionRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
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
                    statRow("Charges", "\(tower.healCharges)/\(tower.level)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                    statRow("Radius", "\(tower.healRadius)", label: statFont, labelColor: labelColor, valueColor: valueColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Cooldown", "\(String(format: "%.1f", tower.cooldown))s", label: statFont, labelColor: labelColor, valueColor: valueColor)
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

    private func towerTypeName(_ type: TowerType) -> String {
        switch type {
        case .projectile: return "Projectile"
        case .laser: return "Laser"
        case .fire: return "Fire"
        case .ice: return "Ice"
        case .bowler: return "Bowler"
        case .sword: return "Sword"
        case .healer: return "Healer"
        }
    }

    private func handleTap(entity: Entity) {
        guard let renderer, let coord = renderer.coord(for: entity) else { return }

        // Check if tapping an existing tower
        if let tower = gameState.tower(at: coord) {
            selectedTower = tower
            selectedBonusCell = nil
            let (deselected, selected) = gameState.selectCell(at: tower.coord)
            renderer.updateSelection(deselected: deselected, selected: selected)
            return
        }

        // Dismiss any open dialogs
        if selectedTower != nil || selectedBonusCell != nil {
            selectedTower = nil
            selectedBonusCell = nil
            let (deselected, _) = gameState.selectCell(at: HexCoord(q: Int.max, r: Int.max))
            renderer.updateSelection(deselected: deselected, selected: nil)
        }

        if gameState.phase == .placing {
            // Try to place a tower
            if let tower = gameState.placeTower(at: coord) {
                let cell = gameState.hexGrid.cell(at: coord)
                renderer.createTower(tower, cellHeight: cell?.height ?? 1.0, spacing: gameState.spacing)
                renderer.removeBonusIndicator(for: coord)
                selectedBonusCell = nil
                // If tower got a free upgrade to max, add the dome
                if tower.level == Tower.maxLevel {
                    renderer.addMaxLevelDome(for: tower)
                }
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

        let (deselected, selected) = gameState.selectCell(at: coord)
        renderer.updateSelection(deselected: deselected, selected: selected)
    }
}

#Preview {
    ContentView()
}
