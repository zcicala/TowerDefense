//
//  SceneRenderer.swift
//  TestGame
//

import SwiftUI
import RealityKit
import Metal

/// Handles creating and updating RealityKit entities from game state.
@MainActor
class SceneRenderer {
    private let surfaceShader: CustomMaterial.SurfaceShader
    private var entityMap: [HexCoord: Entity] = [:]
    private var content: (any RealityViewContentProtocol)?

    init?() {
        guard let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return nil }
        surfaceShader = CustomMaterial.SurfaceShader(named: "celSurfaceShader", in: library)
    }

    /// Builds all entities for the current game state and adds them to the scene.
    func buildScene(from gameState: GameState, into content: any RealityViewContentProtocol) {
        self.content = content
        let hexRadius = gameState.hexRadius
        let spacing = gameState.spacing

        for cell in gameState.hexGrid.cells.values {
            let isPath = cell.type == .path || cell.type == .start || cell.type == .end
            let mesh = HexMeshGenerator.generate(radius: hexRadius, height: cell.height, cornerRadius: 0.08)

            let t = max(0, min(1, cell.height))
            var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
            let tint: SimpleMaterial.Color
            switch cell.type {
            case .start:
                tint = SimpleMaterial.Color(red: 0.2, green: 0.6, blue: 0.25, alpha: 1)
            case .end:
                tint = SimpleMaterial.Color(red: 0.7, green: 0.2, blue: 0.2, alpha: 1)
            default:
                tint = colorForHeight(t, isPath: cell.type == .path)
            }
            material.baseColor = CustomMaterial.BaseColor(tint: tint)

            let pos = cell.coord.worldPosition(spacing: spacing)
            let entity = Entity()
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.components.set(CollisionComponent(shapes: [.generateBox(size: [hexRadius * 2, cell.height, hexRadius * 2])]))
            entity.components.set(InputTargetComponent())
            entity.position = [pos.x, cell.height / 2, pos.y]
            content.add(entity)

            entityMap[cell.coord] = entity
        }
    }

    /// Creates and returns a camera entity.
    func createCamera(into content: any RealityViewContentProtocol) -> Entity {
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent())
        content.add(camera)
        return camera
    }

    // MARK: - Selection Visuals

    func updateSelection(deselected: [HexCell], selected: HexCell?) {
        for cell in deselected {
            guard let entity = entityMap[cell.coord] else { continue }
            if var material = entity.components[ModelComponent.self]?.materials.first as? CustomMaterial {
                material.custom.value[0] = 0
                entity.components[ModelComponent.self]?.materials = [material]
            }
        }

        if let cell = selected, let entity = entityMap[cell.coord] {
            if var material = entity.components[ModelComponent.self]?.materials.first as? CustomMaterial {
                material.custom.value[0] = 1
                entity.components[ModelComponent.self]?.materials = [material]
            }
        }
    }

    /// Looks up the HexCoord for a tapped entity.
    func coord(for entity: Entity) -> HexCoord? {
        entityMap.first { $0.value === entity }?.key
    }

    // MARK: - Towers

    private var towerEntities: [UUID: Entity] = [:]
    private var turretEntities: [UUID: Entity] = [:]

    func createTower(_ tower: Tower, cellHeight: Float, spacing: Float) {
        guard let content else { return }

        let pos = tower.coord.worldPosition(spacing: spacing)
        let root = Entity()
        root.position = [pos.x, cellHeight, pos.y]

        // Tower material — different tint for laser vs projectile
        var stoneMaterial = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        let tint: SimpleMaterial.Color
        switch tower.type {
        case .laser: tint = .init(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        case .fire:  tint = .init(red: 0.6, green: 0.35, blue: 0.2, alpha: 1)
        case .projectile: tint = .init(red: 0.5, green: 0.5, blue: 0.6, alpha: 1)
        }
        stoneMaterial.baseColor = CustomMaterial.BaseColor(tint: tint)

        // Stack of 5 rectangular prisms with rounded edges
        let prismWidth: Float = 0.25
        let prismHeight: Float = 0.3
        let prismGap: Float = 0.02
        let cornerRadius: Float = 0.04

        var currentY: Float = 0
        for i in 0..<2 {
            let scale = pow(0.9, Float(i))
            let w = prismWidth * scale
            let h = prismHeight * scale
            let cr = cornerRadius * scale
            let mesh = MeshResource.generateBox(width: w, height: h, depth: w, cornerRadius: cr)
            let prism = Entity()
            prism.components.set(ModelComponent(mesh: mesh, materials: [stoneMaterial]))
            prism.position.y = currentY + h / 2
            root.addChild(prism)
            currentY += h + prismGap
        }

        let stackTop = currentY - prismGap

        // Turret group (rotates as a unit)
        let turretGroup = Entity()
        turretGroup.position.y = stackTop + 0.05
        root.addChild(turretGroup)

        // Turret: height 0.1, radius 0.15, approximated with high-segment box for rounded edges
        var turretMaterial = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        let turretTint: SimpleMaterial.Color
        switch tower.type {
        case .laser: turretTint = .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        case .fire:  turretTint = .init(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        case .projectile: turretTint = .init(red: 0.7, green: 0.3, blue: 0.2, alpha: 1)
        }
        turretMaterial.baseColor = CustomMaterial.BaseColor(tint: turretTint)

        let turretMesh = MeshResource.generateBox(width: 0.3, height: 0.1, depth: 0.3, cornerRadius: 0.05)
        let turret = Entity()
        turret.components.set(ModelComponent(mesh: turretMesh, materials: [turretMaterial]))
        turretGroup.addChild(turret)

        // Barrel: short black cylinder protruding from one side
        var barrelMaterial = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        barrelMaterial.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))

        let barrelMesh = MeshResource.generateCylinder(height: 0.2, radius: 0.06)
        let barrel = Entity()
        barrel.components.set(ModelComponent(mesh: barrelMesh, materials: [barrelMaterial]))
        barrel.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        barrel.position = [0, 0, -0.25]
        turretGroup.addChild(barrel)

        content.add(root)
        towerEntities[tower.id] = root
        turretEntities[tower.id] = turretGroup
    }

    func updateTurretRotation(_ tower: Tower) {
        guard let turretGroup = turretEntities[tower.id] else { return }
        turretGroup.orientation = simd_quatf(angle: tower.currentYaw, axis: [0, 1, 0])
    }

    // MARK: - Laser Beams

    private var beamEntities: [UUID: Entity] = [:]
    private var beamParticleEntities: [UUID: Entity] = [:]

    func createBeam(for tower: Tower, origin: SIMD3<Float>, endpoint: SIMD3<Float>) {
        guard let content else { return }

        let diff = endpoint - origin
        let beamLength = simd_length(diff)
        let midpoint = origin + diff * 0.5

        // Thin red cylinder stretched along the beam
        let mesh = MeshResource.generateBox(width: 0.03, height: 0.03, depth: beamLength)
        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 0.1, blue: 0.1, alpha: 1))

        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = midpoint
        let direction = normalize(diff)
        entity.orientation = simd_quatf(from: [0, 0, 1], to: direction)

        content.add(entity)
        beamEntities[tower.id] = entity

        // Glow particles along the beam
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = [0.12, 0.12, beamLength]
        emitter.speed = 0.15
        emitter.speedVariation = 0.1
        emitter.mainEmitter.birthRate = 200
        emitter.mainEmitter.lifeSpan = 0.4
        emitter.mainEmitter.size = 0.04
        emitter.mainEmitter.sizeVariation = 0.02
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 1.0, green: 0.5, blue: 0.5, alpha: 1.0)),
            end: .single(.init(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive

        let particleEntity = Entity()
        particleEntity.components.set(emitter)
        particleEntity.position = midpoint
        particleEntity.orientation = entity.orientation
        content.add(particleEntity)
        beamParticleEntities[tower.id] = particleEntity
    }

    func updateBeam(for tower: Tower, origin: SIMD3<Float>, endpoint: SIMD3<Float>) {
        guard let entity = beamEntities[tower.id] else { return }

        let diff = endpoint - origin
        let beamLength = simd_length(diff)
        let midpoint = origin + diff * 0.5

        let mesh = MeshResource.generateBox(width: 0.03, height: 0.03, depth: beamLength)
        if var model = entity.components[ModelComponent.self] {
            model.mesh = mesh
            entity.components[ModelComponent.self] = model
        }
        entity.position = midpoint
        let direction = normalize(diff)
        entity.orientation = simd_quatf(from: [0, 0, 1], to: direction)

        // Update particle entity to follow beam
        if let particleEntity = beamParticleEntities[tower.id] {
            particleEntity.position = midpoint
            particleEntity.orientation = entity.orientation
            if var emitter = particleEntity.components[ParticleEmitterComponent.self] {
                emitter.emitterShapeSize = [0.2, 0.2, beamLength]
                particleEntity.components[ParticleEmitterComponent.self] = emitter
            }
        }
    }

    func removeBeam(for tower: Tower) {
        beamEntities[tower.id]?.removeFromParent()
        beamEntities.removeValue(forKey: tower.id)
        beamParticleEntities[tower.id]?.removeFromParent()
        beamParticleEntities.removeValue(forKey: tower.id)
    }

    func removeAllBeams() {
        for (_, entity) in beamEntities {
            entity.removeFromParent()
        }
        beamEntities.removeAll()
        for (_, entity) in beamParticleEntities {
            entity.removeFromParent()
        }
        beamParticleEntities.removeAll()
    }

    // MARK: - Fire Cones

    private var coneEntities: [UUID: Entity] = [:]

    func createCone(for tower: Tower, origin: SIMD3<Float>, target: SIMD3<Float>) {
        guard let content else { return }

        let diff = target - origin
        let distance = simd_length(diff)
        let direction = normalize(diff)
        // Emit particles from the barrel tip, spreading outward toward the target
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .point
        emitter.speed = distance * 1.8
        emitter.speedVariation = distance * 0.3
        emitter.mainEmitter.birthRate = 500
        emitter.mainEmitter.lifeSpan = Double(distance / (distance * 1.8)) + 0.05
        emitter.mainEmitter.lifeSpanVariation = 0.05
        emitter.mainEmitter.size = 0.05
        emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 6.0
        emitter.mainEmitter.sizeVariation = 0.02
        emitter.mainEmitter.spreadingAngle = 0.25
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)),
            end: .single(.init(red: 1.0, green: 0.15, blue: 0.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive

        let entity = Entity()
        entity.components.set(emitter)
        entity.position = origin
        // Point emitter emits along local +Y; rotate so +Y points toward target
        let rotation = simd_quatf(from: [0, 1, 0], to: direction)
        entity.orientation = rotation
        content.add(entity)
        coneEntities[tower.id] = entity
    }

    func removeCone(for tower: Tower) {
        coneEntities[tower.id]?.removeFromParent()
        coneEntities.removeValue(forKey: tower.id)
    }

    func removeAllCones() {
        for (_, entity) in coneEntities {
            entity.removeFromParent()
        }
        coneEntities.removeAll()
    }

    // MARK: - Enemies

    private var enemyEntities: [UUID: Entity] = [:]

    func createEnemy(_ enemy: Enemy, radius: Float, at position: SIMD3<Float>) {
        guard let content else { return }
        let mesh = MeshResource.generateSphere(radius: radius)
        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))

        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = position
        content.add(entity)
        enemyEntities[enemy.id] = entity
    }

    func updateEnemyPosition(_ enemy: Enemy, position: SIMD3<Float>) {
        guard let entity = enemyEntities[enemy.id] else { return }
        entity.position = position
        let hpRatio = max(0, enemy.hitPoints / enemy.maxHitPoints)
        let s = 0.25 + 0.75 * hpRatio
        entity.scale = [s, s, s]
    }

    func removeEnemy(_ enemy: Enemy) {
        if let entity = enemyEntities[enemy.id], let content {
            let pos = entity.position
            entity.removeFromParent()
            enemyEntities.removeValue(forKey: enemy.id)

            // Spawn death impact particles
            var emitter = ParticleEmitterComponent()
            emitter.emitterShape = .sphere
            emitter.emitterShapeSize = [0.08, 0.08, 0.08]
            emitter.speed = 2.0
            emitter.speedVariation = 0.8
            emitter.mainEmitter.birthRate = 500
            emitter.mainEmitter.lifeSpan = 0.5
            emitter.mainEmitter.lifeSpanVariation = 0.15
            emitter.mainEmitter.size = 0.05
            emitter.mainEmitter.sizeVariation = 0.025
            emitter.mainEmitter.color = .evolving(
                start: .single(.init(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)),
                end: .single(.init(red: 1.0, green: 0.15, blue: 0.0, alpha: 0.0))
            )
            emitter.mainEmitter.blendMode = .additive
            emitter.timing = .once(warmUp: 0, emit: .init(duration: 0.08))

            let particleEntity = Entity()
            particleEntity.components.set(emitter)
            particleEntity.position = pos
            content.add(particleEntity)

            // Remove particle entity after particles fade out
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.0))
                particleEntity.removeFromParent()
            }
        } else {
            enemyEntities[enemy.id]?.removeFromParent()
            enemyEntities.removeValue(forKey: enemy.id)
        }
    }

    func removeAllEnemies() {
        for (_, entity) in enemyEntities {
            entity.removeFromParent()
        }
        enemyEntities.removeAll()
    }

    // MARK: - Projectiles

    private var projectileEntities: [UUID: Entity] = [:]

    func createProjectile(_ projectile: Projectile) {
        guard let content else { return }
        let mesh = MeshResource.generateSphere(radius: 0.05)
        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 0.9, blue: 0.3, alpha: 1))

        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = projectile.origin
        content.add(entity)
        projectileEntities[projectile.id] = entity
    }

    func updateProjectilePosition(_ projectile: Projectile) {
        projectileEntities[projectile.id]?.position = projectile.currentPosition
    }

    func removeProjectile(_ projectile: Projectile) {
        projectileEntities[projectile.id]?.removeFromParent()
        projectileEntities.removeValue(forKey: projectile.id)
    }

    func removeAllProjectiles() {
        for (_, entity) in projectileEntities {
            entity.removeFromParent()
        }
        projectileEntities.removeAll()
    }

    // MARK: - Color

    private func colorForHeight(_ t: Float, isPath: Bool) -> SimpleMaterial.Color {
        let darken: Float = isPath ? 0.55 : 1.0
        let r = (0.76 - 0.3 * t) * darken
        let g = (0.65 + 0.15 * t) * darken
        let b = (0.42 - 0.12 * t) * darken
        return SimpleMaterial.Color(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }
}
