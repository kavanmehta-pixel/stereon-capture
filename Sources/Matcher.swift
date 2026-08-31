import Foundation
import simd

// MARK: - Matcher identity
//
// Reported with every match so a manifest read six months from now says which
// matcher made the call. Bump this whenever the gates, sigma or the envelope
// port change in a way that would move a decision.
let matcherVersion = "dnd-v2"

/// One row of GET /api/library-lite — the match-relevant slice of a library
/// item. `l/w/h` are the item's own dims; `env*` is an explicit measured
/// envelope override; packaging/orientation drive the candidate variants.
struct LibraryItem {
    let id: String
    let sku: String
    let name: String
    let l: Float
    let w: Float
    let h: Float
    let packagingType: String
    let orientation: String
    let envL: Float?
    let envW: Float?
    let envH: Float?
    let weightKg: Double?
    let locked: Bool
    let confidence: String
    /// Created at the dock and not yet reviewed by a supervisor. Provisional
    /// items are visible in suggestions but can never auto-match — an unknown
    /// scan must not be able to bootstrap itself into an identity gate.
    let provisional: Bool

    init(id: String, sku: String, name: String,
         l: Float, w: Float, h: Float,
         packagingType: String = "none", orientation: String = "as-is",
         envL: Float? = nil, envW: Float? = nil, envH: Float? = nil,
         weightKg: Double? = nil,
         locked: Bool = false, confidence: String = "unverified",
         provisional: Bool = false) {
        self.id = id
        self.sku = sku
        self.name = name
        self.l = l
        self.w = w
        self.h = h
        self.packagingType = packagingType
        self.orientation = orientation
        self.envL = envL
        self.envW = envW
        self.envH = envH
        self.weightKg = weightKg
        self.locked = locked
        self.confidence = confidence
        self.provisional = provisional
    }
}

extension LibraryItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, sku, name, l, w, h, packagingType, orientation
        case envL, envW, envH, weightKg, locked, confidence, provisional
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            sku: try c.decodeIfPresent(String.self, forKey: .sku) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            // Tolerate a dimensionless row rather than throwing: one bad
            // record must never cost the operator the whole library. A zero
            // here is filtered out before scoring (see `usable`).
            l: try c.decodeIfPresent(Float.self, forKey: .l) ?? 0,
            w: try c.decodeIfPresent(Float.self, forKey: .w) ?? 0,
            h: try c.decodeIfPresent(Float.self, forKey: .h) ?? 0,
            packagingType: try c.decodeIfPresent(String.self, forKey: .packagingType) ?? "none",
            orientation: try c.decodeIfPresent(String.self, forKey: .orientation) ?? "as-is",
            envL: try c.decodeIfPresent(Float.self, forKey: .envL),
            envW: try c.decodeIfPresent(Float.self, forKey: .envW),
            envH: try c.decodeIfPresent(Float.self, forKey: .envH),
            weightKg: try c.decodeIfPresent(Double.self, forKey: .weightKg),
            locked: try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false,
            confidence: try c.decodeIfPresent(String.self, forKey: .confidence) ?? "unverified",
            provisional: try c.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
        )
    }
}

// MARK: - Canonical shipped envelope
//
// Ported from stereon/src/lib/packaging.ts. That file is the source of truth;
// stereon/docs/envelope-fixtures.json pins both implementations to the same
// numbers (stereon/scripts/check-envelope-fixtures.mjs runs the TS side).
// If the two ever disagree, the TypeScript wins and this gets fixed.

/// AU standard pallet.
let palletL = 1.165
let palletW = 1.165
let palletH = 0.15
/// A-frame base width — the frame's feet set the footprint even for a thin panel.
let aFrameBaseW = 0.9

/// An (l, w, h) box in metres.
struct Envelope: Equatable {
    var l: Float
    var w: Float
    var h: Float
}

/// Packaging allowances added around the oriented item. Assumptions, not
/// gospel — near a limit, measure the packaged freight (Bible §11.2).
/// Unknown types fall through to zero allowance, matching a `none` spec.
private func packagingAllowance(_ type: String) -> (l: Double, w: Double, h: Double) {
    switch type {
    case "pallet":  return (0, 0, palletH)
    case "crate":   return (0.1, 0.1, 0.15)
    case "a-frame": return (0, 0, 0.1)
    case "carton":  return (0.05, 0.05, 0.05)
    default:        return (0, 0, 0) // "none" and anything unrecognised
    }
}

/// 'vertical' and 'flat' both swap W and H: standing a flat panel up, or
/// laying a tall gate down. L (the long axis along the deck) never changes.
func orientedDims(_ dims: (l: Double, w: Double, h: Double),
                  orientation: String) -> (l: Double, w: Double, h: Double) {
    if orientation == "vertical" || orientation == "flat" {
        return (l: dims.l, w: dims.h, h: dims.w)
    }
    return dims
}

private func roundCm(_ m: Double) -> Double { (m * 100).rounded() / 100 }

/// The box that actually occupies the deck: the item in its shipping
/// orientation, plus its packaging. A measured `envelopeOverride` always wins.
/// Arithmetic runs in Double so the rounding matches JavaScript exactly.
func shippedEnvelope(dims: (l: Double, w: Double, h: Double),
                     packagingType: String,
                     orientation: String,
                     envelopeOverride: (l: Double, w: Double, h: Double)? = nil) -> Envelope {
    if let o = envelopeOverride {
        // Measured packaged dims — returned verbatim, exactly as the TS does.
        return Envelope(l: Float(o.l), w: Float(o.w), h: Float(o.h))
    }

    let d = orientedDims(dims, orientation: orientation)
    let a = packagingAllowance(packagingType)
    var l = d.l + a.l
    var w = d.w + a.w
    let h = d.h + a.h

    if packagingType == "pallet" {
        l = max(l, palletL)
        w = max(w, palletW)
    } else if packagingType == "a-frame" {
        w = max(w, aFrameBaseW)
    }

    return Envelope(l: Float(roundCm(l)), w: Float(roundCm(w)), h: Float(roundCm(h)))
}

/// Convenience overload for a library row.
func shippedEnvelope(of item: LibraryItem) -> Envelope {
    var override: (l: Double, w: Double, h: Double)?
    if let el = item.envL, let ew = item.envW, let eh = item.envH {
        override = (Double(el), Double(ew), Double(eh))
    }
    return shippedEnvelope(dims: (Double(item.l), Double(item.w), Double(item.h)),
                           packagingType: item.packagingType,
                           orientation: item.orientation,
                           envelopeOverride: override)
}

// MARK: - Gates
//
// HONEST NAMING. The score below is a *dimension-normalised distance*: the sum
// over three axes of (delta / sigma)². It is NOT a Mahalanobis distance and it
// is NOT chi-square distributed, because sigma is not a measured standard
// deviation — it is a handcrafted heuristic, 3.5% of the candidate axis with a
// 2 cm floor, chosen before any real dock data existed. `suggestDistanceGate`
// was originally copied off a χ² table (3 dof, 99%); it is kept only because it
// happens to cast a usable suggestion net, not because it means 99% of
// anything. Re-derive all three gates from real Vision Intelligence scan data
// before treating any number here as calibrated.

/// Auto-match ceiling on the dimension-normalised distance.
let autoDistanceGate: Float = 3.5
/// Everything at or under this is worth showing the operator.
let suggestDistanceGate: Float = 11.34
/// The runner-up must be at least this much worse before auto is allowed —
/// two plausible candidates is an operator decision, not a machine one.
let autoMarginRequired: Float = 4.0

/// Hard per-axis cap for AUTO, in addition to the aggregate gate.
/// Absolute ceiling…
let autoPerAxisCapMetres: Float = 0.06
/// …and a proportional one; the tighter of the two applies. Without this, a
/// permissive aggregate swallows a large single-axis mismatch on big freight:
/// on a 5 m axis, sigma = 0.175 m, so a 30 cm error scores only 2.94 and slips
/// under a 3.5 gate. 30 cm is not an identity match.
let autoPerAxisCapFraction: Float = 0.08

/// sigma for one axis: 3.5% of the candidate axis, floored at 2 cm.
private let sigmaFraction: Float = 0.035
private let sigmaFloorMetres: Float = 0.02

/// Suggestion breadth for an imprecise (non-LiDAR) scan. This ONLY widens
/// sigma to pull more candidates into the suggest list. It must never feed an
/// auto decision — see `autoIsPossible(precise:)`.
private let impreciseSigmaWidening: Float = 1.8

/// K-FACTOR INVERSION FIX.
///
/// The old code widened sigma to k = 1.8 for an imprecise scan, which lowered
/// the distance, which made a *sloppier* scan *more* likely to auto-match. The
/// gate got easier exactly as the evidence got worse — backwards for a safety
/// decision. The wider sigma is still right for casting a broad suggestion net
/// (a fuzzy scan legitimately has more plausible neighbours), so it is kept for
/// that and only that: an imprecise scan is capped at .suggest, full stop.
private func autoIsPossible(precise: Bool) -> Bool { precise }

// MARK: - Scored candidate

/// One library item scored against the scan.
struct ScoredCandidate {
    let item: LibraryItem
    /// Dimension-normalised distance — the sum of squared per-axis deviations
    /// in units of sigma. Lower is closer. See the gate comment above for what
    /// this number is and is not.
    let distance: Float
    /// Signed per-axis deltas (scan − candidate) in centimetres, in the same
    /// axis order the UI labels them.
    let deltasCm: [Float]
    /// The candidate envelope variant that won — raw dims, computed shipped
    /// envelope, or measured override.
    let envelope: Envelope
    /// Largest |delta| on the winning variant, in metres.
    let worstAxisDeltaMetres: Float
    /// The winning variant satisfies the hard per-axis cap.
    let withinPerAxisCap: Bool
    /// Library-side eligibility only: locked && confidence == "high" &&
    /// !provisional. Says nothing about how well this scan fits — an eligible
    /// item still has to pass every gate.
    let eligibleForAuto: Bool
    /// UI labels, e.g. ["unverified", "unlocked"] or ["unverified", "provisional"].
    let flags: [String]
}

// MARK: - Outcome

enum MatchOutcome {
    case auto(LibraryItem, distance: Float)
    case suggest([ScoredCandidate])
    case none
}

// MARK: - Entry points

/// Match a captured envelope against the library.
///
/// `scan` uses the capture convention (`ScanResult.aabbDims`): x and z are the
/// footprint axes, y is height. Candidates are the item's raw dims, its
/// canonical shipped envelope and any measured override; each item keeps its
/// best variant.
///
/// AUTO requires ALL of:
///   1. `precise == true` (an imprecise scan can never exceed .suggest)
///   2. the item is verified: locked && confidence == "high" && !provisional
///   3. every compared axis within min(6 cm, 8% of that axis)
///   4. aggregate distance <= autoDistanceGate
///   5. the runner-up at least autoMarginRequired worse
/// Anything short of that falls through to a human.
func matchScan(dims scan: SIMD3<Float>, precise: Bool, library: [LibraryItem]) -> MatchOutcome {
    let scored = scoreLibrary(dims: scan, precise: precise, library: library)
    guard let best = scored.first else { return .none }

    let runnerUp = scored.dropFirst().first
    let separated = runnerUp == nil || runnerUp!.distance - best.distance >= autoMarginRequired

    if autoIsPossible(precise: precise),
       best.eligibleForAuto,
       best.withinPerAxisCap,
       best.distance <= autoDistanceGate,
       separated {
        return .auto(best.item, distance: best.distance)
    }

    let gated = scored.filter { $0.distance <= suggestDistanceGate }
    if gated.isEmpty { return .none }
    return .suggest(Array(gated.prefix(3)))
}

/// Every library item inside the suggest gate, best first — the
/// "choose different" list behind an auto match. Ineligible items appear here
/// too, carrying their flags so the sheet can label them 'unverified'.
func matchCandidates(dims scan: SIMD3<Float>, precise: Bool,
                     library: [LibraryItem]) -> [ScoredCandidate] {
    scoreLibrary(dims: scan, precise: precise, library: library)
        .filter { $0.distance <= suggestDistanceGate }
}

// MARK: - Scoring

private func scoreLibrary(dims scan: SIMD3<Float>, precise: Bool,
                          library: [LibraryItem]) -> [ScoredCandidate] {
    library.compactMap { item -> ScoredCandidate? in
        // A row that arrived without dimensions can't be scored against
        // anything — skip it rather than letting a zero axis distort sigma.
        guard item.l > 0, item.w > 0, item.h > 0 else { return nil }
        guard let best = bestVariantScore(scan: scan, item: item, precise: precise) else { return nil }
        let gate = autoEligibility(of: item)
        return ScoredCandidate(item: item,
                               distance: best.distance,
                               deltasCm: best.deltasCm,
                               envelope: best.envelope,
                               worstAxisDeltaMetres: best.worstAxisDeltaMetres,
                               withinPerAxisCap: best.withinPerAxisCap,
                               eligibleForAuto: gate.eligible,
                               flags: gate.flags)
    }
    .sorted { $0.distance < $1.distance }
}

/// Library eligibility for AUTO. Anything ineligible can still be suggested —
/// it just carries a flag so the operator sees what they are confirming.
private func autoEligibility(of item: LibraryItem) -> (eligible: Bool, flags: [String]) {
    let highConfidence = item.confidence.lowercased() == "high"
    let eligible = item.locked && highConfidence && !item.provisional
    var flags: [String] = []
    if !eligible { flags.append("unverified") }
    if item.provisional { flags.append("provisional") }
    if !item.locked { flags.append("unlocked") }
    if !highConfidence { flags.append("low-confidence") }
    return (eligible, flags)
}

private struct VariantScore {
    let distance: Float
    let deltasCm: [Float]
    let envelope: Envelope
    let worstAxisDeltaMetres: Float
    let withinPerAxisCap: Bool
}

private func bestVariantScore(scan: SIMD3<Float>, item: LibraryItem,
                              precise: Bool) -> VariantScore? {
    var best: VariantScore?
    for variant in envelopeVariants(of: item) {
        let scored = score(scan: scan, candidate: variant,
                           orientation: item.orientation, precise: precise)
        if best == nil || scored.distance < best!.distance { best = scored }
    }
    return best
}

/// Candidate envelopes: the bare item as stored, the canonical shipped
/// envelope from packaging + orientation, and the measured override when one
/// exists. A dock scan may legitimately see any of the three.
private func envelopeVariants(of item: LibraryItem) -> [Envelope] {
    var variants = [Envelope(l: item.l, w: item.w, h: item.h)]

    let computed = shippedEnvelope(dims: (Double(item.l), Double(item.w), Double(item.h)),
                                   packagingType: item.packagingType,
                                   orientation: item.orientation,
                                   envelopeOverride: nil)
    if !variants.contains(computed) { variants.append(computed) }

    if let el = item.envL, let ew = item.envW, let eh = item.envH {
        let override = Envelope(l: el, w: ew, h: eh)
        if !variants.contains(override) { variants.append(override) }
    }
    return variants
}

/// One scan-vs-candidate distance. An upright item keeps its height axis —
/// only the footprint may be seen rotated; anything else may be lying on any
/// face, so all three axes are compared sorted.
private func score(scan: SIMD3<Float>, candidate: Envelope,
                   orientation: String, precise: Bool) -> VariantScore {
    let s: [Float]
    let c: [Float]
    if orientation == "upright" || orientation == "vertical" {
        s = [max(scan.x, scan.z), min(scan.x, scan.z), scan.y]
        c = [max(candidate.l, candidate.w), min(candidate.l, candidate.w), candidate.h]
    } else {
        s = [scan.x, scan.y, scan.z].sorted(by: >)
        c = [candidate.l, candidate.w, candidate.h].sorted(by: >)
    }

    // Widened sigma broadens the SUGGEST net for an imprecise scan. It cannot
    // buy an auto-match: autoIsPossible(precise:) already denied that.
    let k: Float = precise ? 1.0 : impreciseSigmaWidening

    var distance: Float = 0
    var deltasCm = [Float]()
    var worst: Float = 0
    var withinCap = true

    for i in 0..<3 {
        let sigma = k * max(sigmaFloorMetres, sigmaFraction * c[i])
        let delta = s[i] - c[i]
        distance += (delta / sigma) * (delta / sigma)
        deltasCm.append(delta * 100)

        let magnitude = abs(delta)
        worst = max(worst, magnitude)
        let cap = min(autoPerAxisCapMetres, autoPerAxisCapFraction * abs(c[i]))
        if magnitude > cap { withinCap = false }
    }

    return VariantScore(distance: distance, deltasCm: deltasCm, envelope: candidate,
                        worstAxisDeltaMetres: worst, withinPerAxisCap: withinCap)
}
