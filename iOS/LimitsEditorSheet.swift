import SwiftUI

public struct LimitsEditorSheet: View {
    let pointId: Int
    let title: String
    @Bindable var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var limits: PointThresholds = PointThresholds()
    @State private var showScheduleEditor = false
    
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
                }
            }
            .navigationTitle("Границы: \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                self.limits = vm.settings.pointLimits[pointId] ?? PointThresholds()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
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

struct ScheduleTableSheet: View {
    @Binding var schedule: [TempSchedulePoint]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
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
