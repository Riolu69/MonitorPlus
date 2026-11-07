import SwiftUI

public struct DashboardView: View {
    @Bindable var vm: AppViewModel
    @State private var selectedLogPoint: PointResultData?
    @State private var showSelection = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            Group {
                if !vm.isConnected {
                    ContentUnavailableView(
                        "Нет подключения",
                        systemImage: "wifi.slash",
                        description: Text("Подключитесь к серверу ЛЭРС УЧЁТ в настройках")
                    )
                } else if vm.dashboardGroups.isEmpty {
                    ContentUnavailableView(
                        "Нет точек учёта",
                        systemImage: "square.grid.2x2",
                        description: Text("После подключения точки появятся здесь")
                    )
                } else {
                    dashboardContent
                }
            }
            .navigationTitle("Дашборд")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { schedulerMenu }
                ToolbarItem(placement: .topBarTrailing) { pollButton }
            }
            .sheet(item: $selectedLogPoint) { pt in
                PollLogSheetView(pointId: pt.id, pointTitle: pt.title, coordinator: vm.coordinator)
            }
            .sheet(isPresented: $showSelection) {
                PointSelectionSheet(vm: vm, list: .dashboard, title: "Точки дашборда")
            }
        }
    }

    private var pollButton: some View {
        Group {
            if vm.isPollingAll {
                ProgressView()
            } else {
                Button("Опросить всё") {
                    Task { await vm.pollAllPoints() }
                }
            }
        }
    }

    /// Планировщик без дрейфа, интервал, принудительный опрос, выбор точек.
    private var schedulerMenu: some View {
        Menu {
            Button {
                Task { await vm.forcePollNow() }
            } label: {
                Label("Принудительный опрос", systemImage: "arrow.clockwise")
            }
            .disabled(vm.isPollingAll)

            Divider()

            if vm.isDashboardSchedulerRunning {
                Button(role: .destructive) {
                    vm.stopDashboardScheduler()
                } label: {
                    Label("Остановить автоопрос", systemImage: "stop.circle")
                }
            } else {
                Button {
                    vm.startDashboardScheduler()
                } label: {
                    Label("Запустить автоопрос", systemImage: "play.circle")
                }
            }

            Picker("Интервал автоопроса", selection: $vm.settings.dashboardIntervalMin) {
                ForEach([1, 5, 10, 15, 30, 60], id: \.self) { min in
                    Text("\(min) мин").tag(min)
                }
            }

            Divider()

            Button {
                showSelection = true
            } label: {
                Label("Выбрать точки", systemImage: "checklist")
            }
        } label: {
            Image(systemName: vm.isDashboardSchedulerRunning ? "clock.badge.checkmark" : "ellipsis.circle")
        }
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                statusBanner
                LazyVStack(spacing: 16) {
                    ForEach(vm.dashboardGroups) { group in
                        NodeSectionView(
                            group: group,
                            currentTnv: vm.globalTnv,
                            onTogglePause: { vm.togglePause(nodeTitle: group.nodeTitle) },
                            onPoll: { pt in Task { await vm.pollSinglePoint(pt) } },
                            onShowLog: { pt in selectedLogPoint = pt }
                        )
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await vm.pollAllPoints()
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tnv = vm.globalTnv {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.blue)
                    Text("Тнв")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f °C", tnv))
                        .font(.headline)
                }
            }
            if vm.isDashboardSchedulerRunning, let next = vm.dashboardNextRun {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.green)
                    Text("Автоопрос: каждые \(vm.settings.dashboardIntervalMin) мин")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("след. \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(vm.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Node section (grouped card with pause)
struct NodeSectionView: View {
    let group: DashboardNodeGroup
    let currentTnv: Double?
    var onTogglePause: () -> Void
    var onPoll: (PointResultData) -> Void
    var onShowLog: (PointResultData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.nodeTitle)
                        .font(.headline)
                    Text(group.generalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onTogglePause()
                } label: {
                    Image(systemName: group.isPaused ? "play.circle" : "pause.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.isPaused ? "Возобновить опрос" : "Приостановить опрос")
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(group.points) { pt in
                    PointCardView(pt: pt, currentTnv: currentTnv,
                                  onPoll: { onPoll(pt) }, onShowLog: { onShowLog(pt) })
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Point card
struct PointCardView: View {
    let pt: PointResultData
    let currentTnv: Double?
    var onPoll: () -> Void
    var onShowLog: () -> Void

    private var statusColor: Color {
        if pt.state == .error { return .red }
        if pt.hasBreach(currentTnv: currentTnv) { return .red }
        if pt.state == .ok || pt.state == .okCached { return .green }
        if pt.state == .polling || pt.state == .queued { return .orange }
        return .secondary
    }

    private var statusIcon: String {
        switch pt.state {
        case .ok: return "checkmark.circle.fill"
        case .okCached: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .polling: return "arrow.triangle.2.circlepath"
        case .queued: return "hourglass"
        case .paused: return "pause.circle.fill"
        case .pending: return "circle.dotted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pt.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.callout)
            }

            Text(pt.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            VStack(spacing: 5) {
                metricRow("T1", value: pt.t1, unit: "°C",
                          breach: pt.isBreached(pt.t1, pt.limits?.t1Min, pt.limits?.t1Max)
                                  || pt.isT1ScheduleBreached(currentTnv: currentTnv))
                if let exp = pt.expectedT1(currentTnv: currentTnv) {
                    metricRow("T1 график", value: exp, unit: "°C")
                }
                metricRow("T2", value: pt.t2, unit: "°C",
                          breach: pt.isBreached(pt.t2, pt.limits?.t2Min, pt.limits?.t2Max)
                                  || pt.isT2ScheduleBreached(currentTnv: currentTnv))
                metricRow("ΔT", value: pt.deltaT, unit: "°C")
                metricRow("P1", value: pt.p1, unit: "атм",
                          breach: pt.isBreached(pt.p1, pt.limits?.p1Min, pt.limits?.p1Max))
                metricRow("V1", value: pt.v1, unit: "м³/ч",
                          breach: pt.isBreached(pt.v1, pt.limits?.v1Min, pt.limits?.v1Max))
                metricRow("Q", value: pt.q, unit: "Гкал",
                          breach: pt.isBreached(pt.q, pt.limits?.qMin, pt.limits?.qMax))
            }

            HStack(spacing: 12) {
                Button { onPoll() } label: {
                    Label("Опросить", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { onShowLog() } label: {
                    Label("Журнал", systemImage: "doc.text").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            if pt.hasBreach(currentTnv: currentTnv) {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func metricRow(_ label: String, value: Double?, unit: String, breach: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value != nil ? String(format: "%.1f", value!) : "—")
                .font(.callout.weight(breach ? .bold : .regular))
                .foregroundStyle(breach ? .red : .primary)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
