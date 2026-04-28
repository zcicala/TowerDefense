//
//  HexMeshGenerator.swift
//  TestGame
//

import RealityKit

/// Pure geometry: generates rounded hexagonal prism meshes.
enum HexMeshGenerator {
    static func generate(radius R: Float, height H: Float, cornerRadius r: Float) -> MeshResource {
        let halfH = H / 2
        let nSeg = 4
        let Ri = R - 2 * r / sqrt(3)
        let Hi = halfH - r

        let angles: [Float] = (0..<6).map { Float($0) * .pi / 3 }
        let faceAngles: [Float] = (0..<6).map { Float($0) * .pi / 3 + .pi / 6 }
        let innerVerts: [SIMD2<Float>] = angles.map { SIMD2<Float>(Ri * cos($0), Ri * sin($0)) }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
            indices.append(contentsOf: [a, b, c, b, d, c])
        }

        // === TOP FACE ===
        let topCenter = UInt32(positions.count)
        positions.append([0, halfH, 0])
        normals.append([0, 1, 0])
        for v in innerVerts {
            positions.append([v.x, halfH, v.y])
            normals.append([0, 1, 0])
        }
        for i in 0..<6 {
            indices.append(contentsOf: [topCenter, topCenter + UInt32((i + 1) % 6) + 1, topCenter + UInt32(i) + 1])
        }

        // === BOTTOM FACE ===
        let botCenter = UInt32(positions.count)
        positions.append([0, -halfH, 0])
        normals.append([0, -1, 0])
        for v in innerVerts {
            positions.append([v.x, -halfH, v.y])
            normals.append([0, -1, 0])
        }
        for i in 0..<6 {
            indices.append(contentsOf: [botCenter, botCenter + UInt32(i) + 1, botCenter + UInt32((i + 1) % 6) + 1])
        }

        // === 6 FLAT SIDE FACES ===
        for i in 0..<6 {
            let next = (i + 1) % 6
            let fn = SIMD2<Float>(cos(faceAngles[i]), sin(faceAngles[i]))
            let base = UInt32(positions.count)
            let n3 = SIMD3<Float>(fn.x, 0, fn.y)

            positions.append([innerVerts[i].x + r * fn.x, Hi, innerVerts[i].y + r * fn.y])
            positions.append([innerVerts[next].x + r * fn.x, Hi, innerVerts[next].y + r * fn.y])
            positions.append([innerVerts[i].x + r * fn.x, -Hi, innerVerts[i].y + r * fn.y])
            positions.append([innerVerts[next].x + r * fn.x, -Hi, innerVerts[next].y + r * fn.y])
            normals.append(contentsOf: [n3, n3, n3, n3])

            quad(base, base + 1, base + 2, base + 3)
        }

        // === 6 TOP EDGE BEVELS ===
        for i in 0..<6 {
            let next = (i + 1) % 6
            let fn = SIMD2<Float>(cos(faceAngles[i]), sin(faceAngles[i]))
            let base = UInt32(positions.count)

            for seg in 0...nSeg {
                let alpha = Float(seg) * (.pi / 2) / Float(nSeg)
                let cosA = cos(alpha), sinA = sin(alpha)
                let offset = r * cosA
                let y = Hi + r * sinA
                let n3 = SIMD3<Float>(cosA * fn.x, sinA, cosA * fn.y)

                positions.append([innerVerts[i].x + offset * fn.x, y, innerVerts[i].y + offset * fn.y])
                normals.append(n3)
                positions.append([innerVerts[next].x + offset * fn.x, y, innerVerts[next].y + offset * fn.y])
                normals.append(n3)
            }
            for seg in 0..<nSeg {
                let row = base + UInt32(seg) * 2
                let nextRow = base + UInt32(seg + 1) * 2
                quad(nextRow, nextRow + 1, row, row + 1)
            }
        }

        // === 6 BOTTOM EDGE BEVELS ===
        for i in 0..<6 {
            let next = (i + 1) % 6
            let fn = SIMD2<Float>(cos(faceAngles[i]), sin(faceAngles[i]))
            let base = UInt32(positions.count)

            for seg in 0...nSeg {
                let alpha = Float(seg) * (.pi / 2) / Float(nSeg)
                let cosA = cos(alpha), sinA = sin(alpha)
                let offset = r * cosA
                let y = -Hi - r * sinA
                let n3 = SIMD3<Float>(cosA * fn.x, -sinA, cosA * fn.y)

                positions.append([innerVerts[i].x + offset * fn.x, y, innerVerts[i].y + offset * fn.y])
                normals.append(n3)
                positions.append([innerVerts[next].x + offset * fn.x, y, innerVerts[next].y + offset * fn.y])
                normals.append(n3)
            }
            for seg in 0..<nSeg {
                let row = base + UInt32(seg) * 2
                let nextRow = base + UInt32(seg + 1) * 2
                quad(row, row + 1, nextRow, nextRow + 1)
            }
        }

        // === 6 VERTICAL EDGE BEVELS ===
        for i in 0..<6 {
            let startAngle = angles[i] - .pi / 6
            let endAngle = angles[i] + .pi / 6
            let base = UInt32(positions.count)

            for seg in 0...nSeg {
                let theta = startAngle + Float(seg) * (endAngle - startAngle) / Float(nSeg)
                let n3 = SIMD3<Float>(cos(theta), 0, sin(theta))
                let ox = r * cos(theta), oz = r * sin(theta)

                positions.append([innerVerts[i].x + ox, Hi, innerVerts[i].y + oz])
                normals.append(n3)
                positions.append([innerVerts[i].x + ox, -Hi, innerVerts[i].y + oz])
                normals.append(n3)
            }
            for seg in 0..<nSeg {
                let col = base + UInt32(seg) * 2
                let nextCol = base + UInt32(seg + 1) * 2
                quad(col, nextCol, col + 1, nextCol + 1)
            }
        }

        // === 12 CORNER PATCHES (6 top + 6 bottom) ===
        let stride = UInt32(nSeg + 1)
        for i in 0..<6 {
            let startAngle = angles[i] - .pi / 6
            let endAngle = angles[i] + .pi / 6
            let cx = innerVerts[i].x, cz = innerVerts[i].y

            let topBase = UInt32(positions.count)
            for ai in 0...nSeg {
                let alpha = Float(ai) * (.pi / 2) / Float(nSeg)
                let cosA = cos(alpha), sinA = sin(alpha)
                for bi in 0...nSeg {
                    let theta = startAngle + Float(bi) * (endAngle - startAngle) / Float(nSeg)
                    let nx = cosA * cos(theta), ny = sinA, nz = cosA * sin(theta)
                    positions.append([cx + r * nx, Hi + r * ny, cz + r * nz])
                    normals.append([nx, ny, nz])
                }
            }
            for ai in 0..<nSeg {
                for bi in 0..<nSeg {
                    let tl = topBase + UInt32(ai) * stride + UInt32(bi)
                    quad(tl + stride, tl + stride + 1, tl, tl + 1)
                }
            }

            let botBase = UInt32(positions.count)
            for ai in 0...nSeg {
                let alpha = Float(ai) * (.pi / 2) / Float(nSeg)
                let cosA = cos(alpha), sinA = sin(alpha)
                for bi in 0...nSeg {
                    let theta = startAngle + Float(bi) * (endAngle - startAngle) / Float(nSeg)
                    let nx = cosA * cos(theta), ny = -sinA, nz = cosA * sin(theta)
                    positions.append([cx + r * nx, -Hi + r * ny, cz + r * nz])
                    normals.append([nx, ny, nz])
                }
            }
            for ai in 0..<nSeg {
                for bi in 0..<nSeg {
                    let tl = botBase + UInt32(ai) * stride + UInt32(bi)
                    quad(tl, tl + 1, tl + stride, tl + stride + 1)
                }
            }
        }

        var descriptor = MeshDescriptor(name: "roundedHexPrism")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        return try! MeshResource.generate(from: [descriptor])
    }
}
