import Foundation
import SwiftUI

@Observable
@MainActor
final class AppViewModel {
    var host: String = "localhost"
    var port: String = "10000"
    var login: String = ""
    var pass: String = ""
    var isConnected: Bool = false
    var statusText: String = "Готово к работе"
    
    var allPoints: [MeasurePointItem] = []
    var dashboardPoints: [PointResultData] = []
    
    var currentTnv: Double? = nil
    var tnvCorrection: Double = 0.0
    var cardScale: Double = 1.0
    
    private let coordinator = LersCoordinator()
    
    func connect() async {
        guard let p = Int(port) else { return }
        statusText = "Подключение..."
        await coordinator.configure(host: host, port: p)
        
        do {
            _ = try await coordinator.login(login: login, pass: pass)
            statusText = "Загрузка точек..."
            let points = try await coordinator.fetchMeasurePoints()
            self.allPoints = points
            self.dashboardPoints = points.map { PointResultData(id: $0.id, title: $0.title, nodeTitle: $0.nodeTitle) }
            self.isConnected = true
            self.statusText = "Подключено: \(points.count) точек"
        } catch {
            self.statusText = "Ошибка: \(error.localizedDescription)"
        }
    }
    
    func pollSingle(point: PointResultData) async {
        point.state = .polling
        point.statusMessage = "Идет опрос..."
        
        do {
            if let json = try await coordinator.pollPoint(pointId: point.id) {
                parsePointValues(point: point, json: json)
                point.state = .ok
                point.deviceTime = Date()
                point.statusMessage = "Опрошено в \(Date().formatted(date: .omitted, time: .standard))"
            } else {
                point.state = .error
                point.statusMessage = "Нет данных от прибора"
            }
        } catch {
            point.state = .error
            point.statusMessage = error.localizedDescription
        }
    }
    
    private func parsePointValues(point: PointResultData, json: [String: Any]) {
        func extract(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = json[k] as? Double { return v }
                if let s = json[k] as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) { return d }
            }
            if let arr = json["values"] as? [[String: Any]] {
                for item in arr {
                    let name = (item["dataParameter"] as? String) ?? (item["parameter"] as? String) ?? ""
                    if keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        if let v = item["value"] as? Double { return v }
                        if let s = item["value"] as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) { return d }
                    }
                }
            }
            return nil
        }
        
        point.t1 = extract(["t_in", "t1", "temperatureIn", "T1", "t_supply"])
        point.t2 = extract(["t_out", "t2", "temperatureOut", "T2", "t_return"])
        point.p1 = extract(["p_in", "p1", "pressureIn", "P1"])
        point.p2 = extract(["p_out", "p2", "pressureOut", "P2"])
        point.v1 = extract(["v_in", "v1", "volume1", "V1"])
        point.v2 = extract(["v_out", "v2", "volume2", "V2"])
        point.m1 = extract(["m_in", "m1", "mass1", "M1"])
        point.m2 = extract(["m_out", "m2", "mass2", "M2"])
        point.q  = extract(["q_delta", "q", "q_in", "Q"])
    }
}
