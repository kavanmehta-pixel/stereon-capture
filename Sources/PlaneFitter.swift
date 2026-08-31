import simd

/// Pulls the flat surfaces out of the item's point cloud by RANSAC, so a
/// laptop comes back as two panels meeting at its hinge angle and a crate as
/// its visible faces — real geometry rather than a box drawn around it.
///
/// Deliberately not a convex hull: every panel here is supported by measured
/// inliers and can be reported with a confidence, which matters when the
/// output is evidence rather than a picture.
struct Panel {
    var normal: SIMD3<Float>
    var centre: SIMD3<Float>
    /// four corners of the fitted rectangle, wound consistently
    var corners: [SIMD3<Float>]
    var inliers: Int
    var area: Float

    /// Angle to another panel, measured between the surfaces themselves
    /// (a flat sheet reads 180°, a right-angled corner 90°).
    func angle(to other: Panel) -> Float {
        let d = max(-1, min(1, simd_dot(normal, other.normal)))
        return 180 - acos(abs(d)) * 180 / .pi
    }
}

enum PlaneFitter {

    static func panels(from points: [SIMD3<Float>],
                       maxPanels: Int = 4,
                       tolerance: Float = 0.012) -> [Panel] {
        var remaining = points
        var found = [Panel]()
        var rng = SplitMix(seed: 0x5EED_1234)

        for _ in 0..<maxPanels {
            guard remaining.count >= 30 else { break }
            guard let (normal, point, inlierIdx) = ransacPlane(remaining, tolerance: tolerance, rng: &rng) else { break }
            // a panel has to be a real share of what's left, not a lucky triple
            guard inlierIdx.count >= max(25, remaining.count / 8) else { break }

            let inliers = inlierIdx.map { remaining[$0] }
            let refined = refine(inliers, seedNormal: normal, seedPoint: point)
            if let panel = rectangle(for: inliers, normal: refined.normal, centre: refined.centre) {
                found.append(panel)
            }
            let drop = Set(inlierIdx)
            remaining = remaining.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
        }
        return found.sorted { $0.area > $1.area }
    }

    // MARK: - RANSAC

    private static func ransacPlane(_ pts: [SIMD3<Float>],
                                    tolerance: Float,
                                    rng: inout SplitMix) -> (SIMD3<Float>, SIMD3<Float>, [Int])? {
        var bestCount = 0
        var best: (SIMD3<Float>, SIMD3<Float>)?
        let trials = 220

        for _ in 0..<trials {
            let i = rng.index(pts.count), j = rng.index(pts.count), k = rng.index(pts.count)
            guard i != j, j != k, i != k else { continue }
            let n = simd_cross(pts[j] - pts[i], pts[k] - pts[i])
            let len = simd_length(n)
            guard len > 1e-6 else { continue }
            let unit = n / len
            let d = simd_dot(unit, pts[i])

            var count = 0
            for p in pts where abs(simd_dot(unit, p) - d) <= tolerance { count += 1 }
            if count > bestCount { bestCount = count; best = (unit, pts[i]) }
        }

        guard let (normal, point) = best else { return nil }
        let d = simd_dot(normal, point)
        var idx = [Int]()
        for (n, p) in pts.enumerated() where abs(simd_dot(normal, p) - d) <= tolerance { idx.append(n) }
        return (normal, point, idx)
    }

    /// Least-squares plane through the inliers: the normal is the direction of
    /// least variance, found by power-iterating on (trace·I − covariance).
    private static func refine(_ pts: [SIMD3<Float>],
                               seedNormal: SIMD3<Float>,
                               seedPoint: SIMD3<Float>) -> (normal: SIMD3<Float>, centre: SIMD3<Float>) {
        let n = Float(pts.count)
        var centre = SIMD3<Float>.zero
        for p in pts { centre += p }
        centre /= n

        var xx: Float = 0, xy: Float = 0, xz: Float = 0, yy: Float = 0, yz: Float = 0, zz: Float = 0
        for p in pts {
            let d = p - centre
            xx += d.x*d.x; xy += d.x*d.y; xz += d.x*d.z
            yy += d.y*d.y; yz += d.y*d.z; zz += d.z*d.z
        }
        let cov = simd_float3x3(SIMD3(xx, xy, xz), SIMD3(xy, yy, yz), SIMD3(xz, yz, zz))
        let trace = xx + yy + zz
        guard trace > 1e-9 else { return (seedNormal, centre) }
        let m = simd_float3x3(diagonal: SIMD3(repeating: trace)) - cov

        var v = seedNormal
        for _ in 0..<40 {
            let next = m * v
            let len = simd_length(next)
            guard len > 1e-12 else { break }
            v = next / len
        }
        return (simd_length(v) > 0.5 ? v : seedNormal, centre)
    }

    /// Tightest in-plane rectangle around the inliers, returned as 4 corners.
    private static func rectangle(for pts: [SIMD3<Float>],
                                  normal: SIMD3<Float>,
                                  centre: SIMD3<Float>) -> Panel? {
        guard pts.count >= 3 else { return nil }
        // any two axes spanning the plane
        let helper: SIMD3<Float> = abs(normal.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(normal, helper))
        let v = simd_normalize(simd_cross(normal, u))

        var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        for p in pts {
            let d = p - centre
            let a = simd_dot(d, u), b = simd_dot(d, v)
            minU = min(minU, a); maxU = max(maxU, a)
            minV = min(minV, b); maxV = max(maxV, b)
        }
        let w = maxU - minU, h = maxV - minV
        guard w > 0.01, h > 0.01 else { return nil }

        let corners = [
            centre + u * minU + v * minV,
            centre + u * maxU + v * minV,
            centre + u * maxU + v * maxV,
            centre + u * minU + v * maxV,
        ]
        return Panel(normal: normal, centre: centre, corners: corners,
                     inliers: pts.count, area: w * h)
    }
}

/// Deterministic RNG so the same cloud always yields the same panels — a scan
/// that changes shape between runs is not evidence.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(max(1, count))) }
}
