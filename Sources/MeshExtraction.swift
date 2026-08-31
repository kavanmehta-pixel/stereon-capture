import ARKit
import simd

/// Accumulates ARMeshAnchor geometry into one indexed mesh, keeping only
/// triangles whose three vertices all fall inside the crop box.
///
/// Clipping and output are done in BOX-LOCAL space (the box's yaw removed, its
/// ground centre at the origin), so the resulting AABB is a true oriented
/// bounding box rather than a world-axis one.
struct MergedMesh {
    var vertices: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    mutating func append(anchor: ARMeshAnchor,
                         boxCenter: SIMD3<Float>,
                         halfX: Float,
                         halfZ: Float,
                         height: Float,
                         floorTrim: Float,
                         yaw: Float) {
        let geometry = anchor.geometry
        let localVertices = geometry.vertices.asFloat3Array()
        let localNormals = geometry.normals.asFloat3Array()
        let faceIndices = geometry.faces.asIndexArray()
        guard !localVertices.isEmpty, !faceIndices.isEmpty else { return }

        let transform = anchor.transform
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )

        // World -> box-local is a rotation about Y by -yaw, after recentring.
        let cy = cos(yaw), sy = sin(yaw)
        func toBoxLocal(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let dx = p.x - boxCenter.x, dz = p.z - boxCenter.z
            return SIMD3<Float>(dx * cy - dz * sy, p.y - boxCenter.y, dx * sy + dz * cy)
        }
        func rotateToBoxLocal(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(v.x * cy - v.z * sy, v.y, v.x * sy + v.z * cy)
        }

        var boxVertices = [SIMD3<Float>](repeating: .zero, count: localVertices.count)
        var inside = [Bool](repeating: false, count: localVertices.count)
        for i in localVertices.indices {
            let v = localVertices[i]
            let w4 = transform * SIMD4<Float>(v.x, v.y, v.z, 1)
            let b = toBoxLocal(SIMD3<Float>(w4.x, w4.y, w4.z))
            boxVertices[i] = b
            inside[i] = abs(b.x) <= halfX && abs(b.z) <= halfZ
                && b.y >= floorTrim && b.y <= height
        }

        var remap = [UInt32: UInt32]()
        var face = 0
        while face + 2 < faceIndices.count {
            let a = faceIndices[face], b = faceIndices[face + 1], c = faceIndices[face + 2]
            face += 3
            guard Int(a) < inside.count, Int(b) < inside.count, Int(c) < inside.count else { continue }
            guard inside[Int(a)], inside[Int(b)], inside[Int(c)] else { continue }
            for original in [a, b, c] {
                if let mapped = remap[original] {
                    indices.append(mapped)
                } else {
                    let mapped = UInt32(vertices.count)
                    remap[original] = mapped
                    vertices.append(boxVertices[Int(original)])
                    let idx = Int(original)
                    let n = idx < localNormals.count ? localNormals[idx] : SIMD3<Float>(0, 1, 0)
                    normals.append(simd_normalize(rotateToBoxLocal(rotation * n)))
                    indices.append(mapped)
                }
            }
        }
    }
}

extension ARGeometrySource {
    func asFloat3Array() -> [SIMD3<Float>] {
        guard format == .float3 else { return [] }
        var out = [SIMD3<Float>]()
        out.reserveCapacity(count)
        let base = buffer.contents().advanced(by: offset)
        for i in 0..<count {
            let p = base.advanced(by: i * stride).assumingMemoryBound(to: (Float, Float, Float).self).pointee
            out.append(SIMD3<Float>(p.0, p.1, p.2))
        }
        return out
    }
}

extension ARGeometryElement {
    func asIndexArray() -> [UInt32] {
        guard indexCountPerPrimitive == 3 else { return [] }
        let total = count * 3
        var out = [UInt32]()
        out.reserveCapacity(total)
        let base = buffer.contents()
        if bytesPerIndex == 4 {
            let p = base.assumingMemoryBound(to: UInt32.self)
            for i in 0..<total { out.append(p[i]) }
        } else if bytesPerIndex == 2 {
            let p = base.assumingMemoryBound(to: UInt16.self)
            for i in 0..<total { out.append(UInt32(p[i])) }
        }
        return out
    }
}
