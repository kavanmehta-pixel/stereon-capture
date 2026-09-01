import Foundation
import simd

/// The Stereon pilot server, v2 resource model: a load-out is identified by its
/// server `loadoutId`, and the human reference is metadata. Every write is
/// idempotent on a client-generated id, so the outbox can re-send anything it
/// isn't sure about without double-counting freight.
enum StereonServer {
    // Pairing entered in Settings wins; anything unset falls back to the
    // compile-time defaults in StereonConfig.swift, which is gitignored — a
    // key was committed here once, leaked with the repo, and had to be
    // rotated. If the build fails on those two symbols, copy
    // StereonConfig.example.swift.txt to Sources/StereonConfig.swift and fill
    // in the real values.
    static var baseURL: URL { StereonSettings.resolvedBaseURL }
    static var accessKey: String { StereonSettings.resolvedAccessKey }

    // MARK: - Scan inbox

    /// Returns the created library item id. `provisional` marks a dock-created
    /// item as needing supervisor review before it can ever auto-match.
    static func uploadScan(glb: Data, name: String, l: Float, w: Float, h: Float,
                           mode: String, provisional: Bool) async throws -> String {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/scan-inbox"),
                                  resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "l", value: String(format: "%.4f", l)),
            URLQueryItem(name: "w", value: String(format: "%.4f", w)),
            URLQueryItem(name: "h", value: String(format: "%.4f", h)),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "operator", value: StereonSettings.resolvedOperatorName),
        ]
        if provisional { query.append(URLQueryItem(name: "provisional", value: "1")) }
        comps.queryItems = query
        guard let url = comps.url else { throw OutboxTransportError.offline("Bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(accessKey, forHTTPHeaderField: "x-access-key")
        request.setValue("model/gltf-binary", forHTTPHeaderField: "Content-Type")

        let json = try await run(request, body: glb)
        guard let itemId = json["itemId"] as? String else {
            throw OutboxTransportError.offline("Unexpected server reply")
        }
        return itemId
    }

    /// Capture-convention wrapper: x = l, z = w, y = h.
    static func uploadScan(glb: Data, name: String, dims: SIMD3<Float>,
                           mode: CaptureMode, provisional: Bool = false) async throws -> String {
        try await uploadScan(glb: glb, name: name, l: dims.x, w: dims.z, h: dims.y,
                             mode: mode == .lidarMesh ? "lidarMesh" : "boxFit",
                             provisional: provisional)
    }

    // MARK: - Library

    /// The match-relevant slice of the library, for on-device piece matching.
    static func fetchLibraryLite() async throws -> [LibraryItem] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/library-lite"))
        request.timeoutInterval = 20
        request.setValue(accessKey, forHTTPHeaderField: "x-access-key")
        let data = try await runRaw(request)
        struct LibraryReply: Decodable { let items: [LibraryItem] }
        do {
            return try JSONDecoder().decode(LibraryReply.self, from: data).items
        } catch {
            throw OutboxTransportError.offline("Couldn't read the library reply")
        }
    }

    // MARK: - Load-outs (v2)

    struct StartReply { let loadoutId: String; let resumed: Bool }

    /// Idempotent on `clientStartId`: the same id always returns the same
    /// load-out, so a retry after a timeout can never open a second one.
    static func startLoadout(clientStartId: String, reference: String,
                             operatorName: String, planId: String?) async throws -> StartReply {
        var body: [String: Any] = [
            "clientStartId": clientStartId,
            "reference": reference,
            "operator": operatorName,
        ]
        if let planId, !planId.isEmpty { body["planId"] = planId }
        let reply = try await postJSON(path: "api/loadouts/start", body: body)
        guard let loadoutId = reply["loadoutId"] as? String, !loadoutId.isEmpty else {
            throw OutboxTransportError.offline("Server didn't return a load-out id")
        }
        return StartReply(loadoutId: loadoutId, resumed: reply["resumed"] as? Bool ?? false)
    }

    struct LoadOutPieceReply {
        let pieceId: String
        let pieceCount: Int?
        let duplicate: Bool
    }

    /// Appends one evidence record. Idempotent on `eventId` inside the
    /// load-out; 409 when the load-out is already completed, which the outbox
    /// treats as terminal rather than silently opening a new one.
    static func postPiece(loadoutId: String, eventId: String,
                          piece: [String: Any]) async throws -> LoadOutPieceReply {
        let reply = try await postJSON(path: "api/loadouts/\(escape(loadoutId))/pieces",
                                       body: ["eventId": eventId, "piece": piece])
        return LoadOutPieceReply(pieceId: reply["pieceId"] as? String ?? eventId,
                                 pieceCount: reply["pieceCount"] as? Int,
                                 duplicate: reply["duplicate"] as? Bool ?? false)
    }

    /// Closes the load-out. Completing twice is fine.
    static func completeLoadout(loadoutId: String, clientEventId: String) async throws {
        _ = try await postJSON(path: "api/loadouts/\(escape(loadoutId))/complete",
                               body: ["clientEventId": clientEventId])
    }

    /// Pulls one piece back out. Returns the server's piece count when it sends one.
    @discardableResult
    static func undoPiece(loadoutId: String, pieceId: String) async throws -> Int? {
        let reply = try await postJSON(
            path: "api/loadouts/\(escape(loadoutId))/pieces/\(escape(pieceId))/undo", body: [:])
        return reply["pieceCount"] as? Int
    }

    // MARK: - Progress & plans

    struct LoadoutProgress: Decodable {
        struct Expected: Decodable {
            let itemId: String
            let sku: String
            let name: String
            let planned: Int

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                itemId = try c.decodeIfPresent(String.self, forKey: .itemId) ?? ""
                sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? ""
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
                planned = try c.decodeIfPresent(Int.self, forKey: .planned) ?? 0
            }
            private enum CodingKeys: String, CodingKey { case itemId, sku, name, planned }
        }

        struct Loaded: Decodable {
            let itemId: String
            let loaded: Int

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                itemId = try c.decodeIfPresent(String.self, forKey: .itemId) ?? ""
                loaded = try c.decodeIfPresent(Int.self, forKey: .loaded) ?? 0
            }
            private enum CodingKeys: String, CodingKey { case itemId, loaded }
        }

        struct Unexpected: Decodable {
            let itemId: String?
            let name: String
            let count: Int

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
                count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
            }
            private enum CodingKeys: String, CodingKey { case itemId, name, count }
        }

        let expected: [Expected]
        let loaded: [Loaded]
        let unexpected: [Unexpected]
        let reconciled: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            expected = try c.decodeIfPresent([Expected].self, forKey: .expected) ?? []
            loaded = try c.decodeIfPresent([Loaded].self, forKey: .loaded) ?? []
            unexpected = try c.decodeIfPresent([Unexpected].self, forKey: .unexpected) ?? []
            reconciled = try c.decodeIfPresent(Bool.self, forKey: .reconciled) ?? false
        }
        private enum CodingKeys: String, CodingKey { case expected, loaded, unexpected, reconciled }
    }

    static func progress(loadoutId: String) async throws -> LoadoutProgress {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/loadouts/\(escape(loadoutId))/progress"))
        request.timeoutInterval = 15
        request.setValue(accessKey, forHTTPHeaderField: "x-access-key")
        let data = try await runRaw(request)
        do {
            return try JSONDecoder().decode(LoadoutProgress.self, from: data)
        } catch {
            throw OutboxTransportError.offline("Couldn't read the progress reply")
        }
    }

    /// The plan picker's list. The endpoint may not exist yet — callers degrade
    /// silently to a typed plan id.
    struct PlanLite: Identifiable, Decodable, Equatable {
        let id: String
        let name: String
        let pieceCount: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            let name = try c.decodeIfPresent(String.self, forKey: .name)
            let reference = try c.decodeIfPresent(String.self, forKey: .reference)
            self.name = name ?? reference ?? id
            pieceCount = try c.decodeIfPresent(Int.self, forKey: .pieceCount)
        }
        private enum CodingKeys: String, CodingKey { case id, name, reference, pieceCount }
    }

    static func plansLite() async throws -> [PlanLite] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/plans-lite"))
        request.timeoutInterval = 15
        request.setValue(accessKey, forHTTPHeaderField: "x-access-key")
        let data = try await runRaw(request)
        struct Reply: Decodable { let plans: [PlanLite] }
        if let reply = try? JSONDecoder().decode(Reply.self, from: data) { return reply.plans }
        if let plans = try? JSONDecoder().decode([PlanLite].self, from: data) { return plans }
        return []
    }

    // MARK: - Plumbing

    /// One path segment. Unreserved characters stay readable in the logs;
    /// anything else — a slash above all — is encoded.
    private static let pathSegment: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: pathSegment) ?? component
    }

    private static func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(accessKey, forHTTPHeaderField: "x-access-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(request, body: nil)
    }

    /// Every HTTP failure comes back as an `OutboxTransportError` carrying the
    /// status code, because the outbox's retry decision depends on it.
    private static func runRaw(_ request: URLRequest, body: Data? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await URLSession.shared.upload(for: request, from: body)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            throw OutboxTransportError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OutboxTransportError.offline("No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OutboxTransportError(statusCode: http.statusCode,
                                       message: detail ?? "Server returned \(http.statusCode)")
        }
        return data
    }

    private static func run(_ request: URLRequest, body: Data?) async throws -> [String: Any] {
        let data = try await runRaw(request, body: body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Outbox transport

/// Turns a durable outbox event into the v2 call it stands for. Nothing here
/// decides whether to retry — that is the outbox's job, driven by the status
/// code on the thrown `OutboxTransportError`.
@MainActor
final class StereonOutboxTransport: OutboxTransport {
    var blobDirectory: URL?

    func send(_ event: OutboxEvent, progress: (OutboxProgress) -> Void) async throws -> OutboxAck {
        switch event.payload {
        case .start(let p):
            let reply = try await StereonServer.startLoadout(clientStartId: p.clientStartId,
                                                             reference: p.reference,
                                                             operatorName: p.operatorName,
                                                             planId: p.planId)
            progress(OutboxProgress(loadoutId: reply.loadoutId))
            return OutboxAck(loadoutId: reply.loadoutId)

        case .piece(let p):
            guard let loadoutId = event.loadoutId else {
                throw OutboxTransportError.offline("Load-out isn't open on the server yet")
            }
            var itemId = p.matchedItemId
            var createdItemId: String?

            // Two operations, one event: create the provisional item, then
            // append the piece. The created id is reported the moment it
            // exists, so a failure on the second half never makes a duplicate.
            if itemId == nil, let spec = p.newItem {
                let created = try await StereonServer.uploadScan(
                    glb: glbData(for: spec),
                    name: spec.name,
                    l: Float(spec.l), w: Float(spec.w), h: Float(spec.h),
                    mode: spec.mode,
                    provisional: spec.provisional)
                itemId = created
                createdItemId = created
                progress(OutboxProgress(createdItemId: created))
            }

            var piece: [String: Any] = [
                "matchedItemId": itemId ?? NSNull(),
                "matchedBy": p.matchedBy,
                "qty": p.qty,
                "note": p.note,
                "operator": p.operatorName,
                "deviceAt": ISO8601DateFormatter().string(from: p.deviceAt),
            ]
            if let l = p.scanL, let w = p.scanW, let h = p.scanH {
                piece["scanDims"] = ["l": l, "w": w, "h": h]
                // Flat keys as well: the legacy shim reads these.
                piece["scanL"] = l
                piece["scanW"] = w
                piece["scanH"] = h
            }
            if let score = p.matchScore { piece["matchScore"] = score }
            if let version = p.matcherVersion { piece["matcherVersion"] = version }
            if let reason = p.overrideReason { piece["overrideReason"] = reason }

            let reply = try await StereonServer.postPiece(loadoutId: loadoutId,
                                                          eventId: p.eventId,
                                                          piece: piece)
            return OutboxAck(pieceId: reply.pieceId, pieceCount: reply.pieceCount,
                             createdItemId: createdItemId, duplicate: reply.duplicate)

        case .complete(let p):
            guard let loadoutId = event.loadoutId else {
                throw OutboxTransportError.offline("Load-out isn't open on the server yet")
            }
            try await StereonServer.completeLoadout(loadoutId: loadoutId, clientEventId: p.clientEventId)
            return OutboxAck()

        case .undo(let p):
            guard let loadoutId = event.loadoutId else {
                throw OutboxTransportError.offline("Load-out isn't open on the server yet")
            }
            let count = try await StereonServer.undoPiece(loadoutId: loadoutId, pieceId: p.pieceId)
            return OutboxAck(pieceCount: count)
        }
    }

    /// A failed mesh export must not strand the piece — fall back to a
    /// dims-only box so the scan inbox still accepts the provisional item.
    private func glbData(for spec: OutboxNewItem) -> Data {
        if let file = spec.glbFile, let dir = blobDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent(file)) {
            return data
        }
        let box = BoxMesh.make(width: Float(spec.l), depth: Float(spec.w), height: Float(spec.h))
        return GLBWriter.encode(vertices: box.vertices, normals: box.normals, indices: box.indices)
    }
}
