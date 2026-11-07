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

public actor LersCoordinator {
    private var baseUrl: String = ""
    private var token: String?
    private let session: URLSession
    
    // Кэш и логи
    private var cache: [Int: PointSnapshot] = [:]
    private var logs: [Int: [PollLogEntry]] = [:]
    
    // Ограничение одновременных дозвонов (в C# SemaphoreSlim maxDevicePolls = 6)
    private let maxDeviceSlots = 4
    private var runningSlots = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }
    
    public func configure(host: String, port: Int, token: String?) {
        self.baseUrl = "http://\(host):\(port)/api/v1"
        self.token = token
    }
    
    public func addLog(pointId: Int, state: PollState, message: String, phase: String) {
        var list = logs[pointId] ?? []
        list.append(PollLogEntry(state: state, message: message, phase: phase))
        if list.count > 150 { list.removeFirst(list.count - 150) }
        logs[pointId] = list
    }
    
    public func getLogs(pointId: Int) -> [PollLogEntry] {
        return logs[pointId] ?? []
    }
    
    public func clearLogs(pointId: Int) {
        logs[pointId] = []
    }
    
    private func authRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
    
    // MARK: - Опрос точки с освобождением канала связи
    public func pollPoint(pointId: Int, nodeTitle: String, ignoreCache: Bool) async -> (PollState, String, [String: Any]?) {
        addLog(pointId: pointId, state: .queued, message: "В очереди опроса", phase: "Ожидание")
        
        if !ignoreCache, let snap = cache[pointId], snap.age(nowUtc: Date()) < 180 {
            let msg = "Снято из кэша (\(Int(snap.age(nowUtc: Date()) / 60)) мин назад)"
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
        
        // Гарантированное отключение прибора (Disconnect)
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
    
    // MARK: - Чтение суммарного расхода V1 для модуля подпитки
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
    
    private func acquireSlot() async {
        if runningSlots < maxDeviceSlots {
            runningSlots += 1
            return
        }
        await withCheckedContinuation { cont in
            slotWaiters.append(cont)
        }
    }
    
    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.resume()
        } else {
            runningSlots = max(0, runningSlots - 1)
        }
    }
}
