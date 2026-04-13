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

    var body: some View {
        ZStack(alignment: .top) {
            RealityView { content in
                gameState.generateMap()

                guard let renderer = SceneRenderer() else { return }
                self.renderer = renderer
                renderer.buildScene(from: gameState, into: content)
                cameraEntity = renderer.createCamera(into: content)
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

                    // Update enemy positions
                    for enemy in events.movedEnemies {
                        if let pos = gameState.enemyWorldPosition(enemy) {
                            renderer.updateEnemyPosition(enemy, position: pos)
                        }
                    }

                    // Remove killed enemies
                    for enemy in events.killedEnemies {
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

                    // Remove ended fire cones
                    for tower in events.conesEnded {
                        renderer.removeCone(for: tower)
                    }

                    if events.roundOver {
                        renderer.removeAllEnemies()
                        renderer.removeAllProjectiles()
                        renderer.removeAllBeams()
                        renderer.removeAllCones()
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
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6))
                .cornerRadius(8)

                if gameState.phase == .placing {
                    Picker("Tower", selection: $gameState.selectedTowerType) {
                        Text("Projectile ($\(gameState.costForTower(.projectile)))").tag(TowerType.projectile)
                        Text("Laser ($\(gameState.costForTower(.laser)))").tag(TowerType.laser)
                        Text("Fire ($\(gameState.costForTower(.fire)))").tag(TowerType.fire)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 400)

                    Text("Tap terrain cells to place towers")
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
                    Text("Round Complete!")
                        .font(.headline)
                        .foregroundColor(.green)

                    Button("Next Round") {
                        gameState.returnToPlacing()
                        showRoundOverMessage = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 16)
        }
    }

    private func updateCamera() {
        guard let camera = cameraEntity else { return }
        let x = cameraTarget.x + cameraDistance * cos(cameraPitch) * sin(cameraYaw)
        let y = cameraTarget.y + cameraDistance * sin(cameraPitch)
        let z = cameraTarget.z + cameraDistance * cos(cameraPitch) * cos(cameraYaw)
        camera.look(at: cameraTarget, from: [x, y, z], relativeTo: nil)
    }

    private func handleTap(entity: Entity) {
        guard let renderer, let coord = renderer.coord(for: entity) else { return }

        if gameState.phase == .placing {
            // Try to place a tower
            if let tower = gameState.placeTower(at: coord) {
                let cell = gameState.hexGrid.cell(at: coord)
                renderer.createTower(tower, cellHeight: cell?.height ?? 1.0, spacing: gameState.spacing)
                return
            }
        }

        let (deselected, selected) = gameState.selectCell(at: coord)
        renderer.updateSelection(deselected: deselected, selected: selected)
    }
}

#Preview {
    ContentView()
}
