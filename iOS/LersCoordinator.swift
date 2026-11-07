import Foundation
import CoreFoundation

// MARK: - Sendable DTOs (Swift 6 strict concurrency)
// Всё, что пересекает границу актора, должно быть Sendable.
// Поэтому вместо «сырого» [String: Any] передаём типизированные структуры.

/// Все числовые параметры точки учёта, извлечённые из ответа ЛЭРС.
public struct PointValues: Sendable, Equatable {
    public var t1: Double?
    public var t2: Double?
    public var p1: Double?
    public var p2: Double?
    public var v1: Double?
    public var v2: Double?
    public var m1: Double?
    public var m2: Double?
    public var q: Double?
    public var tnv: Double?

    public init() {}
}

/// Снимок показаний прибора. Полный аналог WPF PointSnapshot.
public struct PointSnapshot: Sendable {
    public let pointId: Int
    public let deviceTime: Date?
    public let values: PointValues
    public let readAtUtc: Date
    public let polledOkAtUtc: Date?

    public init(pointId: Int, deviceTime: Date?, values: PointValues,
                readAtUtc: Date = Date(), polledOkAtUtc: Date? = nil) {
        self.pointId = pointId
        self.deviceTime = deviceTime
        self.values = values
        self.readAtUtc = readAtUtc
        self.polledOkAtUtc = polledOkAtUtc
    }

    public func age(nowUtc: Date = Date()) -> TimeInterval {
        max(0, nowUtc.timeIntervalSince(polledOkAtUtc ?? readAtUtc))
    }
}

/// Результат опроса точки (аналог WPF PollUpdate).
public struct PollOutcome: Sendable {
    public let pointId: Int
    public let state: PollState
    public let message: String
    public let snapshot: PointSnapshot?

    public init(pointId: Int, state: PollState, message: String, snapshot: PointSnapshot?) {
        self.pointId = pointId
        self.state = state
        self.message = message
        self.snapshot = snapshot
    }
}

/// Четыре объёма подпитки (аналог вызова vm.SetVolumes).
public struct PodpitkaVolumes: Sendable {
    public let report: Double?
    public let day: Double?
    public let today: Double?
    public let hour: Double?
}

/// Результат разбора архива показаний.
public struct ArchiveParseResult: Sendable {
    public var rows: [ArchiveRow] = []
    public var availableKinds: [String] = []
}

/// Часть параллельного запроса объёмов (Sendable для TaskGroup).
private struct VolumePart: Sendable {
    let key: Int
    let value: Double?
}

/// Ошибки подключения, которые показывает UI.
public enum LersNetworkError: Error, LocalizedError, Sendable {
    case invalidAddress
    case http(status: Int, body: String)
    case emptyToken
    case atsBlocked
    case transport(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Некорректный адрес сервера"
        case let .http(status, body):
            if status == 401 || status == 403 { return "Неверный логин или пароль" }
            return "Ошибка сервера: код \(status)\(body.isEmpty ? "" : " — \(body)")"
        case .emptyToken:
            return "Пустой токен авторизации"
        case .atsBlocked:
            return "ATS блокирует HTTP-соединение"
        case let .transport(code, message):
            switch code {
            case NSURLErrorTimedOut: return "Таймаут: сервер недоступен"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "Нет связи с сервером: \(message)"
            case NSURLErrorNotConnectedToInternet: return "Нет подключения к интернету"
            case NSURLErrorSecureConnectionFailed: return "Не удалось установить защищённое соединение"
            default: return "Ошибка сети: \(message)"
            }
        }
    }
}

// MARK: - LersCoordinator
/// Актор, владеющий ВСЕМ сетевым взаимодействием с ЛЭРС УЧЁТ.
///
/// Порт оригинального WPF-кода:
///  * PollCoordinator: 6 слотов приборов / 16 HTTP-слотов, блокировка канала
///    по объекту (nodeKey), дедупликация in-flight, кэш 3 мин, таймаут опроса
///    3 мин, таймаут запроса 30 с, экспоненциальный backoff, обработка
///    «канал занят», три варианта эндпоинта отключения.
///  * PodpitkaVolumeService: path/query-фолбэки, полный набор алиасов объёма,
///    фильтрация почасовых записей, фолбэк на /Consumption/Last.
///  * ParseArchiveResponse / FlattenRecord: текущие/часовые/суточные/месячные
///    архивы + legacy .NET Hashtable.
///
/// Соединение остаётся обычным HTTP: `http://{host}:{port}/api/v1`.
public actor LersCoordinator {

    // MARK: - Configuration

    private var baseUrl: String = ""
    private var token: String?
    private let session: URLSession

    /// Как в оригинале.
    public var cacheTtl: TimeInterval = 180
    public var pollTimeout: TimeInterval = 180
    public var requestTimeout: TimeInterval = 30

    private let maxDevicePolls = 6
    private let maxHttpSlots = 16

    // MARK: - Cache / in-flight / logs

    private var cache: [Int: PointSnapshot] = [:]
    private var inFlight: [Int: Task<PollOutcome, Never>] = [:]

    private var logs: [Int: [PollLogEntry]] = [:]
    private var logSubscribers: [Int: [SubscriberEntry]] = [:]
    private var nextSubscriberId: Int = 0

    private struct SubscriberEntry {
        let id: Int
        let continuation: AsyncStream<PollLogEntry>.Continuation
    }

    // MARK: - Slot pools (device / http / channel lock)
    // Один универсальный пул вместо трёх реализаций семафора.
    private enum Pool: Hashable, Sendable {
        case device
        case http
        case channel(String)
    }

    private var slotLimit: [Pool: Int] = [.device: 6, .http: 16]
    private var slotRunning: [Pool: Int] = [:]
    private var slotWaiters: [Pool: [CheckedContinuation<Void, Never>]] = [:]

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 16
        // Критично для опроса: нельзя допускать HTTP-кэширование /Consumption/Last,
        // иначе проверка «свежести» DeviceTime будет всегда видеть старый ответ.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    public func configure(host: String, port: Int, token: String?) {
        self.baseUrl = "http://\(host):\(port)/api/v1"
        self.token = token
        // Данные другого сервера не должны попадать в кэш.
        self.cache.removeAll()
    }

    public func getToken() -> String? { token }

    // MARK: - Login

    /// POST /api/v1/Login. Настраивает токен внутри актора.
    public func login(login: String, password: String) async throws -> String {
        guard !baseUrl.isEmpty else { throw LersNetworkError.invalidAddress }
        guard let url = URL(string: "\(baseUrl)/Login") else {
            throw LersNetworkError.invalidAddress
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: String] = [
            "login": login.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "application": "LersMonitor WPF"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let status: Int
        do {
            let (d, res) = try await session.data(for: req)
            data = d
            status = (res as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            let e = error as NSError
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                throw LersNetworkError.atsBlocked
            }
            throw LersNetworkError.transport(code: e.code, message: error.localizedDescription)
        }

        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LersNetworkError.http(status: status, body: String(body.prefix(200)))
        }

        var parsed = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = json["token"] as? String {
            parsed = t
        } else if let s = String(data: data, encoding: .utf8) {
            parsed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        }
        guard !parsed.isEmpty else { throw LersNetworkError.emptyToken }

        self.token = parsed
        return parsed
    }

    /// Лёгкая проверка живости сессии. Возвращает HTTP-код (0 = сетевая ошибка).
    public func ping() async -> Int {
        guard let url = URL(string: "\(baseUrl)/Core/MeasurePoints?type=Regular") else { return 0 }
        var req = authRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (_, res) = try await session.data(for: req)
            return (res as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }

    // MARK: - Core/Nodes и Core/MeasurePoints (порт MainWindow.Connect)

    public func fetchNodes() async -> [Int: String] {
        guard let url = URL(string: "\(baseUrl)/Core/Nodes") else { return [:] }
        guard let (data, code) = await send(url: url), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }

        let array: [[String: Any]]
        if let arr = json as? [[String: Any]] { array = arr }
        else if let dict = json as? [String: Any], let arr = dict["nodes"] as? [[String: Any]] { array = arr }
        else { array = [] }

        var result: [Int: String] = [:]
        for node in array {
            let id = intValue(node["id"])
            let title = (node["title"] as? String) ?? ""
            if id > 0 && !title.isEmpty { result[id] = title }
        }
        return result
    }

    public func fetchPoints() async -> [MeasurePointItem] {
        let nodeTitles = await fetchNodes()
        guard let url = URL(string: "\(baseUrl)/Core/MeasurePoints?type=Regular&getCustomers=true") else { return [] }
        guard let (data, code) = await send(url: url), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let array: [[String: Any]]
        if let arr = json as? [[String: Any]] { array = arr }
        else if let dict = json as? [String: Any], let arr = dict["measurePoints"] as? [[String: Any]] { array = arr }
        else { array = [] }

        var points: [MeasurePointItem] = []
        for item in array {
            let id = intValue(item["id"])
            guard id > 0 else { continue }
            let title = (item["title"] as? String) ?? "Точка"
            let nodeId = intValue(item["nodeId"])
            var nodeTitle = (item["nodeTitle"] as? String) ?? ""
            if nodeTitle.isEmpty, let mapped = nodeTitles[nodeId] { nodeTitle = mapped }
            if nodeTitle.isEmpty { nodeTitle = "Объект" }
            points.append(MeasurePointItem(id: id, title: title, nodeTitle: nodeTitle, nodeId: nodeId))
        }
        return points.sorted { ($0.nodeTitle, $0.title) < ($1.nodeTitle, $1.title) }
    }

    // MARK: - AsyncStream журнала (push-модель, без опроса)

    public func addLog(pointId: Int, state: PollState, message: String, phase: String) {
        let entry = PollLogEntry(state: state, message: message, phase: phase)
        var list = logs[pointId] ?? []
        list.append(entry)
        if list.count > 150 { list.removeFirst(list.count - 150) }
        logs[pointId] = list
        for sub in logSubscribers[pointId] ?? [] { sub.continuation.yield(entry) }
    }

    public func getLogs(pointId: Int) -> [PollLogEntry] { logs[pointId] ?? [] }

    public func clearLogs(pointId: Int) {
        logs[pointId] = []
        for sub in logSubscribers[pointId] ?? [] { sub.continuation.finish() }
        logSubscribers[pointId] = nil
    }

    public func logStream(pointId: Int) async -> AsyncStream<PollLogEntry> {
        let existingLogs = logs[pointId] ?? []
        let subscriberId = nextSubscriberId
        nextSubscriberId += 1
        return AsyncStream { continuation in
            for entry in existingLogs { continuation.yield(entry) }
            let coordinator = self
            Task {
                await coordinator.registerSubscriber(pointId: pointId, id: subscriberId, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task { await coordinator.removeSubscriber(pointId: pointId, subscriberId: subscriberId) }
            }
        }
    }

    private func registerSubscriber(pointId: Int, id: Int, continuation: AsyncStream<PollLogEntry>.Continuation) {
        logSubscribers[pointId, default: []].append(SubscriberEntry(id: id, continuation: continuation))
    }

    private func removeSubscriber(pointId: Int, subscriberId: Int) {
        guard var subs = logSubscribers[pointId] else { return }
        subs.removeAll { $0.id == subscriberId }
        if subs.isEmpty { logSubscribers.removeValue(forKey: pointId) }
        else { logSubscribers[pointId] = subs }
    }

    private func publish(_ pointId: Int, _ state: PollState, _ message: String) {
        addLog(pointId: pointId, state: state, message: message,
               phase: Self.phaseFor(state: state, message: message))
    }

    private static func phaseFor(state: PollState, message: String) -> String {
        if message.isEmpty { return "" }
        let m = message.lowercased()
        if state == .queued { return "Ожидание" }
        if m.contains("канал") || m.contains("очеред") { return "Дозвон" }
        if m.contains("снят") || m.contains("данные") { return "Снятие данных" }
        if m.contains("отключ") { return "Отключение" }
        if m.contains("опрос") || state == .polling { return "Опрос" }
        if state == .ok || state == .okCached { return "Готово" }
        if state == .error { return "Ошибка" }
        return ""
    }

    // MARK: - Публичный API опроса (порт PollCoordinator)

    /// Дедупликация: плановый и ручной опрос одной точки делят один запрос.
    public func poll(target: PollTarget, ignoreCache: Bool) async -> PollOutcome {
        if let existing = inFlight[target.pointId] {
            return await existing.value
        }
        let task = Task<PollOutcome, Never> {
            await self.runPoll(target: target, ignoreCache: ignoreCache)
        }
        inFlight[target.pointId] = task
        let outcome = await task.value
        inFlight[target.pointId] = nil
        return outcome
    }

    /// Совместимый с прежним кодом вариант вызова.
    public func pollPoint(pointId: Int, nodeTitle: String, ignoreCache: Bool) async -> PollOutcome {
        await poll(target: PollTarget(pointId: pointId, nodeKey: nodeTitle), ignoreCache: ignoreCache)
    }

    public func pollMany(_ targets: [PollTarget], ignoreCache: Bool) async -> [PollOutcome] {
        await withTaskGroup(of: PollOutcome.self) { group in
            for t in targets {
                group.addTask { await self.poll(target: t, ignoreCache: ignoreCache) }
            }
            var collected: [PollOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
    }

    /// Только прочитать то, что уже лежит в ЛЭРС, без опроса прибора.
    public func readOnly(target: PollTarget) async -> PollOutcome {
        guard let snap = await getLast(pointId: target.pointId) else {
            let msg = "Нет данных в ЛЭРС"
            publish(target.pointId, .error, msg)
            return PollOutcome(pointId: target.pointId, state: .error, message: msg, snapshot: nil)
        }
        cache[target.pointId] = snap
        let msg = "Снято \(Self.fmt(snap))"
        publish(target.pointId, .ok, msg)
        return PollOutcome(pointId: target.pointId, state: .ok, message: msg, snapshot: snap)
    }

    /// Прочитать актуальные показания (для Тнв и тренда).
    public func readLast(pointId: Int) async -> PointSnapshot? {
        await getLast(pointId: pointId)
    }

    // MARK: - Ядро опроса

    private func runPoll(target: PollTarget, ignoreCache: Bool) async -> PollOutcome {
        let id = target.pointId
        publish(id, .queued, "В очереди")

        if !ignoreCache, let c = cache[id], c.age() <= cacheTtl {
            return cachedOutcome(id, c)
        }

        let channel = Pool.channel(target.nodeKey)
        if slotLimit[channel] == nil { slotLimit[channel] = 1 }

        await acquire(channel)                       // 1 прибор на канал (объект) за раз
        await acquire(.device)                       // глобальный потолок 6
        let outcome = await pollDevice(target: target, ignoreCache: ignoreCache)
        release(.device)
        release(channel)
        return outcome
    }

    private func cachedOutcome(_ id: Int, _ s: PointSnapshot) -> PollOutcome {
        let minutes = Int(s.age() / 60)
        let msg = "Снято \(Self.fmt(s)) (данные \(minutes) мин назад, повторно не опрашивали)"
        publish(id, .okCached, msg)
        return PollOutcome(pointId: id, state: .okCached, message: msg, snapshot: s)
    }

    private func pollDevice(target: PollTarget, ignoreCache: Bool) async -> PollOutcome {
        let id = target.pointId
        publish(id, .polling, "Проверка актуальных данных в базе ЛЭРС")

        let first = await getLast(pointId: id)
        if let first, !ignoreCache, first.age() <= cacheTtl {
            cache[id] = first
            return cachedOutcome(id, first)
        }

        let before = first?.deviceTime
        var lastError = "Нет ответа от прибора"
        var hardErrors = 0
        let deadline = Date().addingTimeInterval(pollTimeout)
        var nextPostAt = Date()
        var delay: TimeInterval = 2

        while Date() < deadline {
            if Task.isCancelled { break }

            if Date() >= nextPostAt {
                publish(id, .polling, "Отправка команды опроса прибору (дозвон)")
                let (ok, code, err) = await postPoll(pointId: id)
                if ok {
                    nextPostAt = Date().addingTimeInterval(30)  // не долбим прибор повторными POST
                    publish(id, .polling, "Идёт опрос прибора...")
                } else {
                    lastError = err
                    if Self.isBusy(code: code, message: err) {
                        nextPostAt = Date().addingTimeInterval(5 + Double(Int.random(in: 0..<6)))
                        publish(id, .polling, "Ожидание канала...")
                    } else {
                        hardErrors += 1
                        if hardErrors >= 5 { break }            // быстрый отказ
                        nextPostAt = Date().addingTimeInterval(min(30, 3 * Double(hardErrors * hardErrors)))
                        publish(id, .polling, "Повтор (\(err))")
                    }
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(6, delay * 1.5)                         // 2 → 3 → 4.5 → 6 с

            publish(id, .polling, "Проверка снятых данных из базы ЛЭРС")
            if let snap = await getLast(pointId: id),
               let dt = snap.deviceTime,
               before.map({ dt > $0 }) ?? true {
                let fresh = PointSnapshot(pointId: id, deviceTime: dt, values: snap.values,
                                          readAtUtc: snap.readAtUtc, polledOkAtUtc: Date())
                cache[id] = fresh
                publish(id, .polling, "Отключение прибора, освобождение канала")
                await disconnect(pointId: id)
                let msg = "Опрошено \(Self.fmt(fresh))"
                publish(id, .ok, msg)
                return PollOutcome(pointId: id, state: .ok, message: msg, snapshot: fresh)
            }
        }

        // Отключаем прибор даже при таймауте — канал обязан быть освобождён.
        publish(id, .error, "Отключение прибора после таймаута")
        await disconnect(pointId: id)
        let msg = "Таймаут: \(lastError)"
        publish(id, .error, msg)
        return PollOutcome(pointId: id, state: .error, message: msg, snapshot: first)
    }

    private static func fmt(_ s: PointSnapshot) -> String {
        (s.deviceTime ?? s.readAtUtc).formatted(date: .omitted, time: .standard)
    }

    // MARK: - HTTP: дозвон, отключение, снятие данных

    private func getLast(pointId: Int) async -> PointSnapshot? {
        await acquire(.http)
        defer { release(.http) }
        guard let url = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/Last") else { return nil }
        guard let (data, code) = await send(url: url, timeout: requestTimeout), code == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PointSnapshot(pointId: pointId,
                             deviceTime: dateFrom(json, keys: ["dateTime", "deviceTime", "date"]),
                             values: extractValues(json),
                             readAtUtc: Date())
    }

    private func postPoll(pointId: Int) async -> (ok: Bool, code: Int, error: String) {
        await acquire(.http)
        defer { release(.http) }
        guard let url = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Currents?once=true") else {
            return (false, 0, "Некорректный адрес")
        }
        guard let (data, code) = await send(url: url, method: "POST", body: Data(), timeout: requestTimeout) else {
            return (false, 0, "Сбой сети")
        }
        if (200...299).contains(code) { return (true, code, "") }
        return (false, code, Self.parseLersError(data: data, status: code))
    }

    /// Три варианта эндпоинта отключения, как в оригинале. Ошибки игнорируются.
    public func disconnect(pointId: Int) async {
        await acquire(.http)
        defer { release(.http) }
        let variants: [(String, String, Data?)] = [
            ("/Poll/MeasurePoints/\(pointId)/Disconnect", "POST", Data()),
            ("/Poll/MeasurePoints/\(pointId)/Currents", "DELETE", nil),
            ("/Poll/MeasurePoints/\(pointId)/Stop", "POST", Data())
        ]
        for (path, method, body) in variants {
            guard let url = URL(string: baseUrl + path) else { continue }
            if let (_, code) = await send(url: url, method: method, body: body, timeout: 15),
               (200...299).contains(code) { return }
        }
    }

    /// Тренд: включаем непрерывный опрос прибора (без once=true).
    public func startTrendPolling(pointId: Int) async {
        guard let url = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Currents") else { return }
        _ = await send(url: url, method: "POST", body: Data(), timeout: requestTimeout)
    }

    public func stopTrendPolling(pointId: Int) async {
        guard let url = URL(string: "\(baseUrl)/Poll/MeasurePoints/\(pointId)/Currents") else { return }
        _ = await send(url: url, method: "DELETE", timeout: 15)
    }

    private static func isBusy(code: Int, message: String) -> Bool {
        if code == 409 || code == 423 { return true }
        let m = message.lowercased()
        return m.contains("занят") || m.contains("already") ||
               m.contains("используется") || m.contains("ожидани")
    }

    private static func parseLersError(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let a = json["errorDescription"] as? String { return a }
            if let b = json["errorMessage"] as? String { return b }
        }
        return "Отказ (\(status))"
    }

    // MARK: - PodpitkaVolumeService (объёмы подпитки)

    /// Порядок важен: как в оригинале, сначала объём подачи, затем масса, затем обратка.
    private static let volumeKeyList: [String] = [
        "v_in", "V_in", "v1", "V1", "v_mu", "V_mu", "volume1", "volume", "v", "V",
        "m_in", "M_in", "m1", "M1", "m_mu", "M_mu", "mass1", "mass", "m", "M",
        "v_delta", "V_delta", "m_delta", "M_delta", "v_out", "V_out", "v2", "V2"
    ]
    /// `Self` — ковариантный тип, его нельзя использовать в инициализаторе
    /// хранимого static-свойства (ошибка Swift 6). Ссылаемся на тип по имени.
    private static let volumeKeys: Set<String> =
        Set(LersCoordinator.volumeKeyList.map { $0.lowercased() })

    /// Суммарный объём V1 за период. Три формата URL + фильтрация почасовых записей.
    public func sumV1(pointId: Int, from: Date, to: Date, hourly: Bool,
                      hourFilterFrom: Date? = nil, hourFilterTo: Date? = nil) async -> Double? {
        await acquire(.http)
        defer { release(.http) }

        let f = Self.dayString(from)
        let t = Self.dayString(to)
        let kind = hourly ? "Hour" : "Day"
        let root = "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption"

        var urls: [URL] = []
        if let u = URL(string: "\(root)/\(f)/\(t)") { urls.append(u) }
        if let u = URL(string: "\(root)?start=\(f)&end=\(t)&dataKind=\(kind)") { urls.append(u) }
        if let u = URL(string: "\(root)?startDate=\(f)&endDate=\(t)&dataKind=\(kind)") { urls.append(u) }

        for url in urls {
            guard let (data, code) = await send(url: url, timeout: requestTimeout), code == 200 else { continue }
            if let value = parseConsumption(data: data, hourFilterFrom: hourFilterFrom, hourFilterTo: hourFilterTo) {
                return value
            }
        }
        return nil
    }

    /// Оперативный срез объёма из /Consumption/Last (фолбэк для неполного часа).
    public func lastInstantVolume(pointId: Int) async -> Double? {
        await acquire(.http)
        defer { release(.http) }
        guard let url = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/Last"),
              let (data, code) = await send(url: url, timeout: requestTimeout), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return extractVolume(json)
    }

    /// Полный цикл расчёта четырёх объёмов (порт RefreshAsync).
    public func refreshVolumes(pointId: Int, now: Date, startDay: Int, endDay: Int) async -> PodpitkaVolumes {
        let cal = Calendar.current
        let r = PodpitkaPeriod.report(now: now, startDay: startDay, endDay: endDay)
        let y = PodpitkaPeriod.yesterday(now: now)
        let t = PodpitkaPeriod.today(now: now)
        let h = PodpitkaPeriod.prevHour(now: now)

        // Путевой эндпоинт ЛЭРС включает обе границы → отнимаем один день.
        let reportEnd = cal.date(byAdding: .day, value: -1, to: r.toExclusive) ?? r.toExclusive
        let currentHour = cal.component(.hour, from: now)
        let pid = pointId

        // Параллельно, как Task.WhenAll в оригинале. Все результаты — Sendable.
        let parts = await withTaskGroup(of: VolumePart.self) { group in
            group.addTask {
                VolumePart(key: 0, value: await self.sumV1(pointId: pid, from: r.from, to: reportEnd, hourly: false))
            }
            group.addTask {
                VolumePart(key: 1, value: await self.sumV1(pointId: pid, from: y.from, to: y.from, hourly: false))
            }
            group.addTask {
                VolumePart(key: 2, value: await self.sumV1(pointId: pid, from: t.from, to: t.toExclusive,
                                                           hourly: true, hourFilterFrom: t.from, hourFilterTo: t.toExclusive))
            }
            group.addTask {
                VolumePart(key: 3, value: await self.sumV1(pointId: pid, from: h.from, to: h.toExclusive,
                                                           hourly: true, hourFilterFrom: h.from, hourFilterTo: h.toExclusive))
            }
            var collected: [Int: Double?] = [:]
            for await part in group { collected[part.key] = part.value }
            return collected
        }

        let report = parts[0] ?? nil
        let day = parts[1] ?? nil
        var today: Double? = currentHour > 0 ? (parts[2] ?? nil) : nil
        var hour: Double? = parts[3] ?? nil

        if hour == nil { hour = await lastInstantVolume(pointId: pid) }
        if today == nil, let hour { today = hour }

        return PodpitkaVolumes(report: report, day: day, today: today, hour: hour)
    }

    private func parseConsumption(data: Data, hourFilterFrom: Date?, hourFilterTo: Date?) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = json as? [String: Any], let single = extractVolume(dict) { return single }

        let records: [[String: Any]]
        if let arr = json as? [[String: Any]] {
            records = arr
        } else if let dict = json as? [String: Any] {
            // Берём первый непустой массив (у ЛЭРС это hourConsumption / dayConsumption / ...).
            records = dict.values.compactMap { $0 as? [[String: Any]] }.first { !$0.isEmpty } ?? []
        } else {
            records = []
        }
        guard !records.isEmpty else { return nil }

        var total = 0.0
        var hasData = false
        for record in records {
            if hourFilterFrom != nil || hourFilterTo != nil {
                guard let recDate = recordDate(record) else { continue }
                if let lo = hourFilterFrom, recDate < lo { continue }
                if let hi = hourFilterTo, recDate >= hi { continue }
            }
            if let v = extractVolume(record) {
                total += v
                hasData = true
            }
        }
        return hasData ? total : nil
    }

    private func recordDate(_ record: [String: Any]) -> Date? {
        dateFrom(record, keys: ["dateTime", "date", "targetDate", "timestamp", "d", "hour"])
    }

    private func extractVolume(_ record: [String: Any]) -> Double? {
        // 1. Прямые поля объекта: сначала в приоритетном порядке, затем регистронезависимо.
        for key in Self.volumeKeyList {
            if let d = number(record[key]) { return d }
        }
        for (key, value) in record where Self.volumeKeys.contains(key.lowercased()) {
            if let d = number(value) { return d }
        }
        // 2. Вложенные массивы параметров [{ dataParameter: "V_in", value: 11.0 }].
        for (_, value) in record {
            guard let arr = value as? [[String: Any]] else { continue }
            for item in arr {
                let param = (item["dataParameter"] as? String)
                    ?? (item["parameter"] as? String)
                    ?? (item["name"] as? String) ?? ""
                guard !param.isEmpty, Self.volumeKeys.contains(param.lowercased()) else { continue }
                if let d = number(item["value"] ?? item["val"]) { return d }
            }
        }
        // 3. Просто поле value без имени параметра.
        if let d = number(record["value"]) { return d }
        return nil
    }

    // MARK: - Архив показаний (порт ParseArchiveResponse / FlattenRecord)

    public func loadArchive(pointId: Int, kind: ArchiveKind, from: Date, to: Date) async -> ArchiveParseResult {
        await acquire(.http)
        defer { release(.http) }
        let f = Self.dayString(from)
        let t = Self.dayString(to)
        guard let url = URL(string: "\(baseUrl)/Data/MeasurePoints/\(pointId)/Consumption/\(f)/\(t)"),
              let (data, code) = await send(url: url, timeout: requestTimeout), code == 200 else {
            return ArchiveParseResult()
        }
        return parseArchive(data: data, kind: kind)
    }

    private func parseArchive(data: Data, kind: ArchiveKind) -> ArchiveParseResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return ArchiveParseResult() }
        var result = ArchiveParseResult()

        // Legacy .NET Hashtable: { Comparer, Count, Keys, Values }
        if let root = json as? [String: Any],
           let keys = root["Keys"] as? [Any],
           let values = root["Values"] as? [Any] {
            for (i, value) in values.enumerated() {
                if let dict = value as? [String: Any] {
                    let row = flattenRecord(dict)
                    if !row.isEmpty { result.rows.append(ArchiveRow(cells: row)) }
                } else if i < keys.count, let key = keys[i] as? String {
                    result.rows.append(ArchiveRow(cells: [key: scalarToString(value)]))
                }
            }
            if !result.rows.isEmpty { result.availableKinds.append(kind.rawValue) }
            return result
        }

        // Стандартный формат: объект с массивами *Consumption.
        let rootDict = json as? [String: Any]
        if let root = rootDict {
            for (name, value) in root {
                guard name.lowercased().hasSuffix("consumption"),
                      let arr = value as? [Any], !arr.isEmpty else { continue }
                result.availableKinds.append(name)
            }
        }

        var selected: [Any]?
        if let root = rootDict {
            for name in kind.arrayNames {
                if let arr = root[name] as? [Any] { selected = arr; break }
            }
            if selected?.isEmpty ?? true {
                for (name, value) in root {
                    guard name.lowercased().hasSuffix("consumption"),
                          name.lowercased() != "dataparametersunit",
                          let arr = value as? [Any], !arr.isEmpty else { continue }
                    selected = arr
                    break
                }
            }
        } else if let arr = json as? [Any] {
            selected = arr
        }

        guard let records = selected else { return result }
        for record in records {
            guard let dict = record as? [String: Any] else { continue }
            let row = flattenRecord(dict)
            if !row.isEmpty { result.rows.append(ArchiveRow(cells: row)) }
        }
        return result
    }

    /// Прямые поля + вложенный массив values [{dataParameter, value}].
    private func flattenRecord(_ record: [String: Any]) -> [String: String] {
        var row: [String: String] = [:]
        for (key, value) in record {
            if let arr = value as? [[String: Any]] {
                for item in arr {
                    let param = (item["dataParameter"] as? String)
                        ?? (item["parameter"] as? String)
                        ?? (item["name"] as? String)
                    let val = item["value"] ?? item["val"]
                    if let param, !param.isEmpty, val != nil {
                        row[param] = scalarToString(val)
                    }
                }
            } else {
                row[key] = scalarToString(value)
            }
        }
        return row
    }

    // MARK: - Разбор параметров точки (порт UpdatePointValues / ExtractParameterValue)

    private func extractValues(_ root: [String: Any]) -> PointValues {
        var v = PointValues()
        v.t1  = extractParameter(root, ["t_in", "t1", "temperatureIn", "T1", "t1Value", "T_in", "t_supply"])
        v.t2  = extractParameter(root, ["t_out", "t2", "temperatureOut", "T2", "t2Value", "T_out", "t_return"])
        v.p1  = extractParameter(root, ["p_in", "p1", "pressureIn", "P1", "p1Value", "P_in", "p_supply"])
        v.p2  = extractParameter(root, ["p_out", "p2", "pressureOut", "P2", "p2Value", "P_out", "p_return"])
        v.v1  = extractParameter(root, ["v_in", "v1", "volume1", "V1", "V_in", "volume_supply"])
        v.v2  = extractParameter(root, ["v_out", "v2", "volume2", "V2", "V_out", "volume_return"])
        v.m1  = extractParameter(root, ["m_in", "m1", "mass1", "M1", "M_in", "mass_supply"])
        v.m2  = extractParameter(root, ["m_out", "m2", "mass2", "M2", "M_out", "mass_return"])
        v.q   = extractParameter(root, ["q_delta", "q", "q_in", "q_out", "q_gvs", "Q_delta", "Q", "heat", "thermalEnergy"])
        v.tnv = extractParameter(root, ["t_out_env", "t_nv", "T_nv", "outdoorTemp", "t_outdoor", "t_env"])
        return v
    }

    private func extractParameter(_ root: [String: Any], _ aliases: [String]) -> Double? {
        for name in aliases {
            if let d = number(root[name]) { return d }
        }
        let wanted = Set(aliases.map { $0.lowercased() })
        for (key, value) in root where wanted.contains(key.lowercased()) {
            if let d = number(value) { return d }
        }
        for (_, value) in root {
            guard let arr = value as? [[String: Any]] else { continue }
            for item in arr {
                let param = (item["dataParameter"] as? String)
                    ?? (item["parameter"] as? String)
                    ?? (item["name"] as? String) ?? ""
                guard wanted.contains(param.lowercased()) else { continue }
                if let d = number(item["value"] ?? item["val"]) { return d }
            }
        }
        return nil
    }

    // MARK: - Низкоуровневые помощники

    private func authRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(url: URL, method: String = "GET", body: Data? = nil,
                      timeout: TimeInterval = 30) async -> (Data, Int)? {
        var req = authRequest(url: url, method: method)
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, res) = try await session.data(for: req)
            return (data, (res as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return nil
        }
    }

    private func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private func number(_ any: Any?) -> Double? {
        guard let any, !(any is NSNull) else { return nil }
        if let d = any as? Double { return d }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let s = any as? String {
            return Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func scalarToString(_ any: Any?) -> String {
        guard let any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let dict = any as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(any)"
    }

    private func dateFrom(_ dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let raw = dict[key], let s = raw as? String else { continue }
            if let d = Self.parseDate(s) { return d }
        }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFull.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    /// Локальный форматтер создаётся на каждый вызов: DateFormatter не является Sendable,
    /// поэтому статический экземпляр недопустим при Swift 6 strict concurrency.
    /// Часовой пояс системный — совпадает с WPF `ToString("yyyy-MM-dd")`.
    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Slot management (actor-isolated, без data race)

    private func acquire(_ pool: Pool) async {
        let limit = slotLimit[pool] ?? 1
        let running = slotRunning[pool] ?? 0
        if running < limit {
            slotRunning[pool] = running + 1
            return
        }
        await withCheckedContinuation { cont in
            slotWaiters[pool, default: []].append(cont)
        }
        // Слот передан напрямую из release(), счётчик не меняем.
    }

    private func release(_ pool: Pool) {
        if var waiters = slotWaiters[pool], !waiters.isEmpty {
            let next = waiters.removeFirst()
            slotWaiters[pool] = waiters
            next.resume()
        } else {
            slotRunning[pool] = max(0, (slotRunning[pool] ?? 0) - 1)
        }
    }
}
