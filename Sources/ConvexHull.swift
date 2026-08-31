import simd

/// 3D convex hull (QuickHull) over the corners the operator marked.
///
/// Deliberately fed a handful of clean, human-placed points rather than a
/// cloud of thousands: on small verified sets the result is exact, and every
/// face is supported by a point somebody actually aimed at. A laptop marked at
/// its base and lid comes back as the wedge it is, not a brick.
///
/// Returns nil rather than a suspect answer — the caller falls back to the
/// bounding box. A shape that is quietly wrong is worse than no shape.
enum ConvexHull {

    struct Result {
        /// flat-shaded triangle soup, ready for GLB
        var vertices: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
        var volume: Float
        var faceCount: Int
    }

    private struct Face {
        var a: Int, b: Int, c: Int
        var normal: SIMD3<Double>
        var offset: Double
        var outside: [Int] = []
        var dead = false
    }

    private static func edgeKey(_ u: Int, _ v: Int) -> Int64 {
        Int64(UInt32(bitPattern: Int32(u))) << 32 | Int64(UInt32(bitPattern: Int32(v)))
    }

    static func compute(_ input: [SIMD3<Float>]) -> Result? {
        guard input.count >= 4, input.count <= 256 else { return nil }
        let pts = input.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }

        var lo = pts[0], hi = pts[0]
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let span = simd_reduce_max(hi - lo)
        guard span > 1e-3 else { return nil }
        let eps = span * 1e-4

        guard var faces = initialTetrahedron(pts, eps: eps) else { return nil }

        for i in 0..<pts.count {
            for f in faces.indices where simd_dot(faces[f].normal, pts[i]) - faces[f].offset > eps {
                faces[f].outside.append(i)
                break
            }
        }

        var iterations = 0
        while iterations < 5_000 {
            iterations += 1
            guard let seed = faces.indices.first(where: { !faces[$0].dead && !faces[$0].outside.isEmpty }) else { break }

            var apex = faces[seed].outside[0]
            var best = -Double.greatestFiniteMagnitude
            for i in faces[seed].outside {
                let d = simd_dot(faces[seed].normal, pts[i]) - faces[seed].offset
                if d > best { best = d; apex = i }
            }
            let p = pts[apex]

            var visible = [Int]()
            for f in faces.indices where !faces[f].dead {
                if simd_dot(faces[f].normal, p) - faces[f].offset > eps { visible.append(f) }
            }
            if visible.isEmpty { faces[seed].outside.removeAll(); continue }

            var directed = Set<Int64>()
            for f in visible {
                directed.insert(edgeKey(faces[f].a, faces[f].b))
                directed.insert(edgeKey(faces[f].b, faces[f].c))
                directed.insert(edgeKey(faces[f].c, faces[f].a))
            }
            var horizon = [(Int, Int)]()
            for f in visible {
                for (u, v) in [(faces[f].a, faces[f].b), (faces[f].b, faces[f].c), (faces[f].c, faces[f].a)]
                where !directed.contains(edgeKey(v, u)) { horizon.append((u, v)) }
            }
            guard !horizon.isEmpty else { faces[seed].outside.removeAll(); continue }

            var orphans = [Int]()
            for f in visible {
                orphans.append(contentsOf: faces[f].outside)
                faces[f].outside.removeAll()
                faces[f].dead = true
            }

            let firstNew = faces.count
            for (u, v) in horizon {
                // a horizon edge that cannot form a real triangle means the
                // topology is about to tear — bail rather than emit a hole
                guard let face = makeFace(u, v, apex, pts: pts, eps: eps) else { return nil }
                faces.append(face)
            }

            for i in orphans where i != apex {
                for f in firstNew..<faces.count where simd_dot(faces[f].normal, pts[i]) - faces[f].offset > eps {
                    faces[f].outside.append(i)
                    break
                }
            }
        }

        let live = faces.filter { !$0.dead }
        guard live.count >= 4 else { return nil }

        // Closed-surface check. Every directed edge must appear exactly once
        // and its twin exactly once; anything else means duplicated faces or a
        // hole, and the volume would be nonsense.
        var counts = [Int64: Int]()
        for f in live {
            for (u, v) in [(f.a, f.b), (f.b, f.c), (f.c, f.a)] {
                counts[edgeKey(u, v), default: 0] += 1
            }
        }
        for f in live {
            for (u, v) in [(f.a, f.b), (f.b, f.c), (f.c, f.a)] {
                guard counts[edgeKey(u, v)] == 1, counts[edgeKey(v, u)] == 1 else { return nil }
            }
        }

        var volume = 0.0
        var vertices = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()
        for f in live {
            let a = pts[f.a], b = pts[f.b], c = pts[f.c]
            volume += simd_dot(a, simd_cross(b, c)) / 6.0
            let n = SIMD3<Float>(Float(f.normal.x), Float(f.normal.y), Float(f.normal.z))
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [input[f.a], input[f.b], input[f.c]])
            normals.append(contentsOf: [n, n, n])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        guard abs(volume) > 1e-7 else { return nil }

        return Result(vertices: vertices, normals: normals, indices: indices,
                      volume: Float(abs(volume)), faceCount: live.count)
    }

    private static func makeFace(_ a: Int, _ b: Int, _ c: Int,
                                 pts: [SIMD3<Double>], eps: Double) -> Face? {
        let n = simd_cross(pts[b] - pts[a], pts[c] - pts[a])
        let len = simd_length(n)
        guard len > eps * eps else { return nil }
        let unit = n / len
        return Face(a: a, b: b, c: c, normal: unit, offset: simd_dot(unit, pts[a]))
    }

    private static func initialTetrahedron(_ pts: [SIMD3<Double>], eps: Double) -> [Face]? {
        var minIdx = [0, 0, 0], maxIdx = [0, 0, 0]
        for i in pts.indices {
            for axis in 0..<3 {
                if pts[i][axis] < pts[minIdx[axis]][axis] { minIdx[axis] = i }
                if pts[i][axis] > pts[maxIdx[axis]][axis] { maxIdx[axis] = i }
            }
        }
        var a = 0, b = 0, bestSpan = -1.0
        for axis in 0..<3 {
            let d = simd_distance(pts[minIdx[axis]], pts[maxIdx[axis]])
            if d > bestSpan { bestSpan = d; a = minIdx[axis]; b = maxIdx[axis] }
        }
        guard bestSpan > eps else { return nil }

        var c = -1, bestC = eps
        for i in pts.indices {
            let d = simd_length(simd_cross(pts[b] - pts[a], pts[i] - pts[a])) / bestSpan
            if d > bestC { bestC = d; c = i }
        }
        guard c >= 0 else { return nil }

        let n0 = simd_normalize(simd_cross(pts[b] - pts[a], pts[c] - pts[a]))
        var d = -1, bestD = eps
        for i in pts.indices {
            let dist = abs(simd_dot(n0, pts[i] - pts[a]))
            if dist > bestD { bestD = dist; d = i }
        }
        guard d >= 0 else { return nil }

        let centroid = (pts[a] + pts[b] + pts[c] + pts[d]) / 4
        var faces = [Face]()
        for (x, y, z) in [(a, b, c), (a, c, d), (a, d, b), (b, d, c)] {
            guard var f = makeFace(x, y, z, pts: pts, eps: eps) else { return nil }
            if simd_dot(f.normal, centroid) - f.offset > 0 {
                guard let flipped = makeFace(x, z, y, pts: pts, eps: eps) else { return nil }
                f = flipped
            }
            faces.append(f)
        }
        return faces
    }
}
