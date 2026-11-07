import SwiftUI

// MARK: - Модальное окно журнала опроса
public struct PollLogSheetView: View {
    let pointId: Int
    let pointTitle: String
    let coordinator: LersCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PollLogEntry] = []
    
    public init(pointId: Int, pointTitle: String, coordinator: LersCoordinator) {
        self.pointId = pointId
        self.pointTitle = pointTitle
        self.coordinator = coordinator
    }
    
    public var body: some View {
        NavigationStack {
            List(entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(stateColor(entry.state))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("[\(entry.phase)]")
                                .font(.caption2.bold())
                                .foregroundStyle(.blue)
                        }
                        Text(entry.message)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ход опроса: \(pointTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Очистить") {
                        Task {
                            await coordinator.clearLogs(pointId: pointId)
                            entries = []
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    self.entries = await coordinator.getLogs(pointId: pointId)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
    
    private func stateColor(_ st: PollState) -> Color {
        switch st {
        case .ok, .okCached: return .green
        case .error: return .red
        case .polling: return .orange
        default: return .gray
        }
    }
}

// MARK: - Модальное окно настройки границ точки
public struct LimitsEditorSheet: View {
    let pointId: Int
    let title: String
    @Bindable var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var limits: PointThresholds = PointThresholds()
    @State private var showScheduleEditor = false
    
    public init(pointId: Int, title: String, vm: AppViewModel) {
        self.pointId = pointId
        self.title = title
        self.vm = vm
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section("Температурный график") {
                    HStack {
                        Text("Узловых точек графика:")
                        Spacer()
                        Text("\(limits.schedule.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Допуск (±):")
                        Spacer()
                        TextField("3.0", value: $limits.scheduleTolerance, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("°C")
                    }
                    Button("📈 Открыть редактор графика") {
                        showScheduleEditor = true
                    }
                }
                
                Section("Границы температур (°C)") {
                    HStack {
                        TextField("T1 Мин", value: $limits.t1Min, format: .number)
                        TextField("T1 Макс", value: $limits.t1Max, format: .number)
                    }
                    HStack {
                        TextField("T2 Мин", value: $limits.t2Min, format: .number)
                        TextField("T2 Макс", value: $limits.t2Max, format: .number)
                    }
                }
                
                Section("Границы давления (атм)") {
                    HStack {
                        TextField("P1 Мин", value: $limits.p1Min, format: .number)
                        TextField("P1 Макс", value: $limits.p1Max, format: .number)
                    }
                    HStack {
                        TextField("P2 Мин", value: $limits.p2Min, format: .number)
                        TextField("P2 Макс", value: $limits.p2Max, format: .number)
                    }
                }
                
                Section("Расход и масса") {
                    HStack {
                        TextField("V1 Мин", value: $limits.v1Min, format: .number)
                        TextField("V1 Макс", value: $limits.v1Max, format: .number)
                    }
                    HStack {
                        TextField("Q Мин", value: $limits.qMin, format: .number)
                        TextField("Q Макс", value: $limits.qMax, format: .number)
                    }
                }
            }
            .navigationTitle("Границы")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                self.limits = vm.settings.pointLimits[pointId] ?? PointThresholds()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        vm.settings.pointLimits[pointId] = limits
                        vm.saveSettings()
                        vm.buildDashboardGroups()
                        dismiss()
                    }
                    .bold()
                }
            }
            .sheet(isPresented: $showScheduleEditor) {
                ScheduleTableSheet(schedule: $limits.schedule)
            }
        }
    }
}

// MARK: - Таблица узлов температурного графика
public struct ScheduleTableSheet: View {
    @Binding var schedule: [TempSchedulePoint]
    @Environment(\.dismiss) private var dismiss
    
    public init(schedule: Binding<[TempSchedulePoint]>) {
        self._schedule = schedule
    }
    
    public var body: some View {
        NavigationStack {
            List {
                ForEach($schedule) { $pt in
                    HStack {
                        Text("Тнв:")
                        TextField("0", value: $pt.tnv, format: .number).frame(width: 45)
                        Text("T1:")
                        TextField("70", value: $pt.t1, format: .number).frame(width: 45)
                        Text("T2:")
                        TextField("50", value: $pt.t2, format: .number).frame(width: 45)
                    }
                    .font(.footnote)
                }
                .onDelete { schedule.remove(atOffsets: $0) }
            }
            .navigationTitle("Узлы графика")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Добавить") {
                        schedule.append(TempSchedulePoint(tnv: 0, t1: 70, t2: 50))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }.bold()
                }
            }
        }
    }
}
