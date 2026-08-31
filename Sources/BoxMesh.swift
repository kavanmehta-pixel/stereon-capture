import simd

/// Generates a closed box mesh with the floor at y=0 and the footprint centred
/// on the origin — the same convention as a cropped LiDAR scan, so both capture
/// modes export an identical coordinate frame.
enum BoxMesh {
    static func make(width: Float, depth: Float, height: Float)
        -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        let hw = width / 2, hd = depth / 2, h = height
        var vertices = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  _ normal: SIMD3<Float>) {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [a, b, c, d])
            normals.append(contentsOf: [normal, normal, normal, normal])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        let b0 = SIMD3<Float>(-hw, 0, -hd), b1 = SIMD3<Float>(hw, 0, -hd)
        let b2 = SIMD3<Float>(hw, 0, hd), b3 = SIMD3<Float>(-hw, 0, hd)
        let t0 = SIMD3<Float>(-hw, h, -hd), t1 = SIMD3<Float>(hw, h, -hd)
        let t2 = SIMD3<Float>(hw, h, hd), t3 = SIMD3<Float>(-hw, h, hd)

        quad(b0, b1, b2, b3, SIMD3(0, -1, 0))
        quad(t3, t2, t1, t0, SIMD3(0, 1, 0))
        quad(b0, t0, t1, b1, SIMD3(0, 0, -1))
        quad(b2, t2, t3, b3, SIMD3(0, 0, 1))
        quad(b3, t3, t0, b0, SIMD3(-1, 0, 0))
        quad(b1, t1, t2, b2, SIMD3(1, 0, 0))

        return (vertices, normals, indices)
    }
}
