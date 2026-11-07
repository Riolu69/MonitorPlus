import Foundation
import SwiftUI

// Sendable struct to hold connection info (tuples aren't Sendable in Swift 6)
struct ConnectionInfo: Sendable {
    let host: String
    let port: Int
    let token: String
}

// Sendable result for parallel podpitka queries
struct PodpitkaResult: Sendable {
    let pointId: Int
    let report: Double?
    let day: Double?
    let today: Double?
    let hour: Double?
}

@Observable
@MainActor
public final class AppViewModel {
    public var settings = UserSettings()
    public var isConnected: Bool = false
    public var statusText: String = "Готово к работе"
    public var isPollingAll: Bool = false

    public var allPoints: [MeasurePointItem] = []
    public var filteredPoints: [MeasurePointItem] = []
    public var dashboardGroups: [DashboardNodeGroup] = []
    public var podpitkaGroups: [PodpitkaNodeGroup] = []
    public var trendHistory: [PointResultData] = []

    // Filters
    public var searchText: String = "" { didSet { applyFilter() } }
    public var selectedNodeFilter: String = "Все объекты" { didSet { applyFilter() } }
    public var selectedSystemFilter: String = "Все системы" { didSet { applyFilter() } }

    // Current outdoor temperature
    public var globalTnv: Double? = nil

    // Table columns
    public var showCols: [String: Bool] = [
        "T1": true, "T2": true, "ΔT": true, "P1": true, "P2": false,
        "ΔP": true, "V1": true, "V2": false, "M1": true, "M2": true, "Q": true
    ]

    public let coordinator = LersCoordinator()

    // Connection info for reconnect (Sendable struct)
    private var connectionInfo: ConnectionInfo?

    public init() {
        loadSettings()
    }

    // MARK: - Connect
    public func connect() async {
        statusText = "Подключение..."

        let cleanHost = settings.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let port = settings.port > 0 ? settings.port : 10000
        let urlStr = "http://\(cleanHost):\(port)/api/v1/Login"
        guard let url = URL(string: urlStr) else {
            statusText = "Ошибка: некорректный адрес сервера"
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Password from Keychain
        let pass = KeychainHelper.loadPassword() ?? ""
        let body: [String: String] = [
            "login": settings.login.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": pass,
            "application": "LersMonitor iOS"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, res) = try await URLSession.shared.data(for: req)
            guard let httpRes = res as? HTTPURLResponse else {
                statusText = "Ошибка: не получен HTTP-ответ"
                return
            }

            if httpRes.statusCode == 401 || httpRes.statusCode == 403 {
                statusText = "Ошибка: неверный логин или пароль"
                return
            }

            guard httpRes.statusCode == 200 else {
                statusText = "Ошибка сервера: код \(httpRes.statusCode)"
                return
            }

            var token = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = json["token"] as? String {
                token = t
            } else if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) {
                token = s
            }

            if token.isEmpty {
                statusText = "Ошибка: пустой токен авторизации"
                return
            }

            statusText = "Загрузка точек учёта..."
            connectionInfo = ConnectionInfo(host: cleanHost, port: port, token: token)
            await coordinator.configure(host: cleanHost, port: port, token: token)
            await loadPoints(host: cleanHost, port: port, token: token)

            self.isConnected = true
            self.statusText = "Подключено: точек \(allPoints.count)"
            saveSettings()

            Task { await updateGlobalTnv() }
        } catch {
            let err = error as NSError
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorTimedOut {
                statusText = "Ошибка: таймаут (сервер недоступен)"
            } else if err.domain == NSURLErrorDomain && err.code == NSURLErrorCannotConnectToHost {
                statusText = "Ошибка: нет связи с \(cleanHost):\(port)"
            } else {
                statusText = "Ошибка сети: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Reconnect (uses stored token if still valid, otherwise re-login)
    public func reconnectIfNeeded() async {
        guard let info = connectionInfo else { return }

        // Try a lightweight API call with the existing token
        let urlStr = "http://\(info.host):\(info.port)/api/v1/Core/MeasurePoints?type=Regular"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        let (_, res) = try? await URLSession.shared.data(for: req)
        if let httpRes = res as? HTTPURLResponse {
            if httpRes.statusCode == 401 || httpRes.statusCode == 403 {
                // Token expired — need full re-login
                isConnected = false
                statusText = "Сессия истекла. Переподключитесь."
                await connect()
            }
        } else {
            // Network error — keep connection state, will retry later
            statusText = "Потеря связи с сервером"
        }
    }

    // MARK: - Load points
    private func loadPoints(host: String, port: Int, token: String) async {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/Core/MeasurePoints?type=Regular&getCustomers=true") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }

        let array: [[String: Any]]
        if let arr = json as? [[String: Any]] { array = arr }
        else if let dict = json as? [String: Any], let arr = dict["measurePoints"] as? [[String: Any]] { array = arr }
        else { array = [] }

        self.allPoints = array.compactMap { d in
            guard let id = d["id"] as? Int else { return nil }
            return MeasurePointItem(id: id, title: (d["title"] as? String) ?? "Точка", nodeTitle: (d["nodeTitle"] as? String) ?? "Объект")
        }.sorted { ($0.nodeTitle, $0.title) < ($1.nodeTitle, $1.title) }

        applyFilter()
        buildDashboardGroups()
        buildPodpitkaGroups()
    }

    // MARK: - Filters
    public func applyFilter() {
        var list = allPoints
        if !searchText.isEmpty {
            list = list.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if selectedNodeFilter != "Все объекты" {
            list = list.filter { $0.nodeTitle == selectedNodeFilter }
        }
        if selectedSystemFilter != "Все системы" {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(selectedSystemFilter) }
        }
        self.filteredPoints = list
    }

    // MARK: - Build groups
    public func buildDashboardGroups() {
        let grouped = Dictionary(grouping: allPoints) { $0.nodeTitle }
        self.dashboardGroups = grouped.map { node, pts in
            let vmPoints = pts.map { p in
                PointResultData(id: p.id, title: p.title, nodeTitle: p.nodeTitle, limits: settings.pointLimits[p.id])
            }
            return DashboardNodeGroup(nodeTitle: node, points: vmPoints)
        }.sorted { $0.nodeTitle < $1.nodeTitle }
    }

    public func buildPodpitkaGroups() {
        let targets = allPoints.filter { settings.podpitkaPointIds.contains($0.id) }
        let grouped = Dictionary(grouping: targets) { $0.nodeTitle }
        self.podpitkaGroups = grouped.map { node, pts in
            let vmPoints = pts.map { p in
                PodpitkaPointData(id: p.id, title: p.title, nodeTitle: p.nodeTitle, limits: settings.podpitkaLimits[p.id])
            }
            return PodpitkaNodeGroup(nodeTitle: node, points: vmPoints)
        }.sorted { $0.nodeTitle < $1.nodeTitle }
    }

    // MARK: - Poll single point
    public func pollSinglePoint(_ p: PointResultData) async {
        p.state = .polling
        p.status = "Идет опрос..."
        let pointId = p.id
        let nodeTitle = p.nodeTitle
        let (st, msg, raw) = await coordinator.pollPoint(pointId: pointId, nodeTitle: nodeTitle, ignoreCache: true)
        p.state = st
        p.status = msg
        if let raw = raw {
            parsePointData(p, json: raw)
            p.deviceTime = Date()
        }
    }

    // MARK: - Poll all points in parallel (TaskGroup with concurrency limit in coordinator)
    public func pollAllPoints() async {
        guard !isPollingAll else { return }
        isPollingAll = true
        statusText = "Опрос всех точек..."

        // Collect all non-paused points
        let allPts: [PointResultData] = dashboardGroups.flatMap { g in
            g.isPaused ? [] : g.points
        }

        // pollSinglePoint mutates PointResultData (a @MainActor @Observable class),
        // so we must keep it on the MainActor. The coordinator handles concurrency
        // limiting internally (4 device slots), so even though tasks are spawned
        // concurrently, the actual device polls are serialized at the coordinator level.
        await withTaskGroup(of: Void.self) { group in
            for pt in allPts {
                group.addTask { @MainActor in
                    await self.pollSinglePoint(pt)
                }
            }
            // Wait for all
            for await _ in group {}
        }

        isPollingAll = false
        statusText = "Опрос завершен: \(allPts.count) точек"
    }

    // MARK: - Refresh podpitka data in parallel
    // Uses point IDs in the TaskGroup to avoid passing non-Sendable references.
    public func refreshPodpitka() async {
        let now = Date()
        let rPer = PodpitkaPeriod.report(now: now, startDay: settings.reportPeriodStartDay, endDay: settings.reportPeriodEndDay)
        let yPer = PodpitkaPeriod.yesterday(now: now)
        let tPer = PodpitkaPeriod.today(now: now)
        let hPer = PodpitkaPeriod.prevHour(now: now)

        // Collect all podpitka point IDs
        let allPts: [PodpitkaPointData] = podpitkaGroups.flatMap { $0.points }
        for p in allPts {
            p.state = .polling
        }

        // Capture coordinator reference before entering TaskGroup
        // (coordinator is a Sendable actor, safe to pass across isolation boundaries)
        let coordinator = self.coordinator

        // Run network calls in parallel — return only Sendable data
        let results = await withTaskGroup(of: PodpitkaResult.self) { group in
            for p in allPts {
                let pid = p.id
                group.addTask {
                    let rep = await coordinator.sumV1(pointId: pid, from: rPer.from, to: rPer.toExclusive, hourly: false)
                    let day = await coordinator.sumV1(pointId: pid, from: yPer.from, to: yPer.toExclusive, hourly: false)
                    let today = await coordinator.sumV1(pointId: pid, from: tPer.from, to: tPer.toExclusive, hourly: true)
                    let hour = await coordinator.sumV1(pointId: pid, from: hPer.from, to: hPer.toExclusive, hourly: true)
                    return PodpitkaResult(pointId: pid, report: rep, day: day, today: today, hour: hour)
                }
            }
            var collected: [PodpitkaResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Apply results back on MainActor
        let resultMap = Dictionary(uniqueKeysWithValues: results.map { ($0.pointId, ($0.report, $0.day, $0.today, $0.hour)) })
        for p in allPts {
            if let vals = resultMap[p.id] {
                p.report = vals.0
                p.day = vals.1
                p.today = vals.2
                p.hour = vals.3
            }
            p.updatedAt = Date()
            p.state = .ok
            p.message = "Обновлено в \(Date().formatted(date: .omitted, time: .standard))"
        }
    }

    // MARK: - Update outdoor temperature
    public func updateGlobalTnv() async {
        guard let id = settings.tnvSourcePointId else { return }
        let (_, _, raw) = await coordinator.pollPoint(pointId: id, nodeTitle: "Тнв", ignoreCache: false)
        if let raw = raw {
            let dummy = PointResultData(id: id, title: "", nodeTitle: "")
            parsePointData(dummy, json: raw)
            if let t = dummy.t1 ?? dummy.t2 {
                self.globalTnv = t + settings.tnvCorrection
            }
        }
    }

    // MARK: - Parse point data from JSON
    private func parsePointData(_ p: PointResultData, json: [String: Any]) {
        func get(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = json[k] as? Double { return v }
                if let s = json[k] as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) { return d }
            }
            if let arr = json["values"] as? [[String: Any]] {
                for it in arr {
                    let name = ((it["dataParameter"] as? String) ?? "").lowercased()
                    if keys.contains(name) {
                        if let v = it["value"] as? Double { return v }
                        if let s = it["value"] as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) { return d }
                    }
                }
            }
            return nil
        }
        p.t1 = get(["t_in", "t1", "t_supply", "t_nv"])
        p.t2 = get(["t_out", "t2", "t_return"])
        p.p1 = get(["p_in", "p1"])
        p.p2 = get(["p_out", "p2"])
        p.v1 = get(["v_in", "v1"])
        p.v2 = get(["v_out", "v2"])
        p.m1 = get(["m_in", "m1"])
        p.m2 = get(["m_out", "m2"])
        p.q  = get(["q_delta", "q", "q_in"])
    }

    // MARK: - Settings persistence (password in Keychain)
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "LersSettings"),
           let set = try? JSONDecoder().decode(UserSettings.self, from: data) {
            self.settings = set
        }
    }

    public func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(d, forKey: "LersSettings")
        }
    }

    /// Save password to Keychain (called from SettingsView when user enters it)
    public func savePassword(_ password: String) {
        if settings.rememberCredentials {
            KeychainHelper.savePassword(password)
        } else {
            KeychainHelper.deletePassword()
        }
    }

    /// Load password from Keychain for display in SettingsView
    public func loadPassword() -> String {
        return KeychainHelper.loadPassword() ?? ""
    }
}
