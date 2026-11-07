import Foundation
import SwiftUI

// MARK: - Poll states
public enum PollState: String, Codable, CaseIterable, Sendable {
    case pending = "Ожидание"
    case queued = "В очереди"
    case polling = "Опрос..."
    case ok = "Опрошено"
    case okCached = "Из кэша"
    case error = "Ошибка"
    case paused = "Приостановлено"
}

// MARK: - Poll log entry (streamed via AsyncStream)
public struct PollLogEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let state: PollState
    public let message: String
    public let phase: String

    public init(state: PollState, message: String, phase: String) {
        self.timestamp = Date()
        self.state = state
        self.message = message
        self.phase = phase
    }
}

// MARK: - Poll target (Sendable, used across TaskGroup boundaries)
public struct PollTarget: Sendable, Hashable {
    public let pointId: Int
    public let nodeKey: String
    public init(pointId: Int, nodeKey: String) {
        self.pointId = pointId
        self.nodeKey = nodeKey
    }
}

// MARK: - Archive kinds (from original WPF "Архив показаний")
public enum ArchiveKind: String, CaseIterable, Identifiable, Sendable {
    case current = "Текущие"
    case hour = "Часовые"
    case day = "Суточные"
    case month = "Месячные"

    public var id: String { rawValue }
    /// Имя массива в ответе ЛЭРС
    public var arrayNames: [String] {
        switch self {
        case .current: return ["currentConsumption", "currentConsumptions"]
        case .hour:    return ["hourConsumption", "hourConsumptions"]
        case .day:     return ["dayConsumption", "dayConsumptions"]
        case .month:   return ["monthConsumption", "monthConsumptions"]
        }
    }
}

/// Плоская строка архива: имя параметра → строковое значение
public struct ArchiveRow: Identifiable, Sendable {
    public let id = UUID()
    public let cells: [String: String]
    public var sortedKeys: [String] { cells.keys.sorted() }
}

// MARK: - System type filters (original: Все системы / Теплоснабжение / ГВС / Подпитка / ХВС)
public enum SystemTypes {
    public static let all = ["Все системы", "Теплоснабжение", "ГВС", "Подпитка", "ХВС"]
}

// MARK: - Podpitka periods (V1 volume calculation)
public struct PodpitkaPeriod: Sendable {
    public let from: Date
    public let toExclusive: Date

    public static func report(now: Date, startDay: Int = 25, endDay: Int = 24) -> PodpitkaPeriod {
        let calendar = Calendar.current
        let sDay = min(max(startDay, 1), 31)
        let eDay = min(max(endDay, 1), 31)

        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        if sDay <= eDay {
            let comp = DateComponents(year: currentYear, month: currentMonth, day: 1)
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
            let realStart = min(sDay, rStart.count)
            var from = calendar.date(bySetting: .day, value: realStart, of: startMonth)!

            var endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
            let rEnd = calendar.range(of: .day, in: .month, for: endMonth)!
            let realEnd = min(eDay, rEnd.count)
            var endDate = calendar.date(bySetting: .day, value: realEnd, of: endMonth)!

            if now <= endDate {
                startMonth = calendar.date(byAdding: .month, value: -1, to: startMonth)!
                let rS2 = calendar.range(of: .day, in: .month, for: startMonth)!
                from = calendar.date(bySetting: .day, value: min(sDay, rS2.count), of: startMonth)!

                endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
                let rE2 = calendar.range(of: .day, in: .month, for: endMonth)!
                endDate = calendar.date(bySetting: .day, value: min(eDay, rE2.count), of: endMonth)!
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

// MARK: - Temperature schedule
public struct TempSchedulePoint: Codable, Identifiable, Hashable, Sendable {
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

    public static func band(_ value: Double, tolerance: Double) -> String {
        String(format: "%.1f … %.1f", value - tolerance, value + tolerance)
    }
}

// MARK: - Thresholds
public struct PointThresholds: Codable, Equatable, Sendable {
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

public struct VolumeThresholds: Codable, Equatable, Sendable {
    public var reportMin: Double?; public var reportMax: Double?
    public var dayMin: Double?;    public var dayMax: Double?
    public var todayMin: Double?;  public var todayMax: Double?
    public var hourMin: Double?;   public var hourMax: Double?
}

// MARK: - Saved point snapshot (LastResults persistence, like original WPF)
public struct SavedPointResult: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var nodeTitle: String
    public var state: PollState
    public var status: String
    public var t1: Double?; public var t2: Double?
    public var p1: Double?; public var p2: Double?
    public var v1: Double?; public var v2: Double?
    public var m1: Double?; public var m2: Double?
    public var q: Double?
    public var deviceTime: Date?
}

// MARK: - User settings (password in Keychain, not here)
public struct UserSettings: Codable, Equatable, Sendable {
    public var host: String = "localhost"
    public var port: Int = 10000
    public var login: String = ""
    public var rememberCredentials: Bool = true
    public var themeMode: Int = 0
    public var timeLightStr: String = "08:00"
    public var timeDarkStr: String = "20:00"
    public var selectedPointIds: [Int] = []
    public var tnvSourcePointId: Int?
    public var pointLimits: [Int: PointThresholds] = [:]
    public var lastResults: [SavedPointResult] = []
    public var podpitkaPointIds: [Int] = []
    public var podpitkaIntervalMin: Int = 30
    public var podpitkaLimits: [Int: VolumeThresholds] = [:]
    public var tnvCorrection: Double = 0.0
    public var hideGeneral: Bool = false
    public var hideTrend: Bool = false
    public var hideDashboard: Bool = false
    public var hidePodpitka: Bool = false
    public var hideArchive: Bool = true
    public var experimentalArchive: Bool = false
    public var experimentalReportPeriod: Bool = false
    public var reportPeriodStartDay: Int = 25
    public var reportPeriodEndDay: Int = 24
    public var dashboardIntervalMin: Int = 10
    public var dashboardPointIds: [Int] = []
    public var trendDurationMin: Int = 3

    public init() {}

    // Backwards-compatible decoding: original WPF settings.json has extra keys
    // (PasswordBase64, UiScale, LastResults as VMs). Unknown keys are ignored,
    // and every field falls back to its default when missing.
    private enum CodingKeys: String, CodingKey {
        case host, port, login, rememberCredentials, themeMode, timeLightStr, timeDarkStr
        case selectedPointIds, tnvSourcePointId, pointLimits, lastResults
        case podpitkaPointIds, podpitkaIntervalMin, podpitkaLimits, tnvCorrection
        case hideGeneral, hideTrend, hideDashboard, hidePodpitka, hideArchive
        case experimentalArchive, experimentalReportPeriod, reportPeriodStartDay, reportPeriodEndDay
        case dashboardIntervalMin, dashboardPointIds, trendDurationMin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 10000
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
        rememberCredentials = try c.decodeIfPresent(Bool.self, forKey: .rememberCredentials) ?? true
        themeMode = try c.decodeIfPresent(Int.self, forKey: .themeMode) ?? 0
        timeLightStr = try c.decodeIfPresent(String.self, forKey: .timeLightStr) ?? "08:00"
        timeDarkStr = try c.decodeIfPresent(String.self, forKey: .timeDarkStr) ?? "20:00"
        selectedPointIds = try c.decodeIfPresent([Int].self, forKey: .selectedPointIds) ?? []
        tnvSourcePointId = try c.decodeIfPresent(Int.self, forKey: .tnvSourcePointId)
        pointLimits = try c.decodeIfPresent([Int: PointThresholds].self, forKey: .pointLimits) ?? [:]
        lastResults = try c.decodeIfPresent([SavedPointResult].self, forKey: .lastResults) ?? []
        podpitkaPointIds = try c.decodeIfPresent([Int].self, forKey: .podpitkaPointIds) ?? []
        podpitkaIntervalMin = try c.decodeIfPresent(Int.self, forKey: .podpitkaIntervalMin) ?? 30
        podpitkaLimits = try c.decodeIfPresent([Int: VolumeThresholds].self, forKey: .podpitkaLimits) ?? [:]
        tnvCorrection = try c.decodeIfPresent(Double.self, forKey: .tnvCorrection) ?? 0
        hideGeneral = try c.decodeIfPresent(Bool.self, forKey: .hideGeneral) ?? false
        hideTrend = try c.decodeIfPresent(Bool.self, forKey: .hideTrend) ?? false
        hideDashboard = try c.decodeIfPresent(Bool.self, forKey: .hideDashboard) ?? false
        hidePodpitka = try c.decodeIfPresent(Bool.self, forKey: .hidePodpitka) ?? false
        hideArchive = try c.decodeIfPresent(Bool.self, forKey: .hideArchive) ?? true
        experimentalArchive = try c.decodeIfPresent(Bool.self, forKey: .experimentalArchive) ?? false
        experimentalReportPeriod = try c.decodeIfPresent(Bool.self, forKey: .experimentalReportPeriod) ?? false
        reportPeriodStartDay = try c.decodeIfPresent(Int.self, forKey: .reportPeriodStartDay) ?? 25
        reportPeriodEndDay = try c.decodeIfPresent(Int.self, forKey: .reportPeriodEndDay) ?? 24
        dashboardIntervalMin = try c.decodeIfPresent(Int.self, forKey: .dashboardIntervalMin) ?? 10
        dashboardPointIds = try c.decodeIfPresent([Int].self, forKey: .dashboardPointIds) ?? []
        trendDurationMin = try c.decodeIfPresent(Int.self, forKey: .trendDurationMin) ?? 3

        // Оригинал: некорректные значения допуска отсекаются
        for key in pointLimits.keys {
            let tol = pointLimits[key]!.scheduleTolerance
            if tol < 0 || tol > 50 { pointLimits[key]?.scheduleTolerance = TempScheduleMath.defaultTolerance }
        }
    }
}

// MARK: - Measure point
public struct MeasurePointItem: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public var title: String
    public var nodeTitle: String
    public var nodeId: Int
    public var displayName: String { "\(nodeTitle) — \(title)" }

    public init(id: Int, title: String, nodeTitle: String, nodeId: Int = 0) {
        self.id = id
        self.title = title
        self.nodeTitle = nodeTitle
        self.nodeId = nodeId
    }

    /// Грубая классификация по названию — как в оригинале (фильтр «Тип системы»)
    public func matches(systemType: String) -> Bool {
        if systemType == "Все системы" { return true }
        return title.localizedCaseInsensitiveContains(systemType)
    }
}

// MARK: - Observable point data for dashboard / general monitor
// @unchecked Sendable: instances are created on MainActor and mutated from
// MainActor context only.
@Observable
public final class PointResultData: Identifiable, @unchecked Sendable {
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
    public var hasError: Bool { state == .error }
    public var isWaiting: Bool { state == .pending || state == .queued || state == .polling }
    public var isDone: Bool { !isWaiting && state != .paused }

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

    public func expectedT1(currentTnv: Double?) -> Double? {
        TempScheduleMath.expected(tnv: currentTnv, schedule: limits?.schedule).expT1
    }
    public func expectedT2(currentTnv: Double?) -> Double? {
        TempScheduleMath.expected(tnv: currentTnv, schedule: limits?.schedule).expT2
    }

    public func hasBreach(currentTnv: Double?) -> Bool {
        return isBreached(t1, limits?.t1Min, limits?.t1Max) || isT1ScheduleBreached(currentTnv: currentTnv) ||
               isBreached(t2, limits?.t2Min, limits?.t2Max) || isT2ScheduleBreached(currentTnv: currentTnv) ||
               isBreached(p1, limits?.p1Min, limits?.p1Max) || isBreached(p2, limits?.p2Min, limits?.p2Max) ||
               isBreached(v1, limits?.v1Min, limits?.v1Max) || isBreached(v2, limits?.v2Min, limits?.v2Max) ||
               isBreached(m1, limits?.m1Min, limits?.m1Max) || isBreached(m2, limits?.m2Min, limits?.m2Max) ||
               isBreached(q, limits?.qMin, limits?.qMax)
    }

    public func toSaved() -> SavedPointResult {
        SavedPointResult(id: id, title: title, nodeTitle: nodeTitle, state: state, status: status,
                         t1: t1, t2: t2, p1: p1, p2: p2, v1: v1, v2: v2, m1: m1, m2: m2, q: q,
                         deviceTime: deviceTime)
    }

    public func restore(from s: SavedPointResult) {
        state = (s.state == .pending && s.status.contains("Снято")) ? .okCached : s.state
        status = s.status
        t1 = s.t1; t2 = s.t2; p1 = s.p1; p2 = s.p2
        v1 = s.v1; v2 = s.v2; m1 = s.m1; m2 = s.m2; q = s.q
        deviceTime = s.deviceTime
    }
}

// MARK: - Observable podpitka point data
@Observable
public final class PodpitkaPointData: Identifiable, @unchecked Sendable {
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

    public var isDone: Bool { state == .ok || state == .okCached || state == .error }
    public var hasError: Bool { state == .error }

    public init(id: Int, title: String, nodeTitle: String, limits: VolumeThresholds? = nil) {
        self.id = id
        self.title = title
        self.nodeTitle = nodeTitle
        self.limits = limits
    }

    public func setVolumes(report: Double?, day: Double?, today: Double?, hour: Double?) {
        self.report = report
        self.day = day
        self.today = today
        self.hour = hour
        self.updatedAt = Date()
    }

    /// После опроса прибора: обновляем часовой срез и «сегодня»
    public func updateHour(today: Double?, hourValue: Double) {
        self.hour = hourValue
        if let today = today { self.today = today }
        else if self.today == nil { self.today = hourValue }
        self.updatedAt = Date()
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

// MARK: - Node groups
public struct DashboardNodeGroup: Identifiable {
    public var id: String { nodeTitle }
    public let nodeTitle: String
    public var points: [PointResultData]
    public var isPaused: Bool = false

    public var generalStatus: String {
        if isPaused { return "Опрос приостановлен" }
        let waiting = points.filter { !$0.isDone }.count
        if waiting > 0 { return "Опрошено \(points.count - waiting) из \(points.count)" }
        if let err = points.first(where: { $0.hasError }) { return err.status }
        return "Опрошено успешно"
    }
}

public struct PodpitkaNodeGroup: Identifiable {
    public var id: String { nodeTitle }
    public let nodeTitle: String
    public var points: [PodpitkaPointData]

    public var generalStatus: String {
        let waiting = points.filter { !$0.isDone }.count
        if waiting > 0 { return "Опрошено \(points.count - waiting) из \(points.count)" }
        return points.first(where: { $0.hasError })?.message ?? "Опрошено успешно"
    }
}
