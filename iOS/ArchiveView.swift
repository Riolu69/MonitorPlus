import SwiftUI

/// Архив показаний: порт BtnArchiveLoad_Click / ParseArchiveResponse.
public struct ArchiveView: View {
    @Bindable var vm: AppViewModel

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    /// Колонки таблицы — объединение ключей всех строк, не более 14.
    private var columns: [String] {
        Array(Set(vm.archiveRows.flatMap(\.sortedKeys)).sorted().prefix(14))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    statusBanner
                    if !vm.archiveRows.isEmpty { table }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Архив")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.loadArchive() }
                    } label: {
                        Label("Загрузить", systemImage: "arrow.down.circle")
                    }
                    .disabled(vm.isLoadingArchive || vm.archivePointId == nil || !vm.isConnected)
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Запрос к ЛЭРС УЧЁТ")
                .font(.headline)

            Picker("Точка учёта", selection: $vm.archivePointId) {
                Text("Не выбрана").tag(nil as Int?)
                ForEach(vm.allPoints) { pt in
                    Text(pt.displayName).tag(pt.id as Int?)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Тип архива")
                Spacer()
                Picker("Тип архива", selection: $vm.archiveKind) {
                    ForEach(ArchiveKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Text("Период")
                Spacer()
                Picker("Период", selection: $vm.archiveDays) {
                    ForEach([1, 7, 14, 30], id: \.self) { d in
                        Text("\(d) дн.").tag(d)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var statusBanner: some View {
        Group {
            if vm.isLoadingArchive {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Загрузка данных из ЛЭРС...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else if !vm.archiveStatus.isEmpty {
                Text(vm.archiveStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.self) { col in
                            Text(col)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 6)
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground))

                    ForEach(vm.archiveRows) { row in
                        Divider()
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.self) { col in
                                Text(row.cells[col] ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}
