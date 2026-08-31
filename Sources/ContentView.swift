import RealityKit
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CaptureController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var flashing = false
    @State private var showPendingSheet = false

    var body: some View {
        Group {
            if CaptureController.isARSupported {
                captureView
            } else {
                UnsupportedView()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var captureView: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            // Legibility scrim: glass needs the content beneath it tamed.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // The reticle aims a single-item detect; while working a list of
            // separated items the taps go to the markers instead.
            if !controller.roiPlaced && !controller.isProcessing && !controller.multiActive {
                Reticle(active: controller.tapStage != .off || controller.solidPointCount >= 40)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                StatusPill(message: controller.statusMessage)
                if controller.loadoutActive {
                    LoadoutChip(controller: controller, onShowPending: { showPendingSheet = true })
                    if let line = controller.progressLine {
                        ProgressChip(line: line, unexpected: controller.progressUnexpected)
                            .transition(.opacity)
                    }
                    if let last = controller.lastAdded {
                        UndoChip(name: last.name, synced: controller.lastAddedIsSynced) {
                            controller.undoLastAdded()
                        }
                        .transition(.opacity)
                    }
                }
                if controller.multiActive, !controller.candidates.isEmpty {
                    MultiChip(captured: controller.multiCapturedCount,
                              total: controller.candidates.count,
                              needsLook: controller.candidates.filter { $0.needsCloserLook && !$0.done }.count)
                        .transition(.opacity)
                }
                LearningChip(points: controller.solidPointCount, mode: controller.mode)
                Spacer()
                ControlDeck(controller: controller)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            if controller.isProcessing || controller.isDetecting {
                BusyOverlay(text: controller.isDetecting
                            ? (controller.multiActive ? "Finding the items…" : "Finding the item…")
                            : "Building the scan…")
                    .transition(.opacity)
            }

            // Confirmation you can read across a loading dock without looking
            // at the phone: the whole screen goes green the instant the server
            // has the piece — not when the button was tapped.
            if flashing {
                Color.green.opacity(0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: controller.roiPlaced)
        .animation(.smooth(duration: 0.3), value: controller.showAdjust)
        .animation(.easeInOut(duration: 0.2), value: controller.isProcessing)
        .animation(.easeInOut(duration: 0.2), value: controller.isDetecting)
        .animation(.smooth(duration: 0.3), value: controller.lastAdded)
        .animation(.smooth(duration: 0.3), value: controller.progressLine)
        .animation(.easeOut(duration: 0.09), value: flashing)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { controller.flushOutbox() }
        }
        .onChange(of: controller.ackFlash) { _, _ in
            flashing = true
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000)
                flashing = false
            }
        }
        .sheet(item: $controller.result, onDismiss: { controller.reset() }) { result in
            ResultSheet(result: result) { controller.result = nil }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $controller.loadoutDecision, onDismiss: { controller.reset() }) { decision in
            // A swipe must never throw a captured piece away — Cancel confirms.
            LoadoutDecisionSheet(decision: decision, controller: controller)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showPendingSheet) {
            PendingEventsSheet(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Control deck

private struct ControlDeck: View {
    @ObservedObject var controller: CaptureController
    @State private var showLoadoutPrompt = false

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 14) {
                // Marking takes precedence: while placing points the operator
                // needs Undo and the live size, not the finished-box controls.
                if controller.tapStage != .off {
                    if controller.roiPlaced {
                        DimsReadout(size: controller.roiSize,
                                    yaw: controller.roiYawDegrees,
                                    fitPoints: controller.markedPoints.count)
                    }
                    Text(controller.markedPoints.count < 4
                         ? "\(controller.markedPoints.count) marked · 4+ gives a real shape"
                         : "\(controller.markedPoints.count) marked · mark the highest and widest points too")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(radius: 3)

                    HStack(spacing: 10) {
                        Button {
                            controller.undoLastMark()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(controller.markedPoints.isEmpty)

                        Button {
                            controller.cancelCornerTaps()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    if controller.markedPoints.count >= 2 {
                        Button {
                            controller.finishMarking()
                        } label: {
                            Label("Done — \(controller.markedPoints.count) points", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .tint(Theme.accent)
                    }
                } else if controller.roiPlaced {
                    DimsReadout(size: controller.roiSize,
                                yaw: controller.roiYawDegrees,
                                fitPoints: controller.lastFitPointCount)

                    if controller.showAdjust {
                        VStack(spacing: 10) {
                            slider("Width", $controller.roiSize.x, "arrow.left.and.right", 0.1...6)
                            slider("Depth", $controller.roiSize.z, "arrow.up.and.down", 0.1...6)
                            slider("Height", $controller.roiSize.y, "arrow.up.to.line", 0.1...6)
                            yawSlider
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    HStack(spacing: 10) {
                        Button {
                            controller.detectAndFit()
                        } label: {
                            Label("Re-detect", systemImage: "sparkle.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)

                        Button {
                            controller.showAdjust.toggle()
                        } label: {
                            Label("Adjust", systemImage: controller.showAdjust ? "chevron.down" : "slider.horizontal.3")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }

                    Button {
                        controller.finish()
                    } label: {
                        Label("Capture", systemImage: "cube.transparent.fill")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .tint(Theme.accent)
                    .disabled(controller.isProcessing)

                    HintRow(text: "Drag to move · twist with two fingers to rotate")
                } else if controller.multiActive {
                    multiPanel
                } else if controller.loadoutActive {
                    if controller.sessionCompletedLocally {
                        // Ended, not yet closed. Nothing to scan into.
                        Button {
                            controller.flushOutbox()
                        } label: {
                            Label("Syncing the close…", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                    } else {
                        // One tap does the whole loop: detect, fit, capture. The
                        // manual paths stay available as secondary buttons.
                        Button {
                            controller.scanPiece()
                        } label: {
                            Label("Scan piece", systemImage: "viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .tint(Theme.accent)
                        .disabled(controller.isDetecting)

                        HStack(spacing: 10) {
                            Button {
                                controller.beginCornerTaps()
                            } label: {
                                Label("Mark corners", systemImage: "hand.tap")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)

                            Button {
                                controller.placeROI()
                            } label: {
                                Label("Free box", systemImage: "cube")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }

                        Button {
                            controller.beginMultiScan()
                        } label: {
                            Label("Scan several", systemImage: "square.grid.2x2")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(controller.isDetecting)
                    }
                } else {
                    Button {
                        controller.beginCornerTaps()
                    } label: {
                        Label("Mark the corners", systemImage: "hand.tap")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .tint(Theme.accent)

                    HStack(spacing: 10) {
                        Button {
                            controller.detectAndFit()
                        } label: {
                            Label("Auto-detect", systemImage: "sparkle.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(controller.isDetecting)

                        Button {
                            controller.placeROI()
                        } label: {
                            Label("Free box", systemImage: "cube")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }

                    HStack(spacing: 10) {
                        Button {
                            controller.beginMultiScan()
                        } label: {
                            Label("Scan several", systemImage: "square.grid.2x2")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(controller.isDetecting)

                        Button {
                            controller.loadPlans()
                            showLoadoutPrompt = true
                        } label: {
                            Label("Load-out", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
            }
        }
        .padding(.bottom, 10)
        .sheet(isPresented: $showLoadoutPrompt) {
            StartLoadoutSheet(controller: controller) { showLoadoutPrompt = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Working a list of separated items. The caveat is not decoration: the
    /// flow is only honest while every item is individually visible.
    private var multiPanel: some View {
        VStack(spacing: 12) {
            Text("Works when items are separated and fully visible — not for a packed stack.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .shadow(radius: 3)

            HStack(spacing: 10) {
                Button {
                    controller.rescanMulti()
                } label: {
                    Label("Re-scan", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(controller.isDetecting)

                Button {
                    controller.endMultiScan()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Theme.accent)
            }

            HintRow(text: controller.candidates.isEmpty
                    ? "Move closer to the items, then re-scan"
                    : "Tap a numbered marker to capture that item")
        }
    }

    private var yawSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "rotate.3d")
                .font(.footnote).foregroundStyle(.secondary).frame(width: 22)
            Slider(value: Binding(
                get: { controller.roiYawDegrees },
                set: { controller.roiYawDegrees = $0; controller.updateROIBox() }
            ), in: 0...90)
            .tint(Theme.accent)
            Text(String(format: "%.0f°", controller.roiYawDegrees))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func slider(_ label: String, _ value: Binding<Float>,
                        _ symbol: String, _ range: ClosedRange<Float>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote).foregroundStyle(.secondary).frame(width: 22)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; controller.updateROIBox() }
            ), in: range)
            .tint(Theme.accent)
            Text(String(format: "%.2f m", value.wrappedValue))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

private struct DimsReadout: View {
    let size: SIMD3<Float>
    let yaw: Float
    let fitPoints: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            dim(size.x)
            times
            dim(size.z)
            times
            dim(size.y)
            Text("m")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if fitPoints > 0 {
                Label("\(fitPoints)", systemImage: "sparkles")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var times: some View {
        Text("×").font(.footnote).foregroundStyle(.tertiary)
    }

    private func dim(_ v: Float) -> some View {
        Text(String(format: "%.2f", v))
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .monospacedDigit()
    }
}

private struct HintRow: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "hand.draw")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
            .shadow(radius: 3)
    }
}

// MARK: - Status chrome

private struct StatusPill: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct LearningChip: View {
    let points: Int
    let mode: CaptureMode

    private var ready: Bool { points >= 40 }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: mode == .lidarMesh ? "scanner" : "circle.dotted")
                .font(.caption2.weight(.semibold))
            Text(mode == .lidarMesh ? "LiDAR mesh" : (ready ? "Ready · \(points) pts" : "Learning · \(points) pts"))
                .font(.caption.weight(.medium).monospacedDigit())
        }
        .foregroundStyle(ready ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.clear, in: .capsule)
    }
}

/// "3 of 5 captured" while a several-items pass is open. Anything the pass
/// could not measure is counted here rather than quietly left off the list.
private struct MultiChip: View {
    let captured: Int
    let total: Int
    let needsLook: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.grid.2x2")
                .font(.caption2.weight(.semibold))
            Text("\(captured) of \(total) captured")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(captured == total ? AnyShapeStyle(.green) : AnyShapeStyle(Theme.accent))
            if needsLook > 0 {
                Text("· \(needsLook) needs a closer look")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.clear, in: .capsule)
    }
}

private struct Reticle: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { corner in
                CornerMark(color: active ? Theme.accent : .white)
                    .rotationEffect(.degrees(Double(corner) * 90))
            }
            Circle()
                .fill(active ? Theme.accent : .white)
                .frame(width: 5, height: 5)
        }
        .frame(width: 78, height: 78)
        .opacity(pulse ? 0.5 : 1)
        .scaleEffect(pulse ? 1.05 : 1)
        .shadow(radius: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}

private struct CornerMark: View {
    let color: Color
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 20))
            path.addLine(to: CGPoint(x: 0, y: 5))
            path.addQuadCurve(to: CGPoint(x: 5, y: 0), control: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 20, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: 78, height: 78, alignment: .topLeading)
    }
}

private struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).font(.subheadline.weight(.medium))
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .allowsHitTesting(false)
    }
}

private struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("AR not supported").font(.title2.weight(.semibold))
            Text("Stereon Capture needs an ARKit-capable iPhone.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Result sheet

private struct ResultSheet: View {
    let result: ScanResult
    let onNewScan: () -> Void

    private enum UploadState: Equatable {
        case idle, sending
        case done(String)
        case failed(String)
    }

    @State private var itemName = ""
    @State private var uploadState: UploadState = .idle

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                HStack(spacing: 10) {
                    MetricTile(label: "Width", value: result.aabbDims.x)
                    MetricTile(label: "Depth", value: result.aabbDims.z)
                    MetricTile(label: "Height", value: result.aabbDims.y)
                }

                DetailCard(result: result)

                if result.mode == .boxFit {
                    Text(result.isShape
                         ? "Shape is the hull of the corners you marked — every face is backed by a point you placed. Tape-verify before locking."
                         : "Box fit is a fitted envelope, not measured geometry. Tape-verify before locking the item.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 8)
                }

                uploadCard

                VStack(spacing: 10) {
                    if let url = result.glbURL {
                        ShareLink(item: url) {
                            Label("Share GLB", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Button(action: onNewScan) {
                        Label("New scan", systemImage: "plus.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(22)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: result.isShape ? "cube.transparent.fill" : "checkmark.seal.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(result.isShape ? "Shape captured" : "Scan captured")
                .font(.title2.weight(.semibold))
            Text(result.isShape
                 ? "Fitted shape · envelope in metres"
                 : "\(result.mode.label) · envelope in metres")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var uploadCard: some View {
        VStack(spacing: 12) {
            switch uploadState {
            case .done(let name):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("In the Stereon library as “\(name)”")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            default:
                TextField("Item name (e.g. Vision camera tower)", text: $itemName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button {
                    send()
                } label: {
                    if uploadState == .sending {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text("Sending…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Send to Stereon library", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(uploadState == .sending)
                if case .failed(let message) = uploadState {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func send() {
        guard let url = result.glbURL, let glb = try? Data(contentsOf: url) else {
            uploadState = .failed("No GLB file to send")
            return
        }
        let name = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        uploadState = .sending
        Task {
            do {
                _ = try await StereonServer.uploadScan(glb: glb, name: name,
                                                       dims: result.aabbDims, mode: result.mode)
                uploadState = .done(name.isEmpty ? "Scan" : name)
            } catch {
                uploadState = .failed(error.localizedDescription)
            }
        }
    }
}

private struct MetricTile: View {
    let label: String
    let value: Float
    var body: some View {
        VStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f", value))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text("m").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct DetailCard: View {
    let result: ScanResult
    var body: some View {
        VStack(spacing: 0) {
            if let volume = result.shapeVolume {
                row("Shape volume", String(format: "%.3f m³", volume))
                Divider().overlay(.white.opacity(0.06))
                row("Box volume", String(format: "%.3f m³", result.boxVolume))
                Divider().overlay(.white.opacity(0.06))
                row("Air saved vs box",
                    String(format: "%.0f%%", max(0, (1 - volume / max(result.boxVolume, 1e-6)) * 100)))
                Divider().overlay(.white.opacity(0.06))
            }
            row("Footprint area", String(format: "%.2f m²", result.aabbDims.x * result.aabbDims.z))
            Divider().overlay(.white.opacity(0.06))
            if result.mode == .lidarMesh {
                row("PCA cross-check",
                    String(format: "%.2f × %.2f m", result.orientedFootprint.x, result.orientedFootprint.y))
                Divider().overlay(.white.opacity(0.06))
            }
            row("Triangles", "\(result.triangleCount)")
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 14)
    }
}

// MARK: - Load-out

private struct LoadoutChip: View {
    @ObservedObject var controller: CaptureController
    let onShowPending: () -> Void
    @State private var confirmEnd = false
    @State private var blockedEnd = false

    private var pending: Int { controller.loadoutPending }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.loadoutReference)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // The CTO's three numbers. "Loaded" is what the operator
                    // believes; "synced" is what the server can prove.
                    Text("\(controller.loadoutLoaded) loaded · \(controller.loadoutSynced) synced · \(pending) pending")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pending > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 10)
                // A real button a gloved thumb can hit, not a caption-sized label.
                Button {
                    if pending > 0 { blockedEnd = true } else { confirmEnd = true }
                } label: {
                    Text("End")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 56, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(pending > 0 ? .orange : Theme.accent)
                .disabled(controller.sessionCompletedLocally)
            }

            if pending > 0 {
                Button(action: onShowPending) {
                    Label("\(pending) piece\(pending == 1 ? "" : "s") still syncing — review",
                          systemImage: controller.loadoutFailed > 0
                              ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.loadoutFailed > 0 ? .red : .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .confirmationDialog("End load-out \(controller.loadoutReference)?",
                            isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End load-out — \(controller.loadoutLoaded) pieces", role: .destructive) {
                controller.endLoadout()
            }
            Button("Keep scanning", role: .cancel) {}
        }
        // Ending on top of unsynced pieces is how a manifest goes short.
        .confirmationDialog("\(pending) piece\(pending == 1 ? "" : "s") still syncing",
                            isPresented: $blockedEnd, titleVisibility: .visible) {
            Button("Retry now") { controller.flushOutbox() }
            Button("Review pending") { onShowPending() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The load-out can't be closed until the server has every piece.")
        }
    }
}

/// Plan reconciliation, compact enough to sit under the session chip.
private struct ProgressChip: View {
    let line: String
    let unexpected: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.caption2.weight(.semibold))
            Text(line)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
            if unexpected > 0 {
                Text("· \(unexpected) unexpected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear, in: .capsule)
    }
}

/// Session start: reference plus the plan to reconcile against. The plan list
/// is a convenience — a typed id works when the endpoint isn't there.
private struct StartLoadoutSheet: View {
    @ObservedObject var controller: CaptureController
    let onClose: () -> Void

    @State private var reference = ""
    @State private var planId = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reference") {
                    TextField("e.g. VI-2481", text: $reference)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                Section("Plan (optional)") {
                    if controller.plans.isEmpty {
                        TextField("Plan id", text: $planId)
                            .autocorrectionDisabled()
                    } else {
                        Picker("Plan", selection: $planId) {
                            Text("None").tag("")
                            ForEach(controller.plans) { plan in
                                Text(plan.pieceCount.map { "\(plan.name) · \($0)" } ?? plan.name)
                                    .tag(plan.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Start load-out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        controller.beginLoadout(reference: reference, planId: planId)
                        onClose()
                    }
                    .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Everything the phone is still holding, with the server's own words on each
/// failure. Retry or discard one at a time — never in bulk by accident.
private struct PendingEventsSheet: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject private var outbox: Outbox
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard: String?

    init(controller: CaptureController) {
        _controller = ObservedObject(wrappedValue: controller)
        _outbox = ObservedObject(wrappedValue: controller.outbox)
    }

    private var events: [OutboxEvent] { outbox.unresolvedEvents }

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    Text("Everything is synced.")
                        .foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: event))
                                .foregroundStyle(event.state == .failed ? .red : .orange)
                            Text(event.label).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(event.state == .failed ? "Failed" : "Pending")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(event.state == .failed ? .red : .orange)
                        }
                        if let error = event.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("\(event.attempts) attempt\(event.attempts == 1 ? "" : "s")"
                             + (event.lastStatusCode.map { " · HTTP \($0)" } ?? ""))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 10) {
                            Button {
                                controller.retryEvent(event.id)
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)

                            Button(role: .destructive) {
                                confirmDiscard = event.id
                            } label: {
                                Label("Discard", systemImage: "trash")
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Pending sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry all") { controller.retryAllPending() }
                        .disabled(events.isEmpty || outbox.isFlushing)
                }
            }
            .confirmationDialog("Discard this event?",
                                isPresented: Binding(get: { confirmDiscard != nil },
                                                     set: { if !$0 { confirmDiscard = nil } }),
                                titleVisibility: .visible) {
                Button("Discard — the server will never see it", role: .destructive) {
                    if let id = confirmDiscard { controller.discardEvent(id) }
                    confirmDiscard = nil
                }
                Button("Keep", role: .cancel) { confirmDiscard = nil }
            }
        }
    }

    private func icon(for event: OutboxEvent) -> String {
        switch event.kind {
        case .startLoadout: return "shippingbox"
        case .piece: return "cube.fill"
        case .complete: return "checkmark.seal"
        case .undo: return "arrow.uturn.backward"
        }
    }
}

/// Transient post-add affordance: tap to pull the piece straight back out.
private struct UndoChip: View {
    let name: String
    /// Until the server has it, say so — a tick the operator can't trust is
    /// worse than no tick.
    let synced: Bool
    let onUndo: () -> Void

    var body: some View {
        Button(action: onUndo) {
            Label(synced ? "Added \(name) — Undo" : "Added \(name) · syncing — Undo",
                  systemImage: synced ? "arrow.uturn.backward" : "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.glass)
        .tint(synced ? Theme.accent : .orange)
    }
}

private struct LoadoutDecisionSheet: View {
    let decision: LoadoutDecision
    @ObservedObject var controller: CaptureController

    private enum Stage {
        case autoMatch(LibraryItem, Float)
        case suggest([ScoredCandidate])
        case newItem(matchingUnavailable: Bool)
    }

    @State private var stage: Stage
    @State private var newItemName = ""
    @State private var renaming = false
    @State private var confirmDiscard = false
    @State private var retryingFetch = false
    @State private var errorText: String?

    init(decision: LoadoutDecision, controller: CaptureController) {
        self.decision = decision
        _controller = ObservedObject(wrappedValue: controller)
        switch decision {
        case .auto(_, let item, let score): _stage = State(initialValue: .autoMatch(item, score))
        case .suggest(_, let candidates): _stage = State(initialValue: .suggest(candidates))
        case .none: _stage = State(initialValue: .newItem(matchingUnavailable: false))
        case .unavailable: _stage = State(initialValue: .newItem(matchingUnavailable: true))
        }
    }

    private var scan: ScanResult { decision.scan }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch stage {
                case .autoMatch(let item, let score): autoView(item, score)
                case .suggest(let candidates): suggestView(candidates)
                case .newItem(let unavailable): newItemView(matchingUnavailable: unavailable)
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button("Cancel") { confirmDiscard = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .confirmationDialog("Discard this piece?", isPresented: $confirmDiscard,
                                        titleVisibility: .visible) {
                        Button("Discard piece", role: .destructive) {
                            controller.loadoutDecision = nil
                        }
                        Button("Keep", role: .cancel) {}
                    }
            }
            .padding(22)
        }
    }

    private var dimsRow: some View {
        Text(String(format: "%.2f × %.2f × %.2f m",
                    scan.aabbDims.x, scan.aabbDims.z, scan.aabbDims.y))
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func autoView(_ item: LibraryItem, _ score: Float) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            VStack(spacing: 4) {
                Text(item.name.isEmpty ? item.sku : item.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !item.sku.isEmpty {
                    Text(item.sku).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            dimsRow

            Button {
                post(itemId: item.id, matchedBy: "auto",
                     name: item.name.isEmpty ? item.sku : item.name, score: score)
            } label: {
                Label("Add to load-out", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)

            Button("Choose different") {
                errorText = nil
                stage = .suggest(controller.loadoutCandidates(for: scan))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, 6)
    }

    private func suggestView(_ candidates: [ScoredCandidate]) -> some View {
        VStack(spacing: 14) {
            Text("Which item is this?").font(.title3.weight(.semibold))
            dimsRow

            if candidates.isEmpty {
                Text("No close matches in the library.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                let item = candidate.item
                Button {
                    post(itemId: item.id, matchedBy: "operator",
                         name: item.name.isEmpty ? item.sku : item.name,
                         score: candidate.distance,
                         overrideReason: "operator picked from suggestions")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.sku.isEmpty ? item.name : item.sku)
                                .font(.headline)
                            // An item that can't auto-match says so here, so
                            // choosing it is a deliberate act.
                            ForEach(candidate.flags, id: \.self) { flag in
                                Text(flag)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        if !item.sku.isEmpty && !item.name.isEmpty {
                            Text(item.name)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(deltaLine(for: candidate))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                errorText = nil
                stage = .newItem(matchingUnavailable: false)
            } label: {
                Label("New item", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, 6)
    }

    /// Deltas labelled by what each axis means, so they read against the dims
    /// row: L/W/H for upright items, max/mid/min for free orientation.
    private func deltaLine(for candidate: ScoredCandidate) -> String {
        let upright = candidate.item.orientation == "upright" || candidate.item.orientation == "vertical"
        let labels = upright ? ["L", "W", "H"] : ["max", "mid", "min"]
        return zip(labels, candidate.deltasCm)
            .map { String(format: "%@ %+.1f", $0.0, $0.1) }
            .joined(separator: " · ") + " cm"
    }

    /// An unknown piece at the dock gets a name, not a keyboard. It lands as a
    /// provisional library item a supervisor promotes later; naming it properly
    /// is optional and can wait until the truck is loaded.
    private func newItemView(matchingUnavailable: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text(resolvedName).font(.title3.weight(.semibold))
            dimsRow
            Text("Provisional — needs supervisor review before it can auto-match")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if matchingUnavailable {
                Button {
                    retryFetch()
                } label: {
                    if retryingFetch {
                        HStack(spacing: 10) { ProgressView(); Text("Fetching library…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Matching unavailable — Retry fetch", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(retryingFetch)
            }

            Button {
                addAsNewItem()
            } label: {
                Label("Add as \(resolvedName)", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(retryingFetch)

            if renaming {
                TextField("Item name (e.g. Vision camera tower)", text: $newItemName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } else {
                Button("Rename") { renaming = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(.top, 6)
    }

    private var resolvedName: String {
        let typed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? controller.nextUnknownPieceName : typed
    }

    /// Nothing here waits on a network. The piece goes into the durable outbox
    /// and the sheet closes; the tally moves immediately and the confirmation
    /// flash fires when the server actually has it.
    private func post(itemId: String, matchedBy: String, name: String,
                      score: Float? = nil, overrideReason: String? = nil) {
        errorText = nil
        controller.addLoadoutPiece(matchedItemId: itemId, matchedBy: matchedBy,
                                   scan: scan, displayName: name,
                                   matchScore: score, overrideReason: overrideReason)
    }

    /// The provisional item is created by the outbox's transport as step one of
    /// the same event, so the created id and the piece's event id stay bound
    /// together across a kill, a retry or a dead radio.
    private func addAsNewItem() {
        errorText = nil
        let name = resolvedName
        controller.addLoadoutPiece(matchedItemId: nil, matchedBy: "new-item",
                                   scan: scan, displayName: name,
                                   newItem: controller.provisionalSpec(name: name, scan: scan))
    }

    private func retryFetch() {
        retryingFetch = true
        errorText = nil
        Task { @MainActor in
            let ok = await controller.retryLibraryFetch()
            retryingFetch = false
            guard ok else {
                if case .failed(let message) = controller.libraryState {
                    errorText = "Library fetch failed: \(message)"
                } else {
                    errorText = "Library fetch failed."
                }
                return
            }
            switch controller.decide(for: scan) {
            case .auto(_, let item, let score): stage = .autoMatch(item, score)
            case .suggest(_, let candidates): stage = .suggest(candidates)
            case .none, .unavailable: stage = .newItem(matchingUnavailable: false)
            }
        }
    }
}

// MARK: - ARView bridge

private struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
