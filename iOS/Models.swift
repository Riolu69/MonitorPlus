import Foundation
import SwiftUI

// MARK: - Состояния опроса
enum PollState: String, Codable {
    case pending = "Ожидание"
    case queued = "В очереди"
    case polling = "Опрос..."
    case ok = "Опрошено"
    case okCached = "Из кэша"
    case error = "Ошибка"
    case paused = "Приостановлено"
}

// MARK: - Точка учета
struct MeasurePointItem: Identifiable, Codable, Hashable {
    let id: Int
    var title: String
    var nodeTitle: String
    
    var displayName: String {
        "\(nodeTitle) — \(title)"
    }
}

// MARK: - Точка температурного графика
struct TempSchedulePoint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var tnv: Double   // Температура наружного воздуха
    var t1: Double    // Подача
    var t2: Double    // Обратка
    
    enum CodingKeys: String, CodingKey {
        case tnv, t1, t2
    }
}

// MARK: - Математика температурного графика
enum TempScheduleMath {
    static let defaultTolerance: Double = 3.0
    
    /// Линейная интерполяция T1 и T2 для текущей уличной температуры (Тнв)
    static func expected(tnv: Double?, schedule: [TempSchedulePoint]?) -> (expT1: Double?, expT2: Double?) {
        guard let tnv = tnv, let schedule = schedule, !schedule.isEmpty else {
            return (nil, nil)
        }
        
        let sorted = schedule.sorted { $0.tnv < $1.tnv }
        if let exact = sorted.first(where: { abs($0.tnv - tnv) < 0.2 }) {
            return (exact.t1, exact.t2)
        }
        
        guard let first = sorted.first, let last = sorted.last else { return (nil, nil) }
        if tnv <= first.tnv { return (first.t1, first.t2) }
        if tnv >= last.tnv { return (last.t1, last.t2) }
        
        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            if tnv >= p1.tnv && tnv <= p2.tnv {
                let dx = p2.tnv - p1.tnv
                if abs(dx) < 0.001 { return (p1.t1, p1.t2) }
                let ratio = (tnv - p1.tnv) / dx
                let expT1 = p1.t1 + ratio * (p2.t1 - p1.t1)
                let expT2 = p1.t2 + ratio * (p2.t2 - p1.t2)
                return (expT1, expT2)
            }
        }
        return (nil, nil)
    }
}

// MARK: - Границы параметров
struct PointThresholds: Codable {
    var t1Min: Double?; var t1Max: Double?
    var t2Min: Double?; var t2Max: Double?
    var p1Min: Double?; var p1Max: Double?
    var p2Min: Double?; var p2Max: Double?
    var v1Min: Double?; var v1Max: Double?
    var v2Min: Double?; var v2Max: Double?
    var m1Min: Double?; var m1Max: Double?
    var m2Min: Double?; var m2Max: Double?
    var qMin: Double?;  var qMax: Double?
    var schedule: [TempSchedulePoint] = []
    var scheduleTolerance: Double = TempScheduleMath.defaultTolerance
}

// MARK: - Срез параметров точки
@Observable
final class PointResultData: Identifiable {
    let id: Int
    var title: String
    var nodeTitle: String
    var state: PollState = .pending
    var statusMessage: String = "Ожидание..."
    var deviceTime: Date?
    
    var t1: Double?
    var t2: Double?
    var p1: Double?
    var p2: Double?
    var v1: Double?
    var v2: Double?
    var m1: Double?
    var m2: Double?
    var q: Double?
    
    var deltaT: Double? {
        guard let t1 = t1, let t2 = t2 else { return nil }
        return t1 - t2
    }
    
    var deltaP: Double? {
        guard let p1 = p1, let p2 = p2 else { return nil }
        return p1 - p2
    }
    
    var limits: PointThresholds?
    
    init(id: Int, title: String, nodeTitle: String, limits: PointThresholds? = nil) {
        self.id = id
        self.title = title
        self.nodeTitle = nodeTitle
        self.limits = limits
    }
    
    // Проверка нарушений границ и температурного графика
    func isBreached(val: Double?, min: Double?, max: Double?) -> Bool {
        guard let v = val else { return false }
        if let min = min, v < min { return true }
        if let max = max, v > max { return true }
        return false
    }
    
    func isScheduleBreached(currentTnv: Double?) -> (t1Breach: Bool, t2Breach: Bool) {
        guard let limits = limits, !limits.schedule.isEmpty, let tnv = currentTnv else {
            return (false, false)
        }
        let exp = TempScheduleMath.expected(tnv: tnv, schedule: limits.schedule)
        let tol = limits.scheduleTolerance
        
        let b1 = (t1 != nil && exp.expT1 != nil) ? abs(t1! - exp.expT1!) > tol : false
        let b2 = (t2 != nil && exp.expT2 != nil) ? abs(t2! - exp.expT2!) > tol : false
        return (b1, b2)
    }
    
    func hasAnyBreach(currentTnv: Double?) -> Bool {
        let sched = isScheduleBreached(currentTnv: currentTnv)
        return isBreached(val: t1, min: limits?.t1Min, max: limits?.t1Max) || sched.t1Breach ||
               isBreached(val: t2, min: limits?.t2Min, max: limits?.t2Max) || sched.t2Breach ||
               isBreached(val: p1, min: limits?.p1Min, max: limits?.p1Max) ||
               isBreached(val: p2, min: limits?.p2Min, max: limits?.p2Max) ||
               isBreached(val: v1, min: limits?.v1Min, max: limits?.v1Max) ||
               isBreached(val: q, min: limits?.qMin, max: limits?.qMax)
    }
}
