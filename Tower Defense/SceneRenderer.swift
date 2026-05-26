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
    // CustomMaterial(surfaceShader:lightingModel:) re-registers the shader library with
    // RealityKit's shader manager on every call, producing "already exists" warnings.
    // Caching one template per shader (created once) and copying the value type lets
    // every entity share the same registration.
    static let surfaceMaterial: CustomMaterial? = {
        guard let lib = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return nil }
        let shader = CustomMaterial.SurfaceShader(named: "celSurfaceShader", in: lib)
        return try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
    }()
    static let watercolorMaterial: CustomMaterial? = {
        guard let lib = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return nil }
        let shader = CustomMaterial.SurfaceShader(named: "watercolorSurfaceShader", in: lib)
        return try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
    }()

    private var entityMap: [HexCoord: Entity] = [:]
    private var content: (any RealityViewContentProtocol)?

    init?() {
        guard SceneRenderer.surfaceMaterial != nil,
              SceneRenderer.watercolorMaterial != nil else { return nil }
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
            var material = SceneRenderer.surfaceMaterial!
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

    /// Looks up the enemy ID for a tapped entity.
    func enemyID(for entity: Entity) -> UUID? {
        enemyEntities.first { $0.value === entity }?.key
    }

    // MARK: - Bonus Cell Indicators

    private var bonusIndicatorEntities: [HexCoord: Entity] = [:]

    func showBonusIndicator(for cell: HexCell, at position: SIMD3<Float>) {
        guard let content, bonusIndicatorEntities[cell.coord] == nil else { return }

        let entity: Entity

        if cell.bonusType?.isInventoryBonus == true {
            entity = makeTreasureChest(at: position)
        } else {
            entity = makeParticleBonusIndicator(at: position)
        }

        content.add(entity)
        bonusIndicatorEntities[cell.coord] = entity
    }

    private func makeTreasureChest(at position: SIMD3<Float>) -> Entity {
        func mat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CustomMaterial {
            var m = SceneRenderer.surfaceMaterial!
            m.baseColor = CustomMaterial.BaseColor(tint: .init(red: r, green: g, blue: b, alpha: 1))
            return m
        }

        let root = Entity()
        root.position = SIMD3(position.x, position.y, position.z)

        // Body — dark brown box
        let body = Entity()
        body.components.set(ModelComponent(
            mesh: .generateBox(width: 0.22, height: 0.14, depth: 0.18),
            materials: [mat(0.42, 0.22, 0.08)]))
        body.position = [0, 0.07, 0]
        root.addChild(body)

        // Lid box — slightly wider, darker
        let lid = Entity()
        lid.components.set(ModelComponent(
            mesh: .generateBox(width: 0.24, height: 0.06, depth: 0.20),
            materials: [mat(0.30, 0.14, 0.05)]))
        lid.position = [0, 0.17, 0]
        root.addChild(lid)

        // Lid dome — cylinder rotated so its axis runs front-to-back (Z)
        let dome = Entity()
        dome.components.set(ModelComponent(
            mesh: .generateCylinder(height: 0.20, radius: 0.07),
            materials: [mat(0.30, 0.14, 0.05)]))
        dome.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        dome.position = [0, 0.20, 0]
        root.addChild(dome)

        // Gold rim at the lid join
        let rim = Entity()
        rim.components.set(ModelComponent(
            mesh: .generateBox(width: 0.245, height: 0.018, depth: 0.205),
            materials: [mat(0.85, 0.65, 0.10)]))
        rim.position = [0, 0.14, 0]
        root.addChild(rim)

        // Gold horizontal band across the body centre
        let band = Entity()
        band.components.set(ModelComponent(
            mesh: .generateBox(width: 0.225, height: 0.022, depth: 0.185),
            materials: [mat(0.85, 0.65, 0.10)]))
        band.position = [0, 0.07, 0]
        root.addChild(band)

        // Bright gold clasp on the front face
        let clasp = Entity()
        clasp.components.set(ModelComponent(
            mesh: .generateBox(width: 0.04, height: 0.055, depth: 0.022),
            materials: [mat(1.0, 0.82, 0.20)]))
        clasp.position = [0, 0.10, 0.10]
        root.addChild(clasp)

        return root
    }

    private func makeParticleBonusIndicator(at position: SIMD3<Float>) -> Entity {
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
        return entity
    }

    func removeBonusIndicator(for coord: HexCoord) {
        bonusIndicatorEntities[coord]?.removeFromParent()
        bonusIndicatorEntities.removeValue(forKey: coord)
    }

    func removeAllBonusIndicators() {
        for entity in bonusIndicatorEntities.values { entity.removeFromParent() }
        bonusIndicatorEntities.removeAll()
    }

    // MARK: - Farm Entities

    private var farmEntities: [HexCoord: Entity] = [:]

    func createFarm(_ farm: Farm, cellHeight: Float, spacing: Float) {
        guard let content, farmEntities[farm.coord] == nil else { return }

        func mat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CustomMaterial {
            var m = SceneRenderer.surfaceMaterial!
            m.baseColor = CustomMaterial.BaseColor(tint: .init(red: r, green: g, blue: b, alpha: 1))
            return m
        }

        let pos = farm.coord.worldPosition(spacing: spacing)
        let root = Entity()
        root.position = [pos.x, cellHeight, pos.y]

        switch farm.farmType {

        case .farm:
            // Green field base
            let field = Entity()
            field.components.set(ModelComponent(
                mesh: .generateBox(width: 0.58, height: 0.025, depth: 0.58),
                materials: [mat(0.30, 0.54, 0.20)]))
            field.position = [0, 0.0125, 0]
            root.addChild(field)

            // --- House (left half) ---
            let houseX: Float = -0.11
            let wallH: Float = 0.14
            let wallW: Float = 0.22
            let wallD: Float = 0.22
            let groundTop: Float = 0.025

            let walls = Entity()
            walls.components.set(ModelComponent(
                mesh: .generateBox(width: wallW, height: wallH, depth: wallD),
                materials: [mat(0.95, 0.90, 0.78)]))
            walls.position = [houseX, groundTop + wallH / 2, 0]
            root.addChild(walls)

            // Door
            let door = Entity()
            door.components.set(ModelComponent(
                mesh: .generateBox(width: 0.05, height: 0.07, depth: 0.01),
                materials: [mat(0.45, 0.28, 0.12)]))
            door.position = [houseX, groundTop + 0.04, -(wallD / 2 + 0.005)]
            root.addChild(door)

            // Peaked roof — two angled panels meeting at a ridge
            let roofY: Float = groundTop + wallH
            for (sign, xOff) in [(-1.0, houseX - 0.057), (1.0, houseX + 0.057)] as [(Float, Float)] {
                let panel = Entity()
                panel.components.set(ModelComponent(
                    mesh: .generateBox(width: 0.135, height: 0.022, depth: wallD + 0.04),
                    materials: [mat(0.70, 0.22, 0.14)]))
                panel.orientation = simd_quatf(angle: -sign * (.pi / 5), axis: [0, 0, 1])
                panel.position = [xOff, roofY + 0.026, 0]
                root.addChild(panel)
            }

            // --- Crop rows (right half) ---
            let cropX: Float = 0.12
            for rz: Float in [-0.10, 0.0, 0.10] {
                // Soil strip
                let soilRow = Entity()
                soilRow.components.set(ModelComponent(
                    mesh: .generateBox(width: 0.26, height: 0.028, depth: 0.055),
                    materials: [mat(0.38, 0.24, 0.12)]))
                soilRow.position = [cropX, groundTop + 0.014, rz]
                root.addChild(soilRow)
                // Crop tops
                let cropRow = Entity()
                cropRow.components.set(ModelComponent(
                    mesh: .generateBox(width: 0.26, height: 0.055, depth: 0.032),
                    materials: [mat(0.48, 0.72, 0.22)]))
                cropRow.position = [cropX, groundTop + 0.028 + 0.028, rz]
                root.addChild(cropRow)
            }

        case .bank:
            // Stepped base — two layers
            let stepSizes: [(Float, Float, Float, Float)] = [
                (0.58, 0.025, 0.54, 0.0125),
                (0.52, 0.025, 0.48, 0.0375),
            ]
            for (w, h, d, y) in stepSizes {
                let step = Entity()
                step.components.set(ModelComponent(
                    mesh: .generateBox(width: w, height: h, depth: d),
                    materials: [mat(0.78, 0.76, 0.74)]))
                step.position = [0, y, 0]
                root.addChild(step)
            }

            // Building body
            let bodyW: Float = 0.44
            let bodyH: Float = 0.20
            let bodyD: Float = 0.36
            let bodyYBase: Float = 0.05
            let body = Entity()
            body.components.set(ModelComponent(
                mesh: .generateBox(width: bodyW, height: bodyH, depth: bodyD),
                materials: [mat(0.93, 0.91, 0.89)]))
            body.position = [0, bodyYBase + bodyH / 2, 0]
            root.addChild(body)

            // Columns — front and back rows
            let colH: Float = bodyH
            let colY: Float = bodyYBase + colH / 2
            for colZ: Float in [-(bodyD / 2), bodyD / 2] {
                for cx: Float in [-0.15, -0.05, 0.05, 0.15] {
                    let col = Entity()
                    col.components.set(ModelComponent(
                        mesh: .generateCylinder(height: colH, radius: 0.026),
                        materials: [mat(0.86, 0.84, 0.82)]))
                    col.position = [cx, colY, colZ]
                    root.addChild(col)
                }
            }

            // Entablature (horizontal band above columns)
            let entabH: Float = 0.04
            let entabYCenter: Float = bodyYBase + bodyH + entabH / 2
            let entab = Entity()
            entab.components.set(ModelComponent(
                mesh: .generateBox(width: 0.50, height: entabH, depth: 0.42),
                materials: [mat(0.80, 0.78, 0.76)]))
            entab.position = [0, entabYCenter, 0]
            root.addChild(entab)

            // Pediment (gable) — two slanted panels forming a triangle
            let pedBase: Float = bodyYBase + bodyH + entabH
            for (sign, xOff) in [(-1.0, -0.115), (1.0, 0.115)] as [(Float, Float)] {
                let panel = Entity()
                panel.components.set(ModelComponent(
                    mesh: .generateBox(width: 0.27, height: 0.022, depth: 0.40),
                    materials: [mat(0.80, 0.78, 0.76)]))
                panel.orientation = simd_quatf(angle: -sign * (.pi / 7), axis: [0, 0, 1])
                panel.position = [xOff, pedBase + 0.042, 0]
                root.addChild(panel)
            }

        case .quarry:
            // Gray stone base
            let base = Entity()
            base.components.set(ModelComponent(
                mesh: .generateBox(width: 0.54, height: 0.05, depth: 0.54),
                materials: [mat(0.45, 0.44, 0.46)]))
            base.position = [0, 0.025, 0]
            root.addChild(base)
            // Four rough stone blocks at corners
            for (dx, dz) in [(-0.13, -0.13), (0.13, -0.13), (-0.13, 0.13), (0.13, 0.13)] as [(Float, Float)] {
                let block = Entity()
                block.components.set(ModelComponent(
                    mesh: .generateBox(width: 0.14, height: 0.12, depth: 0.14),
                    materials: [mat(0.52, 0.50, 0.54)]))
                block.position = [dx, 0.11, dz]
                root.addChild(block)
            }
            // Central drill/post
            let post = Entity()
            post.components.set(ModelComponent(
                mesh: .generateCylinder(height: 0.20, radius: 0.04),
                materials: [mat(0.30, 0.28, 0.32)]))
            post.position = [0, 0.15, 0]
            root.addChild(post)
        }

        content.add(root)
        farmEntities[farm.coord] = root
    }

    func removeFarm(at coord: HexCoord) {
        farmEntities[coord]?.removeFromParent()
        farmEntities.removeValue(forKey: coord)
    }

    func removeAllFarms() {
        for entity in farmEntities.values { entity.removeFromParent() }
        farmEntities.removeAll()
    }

    // MARK: - Slow Aura Indicators

    private var slowAuraIndicatorEntities: [HexCoord: Entity] = [:]

    func showSlowAuraIndicator(at coord: HexCoord, height: Float, spacing: Float) {
        guard let content, slowAuraIndicatorEntities[coord] == nil else { return }
        let pos = coord.worldPosition(spacing: spacing)

        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .torus
        emitter.emitterShapeSize = [0.25, 0.04, 0.25]
        emitter.speed = 0.5
        emitter.speedVariation = 0.1
        emitter.mainEmitter.birthRate = 40
        emitter.mainEmitter.lifeSpan = 1.0
        emitter.mainEmitter.size = 0.08
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0)),
            end:   .single(.init(red: 0.1, green: 0.3, blue: 0.9, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.timing = .repeating(warmUp: 0, emit: .init(duration: 1.0), idle: .init(duration: 0))

        let entity = Entity()
        entity.components.set(emitter)
        entity.position = SIMD3(pos.x, height + 0.08, pos.y)
        content.add(entity)
        slowAuraIndicatorEntities[coord] = entity
    }

    func removeSlowAuraIndicator(at coord: HexCoord) {
        slowAuraIndicatorEntities[coord]?.removeFromParent()
        slowAuraIndicatorEntities.removeValue(forKey: coord)
    }

    func removeAllSlowAuraIndicators() {
        for entity in slowAuraIndicatorEntities.values { entity.removeFromParent() }
        slowAuraIndicatorEntities.removeAll()
    }

    // MARK: - Damage Aura Indicators

    private var damageAuraIndicatorEntities: [HexCoord: Entity] = [:]

    func showDamageAuraIndicator(at coord: HexCoord, height: Float, spacing: Float) {
        guard let content, damageAuraIndicatorEntities[coord] == nil else { return }
        let pos = coord.worldPosition(spacing: spacing)

        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .torus
        emitter.emitterShapeSize = [0.25, 0.04, 0.25]
        emitter.speed = 0.5
        emitter.speedVariation = 0.1
        emitter.mainEmitter.birthRate = 40
        emitter.mainEmitter.lifeSpan = 1.0
        emitter.mainEmitter.size = 0.08
        emitter.mainEmitter.color = .evolving(
            start: .single(.init(red: 1.0, green: 0.3, blue: 0.05, alpha: 1.0)),
            end:   .single(.init(red: 0.8, green: 0.1, blue: 0.0, alpha: 0.0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.timing = .repeating(warmUp: 0, emit: .init(duration: 1.0), idle: .init(duration: 0))

        let entity = Entity()
        entity.components.set(emitter)
        entity.position = SIMD3(pos.x, height + 0.08, pos.y)
        content.add(entity)
        damageAuraIndicatorEntities[coord] = entity
    }

    func removeDamageAuraIndicator(at coord: HexCoord) {
        damageAuraIndicatorEntities[coord]?.removeFromParent()
        damageAuraIndicatorEntities.removeValue(forKey: coord)
    }

    func removeAllDamageAuraIndicators() {
        for entity in damageAuraIndicatorEntities.values { entity.removeFromParent() }
        damageAuraIndicatorEntities.removeAll()
    }

    // MARK: - Placement Preview

    private var ghostTowerType: TowerType? = nil
    private var ghostTowerEntity: Entity? = nil
    private var rangeHighlightedCoords: [HexCoord] = []

    func showGhostTower(type: TowerType, at coord: HexCoord, cellHeight: Float, spacing: Float) {
        let pos = coord.worldPosition(spacing: spacing)
        let targetPos = SIMD3<Float>(pos.x, cellHeight, pos.y)

        // If same type already exists, just reposition it
        if let existing = ghostTowerEntity, ghostTowerType == type {
            existing.position = targetPos
            return
        }

        removeGhostTower()
        guard let content else { return }

        let alpha: Float = 0.4
        func mat(_ r: Float, _ g: Float, _ b: Float) -> UnlitMaterial {
            var m = UnlitMaterial(color: .init(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(alpha)))
            m.blending = .transparent(opacity: .init(floatLiteral: alpha))
            return m
        }

        let (br, bg, bb, tr, tg, tb): (Float, Float, Float, Float, Float, Float)
        switch type {
        case .laser:      (br, bg, bb, tr, tg, tb) = (0.3, 0.5, 0.7, 0.2, 0.4, 0.8)
        case .fire:       (br, bg, bb, tr, tg, tb) = (0.6, 0.35, 0.2, 0.9, 0.4, 0.1)
        case .ice:        (br, bg, bb, tr, tg, tb) = (0.5, 0.6, 0.8, 0.3, 0.6, 1.0)
        case .projectile: (br, bg, bb, tr, tg, tb) = (0.5, 0.5, 0.6, 0.7, 0.3, 0.2)
        case .bowler:     (br, bg, bb, tr, tg, tb) = (0.75, 0.75, 0.75, 0.3, 0.3, 0.3)
        case .sword:      (br, bg, bb, tr, tg, tb) = (0.35, 0.45, 0.35, 0.85, 0.85, 0.95)
        case .healer:     (br, bg, bb, tr, tg, tb) = (0.3, 0.6, 0.4, 0.9, 1.0, 0.9)
        case .fireball:   (br, bg, bb, tr, tg, tb) = (0.6, 0.2, 0.05, 1.0, 0.45, 0.0)
        case .antiAir:    (br, bg, bb, tr, tg, tb) = (0.2, 0.35, 0.15, 0.75, 0.78, 0.8)
        case .targeting:  (br, bg, bb, tr, tg, tb) = (0.35, 0.2, 0.55, 0.65, 0.4, 0.9)
        }

        let root = Entity()
        root.position = targetPos

        // Two-prism base (mirrors createTower geometry)
        var currentY: Float = 0
        for i in 0..<2 {
            let scale = pow(0.9, Float(i))
            let w = 0.25 * scale
            let h = 0.3 * scale
            let prism = ModelEntity(
                mesh: .generateBox(width: w, height: h, depth: w, cornerRadius: 0.04 * scale),
                materials: [mat(br, bg, bb)])
            prism.position.y = currentY + h / 2
            root.addChild(prism)
            currentY += h + 0.02
        }

        // Turret
        let turret = ModelEntity(
            mesh: .generateBox(width: 0.3, height: 0.1, depth: 0.3, cornerRadius: 0.05),
            materials: [mat(tr, tg, tb)])
        turret.position.y = currentY + 0.05
        root.addChild(turret)

        content.add(root)
        ghostTowerEntity = root
        ghostTowerType = type
    }

    func removeGhostTower() {
        ghostTowerEntity?.removeFromParent()
        ghostTowerEntity = nil
        ghostTowerType = nil
    }

    func showRangeHighlights(coords: [HexCoord]) {
        removeRangeHighlights()
        for coord in coords {
            guard let entity = entityMap[coord] else { continue }
            if var material = entity.components[ModelComponent.self]?.materials.first as? CustomMaterial {
                material.custom.value[1] = 1
                entity.components[ModelComponent.self]?.materials = [material]
                rangeHighlightedCoords.append(coord)
            }
        }
    }

    func removeRangeHighlights() {
        for coord in rangeHighlightedCoords {
            guard let entity = entityMap[coord] else { continue }
            if var material = entity.components[ModelComponent.self]?.materials.first as? CustomMaterial {
                material.custom.value[1] = 0
                entity.components[ModelComponent.self]?.materials = [material]
            }
        }
        rangeHighlightedCoords.removeAll()
    }

    // MARK: - Towers

    private var towerEntities: [UUID: Entity] = [:]
    private var turretEntities: [UUID: Entity] = [:]
    private var dishEntities: [UUID: Entity] = [:]

    func createTower(_ tower: Tower, cellHeight: Float, spacing: Float) {
        guard let content else { return }

        let pos = tower.coord.worldPosition(spacing: spacing)
        let root = Entity()
        root.position = [pos.x, cellHeight, pos.y]

        // Tower material — different tint for laser vs projectile
        var stoneMaterial = SceneRenderer.surfaceMaterial!
        let tint: SimpleMaterial.Color
        switch tower.type {
        case .laser: tint = .init(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        case .fire:  tint = .init(red: 0.6, green: 0.35, blue: 0.2, alpha: 1)
        case .ice:   tint = .init(red: 0.5, green: 0.6, blue: 0.8, alpha: 1)
        case .projectile: tint = .init(red: 0.5, green: 0.5, blue: 0.6, alpha: 1)
        case .bowler: tint = .init(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
        case .sword:  tint = .init(red: 0.35, green: 0.45, blue: 0.35, alpha: 1)
        case .healer: tint = .init(red: 0.3, green: 0.6, blue: 0.4, alpha: 1)  // soft green base
        case .fireball: tint = .init(red: 0.6, green: 0.2, blue: 0.05, alpha: 1)
        case .antiAir:   tint = .init(red: 0.2, green: 0.35, blue: 0.15, alpha: 1)
        case .targeting: tint = .init(red: 0.35, green: 0.2, blue: 0.55, alpha: 1)
        }
        stoneMaterial.baseColor = CustomMaterial.BaseColor(tint: tint)

        // Stack of 2 rectangular prisms with rounded edges
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
        var turretMaterial = SceneRenderer.surfaceMaterial!
        let turretTint: SimpleMaterial.Color
        switch tower.type {
        case .laser: turretTint = .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        case .fire:  turretTint = .init(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        case .ice:   turretTint = .init(red: 0.3, green: 0.6, blue: 1.0, alpha: 1)
        case .projectile: turretTint = .init(red: 0.7, green: 0.3, blue: 0.2, alpha: 1)
        case .bowler: turretTint = .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        case .sword:  turretTint = .init(red: 0.85, green: 0.85, blue: 0.95, alpha: 1)  // silver top
        case .healer: turretTint = .init(red: 0.9, green: 1.0, blue: 0.9, alpha: 1)    // pale green top
        case .fireball: turretTint = .init(red: 1.0, green: 0.45, blue: 0.0, alpha: 1)
        case .antiAir:   turretTint = .init(red: 0.75, green: 0.78, blue: 0.8, alpha: 1)
        case .targeting: turretTint = .init(red: 0.65, green: 0.4, blue: 0.9, alpha: 1)
        }
        turretMaterial.baseColor = CustomMaterial.BaseColor(tint: turretTint)

        let turretMesh = MeshResource.generateBox(width: 0.3, height: 0.1, depth: 0.3, cornerRadius: 0.05)
        let turret = Entity()
        turret.components.set(ModelComponent(mesh: turretMesh, materials: [turretMaterial]))
        turretGroup.addChild(turret)

        // Barrel / launch mechanism
        var barrelMaterial = SceneRenderer.surfaceMaterial!
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
            var bladeMat = SceneRenderer.surfaceMaterial!
            bladeMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.85, green: 0.85, blue: 0.95, alpha: 1))
            let bladeMesh = MeshResource.generateBox(width: 0.04, height: 0.4, depth: 0.04, cornerRadius: 0.01)
            let blade = Entity()
            blade.components.set(ModelComponent(mesh: bladeMesh, materials: [bladeMat]))
            blade.position = [0, 0.25, 0]
            turretGroup.addChild(blade)
        } else if tower.type == .healer {
            // Cross shape on top (two overlapping boxes forming a +)
            var crossMat = SceneRenderer.surfaceMaterial!
            crossMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1))
            let armH = Entity()
            armH.components.set(ModelComponent(mesh: MeshResource.generateBox(width: 0.22, height: 0.06, depth: 0.06), materials: [crossMat]))
            armH.position = [0, 0.1, 0]
            turretGroup.addChild(armH)
            let armV = Entity()
            armV.components.set(ModelComponent(mesh: MeshResource.generateBox(width: 0.06, height: 0.22, depth: 0.06), materials: [crossMat]))
            armV.position = [0, 0.1, 0]
            turretGroup.addChild(armV)
        } else if tower.type == .targeting {
            // Central pivot post rising from the equipment box
            var pivotMat = SceneRenderer.surfaceMaterial!
            pivotMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.30, green: 0.30, blue: 0.32, alpha: 1))
            let pivot = Entity()
            pivot.components.set(ModelComponent(
                mesh: MeshResource.generateCylinder(height: 0.10, radius: 0.025),
                materials: [pivotMat]))
            pivot.position = [0, 0.05, 0]
            turretGroup.addChild(pivot)

            // dishGroup — the whole assembly that spins around Y
            let dishGroup = Entity()
            dishGroup.position = [0, 0.12, 0]
            turretGroup.addChild(dishGroup)

            // Dish face — flat rectangular panel tilted ~50° from horizontal (faces forward+upward)
            var faceMat = SceneRenderer.surfaceMaterial!
            faceMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.62, green: 0.63, blue: 0.65, alpha: 1))
            let dishFace = Entity()
            dishFace.components.set(ModelComponent(
                mesh: MeshResource.generateBox(width: 0.34, height: 0.26, depth: 0.025),
                materials: [faceMat]))
            // Tilt the face so it points forward (+Z) and up — rotate -50° around X
            dishFace.orientation = simd_quatf(angle: -.pi * 0.28, axis: [1, 0, 0])
            dishFace.position = [0, 0.08, 0.02]
            dishGroup.addChild(dishFace)

            // Structural frame bars on the back of the dish (children of dishFace so they match tilt)
            var frameMat = SceneRenderer.surfaceMaterial!
            frameMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.28, green: 0.30, blue: 0.28, alpha: 1))
            let frameH = Entity()  // horizontal bar
            frameH.components.set(ModelComponent(
                mesh: MeshResource.generateBox(width: 0.31, height: 0.018, depth: 0.015),
                materials: [frameMat]))
            frameH.position = [0, 0, -0.022]
            dishFace.addChild(frameH)
            let frameV = Entity()  // vertical bar
            frameV.components.set(ModelComponent(
                mesh: MeshResource.generateBox(width: 0.018, height: 0.23, depth: 0.015),
                materials: [frameMat]))
            frameV.position = [0, 0, -0.022]
            dishFace.addChild(frameV)

            // Feed horn arm — thin cylinder extending forward (+Z) from dish face centre
            // Rotating -90° around X maps the cylinder's Y axis → +Z, so it extends forward
            var armMat = SceneRenderer.surfaceMaterial!
            armMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.22, green: 0.22, blue: 0.25, alpha: 1))
            let arm = Entity()
            arm.components.set(ModelComponent(
                mesh: MeshResource.generateCylinder(height: 0.16, radius: 0.012),
                materials: [armMat]))
            arm.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            arm.position = [0, 0, 0.09]   // arm centre sits 0.09 in front of dish face
            dishFace.addChild(arm)

            // Feed horn head — small box at the arm tip
            var hornMat = SceneRenderer.surfaceMaterial!
            hornMat.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
            let horn = Entity()
            horn.components.set(ModelComponent(
                mesh: MeshResource.generateBox(width: 0.045, height: 0.045, depth: 0.06),
                materials: [hornMat]))
            horn.position = [0, 0, 0.17]   // at the focal point, beyond arm tip
            dishFace.addChild(horn)

            dishEntities[tower.id] = dishGroup
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

        var material = SceneRenderer.surfaceMaterial!
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
        var domeMaterial = SceneRenderer.surfaceMaterial!
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

        if tower.type == .targeting, let dish = dishEntities[tower.id] {
            let period = Double.pi * 2.0 / 1.5
            let t = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            let spinAngle = Float(t * 1.5)
            // dishGroup spins around Y; the dish face tilt is baked into its child entity
            dish.orientation = simd_quatf(angle: spinAngle, axis: [0, 1, 0])
        }
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
        var material = SceneRenderer.surfaceMaterial!
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
        var mat = SceneRenderer.surfaceMaterial!
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
        var mat = SceneRenderer.surfaceMaterial!
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
        var material = SceneRenderer.watercolorMaterial!

        switch enemy.enemyType {
        case .boss:
            mesh = MeshResource.generateBox(width: radius * 3, height: radius * 4, depth: radius * 3, cornerRadius: radius * 0.3)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.6, green: 0.1, blue: 0.15, alpha: 1))
        case .superExploder:
            // Larger, darker orange-red box
            mesh = MeshResource.generateBox(width: radius * 3.0, height: radius * 3.0, depth: radius * 3.0, cornerRadius: radius * 0.25)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.85, green: 0.1, blue: 0.0, alpha: 1))
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
        case .superHopper:
            // Larger, darker green sphere
            mesh = MeshResource.generateSphere(radius: radius * 1.5)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.05, green: 0.55, blue: 0.1, alpha: 1))
        case .hopper:
            // Slightly flattened sphere — lime green
            mesh = MeshResource.generateSphere(radius: radius * 1.1)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.2, green: 0.85, blue: 0.25, alpha: 1))
        case .basic:
            mesh = MeshResource.generateSphere(radius: radius)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        case .hive:
            mesh = MeshResource.generateSphere(radius: radius * 2.5)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.45, green: 0.1, blue: 0.65, alpha: 1))
        case .mirroid:
            mesh = MeshResource.generateSphere(radius: radius * 2)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)) // placeholder, overridden below
        case .wisp:
            mesh = MeshResource.generateSphere(radius: radius * 0.9)
            material.baseColor = CustomMaterial.BaseColor(tint: .init(red: 0.5, green: 0.85, blue: 1.0, alpha: 1))
        }

        let entity = Entity()

        if enemy.enemyType == .mirroid {
            var pbr = PhysicallyBasedMaterial()
            pbr.baseColor = .init(tint: .init(red: 0.85, green: 0.9, blue: 0.95, alpha: 1))
            pbr.metallic = .init(floatLiteral: 1.0)
            pbr.roughness = .init(floatLiteral: 0.05)
            entity.components.set(ModelComponent(mesh: mesh, materials: [pbr]))
        } else {
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        }
        let collisionRadius: Float
        switch enemy.enemyType {
        case .basic:         collisionRadius = radius
        case .hopper:        collisionRadius = radius * 1.1
        case .tank:          collisionRadius = radius * 2
        case .fastTank:      collisionRadius = radius * 2
        case .shield:        collisionRadius = radius * 1.5
        case .superHopper:   collisionRadius = radius * 1.5
        case .boss:          collisionRadius = radius * 2
        case .exploder:      collisionRadius = radius * 1.5
        case .superExploder: collisionRadius = radius * 2
        case .hive:          collisionRadius = radius * 2.5
        case .mirroid:       collisionRadius = radius * 2
        case .wisp:          collisionRadius = radius * 0.9
        }
        entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: collisionRadius)]))
        entity.components.set(InputTargetComponent())

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

        // Apply incremental rolling rotation each frame
        let dAngle = enemy.rollDeltaAngle
        if dAngle > 0.0001 {
            let axis = enemy.rollAxis
            let axisLen = simd_length(axis)
            if axisLen > 0.001 {
                let deltaRot = simd_quatf(angle: dAngle, axis: axis / axisLen)
                entity.orientation = deltaRot * entity.orientation
            }
        }
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
        let isFB = projectile.burnOnImpact
        let mesh = MeshResource.generateSphere(radius: isFB ? 0.13 : 0.05)
        var material = SceneRenderer.surfaceMaterial!
        material.baseColor = CustomMaterial.BaseColor(tint: isFB
            ? .init(red: 1.0, green: 0.35, blue: 0.0, alpha: 1)
            : .init(red: 1.0, green: 0.9, blue: 0.3, alpha: 1))

        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = projectile.origin

        if isFB {
            var trail = ParticleEmitterComponent()
            trail.emitterShape = .point
            trail.speed = 1
            trail.speedVariation = 0.8
            trail.mainEmitter.birthRate = 150
            trail.mainEmitter.lifeSpan = 0.5
            trail.mainEmitter.lifeSpanVariation = 0.15
            trail.mainEmitter.size = 0.2
            trail.mainEmitter.sizeMultiplierAtEndOfLifespan = 5.0
            trail.mainEmitter.sizeVariation = 0.04
            trail.mainEmitter.spreadingAngle = 0.5
            trail.mainEmitter.color = .evolving(
                start: .single(.init(red: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)),
                end:   .single(.init(red: 1.0, green: 0.15, blue: 0.0, alpha: 0.0))
            )
            trail.mainEmitter.blendMode = .additive
            trail.timing = .once(warmUp: 0.5, emit: .init(duration: 60))

            // Orient emitter so +Y faces backward (toward the tower that fired)
            let trailEntity = Entity()
            let travelDir = projectile.target - projectile.origin
            let len = simd_length(travelDir)
            if len > 0.001 {
                let backward = -(travelDir / len)
                trailEntity.orientation = simd_quatf(from: [0, 1, 0], to: backward)
            }
            trailEntity.components.set(trail)
            entity.addChild(trailEntity)
        }

        content.add(entity)
        projectileEntities[projectile.id] = entity
    }

    func createFireballExplosion(at position: SIMD3<Float>) {
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
            end:   .single(.init(red: 1.0, green: 0.1, blue: 0.0, alpha: 0.0))
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
        dishEntities.removeValue(forKey: id)
    }

    func moveTowerEntity(id: UUID, to coord: HexCoord, cellHeight: Float, spacing: Float) {
        guard let entity = towerEntities[id] else { return }
        let pos = coord.worldPosition(spacing: spacing)
        entity.position = [pos.x, cellHeight, pos.y]
    }

    func rebuildBaseTower(cellHeight: Float, position: SIMD2<Float>) {
        baseTowerRoot?.removeFromParent()
        baseTowerRoot = nil
        baseTowerBlocks.removeAll()
        createBaseTower(cellHeight: cellHeight, position: position)
    }

    // MARK: - Dynamic Terrain

    /// Adds a single terrain cell entity to the scene. Call after adding the cell to the hex grid.
    func addTerrainCell(_ cell: HexCell, spacing: Float, hexRadius: Float) {
        guard let content else { return }
        let mesh = HexMeshGenerator.generate(radius: hexRadius, height: cell.height, cornerRadius: 0.08)
        let t = max(0, min(1, cell.height))
        var material = SceneRenderer.surfaceMaterial!
        let tint: SimpleMaterial.Color
        switch cell.terrainType {
        case .grass:
            tint = colorForHeight(t, isPath: false)
        case .rock:
            let v = CGFloat(0.44 + 0.14 * t)
            tint = SimpleMaterial.Color(red: v, green: v, blue: v + 0.03, alpha: 1)
        case .gold:
            tint = SimpleMaterial.Color(red: CGFloat(0.70 + 0.12 * t),
                                        green: CGFloat(0.56 + 0.10 * t),
                                        blue: CGFloat(0.14), alpha: 1)
        }
        material.baseColor = CustomMaterial.BaseColor(tint: tint)
        let pos = cell.coord.worldPosition(spacing: spacing)
        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: [hexRadius * 2, cell.height, hexRadius * 2])]))
        entity.components.set(InputTargetComponent())
        entity.position = [pos.x, cell.height / 2, pos.y]
        entity.scale = [0.1, 0.1, 0.1]
        content.add(entity)
        // Animate from 1/10 scale to full size over 0.25 seconds
        let target = Transform(scale: [1, 1, 1], rotation: entity.transform.rotation,
                               translation: entity.transform.translation)
        entity.move(to: target, relativeTo: nil, duration: 0.25, timingFunction: .easeOut)
        entityMap[cell.coord] = entity
    }

    /// Adds a path or start cell entity to the scene (for dynamically grown branch paths).
    func addPathCell(_ cell: HexCell, spacing: Float, hexRadius: Float) {
        guard let content else { return }
        let mesh = HexMeshGenerator.generate(radius: hexRadius, height: cell.height, cornerRadius: 0.08)
        var material = SceneRenderer.surfaceMaterial!
        let tint: SimpleMaterial.Color
        if cell.type == .start {
            tint = SimpleMaterial.Color(red: 0.2, green: 0.6, blue: 0.25, alpha: 1)
        } else {
            let t = max(0, min(1, cell.height))
            tint = colorForHeight(t, isPath: true)
        }
        material.baseColor = CustomMaterial.BaseColor(tint: tint)
        let pos = cell.coord.worldPosition(spacing: spacing)
        let entity = Entity()
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: [hexRadius * 2, cell.height, hexRadius * 2])]))
        entity.components.set(InputTargetComponent())
        entity.position = [pos.x, cell.height / 2, pos.y]
        entity.scale = [0.1, 0.1, 0.1]
        content.add(entity)
        let target = Transform(scale: [1, 1, 1], rotation: entity.transform.rotation,
                               translation: entity.transform.translation)
        entity.move(to: target, relativeTo: nil, duration: 0.25, timingFunction: .easeOut)
        entityMap[cell.coord] = entity
    }

    /// Removes a terrain cell entity from the scene.
    func removeTerrainCell(at coord: HexCoord) {
        entityMap[coord]?.removeFromParent()
        entityMap.removeValue(forKey: coord)
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
