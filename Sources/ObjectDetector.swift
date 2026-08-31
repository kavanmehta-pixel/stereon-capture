import CoreVideo
import Vision
import simd

/// A binary silhouette of the item, in upright-image normalized space.
struct ObjectMask {
    let width: Int
    let height: Int
    private let values: [UInt8]
    let coverage: Double

    init?(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var out = [UInt8](repeating: 0, count: w * h)
        switch format {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = UInt8(max(0, min(255, row[x] * 255))) }
            }
        default:
            return nil
        }

        var lit = 0
        for v in out where v > 128 { lit += 1 }
        self.width = w
        self.height = h
        self.values = out
        self.coverage = Double(lit) / Double(w * h)
    }

    /// The silhouette's extreme points in eight directions — the corners and
    /// edge tips a person would naturally aim at. Returned in normalized
    /// upright-image space.
    func extremes() -> [CGPoint] {
        let directions: [(Double, Double)] = [
            (0, -1), (0.707, -0.707), (1, 0), (0.707, 0.707),
            (0, 1), (-0.707, 0.707), (-1, 0), (-0.707, -0.707),
        ]
        var bestScore = [Double](repeating: -.greatestFiniteMagnitude, count: directions.count)
        var bestPoint = [CGPoint](repeating: .zero, count: directions.count)
        var found = false

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where values[y * width + x] > 128 {
                found = true
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                for (i, d) in directions.enumerated() {
                    let score = d.0 * u + d.1 * v
                    if score > bestScore[i] {
                        bestScore[i] = score
                        bestPoint[i] = CGPoint(x: u, y: v)
                    }
                }
            }
        }
        guard found else { return [] }

        // collapse near-duplicates (a smooth blob hits the same pixel twice)
        var unique = [CGPoint]()
        for p in bestPoint where !unique.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 0.04 }) {
            unique.append(p)
        }
        return unique
    }

    /// `u`,`v` are normalized (0…1) in upright-image space, v measured from the top.
    func contains(u: Double, v: Double) -> Bool {
        guard u >= 0, u < 1, v >= 0, v < 1 else { return false }
        let x = min(width - 1, max(0, Int(u * Double(width))))
        let y = min(height - 1, max(0, Int(v * Double(height))))
        return values[y * width + x] > 128
    }
}

/// Isolates the item the user is aiming at using Vision's foreground instance
/// segmentation — the engine behind "lift subject from background". Needs no
/// LiDAR, so it is what gives a non-Pro iPhone real object awareness: the
/// silhouette tells us which ARKit feature points belong to the ITEM rather
/// than to the floor it stands on or the wall behind it.
enum ObjectDetector {
    /// Runs segmentation on a camera frame and returns the silhouette of the
    /// instance under `reticle` (normalized, upright-image space), falling back
    /// to the union of all foreground instances.
    static func detect(in pixelBuffer: CVPixelBuffer, reticle: CGPoint) -> ObjectMask? {
        // The AR capture buffer is camera-native (landscape); .right makes it
        // upright for a portrait app, matching the space we project points into.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        // Prefer the single instance the user is actually aiming at.
        for index in observation.allInstances.prefix(4) {
            guard let buffer = try? observation.generateMask(forInstances: IndexSet(integer: index)),
                  let mask = ObjectMask(pixelBuffer: buffer) else { continue }
            if mask.contains(u: Double(reticle.x), v: Double(reticle.y)) { return mask }
        }

        guard !observation.allInstances.isEmpty,
              let buffer = try? observation.generateMask(forInstances: observation.allInstances) else { return nil }
        return ObjectMask(pixelBuffer: buffer)
    }
}

// MARK: - Several items in one pass
//
// HONEST BOUNDARY. This finds items that are SEPARATED and individually
// visible — staged across a dock floor, or spaced along an open deck. It is
// not, and cannot be, a way to dimension a packed stack: an occluded face has
// no recoverable geometry, so nothing downstream would have anything to
// measure. Segmentation happily returns an instance for a half-hidden carton;
// the point counts are what expose it, and the flow makes the operator look.

/// One foreground instance: its silhouette plus where it sits in the frame,
/// all in normalized upright-image space (v measured from the top).
struct DetectedInstance {
    let index: Int
    let mask: ObjectMask
    /// Centre of mass of the silhouette, not the centre of its bounding box —
    /// an L-shaped item's bbox centre can fall outside the item entirely.
    let centroid: CGPoint
    let bbox: CGRect
}

extension ObjectMask {
    /// Centroid and bounding box of the silhouette. Nil when nothing is lit.
    func footprint() -> (centroid: CGPoint, bbox: CGRect)? {
        var sumX = 0.0, sumY = 0.0, count = 0.0
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where values[y * width + x] > 128 {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                sumX += u; sumY += v; count += 1
                minX = min(minX, u); maxX = max(maxX, u)
                minY = min(minY, v); maxY = max(maxY, v)
            }
        }
        guard count > 0 else { return nil }
        return (CGPoint(x: sumX / count, y: sumY / count),
                CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}

extension ObjectDetector {
    /// Every foreground instance in the frame, each with its own silhouette.
    /// The instance count is whatever Vision found — the SDK documents no cap,
    /// so nothing here imposes one either.
    static func detectAll(in pixelBuffer: CVPixelBuffer) -> [DetectedInstance] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return [] }

        var found = [DetectedInstance]()
        for index in observation.allInstances {
            guard let buffer = try? observation.generateMask(forInstances: IndexSet(integer: index)),
                  let mask = ObjectMask(pixelBuffer: buffer),
                  let shape = mask.footprint() else { continue }
            found.append(DetectedInstance(index: index, mask: mask,
                                          centroid: shape.centroid, bbox: shape.bbox))
        }
        // Left to right across the frame: the order an operator walking a row
        // of freight would work it.
        return found.sorted {
            $0.centroid.x == $1.centroid.x ? $0.centroid.y < $1.centroid.y : $0.centroid.x < $1.centroid.x
        }
    }
}
