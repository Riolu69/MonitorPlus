import SwiftUI

/// Мониторинг тренда точки: порт BtnStartTrend_Click / BtnStopTrend_Click.
/// Непрерывный опрос прибора через /Poll/MeasurePoints/{id}/Currents,
/// чтение свежих снимков каждые 3 секунды, автоматическая остановка по времени.
public struct TrendView: View {
    @Bindable var vm: AppViewModel
    @State private var duration: Int = 3

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Точка учёта", selection: $vm.trendPointId) {
                        Text("Не выбрана").tag(nil as Int?)
                        ForEach(vm.allPoints) { pt in
                            Text(pt.displayName).tag(pt.id as Int?)
                        }
                    }
                    Picker("Длительность", selection: $duration) {
                        ForEach([1, 3, 5, 10, 15], id: \.self) { min in
                            Text("\(min) мин").tag(min)
                        }
                    }
                    .disabled(vm.isTrendRunning)
                } header: {
                    Text("Параметры мониторинга")
                } footer: {
                    Text("Прибор переводится в режим непрерывного опроса. По окончании канал освобождается автоматически.")
                }

                Section {
                    Button {
                        if vm.isTrendRunning {
                            vm.stopTrend()
                        } else if let id = vm.trendPointId {
                            vm.startTrend(pointId: id, durationMin: duration)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: vm.isTrendRunning ? "stop.fill" : "play.fill")
                            Text(vm.isTrendRunning ? "Остановить мониторинг" : "Начать мониторинг")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(vm.trendPointId == nil || !vm.isConnected)
                    .tint(vm.isTrendRunning ? .red : .blue)

                    if vm.isTrendRunning {
                        HStack {
                            Label("Идёт опрос", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(vm.trendRemainingText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !vm.statusText.isEmpty {
                        Text(vm.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if vm.trendHistory.isEmpty {
                        ContentUnavailableView(
                            "Нет данных",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Запустите мониторинг, чтобы увидеть последовательность показаний")
                        )
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(vm.trendHistory) { row in
                            TrendRowView(row: row, currentTnv: vm.globalTnv)
                        }
                    }
                } header: {
                    Text("История (\(vm.trendHistory.count))")
                }
            }
            .navigationTitle("Тренд")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Очистить") { vm.clearTrend() }
                        .disabled(vm.trendHistory.isEmpty)
                }
            }
        }
    }
}

// MARK: - Строка истории показаний
struct TrendRowView: View {
    let row: PointResultData
    let currentTnv: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: row.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(row.hasError ? .red : .green)
                    .font(.caption)
                Text(row.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if row.hasBreach(currentTnv: currentTnv) {
                    Text("Нарушение")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 14) {
                metric("T1", row.t1, "°C")
                metric("T2", row.t2, "°C")
                metric("V1", row.v1, "м³/ч")
                metric("Q", row.q, "Гкал")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value != nil ? String(format: "%.1f", value!) : "—")
                    .font(.footnote.monospacedDigit())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
