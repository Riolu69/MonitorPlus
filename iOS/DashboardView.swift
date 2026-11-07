import SwiftUI

public struct DashboardView: View {
    @Bindable var vm: AppViewModel
    @State private var selectedLogPoint: PointResultData?
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Панель масштаба карточек и статуса
                HStack {
                    Text("Масштаб карточек:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $vm.settings.uiScale, in: 0.7...1.4, step: 0.05)
                        .frame(width: 130)
                    Spacer()
                    if let tnv = vm.globalTnv {
                        Text(String(format: "Тнв: %.1f °C", tnv))
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground))
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(vm.dashboardGroups) { group in
                            NodeCardView(group: group, currentTnv: vm.globalTnv, scale: vm.settings.uiScale) { pt in
                                Task { await vm.pollSinglePoint(pt) }
                            } onShowLog: { pt in
                                selectedLogPoint = pt
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Дашборд")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Опросить всё") {
                        Task {
                            for g in vm.dashboardGroups where !g.isPaused {
                                for p in g.points {
                                    await vm.pollSinglePoint(p)
                                }
                            }
                        }
                    }
                    .font(.footnote.bold())
                }
            }
            .sheet(item: $selectedLogPoint) { pt in
                PollLogSheetView(pointId: pt.id, pointTitle: pt.title, coordinator: vm.coordinator)
            }
        }
    }
}

// Карточка объекта со вложенными плитками
struct NodeCardView: View {
    let group: DashboardNodeGroup
    let currentTnv: Double?
    let scale: Double
    var onPoll: (PointResultData) -> Void
    var onShowLog: (PointResultData) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.nodeTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            
            // Внутренняя сетка плиток (адаптивная колонка)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155 * scale), spacing: 8)], spacing: 8) {
                ForEach(group.points) { pt in
                    PointTileView(pt: pt, currentTnv: currentTnv, scale: scale, onPoll: { onPoll(pt) }, onShowLog: { onShowLog(pt) })
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }
}

struct PointTileView: View {
    let pt: PointResultData
    let currentTnv: Double?
    let scale: Double
    var onPoll: () -> Void
    var onShowLog: () -> Void
    
    private var tileBg: Color {
        if pt.state == .error { return .orange }
        if pt.hasBreach(currentTnv: currentTnv) { return .red }
        if pt.state == .ok || pt.state == .okCached { return .green }
        return Color(.systemGray4)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pt.title)
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button(action: onShowLog) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.white)
                }
                Button(action: onPoll) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.white)
                }
            }
            Divider().background(.white.opacity(0.3))
            
            HStack {
                Text("T1/T2:").font(.system(size: 10 * scale)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(fmt(pt.t1)) / \(fmt(pt.t2)) °C")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("ΔT:").font(.system(size: 10 * scale)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(fmt(pt.deltaT)) °C")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("P1/P2:").font(.system(size: 10 * scale)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(fmt(pt.p1)) / \(fmt(pt.p2))")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("V1:").font(.system(size: 10 * scale)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(fmt(pt.v1, "%.2f")) м³/ч")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("Q:").font(.system(size: 10 * scale)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(fmt(pt.q, "%.3f")) Гкал")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(8)
        .background(tileBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func fmt(_ v: Double?, _ f: String = "%.1f") -> String {
        guard let v = v else { return "—" }
        return String(format: f, v)
    }
}
