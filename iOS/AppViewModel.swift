import Foundation
import SwiftUI

@Observable
@MainActor
public final class AppViewModel {
    public var settings = UserSettings()
    public var isConnected: Bool = false
    public var statusText: String = "Готово к работе"
    
    public var allPoints: [MeasurePointItem] = []
    public var filteredPoints: [MeasurePointItem] = []
    public var dashboardGroups: [DashboardNodeGroup] = []
    public var podpitkaGroups: [PodpitkaNodeGroup] = []
    public var trendHistory: [PointResultData] = []
    
    // Фильтры
    public var searchText: String = "" { didSet { applyFilter() } }
    public var selectedNodeFilter: String = "Все объекты" { didSet { applyFilter() } }
    public var selectedSystemFilter: String = "Все системы" { didSet { applyFilter() } }
    
    // Текущий Тнв
    public var globalTnv: Double? = nil
    
    // Колонки таблицы
    public var showCols: [String: Bool] = [
        "T1": true, "T2": true, "ΔT": true, "P1": true, "P2": false,
        "ΔP": true, "V1": true, "V2": false, "M1": true, "M2": true, "Q": true
    ]
    
    public let coordinator = LersCoordinator()
    private var dashboardTimer: Task<Void, Never>?
    private var podpitkaTimer: Task<Void, Never>?
    
    public init() {
        loadSettings()
    }
    
    public func connect() async {
        statusText = "Подключение..."
        await coordinator.configure(host: settings.host, port: settings.port, token: nil)
        
        let urlStr = "http://\(settings.host):\(settings.port)/api/v1/Login"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let pass = String(data: Data(base64Encoded: settings.passwordBase64) ?? Data(), encoding: .utf8) ?? ""
        let body: [String: String] = ["login": settings.login, "password": pass, "application": "LersMonitor iOS"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, res) = try await URLSession.shared.data(for: req)
            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                statusText = "Ошибка авторизации"
                return
            }
            var token = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = json["token"] as? String {
                token = t
            } else if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) {
                token = s
            }
            
            await coordinator.configure(host: settings.host, port: settings.port, token: token)
            await loadPoints(token: token)
            self.isConnected = true
            self.statusText = "Подключено: \(allPoints.count) точек"
            saveSettings()
            
            // Запуск обновления Тнв
            Task { await updateGlobalTnv() }
        } catch {
            statusText = "Сбой сети: \(error.localizedDescription)"
        }
    }
    
    private func loadPoints(token: String) async {
        guard let url = URL(string: "http://\(settings.host):\(settings.port)/api/v1/Core/MeasurePoints?type=Regular&getCustomers=true") else { return }
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
    
    public func pollSinglePoint(_ p: PointResultData) async {
        p.state = .polling
        p.status = "Идет опрос..."
        let (st, msg, raw) = await coordinator.pollPoint(pointId: p.id, nodeTitle: p.nodeTitle, ignoreCache: true)
        p.state = st
        p.status = msg
        if let raw = raw {
            parsePointData(p, json: raw)
            p.deviceTime = Date()
        }
    }
    
    public func refreshPodpitka() async {
        let now = Date()
        let rPer = PodpitkaPeriod.report(now: now, startDay: settings.reportPeriodStartDay, endDay: settings.reportPeriodEndDay)
        let yPer = PodpitkaPeriod.yesterday(now: now)
        let tPer = PodpitkaPeriod.today(now: now)
        let hPer = PodpitkaPeriod.prevHour(now: now)
        
        for g in podpitkaGroups {
            for p in g.points {
                p.state = .polling
                async let rep = coordinator.sumV1(pointId: p.id, from: rPer.from, to: rPer.toExclusive, hourly: false)
                async let day = coordinator.sumV1(pointId: p.id, from: yPer.from, to: yPer.toExclusive, hourly: false)
                async let today = coordinator.sumV1(pointId: p.id, from: tPer.from, to: tPer.toExclusive, hourly: true)
                async let hour = coordinator.sumV1(pointId: p.id, from: hPer.from, to: hPer.toExclusive, hourly: true)
                
                let res = await (rep, day, today, hour)
                p.report = res.0
                p.day = res.1
                p.today = res.2
                p.hour = res.3
                p.updatedAt = Date()
                p.state = .ok
                p.message = "Обновлено в \(Date().formatted(date: .omitted, time: .standard))"
            }
        }
    }
    
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
}
