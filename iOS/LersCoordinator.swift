import Foundation

public struct PointSnapshot: @unchecked Sendable {
    public let pointId: Int
    public let deviceTime: Date?
    public let rawJson: [String: Any]
    public let readAtUtc: Date
    public let polledOkAtUtc: Date?

    public func age(nowUtc: Date) -> TimeInterval {
        let best = polledOkAtUtc ?? readAtUtc
        return max(0, nowUtc.timeIntervalSince(best))
    }
}

// MARK: - LersCoordinator
// Actor that handles all network communication with the LERS server.
// Provides AsyncStream for log entries (push model, no polling).
// Concurrency-limited device polling via semaphore slots.
public actor LersCoordinator {
    private var baseUrl: String = ""
    private var token: String?
    private let session: URLSession

    // Cache
    private var cache: [Int: PointSnapshot] = [:]

    // Log storage + stream subscribers
    // We use a simple Int counter as subscriber ID since AsyncStream.Continuation
    // is a struct (value type) and cannot be compared by reference identity.
    private var logs: [Int: [PollLogEntry]] = [:]
    private var logSubscribers: [Int: [SubscriberEntry]] = [:]
    private var nextSubscriberId: Int = 0

    // Simple struct to hold subscriber info
    private struct SubscriberEntry {
        let id: Int
        let continuation: AsyncStream<PollLogEntry>.Continuation
    }

    // Concurrency limit for device polls
    private let maxDeviceSlots = 4
    private var runningSlots = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    public func configure(host: String, port: Int, token: String?) {
        self.baseUrl = "http://\(host):\(port)/api/v1"
        self.token = token
    }

    public func getToken() -> String? { token }

    // MARK: - Logging with AsyncStream push
    public func addLog(pointId: Int, state: PollState, message: String, phase: String) {
        let entry = PollLogEntry(state: state, message: message, phase: phase)
        var list = logs[pointId] ?? []
        list.append(entry)
        if list.count > 150 { list.removeFirst(list.count - 150) }
        logs[pointId] = list

        // Push to all subscribers for this point
        if let subs = logSubscribers[pointId] {
            for sub in subs {
                sub.continuation.yield(entry)
            }
        }
    }

    public func getLogs(pointId: Int) -> [PollLogEntry] {
        return logs[pointId] ?? []
    }

    public func clearLogs(pointId: Int) {
        logs[pointId] = []
        // Finish all subscribers so streams end gracefully
        if let subs = logSubscribers[pointId] {
            for sub in subs {
                sub.continuation.finish()
            }
            logSubscribers[pointId] = nil
        }
    }

    /// Subscribe to real-time log updates for a specific point.
    /// Returns an AsyncStream that yields new log entries as they happen,
    /// plus immediately replays existing logs.
    ///
    /// This method is async because it needs to access actor-isolated state
    /// (existing logs, subscriber registry) before creating the stream.
    public func logStream(pointId: Int) async -> AsyncStream<PollLogEntry> {
        // Capture existing logs to replay (copied while on the actor)
        let existingLogs = logs[pointId] ?? []

        // Allocate a subscriber ID
        let subscriberId = nextSubscriberId
        nextSubscriberId += 1

        // Create the stream — the closure runs in a non-isolated context,
        // so we capture `self` and call async actor methods from within.
        return AsyncStream { continuation in
            // Replay existing logs
            for entry in existingLogs {
                continuation.yield(entry)
            }

            // Register as subscriber — must go through actor isolation
            let coordinator = self
            Task {
                await coordinator.registerSubscriber(pointId: pointId, id: subscriberId, continuation: continuation)
            }

            continuation.onTermination = { _ in
                Task {
                    await coordinator.removeSubscriber(pointId: pointId, subscriberId: subscriberId)
                }
            }
        }
    }

    private func registerSubscriber(pointId: Int, id: Int, continuation: AsyncStream<PollLogEntry>.Continuation) {
        logSubscribers[pointId, default: []].append(SubscriberEntry(id: id, continuation: continuation))
    }

    private func removeSubscriber(pointId: Int, subscriberId: Int) {
        if var subs = logSubscribers[pointId] {
            subs.removeAll { $0.id == subscriberId }
            if subs.isEmpty {
                logSubscribers.removeValue(forKey: pointId)
            } else {
                logSubscribers[pointId] = subs
            }
        }
    }

    // MARK: - Authenticated request builder
    private func authRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Poll a single measure point
    public func pollPoint(pointId: Int, nodeTitle: String, ignoreCache: Bool) async -> (PollState, String, [String: Any]?) {
        addLog(pointId: pointId, state: .queued, message: "В очереди опроса", phase: "Ожидание")

        if !ignoreCache, let snap = cache[pointId], snap.age(nowUtc: Date()) < 180 {
            let ageMin = Int(snap.age(nowUtc: Date()) / 60)
            let msg = "Снято из кэша (\(ageMin) мин назад)"
            addLog(pointId: pointId, state: .okCached, message: msg, phase: "Готово")
            return (.okCached, msg, snap.rawJson)
        }

        await acquireSlot()
        defer { releaseSlot() }

        addLog(pointId: pointId, state: .polling, message: "Отправка команды дозвона", phase: "Дозвон")
        if let postUrl = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Currents?once=true") {
            var req = authRequest(url: postUrl, method: "POST")
            req.httpBody = Data()
            _ = try? await session.data(for: req)
        }

        let deadline = Date().addingTimeInterval(35)
        var freshJson: [String: Any]? = nil

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let lastUrl = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/Last") {
                if let (data, res) = try? await session.data(for: authRequest(url: lastUrl)),
                   (res as? HTTPURLResponse)?.statusCode == 200,
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    freshJson = dict
                    break
                }
            }
        }

        // Always disconnect the device to free the channel
        addLog(pointId: pointId, state: .polling, message: "Отключение прибора (освобождение канала)", phase: "Отключение")
        if let disconUrl = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Disconnect") {
            var req = authRequest(url: disconUrl, method: "POST")
            req.httpBody = Data()
            _ = try? await session.data(for: req)
        }

        if let json = freshJson {
            let snap = PointSnapshot(pointId: pointId, deviceTime: Date(), rawJson: json, readAtUtc: Date(), polledOkAtUtc: Date())
            cache[pointId] = snap
            addLog(pointId: pointId, state: .ok, message: "Опрос успешно завершен", phase: "Готово")
            return (.ok, "Опрошено \(Date().formatted(date: .omitted, time: .standard))", json)
        } else {
            addLog(pointId: pointId, state: .error, message: "Таймаут: нет ответа от прибора", phase: "Ошибка")
            return (.error, "Таймаут ответа прибора", nil)
        }
    }

    // MARK: - Read V1 consumption for podpitka
    public func sumV1(pointId: Int, from: Date, to: Date, hourly: Bool) async -> Double? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fromStr = fmt.string(from: from)
        let toStr = fmt.string(from: to)

        guard let url = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/\(fromStr)/\(toStr)") else { return nil }
        guard let (data, res) = try? await session.data(for: authRequest(url: url)),
              (res as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var total = 0.0
        var foundAny = false

        let records: [[String: Any]]
        if let arr = root as? [[String: Any]] { records = arr }
        else if let dict = root as? [String: Any] {
            records = (dict["dayConsumption"] as? [[String: Any]]) ??
                      (dict["hourConsumption"] as? [[String: Any]]) ?? []
        } else { records = [] }

        let targetKeys = ["v_in", "v1", "v_mu", "volume1", "v", "m_in", "m1"]
        for rec in records {
            if let arr = rec["values"] as? [[String: Any]] {
                for item in arr {
                    let pName = ((item["dataParameter"] as? String) ?? "").lowercased()
                    if targetKeys.contains(pName) {
                        if let v = item["value"] as? Double { total += v; foundAny = true }
                        else if let s = item["value"] as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) {
                            total += d; foundAny = true
                        }
                    }
                }
            }
        }
        return foundAny ? total : nil
    }

    // MARK: - Slot management for concurrent device polling
    private func acquireSlot() async {
        if runningSlots < maxDeviceSlots {
            runningSlots += 1
            return
        }
        await withCheckedContinuation { cont in
            slotWaiters.append(cont)
        }
        runningSlots += 1
    }

    private func releaseSlot() {
        runningSlots -= 1
        if !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.resume()
        }
    }
}
