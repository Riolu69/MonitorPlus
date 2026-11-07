import SwiftUI

public struct DashboardView: View {
    @Bindable var vm: AppViewModel
    @State private var selectedLogPoint: PointResultData?

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
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.isPollingAll {
                        ProgressView()
                    } else {
                        Button("Опросить всё") {
                            Task { await vm.pollAllPoints() }
                        }
                        .disabled(vm.isPollingAll)
                    }
                }
            }
            .sheet(item: $selectedLogPoint) { pt in
                PollLogSheetView(pointId: pt.id, pointTitle: pt.title, coordinator: vm.coordinator)
            }
        }
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Tnv banner
                if let tnv = vm.globalTnv {
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.blue)
                        Text("Температура наружного воздуха")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f °C", tnv))
                            .font(.headline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                LazyVStack(spacing: 16) {
                    ForEach(vm.dashboardGroups) { group in
                        NodeSectionView(group: group, currentTnv: vm.globalTnv) { pt in
                            Task { await vm.pollSinglePoint(pt) }
                        } onShowLog: { pt in
                            selectedLogPoint = pt
                        }
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
}

// MARK: - Node section (grouped card)
struct NodeSectionView: View {
    let group: DashboardNodeGroup
    let currentTnv: Double?
    var onPoll: (PointResultData) -> Void
    var onShowLog: (PointResultData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.nodeTitle)
                .font(.headline)
                .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(group.points) { pt in
                    PointCardView(pt: pt, currentTnv: currentTnv, onPoll: { onPoll(pt) }, onShowLog: { onShowLog(pt) })
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Point card (Apple-style: system background, accent for status)
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
            // Header: title + status + actions
            HStack {
                Text(pt.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.callout)
                    .symbolEffect(.rotate, isActive: pt.state == .polling)
            }

            Divider()

            // Values
            VStack(spacing: 5) {
                metricRow("T1", value: pt.t1, unit: "°C", breach: pt.isBreached(pt.t1, pt.limits?.t1Min, pt.limits?.t1Max))
                metricRow("T2", value: pt.t2, unit: "°C", breach: pt.isBreached(pt.t2, pt.limits?.t2Min, pt.limits?.t2Max))
                metricRow("ΔT", value: pt.deltaT, unit: "°C")
                metricRow("V1", value: pt.v1, unit: "м³/ч", breach: pt.isBreached(pt.v1, pt.limits?.v1Min, pt.limits?.v1Max))
                metricRow("Q", value: pt.q, unit: "Гкал")
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    onPoll()
                } label: {
                    Label("Опросить", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onShowLog()
                } label: {
                    Label("Журнал", systemImage: "doc.text")
                        .font(.caption)
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
