import Combine
import Foundation

// A captured piece is operational truth. It must survive an app kill, a crash,
// a dead cell tower and an operator who ends the session by accident. Nothing
// on the dock path talks to the network directly any more: every action becomes
// a durable event on disk first, and the network is a background drain over it.
//
// Deliberately free of UIKit/ARKit/SwiftUI so it compiles and is testable
// off-device — see the swiftc harness used to verify kill/replay/backoff.

// MARK: - Event model

enum OutboxKind: String, Codable {
    case startLoadout
    case piece
    case complete
    case undo
}

enum OutboxState: String, Codable {
    case pending
    case inFlight
    /// The server has it. Safe to forget.
    case acked
    /// The server refused it outright (4xx that isn't 408/429). Needs a human:
    /// retrying the same body forever would just burn battery.
    case failed
}

struct OutboxStartPayload: Codable, Equatable {
    var clientStartId: String
    var reference: String
    var operatorName: String
    var planId: String?
}

/// A library item this piece has to create before it can be recorded. Carried
/// on the event (GLB included, in the outbox blob store) so the two-step
/// create-then-append survives a kill between the two halves.
struct OutboxNewItem: Codable, Equatable {
    var name: String
    var l: Double
    var w: Double
    var h: Double
    var mode: String
    /// Dock-created items never land in the permanent library unreviewed.
    var provisional: Bool = true
    /// Filename inside the outbox blob directory.
    var glbFile: String?
}

struct OutboxPiecePayload: Codable, Equatable {
    var eventId: String
    /// Mutable: the new-item path stamps the created id here after step one,
    /// so a retry appends against the item it already made.
    var matchedItemId: String?
    var matchedBy: String
    var overrideReason: String?
    var scanL: Double?
    var scanW: Double?
    var scanH: Double?
    var matchScore: Double?
    var matcherVersion: String?
    var qty: Int
    var note: String
    var operatorName: String
    var deviceAt: Date
    /// Local label only — the server snapshots sku/name from the library itself.
    var displayName: String
    var newItem: OutboxNewItem?
}

struct OutboxCompletePayload: Codable, Equatable {
    var clientEventId: String
}

struct OutboxUndoPayload: Codable, Equatable {
    /// Server-assigned piece id.
    var pieceId: String
    /// The client piece event this cancels, for local accounting.
    var eventId: String
    var displayName: String
}

enum OutboxPayload: Equatable {
    case start(OutboxStartPayload)
    case piece(OutboxPiecePayload)
    case complete(OutboxCompletePayload)
    case undo(OutboxUndoPayload)
}

extension OutboxPayload: Codable {
    private enum CodingKeys: String, CodingKey { case type, start, piece, complete, undo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "start": self = .start(try c.decode(OutboxStartPayload.self, forKey: .start))
        case "piece": self = .piece(try c.decode(OutboxPiecePayload.self, forKey: .piece))
        case "complete": self = .complete(try c.decode(OutboxCompletePayload.self, forKey: .complete))
        case "undo": self = .undo(try c.decode(OutboxUndoPayload.self, forKey: .undo))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown outbox payload \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let p): try c.encode("start", forKey: .type); try c.encode(p, forKey: .start)
        case .piece(let p): try c.encode("piece", forKey: .type); try c.encode(p, forKey: .piece)
        case .complete(let p): try c.encode("complete", forKey: .type); try c.encode(p, forKey: .complete)
        case .undo(let p): try c.encode("undo", forKey: .type); try c.encode(p, forKey: .undo)
        }
    }
}

struct OutboxEvent: Codable, Identifiable, Equatable {
    var id: String
    var kind: OutboxKind
    /// Resolved once the load-out's start event acks.
    var loadoutId: String?
    /// The client identity of the load-out this belongs to.
    var clientStartId: String?
    var payload: OutboxPayload
    var createdAt: Date
    var attempts: Int
    var lastError: String?
    var lastStatusCode: Int?
    var state: OutboxState

    init(id: String = UUID().uuidString,
         kind: OutboxKind,
         loadoutId: String? = nil,
         clientStartId: String? = nil,
         payload: OutboxPayload,
         createdAt: Date = Date(),
         attempts: Int = 0,
         lastError: String? = nil,
         lastStatusCode: Int? = nil,
         state: OutboxState = .pending) {
        self.id = id
        self.kind = kind
        self.loadoutId = loadoutId
        self.clientStartId = clientStartId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
        self.lastStatusCode = lastStatusCode
        self.state = state
    }

    /// What the operator sees in the pending-events sheet.
    var label: String {
        switch payload {
        case .start(let p): return "Open load-out \(p.reference)"
        case .piece(let p): return p.displayName.isEmpty ? "Piece" : p.displayName
        case .complete: return "Close load-out"
        case .undo(let p): return "Undo \(p.displayName)"
        }
    }
}

// MARK: - Transport

struct OutboxAck: Equatable {
    var loadoutId: String?
    var pieceId: String?
    var pieceCount: Int?
    var createdItemId: String?
    var duplicate: Bool = false
}

/// Reported mid-send so a half-finished two-step event is durable before the
/// second half is even attempted.
struct OutboxProgress: Equatable {
    var createdItemId: String?
    var loadoutId: String?
}

struct OutboxTransportError: LocalizedError, Equatable {
    /// nil means the request never got a reply — offline, DNS, timeout.
    let statusCode: Int?
    let message: String

    var errorDescription: String? { message }

    /// 408 and 429 are the server saying "later", not "no". Everything else in
    /// 4xx is a refusal that will refuse identically forever.
    var isRetryable: Bool {
        guard let statusCode else { return true }
        if statusCode == 408 || statusCode == 429 { return true }
        return !(400..<500).contains(statusCode)
    }

    static func offline(_ message: String) -> OutboxTransportError {
        OutboxTransportError(statusCode: nil, message: message)
    }
}

@MainActor
protocol OutboxTransport: AnyObject {
    /// Where piece GLBs live, set by the outbox at construction.
    var blobDirectory: URL? { get set }
    func send(_ event: OutboxEvent, progress: (OutboxProgress) -> Void) async throws -> OutboxAck
}

// MARK: - The queue

@MainActor
final class Outbox: ObservableObject {
    struct SessionCounts: Equatable {
        var loaded = 0
        var synced = 0
        var pending = 0
        var failed = 0
    }

    @Published private(set) var events: [OutboxEvent] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var ackedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var isFlushing = false

    /// Fired on the main actor the moment the server confirms an event.
    var onAck: ((OutboxEvent, OutboxAck) -> Void)?
    /// Fired when an event is refused outright.
    var onFail: ((OutboxEvent) -> Void)?

    /// Backoff base in seconds — 1/2/4/8/16. Tests shrink it.
    var backoffUnit: TimeInterval = 1.0
    /// Retries inside one flush pass before the load-out is left for the next.
    var maxAttemptsPerFlush = 5
    /// The live session's events are never pruned.
    var protectedStartId: String?

    var transport: OutboxTransport {
        didSet { transport.blobDirectory = blobDirectory }
    }

    let directory: URL
    let blobDirectory: URL
    private let storeURL: URL
    private var resolvedLoadoutIds: [String: String] = [:]
    private var flushTask: Task<Void, Never>?

    init(transport: OutboxTransport, directory: URL? = nil) {
        self.transport = transport
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        self.storeURL = base.appendingPathComponent("outbox.json")
        self.blobDirectory = base.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        transport.blobDirectory = blobDirectory
        load()
    }

    static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return base.appendingPathComponent("StereonOutbox", isDirectory: true)
    }

    // MARK: Persistence

    private struct Store: Codable {
        var version = 2
        var events: [OutboxEvent]
        var resolved: [String: String]
    }

    private func load() {
        defer { recount() }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(Store.self, from: data) else {
            // Never silently drop a queue we can't read — set it aside instead.
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = directory.appendingPathComponent("outbox-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: storeURL, to: quarantine)
            return
        }
        // An event the kill caught mid-send is pending again, not lost. The
        // server dedupes on its id, so a re-send can't double-count.
        events = store.events.map { event in
            var event = event
            if event.state == .inFlight { event.state = .pending }
            return event
        }
        resolvedLoadoutIds = store.resolved
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Store(events: events, resolved: resolvedLoadoutIds)) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent("outbox-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: storeURL.path) {
                _ = try fm.replaceItemAt(storeURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: storeURL)
            }
        } catch {
            try? data.write(to: storeURL, options: .atomic)
            try? fm.removeItem(at: tmp)
        }
    }

    private func recount() {
        pendingCount = events.filter { $0.state == .pending || $0.state == .inFlight }.count
        ackedCount = events.filter { $0.state == .acked }.count
        failedCount = events.filter { $0.state == .failed }.count
    }

    // MARK: Blob store (piece GLBs)

    @discardableResult
    func storeBlob(_ data: Data, name: String) -> String? {
        try? FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        do {
            try data.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func dropBlob(for event: OutboxEvent) {
        guard case .piece(let p) = event.payload, let file = p.newItem?.glbFile else { return }
        try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
    }

    // MARK: Enqueue / inspect

    @discardableResult
    func enqueue(_ event: OutboxEvent) -> OutboxEvent {
        var event = event
        if event.loadoutId == nil, let key = event.clientStartId {
            event.loadoutId = resolvedLoadoutIds[key]
        }
        events.append(event)
        save()
        recount()
        return event
    }

    var hasUnflushedEvents: Bool { events.contains { $0.state != .acked } }

    func unflushed(forStart clientStartId: String?) -> [OutboxEvent] {
        events.filter { $0.clientStartId == clientStartId && $0.state != .acked }
    }

    var unresolvedEvents: [OutboxEvent] { events.filter { $0.state != .acked } }

    var failedEvents: [OutboxEvent] { events.filter { $0.state == .failed } }

    func loadoutId(forStart clientStartId: String) -> String? { resolvedLoadoutIds[clientStartId] }

    /// The chip's three numbers. `loaded` counts pieces the operator believes
    /// are in the load-out; undone pieces stop counting.
    func counts(forStart clientStartId: String?) -> SessionCounts {
        guard let clientStartId else { return SessionCounts() }
        let mine = events.filter { $0.clientStartId == clientStartId }
        let undone = Set(mine.compactMap { event -> String? in
            guard case .undo(let u) = event.payload, event.state != .failed else { return nil }
            return u.eventId
        })
        let pieces = mine.filter { $0.kind == .piece && !undone.contains($0.id) }
        return SessionCounts(
            loaded: pieces.count,
            synced: pieces.filter { $0.state == .acked }.count,
            pending: pieces.filter { $0.state == .pending || $0.state == .inFlight }.count,
            failed: pieces.filter { $0.state == .failed }.count)
    }

    /// Pull a piece back out before it ever reached the server. Returns false
    /// if it is already gone (acked or in flight) and needs a server-side undo.
    func cancelPending(eventId: String) -> Bool {
        guard let i = index(of: eventId),
              events[i].state == .pending || events[i].state == .failed else { return false }
        let removed = events.remove(at: i)
        dropBlob(for: removed)
        save()
        recount()
        return true
    }

    func retry(eventId: String) {
        guard let i = index(of: eventId) else { return }
        events[i].state = .pending
        events[i].lastError = nil
        save()
        recount()
        Task { await flush() }
    }

    func retryAllFailed() {
        var touched = false
        for i in events.indices where events[i].state == .failed {
            events[i].state = .pending
            events[i].lastError = nil
            touched = true
        }
        if touched { save(); recount() }
        Task { await flush() }
    }

    /// Throws the event away for good. Only the operator gets to do this.
    func discard(eventId: String) {
        guard let i = index(of: eventId) else { return }
        let removed = events.remove(at: i)
        dropBlob(for: removed)
        save()
        recount()
    }

    private func index(of eventId: String) -> Int? { events.firstIndex { $0.id == eventId } }

    // MARK: Flush

    /// Serial, FIFO, in order within a load-out: start before pieces before
    /// complete. Concurrent callers join the pass already running.
    func flush() async {
        if let flushTask {
            await flushTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
        flushTask = task
        await task.value
        flushTask = nil
    }

    private func drain() async {
        isFlushing = true
        defer {
            isFlushing = false
            prune()
            recount()
            save()
        }

        // A load-out whose earlier event is still stuck must not have its later
        // events overtake it — a piece before its start would open a second
        // load-out on the server.
        var stalled = Set<String>()
        var cursor = 0
        while cursor < events.count {
            let event = events[cursor]
            cursor += 1
            guard event.state == .pending || event.state == .inFlight else { continue }
            let key = event.clientStartId ?? event.loadoutId ?? event.id
            if stalled.contains(key) { continue }

            if event.kind != .startLoadout, event.loadoutId == nil {
                guard let start = event.clientStartId, let resolved = resolvedLoadoutIds[start] else {
                    // The start hasn't landed yet: hold everything behind it.
                    stalled.insert(key)
                    continue
                }
                if let i = index(of: event.id) { events[i].loadoutId = resolved }
            }

            let drained = await attempt(eventId: event.id)
            if !drained { stalled.insert(key) }
        }
    }

    /// One event, with in-pass exponential backoff. Returns false only when the
    /// event is still pending and its load-out should be held for this pass.
    private func attempt(eventId: String) async -> Bool {
        var pass = 0
        while true {
            guard let i = index(of: eventId) else { return true }
            events[i].state = .inFlight
            events[i].attempts += 1
            pass += 1
            save()
            let event = events[i]

            do {
                let ack = try await transport.send(event) { [weak self] progress in
                    guard let self, let j = self.index(of: eventId) else { return }
                    if let created = progress.createdItemId,
                       case .piece(var piece) = self.events[j].payload {
                        piece.matchedItemId = created
                        self.events[j].payload = .piece(piece)
                    }
                    if let loadoutId = progress.loadoutId {
                        self.events[j].loadoutId = loadoutId
                        if let key = self.events[j].clientStartId {
                            self.resolvedLoadoutIds[key] = loadoutId
                        }
                    }
                    self.save()
                }
                guard let j = index(of: eventId) else { return true }
                if let loadoutId = ack.loadoutId {
                    events[j].loadoutId = loadoutId
                    if let key = events[j].clientStartId { resolvedLoadoutIds[key] = loadoutId }
                }
                if let created = ack.createdItemId, case .piece(var piece) = events[j].payload {
                    piece.matchedItemId = created
                    events[j].payload = .piece(piece)
                }
                events[j].state = .acked
                events[j].lastError = nil
                events[j].lastStatusCode = nil
                let acked = events[j]
                save()
                recount()
                dropBlob(for: acked)
                onAck?(acked, ack)
                return true
            } catch {
                guard let j = index(of: eventId) else { return true }
                let failure = (error as? OutboxTransportError)
                    ?? OutboxTransportError.offline(error.localizedDescription)
                events[j].lastError = failure.message
                events[j].lastStatusCode = failure.statusCode

                if !failure.isRetryable {
                    events[j].state = .failed
                    let failed = events[j]
                    save()
                    recount()
                    onFail?(failed)
                    // A refusal parks this one event. Everything after it keeps
                    // draining; only its own dependents stall, because the
                    // load-out id it would have resolved never arrives.
                    return true
                }

                events[j].state = .pending
                save()
                recount()
                if pass >= maxAttemptsPerFlush { return false }
                let seconds = min(16.0, pow(2.0, Double(pass - 1))) * backoffUnit
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
        }
    }

    // MARK: Housekeeping

    /// Closed sessions stop earning their disk space once everything acked.
    private func prune() {
        let closed = Set(events.compactMap { event -> String? in
            guard event.kind == .complete, event.state == .acked,
                  let key = event.clientStartId, key != protectedStartId else { return nil }
            return key
        })
        guard !closed.isEmpty else { return }
        let stillOpen = Set(events.compactMap { event -> String? in
            guard event.state != .acked, let key = event.clientStartId else { return nil }
            return key
        })
        let drop = closed.subtracting(stillOpen)
        guard !drop.isEmpty else { return }
        events.removeAll { event in
            guard let key = event.clientStartId else { return false }
            return drop.contains(key) && event.state == .acked
        }
        for key in drop { resolvedLoadoutIds.removeValue(forKey: key) }
    }
}
