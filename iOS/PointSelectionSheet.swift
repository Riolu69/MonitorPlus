import SwiftUI

/// Выбор точек учёта для дашборда / общего монитора / подпитки.
/// Заменяет WPF-списки ListPoints, ListPointsDashboard, ListPodpitka.
public struct PointSelectionSheet: View {
    @Bindable var vm: AppViewModel
    let list: PointSelectionList
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var nodeFilter = "Все объекты"
    @State private var systemFilter = "Все системы"
    @State private var limitsPoint: MeasurePointItem?

    public init(vm: AppViewModel, list: PointSelectionList, title: String) {
        self.vm = vm
        self.list = list
        self.title = title
    }

    private var points: [MeasurePointItem] {
        vm.allPoints.filter { p in
            (search.isEmpty || p.displayName.localizedCaseInsensitiveContains(search)) &&
            (nodeFilter == "Все объекты" || p.nodeTitle == nodeFilter) &&
            (systemFilter == "Все системы" || p.matches(systemType: systemFilter))
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Фильтры") {
                    Picker("Объект", selection: $nodeFilter) {
                        ForEach(vm.availableNodes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Тип системы", selection: $systemFilter) {
                        ForEach(vm.systemTypes, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section {
                    ForEach(points) { pt in
                        Button {
                            vm.toggleSelection(pt.id, in: list)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: vm.isSelected(pt.id, in: list)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(vm.isSelected(pt.id, in: list) ? .blue : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pt.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(pt.nodeTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button {
                                limitsPoint = pt
                            } label: {
                                Label("Границы", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("Показано: \(points.count) · выбрано: \(vm.selectionCount(in: list))")
                } footer: {
                    Text("Смахните строку влево, чтобы задать границы значений для точки.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Поиск по точкам и объектам")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            vm.selectAll(points, in: list)
                        } label: {
                            Label("Выбрать все показанные", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            vm.clearSelection(in: list)
                        } label: {
                            Label("Сбросить выбор", systemImage: "xmark.circle")
                        }
                    } label: {
                        Label("Выбор", systemImage: "checklist")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $limitsPoint) { pt in
                if list == .podpitka {
                    PodpitkaLimitsSheet(vm: vm, pointId: pt.id, title: pt.displayName)
                } else {
                    LimitsEditorSheet(vm: vm, pointId: pt.id, title: pt.displayName)
                }
            }
        }
    }
}
