import SwiftUI

public struct GeneralMonitorView: View {
    @Bindable var vm: AppViewModel
    @State private var showLimitsSheet: Bool = false
    @State private var targetPointForLimits: MeasurePointItem?
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Поиск и фильтры
                VStack(spacing: 6) {
                    TextField("Поиск по точкам и объектам...", text: $vm.searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["T1", "T2", "ΔT", "P1", "P2", "ΔP", "V1", "V2", "M1", "M2", "Q"], id: \.self) { col in
                                Toggle(col, isOn: Binding(
                                    get: { vm.showCols[col] ?? true },
                                    set: { vm.showCols[col] = $0 }
                                ))
                                .toggleStyle(.button)
                                .font(.caption2)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                
                // Список точек
                List {
                    ForEach(vm.filteredPoints) { pt in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pt.nodeTitle).font(.caption).foregroundStyle(.secondary)
                                    Text(pt.title).font(.subheadline.bold())
                                }
                                Spacer()
                                Button("Границы") {
                                    targetPointForLimits = pt
                                    showLimitsSheet = true
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Точки учёта")
            .sheet(isPresented: $showLimitsSheet) {
                if let pt = targetPointForLimits {
                    LimitsEditorSheet(pointId: pt.id, title: pt.displayName, vm: vm)
                }
            }
        }
    }
}
