import SwiftUI

// MARK: - Poll log sheet (AsyncStream push, no polling loop)
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
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Нет записей",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Журнал опроса пуст. Запросите опрос точки, чтобы увидеть ход выполнения.")
                    )
                } else {
                    logList
                }
            }
            .navigationTitle("Журнал: \(pointTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Очистить", role: .destructive) {
                        Task {
                            await coordinator.clearLogs(pointId: pointId)
                            entries = []
                        }
                    }
                    .disabled(entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                // Stream new log entries as they arrive (push, no polling)
                let stream = await coordinator.logStream(pointId: pointId)
                for await entry in stream {
                    entries.append(entry)
                    if entries.count > 150 {
                        entries.removeFirst(entries.count - 150)
                    }
                }
            }
        }
    }

    private var logList: some View {
        List {
            ForEach(entries.reversed()) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stateIcon(entry.state))
                        .foregroundStyle(stateColor(entry.state))
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.phase)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        Text(entry.message)
                            .font(.footnote)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
    }

    private func stateColor(_ st: PollState) -> Color {
        switch st {
        case .ok, .okCached: return .green
        case .error: return .red
        case .polling: return .orange
        default: return .gray
        }
    }

    private func stateIcon(_ st: PollState) -> String {
        switch st {
        case .ok: return "checkmark.circle.fill"
        case .okCached: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .polling: return "arrow.triangle.2.circlepath"
        case .queued: return "hourglass"
        case .paused: return "pause.circle.fill"
        case .pending: return "circle.dotted"
        }
    }
}

// MARK: - Limits editor sheet (Apple-style Form)
public struct LimitsEditorSheet: View {
    @Bindable var vm: AppViewModel
    let pointId: Int
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var limits: PointThresholds = PointThresholds()
    @State private var showScheduleEditor = false
    @State private var applyToAll = false

    public init(vm: AppViewModel, pointId: Int, title: String) {
        self.vm = vm
        self.pointId = pointId
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Temperature schedule
                Section {
                    HStack {
                        Text("Узловых точек")
                        Spacer()
                        Text("\(limits.schedule.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Допуск")
                        Spacer()
                        TextField("3.0", value: $limits.scheduleTolerance, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("°C")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showScheduleEditor = true
                    } label: {
                        Label("Редактор графика", systemImage: "chart.line.uptrend.xyaxis")
                    }
                } header: {
                    Text("Температурный график")
                } footer: {
                    Text("График определяет ожидаемые температуры T1/T2 в зависимости от Тнв. Допуск — отклонение, при котором фиксируется нарушение.")
                }

                // Temperature limits
                Section("Температуры, °C") {
                    limitRow("T1", min: $limits.t1Min, max: $limits.t1Max)
                    limitRow("T2", min: $limits.t2Min, max: $limits.t2Max)
                }

                // Pressure limits
                Section("Давление, атм") {
                    limitRow("P1", min: $limits.p1Min, max: $limits.p1Max)
                    limitRow("P2", min: $limits.p2Min, max: $limits.p2Max)
                }

                // Flow and heat
                Section("Расход и теплоэнергия") {
                    limitRow("V1", min: $limits.v1Min, max: $limits.v1Max, unit: "м³/ч")
                    limitRow("V2", min: $limits.v2Min, max: $limits.v2Max, unit: "м³/ч")
                    limitRow("M1", min: $limits.m1Min, max: $limits.m1Max, unit: "т")
                    limitRow("M2", min: $limits.m2Min, max: $limits.m2Max, unit: "т")
                    limitRow("Q", min: $limits.qMin, max: $limits.qMax, unit: "Гкал")
                }

                Section {
                    Toggle("Применить ко всем точкам", isOn: $applyToAll)
                    Button("Сбросить границы", role: .destructive) {
                        limits = PointThresholds()
                    }
                } header: {
                    Text("Область применения")
                } footer: {
                    Text("Границы и температурный график используются для подсветки нарушений на дашборде, в списке точек и тренде.")
                }
            }
            .navigationTitle("Границы")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                self.limits = vm.settings.pointLimits[pointId] ?? PointThresholds()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        vm.setLimits(limits, for: pointId, applyToAll: applyToAll)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showScheduleEditor) {
                ScheduleTableSheet(schedule: $limits.schedule)
            }
        }
    }

    @ViewBuilder
    private func limitRow(_ label: String, min: Binding<Double?>, max: Binding<Double?>, unit: String = "") -> some View {
        HStack {
            Text(label)
                .frame(width: 35, alignment: .leading)
            TextField("Мин", value: min, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
            Text("—")
                .foregroundStyle(.secondary)
            TextField("Макс", value: max, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Schedule table sheet (Apple-style List with inline editing)
public struct ScheduleTableSheet: View {
    @Binding var schedule: [TempSchedulePoint]
    @Environment(\.dismiss) private var dismiss

    public init(schedule: Binding<[TempSchedulePoint]>) {
        self._schedule = schedule
    }

    public var body: some View {
        NavigationStack {
            Group {
                if schedule.isEmpty {
                    ContentUnavailableView(
                        "Нет узлов графика",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Добавьте узловые точки температурного графика")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Узлы графика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            schedule.append(TempSchedulePoint(tnv: 0, t1: 70, t2: 50))
                        } label: {
                            Label("Добавить узел", systemImage: "plus")
                        }
                        Button {
                            schedule.sort { $0.tnv < $1.tnv }
                        } label: {
                            Label("Сортировать по Тнв", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(schedule.count < 2)
                    } label: {
                        Label("Узлы", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach($schedule) { $pt in
                    HStack {
                        Text("Тнв")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .leading)
                        TextField("0", value: $pt.tnv, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                        Text("T1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .leading)
                        TextField("70", value: $pt.t1, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                        Text("T2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .leading)
                        TextField("50", value: $pt.t2, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                    }
                }
                .onDelete { schedule.remove(atOffsets: $0) }
                .onMove { schedule.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Узловые точки графика")
            } footer: {
                Text("Укажите температуру наружного воздуха и соответствующие температуры подачи (T1) и обратки (T2). Между узлами значения интерполируются.")
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            EditButton()
        }
    }
}
