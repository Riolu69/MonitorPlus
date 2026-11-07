import SwiftUI

@main
struct LersMonitorApp: App {
    @State private var vm = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            TabView {
                if !vm.settings.hideDashboard {
                    DashboardView(vm: vm)
                        .tabItem { Label("Дашборд", systemImage: "square.grid.2x2.fill") }
                }
                if !vm.settings.hideGeneral {
                    GeneralMonitorView(vm: vm)
                        .tabItem { Label("Общий", systemImage: "list.bullet.rectangle") }
                }
                if !vm.settings.hidePodpitka {
                    PodpitkaView(vm: vm)
                        .tabItem { Label("Подпитка", systemImage: "drop.fill") }
                }
                SettingsView(vm: vm)
                    .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var vm: AppViewModel
    @State private var rawPassword: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Подключение к ЛЭРС") {
                    TextField("Сервер", text: $vm.settings.host)
                    TextField("Порт", value: $vm.settings.port, format: .number)
                    TextField("Логин", text: $vm.settings.login)
                    SecureField("Пароль", text: $rawPassword)
                    Button(vm.isConnected ? "Переподключиться" : "Подключиться") {
                        if !rawPassword.isEmpty {
                            vm.settings.passwordBase64 = Data(rawPassword.utf8).base64EncodedString()
                        }
                        Task { await vm.connect() }
                    }
                    .bold()
                }
                
                Section("Датчик наружного воздуха (Тнв)") {
                    Picker("Источник Тнв", selection: $vm.settings.tnvSourcePointId) {
                        Text("Не выбран").tag(nil as Int?)
                        ForEach(vm.allPoints) { pt in
                            Text(pt.displayName).tag(pt.id as Int?)
                        }
                    }
                    HStack {
                        Text("Поправка датчика:")
                        Spacer()
                        TextField("0.0", value: $vm.settings.tnvCorrection, format: .number)
                            .frame(width: 60)
                        Text("°C")
                    }
                }
                
                Section("Видимость вкладок") {
                    Toggle("Дашборд", isOn: Binding(get: { !vm.settings.hideDashboard }, set: { vm.settings.hideDashboard = !$0 }))
                    Toggle("Общий мониторинг", isOn: Binding(get: { !vm.settings.hideGeneral }, set: { vm.settings.hideGeneral = !$0 }))
                    Toggle("Подпитка", isOn: Binding(get: { !vm.settings.hidePodpitka }, set: { vm.settings.hidePodpitka = !$0 }))
                }
            }
            .navigationTitle("Настройки")
        }
    }
}
