import SwiftUI

struct ContentView: View {
    @State private var vm = AppViewModel()
    
    var body: some View {
        TabView {
            // Вкладка 1: Дашборд
            NavigationStack {
                DashboardView(vm: vm)
                    .navigationTitle("Дашборд")
            }
            .tabItem {
                Label("Дашборд", systemImage: "square.grid.2x2.fill")
            }
            
            // Вкладка 2: Подключение и сервер
            NavigationStack {
                ConnectionSettingsView(vm: vm)
                    .navigationTitle("Подключение")
            }
            .tabItem {
                Label("Сервер", systemImage: "server.rack")
            }
        }
    }
}

struct DashboardView: View {
    var vm: AppViewModel
    
    private let columns = [
        GridItem(.adaptive(minimum: 165), spacing: 12)
    ]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !vm.isConnected {
                    ContentUnavailableView("Нет подключения", 
                                           systemImage: "wifi.slash", 
                                           description: Text("Перейдите во вкладку «Сервер» для входа"))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.dashboardPoints) { point in
                            PointTileView(point: point, currentTnv: vm.currentTnv) {
                                Task { await vm.pollSingle(point: point) }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let tnv = vm.currentTnv {
                    Text(String(format: "Тнв: %.1f °C", tnv))
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: Capsule())
                }
            }
        }
    }
}

struct ConnectionSettingsView: View {
    @Bindable var vm: AppViewModel
    
    var body: some View {
        Form {
            Section("Параметры ЛЭРС УЧЁТ") {
                TextField("Хост / IP", text: $vm.host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Порт", text: $vm.port)
                    .keyboardType(.numberPad)
                TextField("Логин", text: $vm.login)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Пароль", text: $vm.pass)
            }
            
            Section {
                Button(action: { Task { await vm.connect() } }) {
                    HStack {
                        Spacer()
                        Text(vm.isConnected ? "Переподключиться" : "Войти")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            } footer: {
                Text(vm.statusText)
                    .foregroundStyle(vm.isConnected ? .green : .secondary)
            }
        }
    }
}
