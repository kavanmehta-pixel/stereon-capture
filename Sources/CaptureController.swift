import ARKit
import AudioToolbox
import RealityKit
import UIKit
import simd

enum CaptureMode {
    /// LiDAR scene reconstruction, cropped to the box. Real item geometry.
    case lidarMesh
    /// Manually fitted box on a non-LiDAR device. Envelope only.
    case boxFit

    var label: String {
        switch self {
        case .lidarMesh: return "LiDAR mesh"
        case .boxFit: return "Box fit"
        }
    }
}

struct ScanResult: Identifiable {
    let id = UUID()
    var mode: CaptureMode
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var aabbDims: SIMD3<Float>
    var orientedFootprint: SIMD2<Float>
    /// Set when the mesh is a real fitted shape rather than a box, so the
    /// difference between occupied volume and the box around it is visible.
    var shapeVolume: Float?
    var glbURL: URL?

    var triangleCount: Int { indices.count / 3 }
    var isShape: Bool { shapeVolume != nil }
    var boxVolume: Float { aabbDims.x * aabbDims.y * aabbDims.z }
}

/// One separated item found in a "scan several" pass, already resolved into
/// world space. It carries its OWN feature points, so a capture minutes later
/// fits from the evidence gathered when the instance was segmented rather than
/// from whatever the cloud looks like by then.
struct DetectedCandidate: Identifiable {
    /// 1-based, left to right across the frame — the number drawn in AR.
    let id: Int
    /// Where the numbered marker sits: the near-surface cluster of this
    /// instance's own points, which is the face the operator is looking at.
    let anchor: SIMD3<Float>
    let points: [SIMD3<Float>]
    /// The surface this item stands on, resolved from its own footing.
    let floorY: Float
    /// Silhouette bounds in normalized upright-image space, kept for diagnosis.
    let bbox: CGRect
    var done = false

    /// Matches the fit threshold in the single-item detect path: below this
    /// there is not enough surface detail to measure anything.
    static let minPoints = 20

    /// How much evidence this instance has. Below the fit threshold there is
    /// nothing honest to measure, so it is flagged rather than dropped.
    var pointCount: Int { points.count }
    var needsCloserLook: Bool { points.count < DetectedCandidate.minPoints }
}

/// What the matcher decided about a load-out scan — the operator confirms it
/// in a sheet instead of the normal result sheet.
enum LoadoutDecision: Identifiable {
    /// Item plus the dimension-normalised distance behind the call, which is
    /// recorded on the piece as `matchScore`.
    case auto(ScanResult, LibraryItem, Float)
    case suggest(ScanResult, [ScoredCandidate])
    case none(ScanResult)
    /// The library never arrived — the sheet opens straight in new-item mode
    /// with a retry-fetch escape hatch.
    case unavailable(ScanResult)

    var id: String {
        switch self {
        case .auto(let scan, _, _): return "auto-\(scan.id)"
        case .suggest(let scan, _): return "suggest-\(scan.id)"
        case .none(let scan): return "none-\(scan.id)"
        case .unavailable(let scan): return "unavailable-\(scan.id)"
        }
    }

    var scan: ScanResult {
        switch self {
        case .auto(let scan, _, _): return scan
        case .suggest(let scan, _), .none(let scan), .unavailable(let scan): return scan
        }
    }
}

/// The match library is fetched when a load-out opens. Matching must know the
/// difference between "not here yet" (wait) and "won't arrive" (new-item only).
enum LibraryState {
    case loading
    case loaded([LibraryItem])
    case failed(String)
}

/// UIColor palette for the RealityKit crop-box entities. SwiftUI chrome uses
/// `Theme` (Theme.swift); these two are kept in visual sync by hand.
private enum BoxColor {
    static let edge = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
    static let fill = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
}

@MainActor
final class CaptureController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero)

    @Published var roiPlaced = false
    @Published var roiSize = SIMD3<Float>(1.0, 1.2, 1.0)
    @Published var roiYawDegrees: Float = 0
    /// Corner-tap flow: the operator raycasts the two base corners themselves,
    /// exactly as Apple's Measure has them place endpoints. Human supplies the
    /// semantics, ARKit supplies accurate 3D — far more dependable than
    /// inferring an object's extent from a sparse cloud.
    enum TapStage { case off, awaitingFirst, awaitingSecond }
    @Published var tapStage: TapStage = .off
    @Published var markedPoints: [SIMD3<Float>] = []
    private var snapTargets: [SIMD3<Float>] = []
    private var markerAnchors: [AnchorEntity] = []

    @Published var isProcessing = false
    @Published var isDetecting = false
    @Published var result: ScanResult?
    @Published var solidPointCount = 0
    @Published var lastFitPointCount = 0
    @Published var showAdjust = false
    @Published var statusMessage = ""

    /// Several separated items in one pass. Segmentation finds them all at
    /// once; the operator then works the list one marker at a time and each tap
    /// runs the same single-item fit, so nothing about the measurement changes.
    @Published var multiActive = false
    @Published var candidates: [DetectedCandidate] = []
    /// Instances that were segmented but had no learned points on them — too
    /// far, too dark, or too flat to place. Counted, never silently dropped.
    @Published var multiUnplaceable = 0
    private var candidateAnchors: [AnchorEntity] = []
    private var pendingCandidateId: Int?

    // Load-out batch scanning: pieces are matched against the library and
    // appended to the open load-out instead of landing in the result sheet.
    // Nothing here touches the network directly — every action becomes a
    // durable outbox event first (see Outbox.swift).
    @Published var loadoutActive = false
    @Published var loadoutReference = ""
    /// The client identity of the session. Survives a kill; the server's
    /// loadoutId is resolved from it and can arrive late.
    @Published var loadoutClientStartId: String?
    @Published var loadoutId: String?
    @Published var loadoutPlanId: String?
    /// The chip's three numbers: enqueued, acked, still to sync.
    @Published var loadoutLoaded = 0
    @Published var loadoutSynced = 0
    @Published var loadoutPending = 0
    @Published var loadoutFailed = 0
    /// The operator has ended the session but the close hasn't acked. The
    /// session stays fully on screen until it does — operational state is
    /// never erased ahead of the server confirming it.
    @Published var sessionCompletedLocally = false
    @Published var libraryState: LibraryState = .loading
    @Published var loadoutDecision: LoadoutDecision? = nil
    /// Bumped on every acked piece — drives the full-screen green flash.
    @Published var ackFlash = 0
    /// Compact plan reconciliation line, e.g. "JOB-14 — 8/10 V8+ · 2 remaining".
    @Published var progressLine: String?
    @Published var progressUnexpected = 0
    @Published var plans: [StereonServer.PlanLite] = []
    /// Transient "Added X — Undo" affordance after a piece is enqueued.
    struct LastAddedPiece: Equatable {
        let eventId: String
        let name: String
    }
    @Published var lastAdded: LastAddedPiece?

    let outbox: Outbox
    private let transport: StereonOutboxTransport
    /// Server piece ids, keyed by the client event that produced them —
    /// an undo needs the server's id, which only arrives on the ack.
    private var serverPieceIds: [String: String] = [:]
    private var lastLoadoutPrecise = false
    private var loadoutStartedAt = Date()
    private var lastAddedClearTask: Task<Void, Never>?
    private var autoCaptureOnFit = false

    /// Reported with every piece — see Matcher.swift.
    static var matcherVersionTag: String { matcherVersion }
    /// Settings-provided operator identity; falls back to the historical
    /// "capture-app" literal on an unconfigured phone.
    static var operatorName: String { StereonSettings.resolvedOperatorName }

    /// Any ARKit-capable device can run the box-fit mode.
    static var isARSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    /// Pro devices additionally get real mesh capture.
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    var mode: CaptureMode { Self.hasLiDAR ? .lidarMesh : .boxFit }

    private var viewConfigured = false
    private var worldAnchor: AnchorEntity?
    private var boxContainer: Entity?
    private var boxFrame: ModelEntity?
    private var roiCenter = SIMD3<Float>.zero

    // Sparse-cloud accumulation (the non-LiDAR "eyes"). Feature points are
    // binned to a 1.5 cm grid; a cell observed in 2+ sampled frames is solid.
    private var pointGrid: [SIMD3<Int32>: Int] = [:]
    private var solidPoints: [SIMD3<Int32>: SIMD3<Float>] = [:]
    private let gridCell: Float = 0.015
    private let gridCap = 80_000
    private var sampleTimer: Timer?

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let notifyHaptic = UINotificationFeedbackGenerator()

    override init() {
        let transport = StereonOutboxTransport()
        self.transport = transport
        outbox = Outbox(transport: transport)
        super.init()
        outbox.onAck = { [weak self] event, ack in self?.handleAck(event, ack) }
        outbox.onFail = { [weak self] event in self?.handleFailure(event) }
        statusMessage = initialMessage
        restorePersistedLoadout()
    }

    private var initialMessage: String {
        "Aim at the item, then set the box — it will auto-fit to what it has seen."
    }

    private var sizingMessage: String {
        Self.hasLiDAR
            ? "Drag to move, twist to rotate. Walk around until fully meshed, then capture."
            : "Drag to move, twist to rotate. Walk around the item, Snap to tighten, then capture."
    }

    // MARK: - Session lifecycle

    func start() {
        configureViewOnce()
        runSession(options: [.resetTracking, .removeExistingAnchors])
    }

    private func runSession(options: ARSession.RunOptions) {
        let config = ARWorldTrackingConfiguration()
        if Self.hasLiDAR {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        arView.session.run(config, options: options)
        pointGrid.removeAll()
        solidPoints.removeAll()
        solidPointCount = 0
        startSampling()
        lightHaptic.prepare()
        notifyHaptic.prepare()
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        arView.session.pause()
    }

    private func configureViewOnce() {
        guard !viewConfigured else { return }
        viewConfigured = true
        if Self.hasLiDAR {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.insert(.showFeaturePoints)
        }

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: arView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(pan)
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
        arView.addGestureRecognizer(twist)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    // MARK: - Sparse-cloud accumulation

    private func startSampling() {
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePoints() }
        }
    }

    private func samplePoints() {
        guard result == nil, loadoutDecision == nil, !isProcessing,
              let points = arView.session.currentFrame?.rawFeaturePoints?.points,
              pointGrid.count < gridCap else { return }
        for p in points {
            let key = SIMD3<Int32>(Int32((p.x / gridCell).rounded(.down)),
                                   Int32((p.y / gridCell).rounded(.down)),
                                   Int32((p.z / gridCell).rounded(.down)))
            let hits = (pointGrid[key] ?? 0) + 1
            pointGrid[key] = hits
            if hits == 2 {
                solidPoints[key] = SIMD3<Float>((Float(key.x) + 0.5) * gridCell,
                                                (Float(key.y) + 0.5) * gridCell,
                                                (Float(key.z) + 0.5) * gridCell)
            }
        }
        solidPointCount = solidPoints.count
    }

    /// Lowest detected horizontal plane — the floor, as ARKit understands it.
    private var detectedFloorY: Float? {
        let planes = arView.session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? []
        let ys = planes.filter { $0.alignment == .horizontal }.map { $0.transform.columns.3.y }
        return ys.min()
    }

    // MARK: - Box placement & fitting

    func placeROI() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            statusMessage = "Nothing there yet — move a little so tracking builds up, then try again."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        let hitPoint = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                    hit.worldTransform.columns.3.y,
                                    hit.worldTransform.columns.3.z)
        let floorY = min(detectedFloorY ?? hitPoint.y, hitPoint.y)

        ensureBoxEntities()

        if let fit = fitBox(around: hitPoint, floorY: floorY) {
            apply(fit: fit)
            statusMessage = "Auto-fitted to the item. " + sizingMessage
        } else {
            roiCenter = SIMD3<Float>(hitPoint.x, floorY, hitPoint.z)
            roiYawDegrees = 0
            statusMessage = "Not enough detail yet — walk around the item, then Snap. " + sizingMessage
        }
        boxContainer?.position = roiCenter
        roiPlaced = true
        updateROIBox()
        lightHaptic.impactOccurred()
    }

    /// Shrink-wrap the box onto the solid points it currently contains.
    func snapToItem() {
        guard roiPlaced else { return }
        let floorY = min(detectedFloorY ?? roiCenter.y, roiCenter.y)
        if let fit = fitBox(around: SIMD3<Float>(roiCenter.x, floorY, roiCenter.z),
                            floorY: floorY,
                            restrictToCurrentBox: true) {
            apply(fit: fit)
            boxContainer?.position = roiCenter
            updateROIBox()
            lightHaptic.impactOccurred()
            statusMessage = "Snapped. Fine-tune with the sliders if needed, then capture."
        } else {
            statusMessage = "Only \(solidPointCount) points learned — walk around the item, then Snap again."
            notifyHaptic.notificationOccurred(.warning)
        }
    }

    private struct BoxFit {
        var center: SIMD3<Float>
        var size: SIMD3<Float>
        var yawDegrees: Float
    }

    private func apply(fit: BoxFit) {
        roiCenter = fit.center
        roiSize = fit.size
        roiYawDegrees = fit.yawDegrees
    }

    // MARK: - Corner marking (detect the edges, then tap them)

    /// Segments the item, pulls the corners and edge tips off its silhouette,
    /// and pins each one in 3D so they stay stuck to the object as you move.
    func beginCornerTaps() {
        guard !isProcessing, result == nil, loadoutDecision == nil else { return }
        guard let frame = arView.session.currentFrame else { return }
        tapStage = .awaitingFirst
        markedPoints.removeAll()
        clearMarkers()
        statusMessage = "Finding the edges…"
        isDetecting = true

        let pixelBuffer = frame.capturedImage
        let viewport = arView.bounds.size
        let orientation = UIInterfaceOrientation.portrait
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewport)

        Task.detached(priority: .userInitiated) {
            let mask = ObjectDetector.detect(in: pixelBuffer, reticle: CGPoint(x: 0.5, y: 0.5))
            let corners = mask?.extremes() ?? []
            await MainActor.run {
                self.presentSnapTargets(corners, displayTransform: displayTransform, viewport: viewport)
            }
        }
    }

    private func presentSnapTargets(_ normalizedCorners: [CGPoint],
                                    displayTransform: CGAffineTransform,
                                    viewport: CGSize) {
        isDetecting = false
        snapTargets.removeAll()

        for corner in normalizedCorners {
            // normalized image space → normalized view space → view pixels
            let inView = corner.applying(displayTransform)
            let screen = CGPoint(x: inView.x * viewport.width, y: inView.y * viewport.height)
            guard screen.x > 0, screen.x < viewport.width, screen.y > 0, screen.y < viewport.height else { continue }
            guard let world = resolve3D(atScreen: screen) else { continue }
            snapTargets.append(world)
            addMarker(at: world, radius: 0.011, opacity: 0.55)
        }

        if snapTargets.isEmpty {
            statusMessage = "Couldn't read the edges — tap the item's corners yourself."
        } else {
            statusMessage = "Tap the highlighted corners — or anywhere on the item. Two or more."
            lightHaptic.impactOccurred()
        }
    }

    func cancelCornerTaps() {
        tapStage = .off
        markedPoints.removeAll()
        snapTargets.removeAll()
        clearMarkers()
        statusMessage = roiPlaced ? sizingMessage : initialMessage
    }

    /// Locks in the marked box and clears the marking overlay.
    func finishMarking() {
        guard markedPoints.count >= 2 else { return }
        rebuildFromMarks()
        tapStage = .off
        snapTargets.removeAll()
        clearMarkers()
        notifyHaptic.notificationOccurred(.success)
        statusMessage = "Box covers your \(markedPoints.count) marked points. Fine-tune, then capture."
    }

    func undoLastMark() {
        guard !markedPoints.isEmpty else { return }
        markedPoints.removeLast()
        redrawMarkers()
        if markedPoints.count >= 2 { rebuildFromMarks() }
        statusMessage = "\(markedPoints.count) point\(markedPoints.count == 1 ? "" : "s") marked."
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Working the several-items list: a tap picks a numbered marker.
        if multiActive, tapStage == .off, !roiPlaced,
           !isProcessing, !isDetecting, result == nil, loadoutDecision == nil {
            handleMultiTap(at: gesture.location(in: arView))
            return
        }
        guard tapStage != .off, !isProcessing, result == nil, loadoutDecision == nil else { return }
        let point = gesture.location(in: arView)

        // snap to a detected corner if the tap lands near one
        var chosen: SIMD3<Float>?
        if let camera = arView.session.currentFrame?.camera {
            var bestDistance: CGFloat = 52
            for target in snapTargets {
                let projected = camera.projectPoint(target, orientation: .portrait, viewportSize: arView.bounds.size)
                let d = hypot(projected.x - point.x, projected.y - point.y)
                if d < bestDistance { bestDistance = d; chosen = target }
            }
        }
        guard let world = chosen ?? resolve3D(atScreen: point) else {
            statusMessage = "Nothing to lock onto there — move a little closer and tap again."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // A tap whose depth resolved badly lands out in the room and silently
        // wrecks the measurement, so say so while it can still be undone.
        let before = markedPoints.count >= 2 ? spread(of: markedPoints) : nil
        markedPoints.append(world)
        let after = spread(of: markedPoints)

        addMarker(at: world, radius: 0.017, opacity: 1.0, marked: true)
        lightHaptic.impactOccurred()

        if markedPoints.count >= 2 {
            rebuildFromMarks()
            if let before, after > before * 1.6, after - before > 0.25 {
                notifyHaptic.notificationOccurred(.warning)
                statusMessage = "That point sits well outside the others — undo it if it missed the item."
            } else {
                statusMessage = markedPoints.count < 4
                    ? "\(markedPoints.count) marked. Four or more gives a real shape."
                    : "\(markedPoints.count) marked — include the highest and widest points of the item."
            }
        } else {
            statusMessage = "Now mark another corner — the further apart, the better."
        }
    }

    /// Largest edge of the box enclosing the marked points.
    private func spread(of pts: [SIMD3<Float>]) -> Float {
        guard var lo = pts.first else { return 0 }
        var hi = lo
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return simd_reduce_max(hi - lo)
    }

    /// Screen point → world. Depth comes from the points already learned around
    /// the tap; a raycast is only the fallback, because a corner in mid-air
    /// (the top of a laptop lid) has no plane behind it to hit.
    private func resolve3D(atScreen point: CGPoint) -> SIMD3<Float>? {
        guard let frame = arView.session.currentFrame else { return nil }
        let camera = frame.camera
        let viewport = arView.bounds.size
        let eye = SIMD3<Float>(camera.transform.columns.3.x,
                               camera.transform.columns.3.y,
                               camera.transform.columns.3.z)

        var nearbyDepths = [Float]()
        for p in solidPoints.values {
            let projected = camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
            let dx = projected.x - point.x, dy = projected.y - point.y
            if dx * dx + dy * dy <= 45 * 45 { nearbyDepths.append(simd_distance(p, eye)) }
        }
        if nearbyDepths.count >= 5, let ray = arView.ray(through: point) {
            // lean towards the nearer surface: the object, not what's behind it
            let depth = percentile(nearbyDepths, 0.3)
            return ray.origin + ray.direction * depth
        }
        if let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            return SIMD3<Float>(hit.worldTransform.columns.3.x,
                                hit.worldTransform.columns.3.y,
                                hit.worldTransform.columns.3.z)
        }
        return nil
    }

    /// The box simply encloses every marked point, with its base dropped to the
    /// surface the item stands on.
    private func rebuildFromMarks() {
        guard markedPoints.count >= 2 else { return }

        // Fit the footprint to the item's own axes. An item standing at an
        // angle to the world measures far too big inside a world-aligned box —
        // a laptop sitting at 22° read 34.8 cm wide instead of 31.5.
        let n = Float(markedPoints.count)
        var mx: Float = 0, mz: Float = 0
        for p in markedPoints { mx += p.x; mz += p.z }
        mx /= n; mz /= n
        var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
        for p in markedPoints {
            let dx = p.x - mx, dz = p.z - mz
            sxx += dx * dx; sxz += dx * dz; szz += dz * dz
        }
        let theta = 0.5 * atan2(2 * sxz, sxx - szz)
        let c = cos(theta), s = sin(theta)

        var minA = Float.greatestFiniteMagnitude, maxA = -Float.greatestFiniteMagnitude
        var minB = Float.greatestFiniteMagnitude, maxB = -Float.greatestFiniteMagnitude
        var loY = markedPoints[0].y, hiY = markedPoints[0].y
        for p in markedPoints {
            let dx = p.x - mx, dz = p.z - mz
            let a = c * dx + s * dz, b = -s * dx + c * dz
            minA = min(minA, a); maxA = max(maxA, a)
            minB = min(minB, b); maxB = max(maxB, b)
            loY = min(loY, p.y); hiY = max(hiY, p.y)
        }

        let planes = (arView.session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? [])
            .filter { $0.alignment == .horizontal }
            .map { $0.transform.columns.3.y }
        let baseY = planes.filter { $0 <= loY + 0.04 && $0 >= loY - 0.30 }.max() ?? loY

        let ca = (minA + maxA) / 2, cb = (minB + maxB) / 2
        var degrees = -theta * 180 / .pi
        var extentA = maxA - minA
        var extentB = maxB - minB
        degrees = degrees.truncatingRemainder(dividingBy: 180)
        if degrees < 0 { degrees += 180 }
        if degrees >= 90 { degrees -= 90; swap(&extentA, &extentB) }

        ensureBoxEntities()
        roiCenter = SIMD3<Float>(mx + ca * c - cb * s, baseY, mz + ca * s + cb * c)
        roiSize = SIMD3<Float>(max(extentA, 0.05),
                               max(hiY - baseY, 0.05),
                               max(extentB, 0.05))
        roiYawDegrees = degrees
        boxContainer?.position = roiCenter
        roiPlaced = true
        lastFitPointCount = markedPoints.count
        updateROIBox()
    }

    private func addMarker(at position: SIMD3<Float>, radius: Float, opacity: Float, marked: Bool = false) {
        let anchor = AnchorEntity(world: position)
        var material = UnlitMaterial(color: marked ? .white : BoxColor.edge)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        anchor.addChild(ModelEntity(mesh: .generateSphere(radius: radius), materials: [material]))
        arView.scene.addAnchor(anchor)
        markerAnchors.append(anchor)
    }

    private func redrawMarkers() {
        clearMarkers()
        for t in snapTargets { addMarker(at: t, radius: 0.011, opacity: 0.55) }
        for m in markedPoints { addMarker(at: m, radius: 0.017, opacity: 1.0, marked: true) }
    }

    private func clearMarkers() {
        for a in markerAnchors { a.removeFromParent() }
        markerAnchors.removeAll()
    }

    // MARK: - Object detection (the auto-latch)

    /// Segments the item under the reticle, keeps only the feature points that
    /// land on its silhouette, and fits the box to those. This is what stops
    /// the box swallowing the floor and the wall behind the item.
    func detectAndFit() {
        guard !isDetecting, !isProcessing, result == nil, loadoutDecision == nil else { return }
        guard let frame = arView.session.currentFrame else {
            statusMessage = "Camera isn't ready yet — hold still for a moment."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        guard solidPoints.count >= 40 else {
            statusMessage = "Move around the item a little first so it can learn its shape."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // Project every learned point into upright-image space on the main
        // actor (ARCamera is tied to the frame), then segment off-thread.
        let camera = frame.camera
        let resolution = camera.imageResolution
        let imageSize = CGSize(width: resolution.height, height: resolution.width)
        let eye = SIMD3<Float>(camera.transform.columns.3.x,
                               camera.transform.columns.3.y,
                               camera.transform.columns.3.z)
        // point, where it lands in the image, and how far it is from the camera
        let projected: [(SIMD3<Float>, CGPoint, Float)] = solidPoints.values.map { point in
            (point,
             camera.projectPoint(point, orientation: .portrait, viewportSize: imageSize),
             simd_distance(point, eye))
        }
        // Candidate support surfaces. The base is resolved AFTER we know which
        // points are the item — an item on a desk stands on the desk, not on
        // the lowest plane in the room.
        let supportPlanes = (arView.session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? [])
            .filter { $0.alignment == .horizontal }
            .map { $0.transform.columns.3.y }
        let pixelBuffer = frame.capturedImage

        isDetecting = true
        statusMessage = "Finding the item…"
        Task.detached(priority: .userInitiated) {
            let mask = ObjectDetector.detect(in: pixelBuffer, reticle: CGPoint(x: 0.5, y: 0.5))
            await MainActor.run {
                self.applyDetection(mask: mask, projected: projected,
                                    imageSize: imageSize, supportPlanes: supportPlanes)
            }
        }
    }

    /// U1: the one-tap load-out loop — detect, fit, and capture in one action.
    func scanPiece() {
        guard loadoutActive, !sessionCompletedLocally else { return }
        autoCaptureOnFit = true
        detectAndFit()
        // detectAndFit bailed on a guard (no frame / too few points): nothing
        // is in flight, so disarm the auto-capture.
        if !isDetecting { autoCaptureOnFit = false }
    }

    private func applyDetection(mask: ObjectMask?,
                                projected: [(SIMD3<Float>, CGPoint, Float)],
                                imageSize: CGSize,
                                supportPlanes: [Float]) {
        let autoCapture = autoCaptureOnFit
        autoCaptureOnFit = false
        isDetecting = false
        guard let mask, mask.coverage > 0.005 else {
            statusMessage = "Couldn't pick the item out from its background — place the box by hand instead."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // 1. Silhouette test — 2D only, so it also admits whatever sits behind
        //    the item along the same view rays.
        var masked = [(SIMD3<Float>, CGPoint, Float)]()
        for entry in projected {
            let u = Double(entry.1.x / imageSize.width)
            let v = Double(entry.1.y / imageSize.height)
            if mask.contains(u: u, v: v) { masked.append(entry) }
        }
        guard masked.count >= 25 else {
            statusMessage = "Found the item but not enough surface detail on it — move closer and retry."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // 2. Depth gate. Points the reticle is actually pointing at anchor how
        //    far away the item is; anything well behind that is the room, not
        //    the item. Without this the box swallows the wall behind it.
        let centre = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        let onObject = onObjectPoints(masked: masked, anchor: centre,
                                      anchorRadius: Float(imageSize.width) * 0.18)
        let rejected = masked.count - onObject.count

        // 3. Resolve the surface the item stands on. Its own footing is the
        //    truth; snap to a detected plane only when one sits just beneath.
        let footing = percentile(onObject.map { $0.y }, 0.02)
        let support = supportPlanes.filter { $0 <= footing + 0.04 && $0 >= footing - 0.30 }.max()
        let floorY = support ?? footing

        guard onObject.count >= 20, let fit = fitBox(points: onObject, floorY: floorY) else {
            statusMessage = "Found the item but not enough surface detail on it — move closer and retry."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        if rejected > 0 {
            print("detect: \(masked.count) in silhouette, \(rejected) rejected as background, \(onObject.count) kept")
        }

        ensureBoxEntities()
        apply(fit: fit)
        boxContainer?.position = roiCenter
        roiPlaced = true
        lastFitPointCount = onObject.count
        updateROIBox()
        notifyHaptic.notificationOccurred(.success)
        if autoCapture, loadoutActive {
            statusMessage = "Fitted from \(onObject.count) points — capturing…"
            finish()
        } else {
            statusMessage = "Fitted to the item from \(onObject.count) points. Check the faces, then capture."
        }
    }

    /// Keep only the points that belong to the item's own surface.
    ///
    /// The depths inside `anchorRadius` of `anchor` say how far away the item
    /// is; growing outwards from there through contiguous depths and stopping
    /// at the first real gap separates the item from the desk edge or wall
    /// behind it. An absolute cap stops a cluttered scene running away.
    /// Shared by the single-item detect (anchor = the reticle) and the
    /// several-items pass (anchor = each instance's own centroid), so both
    /// reject background identically.
    private func onObjectPoints(masked: [(SIMD3<Float>, CGPoint, Float)],
                                anchor: CGPoint,
                                anchorRadius: Float) -> [SIMD3<Float>] {
        guard !masked.isEmpty else { return [] }
        var anchorDepths = [Float]()
        for (_, screen, depth) in masked {
            let dx = Float(screen.x - anchor.x), dy = Float(screen.y - anchor.y)
            if sqrt(dx * dx + dy * dy) <= anchorRadius { anchorDepths.append(depth) }
        }
        let reference = median(anchorDepths.isEmpty ? masked.map { $0.2 } : anchorDepths)

        let ordered = masked.sorted { $0.2 < $1.2 }
        let depths = ordered.map { $0.2 }
        var seed = 0
        var closest = Float.greatestFiniteMagnitude
        for (i, d) in depths.enumerated() where abs(d - reference) < closest {
            closest = abs(d - reference); seed = i
        }
        let gap = max(0.04, reference * 0.06)
        let cap = max(0.30, reference * 0.5)
        var lo = seed, hi = seed
        while lo > 0,
              depths[lo] - depths[lo - 1] <= gap,
              reference - depths[lo - 1] <= cap { lo -= 1 }
        while hi < depths.count - 1,
              depths[hi + 1] - depths[hi] <= gap,
              depths[hi + 1] - reference <= cap { hi += 1 }

        return ordered[lo...hi].map { $0.0 }
    }

    /// PCA-fit an oriented box to the solid cloud near `seed`.
    private func fitBox(around seed: SIMD3<Float>, floorY: Float,
                        restrictToCurrentBox: Bool = false) -> BoxFit? {
        let yawNow = roiYawDegrees * .pi / 180
        let cyNow = cos(yawNow), syNow = sin(yawNow)

        var pts = [SIMD3<Float>]()
        for p in solidPoints.values {
            guard p.y > floorY + 0.02, p.y < floorY + 4.8 else { continue }
            if restrictToCurrentBox {
                let dx = p.x - roiCenter.x, dz = p.z - roiCenter.z
                let lx = dx * cyNow - dz * syNow
                let lz = dx * syNow + dz * cyNow
                guard abs(lx) <= roiSize.x * 0.575, abs(lz) <= roiSize.z * 0.575,
                      p.y - roiCenter.y <= roiSize.y * 1.05 else { continue }
            } else {
                let dx = p.x - seed.x, dz = p.z - seed.z
                guard dx * dx + dz * dz < 1.0 else { continue }
            }
            pts.append(p)
        }
        guard pts.count >= 60 else { return nil }
        return fitBox(points: pts, floorY: floorY)
    }

    /// Oriented-box fit over an explicit point set (used by object detection).
    private func fitBox(points pts: [SIMD3<Float>], floorY: Float) -> BoxFit? {
        guard pts.count >= 3 else { return nil }
        // Small and constant: 4 cm added to a 4 m tower is noise, but the same
        // on a 25 cm item is a 16% over-read.
        let margin: Float = 0.01

        let n = Float(pts.count)
        var mx: Float = 0, mz: Float = 0
        for p in pts { mx += p.x; mz += p.z }
        mx /= n; mz /= n
        var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
        for p in pts {
            let dx = p.x - mx, dz = p.z - mz
            sxx += dx * dx; sxz += dx * dz; szz += dz * dz
        }
        let theta = 0.5 * atan2(2 * sxz, sxx - szz)
        let c = cos(theta), s = sin(theta)

        var alongA = [Float](), alongB = [Float](), heights = [Float]()
        alongA.reserveCapacity(pts.count); alongB.reserveCapacity(pts.count); heights.reserveCapacity(pts.count)
        for p in pts {
            let dx = p.x - mx, dz = p.z - mz
            alongA.append(c * dx + s * dz)
            alongB.append(-s * dx + c * dz)
            heights.append(p.y)
        }

        // Percentile extents rather than min/max: one stray point must not
        // define the envelope.
        let minA = percentile(alongA, 0.01), maxA = percentile(alongA, 0.99)
        let minB = percentile(alongB, 0.01), maxB = percentile(alongB, 0.99)
        let topY = percentile(heights, 0.99)

        let ca = (minA + maxA) / 2, cb = (minB + maxB) / 2
        let center = SIMD3<Float>(mx + ca * c - cb * s, floorY, mz + ca * s + cb * c)

        // A rectangular footprint repeats every 90°, so fold the angle into the
        // range the rotation control can actually show, swapping the two
        // horizontal extents when the fold crosses a quarter turn.
        var degrees = -theta * 180 / .pi
        var extentA = maxA - minA
        var extentB = maxB - minB
        degrees = degrees.truncatingRemainder(dividingBy: 180)
        if degrees < 0 { degrees += 180 }
        if degrees >= 90 { degrees -= 90; swap(&extentA, &extentB) }

        let size = SIMD3<Float>(max(extentA + 2 * margin, 0.1),
                                max(topY - floorY + margin, 0.1),
                                max(extentB + 2 * margin, 0.1))
        return BoxFit(center: center, size: size, yawDegrees: degrees)
    }

    private func percentile(_ values: [Float], _ q: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((q * Float(sorted.count - 1)).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func median(_ values: [Float]) -> Float {
        percentile(values, 0.5)
    }

    // MARK: - Several items in one pass
    //
    // WHAT THIS IS. Several items SEPARATED and individually visible — staged
    // across a dock floor, spaced along an open deck — found in one pass so the
    // operator captures them from one standing position instead of starting a
    // session per item.
    //
    // WHAT THIS IS NOT. It cannot dimension a packed, occluded pile. A hidden
    // face has no recoverable geometry, so there is nothing to measure and no
    // amount of segmentation invents it. Segmentation will still happily return
    // an instance for a half-buried carton; what exposes it is the point count,
    // which is why a thin candidate is flagged "needs a closer look" and never
    // quietly measured anyway.
    //
    // Nothing here estimates a dimension. This builds a worklist; every actual
    // measurement still runs the single-item fit, restricted to one instance's
    // points, so accuracy stays exactly what was validated.

    var multiCapturedCount: Int { candidates.filter { $0.done }.count }

    var multiStatusLine: String {
        guard !candidates.isEmpty else {
            return "No items placed — move closer, then re-scan."
        }
        var line = "\(multiCapturedCount) of \(candidates.count) captured — tap a numbered marker."
        let thin = candidates.filter { $0.needsCloserLook && !$0.done }.count
        if thin > 0 { line += " \(thin) need\(thin == 1 ? "s" : "") a closer look." }
        if multiUnplaceable > 0 { line += " \(multiUnplaceable) too far to place." }
        return line
    }

    /// Segments every foreground instance in the frame and turns each one into
    /// a numbered candidate with its own points already resolved.
    func beginMultiScan() {
        guard !isDetecting, !isProcessing, result == nil, loadoutDecision == nil else { return }
        guard let frame = arView.session.currentFrame else {
            statusMessage = "Camera isn't ready yet — hold still for a moment."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        guard solidPoints.count >= 40 else {
            statusMessage = "Move around the items a little first so it can learn their shapes."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // Same preamble as the single-item detect: project on the main actor
        // (ARCamera is tied to the frame), segment off it.
        let camera = frame.camera
        let resolution = camera.imageResolution
        let imageSize = CGSize(width: resolution.height, height: resolution.width)
        let eye = SIMD3<Float>(camera.transform.columns.3.x,
                               camera.transform.columns.3.y,
                               camera.transform.columns.3.z)
        let projected: [(SIMD3<Float>, CGPoint, Float)] = solidPoints.values.map { point in
            (point,
             camera.projectPoint(point, orientation: .portrait, viewportSize: imageSize),
             simd_distance(point, eye))
        }
        let supportPlanes = (frame.anchors.compactMap { $0 as? ARPlaneAnchor })
            .filter { $0.alignment == .horizontal }
            .map { $0.transform.columns.3.y }
        let pixelBuffer = frame.capturedImage

        multiActive = true
        isDetecting = true
        statusMessage = "Finding the items…"
        Task.detached(priority: .userInitiated) {
            let instances = ObjectDetector.detectAll(in: pixelBuffer)
            await MainActor.run {
                self.buildCandidates(instances, projected: projected, eye: eye,
                                     imageSize: imageSize, supportPlanes: supportPlanes)
            }
        }
    }

    private func buildCandidates(_ instances: [DetectedInstance],
                                 projected: [(SIMD3<Float>, CGPoint, Float)],
                                 eye: SIMD3<Float>,
                                 imageSize: CGSize,
                                 supportPlanes: [Float]) {
        isDetecting = false
        // The operator tapped Done while this pass was still running.
        guard multiActive else { return }
        // A re-scan replaces the list, so carry the finished ones across by
        // position — the operator must not lose a capture to a second look.
        let alreadyDone = candidates.filter { $0.done }.map { $0.anchor }
        clearCandidateMarkers()
        candidates = []
        multiUnplaceable = 0

        guard !instances.isEmpty else {
            statusMessage = "Nothing separated out from the background — items need clear space around them."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        var built = [DetectedCandidate]()
        for instance in instances {
            // 1. Silhouette test, exactly as the single-item path does it.
            var masked = [(SIMD3<Float>, CGPoint, Float)]()
            for entry in projected {
                let u = Double(entry.1.x / imageSize.width)
                let v = Double(entry.1.y / imageSize.height)
                if instance.mask.contains(u: u, v: v) { masked.append(entry) }
            }
            guard !masked.isEmpty else { multiUnplaceable += 1; continue }

            // 2. Depth gate. This instance's own centroid plays the part the
            //    reticle plays for a single item: it says which depth is the
            //    item and which is the room behind it.
            let anchorPoint = CGPoint(x: instance.centroid.x * imageSize.width,
                                      y: instance.centroid.y * imageSize.height)
            let span = Float(min(instance.bbox.width * imageSize.width,
                                 instance.bbox.height * imageSize.height))
            let radius = max(Float(imageSize.width) * 0.05, span * 0.35)
            let onObject = onObjectPoints(masked: masked, anchor: anchorPoint, anchorRadius: radius)
            guard !onObject.isEmpty else { multiUnplaceable += 1; continue }

            // 3. Where the marker goes: the near-surface cluster of this
            //    instance's points — the face being looked at, not the far edge.
            let depths = onObject.map { simd_distance($0, eye) }
            let nearDepth = percentile(depths, 0.3)
            var front = [SIMD3<Float>]()
            for (point, depth) in zip(onObject, depths) where depth <= nearDepth { front.append(point) }
            let cluster = front.isEmpty ? onObject : front
            var marker = SIMD3<Float>.zero
            for point in cluster { marker += point }
            marker /= Float(cluster.count)

            // 4. Its own footing, snapped to a plane only when one sits just
            //    beneath — an item on a pallet stands on the pallet.
            let footing = percentile(onObject.map { $0.y }, 0.02)
            let support = supportPlanes.filter { $0 <= footing + 0.04 && $0 >= footing - 0.30 }.max()

            let carried = alreadyDone.contains { simd_distance($0, marker + SIMD3<Float>(0, 0.06, 0)) < 0.25 }
            built.append(DetectedCandidate(id: built.count + 1,
                                           anchor: marker + SIMD3<Float>(0, 0.06, 0),
                                           points: onObject,
                                           floorY: support ?? footing,
                                           bbox: instance.bbox,
                                           done: carried))
        }

        candidates = built
        redrawCandidateMarkers()
        if built.isEmpty {
            statusMessage = "Found \(instances.count) shape\(instances.count == 1 ? "" : "s") but none had detail on it — move closer, then re-scan."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        notifyHaptic.notificationOccurred(.success)
        statusMessage = multiStatusLine
    }

    /// A second pass over the same scene once more of it has been learned.
    /// Captures already made are kept.
    func rescanMulti() {
        guard multiActive else { return }
        beginMultiScan()
    }

    func endMultiScan() {
        multiActive = false
        candidates = []
        multiUnplaceable = 0
        pendingCandidateId = nil
        clearCandidateMarkers()
        statusMessage = loadoutActive
            ? "Load-out \(loadoutReference) · \(loadoutLoaded) added — scan the next piece."
            : initialMessage
    }

    private func handleMultiTap(at point: CGPoint) {
        guard let camera = arView.session.currentFrame?.camera else { return }
        var chosen: DetectedCandidate?
        var bestDistance: CGFloat = 90
        for candidate in candidates {
            let projected = camera.projectPoint(candidate.anchor, orientation: .portrait,
                                                viewportSize: arView.bounds.size)
            let d = hypot(projected.x - point.x, projected.y - point.y)
            if d < bestDistance { bestDistance = d; chosen = candidate }
        }
        guard let candidate = chosen else {
            statusMessage = "Tap a numbered marker. " + multiStatusLine
            return
        }
        captureCandidate(candidate)
    }

    /// Runs the EXISTING single-item fit against one instance's points. No new
    /// estimator: the box comes from the same PCA fit, and on a LiDAR device
    /// the capture crops the same reconstructed mesh to it.
    func captureCandidate(_ candidate: DetectedCandidate) {
        guard !isProcessing, !isDetecting, result == nil, loadoutDecision == nil else { return }
        guard candidate.points.count >= DetectedCandidate.minPoints,
              let fit = fitBox(points: candidate.points, floorY: candidate.floorY) else {
            statusMessage = "Item \(candidate.id) has only \(candidate.pointCount) points — walk closer to it, then re-scan."
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // Marks from an earlier corner-tap must not leak into this fit.
        tapStage = .off
        markedPoints.removeAll()
        snapTargets.removeAll()

        ensureBoxEntities()
        apply(fit: fit)
        boxContainer?.position = roiCenter
        roiPlaced = true
        lastFitPointCount = candidate.points.count
        updateROIBox()
        pendingCandidateId = candidate.id
        statusMessage = "Item \(candidate.id) — fitted from \(candidate.points.count) points, capturing…"
        finish()
    }

    private func markCandidateDone(_ id: Int) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].done = true
        redrawCandidateMarkers()
    }

    // MARK: Candidate markers

    private func redrawCandidateMarkers() {
        clearCandidateMarkers()
        guard multiActive else { return }
        for candidate in candidates { addCandidateMarker(candidate) }
    }

    private func clearCandidateMarkers() {
        for anchor in candidateAnchors { anchor.removeFromParent() }
        candidateAnchors.removeAll()
    }

    private func addCandidateMarker(_ candidate: DetectedCandidate) {
        let color: UIColor = candidate.done ? .systemGreen
            : (candidate.needsCloserLook ? .systemOrange : BoxColor.edge)

        let anchor = AnchorEntity(world: candidate.anchor)
        let facing = Entity()
        anchor.addChild(facing)

        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: candidate.done ? 0.65 : 0.95))
        facing.addChild(ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [material]))

        let label = ModelEntity(mesh: .generateText("\(candidate.id)",
                                                    extrusionDepth: 0.002,
                                                    font: .systemFont(ofSize: 0.05, weight: .bold),
                                                    alignment: .center),
                                materials: [UnlitMaterial(color: .white)])
        // generateText lays out from its own origin, so centre it by its bounds.
        let bounds = label.visualBounds(relativeTo: nil)
        label.position = SIMD3<Float>(-bounds.center.x, -bounds.center.y, 0.037)
        facing.addChild(label)

        // Turn the number towards where the operator is standing.
        if let camera = arView.session.currentFrame?.camera {
            let dx = camera.transform.columns.3.x - candidate.anchor.x
            let dz = camera.transform.columns.3.z - candidate.anchor.z
            facing.orientation = simd_quatf(angle: atan2(dx, dz), axis: SIMD3<Float>(0, 1, 0))
        }

        arView.scene.addAnchor(anchor)
        candidateAnchors.append(anchor)
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard roiPlaced, !isProcessing, result == nil, loadoutDecision == nil else { return }
        switch gesture.state {
        case .began:
            lightHaptic.impactOccurred(intensity: 0.6)
        case .changed:
            let location = gesture.location(in: arView)
            guard let hit = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal).first else { return }
            roiCenter.x = hit.worldTransform.columns.3.x
            roiCenter.z = hit.worldTransform.columns.3.z
            boxContainer?.position = roiCenter
        default:
            break
        }
    }

    @objc private func handleTwist(_ gesture: UIRotationGestureRecognizer) {
        guard roiPlaced, !isProcessing, result == nil, loadoutDecision == nil else { return }
        if gesture.state == .changed {
            roiYawDegrees -= Float(gesture.rotation) * 180 / .pi
            roiYawDegrees = roiYawDegrees.truncatingRemainder(dividingBy: 360)
            gesture.rotation = 0
            updateROIBox()
        }
    }

    // MARK: - Box entity

    func updateROIBox() {
        guard let frame = boxFrame else { return }
        frame.scale = roiSize
        frame.position = SIMD3<Float>(0, roiSize.y / 2, 0)
        frame.orientation = simd_quatf(angle: roiYawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
    }

    private func ensureBoxEntities() {
        if worldAnchor == nil {
            let anchor = AnchorEntity(world: SIMD3<Float>.zero)
            let container = Entity()
            let frame = buildUnitFrame()
            container.addChild(frame)
            anchor.addChild(container)
            arView.scene.addAnchor(anchor)
            worldAnchor = anchor
            boxContainer = container
            boxFrame = frame
        }
        boxContainer?.isEnabled = true
    }

    /// A 1 m wireframe cube (12 edges + faint fill) centred at the origin.
    /// Scaled to `roiSize` by `updateROIBox`, so it is only ever built once.
    private func buildUnitFrame() -> ModelEntity {
        let root = ModelEntity()
        let h: Float = 0.5, t: Float = 0.01

        var fillMaterial = UnlitMaterial(color: BoxColor.fill)
        fillMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.08))
        let fill = ModelEntity(mesh: .generateBox(size: 1.0), materials: [fillMaterial])
        root.addChild(fill)

        let edgeMaterial = UnlitMaterial(color: BoxColor.edge)
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(h, 0, h), SIMD3(t, 1, t)), (SIMD3(-h, 0, h), SIMD3(t, 1, t)),
            (SIMD3(h, 0, -h), SIMD3(t, 1, t)), (SIMD3(-h, 0, -h), SIMD3(t, 1, t)),
            (SIMD3(0, -h, h), SIMD3(1, t, t)), (SIMD3(0, -h, -h), SIMD3(1, t, t)),
            (SIMD3(0, h, h), SIMD3(1, t, t)), (SIMD3(0, h, -h), SIMD3(1, t, t)),
            (SIMD3(h, -h, 0), SIMD3(t, t, 1)), (SIMD3(-h, -h, 0), SIMD3(t, t, 1)),
            (SIMD3(h, h, 0), SIMD3(t, t, 1)), (SIMD3(-h, h, 0), SIMD3(t, t, 1)),
        ]
        for (position, size) in edges {
            let edge = ModelEntity(mesh: .generateBox(size: size), materials: [edgeMaterial])
            edge.position = position
            root.addChild(edge)
        }
        return root
    }

    // MARK: - Capture

    func finish() {
        guard roiPlaced, !isProcessing, result == nil, loadoutDecision == nil else { return }
        isProcessing = true
        statusMessage = "Processing scan…"
        Task { [weak self] in
            self?.performFinish()
            self?.isProcessing = false
        }
    }

    private func performFinish() {
        if loadoutActive, case .loading = libraryState {
            // Don't consume the scan — the ROI stays so Capture can be re-tapped.
            statusMessage = "Library still loading — try again in a moment"
            notifyHaptic.notificationOccurred(.warning)
            return
        }

        // The box was built from operator-marked corners: raycast-accurate
        // points, so the envelope is as trustworthy as a LiDAR mesh.
        let fromMarks = markedPoints.count >= 2
        let scan = Self.hasLiDAR ? buildMeshScan() : buildBoxScan()
        guard var scan else { return }

        // A ScanResult exists, so this candidate has been measured. Discarding
        // the piece in the sheet afterwards just means tapping its marker again.
        if let id = pendingCandidateId {
            pendingCandidateId = nil
            markCandidateDone(id)
        }

        do {
            let data = GLBWriter.encode(vertices: scan.vertices, normals: scan.normals, indices: scan.indices)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scan-\(formatter.string(from: Date())).glb")
            try data.write(to: url)
            scan.glbURL = url
            notifyHaptic.notificationOccurred(.success)
        } catch {
            // No success haptic on this path. In load-out mode the decision
            // sheet still opens: new-item falls back to a dims-only GLB there.
            statusMessage = "GLB export failed: \(error.localizedDescription)"
            notifyHaptic.notificationOccurred(.error)
        }

        if loadoutActive {
            lastLoadoutPrecise = mode == .lidarMesh || fromMarks
            loadoutDecision = decide(for: scan)
        } else {
            result = scan
        }
    }

    // MARK: - Load-out session

    private static let loadoutSessionKey = "stereon.loadout.session.v2"

    private struct PersistedLoadout: Codable {
        var clientStartId: String
        var reference: String
        var loadoutId: String?
        var planId: String?
        var startedAt: Date
        var completedLocally: Bool
        var serverPieceIds: [String: String]
    }

    /// An open session survives an app kill — restored silently on init, the
    /// chip shows it, the outbox resumes draining and scanning carries on.
    private func restorePersistedLoadout() {
        guard let data = UserDefaults.standard.data(forKey: Self.loadoutSessionKey),
              let saved = try? JSONDecoder().decode(PersistedLoadout.self, from: data) else { return }
        loadoutClientStartId = saved.clientStartId
        loadoutReference = saved.reference
        loadoutId = saved.loadoutId ?? outbox.loadoutId(forStart: saved.clientStartId)
        loadoutPlanId = saved.planId
        loadoutStartedAt = saved.startedAt
        sessionCompletedLocally = saved.completedLocally
        serverPieceIds = saved.serverPieceIds
        outbox.protectedStartId = saved.clientStartId

        // Ended last run and everything drained since? Nothing left to show.
        if saved.completedLocally, outbox.unflushed(forStart: saved.clientStartId).isEmpty {
            clearSessionState()
            return
        }

        loadoutActive = true
        refreshCounts()
        libraryState = .loading
        statusMessage = sessionCompletedLocally
            ? "Load-out \(saved.reference) ended — \(loadoutPending) event\(loadoutPending == 1 ? "" : "s") still syncing."
            : "Load-out \(saved.reference) · \(loadoutLoaded) added — scan the next piece."
        Task { [weak self] in await self?.fetchLibrary() }
        Task { [weak self] in await self?.outbox.flush() }
    }

    private func persistLoadoutSession() {
        let defaults = UserDefaults.standard
        guard let startId = loadoutClientStartId, loadoutActive,
              let data = try? JSONEncoder().encode(
                PersistedLoadout(clientStartId: startId,
                                 reference: loadoutReference,
                                 loadoutId: loadoutId,
                                 planId: loadoutPlanId,
                                 startedAt: loadoutStartedAt,
                                 completedLocally: sessionCompletedLocally,
                                 serverPieceIds: serverPieceIds)) else {
            defaults.removeObject(forKey: Self.loadoutSessionKey)
            return
        }
        defaults.set(data, forKey: Self.loadoutSessionKey)
    }

    var libraryItems: [LibraryItem] {
        if case .loaded(let items) = libraryState { return items }
        return []
    }

    /// Whether the most recent piece has actually landed on the server.
    var lastAddedIsSynced: Bool {
        guard let last = lastAdded else { return false }
        return outbox.events.first { $0.id == last.eventId }?.state == .acked
    }

    func refreshCounts() {
        let counts = outbox.counts(forStart: loadoutClientStartId)
        loadoutLoaded = counts.loaded
        loadoutSynced = counts.synced
        loadoutPending = counts.pending + counts.failed
        loadoutFailed = counts.failed
    }

    /// Starts a session. Blocked while the previous one still has events on
    /// disk — two open load-outs is how pieces end up on the wrong manifest.
    func beginLoadout(reference: String, planId: String? = nil) {
        let ref = String(reference.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !ref.isEmpty else {
            statusMessage = "A load-out needs a reference."
            notifyHaptic.notificationOccurred(.warning)
            return
        }
        if outbox.hasUnflushedEvents {
            let stuck = outbox.unresolvedEvents.count
            statusMessage = "\(stuck) event\(stuck == 1 ? "" : "s") from the last load-out still to sync — clear them first."
            notifyHaptic.notificationOccurred(.warning)
            Task { [weak self] in await self?.outbox.flush() }
            return
        }

        let startId = UUID().uuidString
        loadoutClientStartId = startId
        loadoutId = nil
        loadoutActive = true
        loadoutReference = ref
        loadoutPlanId = planId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        sessionCompletedLocally = false
        loadoutStartedAt = Date()
        libraryState = .loading
        lastAdded = nil
        progressLine = nil
        progressUnexpected = 0
        serverPieceIds = [:]
        outbox.protectedStartId = startId

        outbox.enqueue(OutboxEvent(
            kind: .startLoadout,
            clientStartId: startId,
            payload: .start(OutboxStartPayload(clientStartId: startId,
                                               reference: ref,
                                               operatorName: Self.operatorName,
                                               planId: loadoutPlanId))))
        refreshCounts()
        persistLoadoutSession()
        statusMessage = "Load-out \(ref) — scan the first piece."
        Task { [weak self] in await self?.fetchLibrary() }
        Task { [weak self] in await self?.outbox.flush() }
    }

    /// Plan list for the session-start picker. Silent when the endpoint isn't
    /// there yet — the operator can still type a plan id.
    func loadPlans() {
        Task { [weak self] in
            let fetched = (try? await StereonServer.plansLite()) ?? []
            self?.plans = fetched
        }
    }

    private func fetchLibrary() async {
        libraryState = .loading
        do {
            let items = try await StereonServer.fetchLibraryLite()
            guard loadoutActive else { return }
            libraryState = .loaded(items)
            statusMessage = "Load-out \(loadoutReference) — matching against \(items.count) items."
        } catch {
            guard loadoutActive else { return }
            libraryState = .failed(error.localizedDescription)
            statusMessage = "Matching unavailable — pieces can still be added as new items."
        }
    }

    /// The decision sheet's escape hatch when the library fetch failed.
    @discardableResult
    func retryLibraryFetch() async -> Bool {
        await fetchLibrary()
        if case .loaded = libraryState { return true }
        return false
    }

    /// Match a captured piece against the current library state. Tuple members
    /// are read positionally so a rename inside the matcher can't break this.
    func decide(for scan: ScanResult) -> LoadoutDecision {
        guard case .loaded(let items) = libraryState else { return .unavailable(scan) }
        switch matchScan(dims: scan.aabbDims, precise: lastLoadoutPrecise, library: items) {
        case .auto(let item, let score):
            return .auto(scan, item, score)
        case .suggest(let candidates):
            return .suggest(scan, candidates)
        case .none:
            return LoadoutDecision.none(scan)
        }
    }

    /// Ends the session. The reference, the count and the library all stay put
    /// until the server acks the close — operational state is never erased
    /// ahead of the confirmation that it is safe to erase it.
    func endLoadout() {
        guard loadoutActive, let startId = loadoutClientStartId else { return }
        guard loadoutPending == 0 else {
            statusMessage = "\(loadoutPending) piece\(loadoutPending == 1 ? "" : "s") still syncing — retry before ending."
            notifyHaptic.notificationOccurred(.warning)
            Task { [weak self] in await self?.outbox.flush() }
            return
        }
        sessionCompletedLocally = true
        let clientEventId = UUID().uuidString
        outbox.enqueue(OutboxEvent(
            id: clientEventId,
            kind: .complete,
            loadoutId: loadoutId,
            clientStartId: startId,
            payload: .complete(OutboxCompletePayload(clientEventId: clientEventId))))
        refreshCounts()
        persistLoadoutSession()
        statusMessage = "Load-out \(loadoutReference) ended — closing with the server…"
        Task { [weak self] in await self?.outbox.flush() }
    }

    /// Drains what's pending. Called on foreground — deliberately does NOT
    /// re-attempt events the server has already refused, which would just burn
    /// battery on a body the server will refuse identically.
    func flushOutbox() {
        Task { [weak self] in await self?.outbox.flush() }
    }

    /// Operator-driven: puts refused events back in the queue and drains.
    func retryAllPending() {
        outbox.retryAllFailed()
        refreshCounts()
    }

    func retryEvent(_ id: String) {
        outbox.retry(eventId: id)
        refreshCounts()
    }

    func discardEvent(_ id: String) {
        outbox.discard(eventId: id)
        refreshCounts()
        persistLoadoutSession()
        if sessionCompletedLocally, let startId = loadoutClientStartId,
           outbox.unflushed(forStart: startId).isEmpty {
            clearSessionState()
        }
    }

    // MARK: - Pieces

    /// Records one piece. The event id is minted here, before anything touches
    /// the network, and the local count moves immediately — the operator's tally
    /// is never hostage to a radio. The piece shows as pending until it acks.
    func addLoadoutPiece(matchedItemId: String?, matchedBy: String, scan: ScanResult,
                         displayName: String, matchScore: Float? = nil,
                         overrideReason: String? = nil, newItem: OutboxNewItem? = nil) {
        guard loadoutActive, let startId = loadoutClientStartId, !sessionCompletedLocally else { return }
        let eventId = UUID().uuidString

        var spec = newItem
        if spec != nil, let url = scan.glbURL, let data = try? Data(contentsOf: url) {
            spec?.glbFile = outbox.storeBlob(data, name: "\(eventId).glb")
        }

        let payload = OutboxPiecePayload(
            eventId: eventId,
            matchedItemId: matchedItemId,
            matchedBy: matchedBy,
            overrideReason: overrideReason,
            scanL: Double(scan.aabbDims.x),
            scanW: Double(scan.aabbDims.z),
            scanH: Double(scan.aabbDims.y),
            matchScore: matchScore.map(Double.init),
            matcherVersion: Self.matcherVersionTag,
            qty: 1,
            note: "",
            operatorName: Self.operatorName,
            deviceAt: Date(),
            displayName: displayName,
            newItem: spec)

        outbox.enqueue(OutboxEvent(id: eventId,
                                   kind: .piece,
                                   loadoutId: loadoutId,
                                   clientStartId: startId,
                                   payload: .piece(payload)))
        refreshCounts()
        persistLoadoutSession()
        showLastAdded(eventId: eventId, name: displayName)
        lightHaptic.impactOccurred()
        loadoutDecision = nil
        statusMessage = "\(displayName) added — \(loadoutLoaded) in load-out \(loadoutReference)."
        Task { [weak self] in await self?.outbox.flush() }
    }

    /// Name for an unknown piece so the operator never has to type at the dock.
    var nextUnknownPieceName: String { "Unknown piece \(loadoutLoaded + 1)" }

    private func showLastAdded(eventId: String, name: String) {
        lastAdded = LastAddedPiece(eventId: eventId, name: name)
        lastAddedClearTask?.cancel()
        lastAddedClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastAdded = nil
        }
    }

    /// Pulls the just-added piece back out. A piece that never left the phone
    /// is simply deleted; one the server already has gets an undo event.
    func undoLastAdded() {
        guard loadoutActive, let last = lastAdded, let startId = loadoutClientStartId else { return }
        lastAddedClearTask?.cancel()
        lastAdded = nil

        if outbox.cancelPending(eventId: last.eventId) {
            refreshCounts()
            persistLoadoutSession()
            notifyHaptic.notificationOccurred(.success)
            statusMessage = "Removed \(last.name) — \(loadoutLoaded) in load-out \(loadoutReference)."
            return
        }

        guard let serverPieceId = serverPieceIds[last.eventId] else {
            notifyHaptic.notificationOccurred(.warning)
            statusMessage = "\(last.name) is mid-sync — undo it once it lands."
            return
        }
        outbox.enqueue(OutboxEvent(kind: .undo,
                                   loadoutId: loadoutId,
                                   clientStartId: startId,
                                   payload: .undo(OutboxUndoPayload(pieceId: serverPieceId,
                                                                    eventId: last.eventId,
                                                                    displayName: last.name))))
        refreshCounts()
        persistLoadoutSession()
        notifyHaptic.notificationOccurred(.success)
        statusMessage = "Removing \(last.name) — \(loadoutLoaded) in load-out \(loadoutReference)."
        Task { [weak self] in await self?.outbox.flush() }
    }

    // MARK: - Outbox callbacks

    private func handleAck(_ event: OutboxEvent, _ ack: OutboxAck) {
        guard event.clientStartId == loadoutClientStartId else {
            refreshCounts()
            return
        }
        switch event.kind {
        case .startLoadout:
            loadoutId = ack.loadoutId ?? loadoutId
        case .piece:
            if let pieceId = ack.pieceId { serverPieceIds[event.id] = pieceId }
            ackFlash &+= 1
            notifyHaptic.notificationOccurred(.success)
            AudioServicesPlaySystemSound(1057)
            Task { [weak self] in await self?.refreshProgress() }
        case .complete:
            clearSessionState()
            return
        case .undo:
            break
        }
        refreshCounts()
        persistLoadoutSession()
    }

    private func handleFailure(_ event: OutboxEvent) {
        refreshCounts()
        notifyHaptic.notificationOccurred(.error)
        AudioServicesPlaySystemSound(1053)
        let detail = event.lastError ?? "rejected by the server"
        statusMessage = "\(event.label) failed: \(detail)"
    }

    /// The server has the close. Only now is it safe to forget the session.
    private func clearSessionState() {
        let ref = loadoutReference
        outbox.protectedStartId = nil
        loadoutActive = false
        loadoutReference = ""
        loadoutClientStartId = nil
        loadoutId = nil
        loadoutPlanId = nil
        sessionCompletedLocally = false
        loadoutLoaded = 0
        loadoutSynced = 0
        loadoutPending = 0
        loadoutFailed = 0
        serverPieceIds = [:]
        libraryState = .loading
        loadoutDecision = nil
        lastAdded = nil
        lastAddedClearTask?.cancel()
        progressLine = nil
        progressUnexpected = 0
        UserDefaults.standard.removeObject(forKey: Self.loadoutSessionKey)
        statusMessage = ref.isEmpty ? initialMessage : "Load-out \(ref) closed."
    }

    // MARK: - Plan reconciliation

    /// Compact "loaded of planned" line against the linked plan. Degrades
    /// silently: no plan, no endpoint, no line.
    private func refreshProgress() async {
        guard let id = loadoutId, loadoutPlanId != nil else { return }
        guard let progress = try? await StereonServer.progress(loadoutId: id) else { return }
        guard loadoutId == id else { return }

        let loadedById = Dictionary(progress.loaded.map { ($0.itemId, $0.loaded) },
                                    uniquingKeysWith: +)
        let planned = progress.expected.reduce(0) { $0 + $1.planned }
        let loaded = progress.expected.reduce(0) { $0 + min($1.planned, loadedById[$1.itemId] ?? 0) }
        progressUnexpected = progress.unexpected.reduce(0) { $0 + $1.count }

        guard planned > 0 else {
            progressLine = nil
            return
        }
        let remaining = max(0, planned - loaded)
        let headline = progress.expected
            .max { lhs, rhs in
                let l = lhs.planned - min(lhs.planned, loadedById[lhs.itemId] ?? 0)
                let r = rhs.planned - min(rhs.planned, loadedById[rhs.itemId] ?? 0)
                return l == r ? lhs.planned < rhs.planned : l < r
            }
        let label = headline.map { $0.sku.isEmpty ? $0.name : $0.sku } ?? ""
        var line = "\(loadoutReference) — \(loaded)/\(planned)"
        if !label.isEmpty { line += " \(label)" }
        line += remaining == 0 ? " · complete" : " · \(remaining) remaining"
        progressLine = line
    }

    /// Every gated candidate for this scan — the "choose different" list.
    func loadoutCandidates(for scan: ScanResult) -> [ScoredCandidate] {
        matchCandidates(dims: scan.aabbDims, precise: lastLoadoutPrecise, library: libraryItems)
    }

    /// The provisional-item spec for an unknown dock scan. Provisional means
    /// it can be seen and promoted in the web library but can never auto-match
    /// until a supervisor has reviewed it.
    func provisionalSpec(name: String, scan: ScanResult) -> OutboxNewItem {
        OutboxNewItem(name: name,
                      l: Double(scan.aabbDims.x),
                      w: Double(scan.aabbDims.z),
                      h: Double(scan.aabbDims.y),
                      mode: scan.mode == .lidarMesh ? "lidarMesh" : "boxFit",
                      provisional: true,
                      glbFile: nil)
    }

    /// Non-LiDAR. If the operator marked four or more corners we can hull them
    /// into the item's real shape; otherwise the box is the measurement.
    private func buildBoxScan() -> ScanResult? {
        let dims = SIMD3<Float>(roiSize.x, roiSize.y, roiSize.z)
        let footprint = SIMD2<Float>(roiSize.x, roiSize.z)

        if markedPoints.count >= 4 {
            // into the export frame: box yaw removed, floor at y=0, centred —
            // the same convention the mesh pipeline uses everywhere else
            let yaw = roiYawDegrees * .pi / 180
            let cy = cos(yaw), sy = sin(yaw)
            let local = markedPoints.map { p -> SIMD3<Float> in
                let dx = p.x - roiCenter.x, dz = p.z - roiCenter.z
                return SIMD3<Float>(dx * cy - dz * sy, p.y - roiCenter.y, dx * sy + dz * cy)
            }
            if let hull = ConvexHull.compute(local), hull.volume > 0 {
                return ScanResult(mode: .boxFit,
                                  vertices: hull.vertices,
                                  normals: hull.normals,
                                  indices: hull.indices,
                                  aabbDims: dims,
                                  orientedFootprint: footprint,
                                  shapeVolume: hull.volume,
                                  glbURL: nil)
            }
        }

        let (vertices, normals, indices) = BoxMesh.make(width: roiSize.x,
                                                        depth: roiSize.z,
                                                        height: roiSize.y)
        return ScanResult(mode: .boxFit,
                          vertices: vertices,
                          normals: normals,
                          indices: indices,
                          aabbDims: dims,
                          orientedFootprint: footprint,
                          shapeVolume: nil,
                          glbURL: nil)
    }

    /// LiDAR: crop the reconstructed mesh to the box, in box-local space.
    private func buildMeshScan() -> ScanResult? {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        guard !anchors.isEmpty else {
            statusMessage = "No mesh captured yet — keep scanning, then capture."
            notifyHaptic.notificationOccurred(.warning)
            return nil
        }

        let yaw = roiYawDegrees * .pi / 180
        var merged = MergedMesh()
        for anchor in anchors {
            merged.append(anchor: anchor,
                          boxCenter: roiCenter,
                          halfX: roiSize.x / 2,
                          halfZ: roiSize.z / 2,
                          height: roiSize.y,
                          floorTrim: 0.025,
                          yaw: yaw)
        }

        guard merged.vertices.count >= 3, !merged.indices.isEmpty else {
            statusMessage = "Nothing inside the box — reposition or enlarge it and rescan."
            notifyHaptic.notificationOccurred(.error)
            return nil
        }

        var lo = merged.vertices[0], hi = merged.vertices[0]
        for v in merged.vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        let dims = hi - lo

        // Floor at y=0, footprint centred on the origin.
        let shift = SIMD3<Float>((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        for i in merged.vertices.indices {
            merged.vertices[i] -= shift
        }

        return ScanResult(mode: .lidarMesh,
                          vertices: merged.vertices,
                          normals: merged.normals,
                          indices: merged.indices,
                          aabbDims: dims,
                          orientedFootprint: orientedFootprint(of: merged.vertices),
                          shapeVolume: nil,
                          glbURL: nil)
    }

    func reset() {
        result = nil
        loadoutDecision = nil
        roiPlaced = false
        roiYawDegrees = 0
        roiSize = SIMD3<Float>(1.0, 1.2, 1.0)
        worldAnchor?.removeFromParent()
        worldAnchor = nil
        boxContainer = nil
        boxFrame = nil
        if loadoutActive {
            statusMessage = sessionCompletedLocally
                ? "Load-out \(loadoutReference) ended — waiting on the server."
                : "Load-out \(loadoutReference) · \(loadoutLoaded) added — scan the next piece."
            // Keep the learned world map between pieces — no relocalising
            // before every scan. Marks from the previous piece must not leak
            // into the next one's fit.
            tapStage = .off
            markedPoints.removeAll()
            snapTargets.removeAll()
            clearMarkers()
            runSession(options: [])
        } else if multiActive {
            // Same reasoning as a load-out: the remaining candidates are held
            // in world coordinates, so resetting tracking would strand them.
            tapStage = .off
            markedPoints.removeAll()
            snapTargets.removeAll()
            clearMarkers()
            runSession(options: [])
        } else {
            statusMessage = initialMessage
            start()
        }
        if multiActive {
            redrawCandidateMarkers()
            statusMessage = multiStatusLine
        }
    }

    /// Yaw-independent footprint: PCA over the XZ plane. A cross-check on the
    /// box-local AABB — if the two disagree badly the box wasn't aligned.
    private func orientedFootprint(of vertices: [SIMD3<Float>]) -> SIMD2<Float> {
        let n = Float(vertices.count)
        var mx: Float = 0, mz: Float = 0
        for v in vertices { mx += v.x; mz += v.z }
        mx /= n; mz /= n
        var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
        for v in vertices {
            let dx = v.x - mx, dz = v.z - mz
            sxx += dx * dx; sxz += dx * dz; szz += dz * dz
        }
        let theta = 0.5 * atan2(2 * sxz, sxx - szz)
        let c = cos(theta), s = sin(theta)
        var minA: Float = .greatestFiniteMagnitude, maxA: Float = -.greatestFiniteMagnitude
        var minB: Float = .greatestFiniteMagnitude, maxB: Float = -.greatestFiniteMagnitude
        for v in vertices {
            let dx = v.x - mx, dz = v.z - mz
            let a = c * dx + s * dz
            let b = -s * dx + c * dz
            if a < minA { minA = a }; if a > maxA { maxA = a }
            if b < minB { minB = b }; if b > maxB { maxB = b }
        }
        return SIMD2<Float>(maxA - minA, maxB - minB)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
