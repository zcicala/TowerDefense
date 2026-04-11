//
//  ContentView.swift
//  TestGame
//
//  Created by Zac on 4/10/26.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    var body: some View {
        RealityView { content in
            createGameScene(content)
        }
        .realityViewCameraControls(.orbit)
    }

    fileprivate func createGameScene(_ content: any RealityViewContentProtocol) {
        guard let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return }
        let surfaceShader = CustomMaterial.SurfaceShader(named: "celSurfaceShader", in: library)

        let hexRadius: Float = 0.5 // outer radius of each hexagon
        let height: Float = 1.0
        let gap: Float = 0.05
        let gridRadius = 2 // 3 per side means center + 2 rings

        let hexMesh = generateHexPrismMesh(radius: hexRadius, height: height)

        let colors: [SimpleMaterial.Color] = [
            .systemRed, .systemBlue, .systemGreen,
            .systemOrange, .systemPurple, .systemTeal,
            .systemYellow
        ]

        var colorIndex = 0
        for q in -gridRadius...gridRadius {
            for r in -gridRadius...gridRadius {
                let s = -q - r
                guard abs(s) <= gridRadius else { continue }

                var material = try! CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
                material.baseColor = CustomMaterial.BaseColor(tint: colors[colorIndex % colors.count])
                colorIndex += 1

                // Flat-top hex positioning
                let spacing = hexRadius + gap / 2
                let x = spacing * (3.0 / 2.0) * Float(q)
                let z = spacing * (sqrt(3.0) / 2.0 * Float(q) + sqrt(3.0) * Float(r))

                let entity = Entity()
                entity.components.set(ModelComponent(mesh: hexMesh, materials: [material]))
                entity.position = [x, 0, z]
                content.add(entity)
            }
        }

        // Camera
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent())
        content.add(camera)
        camera.look(at: [0, 0, 0], from: [0, 8, 6], relativeTo: nil)
    }

    /// Generates a hexagonal prism mesh with flat top orientation.
    fileprivate func generateHexPrismMesh(radius: Float, height: Float) -> MeshResource {
        let halfH = height / 2.0
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Generate the 6 corner angles for a flat-top hexagon
        let angles: [Float] = (0..<6).map { Float($0) * (.pi / 3.0) }

        // --- Top face (normal pointing up) ---
        let topCenterIdx = UInt32(positions.count)
        positions.append([0, halfH, 0])
        normals.append([0, 1, 0])
        for angle in angles {
            positions.append([radius * cos(angle), halfH, radius * sin(angle)])
            normals.append([0, 1, 0])
        }
        for i in 0..<6 {
            let next = (i + 1) % 6
            indices.append(contentsOf: [
                topCenterIdx,
                topCenterIdx + UInt32(i) + 1,
                topCenterIdx + UInt32(next) + 1
            ])
        }

        // --- Bottom face (normal pointing down) ---
        let botCenterIdx = UInt32(positions.count)
        positions.append([0, -halfH, 0])
        normals.append([0, -1, 0])
        for angle in angles {
            positions.append([radius * cos(angle), -halfH, radius * sin(angle)])
            normals.append([0, -1, 0])
        }
        for i in 0..<6 {
            let next = (i + 1) % 6
            indices.append(contentsOf: [
                botCenterIdx,
                botCenterIdx + UInt32(next) + 1,
                botCenterIdx + UInt32(i) + 1
            ])
        }

        // --- Side faces (6 quads, each split into 2 triangles) ---
        for i in 0..<6 {
            let next = (i + 1) % 6
            let angle0 = angles[i]
            let angle1 = angles[next]

            // Outward-facing normal for this side
            let midAngle = (angle0 + angle1) / 2.0
            let normal: SIMD3<Float> = [cos(midAngle), 0, sin(midAngle)]

            let baseIdx = UInt32(positions.count)

            // Four corners of this side quad
            let topLeft: SIMD3<Float> = [radius * cos(angle0), halfH, radius * sin(angle0)]
            let topRight: SIMD3<Float> = [radius * cos(angle1), halfH, radius * sin(angle1)]
            let botLeft: SIMD3<Float> = [radius * cos(angle0), -halfH, radius * sin(angle0)]
            let botRight: SIMD3<Float> = [radius * cos(angle1), -halfH, radius * sin(angle1)]

            positions.append(contentsOf: [topLeft, topRight, botLeft, botRight])
            normals.append(contentsOf: [normal, normal, normal, normal])

            indices.append(contentsOf: [
                baseIdx, baseIdx + 2, baseIdx + 1,
                baseIdx + 1, baseIdx + 2, baseIdx + 3
            ])
        }

        var descriptor = MeshDescriptor(name: "hexPrism")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        return try! MeshResource.generate(from: [descriptor])
    }
}

#Preview {
    ContentView()
}
