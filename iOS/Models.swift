import Foundation
import SwiftUI

// MARK: - Состояния и лог опроса
public enum PollState: String, Codable, CaseIterable {
    case pending = "Ожидание"
    case queued = "В очереди"
    case polling = "Опрос..."
    case ok = "Опрошено"
    case okCached = "Из кэша"
    case error = "Ошибка"
    case paused = "Приостановлено"
}

public struct PollLogEntry: Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: Date = Date()
    public let state: PollState
    public let message: String
    public let phase: String // "Ожидание", "Дозвон", "Опрос", "Снятие данных", "Отключение", "Готово", "Ошибка"
}

// MARK: - Периоды для расчета подпитки (V1)
public struct PodpitkaPeriod {
    public let from: Date
    public let toExclusive: Date
    
    public static func report(now: Date, startDay: Int = 25, endDay: Int = 24) -> PodpitkaPeriod {
        let calendar = Calendar.current
        let sDay = min(max(startDay, 1), 31)
        let eDay = min(max(endDay, 1), 31)
        
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        
        if sDay <= eDay {
            var comp = DateComponents(year: currentYear, month: currentMonth, day: 1)
            var candMonth = calendar.date(from: comp) ?? now
            let range = calendar.range(of: .day, in: .month, for: candMonth)!
            let realEnd = min(eDay, range.count)
            let endDate = calendar.date(bySetting: .day, value: realEnd, of: candMonth)!
            
            if now <= endDate {
                candMonth = calendar.date(byAdding: .month, value: -1, to: candMonth)!
            }
            let r2 = calendar.range(of: .day, in: .month, for: candMonth)!
            let fDay = min(sDay, r2.count)
            let toDay = min(eDay, r2.count)
            
            let from = calendar.date(bySetting: .day, value: fDay, of: candMonth)!
            let toEx = calendar.date(byAdding: .day, value: 1, to: calendar.date(bySetting: .day, value: toDay, of: candMonth)!)!
            return PodpitkaPeriod(from: from, toExclusive: toEx)
        } else {
            var startMonth = calendar.date(byAdding: .month, value: -1, to: calendar.date(from: DateComponents(year: currentYear, month: currentMonth, day: 1))!)!
            let rStart = calendar.range(of: .day, in: .month, for: startMonth)!
            var realStart = min(sDay, rStart.count)
            var from = calendar.date(bySetting: .day, value: realStart, of: startMonth)!
            
            var endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
            let rEnd = calendar.range(of: .day, in: .month, for: endMonth)!
            var realEnd = min(eDay, rEnd.count)
            var endDate = calendar.date(bySetting: .day, value: realEnd, of: endMonth)!
            
            if now <= endDate {
                startMonth = calendar.date(byAdding: .month, value: -1, to: startMonth)!
                let rS2 = calendar.range(of: .day, in: .month, for: startMonth)!
                realStart = min(sDay, rS2.count)
                from = calendar.date(bySetting: .day, value: realStart, of: startMonth)!
                
                endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
                let rE2 = calendar.range(of: .day, in: .month, for: endMonth)!
                realEnd = min(eDay, rE2.count)
                endDate = calendar.date(bySetting: .day, value: realEnd, of: endMonth)!
            }
            let toEx = calendar.date(byAdding: .day, value: 1, to: endDate)!
            return PodpitkaPeriod(from: from, toExclusive: toEx)
        }
    }
    
    public static func yesterday(now: Date) -> PodpitkaPeriod {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        return PodpitkaPeriod(from: startOfYesterday, toExclusive: startOfToday)
    }
    
    public static func today(now: Date) -> PodpitkaPeriod {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let hourStart = cal.date(bySetting: .minute, value: 0, of: cal.date(bySetting: .second, value: 0, of: now)!)!
        return PodpitkaPeriod(from: startOfToday, toExclusive: hourStart)
    }
    
    public static func prevHour(now: Date) -> PodpitkaPeriod {
        let cal = Calendar.current
        let hourStart = cal.date(bySetting: .minute, value: 0, of: cal.date(bySetting: .second, value: 0, of: now)!)!
        let prevHour = cal.date(byAdding: .hour, value: -1, to: hourStart)!
        return PodpitkaPeriod(from: prevHour, toExclusive: hourStart)
    }
}

// MARK: - Температурный график
public struct TempSchedulePoint: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var tnv: Double
    public var t1: Double
    public var t2: Double
    
    public init(tnv: Double, t1: Double, t2: Double) {
        self.tnv = tnv
        self.t1 = t1
        self.t2 = t2
    }
    
    enum CodingKeys: String, CodingKey {
        case tnv, t1, t2
    }
}

public enum TempScheduleMath {
    public static let defaultTolerance: Double = 3.0
    
    public static func expected(tnv: Double?, schedule: [TempSchedulePoint]?) -> (expT1: Double?, expT2: Double?) {
        guard let tnv = tnv, let schedule = schedule, !schedule.isEmpty else { return (nil, nil) }
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
                return (p1.t1 + ratio * (p2.t1 - p1.t1), p1.t2 + ratio * (p2.t2 - p1.t2))
            }
        }
        return (nil, nil)
    }
}

// MARK: - Допуски и границы
public struct PointThresholds: Codable, Equatable {
    public var t1Min: Double?; public var t1Max: Double?
    public var t2Min: Double?; public var t2Max: Double?
    public var p1Min: Double?; public var p1Max: Double?
    public var p2Min: Double?; public var p2Max: Double?
    public var v1Min: Double?; public var v1Max: Double?
    public var v2Min: Double?; public var v2Max: Double?
    public var m1Min: Double?; public var m1Max: Double?
    public var m2Min: Double?; public var m2Max: Double?
    public var qMin: Double?;  public var qMax: Double?
    public var schedule: [TempSchedulePoint] = []
    public var scheduleTolerance: Double = TempScheduleMath.defaultTolerance
}

public struct VolumeThresholds: Codable, Equatable {
    public var reportMin: Double?; public var reportMax: Double?
    public var dayMin: Double?;    public var dayMax: Double?
    public var todayMin: Double?;  public var todayMax: Double?
    public var hourMin: Double?;   public var hourMax: Double?
}

// MARK: - Сохраняемые настройки пользователя
public struct UserSettings: Codable {
    public var host: String = "localhost"
    public var port: Int = 10000
    public var login: String = ""
    public var passwordBase64: String = ""
    public var rememberCredentials: Bool = true
    public var themeMode: Int = 0
    public var timeLightStr: String = "08:00"
    public var timeDarkStr: String = "20:00"
    public var uiScale: Double = 1.0
    public var selectedPointIds: [Int] = []
    public var tnvSourcePointId: Int?
    public var pointLimits: [Int: PointThresholds] = [:]
    public var podpitkaPointIds: [Int] = []
    public var podpitkaIntervalMin: Int = 30
    public var podpitkaLimits: [Int: VolumeThresholds] = [:]
    public var tnvCorrection: Double = 0.0
    public var hideGeneral: Bool = false
    public var hideTrend: Bool = false
    public var hideDashboard: Bool = false
    public var hidePodpitka: Bool = false
    public var experimentalArchive: Bool = false
    public var experimentalReportPeriod: Bool = false
    public var reportPeriodStartDay: Int = 25
    public var reportPeriodEndDay: Int = 24
}

// MARK: - Точка учета
public struct MeasurePointItem: Identifiable, Codable, Hashable {
    public let id: Int
    public var title: String
    public var nodeTitle: String
    public var displayName: String { "\(nodeTitle) — \(title)" }
}

// MARK: - View-модели для отображения в списках и плитках
@Observable
public final class PointResultData: Identifiable {
    public let id: Int
    public var title: String
    public var nodeTitle: String
    public var state: PollState = .pending
    public var status: String = "Ожидание..."
    public var deviceTime: Date?
    
    public var t1: Double?; public var t2: Double?
    public var p1: Double?; public var p2: Double?
    public var v1: Double?; public var v2: Double?
    public var m1: Double?; public var m2: Double?
    public var q: Double?
    
    public var limits: PointThresholds?
    
    public var deltaT: Double? {
        guard let t1 = t1, let t2 = t2 else { return nil }
        return t1 - t2
    }
    public var deltaP: Double? {
        guard let p1 = p1, let p2 = p2 else { return nil }
        return p1 - p2
    }
    
    public init(id: Int, title: String, nodeTitle: String, limits: PointThresholds? = nil) {
        self.id = id
        self.title = title
        self.nodeTitle = nodeTitle
        self.limits = limits
    }
    
    public func isBreached(_ val: Double?, _ min: Double?, _ max: Double?) -> Bool {
        guard let v = val else { return false }
        if let min = min, v < min { return true }
        if let max = max, v > max { return true }
        return false
    }
    
    public func isT1ScheduleBreached(currentTnv: Double?) -> Bool {
        guard let t1 = t1, let limits = limits, !limits.schedule.isEmpty else { return false }
        let exp = TempScheduleMath.expected(tnv: currentTnv, schedule: limits.schedule)
        guard let expT1 = exp.expT1 else { return false }
        return abs(t1 - expT1) > limits.scheduleTolerance
    }
    
    public func isT2ScheduleBreached(currentTnv: Double?) -> Bool {
        guard let t2 = t2, let limits = limits, !limits.schedule.isEmpty else { return false }
        let exp = TempScheduleMath.expected(tnv: currentTnv, schedule: limits.schedule)
        guard let expT2 = exp.expT2 else { return false }
        return abs(t2 - expT2) > limits.scheduleTolerance
    }
    
    public func hasBreach(currentTnv: Double?) -> Bool {
        return isBreached(t1, limits?.t1Min, limits?.t1Max) || isT1ScheduleBreached(currentTnv: currentTnv) ||
               isBreached(t2, limits?.t2Min, limits?.t2Max) || isT2ScheduleBreached(currentTnv: currentTnv) ||
               isBreached(p1, limits?.p1Min, limits?.p1Max) || isBreached(p2, limits?.p2Min, limits?.p2Max) ||
               isBreached(v1, limits?.v1Min, limits?.v1Max) || isBreached(v2, limits?.v2Min, limits?.v2Max) ||
               isBreached(m1, limits?.m1Min, limits?.m1Max) || isBreached(m2, limits?.m2Min, limits?.m2Max) ||
               isBreached(q, limits?.qMin, limits?.qMax)
    }
}

@Observable
public final class PodpitkaPointData: Identifiable {
    public let id: Int
    public var title: String
    public var nodeTitle: String
    public var state: PollState = .pending
    public var message: String = "Ожидание..."
    public var limits: VolumeThresholds?
    
    public var report: Double?
    public var day: Double?
    public var today: Double?
    public var hour: Double?
    public var updatedAt: Date?
    
    public init(id: Int, title: String, nodeTitle: String, limits: VolumeThresholds? = nil) {
        self.id = id
        self.title = title
        self.nodeTitle = nodeTitle
        self.limits = limits
    }
    
    private func out(_ v: Double?, _ min: Double?, _ max: Double?) -> Bool {
        guard let v = v else { return false }
        if let min = min, v < min { return true }
        if let max = max, v > max { return true }
        return false
    }
    
    public var reportBreach: Bool { out(report, limits?.reportMin, limits?.reportMax) }
    public var dayBreach: Bool    { out(day, limits?.dayMin, limits?.dayMax) }
    public var todayBreach: Bool  { out(today, limits?.todayMin, limits?.todayMax) }
    public var hourBreach: Bool   { out(hour, limits?.hourMin, limits?.hourMax) }
    public var hasBreach: Bool    { reportBreach || dayBreach || todayBreach || hourBreach }
}

public struct DashboardNodeGroup: Identifiable {
    public var id: String { nodeTitle }
    public let nodeTitle: String
    public var points: [PointResultData]
    public var isPaused: Bool = false
}

public struct PodpitkaNodeGroup: Identifiable {
    public var id: String { nodeTitle }
    public let nodeTitle: String
    public var points: [PodpitkaPointData]
}
