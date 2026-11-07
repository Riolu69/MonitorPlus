import Foundation
import SwiftUI

// MARK: - Sendable DTOs

/// Информация о текущем соединении (для диагностики и переподключения).
public struct ConnectionInfo: Sendable {
    let host: String
    let port: Int
    let token: String
}

/// Результат параллельного расчёта объёмов подпитки.
public struct PodpitkaResult: Sendable {
    let pointId: Int
    let volumes: PodpitkaVolumes
}

/// Какие списки выбора точек существуют в приложении.
public enum PointSelectionList: Sendable, Equatable {
    case general
    case dashboard
    case podpitka
}

// MARK: - AppViewModel
/// Центральное состояние приложения. Порт логики MainWindow.xaml.cs:
/// подключение, загрузка /Core/Nodes и /Core/MeasurePoints, фильтры,
/// выбор точек, опрос, Тнв, тренд, планировщики дашборда и подпитки,
/// архив показаний, сохранение настроек и последних результатов.
@Observable
@MainActor
public final class AppViewModel {

    // MARK: - Connection state

    public var settings = UserSettings()
    public var isConnected: Bool = false
    public var statusText: String = "Готово к работе"
    public var isPollingAll: Bool = false
    public var isPollingSelected: Bool = false

    public var isTrendRunning: Bool = false
    public var trendRemainingText: String = ""
    public var isDashboardSchedulerRunning: Bool = false
    public var isPodpitkaSchedulerRunning: Bool = false
    public var dashboardNextRun: Date?
    public var podpitkaNextRun: Date?

    // MARK: - Points and filters

    public var allPoints: [MeasurePointItem] = []
    public var availableNodes: [String] = ["Все объекты"]
    public let systemTypes: [String] = SystemTypes.all

    /// Вычисляемое, а не хранимое: `@Observable` не поддерживает didSet/willSet
    /// на отслеживаемых свойствах. Observation сам проследит зависимости
    /// (allPoints / searchText / фильтры) и обновит все читающие view.
    public var filteredPoints: [MeasurePointItem] {
        var list = allPoints
        if !searchText.isEmpty {
            list = list.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if selectedNodeFilter != "Все объекты" {
            list = list.filter { $0.nodeTitle == selectedNodeFilter }
        }
        if selectedSystemFilter != "Все системы" {
            list = list.filter { $0.matches(systemType: selectedSystemFilter) }
        }
        return list
    }

    public var searchText: String = ""
    public var selectedNodeFilter: String = "Все объекты"
    public var selectedSystemFilter: String = "Все системы"

    public var dashboardNodeFilter: String = "Все объекты"
    public var dashboardSystemFilter: String = "Все системы"
    public var podpitkaNodeFilter: String = "Все объекты"
    public var podpitkaSystemFilter: String = "Все системы"

    // MARK: - Results

    public var dashboardGroups: [DashboardNodeGroup] = []
    public var podpitkaGroups: [PodpitkaNodeGroup] = []
    public var generalResults: [PointResultData] = []
    public var trendHistory: [PointResultData] = []

    // MARK: - Outdoor temperature

    public var globalTnv: Double? = nil
    public var globalTnvUpdated: Date?
    public var globalTnvStatus: String = "Источник не выбран"

    // MARK: - Trend

    public var trendPointId: Int?

    // MARK: - Archive

    public var archivePointId: Int?
    public var archiveKind: ArchiveKind = .hour
    public var archiveDays: Int = 7
    public var archiveRows: [ArchiveRow] = []
    public var archiveAvailableKinds: [String] = []
    public var archiveStatus: String = ""
    public var isLoadingArchive: Bool = false

    // MARK: - Table columns

    public var showCols: [String: Bool] = [
        "T1": true, "T2": true, "ΔT": true, "P1": true, "P2": false,
        "ΔP": true, "V1": true, "V2": false, "M1": true, "M2": true, "Q": true
    ]

    // MARK: - Coordinator

    public let coordinator = LersCoordinator()

    private var connectionInfo: ConnectionInfo?
    private var tnvTask: Task<Void, Never>?
    private var trendTask: Task<Void, Never>?
    private var dashboardTask: Task<Void, Never>?
    private var podpitkaTask: Task<Void, Never>?

    public init() {
        loadSettings()
    }

    // MARK: - Selection helpers

    private func ids(for list: PointSelectionList) -> [Int] {
        switch list {
        case .general:   return settings.selectedPointIds
        case .dashboard: return settings.dashboardPointIds
        case .podpitka:  return settings.podpitkaPointIds
        }
    }

    private func setIds(_ values: [Int], for list: PointSelectionList) {
        switch list {
        case .general:   settings.selectedPointIds = values
        case .dashboard: settings.dashboardPointIds = values
        case .podpitka:  settings.podpitkaPointIds = values
        }
    }

    public func isSelected(_ id: Int, in list: PointSelectionList) -> Bool {
        ids(for: list).contains(id)
    }

    public func selectionCount(in list: PointSelectionList) -> Int {
        ids(for: list).count
    }

    public func toggleSelection(_ id: Int, in list: PointSelectionList) {
        var values = ids(for: list)
        if let idx = values.firstIndex(of: id) { values.remove(at: idx) }
        else { values.append(id) }
        setIds(values, for: list)
        if list == .dashboard { buildDashboardGroups() }
        if list == .podpitka { buildPodpitkaGroups() }
        saveSettings()
    }

    public func selectAll(_ points: [MeasurePointItem], in list: PointSelectionList) {
        setIds(points.map(\.id), for: list)
        if list == .dashboard { buildDashboardGroups() }
        if list == .podpitka { buildPodpitkaGroups() }
        saveSettings()
    }

    public func clearSelection(in list: PointSelectionList) {
        setIds([], for: list)
        if list == .dashboard { buildDashboardGroups() }
        if list == .podpitka { buildPodpitkaGroups() }
        saveSettings()
    }

    // MARK: - Connect (порт BtnConnect_Click)

    public func connect() async {
        statusText = "Подключение к серверу..."
        let cleanHost = Self.cleanHost(settings.host)
        let port = settings.port > 0 ? settings.port : 10000

        await coordinator.configure(host: cleanHost, port: port, token: nil)

        do {
            let token = try await coordinator.login(
                login: settings.login,
                password: KeychainHelper.loadPassword() ?? ""
            )
            connectionInfo = ConnectionInfo(host: cleanHost, port: port, token: token)
            statusText = "Загрузка объектов и точек учёта..."

            allPoints = await coordinator.fetchPoints()
            availableNodes = ["Все объекты"] + Array(Set(allPoints.map(\.nodeTitle))).sorted()
            isConnected = true

            buildDashboardGroups()
            buildPodpitkaGroups()
            restoreLastResults()
            saveSettings()

            statusText = "Подключено к \(cleanHost):\(port). Загружено точек: \(allPoints.count)"
            startTnvTimer()
            await updateGlobalTnv()

            // Оригинал сразу считывает архивные данные за закрытые периоды.
            await refreshPodpitka()
        } catch let err as LersNetworkError {
            isConnected = false
            if case .atsBlocked = err {
                statusText = "ATS блокирует HTTP.\n\(Self.atsDiagnostics())"
            } else {
                statusText = "Ошибка: \(err.errorDescription ?? err.localizedDescription)"
            }
        } catch {
            isConnected = false
            statusText = "Ошибка подключения: \(error.localizedDescription)"
        }
    }

    public func reconnectIfNeeded() async {
        let code = await coordinator.ping()
        if code == 401 || code == 403 {
            isConnected = false
            statusText = "Сессия истекла. Переподключение..."
            await connect()
        } else if code == 0 {
            statusText = "Потеря связи с сервером"
        }
    }

    private static func cleanHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Filters (порт ApplyFilters / ApplyFiltersDashboard / ApplyFiltersPodpitka)

    public var filteredDashboardPoints: [MeasurePointItem] {
        allPoints.filter {
            (dashboardNodeFilter == "Все объекты" || $0.nodeTitle == dashboardNodeFilter) &&
            (dashboardSystemFilter == "Все системы" || $0.matches(systemType: dashboardSystemFilter))
        }
    }

    public var filteredPodpitkaPoints: [MeasurePointItem] {
        allPoints.filter {
            (podpitkaNodeFilter == "Все объекты" || $0.nodeTitle == podpitkaNodeFilter) &&
            (podpitkaSystemFilter == "Все системы" || $0.matches(systemType: podpitkaSystemFilter))
        }
    }

    // MARK: - Groups (порт RefreshDashboardNodes / RefreshPodpitkaNodes)

    public func buildDashboardGroups() {
        // Если пользователь ничего не выбрал — показываем все точки (удобно на iOS).
        let chosen = settings.dashboardPointIds.isEmpty
            ? allPoints.map(\.id)
            : settings.dashboardPointIds
        let targets = allPoints.filter { chosen.contains($0.id) }
        let grouped = Dictionary(grouping: targets) { $0.nodeTitle }
        let previousPaused = Dictionary(uniqueKeysWithValues: dashboardGroups.map { ($0.nodeTitle, $0.isPaused) })

        dashboardGroups = grouped.map { node, pts in
            DashboardNodeGroup(
                nodeTitle: node,
                points: pts.map {
                    PointResultData(id: $0.id, title: $0.title, nodeTitle: $0.nodeTitle,
                                    limits: settings.pointLimits[$0.id])
                },
                isPaused: previousPaused[node] ?? false
            )
        }.sorted { $0.nodeTitle < $1.nodeTitle }
        restoreLastResults()
    }

    public func buildPodpitkaGroups() {
        var chosen = settings.podpitkaPointIds
        if chosen.isEmpty {
            // Автовыбор: точки, в названии которых есть «подпит».
            chosen = allPoints.filter { $0.title.localizedCaseInsensitiveContains("подпит") }.map(\.id)
        }
        let targets = allPoints.filter { chosen.contains($0.id) }
        let grouped = Dictionary(grouping: targets) { $0.nodeTitle }
        podpitkaGroups = grouped.map { node, pts in
            PodpitkaNodeGroup(
                nodeTitle: node,
                points: pts.map {
                    PodpitkaPointData(id: $0.id, title: $0.title, nodeTitle: $0.nodeTitle,
                                      limits: settings.podpitkaLimits[$0.id])
                }
            )
        }.sorted { $0.nodeTitle < $1.nodeTitle }
    }

    public func togglePause(nodeTitle: String) {
        guard let idx = dashboardGroups.firstIndex(where: { $0.nodeTitle == nodeTitle }) else { return }
        dashboardGroups[idx].isPaused.toggle()
        statusText = dashboardGroups[idx].isPaused
            ? "Опрос объекта «\(nodeTitle)» приостановлен"
            : "Опрос объекта «\(nodeTitle)» возобновлён"
    }

    // MARK: - Apply poll outcome

    private func apply(_ outcome: PollOutcome, to p: PointResultData) {
        p.state = outcome.state
        p.status = outcome.message
        if let s = outcome.snapshot {
            p.t1 = s.values.t1
            p.t2 = s.values.t2
            p.p1 = s.values.p1
            p.p2 = s.values.p2
            p.v1 = s.values.v1
            p.v2 = s.values.v2
            p.m1 = s.values.m1
            p.m2 = s.values.m2
            p.q = s.values.q
            p.deviceTime = s.deviceTime
        }
    }

    // MARK: - Poll single / all / selected (порт BtnStartMonitor_Click)

    public func pollSinglePoint(_ p: PointResultData) async {
        p.state = .polling
        p.status = "Идет опрос..."
        let outcome = await coordinator.pollPoint(pointId: p.id, nodeTitle: p.nodeTitle, ignoreCache: true)
        apply(outcome, to: p)
        saveLastResults()
    }

    /// Плановый/принудительный опрос дашборда. Кэш 3 минуты уважается.
    public func pollAllPoints() async {
        guard !isPollingAll else { return }
        isPollingAll = true
        statusText = "Опрос точек дашборда..."

        let active = dashboardGroups.filter { !$0.isPaused }
        let allPts = active.flatMap(\.points)
        for p in allPts where p.state != .polling {
            p.state = .queued
            p.status = "В очереди"
        }

        // Как WPF PollCoordinator.Updated: каждая точка обновляется сразу по
        // завершении своего опроса, а не после окончания всей пачки.
        let coordinator = self.coordinator
        await withTaskGroup(of: Void.self) { group in
            for p in allPts {
                let target = PollTarget(pointId: p.id, nodeKey: p.nodeTitle)
                group.addTask { @MainActor in
                    let outcome = await coordinator.poll(target: target, ignoreCache: false)
                    self.apply(outcome, to: p)
                }
            }
        }

        let ok = allPts.filter { $0.state == .ok || $0.state == .okCached }.count
        statusText = "Опрос завершён: \(ok) из \(allPts.count) точек"
        isPollingAll = false
        saveLastResults()
    }

    /// Опрос выбранных точек на вкладке «Точки учёта».
    public func pollSelectedPoints() async {
        guard !isPollingSelected else { return }
        let chosen = settings.selectedPointIds.isEmpty
            ? filteredPoints.map(\.id)
            : settings.selectedPointIds
        let points = allPoints.filter { chosen.contains($0.id) }
        guard !points.isEmpty else {
            statusText = "Выберите точки учёта в списке"
            return
        }

        isPollingSelected = true
        generalResults = points.map {
            PointResultData(id: $0.id, title: $0.title, nodeTitle: $0.nodeTitle,
                            limits: settings.pointLimits[$0.id])
        }
        for p in generalResults { p.state = .queued; p.status = "В очереди" }

        let coordinator = self.coordinator
        await withTaskGroup(of: Void.self) { group in
            for p in generalResults {
                let target = PollTarget(pointId: p.id, nodeKey: p.nodeTitle)
                group.addTask { @MainActor in
                    let outcome = await coordinator.poll(target: target, ignoreCache: false)
                    self.apply(outcome, to: p)
                }
            }
        }

        let ok = generalResults.filter { $0.state == .ok || $0.state == .okCached }.count
        statusText = "Мониторинг завершён: \(ok) из \(generalResults.count) точек"
        isPollingSelected = false
        saveLastResults()
    }

    /// Прочитать показания без опроса прибора.
    public func readOnly(pointId: Int) async {
        let outcome = await coordinator.readOnly(target: PollTarget(pointId: pointId, nodeKey: ""))
        for p in dashboardGroups.flatMap(\.points) where p.id == pointId { apply(outcome, to: p) }
        for p in generalResults where p.id == pointId { apply(outcome, to: p) }
        statusText = "Считано из ЛЭРС: \(outcome.message)"
        saveLastResults()
    }

    // MARK: - Outdoor temperature (порт UpdateGlobalTnvAsync)

    public func updateGlobalTnv() async {
        guard let id = settings.tnvSourcePointId else {
            globalTnv = nil
            globalTnvStatus = "Источник не выбран"
            return
        }
        guard let snap = await coordinator.readLast(pointId: id) else {
            globalTnvStatus = "Нет ответа от источника"
            return
        }
        if let t = snap.values.tnv ?? snap.values.t1 ?? snap.values.t2 {
            globalTnv = t + settings.tnvCorrection
            globalTnvUpdated = Date()
            globalTnvStatus = "Обновлено в \(Date().formatted(date: .omitted, time: .standard))"
        } else {
            globalTnvStatus = "Параметр Тнв не найден"
        }
    }

    private func startTnvTimer() {
        tnvTask?.cancel()
        tnvTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await updateGlobalTnv()
            }
        }
    }

    // MARK: - Trend monitoring (порт BtnStartTrend_Click / StopNativeLersTrend)

    public func startTrend(pointId: Int, durationMin: Int = 3) {
        guard !isTrendRunning else { return }
        trendPointId = pointId
        isTrendRunning = true
        let duration = max(1, durationMin)
        let end = Date().addingTimeInterval(Double(duration) * 60)

        trendTask = Task {
            await coordinator.startTrendPolling(pointId: pointId)
            var lastObserved: Date?
            while !Task.isCancelled && Date() < end {
                if let snap = await coordinator.readLast(pointId: pointId) {
                    let dt = snap.deviceTime ?? snap.readAtUtc
                    if lastObserved == nil || dt > lastObserved! {
                        lastObserved = dt
                        let row = PointResultData(id: pointId,
                                                  title: allPoints.first { $0.id == pointId }?.title ?? "",
                                                  nodeTitle: allPoints.first { $0.id == pointId }?.nodeTitle ?? "",
                                                  limits: settings.pointLimits[pointId])
                        apply(PollOutcome(pointId: pointId, state: .ok, message: "Снято", snapshot: snap), to: row)
                        row.state = .ok
                        row.status = "Снято \(dt.formatted(date: .omitted, time: .standard))"
                        trendHistory.insert(row, at: 0)
                        if trendHistory.count > 200 { trendHistory.removeLast(trendHistory.count - 200) }
                    }
                }
                let remain = max(0, end.timeIntervalSinceNow)
                trendRemainingText = String(format: "Осталось %d мин %d сек",
                                            Int(remain) / 60, Int(remain) % 60)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await coordinator.stopTrendPolling(pointId: pointId)
            isTrendRunning = false
            trendRemainingText = ""
            statusText = Date() >= end
                ? "Лимит времени (\(duration) мин) исчерпан"
                : "Мониторинг точки остановлен"
        }
    }

    public func stopTrend() {
        trendTask?.cancel()
        isTrendRunning = false
        trendRemainingText = ""
    }

    public func clearTrend() { trendHistory.removeAll() }

    // MARK: - Dashboard scheduler (порт PollScheduler)

    public func startDashboardScheduler() {
        guard !isDashboardSchedulerRunning else { return }
        isDashboardSchedulerRunning = true
        dashboardTask = Task {
            await pollAllPoints()
            while !Task.isCancelled {
                let seconds = UInt64(max(1, settings.dashboardIntervalMin)) * 60
                dashboardNextRun = Date().addingTimeInterval(Double(seconds))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                await pollAllPoints()
            }
            dashboardNextRun = nil
            isDashboardSchedulerRunning = false
        }
    }

    public func stopDashboardScheduler() {
        dashboardTask?.cancel()
        isDashboardSchedulerRunning = false
        dashboardNextRun = nil
        statusText = "Автоопрос дашборда остановлен"
    }

    public func forcePollNow() async { await pollAllPoints() }

    // MARK: - Podpitka scheduler + cycle (порт RefreshAsync)

    public func refreshPodpitka() async {
        let allPts = podpitkaGroups.flatMap(\.points)
        guard !allPts.isEmpty else { return }
        for p in allPts { p.state = .polling; p.message = "Чтение архивов..." }

        let now = Date()
        let startDay = settings.reportPeriodStartDay
        let endDay = settings.reportPeriodEndDay
        let coordinator = self.coordinator

        let results = await withTaskGroup(of: PodpitkaResult.self) { group in
            for p in allPts {
                let pid = p.id
                group.addTask {
                    let volumes = await coordinator.refreshVolumes(
                        pointId: pid, now: now, startDay: startDay, endDay: endDay
                    )
                    return PodpitkaResult(pointId: pid, volumes: volumes)
                }
            }
            var collected: [PodpitkaResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let byId = Dictionary(results.map { ($0.pointId, $0.volumes) }, uniquingKeysWith: { first, _ in first })
        for p in allPts {
            guard let v = byId[p.id] else { continue }
            p.setVolumes(report: v.report, day: v.day, today: v.today, hour: v.hour)
            let hasAny = v.report != nil || v.day != nil || v.today != nil || v.hour != nil
            p.state = hasAny ? .ok : .error
            p.message = hasAny
                ? "Обновлено в \(Date().formatted(date: .omitted, time: .standard))"
                : "Нет архивных данных в ЛЭРС"
        }
        statusText = "Подпитка обновлена: \(allPts.count) точек"
    }

    public func startPodpitkaScheduler() {
        guard !isPodpitkaSchedulerRunning else { return }
        isPodpitkaSchedulerRunning = true
        podpitkaTask = Task {
            await refreshPodpitka()
            while !Task.isCancelled {
                let seconds = UInt64(max(1, settings.podpitkaIntervalMin)) * 60
                podpitkaNextRun = Date().addingTimeInterval(Double(seconds))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                await refreshPodpitka()
            }
            podpitkaNextRun = nil
            isPodpitkaSchedulerRunning = false
        }
    }

    public func stopPodpitkaScheduler() {
        podpitkaTask?.cancel()
        isPodpitkaSchedulerRunning = false
        podpitkaNextRun = nil
    }

    // MARK: - Archive (порт BtnArchiveLoad_Click)

    public func loadArchive() async {
        guard let id = archivePointId else {
            archiveStatus = "Выберите точку учёта."
            return
        }
        isLoadingArchive = true
        archiveStatus = "Загрузка данных из ЛЭРС..."
        archiveRows = []
        archiveAvailableKinds = []

        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -archiveDays, to: now) ?? now
        let to = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let result = await coordinator.loadArchive(pointId: id, kind: archiveKind, from: from, to: to)

        archiveRows = result.rows
        archiveAvailableKinds = result.availableKinds
        if result.rows.isEmpty {
            let avail = result.availableKinds.isEmpty
                ? "Ответ ЛЭРС не содержит архивов"
                : "В ответе ЛЭРС есть: \(result.availableKinds.joined(separator: ", "))"
            archiveStatus = "Архив «\(archiveKind.rawValue)» за выбранный период пуст. \(avail)."
        } else {
            archiveStatus = "Загружено записей: \(result.rows.count) (\(archiveKind.rawValue.lowercased()))"
        }
        isLoadingArchive = false
    }

    // MARK: - Limits / schedule

    public func setLimits(_ limits: PointThresholds, for pointId: Int, applyToAll: Bool = false) {
        if applyToAll {
            for id in allPoints.map(\.id) { settings.pointLimits[id] = limits }
        } else {
            settings.pointLimits[pointId] = limits
        }
        for p in dashboardGroups.flatMap(\.points) { p.limits = settings.pointLimits[p.id] }
        for p in generalResults { p.limits = settings.pointLimits[p.id] }
        saveSettings()
    }

    public func setPodpitkaLimits(_ limits: VolumeThresholds, for pointId: Int) {
        settings.podpitkaLimits[pointId] = limits
        for p in podpitkaGroups.flatMap(\.points) { p.limits = settings.podpitkaLimits[p.id] }
        saveSettings()
    }

    // MARK: - Last results persistence (порт SaveUserSettings с LastResults)

    public func saveLastResults() {
        settings.lastResults = (dashboardGroups.flatMap(\.points) + generalResults).map { $0.toSaved() }
        saveSettings()
    }

    private func restoreLastResults() {
        let saved = Dictionary(settings.lastResults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for p in dashboardGroups.flatMap(\.points) {
            if let s = saved[p.id] { p.restore(from: s) }
        }
        for p in generalResults {
            if let s = saved[p.id] { p.restore(from: s) }
        }
    }

    // MARK: - ATS diagnostics

    public static func atsDiagnostics() -> String {
        guard let bundle = Bundle.main.infoDictionary else {
            return "Info.plist не найден в бандле"
        }
        guard let ats = bundle["NSAppTransportSecurity"] as? [String: Any] else {
            return "NSAppTransportSecurity ОТСУТСТВУЕТ в бандле — Info.plist не применился"
        }
        let arbitrary = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        let webContent = (ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool) ?? false
        let local = (ats["NSAllowsLocalNetworking"] as? Bool) ?? false
        var lines = [
            "NSAllowsArbitraryLoads: \(arbitrary)",
            "NSAllowsArbitraryLoadsInWebContent: \(webContent)",
            "NSAllowsLocalNetworking: \(local)"
        ]
        if let exc = ats["NSExceptionDomains"] as? [String: Any] {
            lines.append("ExceptionDomains: \(exc.keys.sorted().joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Settings persistence (пароль в Keychain)

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "LersSettings"),
           let set = try? JSONDecoder().decode(UserSettings.self, from: data) {
            settings = set
        }
        if let id = settings.tnvSourcePointId { trendPointId = id }
    }

    public func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(d, forKey: "LersSettings")
        }
    }

    public func savePassword(_ password: String) {
        if settings.rememberCredentials {
            KeychainHelper.savePassword(password)
        } else {
            KeychainHelper.deletePassword()
        }
    }

    public func loadPassword() -> String {
        KeychainHelper.loadPassword() ?? ""
    }

    /// Полная остановка фоновых задач (при выходе / смене сервера).
    public func stopAllSchedulers() {
        tnvTask?.cancel()
        trendTask?.cancel()
        dashboardTask?.cancel()
        podpitkaTask?.cancel()
        isTrendRunning = false
        isDashboardSchedulerRunning = false
        isPodpitkaSchedulerRunning = false
        dashboardNextRun = nil
        podpitkaNextRun = nil
    }
}
