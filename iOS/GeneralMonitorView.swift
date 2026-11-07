import SwiftUI

public struct GeneralMonitorView: View {
    @Bindable var vm: AppViewModel
    @State private var showLimitsSheet: Bool = false
    @State private var targetPointForLimits: MeasurePointItem?

    public var body: some View {
        NavigationStack {
            Group {
                if !vm.isConnected {
                    ContentUnavailableView(
                        "Нет подключения",
                        systemImage: "wifi.slash",
                        description: Text("Подключитесь к серверу ЛЭРС УЧЁТ в настройках")
                    )
                } else if vm.filteredPoints.isEmpty && vm.searchText.isEmpty {
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
                ToolbarItem(placement: .topBarTrailing) {
                    columnMenu
                }
            }
            .sheet(isPresented: $showLimitsSheet) {
                if let pt = targetPointForLimits {
                    LimitsEditorSheet(vm: vm, pointId: pt.id, title: pt.displayName)
                }
            }
        }
    }

    // MARK: - Point list
    private var pointList: some View {
        List {
            ForEach(vm.filteredPoints) { pt in
                VStack(alignment: .leading, spacing: 3) {
                    Text(pt.title)
                        .font(.body.weight(.medium))
                    Text(pt.nodeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    Button {
                        targetPointForLimits = pt
                        showLimitsSheet = true
                    } label: {
                        Label("Границы", systemImage: "slider.horizontal.3")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Column visibility menu (replaces horizontal toggle scroll)
    private var columnMenu: some View {
        Menu {
            Section("Колонки данных") {
                ForEach(["T1", "T2", "ΔT", "P1", "P2", "ΔP", "V1", "V2", "M1", "M2", "Q"], id: \.self) { col in
                    Button {
                        vm.showCols[col]?.toggle()
                    } label: {
                        Label(col, systemImage: vm.showCols[col] ?? true ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            Image(systemName: "tablecolumns")
        }
    }
}
