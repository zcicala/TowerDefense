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

    // MARK: - Bonus Cell Indicators

    private var bonusIndicatorEntities: [HexCoord: Entity] = [:]

    func showBonusIndicator(for cell: HexCell, at position: SIMD3<Float>) {
        guard let content, bonusIndicatorEntities[cell.coord] == nil else { return }

        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .torus
        emitter.emitterShapeSize = [0.3, 0.05, 0.3]
        emitter.speed = 0.8
        emitter.speedVariation = 0.1
        emitter.mainEmitter.birthRate = 60
        emitter.mainEmitter.lifeSpan = 1.2
        emitter.mainEmitter.size = 0.1
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 1.0, green: 0.85, blue: 0.1, alpha: 1.0)),
            end: .single(.init(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.timing = .repeating(warmUp: 0, emit: .init(duration: 1.0), idle: .init(duration: 0))

        let entity = Entity()
        entity.components.set(emitter)
        entity.position = SIMD3(position.x, position.y + 0.1, position.z)
        content.add(entity)
        bonusIndicatorEntities[cell.coord] = entity
    }

    func removeBonusIndicator(for coord: HexCoord) {
        bonusIndicatorEntities[coord]?.removeFromParent()
        bonusIndicatorEntities.removeValue(forKey: coord)
    }

    func removeAllBonusIndicators() {
        for entity in bonusIndicatorEntities.values { entity.removeFromParent() }
        bonusIndicatorEntities.removeAll()
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
        case .ice:   tint = .init(red: 0.5, green: 0.6, blue: 0.8, alpha: 1)
        case .projectile: tint = .init(red: 0.5, green: 0.5, blue: 0.6, alpha: 1)
        case .bowler: tint = .init(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
        case .sword:  tint = .init(red: 0.35, green: 0.45, blue: 0.35, alpha: 1)
        case .healer: tint = .init(red: 0.3, green: 0.6, blue: 0.4, alpha: 1)  // soft green base
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
        case .ice:   turretTint = .init(red: 0.3, green: 0.6, blue: 1.0, alpha: 1)
        case .projectile: turretTint = .init(red: 0.7, green: 0.3, blue: 0.2, alpha: 1)
        case .bowler: turretTint = .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        case .sword:  turretTint = .init(red: 0.85, green: 0.85, blue: 0.95, alpha: 1)  // silver top
        case .healer: turretTint = .init(red: 0.9, green: 1.0, blue: 0.9, alpha: 1)    // pale green top
        }
        turretMaterial.baseColor = CustomMaterial.BaseColor(tint: turretTint)

        let turretMesh = MeshResource.generateBox(width: 0.3, height: 0.1, depth: 0.3, cornerRadius: 0.05)
        let turret = Entity()
        turret.components.set(ModelComponent(mesh: turretMesh, materials: [turretMaterial]))
        turretGroup.addChild(turret)

        // Barrel / launch mechanism
        var barrelMaterial = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        barrelMaterial.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))

        if tower.type == .bowler {
            // Resting ball on top of the turret platform
            let ballMesh = MeshResource.generateSphere(radius: 0.1)
            let restBall = Entity()
            restBall.components.set(ModelComponent(mesh: ballMesh, materials: [barrelMaterial]))
            restBall.position = [0, 0.1, 0]
            turretGroup.addChild(restBall)
        } else if tower.type == .sword {
            // Upright sword blade resting in a scabbard
            var bladeMat = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
            bladeMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.85, green: 0.85, blue: 0.95, alpha: 1))
            let bladeMesh = MeshResource.generateBox(width: 0.04, height: 0.4, depth: 0.04, cornerRadius: 0.01)
            let blade = Entity()
            blade.components.set(ModelComponent(mesh: bladeMesh, materials: [bladeMat]))
            blade.position = [0, 0.25, 0]
            turretGroup.addChild(blade)
        } else if tower.type == .healer {
            // Cross shape on top (two overlapping boxes forming a +)
            var crossMat = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
            crossMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1))
            let armH = Entity()
            armH.components.set(ModelComponent(mesh: MeshResource.generateBox(width: 0.22, height: 0.06, depth: 0.06), materials: [crossMat]))
            armH.position = [0, 0.1, 0]
            turretGroup.addChild(armH)
            let armV = Entity()
            armV.components.set(ModelComponent(mesh: MeshResource.generateBox(width: 0.06, height: 0.22, depth: 0.06), materials: [crossMat]))
            armV.position = [0, 0.1, 0]
            turretGroup.addChild(armV)
        } else {
            let barrelMesh = MeshResource.generateCylinder(height: 0.2, radius: 0.06)
            let barrel = Entity()
            barrel.components.set(ModelComponent(mesh: barrelMesh, materials: [barrelMaterial]))
            barrel.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            barrel.position = [0, 0, -0.25]
            turretGroup.addChild(barrel)
        }

        content.add(root)
        towerEntities[tower.id] = root
        turretEntities[tower.id] = turretGroup
    }

    // MARK: - Base Tower

    private var baseTowerRoot: Entity?
    private var baseTowerBlocks: [Entity] = []  // index 0 = bottom, 4 = top

    func createBaseTower(cellHeight: Float, position: SIMD2<Float>) {
        guard let content else { return }

        let root = Entity()
        root.position = [position.x, cellHeight, position.y]

        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        material.baseColor = CustomMaterial.BaseColor(
            tint: .init(red: 0.85, green: 0.75, blue: 0.5, alpha: 1)
        )

        let baseWidth: Float = 0.3
        let blockHeight: Float = 0.25
        let blockGap: Float = 0.02
        let cornerRadius: Float = 0.04

        var currentY: Float = 0
        baseTowerBlocks.removeAll()

        for i in 0..<5 {
            let scale = pow(0.9, Float(i))
            let w = baseWidth * scale
            let h = blockHeight * scale
            let cr = cornerRadius * scale
            let mesh = MeshResource.generateBox(width: w, height: h, depth: w, cornerRadius: cr)
            let block = Entity()
            block.components.set(ModelComponent(mesh: mesh, materials: [material]))
            block.position.y = currentY + h / 2
            root.addChild(block)
            baseTowerBlocks.append(block)
            currentY += h + blockGap
        }

        content.add(root)
        baseTowerRoot = root
    }

    /// Explodes the top remaining block with particles and removes it.
    func explodeTopBlock() {
        guard let content, let block = baseTowerBlocks.last, let root = baseTowerRoot else { return }

        // Compute world position manually: root position + block's local Y offset
        let worldPos = SIMD3<Float>(
            root.position.x,
            root.position.y + block.position.y,
            root.position.z
        )

        block.removeFromParent()
        baseTowerBlocks.removeLast()

        // Spawn explosion particles
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .point
        emitter.emitterShapeSize = [0.15, 0.15, 0.15]
        emitter.speed = 10.0
        emitter.speedVariation = 1.5
        emitter.mainEmitter.birthRate = 1000
        emitter.mainEmitter.lifeSpan = 5
        emitter.mainEmitter.lifeSpanVariation = 0.2
        emitter.mainEmitter.size = 2
        emitter.mainEmitter.sizeVariation = 0.1
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 0.1, green: 0.1, blue: 0.8, alpha: 1.0)),
            end: .single(.init(red: 0.8, green: 0.2, blue: 0.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.timing = .once(warmUp: 0, emit: .init(duration: 0.1))

        let particleEntity = Entity()
        particleEntity.components.set(emitter)
        particleEntity.position = worldPos
        content.add(particleEntity)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            particleEntity.removeFromParent()
        }
    }

    /// Adds a small yellow dome on top of the turret to indicate max level.
    func addMaxLevelDome(for tower: Tower) {
        guard let turretGroup = turretEntities[tower.id] else { return }

        let domeMesh = MeshResource.generateSphere(radius: 0.08)
        var domeMaterial = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        domeMaterial.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 0.9, blue: 0.2, alpha: 1))

        let dome = Entity()
        dome.components.set(ModelComponent(mesh: domeMesh, materials: [domeMaterial]))
        // Position on top of turret (turret height is 0.1, so half = 0.05)
        dome.position = [0, 0.05 + 0.08, 0]
        // Squash into a dome shape
        dome.scale = [1.0, 0.5, 1.0]
        turretGroup.addChild(dome)
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
        let direction = normalize(diff)

        // Solid beam
        let mesh = MeshResource.generateBox(width: 0.03, height: 0.03, depth: beamLength)
        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.3, green: 0.6, blue: 1.0, alpha: 1))

        let beamEntity = Entity()
        beamEntity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        beamEntity.position = midpoint
        beamEntity.orientation = simd_quatf(from: [0, 0, 1], to: direction)
        content.add(beamEntity)
        beamEntities[tower.id] = beamEntity

        // Particle glow
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .point
        emitter.speed = beamLength * 3.0
        emitter.speedVariation = beamLength * 0.2
        emitter.mainEmitter.birthRate = 100
        emitter.mainEmitter.lifeSpan = Double(1.0 / 3.0) + 0.02
        emitter.mainEmitter.lifeSpanVariation = 0.02
        emitter.mainEmitter.size = 0.04
        emitter.mainEmitter.sizeVariation = 0.01
        emitter.mainEmitter.spreadingAngle = 0.03
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)),
            end: .single(.init(red: 0.1, green: 0.3, blue: 1.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive

        let particleEntity = Entity()
        particleEntity.components.set(emitter)
        particleEntity.position = origin
        particleEntity.orientation = simd_quatf(from: [0, 1, 0], to: direction)
        content.add(particleEntity)
        beamParticleEntities[tower.id] = particleEntity
    }

    func updateBeam(for tower: Tower, origin: SIMD3<Float>, endpoint: SIMD3<Float>) {
        let diff = endpoint - origin
        let beamLength = simd_length(diff)
        let midpoint = origin + diff * 0.5
        let direction = normalize(diff)

        // Update solid beam
        if let beamEntity = beamEntities[tower.id] {
            let mesh = MeshResource.generateBox(width: 0.03, height: 0.03, depth: beamLength)
            if var model = beamEntity.components[ModelComponent.self] {
                model.mesh = mesh
                beamEntity.components[ModelComponent.self] = model
            }
            beamEntity.position = midpoint
            beamEntity.orientation = simd_quatf(from: [0, 0, 1], to: direction)
        }

        // Update particle glow
        if let particleEntity = beamParticleEntities[tower.id] {
            particleEntity.position = origin
            particleEntity.orientation = simd_quatf(from: [0, 1, 0], to: direction)
            if var emitter = particleEntity.components[ParticleEmitterComponent.self] {
                emitter.speed = beamLength * 3.0
                emitter.speedVariation = beamLength * 0.2
                emitter.mainEmitter.lifeSpan = Double(1.0 / 3.0) + 0.02
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
        if tower.type == .ice {
            emitter.mainEmitter.color = .evolving(
                start: .single(.init(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)),
                end: .single(.init(red: 0.2, green: 0.4, blue: 1.0, alpha: 0.0))
            )
        } else {
            emitter.mainEmitter.color = .evolving(
                start: .single(.init(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)),
                end: .single(.init(red: 1.0, green: 0.15, blue: 0.0, alpha: 0.0))
            )
        }
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

    func updateCone(for tower: Tower, origin: SIMD3<Float>, target: SIMD3<Float>) {
        guard let entity = coneEntities[tower.id] else { return }

        let diff = target - origin
        let distance = simd_length(diff)
        let direction = normalize(diff)

        entity.position = origin
        entity.orientation = simd_quatf(from: [0, 1, 0], to: direction)

        if var emitter = entity.components[ParticleEmitterComponent.self] {
            emitter.speed = distance * 1.8
            emitter.speedVariation = distance * 0.3
            emitter.mainEmitter.lifeSpan = Double(distance / (distance * 1.8)) + 0.05
            entity.components[ParticleEmitterComponent.self] = emitter
        }
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

    // MARK: - Bowling Balls

    private var ballEntities: [UUID: Entity] = [:]

    func createBowlingBall(_ ball: BowlingBall, at position: SIMD3<Float>) {
        guard let content else { return }
        var mat = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        mat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        let entity = Entity()
        entity.components.set(ModelComponent(mesh: MeshResource.generateSphere(radius: 0.18), materials: [mat]))
        entity.position = position
        entity.scale = [0.05, 0.05, 0.05]
        content.add(entity)
        ballEntities[ball.id] = entity
    }

    func updateBowlingBallPosition(_ ball: BowlingBall, position: SIMD3<Float>) {
        guard let entity = ballEntities[ball.id] else { return }
        entity.position = position
        if ball.isFalling {
            // Grow from near-zero to full size with an ease-out curve
            let t = ball.fallProgress
            let scale = 0.05 + 0.95 * (1 - pow(1 - t, 2))
            entity.scale = [scale, scale, scale]
        } else {
            entity.scale = [1, 1, 1]
        }
    }

    func removeBowlingBall(_ ball: BowlingBall) {
        ballEntities[ball.id]?.removeFromParent()
        ballEntities.removeValue(forKey: ball.id)
    }

    func removeAllBowlingBalls() {
        for (_, entity) in ballEntities { entity.removeFromParent() }
        ballEntities.removeAll()
    }

    /// Small grey poof when a bowling ball rolls off the path.
    func createBallPop(at position: SIMD3<Float>) {
        guard let content else { return }
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.1, 0.1, 0.1]
        emitter.speed = 1.5
        emitter.speedVariation = 0.5
        emitter.mainEmitter.birthRate = 200
        emitter.mainEmitter.lifeSpan = 0.5
        emitter.mainEmitter.size = 0.06
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)),
            end: .single(.init(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.0))
        )
        emitter.timing = .once(warmUp: 0, emit: .init(duration: 0.1))
        let entity = Entity()
        entity.components.set(emitter)
        entity.position = position
        content.add(entity)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            entity.removeFromParent()
        }
    }

    // MARK: - Sword Blades

    private var bladeEntities: [UUID: Entity] = [:]

    func createBlades(for tower: Tower, positions: [(origin: SIMD3<Float>, tip: SIMD3<Float>)]) {
        guard let content, let (origin, tip) = positions.first else { return }
        var mat = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        mat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.9, green: 0.9, blue: 1.0, alpha: 1))
        let entity = Entity()
        entity.components.set(ModelComponent(mesh: MeshResource.generateBox(width: 0.025, height: 0.025, depth: 0.01), materials: [mat]))
        content.add(entity)
        bladeEntities[tower.id] = entity
        applyBladeTransform(entity, origin: origin, tip: tip)
    }

    func updateBlade(for tower: Tower, positions: [(origin: SIMD3<Float>, tip: SIMD3<Float>)]) {
        guard let entity = bladeEntities[tower.id], let (origin, tip) = positions.first else { return }
        applyBladeTransform(entity, origin: origin, tip: tip)
    }

    private func applyBladeTransform(_ entity: Entity, origin: SIMD3<Float>, tip: SIMD3<Float>) {
        let dx = tip.x - origin.x
        let dz = tip.z - origin.z
        let length = sqrt(dx*dx + (tip.y-origin.y)*(tip.y-origin.y) + dz*dz)
        guard length > 0.001 else { entity.scale = [0, 0, 0]; return }

        entity.position = SIMD3(
            (origin.x + tip.x) / 2,
            (origin.y + tip.y) / 2,
            (origin.z + tip.z) / 2
        )
        let angle = atan2(dx, dz)
        entity.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        entity.scale = [1, 1, length / 0.01]  // stretch the unit-depth box to match length
    }

    func removeBlade(for tower: Tower) {
        bladeEntities[tower.id]?.removeFromParent()
        bladeEntities.removeValue(forKey: tower.id)
    }

    func removeAllBlades() {
        for entity in bladeEntities.values { entity.removeFromParent() }
        bladeEntities.removeAll()
    }

    // MARK: - Enemies

    private var enemyEntities: [UUID: Entity] = [:]

    func createEnemy(_ enemy: Enemy, radius: Float, at position: SIMD3<Float>) {
        guard let content else { return }

        let mesh: MeshResource
        var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)

        switch enemy.enemyType {
        case .boss:
            mesh = MeshResource.generateBox(width: radius * 3, height: radius * 4, depth: radius * 3, cornerRadius: radius * 0.3)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.6, green: 0.1, blue: 0.15, alpha: 1))
        case .exploder:
            mesh = MeshResource.generateBox(width: radius * 2.2, height: radius * 2.2, depth: radius * 2.2, cornerRadius: radius * 0.2)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 0.4, blue: 0.0, alpha: 1))
        case .shield:
            mesh = MeshResource.generateSphere(radius: radius * 1.5)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 0.9, blue: 0.2, alpha: 1))
        case .fastTank:
            mesh = MeshResource.generateSphere(radius: radius * 2)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.85, green: 0.35, blue: 0.1, alpha: 1))
        case .tank:
            mesh = MeshResource.generateSphere(radius: radius * 2)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.5, green: 0.25, blue: 0.6, alpha: 1))
        case .basic:
            mesh = MeshResource.generateSphere(radius: radius)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        }

        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = position
        content.add(entity)
        enemyEntities[enemy.id] = entity

        // Create shield dome for shielder enemies
        if enemy.enemyType == .shield {
            createShieldDome(for: enemy, at: position, spacing: radius)
        }
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

    // MARK: - Shield Domes

    private var shieldDomeEntities: [UUID: Entity] = [:]

    func createShieldDome(for enemy: Enemy, at position: SIMD3<Float>, spacing: Float) {
        guard let content else { return }

        // Dome radius covers the shielder's cell + 1 cell around it (~1.5 hex widths)
        let domeRadius: Float = 0.8
        let mesh = MeshResource.generateSphere(radius: domeRadius)
        var material = UnlitMaterial(color: .init(red: 1.0, green: 0.95, blue: 0.3, alpha: 0.2))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.2))

        let dome = Entity()
        dome.components.set(ModelComponent(mesh: mesh, materials: [material]))
        dome.position = position
        // Squash slightly into a dome shape
        dome.scale = [1.0, 0.6, 1.0]
        content.add(dome)
        shieldDomeEntities[enemy.id] = dome
    }

    func updateShieldDome(for enemy: Enemy, position: SIMD3<Float>, shieldRatio: Float) {
        guard let dome = shieldDomeEntities[enemy.id] else { return }
        dome.position = position
        // Scale dome based on remaining shield HP for visual feedback
        let s = 0.5 + 0.5 * shieldRatio
        dome.scale = [s, 0.6 * s, s]
    }

    func removeShieldDome(for enemy: Enemy) {
        shieldDomeEntities[enemy.id]?.removeFromParent()
        shieldDomeEntities.removeValue(forKey: enemy.id)
    }

    func removeAllShieldDomes() {
        for (_, entity) in shieldDomeEntities {
            entity.removeFromParent()
        }
        shieldDomeEntities.removeAll()
    }

    /// Spawns a large orange explosion effect at the given world position.
    func createExplosion(at position: SIMD3<Float>) {
        guard let content else { return }

        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.2, 0.2, 0.2]
        emitter.speed = 4.0
        emitter.speedVariation = 2.0
        emitter.mainEmitter.birthRate = 800
        emitter.mainEmitter.lifeSpan = 0.8
        emitter.mainEmitter.lifeSpanVariation = 0.3
        emitter.mainEmitter.size = 0.1
        emitter.mainEmitter.sizeVariation = 0.05
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 1.0, green: 0.7, blue: 0.1, alpha: 1.0)),
            end: .single(.init(red: 1.0, green: 0.1, blue: 0.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.timing = .once(warmUp: 0, emit: .init(duration: 0.15))

        let entity = Entity()
        entity.components.set(emitter)
        entity.position = position
        content.add(entity)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            entity.removeFromParent()
        }
    }

    func removeAllEnemies() {
        for (_, entity) in enemyEntities {
            entity.removeFromParent()
        }
        enemyEntities.removeAll()
        removeAllShieldDomes()
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

    func removeTower(id: UUID) {
        towerEntities[id]?.removeFromParent()
        towerEntities.removeValue(forKey: id)
        turretEntities.removeValue(forKey: id)
    }

    func rebuildBaseTower(cellHeight: Float, position: SIMD2<Float>) {
        baseTowerRoot?.removeFromParent()
        baseTowerRoot = nil
        baseTowerBlocks.removeAll()
        createBaseTower(cellHeight: cellHeight, position: position)
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
