import SwiftUI

/// Общий монитор: фильтры, множественный выбор точек, опрос выбранных,
/// таблица результатов и редактор границ (порт TabAll из MainWindow.xaml).
public struct GeneralMonitorView: View {
    @Bindable var vm: AppViewModel
    @State private var targetPointForLimits: MeasurePointItem?

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
                } else if vm.allPoints.isEmpty {
                    ContentUnavailableView(
                        "Нет точек учёта",
                        systemImage: "list.bullet",
                        description: Text("После подключения точки появятся здесь")
                    )
                } else {
                    pointList
                }
            }
            .navigationTitle("Точки учёта")
            .searchable(text: $vm.searchText, prompt: "Поиск по точкам и объектам")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { selectionMenu }
                ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            }
            .sheet(item: $targetPointForLimits) { pt in
                LimitsEditorSheet(vm: vm, pointId: pt.id, title: pt.displayName)
            }
        }
    }

    // MARK: - Toolbar

    private var selectionMenu: some View {
        Menu {
            Button {
                vm.selectAll(vm.filteredPoints, in: .general)
            } label: {
                Label("Выбрать все показанные", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                vm.clearSelection(in: .general)
            } label: {
                Label("Сбросить выбор", systemImage: "xmark.circle")
            }
        } label: {
            Label("Выбрано \(vm.selectionCount(in: .general))", systemImage: "checklist")
                .font(.caption)
        }
    }

    private var actionsMenu: some View {
        HStack(spacing: 16) {
            Button {
                Task { await vm.pollSelectedPoints() }
            } label: {
                Label("Опросить", systemImage: "arrow.clockwise")
            }
            .disabled(vm.isPollingSelected || vm.filteredPoints.isEmpty)

            Menu {
                Section("Колонки данных") {
                    ForEach(["T1", "T2", "ΔT", "P1", "P2", "ΔP", "V1", "V2", "M1", "M2", "Q"], id: \.self) { col in
                        Button {
                            vm.showCols[col] = !(vm.showCols[col] ?? true)
                        } label: {
                            Label(col, systemImage: (vm.showCols[col] ?? true) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            } label: {
                Image(systemName: "tablecolumns")
            }
        }
    }

    // MARK: - List

    private var pointList: some View {
        List {
            Section("Фильтры") {
                Picker("Объект", selection: $vm.selectedNodeFilter) {
                    ForEach(vm.availableNodes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Тип системы", selection: $vm.selectedSystemFilter) {
                    ForEach(vm.systemTypes, id: \.self) { Text($0).tag($0) }
                }
            }

            if !vm.generalResults.isEmpty {
                Section("Результаты опроса (\(vm.generalResults.count))") {
                    ForEach(vm.generalResults) { row in
                        ResultRowView(row: row, columns: vm.showCols, currentTnv: vm.globalTnv)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    Task { await vm.pollSinglePoint(row) }
                                } label: {
                                    Label("Опросить", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }

            Section {
                ForEach(vm.filteredPoints) { pt in
                    Button {
                        vm.toggleSelection(pt.id, in: .general)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: vm.isSelected(pt.id, in: .general)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.isSelected(pt.id, in: .general) ? .blue : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pt.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(pt.nodeTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            targetPointForLimits = pt
                        } label: {
                            Label("Границы", systemImage: "slider.horizontal.3")
                        }
                        .tint(.indigo)
                    }
                }
            } header: {
                Text("Доступно точек: \(vm.filteredPoints.count)")
            } footer: {
                Text("Отметьте точки и нажмите «Опросить». Границы значений задаются смахиванием строки влево.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.pollSelectedPoints()
        }
    }
}

// MARK: - Строка результата (аналог GridResults)
private struct MetricCell: Identifiable {
    var id: String { name }
    let name: String
    let value: Double?
    let unit: String
}

struct ResultRowView: View {
    let row: PointResultData
    let columns: [String: Bool]
    let currentTnv: Double?

    private var visibleMetrics: [MetricCell] {
        var items: [MetricCell] = []
        func add(_ key: String, _ value: Double?, _ unit: String) {
            if columns[key] ?? true { items.append(MetricCell(name: key, value: value, unit: unit)) }
        }
        add("T1", row.t1, "°C")
        add("T2", row.t2, "°C")
        add("ΔT", row.deltaT, "°C")
        add("P1", row.p1, "атм")
        add("P2", row.p2, "атм")
        add("ΔP", row.deltaP, "атм")
        add("V1", row.v1, "м³/ч")
        add("V2", row.v2, "м³/ч")
        add("M1", row.m1, "т")
        add("M2", row.m2, "т")
        add("Q", row.q, "Гкал")
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: row.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(row.hasError ? .red : .green)
                    .font(.caption)
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if row.hasBreach(currentTnv: currentTnv) {
                    Text("Нарушение")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Text("\(row.nodeTitle) · \(row.status)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                ForEach(visibleMetrics) { cell in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cell.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(cell.value != nil ? String(format: "%.1f", cell.value!) : "—")
                                .font(.footnote.monospacedDigit())
                            Text(cell.unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.vertical, 4)
    }
}
