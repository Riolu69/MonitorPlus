using System.Collections.Concurrent;
using System.Net;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace LersMonitor
{
    public partial class App : Application { }

    public class DashSettings : INotifyPropertyChanged
    {
        public static DashSettings Instance { get; } = new DashSettings();
        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string prop = "") => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));

        private bool _showT = true; public bool ShowT { get => _showT; set { _showT = value; OnPropertyChanged(); } }
        private bool _showP = true; public bool ShowP { get => _showP; set { _showP = value; OnPropertyChanged(); } }
        private bool _showV = true; public bool ShowV { get => _showV; set { _showV = value; OnPropertyChanged(); } }
        private bool _showM = true; public bool ShowM { get => _showM; set { _showM = value; OnPropertyChanged(); } }
        private bool _showQ = true; public bool ShowQ { get => _showQ; set { _showQ = value; OnPropertyChanged(); } }
        private bool _showDeltaT = true; public bool ShowDeltaT { get => _showDeltaT; set { _showDeltaT = value; OnPropertyChanged(); } }
        private bool _showDeltaP = true; public bool ShowDeltaP { get => _showDeltaP; set { _showDeltaP = value; OnPropertyChanged(); } }
    }

    public partial class MainWindow : Window
    {
        private HttpClient _http = new();
        private string? _token;
        private string _baseUrl = "";
        
        public static double? CurrentGlobalTnv { get; set; }
        public static double TnvCorrection { get; set; } = 0;
        public static UserSettings? AppSettings { get; set; }

        private List<MeasurePointItem> _allPoints = new();
        private readonly ObservableCollection<PointResultViewModel> _results = new();
        private readonly ObservableCollection<PointResultViewModel> _trendHistory = new();
        private readonly ObservableCollection<DashboardNodeViewModel> _dashboardNodes = new();
        private readonly List<PointResultViewModel> _dashboardFlatPoints = new();
        private readonly ObservableCollection<PodpitkaNodeViewModel> _podpitkaNodes = new();
        
        private ObservableCollection<TempSchedulePointViewModel> _currentScheduleEdit = new();
        // true = выбор графика применяется сразу к выбранным точкам (из окна «Границы»),
        // false = график загружается в редактор и ждёт «Сохранить график».
        private bool _scheduleSourceApplyDirectly;

        private UserSettings _settings = new();
        private List<MeasurePointItem> _editingPoints = new();
        private List<MeasurePointItem> _editingPodpitkaPoints = new();
        
        private CancellationTokenSource? _generalMonitorCts;
        private CancellationTokenSource? _trendCts;
        private CancellationTokenSource? _dashboardCts;
        private CancellationTokenSource? _podCts;
        private bool _isLoaded = false;
        private int _activeTrendPointId = 0;
        
        private DispatcherTimer _themeTimer;
        private DispatcherTimer _globalTnvTimer;
        
        private PollCoordinator _coord = null!;
        private PollScheduler? _dashScheduler;
        private PollScheduler? _podpitkaScheduler;
        private PodpitkaVolumeService _volumes = null!;
        private static readonly SemaphoreSlim _uiGate = new(1);

        private static string SettingsFilePath =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LersMonitor", "settings.json");

        public MainWindow()
        {
            System.Net.ServicePointManager.DefaultConnectionLimit = 1000;
            InitializeComponent();
            try { _http.Timeout = Timeout.InfiniteTimeSpan; } catch {}
            
            GridResults.ItemsSource = _results;
            GridTrend.ItemsSource = _trendHistory;
            ItemsDashboard.ItemsSource = _dashboardNodes;
            ItemsPodpitka.ItemsSource = _podpitkaNodes;
            GridTempSchedule.ItemsSource = _currentScheduleEdit;
            
            CmbTrendDuration.ItemsSource = Enumerable.Range(1, 10).ToList();
            CmbTrendDuration.SelectedItem = 3;

            CmbDashboardInterval.ItemsSource = new List<int> { 1, 2, 3, 5, 10, 15, 20, 30, 60 };
            CmbDashboardInterval.SelectedItem = 10;
            
            CmbPodpitkaInterval.ItemsSource = PodpitkaPeriods.IntervalsMin;
            CmbPodpitkaInterval.SelectedItem = 30;

            _themeTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
            _themeTimer.Tick += ThemeTimer_Tick;
            
            _globalTnvTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
            _globalTnvTimer.Tick += async (s, e) => await UpdateGlobalTnvAsync();

            LoadUserSettings();
            _isLoaded = true;
        }
        
        private void InitPolling()
        {
            _coord = new PollCoordinator(_http, () => _baseUrl, maxDevicePolls: 6, maxHttp: 16);
            _coord.Updated += u => Dispatcher.InvokeAsync(() => ApplyUpdate(u));
            _volumes = new PodpitkaVolumeService(_http, () => _baseUrl);
        }
        
        private void ApplyUpdate(PollUpdate u)
        {
            foreach (var vm in _dashboardFlatPoints.Concat(_results).Where(v => v.Id == u.PointId))
            {
                if (u.Snapshot != null && u.State is PollState.Ok or PollState.OkCached)
                {
                    using var doc = JsonDocument.Parse(u.Snapshot.RawJson);
                    vm.DeviceTime = u.Snapshot.DeviceTime;
                    UpdatePointValues(vm, doc.RootElement);
                }
                vm.State = u.State; vm.Status = u.Message; vm.RefreshColors();
            }
            foreach (var n in _dashboardNodes) n.Refresh();
            
            foreach (var p in _podpitkaNodes.SelectMany(n => n.Points).Where(p => p.Id == u.PointId))
            { 
                p.State = u.State; p.Message = u.Message; 
            }
            foreach (var n in _podpitkaNodes) n.Refresh();
        }

        private void LoadUserSettings()
        {
            try
            {
                if (File.Exists(SettingsFilePath))
                {
                    var json = File.ReadAllText(SettingsFilePath);
                    var loaded = JsonSerializer.Deserialize<UserSettings>(json);
                    if (loaded != null)
                    {
                        _settings = loaded;
                        TxtHost.Text = string.IsNullOrWhiteSpace(_settings.Host) ? "localhost" : _settings.Host;
                        TxtPort.Text = _settings.Port == 0 ? "10000" : _settings.Port.ToString();
                        TxtLogin.Text = _settings.Login;
                        ChkRemember.IsChecked = _settings.RememberCredentials;
                        
                        TxtThemeLight.Text = _settings.TimeLightStr;
                        TxtThemeDark.Text = _settings.TimeDarkStr;
                        SldUiScale.Value = _settings.UiScale <= 0 ? 1.0 : _settings.UiScale;

                        if (!string.IsNullOrEmpty(_settings.PasswordBase64))
                        {
                            try {
                                var bytes = Convert.FromBase64String(_settings.PasswordBase64);
                                TxtPassword.Password = Encoding.UTF8.GetString(bytes);
                            } catch {}
                        }
                        
                        CmbTheme.SelectedIndex = _settings.ThemeMode;
                        
                        if (_settings.PointLimits == null) _settings.PointLimits = new Dictionary<int, PointThresholds>();
                        // Старые settings.json без поля ScheduleTolerance получают 3.0 из инициализатора;
                        // здесь отсекаем только явно некорректные значения.
                        foreach (var lim in _settings.PointLimits.Values)
                            if (lim.ScheduleTolerance < 0 || lim.ScheduleTolerance > 50)
                                lim.ScheduleTolerance = TempScheduleMath.DefaultTolerance;
                        if (_settings.PodpitkaLimits == null) _settings.PodpitkaLimits = new Dictionary<int, VolumeThresholds>();
                        if (_settings.PodpitkaPointIds == null) _settings.PodpitkaPointIds = new List<int>();

                        CmbPodpitkaInterval.SelectedItem = _settings.PodpitkaIntervalMin > 0 ? _settings.PodpitkaIntervalMin : 30;

                        TnvCorrection = _settings.TnvCorrection;
                        AppSettings = _settings;
                        if (BtnArchive != null) BtnArchive.Visibility = _settings.ExperimentalArchive ? Visibility.Visible : Visibility.Collapsed;

                        if (_settings.LastResults != null && _settings.LastResults.Any())
                        {
                            foreach (var r in _settings.LastResults)
                            {
                                if (_settings.PointLimits.TryGetValue(r.Id, out var limits)) r.Limits = limits;
                                if (r.State == PollState.Pending && !string.IsNullOrEmpty(r.Status) && r.Status.Contains("Снято"))
                                {
                                    r.State = PollState.OkCached;
                                }
                                _results.Add(r);
                                r.RefreshColors();
                            }
                        }
                    }
                }
            }
            catch { }
            
            _themeTimer.Start();
            ApplyThemeLogic();
            ApplySectionVisibility();
        }

        private void SaveUserSettings(List<int>? selectedPointIds = null)
        {
            if (!_isLoaded) return;
            try
            {
                var dir = Path.GetDirectoryName(SettingsFilePath);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    Directory.CreateDirectory(dir);

                bool remember = ChkRemember.IsChecked == true;
                _settings.RememberCredentials = remember;

                if (remember)
                {
                    _settings.Host = TxtHost.Text.Trim();
                    ushort.TryParse(TxtPort.Text.Trim(), out ushort p);
                    _settings.Port = p == 0 ? (ushort)10000 : p;
                    _settings.Login = TxtLogin.Text.Trim();
                    _settings.PasswordBase64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(TxtPassword.Password));
                }
                else
                {
                    _settings.Host = "localhost";
                    _settings.Port = 10000;
                    _settings.Login = "";
                    _settings.PasswordBase64 = "";
                }

                _settings.ThemeMode = CmbTheme.SelectedIndex;
                _settings.TimeLightStr = TxtThemeLight.Text;
                _settings.TimeDarkStr = TxtThemeDark.Text;
                _settings.UiScale = SldUiScale.Value;
                _settings.PodpitkaIntervalMin = CmbPodpitkaInterval.SelectedItem is int m ? m : 30;

                if (selectedPointIds != null) _settings.SelectedPointIds = selectedPointIds;
                _settings.LastResults = _results.ToList();

                var json = JsonSerializer.Serialize(_settings, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(SettingsFilePath, json);
            }
            catch { }
        }

        protected override void OnClosed(EventArgs e)
        {
            _generalMonitorCts?.Cancel();
            _dashboardCts?.Cancel();
            _themeTimer.Stop();
            _globalTnvTimer.Stop();
            StopNativeLersTrend();
            SaveUserSettings();
            base.OnClosed(e);
        }

        private void TabMode_Checked(object sender, RoutedEventArgs e)
        {
            if (ViewGeneral == null || ViewTrend == null || ViewDashboard == null || ViewPodpitka == null) return;
            ViewGeneral.Visibility = Visibility.Collapsed;
            ViewTrend.Visibility = Visibility.Collapsed;
            ViewDashboard.Visibility = Visibility.Collapsed;
            ViewPodpitka.Visibility = Visibility.Collapsed;
            if (TabAll.IsChecked == true) ViewGeneral.Visibility = Visibility.Visible;
            else if (TabSingle.IsChecked == true) ViewTrend.Visibility = Visibility.Visible;
            else if (TabDashboard.IsChecked == true) ViewDashboard.Visibility = Visibility.Visible;
            else if (TabPodpitka.IsChecked == true) ViewPodpitka.Visibility = Visibility.Visible;
        }

        private void CmbTheme_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!_isLoaded || PanelAutoTheme == null) return;
            PanelAutoTheme.Visibility = CmbTheme.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
            ApplyThemeLogic();
            SaveUserSettings();
        }

        private void ThemeTimer_Tick(object? sender, EventArgs e) => ApplyThemeLogic();

        private void ApplyThemeLogic()
        {
            if (CmbTheme == null) return;
            bool isDark = false;
            if (CmbTheme.SelectedIndex == 0) isDark = false;
            else if (CmbTheme.SelectedIndex == 1) isDark = true;
            else if (CmbTheme.SelectedIndex == 2)
            {
                if (TimeSpan.TryParse(TxtThemeLight.Text, out var tLight) && TimeSpan.TryParse(TxtThemeDark.Text, out var tDark))
                {
                    var now = DateTime.Now.TimeOfDay;
                    bool isLightTime = now >= tLight && now < tDark;
                    isDark = !isLightTime;
                }
            }

            ApplyThemeColors(isDark);
        }

        private void ApplyThemeColors(bool isDark)
        {
            var res = this.Resources;
            if (isDark)
            {
                res["SystemBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#000000"));
                res["CardBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1C1C1E"));
                res["CardBackgroundAlt"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2C2C2E"));
                res["BorderBrushColor"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#38383A"));
                res["BorderBrushSubtle"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2C2C2E"));
                res["LabelPrimary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FFFFFF"));
                res["LabelSecondary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#98989F"));
                res["LabelTertiary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#48484A"));
                res["InputBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2C2C2E"));
                res["HeaderBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1C1C1E"));
                res["SelectionBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0A84FF"));
                res["SelectionForeground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FFFFFF"));
                res["SegmentedBg"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1C1C1E"));
                res["SegmentedSelectedBg"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#636366"));
                res["AccentBlue"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0A84FF"));
                res["AccentBlueHover"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#409CFF"));
                res["AccentGreen"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#30D158"));
                res["AccentRed"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FF453A"));
                res["AccentOrange"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FF9F0A"));
                res["AccentGray"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#8E8E93"));
            }
            else
            {
                res["SystemBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F2F2F7"));
                res["CardBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FFFFFF"));
                res["CardBackgroundAlt"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F9F9FB"));
                res["BorderBrushColor"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E5E5EA"));
                res["BorderBrushSubtle"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F0F0F2"));
                res["LabelPrimary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1C1C1E"));
                res["LabelSecondary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#86868B"));
                res["LabelTertiary"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#C7C7CC"));
                res["InputBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F2F2F7"));
                res["HeaderBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F9F9FB"));
                res["SelectionBackground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#007AFF"));
                res["SelectionForeground"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FFFFFF"));
                res["SegmentedBg"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#EFF0F3"));
                res["SegmentedSelectedBg"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FFFFFF"));
                res["AccentBlue"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#007AFF"));
                res["AccentBlueHover"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0051D5"));
                res["AccentGreen"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#34C759"));
                res["AccentRed"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FF3B30"));
                res["AccentOrange"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#FF9500"));
                res["AccentGray"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#8E8E93"));
            }

            foreach (var r in _results) r.RefreshColors();
            foreach (var r in _trendHistory) r.RefreshColors();
            foreach (var r in _dashboardFlatPoints) r.RefreshColors();
            foreach (var node in _dashboardNodes) node.Refresh();
            foreach (var n in _podpitkaNodes) { foreach (var p in n.Points) p.RefreshColors(); n.Refresh(); }
        }

        private async void BtnConnect_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                TxtStatus.Text = "Подключение к серверу...";
                BtnConnect.IsEnabled = false;
                string host = TxtHost.Text.Trim();
                string portStr = TxtPort.Text.Trim();
                string login = TxtLogin.Text.Trim();
                string password = TxtPassword.Password;

                if (string.IsNullOrWhiteSpace(host) || !ushort.TryParse(portStr, out ushort port)) {
                    MessageBox.Show("Укажите корректный IP/хост и порт.", "Внимание", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                _baseUrl = $"http://{host}:{port}/api/v1";

                // Always use a fresh HttpClient instance on connect to prevent "This instance has already started one or more requests"
                _http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
                _http.DefaultRequestHeaders.Accept.Clear();
                _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

                var loginPayload = JsonSerializer.Serialize(new { login, password, application = "LersMonitor WPF" });
                var loginContent = new StringContent(loginPayload, Encoding.UTF8, "application/json");

                var response = await _http.PostAsync($"{_baseUrl}/Login", loginContent);
                var loginResponseJson = await response.Content.ReadAsStringAsync();

                if (!response.IsSuccessStatusCode) throw new Exception($"Код {(int)response.StatusCode}: {loginResponseJson}");

                using (var doc = JsonDocument.Parse(loginResponseJson))
                {
                    if (doc.RootElement.TryGetProperty("token", out var tokenProp)) _token = tokenProp.GetString();
                    else _token = loginResponseJson.Trim('"');
                }

                _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _token);
                SaveUserSettings();
                InitPolling();
                TxtStatus.Text = "Загрузка объектов и точек учёта...";

                var nodeTitlesById = new Dictionary<int, string>();
                try
                {
                    var nodesRes = await _http.GetAsync($"{_baseUrl}/Core/Nodes");
                    if (nodesRes.IsSuccessStatusCode)
                    {
                        var nodesJson = await nodesRes.Content.ReadAsStringAsync();
                        using var nDoc = JsonDocument.Parse(nodesJson);
                        JsonElement nodesArr = nDoc.RootElement.ValueKind == JsonValueKind.Array ? nDoc.RootElement : (nDoc.RootElement.TryGetProperty("nodes", out var nProp) ? nProp : nDoc.RootElement);
                        foreach (var node in nodesArr.EnumerateArray())
                        {
                            int id = node.TryGetProperty("id", out var idElem) ? idElem.GetInt32() : 0;
                            string title = node.TryGetProperty("title", out var titleElem) ? titleElem.GetString() ?? "" : "";
                            if (id > 0 && !string.IsNullOrEmpty(title)) nodeTitlesById[id] = title;
                        }
                    }
                }
                catch { }

                var pointsRes = await _http.GetAsync($"{_baseUrl}/Core/MeasurePoints?type=Regular&getCustomers=true");
                pointsRes.EnsureSuccessStatusCode();

                var pointsJson = await pointsRes.Content.ReadAsStringAsync();
                _allPoints = new List<MeasurePointItem>();
                
                using (var pDoc = JsonDocument.Parse(pointsJson))
                {
                    JsonElement arrayElement = pDoc.RootElement.ValueKind == JsonValueKind.Array ? pDoc.RootElement : (pDoc.RootElement.TryGetProperty("measurePoints", out var mProp) ? mProp : pDoc.RootElement);
                    foreach (var item in arrayElement.EnumerateArray())
                    {
                        int id = item.TryGetProperty("id", out var idElem) ? idElem.GetInt32() : 0;
                        string pointTitle = item.TryGetProperty("title", out var titleElem) ? titleElem.GetString() ?? "" : "Точка";
                        int nodeId = item.TryGetProperty("nodeId", out var nodeIdElem) ? nodeIdElem.GetInt32() : 0;
                        string nodeTitle = item.TryGetProperty("nodeTitle", out var nodeTitleElem) ? nodeTitleElem.GetString() ?? "" : "";

                        if (string.IsNullOrEmpty(nodeTitle) && nodeId > 0 && nodeTitlesById.ContainsKey(nodeId)) nodeTitle = nodeTitlesById[nodeId];
                        if (string.IsNullOrEmpty(nodeTitle)) nodeTitle = "Объект";

                        if (id > 0) _allPoints.Add(new MeasurePointItem { Id = id, Title = pointTitle, NodeTitle = nodeTitle });
                    }
                }

                _allPoints = _allPoints.OrderBy(p => p.NodeTitle).ThenBy(p => p.Title).ToList();
                
                var uniqueNodes = _allPoints.Select(p => p.NodeTitle).Distinct().OrderBy(n => n).ToList();
                uniqueNodes.Insert(0, "Все объекты");
                CmbNode.ItemsSource = uniqueNodes; CmbNode.SelectedIndex = 0;
                CmbNodeDashboard.ItemsSource = uniqueNodes; CmbNodeDashboard.SelectedIndex = 0;
                
                CmbSystemType.ItemsSource = new List<string> { "Все системы", "Теплоснабжение", "ГВС", "Подпитка", "ХВС" }; CmbSystemType.SelectedIndex = 0;
                CmbSystemTypeDashboard.ItemsSource = new List<string> { "Все системы", "Теплоснабжение", "ГВС", "Подпитка", "ХВС" }; CmbSystemTypeDashboard.SelectedIndex = 0;

                CmbNodePodpitka.ItemsSource = uniqueNodes; CmbNodePodpitka.SelectedIndex = 0;
                CmbSystemTypePodpitka.ItemsSource = new List<string> { "Все системы", "Теплоснабжение", "ГВС", "Подпитка", "ХВС" }; CmbSystemTypePodpitka.SelectedIndex = 0;

                CmbTrendPoint.ItemsSource = _allPoints;
                if (_allPoints.Any()) CmbTrendPoint.SelectedIndex = 0;
                
                CmbTnvSource.ItemsSource = _allPoints;
                if (_settings.TnvSourcePointId.HasValue) 
                {
                    CmbTnvSource.SelectedItem = _allPoints.FirstOrDefault(p => p.Id == _settings.TnvSourcePointId.Value);
                }
                _globalTnvTimer.Start();

                ApplyFilters(); ApplyFiltersDashboard(); ApplyFiltersPodpitka();

                if (_settings.SelectedPointIds != null && _settings.SelectedPointIds.Any())
                {
                    foreach (var p in _allPoints.Where(p => _settings.SelectedPointIds.Contains(p.Id))) ListPoints.SelectedItems.Add(p);
                }
                
                RefreshPodpitkaNodes();
                // Сразу считываем архивные данные из ЛЭРС за закрытые периоды
                _ = Task.Run(async () =>
                {
                    var pts = _podpitkaNodes.SelectMany(n => n.Points).ToList();
                    await Task.WhenAll(pts.Select(p => _volumes.RefreshAsync(p, DateTime.Now, CancellationToken.None)));
                    Dispatcher.Invoke(() => { foreach (var n in _podpitkaNodes) n.Refresh(); });
                });

                BtnStartMonitor.IsEnabled = true; BtnStartDashboard.IsEnabled = true;
                TxtStatus.Text = $"Подключено к {host}:{port}. Загружено точек: {_allPoints.Count}";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Ошибка подключения:\n\n{ex.Message}", "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
                TxtStatus.Text = "Ошибка подключения";
            }
            finally { BtnConnect.IsEnabled = true; }
        }

        private async void CmbTnvSource_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (CmbTnvSource.SelectedItem is MeasurePointItem pt)
            {
                _settings.TnvSourcePointId = pt.Id;
                SaveUserSettings();
                TxtGlobalTnv.Text = "...";
                TxtTnvCardUpdated.Text = "Ожидание данных...";
                await UpdateGlobalTnvAsync();
            }
        }
        
        private async Task UpdateGlobalTnvAsync()
        {
            if (CmbTnvSource.SelectedItem is MeasurePointItem pt && _http.DefaultRequestHeaders.Authorization != null)
            {
                try
                {
                    var res = await _http.GetAsync($"{_baseUrl}/Data/MeasurePoints/{pt.Id}/Consumption/Last");
                    if (res.IsSuccessStatusCode)
                    {
                        var json = await res.Content.ReadAsStringAsync();
                        if (!string.IsNullOrWhiteSpace(json) && json.Trim() != "null")
                        {
                            using var doc = JsonDocument.Parse(json);
                            var tnv = ExtractParameterValue(doc.RootElement, "t_out_env", "t_nv", "T_nv", "outdoorTemp", "t_outdoor", "t_env");
                            if (tnv.HasValue)
                            {
                                CurrentGlobalTnv = tnv + TnvCorrection;
                                TxtGlobalTnv.Text = CurrentGlobalTnv.Value.ToString("F1");
                                TxtTnvCardUpdated.Text = $"Обновлено в {DateTime.Now:HH:mm:ss}";
                                foreach (var p in _dashboardFlatPoints) p.RefreshColors();
                                foreach (var p in _results) p.RefreshColors();
                                foreach (var node in _dashboardNodes) node.Refresh();
                            }
                            else TxtTnvCardUpdated.Text = "Параметр Тнв не найден";
                        }
                        else TxtTnvCardUpdated.Text = "Нет данных в ответе";
                    }
                    else TxtTnvCardUpdated.Text = "Нет ответа от источника";
                }
                catch { TxtTnvCardUpdated.Text = "Нет связи с источником"; }
            }
        }

        private async void BtnNodeToggle_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button btn && btn.Tag is DashboardNodeViewModel node && _dashboardCts != null)
            {
                node.IsPaused = !node.IsPaused;
                foreach (var p in node.Points) { p.State = node.IsPaused ? PollState.Paused : PollState.Pending; p.Status = node.IsPaused ? "Опрос приостановлен" : "Ожидание..."; }
                node.Refresh();
                if (!node.IsPaused)
                    await _coord.PollManyAsync(node.Points.Select(p => new PollTarget(p.Id, node.NodeTitle)), false, _dashboardCts.Token);
            }
        }

        private async void BtnRetryPoint_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button btn && btn.Tag is PointResultViewModel vm && _dashboardCts != null)
            {
                await _coord.PollPointAsync(new PollTarget(vm.Id, vm.NodeTitle), ignoreCache: true, _dashboardCts.Token);
            }
        }

        private void BtnPollDetails_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (sender is not Button btn) return;

                int pointId = 0;
                string title = "";

                if (btn.Tag is PointResultViewModel vm)
                {
                    pointId = vm.Id;
                    title = vm.Title;
                }
                else if (btn.Tag is PodpitkaPointViewModel pvm)
                {
                    pointId = pvm.Id;
                    title = pvm.Title;
                }

                if (pointId == 0) return;

                var win = new PollDetailsWindow(pointId, title, _coord.Log)
                {
                    Owner = this
                };
                win.Show();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Не удалось открыть окно хода опроса: " + ex.Message, "Ошибка", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void BtnToggleGeneral_Click(object sender, RoutedEventArgs e)
        {
            bool isVis = PanelGeneralLeft.Visibility == Visibility.Visible;
            PanelGeneralLeft.Visibility = isVis ? Visibility.Collapsed : Visibility.Visible;
            if (BtnToggleGenPanel != null) BtnToggleGenPanel.Content = isVis ? "▶" : "◀";
        }

        private void BtnToggleDashboard_Click(object sender, RoutedEventArgs e)
        {
            bool isVis = PanelDashboardLeft.Visibility == Visibility.Visible;
            PanelDashboardLeft.Visibility = isVis ? Visibility.Collapsed : Visibility.Visible;
            if (BtnToggleDashPanel != null) BtnToggleDashPanel.Content = isVis ? "▶" : "◀";
        }

        private void ApplyFilters_Changed(object sender, RoutedEventArgs e) => ApplyFilters();

        private void ApplyFiltersDashboard_Changed(object sender, RoutedEventArgs e) => ApplyFiltersDashboard();

        private void ApplyFilters()
        {
            if (_allPoints == null || !_allPoints.Any()) return;
            string query = TxtSearch.Text.Trim().ToLower();
            string? selectedNode = CmbNode.SelectedItem as string;
            string? selectedType = CmbSystemType.SelectedItem as string;

            var filtered = _allPoints.AsEnumerable();
            if (!string.IsNullOrEmpty(query)) filtered = filtered.Where(p => p.DisplayName.ToLower().Contains(query));
            if (!string.IsNullOrEmpty(selectedNode) && selectedNode != "Все объекты") filtered = filtered.Where(p => p.NodeTitle == selectedNode);
            if (!string.IsNullOrEmpty(selectedType) && selectedType != "Все системы") filtered = filtered.Where(p => p.Title.ToLower().Contains(selectedType.ToLower()));
            ListPoints.ItemsSource = filtered.ToList();
        }

        private void ApplyFiltersDashboard()
        {
            if (_allPoints == null || !_allPoints.Any()) return;
            string query = TxtSearchDashboard.Text.Trim().ToLower();
            string? selectedNode = CmbNodeDashboard.SelectedItem as string;
            string? selectedType = CmbSystemTypeDashboard.SelectedItem as string;

            var filtered = _allPoints.AsEnumerable();
            if (!string.IsNullOrEmpty(query)) filtered = filtered.Where(p => p.DisplayName.ToLower().Contains(query));
            if (!string.IsNullOrEmpty(selectedNode) && selectedNode != "Все объекты") filtered = filtered.Where(p => p.NodeTitle == selectedNode);
            if (!string.IsNullOrEmpty(selectedType) && selectedType != "Все системы") filtered = filtered.Where(p => p.Title.ToLower().Contains(selectedType.ToLower()));
            ListPointsDashboard.ItemsSource = filtered.ToList();
        }

        private void BtnSelectAll_Click(object sender, RoutedEventArgs e) => ListPoints.SelectAll();
        private void BtnClearSelection_Click(object sender, RoutedEventArgs e) => ListPoints.UnselectAll();
        private void BtnSelectAllDashboard_Click(object sender, RoutedEventArgs e) => ListPointsDashboard.SelectAll();
        private void BtnClearSelectionDashboard_Click(object sender, RoutedEventArgs e) => ListPointsDashboard.UnselectAll();

        private void ColumnToggle_Click(object sender, RoutedEventArgs e)
        {
            if (sender is CheckBox chk && GridResults != null)
            {
                string headerPrefix = chk.Content?.ToString() + " ";
                foreach (var col in GridResults.Columns)
                {
                    if (col.Header != null && (col.Header.ToString()!.StartsWith(headerPrefix) || col.Header.ToString()!.StartsWith(chk.Content?.ToString() + " (")))
                    {
                        col.Visibility = chk.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
                        break;
                    }
                }
            }
        }

        private void DashFilter_Click(object sender, RoutedEventArgs e)
        {
            DashSettings.Instance.ShowT = ChkDashT.IsChecked == true;
            DashSettings.Instance.ShowP = ChkDashP.IsChecked == true;
            DashSettings.Instance.ShowV = ChkDashV.IsChecked == true;
            DashSettings.Instance.ShowM = ChkDashM.IsChecked == true;
            DashSettings.Instance.ShowQ = ChkDashQ.IsChecked == true;
            DashSettings.Instance.ShowDeltaT = ChkDashDeltaT.IsChecked == true;
            DashSettings.Instance.ShowDeltaP = ChkDashDeltaP.IsChecked == true;
        }

        private void BtnSettingsShared_Click(object sender, RoutedEventArgs e)
        {
            var activeList = TabDashboard.IsChecked == true ? ListPointsDashboard : ListPoints;
            var selected = activeList.SelectedItems.Cast<MeasurePointItem>().ToList();
            if (!selected.Any()) { MessageBox.Show("Выберите хотя бы одну точку для настройки границ."); return; }
            _editingPoints = selected;

            if (_editingPoints.Count == 1)
            {
                var point = _editingPoints.First();
                TxtLimitsTitle.Text = $"Границы: {point.Title}";
                TxtLimitsSubtitle.Text = point.NodeTitle;

                if (_settings.PointLimits.TryGetValue(point.Id, out var limits))
                {
                    TxtT1Min.Text = limits.T1Min?.ToString(); TxtT1Max.Text = limits.T1Max?.ToString();
                    TxtT2Min.Text = limits.T2Min?.ToString(); TxtT2Max.Text = limits.T2Max?.ToString();
                    TxtP1Min.Text = limits.P1Min?.ToString(); TxtP1Max.Text = limits.P1Max?.ToString();
                    TxtP2Min.Text = limits.P2Min?.ToString(); TxtP2Max.Text = limits.P2Max?.ToString();
                    TxtV1Min.Text = limits.V1Min?.ToString(); TxtV1Max.Text = limits.V1Max?.ToString();
                    TxtV2Min.Text = limits.V2Min?.ToString(); TxtV2Max.Text = limits.V2Max?.ToString();
                    TxtM1Min.Text = limits.M1Min?.ToString(); TxtM1Max.Text = limits.M1Max?.ToString();
                    TxtM2Min.Text = limits.M2Min?.ToString(); TxtM2Max.Text = limits.M2Max?.ToString();
                    TxtQMin.Text = limits.QMin?.ToString(); TxtQMax.Text = limits.QMax?.ToString();
                }
                else ClearLimitsFields();
            }
            else
            {
                TxtLimitsTitle.Text = $"Групповая настройка ({_editingPoints.Count} точек)";
                TxtLimitsSubtitle.Text = "Заполните только те поля, которые хотите применить";
                ClearLimitsFields();
            }
            OverlayLimits.Visibility = Visibility.Visible;
        }
        
        /// <summary>Читает поле допуска. Поддерживает и запятую, и точку; диапазон 0…50 °C.</summary>
        private bool TryGetScheduleTolerance(out double value)
        {
            value = TempScheduleMath.DefaultTolerance;
            string text = (TxtScheduleTolerance?.Text ?? "").Trim().Replace(',', '.');
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed)) return false;
            if (parsed < 0 || parsed > 50) return false;
            value = parsed;
            return true;
        }

        private double EditorTolerance()
            => TryGetScheduleTolerance(out double tol) ? tol : TempScheduleMath.DefaultTolerance;

        /// <summary>Строки графика из редактора, отсортированные по Тнв.</summary>
        private List<TempSchedulePoint> CurrentEditorSchedule()
            => _currentScheduleEdit
                .Select(x => new TempSchedulePoint { Tnv = x.Tnv, T1 = x.T1, T2 = x.T2 })
                .OrderBy(x => x.Tnv)
                .ToList();

        /// <summary>Перечитывает границы во всех VM и обновляет цвета/подсказки по графику.</summary>
        private void SyncLimitsToViews(IEnumerable<int> pointIds)
        {
            var ids = pointIds.ToHashSet();
            foreach (var vm in _results.Concat(_dashboardFlatPoints).Concat(_trendHistory))
            {
                if (!ids.Contains(vm.Id)) continue;
                _settings.PointLimits.TryGetValue(vm.Id, out var lim);
                vm.Limits = lim;
                vm.RefreshColors();
            }
            foreach (var node in _dashboardNodes) node.Refresh();
        }

        /// <summary>Записывает график и допуск в настройки указанных точек и сохраняет их.</summary>
        private void WriteScheduleToPoints(IEnumerable<MeasurePointItem> points, List<TempSchedulePoint> schedule, double tol)
        {
            var targetList = points.ToList();
            foreach (var point in targetList)
            {
                if (!_settings.PointLimits.TryGetValue(point.Id, out var limits))
                {
                    limits = new PointThresholds();
                    _settings.PointLimits[point.Id] = limits;
                }
                // Отдельная копия списка на каждую точку: правка одной не меняет остальные.
                limits.Schedule = schedule
                    .Select(s => new TempSchedulePoint { Tnv = s.Tnv, T1 = s.T1, T2 = s.T2 })
                    .ToList();
                limits.ScheduleTolerance = tol;
            }
            SyncLimitsToViews(targetList.Select(p => p.Id));
            SaveUserSettings();
        }

        // ---------- Выбор готового графика из другой точки ----------

        private void BtnPickScheduleSourceDirect_Click(object sender, RoutedEventArgs e)
        {
            if (!_editingPoints.Any())
            {
                MessageBox.Show("Сначала выберите точки для настройки границ.",
                    "Температурный график", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            OpenScheduleSourcePicker(true);
        }

        private void BtnPickScheduleSource_Click(object sender, RoutedEventArgs e)
            => OpenScheduleSourcePicker(false);

        private void OpenScheduleSourcePicker(bool applyDirectly)
        {
            var sources = new List<ScheduleSourceItem>();
            foreach (var kv in _settings.PointLimits)
            {
                if (kv.Value?.Schedule == null || kv.Value.Schedule.Count == 0) continue;
                var pt = _allPoints.FirstOrDefault(p => p.Id == kv.Key);
                double tol = kv.Value.ScheduleTolerance >= 0 && kv.Value.ScheduleTolerance <= 50
                    ? kv.Value.ScheduleTolerance
                    : TempScheduleMath.DefaultTolerance;

                sources.Add(new ScheduleSourceItem
                {
                    PointId = kv.Key,
                    DisplayName = pt?.DisplayName ?? $"Точка #{kv.Key}",
                    Description = string.Format(CultureInfo.CurrentCulture,
                        "Строк в графике: {0} · допуск ±{1:0.##} °C", kv.Value.Schedule.Count, tol),
                    Schedule = kv.Value.Schedule,
                    Tolerance = tol
                });
            }

            sources = sources.OrderBy(s => s.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
            if (sources.Count == 0)
            {
                MessageBox.Show("Пока ни у одной точки нет сохранённого температурного графика.\n\n" +
                    "Создайте его через «📈 Температурный график», после чего этот список заполнится.",
                    "Нет готовых графиков", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            _scheduleSourceApplyDirectly = applyDirectly;
            TxtScheduleSourceHint.Text = applyDirectly
                ? "График и допуск будут сразу применены к выбранным точкам и сохранены."
                : "График и допуск попадут в редактор. Нажмите «Сохранить график», чтобы применить их.";
            ListScheduleSources.ItemsSource = sources;
            ListScheduleSources.SelectedIndex = 0;
            OverlayScheduleSource.Visibility = Visibility.Visible;
        }

        private void BtnCancelScheduleSource_Click(object sender, RoutedEventArgs e)
            => OverlayScheduleSource.Visibility = Visibility.Collapsed;

        private void BtnApplyScheduleSource_Click(object sender, RoutedEventArgs e)
        {
            if (ListScheduleSources.SelectedItem is not ScheduleSourceItem src)
            {
                MessageBox.Show("Выберите точку из списка.", "Температурный график",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            if (_scheduleSourceApplyDirectly)
            {
                if (_editingPoints.Count == 0) { OverlayScheduleSource.Visibility = Visibility.Collapsed; return; }
                WriteScheduleToPoints(_editingPoints, src.Schedule, src.Tolerance);
                OverlayScheduleSource.Visibility = Visibility.Collapsed;
                MessageBox.Show(string.Format(CultureInfo.CurrentCulture,
                    "График из «{0}» применён к {1} точкам.", src.DisplayName, _editingPoints.Count),
                    "Готово", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            _currentScheduleEdit.Clear();
            foreach (var sp in src.Schedule.OrderBy(p => p.Tnv))
                _currentScheduleEdit.Add(new TempSchedulePointViewModel { Tnv = sp.Tnv, T1 = sp.T1, T2 = sp.T2 });

            // Сначала строки, затем текст: TextChanged разошлёт допуск по строкам.
            TxtScheduleTolerance.Text = src.Tolerance.ToString("0.##", CultureInfo.CurrentCulture);
            foreach (var row in _currentScheduleEdit) row.Tolerance = src.Tolerance;
            TxtScheduleSource.Text = "Источник: " + src.DisplayName;
            UpdateScheduleToleranceHint();
            OverlayScheduleSource.Visibility = Visibility.Collapsed;
        }

        private void BtnApplyScheduleToAll_Click(object sender, RoutedEventArgs e)
        {
            if (!TryGetScheduleTolerance(out double tol))
            {
                MessageBox.Show("Введите допустимое отклонение от 0 до 50 °C.",
                    "Температурный график", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            var schedule = CurrentEditorSchedule();
            if (schedule.Count == 0)
            {
                MessageBox.Show("График пуст — добавьте хотя бы одну точку.",
                    "Температурный график", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            if (_allPoints.Count == 0)
            {
                MessageBox.Show("Список точек пуст — подключитесь к ЛЭРС.",
                    "Температурный график", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var answer = MessageBox.Show(string.Format(CultureInfo.CurrentCulture,
                "Применить текущий график (строк: {0}, допуск ±{1:0.##} °C) ко ВСЕМ {2} точкам?\n\n" +
                "Существующие графики у других точек будут заменены.",
                schedule.Count, tol, _allPoints.Count),
                "Применить ко всем", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;

            WriteScheduleToPoints(_allPoints, schedule, tol);
            TxtScheduleSource.Text = string.Format(CultureInfo.CurrentCulture,
                "График применён ко всем {0} точкам.", _allPoints.Count);
        }

        private void BtnEditTempSchedule_Click(object sender, RoutedEventArgs e)
        {
            _currentScheduleEdit.Clear();
            var point = _editingPoints.FirstOrDefault();
            double tol = TempScheduleMath.DefaultTolerance;

            if (point != null && _settings.PointLimits.TryGetValue(point.Id, out var limits))
            {
                if (limits.Schedule != null)
                    foreach (var sp in limits.Schedule)
                        _currentScheduleEdit.Add(new TempSchedulePointViewModel { Tnv = sp.Tnv, T1 = sp.T1, T2 = sp.T2 });

                if (limits.ScheduleTolerance >= 0 && limits.ScheduleTolerance <= 50)
                    tol = limits.ScheduleTolerance;
            }

            // Сначала строки, потом текст: TextChanged разошлёт допуск по всем строкам.
            TxtScheduleTolerance.Text = tol.ToString("0.##", CultureInfo.CurrentCulture);
            foreach (var row in _currentScheduleEdit) row.Tolerance = tol;
            TxtScheduleSource.Text = "";
            UpdateScheduleToleranceHint();
            OverlayTempSchedule.Visibility = Visibility.Visible;
        }

        private void TxtScheduleTolerance_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (TxtScheduleToleranceHint == null) return;   // окно ещё не проинициализировано
            double tol = EditorTolerance();
            foreach (var row in _currentScheduleEdit) row.Tolerance = tol;
            UpdateScheduleToleranceHint();
        }

        private void GridTempSchedule_RowEditEnding(object sender, DataGridRowEditEndingEventArgs e)
            => UpdateScheduleToleranceHint();

        /// <summary>Показывает, какой коридор температур получается при текущем Тнв.</summary>
        private void UpdateScheduleToleranceHint()
        {
            if (TxtScheduleToleranceHint == null) return;

            double tol = EditorTolerance();
            var pts = _currentScheduleEdit
                .Select(x => new TempSchedulePoint { Tnv = x.Tnv, T1 = x.T1, T2 = x.T2 })
                .ToList();
            var exp = TempScheduleMath.Expected(CurrentGlobalTnv, pts);

            if (CurrentGlobalTnv.HasValue && exp.expT1.HasValue && exp.expT2.HasValue)
            {
                TxtScheduleToleranceHint.Text = string.Format(CultureInfo.CurrentCulture,
                    "При Тнв = {0:0.#} °C по графику допустимо: T1 {1:0.#}…{2:0.#} °C, T2 {3:0.#}…{4:0.#} °C. Выход за границы считается нарушением.",
                    CurrentGlobalTnv.Value,
                    exp.expT1.Value - tol, exp.expT1.Value + tol,
                    exp.expT2.Value - tol, exp.expT2.Value + tol);
            }
            else
            {
                TxtScheduleToleranceHint.Text = string.Format(CultureInfo.CurrentCulture,
                    "Отклонение ±{0:0.##} °C применяется к T1 и T2 всех точек графика. Диапазоны в таблице пересчитываются сразу.",
                    tol);
            }
        }

        private void BtnAddSchedulePoint_Click(object sender, RoutedEventArgs e)
        {
            _currentScheduleEdit.Add(new TempSchedulePointViewModel
            {
                Tnv = 0, T1 = 70, T2 = 50, Tolerance = EditorTolerance()
            });
        }

        private void BtnRemoveSchedulePoint_Click(object sender, RoutedEventArgs e)
        {
            if (GridTempSchedule.SelectedItem is TempSchedulePointViewModel item)
                _currentScheduleEdit.Remove(item);
        }

        private void BtnCancelSchedule_Click(object sender, RoutedEventArgs e)
        {
            OverlayTempSchedule.Visibility = Visibility.Collapsed;
        }

        private void BtnSaveSchedule_Click(object sender, RoutedEventArgs e)
        {
            if (!TryGetScheduleTolerance(out double tol))
            {
                MessageBox.Show("Введите допустимое отклонение от 0 до 50 °C (например 3 или 2,5).",
                    "Температурный график", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            WriteScheduleToPoints(_editingPoints, CurrentEditorSchedule(), tol);
            TxtScheduleSource.Text = "";
            OverlayTempSchedule.Visibility = Visibility.Collapsed;
        }

        private void ClearLimitsFields()
        {
            TxtT1Min.Text = ""; TxtT1Max.Text = ""; TxtT2Min.Text = ""; TxtT2Max.Text = "";
            TxtP1Min.Text = ""; TxtP1Max.Text = ""; TxtP2Min.Text = ""; TxtP2Max.Text = "";
            TxtV1Min.Text = ""; TxtV1Max.Text = ""; TxtV2Min.Text = ""; TxtV2Max.Text = "";
            TxtM1Min.Text = ""; TxtM1Max.Text = ""; TxtM2Min.Text = ""; TxtM2Max.Text = "";
            TxtQMin.Text = ""; TxtQMax.Text = "";
        }

        private void BtnCancelLimits_Click(object sender, RoutedEventArgs e)
        {
            OverlayLimits.Visibility = Visibility.Collapsed; _editingPoints.Clear();
        }

        private void BtnSaveLimits_Click(object sender, RoutedEventArgs e)
        {
            if (!_editingPoints.Any()) return;
            var t1Min = ParseDouble(TxtT1Min.Text); var t1Max = ParseDouble(TxtT1Max.Text);
            var t2Min = ParseDouble(TxtT2Min.Text); var t2Max = ParseDouble(TxtT2Max.Text);
            var p1Min = ParseDouble(TxtP1Min.Text); var p1Max = ParseDouble(TxtP1Max.Text);
            var p2Min = ParseDouble(TxtP2Min.Text); var p2Max = ParseDouble(TxtP2Max.Text);
            var v1Min = ParseDouble(TxtV1Min.Text); var v1Max = ParseDouble(TxtV1Max.Text);
            var v2Min = ParseDouble(TxtV2Min.Text); var v2Max = ParseDouble(TxtV2Max.Text);
            var m1Min = ParseDouble(TxtM1Min.Text); var m1Max = ParseDouble(TxtM1Max.Text);
            var m2Min = ParseDouble(TxtM2Min.Text); var m2Max = ParseDouble(TxtM2Max.Text);
            var qMin = ParseDouble(TxtQMin.Text); var qMax = ParseDouble(TxtQMax.Text);

            foreach (var point in _editingPoints)
            {
                if (!_settings.PointLimits.TryGetValue(point.Id, out var limits)) { limits = new PointThresholds(); _settings.PointLimits[point.Id] = limits; }

                if (!string.IsNullOrWhiteSpace(TxtT1Min.Text)) limits.T1Min = t1Min; if (!string.IsNullOrWhiteSpace(TxtT1Max.Text)) limits.T1Max = t1Max;
                if (!string.IsNullOrWhiteSpace(TxtT2Min.Text)) limits.T2Min = t2Min; if (!string.IsNullOrWhiteSpace(TxtT2Max.Text)) limits.T2Max = t2Max;
                if (!string.IsNullOrWhiteSpace(TxtP1Min.Text)) limits.P1Min = p1Min; if (!string.IsNullOrWhiteSpace(TxtP1Max.Text)) limits.P1Max = p1Max;
                if (!string.IsNullOrWhiteSpace(TxtP2Min.Text)) limits.P2Min = p2Min; if (!string.IsNullOrWhiteSpace(TxtP2Max.Text)) limits.P2Max = p2Max;
                if (!string.IsNullOrWhiteSpace(TxtV1Min.Text)) limits.V1Min = v1Min; if (!string.IsNullOrWhiteSpace(TxtV1Max.Text)) limits.V1Max = v1Max;
                if (!string.IsNullOrWhiteSpace(TxtV2Min.Text)) limits.V2Min = v2Min; if (!string.IsNullOrWhiteSpace(TxtV2Max.Text)) limits.V2Max = v2Max;
                if (!string.IsNullOrWhiteSpace(TxtM1Min.Text)) limits.M1Min = m1Min; if (!string.IsNullOrWhiteSpace(TxtM1Max.Text)) limits.M1Max = m1Max;
                if (!string.IsNullOrWhiteSpace(TxtM2Min.Text)) limits.M2Min = m2Min; if (!string.IsNullOrWhiteSpace(TxtM2Max.Text)) limits.M2Max = m2Max;
                if (!string.IsNullOrWhiteSpace(TxtQMin.Text)) limits.QMin = qMin; if (!string.IsNullOrWhiteSpace(TxtQMax.Text)) limits.QMax = qMax;

                var vm = _results.FirstOrDefault(r => r.Id == point.Id); if (vm != null) { vm.Limits = limits; vm.RefreshColors(); }
                var vmDash = _dashboardFlatPoints.FirstOrDefault(r => r.Id == point.Id); if (vmDash != null) { vmDash.Limits = limits; vmDash.RefreshColors(); }
            }
            
            foreach (var node in _dashboardNodes) node.Refresh();
            SaveUserSettings();
            OverlayLimits.Visibility = Visibility.Collapsed; _editingPoints.Clear();
        }

        private double? ParseDouble(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            if (double.TryParse(text.Replace(",", "."), NumberStyles.Any, CultureInfo.InvariantCulture, out double res)) return res;
            return null;
        }

        private void UpdatePointValues(PointResultViewModel vm, JsonElement root)
        {
            vm.T1 = ExtractParameterValue(root, "t_in", "t1", "temperatureIn", "T1", "t1Value", "T_in", "t_supply");
            vm.T2 = ExtractParameterValue(root, "t_out", "t2", "temperatureOut", "T2", "t2Value", "T_out", "t_return");
            vm.P1 = ExtractParameterValue(root, "p_in", "p1", "pressureIn", "P1", "p1Value", "P_in", "p_supply");
            vm.P2 = ExtractParameterValue(root, "p_out", "p2", "pressureOut", "P2", "p2Value", "P_out", "p_return");
            vm.V1 = ExtractParameterValue(root, "v_in", "v1", "volume1", "V1", "V_in", "volume_supply");
            vm.V2 = ExtractParameterValue(root, "v_out", "v2", "volume2", "V2", "V_out", "volume_return");
            vm.M1 = ExtractParameterValue(root, "m_in", "m1", "mass1", "M1", "M_in", "mass_supply");
            vm.M2 = ExtractParameterValue(root, "m_out", "m2", "mass2", "M2", "M_out", "mass_return");
            vm.Q  = ExtractParameterValue(root, "q_delta", "q", "q_in", "q_out", "q_gvs", "Q_delta", "Q", "heat", "thermalEnergy");
        }

        private async void BtnStartMonitor_Click(object sender, RoutedEventArgs e)
        {
            var selectedPoints = ListPoints.SelectedItems.Cast<MeasurePointItem>().ToList();
            if (!selectedPoints.Any()) { MessageBox.Show("Выберите точки учёта в списке слева."); return; }
            SaveUserSettings(selectedPoints.Select(p => p.Id).ToList());

            _generalMonitorCts = new CancellationTokenSource();
            var token = _generalMonitorCts.Token;
            _results.Clear();
            foreach (var p in selectedPoints)
            {
                _settings.PointLimits.TryGetValue(p.Id, out var pointLimits);
                _results.Add(new PointResultViewModel { Id = p.Id, Title = p.Title, NodeTitle = p.NodeTitle, Status = "Ожидание...", Limits = pointLimits });
            }

            try
            {
                BtnStartMonitor.IsEnabled = false; BtnCancelMonitor.Visibility = Visibility.Visible;
                TxtStatus.Text = "Фиксация времени до опроса...";
                var targets = selectedPoints.Select(p => new PollTarget(p.Id, p.NodeTitle)).ToList();
                await _coord.PollManyAsync(targets, false, token);
                if (!token.IsCancellationRequested) TxtStatus.Text = "Мониторинг завершен.";
                SaveUserSettings();
            }
            catch (OperationCanceledException) { TxtStatus.Text = "Опрос отменен."; foreach (var r in _results.Where(x => !x.Status.Contains("успешно"))) r.Status = "Отменено"; }
            catch (Exception) { MessageBox.Show("Ошибка во время опроса."); TxtStatus.Text = "Сбой операции"; }
            finally { BtnStartMonitor.IsEnabled = true; BtnCancelMonitor.Visibility = Visibility.Collapsed; }
        }

        private void BtnCancelMonitor_Click(object sender, RoutedEventArgs e)
        {
            _generalMonitorCts?.Cancel(); TxtStatus.Text = "Опрос отменен пользователем.";
        }

        private async void BtnStartTrend_Click(object sender, RoutedEventArgs e)
        {
            if (CmbTrendPoint.SelectedItem is not MeasurePointItem selectedPoint) return;
            int durationMinutes = CmbTrendDuration.SelectedItem is int min ? min : 3;
            var maxEndTime = DateTime.UtcNow.AddMinutes(durationMinutes);
            _activeTrendPointId = selectedPoint.Id;
            _trendCts = new CancellationTokenSource(); var token = _trendCts.Token;

            BtnStartTrend.Visibility = Visibility.Collapsed; BtnStopTrend.Visibility = Visibility.Visible;
            CmbTrendPoint.IsEnabled = false; CmbTrendDuration.IsEnabled = false;

            _settings.PointLimits.TryGetValue(selectedPoint.Id, out var limits);
            TxtStatus.Text = $"Запуск мониторинга для {selectedPoint.Title} (макс. {durationMinutes} мин)...";

            try
            {
                try {
                    using var pollReq = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/Poll/MeasurePoints/{selectedPoint.Id}/Currents");
                    pollReq.Content = new ByteArrayContent(Array.Empty<byte>()); pollReq.Content.Headers.ContentLength = 0;
                    using var r = await _http.SendAsync(pollReq, token);
                } catch { }

                DateTime? lastObservedTime = null;
                while (!token.IsCancellationRequested)
                {
                    if (DateTime.UtcNow >= maxEndTime) { TxtStatus.Text = $"Лимит времени ({durationMinutes} мин) исчерпан."; break; }
                    try
                    {
                        var res = await _http.GetAsync($"{_baseUrl}/Data/MeasurePoints/{selectedPoint.Id}/Consumption/Last", token);
                        if (res.IsSuccessStatusCode)
                        {
                            var json = await res.Content.ReadAsStringAsync(token);
                            if (!string.IsNullOrWhiteSpace(json) && json.Trim() != "null")
                            {
                                using var doc = JsonDocument.Parse(json); var root = doc.RootElement;
                                var timeNow = TryGetDate(root, "dateTime", "deviceTime", "date") ?? DateTime.Now;
                                if (lastObservedTime == null || timeNow > lastObservedTime)
                                {
                                    lastObservedTime = timeNow;
                                    var row = new PointResultViewModel { Id = selectedPoint.Id, Title = selectedPoint.Title, NodeTitle = selectedPoint.NodeTitle, DeviceTime = timeNow, Limits = limits, Status = "Снято" };
                                    UpdatePointValues(row, root); _trendHistory.Insert(0, row); row.RefreshColors();
                                    var remain = maxEndTime - DateTime.UtcNow;
                                    TxtStatus.Text = $"Данные: {timeNow:HH:mm:ss} (осталось {(int)remain.TotalMinutes} мин {(int)remain.Seconds} сек)";
                                }
                            }
                        }
                    }
                    catch (OperationCanceledException) { break; } catch { }
                    await Task.Delay(3000, token);
                }
            }
            catch (OperationCanceledException) { }
            finally
            {
                StopNativeLersTrend();
                BtnStartTrend.Visibility = Visibility.Visible; BtnStopTrend.Visibility = Visibility.Collapsed;
                CmbTrendPoint.IsEnabled = true; CmbTrendDuration.IsEnabled = true;
                if (!TxtStatus.Text.StartsWith("Лимит времени")) TxtStatus.Text = "Мониторинг точки остановлен.";
            }
        }

        private async void StopNativeLersTrend()
        {
            _trendCts?.Cancel();
            if (_activeTrendPointId > 0 && !string.IsNullOrEmpty(_baseUrl)) {
                try { 
                    using var stopReq = new HttpRequestMessage(HttpMethod.Delete, $"{_baseUrl}/Poll/MeasurePoints/{_activeTrendPointId}/Currents"); 
                    using var r = await _http.SendAsync(stopReq); 
                } catch { }
                _activeTrendPointId = 0;
            }
        }

        private void BtnStopTrend_Click(object sender, RoutedEventArgs e) => StopNativeLersTrend();
        private void BtnClearTrend_Click(object sender, RoutedEventArgs e) => _trendHistory.Clear();

        private void BtnStartDashboard_Click(object sender, RoutedEventArgs e)
        {
            var selectedPoints = ListPointsDashboard.SelectedItems.Cast<MeasurePointItem>().ToList();
            if (!selectedPoints.Any()) { MessageBox.Show("Выберите точки учёта для дашборда."); return; }

            int intervalMin = CmbDashboardInterval.SelectedItem is int min ? min : 10;
            _dashboardCts = new CancellationTokenSource(); var token = _dashboardCts.Token;

            BtnStartDashboard.Visibility = Visibility.Collapsed; BtnStopDashboard.Visibility = Visibility.Visible;
            BtnForcePoll.IsEnabled = true;
            CmbDashboardInterval.IsEnabled = false;

            _dashboardNodes.Clear(); _dashboardFlatPoints.Clear();

            var groups = selectedPoints.GroupBy(p => p.NodeTitle);
            foreach (var g in groups)
            {
                var nodeVm = new DashboardNodeViewModel { NodeTitle = g.Key };
                foreach (var p in g)
                {
                    _settings.PointLimits.TryGetValue(p.Id, out var pointLimits);
                    var vm = new PointResultViewModel { Id = p.Id, Title = p.Title, NodeTitle = p.NodeTitle, Status = "Ожидание автоопроса...", Limits = pointLimits };
                    vm.PropertyChanged += (s, ev) => nodeVm.Refresh();
                    nodeVm.Points.Add(vm); _dashboardFlatPoints.Add(vm);
                }
                _dashboardNodes.Add(nodeVm);
            }

            if (selectedPoints.Count == 1) { PanelSinglePoint.Visibility = Visibility.Visible; PanelMultiPoint.Visibility = Visibility.Collapsed; PanelSinglePoint.DataContext = _dashboardFlatPoints.First(); }
            else { PanelSinglePoint.Visibility = Visibility.Collapsed; PanelMultiPoint.Visibility = Visibility.Visible; }

            IReadOnlyList<PollTarget> Targets() => _dashboardNodes.Where(n => !n.IsPaused)
                .SelectMany(n => n.Points.Select(p => new PollTarget(p.Id, n.NodeTitle))).ToList();

            _dashScheduler = new PollScheduler(_coord, Targets);
            _ = _dashScheduler.RunAsync(TimeSpan.FromMinutes(intervalMin), token);
            
            var statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            statusTimer.Tick += (s, ev) => {
                if (token.IsCancellationRequested) { statusTimer.Stop(); return; }
                var remain = _dashScheduler.NextRunLocal - DateTime.Now;
                if (remain.TotalSeconds < 0) remain = TimeSpan.Zero;
                TxtStatus.Text = $"Дашборд: следующий опрос через {remain:mm\\:ss}";
            };
            statusTimer.Start();
        }

        private void BtnStopDashboard_Click(object sender, RoutedEventArgs e)
        {
            _dashboardCts?.Cancel();
            BtnStartDashboard.Visibility = Visibility.Visible; BtnStopDashboard.Visibility = Visibility.Collapsed;
            BtnForcePoll.IsEnabled = false;
            CmbDashboardInterval.IsEnabled = true; 
            TxtStatus.Text = "Автоопрос дашборда остановлен.";
        }
        
        private async void BtnForcePoll_Click(object sender, RoutedEventArgs e)
        {
            if (_dashScheduler == null || _dashboardCts == null) return;
            BtnForcePoll.IsEnabled = false;
            try { await _dashScheduler.ForceNowAsync(_dashboardCts.Token); }
            finally { BtnForcePoll.IsEnabled = true; }
        }

        // --- Вкладка Подпитка ---
        
        private void RefreshPodpitkaNodes()
        {
            _podpitkaNodes.Clear();
            var points = _allPoints.Where(p => _settings.PodpitkaPointIds.Contains(p.Id)).ToList();
            foreach (var g in points.GroupBy(p => p.NodeTitle))
            {
                var n = new PodpitkaNodeViewModel { NodeTitle = g.Key };
                foreach (var p in g)
                {
                    _settings.PodpitkaLimits.TryGetValue(p.Id, out var limits);
                    n.Points.Add(new PodpitkaPointViewModel { Id = p.Id, Title = p.Title, NodeTitle = p.NodeTitle, Limits = limits });
                }
                _podpitkaNodes.Add(n);
            }
        }
        
        private void StartPodpitkaScheduler()
        {
            _podCts?.Cancel();
            _podCts = new CancellationTokenSource();
            _podpitkaScheduler = new PollScheduler(_coord, () => _podpitkaNodes.SelectMany(n => n.Points.Select(p => new PollTarget(p.Id, n.NodeTitle))).ToList());
            
            _ = Task.Run(async () =>
            {
                using var timer = new PeriodicTimer(TimeSpan.FromMinutes(_settings.PodpitkaIntervalMin));
                _ = PodpitkaCycleAsync(false, _podCts.Token);
                try { while (await timer.WaitForNextTickAsync(_podCts.Token)) _ = PodpitkaCycleAsync(false, _podCts.Token); }
                catch (OperationCanceledException) { }
            });
        }

        private async Task PodpitkaCycleAsync(bool ignoreCache, CancellationToken ct)
        {
            var pts = _podpitkaNodes.SelectMany(n => n.Points.Select(p => (p, n))).ToList();
            var now = DateTime.Now;
            // startDay/endDay are read inside RefreshAsync from AppSettings

            // 1. Сразу читаем готовые регламентные архивы из базы ЛЭРС
            await Task.WhenAll(pts.Select(async x =>
            {
                try
                {
                    await _volumes.RefreshAsync(x.p, now, ct);
                    x.p.State = PollState.OkCached;
                    x.p.Message = "Данные из ЛЭРС загружены";
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    x.p.Message = "Ошибка архива: " + ex.Message;
                }
            }));
            Dispatcher.Invoke(() => { foreach (var n in _podpitkaNodes) n.Refresh(); });

            // 2. Опрашиваем приборы для добора свежих данных.
            //    После опроса перечитываем часовые архивы из базы (теперь с свежими данными),
            //    не перезаписывая отчётный период и "вчера".
            await Task.WhenAll(pts.Select(async x =>
            {
                try
                {
                    x.p.State = PollState.Polling;
                    var u = await _coord.PollPointAsync(new PollTarget(x.p.Id, x.n.NodeTitle), ignoreCache, ct);
                    if (u.State != PollState.Error)
                    {
                        // Перечитаем часовые данные из базы после опроса прибора
                        var afterNow = DateTime.Now;
                        var h = PodpitkaPeriods.PrevHour(afterNow);
                        var t = PodpitkaPeriods.Today(afterNow);

                        // Обновляем "прошлый час" и "сегодня" из часового архива
                        var hourVal = await _volumes.SumV1Async(x.p.Id, h.From, h.ToExclusive, true, ct, h.From, h.ToExclusive);
                        var todayVal = afterNow.Hour > 0
                            ? await _volumes.SumV1Async(x.p.Id, t.From, t.ToExclusive, true, ct, t.From, t.ToExclusive)
                            : null;

                        if (hourVal.HasValue)
                            x.p.UpdateHour(todayVal, hourVal.Value);
                        else
                        {
                            // Если часовой архив ещё не записался — берём оперативный срез
                            var instant = await _volumes.GetLastInstantVolumeAsync(x.p.Id, ct);
                            if (instant.HasValue) x.p.UpdateHour(todayVal, instant.Value);
                        }

                        x.p.State = PollState.Ok;
                        x.p.Message = "Опрошено " + DateTime.Now.ToString("HH:mm:ss");
                    }
                }
                catch { }
            }));
            Dispatcher.Invoke(() => { foreach (var n in _podpitkaNodes) n.Refresh(); });
        }

        private void BtnTogglePodpitka_Click(object sender, RoutedEventArgs e)
        {
            bool isVis = PanelPodpitkaLeft.Visibility == Visibility.Visible;
            PanelPodpitkaLeft.Visibility = isVis ? Visibility.Collapsed : Visibility.Visible;
            BtnTogglePodpPanel.Content = isVis ? "▶" : "◀";
        }

        private void BtnSelectAllPodpitka_Click(object sender, RoutedEventArgs e) => ListPodpitka.SelectAll();
        private void BtnClearSelectionPodpitka_Click(object sender, RoutedEventArgs e) => ListPodpitka.UnselectAll();

        private bool _updatingPodpitkaList = false;

        private void ListPodpitka_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!_isLoaded || _updatingPodpitkaList) return;
            _settings.PodpitkaPointIds = ListPodpitka.SelectedItems.Cast<MeasurePointItem>().Select(p => p.Id).ToList();
            SaveUserSettings();
            RefreshPodpitkaNodes();
            _ = Task.Run(async () =>
            {
                var pts = _podpitkaNodes.SelectMany(n => n.Points).ToList();
                await Task.WhenAll(pts.Select(p => _volumes.RefreshAsync(p, DateTime.Now, CancellationToken.None)));
                Dispatcher.Invoke(() =>
                {
                    foreach (var p in pts) p.State = PollState.OkCached;
                    foreach (var n in _podpitkaNodes) n.Refresh();
                });
            });
        }

        private void ApplyFiltersPodpitka_Changed(object sender, RoutedEventArgs e) => ApplyFiltersPodpitka();

        private void ApplyFiltersPodpitka()
        {
            if (_allPoints == null || !_allPoints.Any()) return;
            string q = TxtSearchPodpitka.Text.Trim().ToLower();
            string? selectedNode = CmbNodePodpitka?.SelectedItem as string;
            string? selectedType = CmbSystemTypePodpitka?.SelectedItem as string;

            var filtered = _allPoints.AsEnumerable();
            if (!string.IsNullOrEmpty(q)) filtered = filtered.Where(p => p.DisplayName.ToLower().Contains(q));
            if (!string.IsNullOrEmpty(selectedNode) && selectedNode != "Все объекты") filtered = filtered.Where(p => p.NodeTitle == selectedNode);
            if (!string.IsNullOrEmpty(selectedType) && selectedType != "Все системы") filtered = filtered.Where(p => p.Title.ToLower().Contains(selectedType.ToLower()));

            _updatingPodpitkaList = true;
            try
            {
                var list = filtered.ToList();
                ListPodpitka.ItemsSource = list;

                if (_settings.PodpitkaPointIds != null)
                {
                    foreach (var p in list.Where(p => _settings.PodpitkaPointIds.Contains(p.Id)))
                        ListPodpitka.SelectedItems.Add(p);
                }
            }
            finally
            {
                _updatingPodpitkaList = false;
            }
        }

        private void BtnStartPodpitka_Click(object sender, RoutedEventArgs e)
        {
            StartPodpitkaScheduler();
            BtnStartPodpitka.Visibility = Visibility.Collapsed;
            BtnStopPodpitka.Visibility = Visibility.Visible;
            CmbPodpitkaInterval.IsEnabled = false;
            TxtStatus.Text = "Автоопрос подпитки запущен.";
        }

        private void BtnStopPodpitka_Click(object sender, RoutedEventArgs e)
        {
            _podCts?.Cancel();
            _podCts = null;
            BtnStartPodpitka.Visibility = Visibility.Visible;
            BtnStopPodpitka.Visibility = Visibility.Collapsed;
            CmbPodpitkaInterval.IsEnabled = true;
            TxtStatus.Text = "Автоопрос подпитки остановлен.";
        }


        private void CmbPodpitkaInterval_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (CmbPodpitkaInterval.SelectedItem is int m)
            {
                _settings.PodpitkaIntervalMin = m;
                SaveUserSettings();
                StartPodpitkaScheduler();
            }
        }

        private async void BtnPodpitkaForce_Click(object sender, RoutedEventArgs e)
        {
            if (_podCts == null) StartPodpitkaScheduler();
            BtnPodpitkaForce.IsEnabled = false;
            try { await PodpitkaCycleAsync(false, _podCts!.Token); }
            finally { BtnPodpitkaForce.IsEnabled = true; }
        }

        // --- Кнопка настроек (шестерёнка) ---

        private bool _settingsGearInitialLoad = true;

        private void BtnSettingsGear_Click(object sender, RoutedEventArgs e)
        {
            _settingsGearInitialLoad = true;
            ChkExperimentalArchive.IsChecked = _settings.ExperimentalArchive;
            ChkExperimentalReportPeriod.IsChecked = _settings.ExperimentalReportPeriod;
            ChkSectionGeneral.IsChecked = !_settings.HideGeneral;
            ChkSectionTrend.IsChecked = !_settings.HideTrend;
            ChkSectionDashboard.IsChecked = !_settings.HideDashboard;
            ChkSectionPodpitka.IsChecked = !_settings.HidePodpitka;
            PanelReportPeriodSettings.Visibility = _settings.ExperimentalReportPeriod ? Visibility.Visible : Visibility.Collapsed;

            // Populate day ComboBoxes 1-31
            var days = Enumerable.Range(1, 31).Select(d => d.ToString()).ToList();
            CmbReportPeriodStartDay.ItemsSource = days;
            CmbReportPeriodEndDay.ItemsSource = days.ToList();
            CmbReportPeriodStartDay.SelectedItem = _settings.ReportPeriodStartDay.ToString();
            CmbReportPeriodEndDay.SelectedItem = _settings.ReportPeriodEndDay.ToString();

            _settingsGearInitialLoad = false;
            OverlayAppSettings.Visibility = Visibility.Visible;
        }

        private void BtnCloseAppSettings_Click(object sender, RoutedEventArgs e)
        {
            OverlayAppSettings.Visibility = Visibility.Collapsed;
        }

        private void SectionToggle_Click(object sender, RoutedEventArgs e)
        {
            if (_settingsGearInitialLoad) return;
            _settings.HideGeneral = ChkSectionGeneral.IsChecked != true;
            _settings.HideTrend = ChkSectionTrend.IsChecked != true;
            _settings.HideDashboard = ChkSectionDashboard.IsChecked != true;
            _settings.HidePodpitka = ChkSectionPodpitka.IsChecked != true;
            ApplySectionVisibility();
            SaveUserSettings();
        }

        private void ApplySectionVisibility()
        {
            TabAll.Visibility = _settings.HideGeneral ? Visibility.Collapsed : Visibility.Visible;
            TabSingle.Visibility = _settings.HideTrend ? Visibility.Collapsed : Visibility.Visible;
            TabDashboard.Visibility = _settings.HideDashboard ? Visibility.Collapsed : Visibility.Visible;
            TabPodpitka.Visibility = _settings.HidePodpitka ? Visibility.Collapsed : Visibility.Visible;
            if (TabAll.IsChecked == true && _settings.HideGeneral) SwitchToFirstVisibleTab();
            else if (TabSingle.IsChecked == true && _settings.HideTrend) SwitchToFirstVisibleTab();
            else if (TabDashboard.IsChecked == true && _settings.HideDashboard) SwitchToFirstVisibleTab();
            else if (TabPodpitka.IsChecked == true && _settings.HidePodpitka) SwitchToFirstVisibleTab();
        }

        private void SwitchToFirstVisibleTab()
        {
            if (!_settings.HideGeneral) TabAll.IsChecked = true;
            else if (!_settings.HideTrend) TabSingle.IsChecked = true;
            else if (!_settings.HideDashboard) TabDashboard.IsChecked = true;
            else if (!_settings.HidePodpitka) TabPodpitka.IsChecked = true;
        }

        private void ExperimentalToggle_Click(object sender, RoutedEventArgs e)
        {
            if (_settingsGearInitialLoad) return;
            _settings.ExperimentalArchive = ChkExperimentalArchive.IsChecked == true;
            _settings.ExperimentalReportPeriod = ChkExperimentalReportPeriod.IsChecked == true;
            PanelReportPeriodSettings.Visibility = _settings.ExperimentalReportPeriod ? Visibility.Visible : Visibility.Collapsed;
            BtnArchive.Visibility = _settings.ExperimentalArchive ? Visibility.Visible : Visibility.Collapsed;
            SaveUserSettings();
        }

        // --- Корректировка Тнв ---

        private void BtnTnvCorrection_Click(object sender, RoutedEventArgs e)
        {
            TxtTnvCorrectionValue.Text = TnvCorrection == 0 ? "0" : TnvCorrection.ToString("+0.#;-0.#;0", CultureInfo.CurrentCulture);
            UpdateTnvCorrectionPreview();
            OverlayTnvCorrection.Visibility = Visibility.Visible;
        }

        private void BtnTnvCorrectionStep_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button btn && double.TryParse(btn.Tag?.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out double step))
            {
                double current = ParseDouble(TxtTnvCorrectionValue.Text) ?? 0;
                double newVal = current + step;
                TxtTnvCorrectionValue.Text = newVal.ToString("+0.#;-0.#;0", CultureInfo.CurrentCulture);
                UpdateTnvCorrectionPreview();
            }
        }

        private void BtnTnvCorrectionReset_Click(object sender, RoutedEventArgs e)
        {
            TxtTnvCorrectionValue.Text = "0";
            UpdateTnvCorrectionPreview();
        }

        private void UpdateTnvCorrectionPreview()
        {
            double correction = ParseDouble(TxtTnvCorrectionValue.Text) ?? 0;
            double? rawTnv = CurrentGlobalTnv - TnvCorrection;
            if (rawTnv.HasValue)
            {
                double corrected = rawTnv.Value + correction;
                TxtTnvRawValue.Text = $"{rawTnv.Value:F1} °C";
                TxtTnvCorrectedPreview.Text = $"С поправкой: {corrected:F1} °C";
            }
            else
            {
                TxtTnvRawValue.Text = "—";
                TxtTnvCorrectedPreview.Text = "";
            }
        }

        private void BtnApplyTnvCorrection_Click(object sender, RoutedEventArgs e)
        {
            double correction = ParseDouble(TxtTnvCorrectionValue.Text) ?? 0;
            TnvCorrection = correction;
            _settings.TnvCorrection = correction;
            SaveUserSettings();
            _ = UpdateGlobalTnvAsync();
            OverlayTnvCorrection.Visibility = Visibility.Collapsed;
        }

        private void BtnCancelTnvCorrection_Click(object sender, RoutedEventArgs e)
        {
            OverlayTnvCorrection.Visibility = Visibility.Collapsed;
        }

        // --- Архив показаний ---

        private void BtnArchive_Click(object sender, RoutedEventArgs e)
        {
            if (_allPoints == null || !_allPoints.Any())
            {
                MessageBox.Show("Сначала подключитесь к ЛЭРС.", "Архив", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            CmbArchivePoint.ItemsSource = _allPoints;
            if (CmbArchivePoint.SelectedIndex < 0 && _allPoints.Any()) CmbArchivePoint.SelectedIndex = 0;
            CmbArchiveKind.SelectedIndex = 1; // Часовые по умолчанию
            DpArchiveFrom.SelectedDate = DateTime.Now.AddDays(-7);
            DpArchiveTo.SelectedDate = DateTime.Now;
            CmbArchiveDays.SelectedIndex = 1;
            RbArchivePreset.IsChecked = true;
            GridArchive.ItemsSource = null;
            TxtArchiveStatus.Text = "";
            OverlayArchive.Visibility = Visibility.Visible;
        }

        private void BtnCloseArchive_Click(object sender, RoutedEventArgs e)
        {
            OverlayArchive.Visibility = Visibility.Collapsed;
        }

        private void RbArchiveMode_Changed(object sender, RoutedEventArgs e)
        {
            if (CmbArchiveDays == null) return;
            bool isPreset = RbArchivePreset.IsChecked == true;
            CmbArchiveDays.IsEnabled = isPreset;
            DpArchiveFrom.IsEnabled = !isPreset;
            DpArchiveTo.IsEnabled = !isPreset;
        }

        private async void BtnArchiveLoad_Click(object sender, RoutedEventArgs e)
        {
            if (CmbArchivePoint.SelectedItem is not MeasurePointItem pt)
            {
                TxtArchiveStatus.Text = "Выберите точку учёта.";
                return;
            }
            int kindIndex = Math.Max(0, CmbArchiveKind.SelectedIndex);
            TxtArchiveStatus.Text = "Загрузка данных из ЛЭРС...";
            GridArchive.ItemsSource = null;

            try
            {
                DateTime now = DateTime.Now;
                DateTime from, to;

                if (RbArchivePreset.IsChecked == true)
                {
                    int days = CmbArchiveDays.SelectedIndex switch
                    {
                        0 => 1, 1 => 7, 2 => 14, 3 => 30, _ => 7
                    };
                    from = now.AddDays(-days);
                    to = now;
                }
                else
                {
                    from = DpArchiveFrom.SelectedDate ?? now.AddDays(-7);
                    to = DpArchiveTo.SelectedDate ?? now;
                    if (to < from) (from, to) = (to, from);
                    to = to.Date.AddDays(1); // include the selected "to" day
                }

                // Тип данных ЛЭРС и соответствующий массив в ответе
                string kindParam = kindIndex switch
                {
                    0 => "Current", 1 => "Hour", 2 => "Day", 3 => "Month", _ => "Day"
                };
                string kindRu = kindIndex switch
                {
                    0 => "текущие", 1 => "часовые", 2 => "суточные", 3 => "месячные", _ => "суточные"
                };

                string fromDate = from.ToString("yyyy-MM-dd");
                string toDate = to.ToString("yyyy-MM-dd");

                // Основной документированный формат ЛЭРС: путь с датами.
                // Сервер сам выбирает набор доступных архивов и возвращает их в отдельных массивах.
                string url = $"{_baseUrl}/Data/MeasurePoints/{pt.Id}/Consumption/{fromDate}/{toDate}";

                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                using var res = await _http.SendAsync(req);

                if (!res.IsSuccessStatusCode)
                {
                    var statusCode = res.StatusCode.ToString();
                    TxtArchiveStatus.Text = $"Нет данных. Код: {statusCode}. Возможно, для этой точки нет архива за период {fromDate} – {toDate}.";
                    return;
                }

                var json = await res.Content.ReadAsStringAsync();
                if (string.IsNullOrWhiteSpace(json) || json.Trim() == "null")
                {
                    TxtArchiveStatus.Text = $"Сервер вернул пустой ответ за период {fromDate} – {toDate}.";
                    return;
                }

                var parsed = ParseArchiveResponse(json, kindParam);
                var rows = parsed.Rows;

                if (rows.Count == 0)
                {
                    // Ничего не нашлось — сообщаем, какие именно архивы есть в ответе
                    var avail = parsed.AvailableKinds.Count > 0
                        ? "В ответе ЛЭРС есть: " + string.Join(", ", parsed.AvailableKinds.Select(k => k.ToLowerInvariant()))
                        : "Ответ ЛЭРС не содержит архивов";
                    TxtArchiveStatus.Text =
                        $"{kindRu.capitalize()} показаний за период {fromDate} – {toDate} на сервере нет. {avail}.";
                    return;
                }

                GridArchive.AutoGenerateColumns = true;
                GridArchive.ItemsSource = rows;
                TxtArchiveStatus.Text =
                    $"Загружено записей: {rows.Count} ({kindRu}, период {fromDate} – {toDate})";
            }
            catch (Exception ex)
            {
                TxtArchiveStatus.Text = "Ошибка: " + ex.Message;
            }
        }

        /// <summary>Результат разбора ответа ЛЭРС: строки + список реально доступных типов архивов.</summary>
        private sealed class ArchiveParseResult
        {
            public List<Dictionary<string, string>> Rows { get; } = new();
            public List<string> AvailableKinds { get; } = new();
        }

        /// <summary>Парсит ответ ЛЭРС для архива показаний.
        ///
        /// Формат ответа ЛЭРС:
        /// {
        ///   "monthConsumption":   [ ... ],
        ///   "dayConsumption":     [ { dateTime, values:[ {dataParameter, value}, ... ] } ],
        ///   "hourConsumption":    [ ... ],
        ///   "currentConsumption": [ ... ],
        ///   "dataParametersUnit": [ {dataParameterCategory, unit} ]   ← метаданные, НЕ данные
        /// }
        ///
        /// Массив выбирается строго по запрошенному типу (Current/Hour/Day/Month),
        /// чтобы метаданные и чужие архивы не попадали в таблицу.
        /// Поддерживается также legacy-формат .NET Hashtable ({Comparer, Count, Keys, Values}).
        /// </summary>
        private static ArchiveParseResult ParseArchiveResponse(string json, string kind)
        {
            var result = new ArchiveParseResult();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (root.ValueKind != JsonValueKind.Object && root.ValueKind != JsonValueKind.Array)
                return result;

            // --- Legacy-формат .NET Hashtable: {"Comparer":..,"Count":N,"Keys":[..],"Values":[..]} ---
            if (root.ValueKind == JsonValueKind.Object &&
                root.TryGetProperty("Keys", out var htKeys) && htKeys.ValueKind == JsonValueKind.Array &&
                root.TryGetProperty("Values", out var htValues) && htValues.ValueKind == JsonValueKind.Array)
            {
                var keyArr = htKeys.EnumerateArray().ToList();
                var valArr = htValues.EnumerateArray().ToList();
                for (int i = 0; i < valArr.Count; i++)
                {
                    var val = valArr[i];
                    if (val.ValueKind == JsonValueKind.Object)
                    {
                        var row = FlattenRecord(val);
                        if (row.Count > 0) result.Rows.Add(row);
                    }
                    else if (i < keyArr.Count && keyArr[i].ValueKind == JsonValueKind.String)
                    {
                        result.Rows.Add(new Dictionary<string, string> { [keyArr[i].GetString() ?? "value"] = ScalarToString(val) });
                    }
                }
                if (result.Rows.Count > 0) result.AvailableKinds.Add(kind);
                return result;
            }

            // --- Стандартный формат: выбираем массив по типу ---
            string[] kindArrayNames = kind switch
            {
                "Current" => new[] { "currentConsumption", "currentConsumptions" },
                "Hour" => new[] { "hourConsumption", "hourConsumptions" },
                "Month" => new[] { "monthConsumption", "monthConsumptions" },
                _ => new[] { "dayConsumption", "dayConsumptions" }
            };

            // Список всех массивов-архивов, которые реально присутствуют в ответе (для диагностики)
            foreach (var prop in root.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.Array &&
                    prop.Name.EndsWith("Consumption", StringComparison.OrdinalIgnoreCase) &&
                    prop.Value.GetArrayLength() > 0)
                    result.AvailableKinds.Add(prop.Name);
            }

            JsonElement? selected = null;

            // 1) Прямое совпадение по имени массива нужного типа
            foreach (var name in kindArrayNames)
            {
                if (root.TryGetProperty(name, out var direct) && direct.ValueKind == JsonValueKind.Array)
                {
                    selected = direct;
                    break;
                }
            }

            // 2) Фолбэк: если нужный массив пуст — берём любой непустой массив-архив,
            //    исключая dataParametersUnit (это метаданные единиц, а не показания)
            if (selected is null || selected.Value.GetArrayLength() == 0)
            {
                foreach (var prop in root.EnumerateObject())
                {
                    if (prop.Value.ValueKind != JsonValueKind.Array) continue;
                    if (prop.Value.GetArrayLength() == 0) continue;
                    if (prop.Name.Equals("dataParametersUnit", StringComparison.OrdinalIgnoreCase)) continue;
                    if (!prop.Name.EndsWith("Consumption", StringComparison.OrdinalIgnoreCase)) continue;
                    selected = prop.Value;
                    break;
                }
            }

            // 3) Фолбэк: корневой массив
            if (selected is null && root.ValueKind == JsonValueKind.Array)
                selected = root;

            if (selected is null) return result;

            foreach (var record in selected.Value.EnumerateArray())
            {
                if (record.ValueKind != JsonValueKind.Object) continue;
                var row = FlattenRecord(record);
                if (row.Count > 0) result.Rows.Add(row);
            }

            return result;
        }

        /// <summary>Разворачивает одну запись архива в плоскую строку:
        /// прямые поля + вложенный массив values [{dataParameter, value}].</summary>
        private static Dictionary<string, string> FlattenRecord(JsonElement record)
        {
            var row = new Dictionary<string, string>();

            foreach (var prop in record.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.Array)
                {
                    // Массив параметров [{ dataParameter: "T_in", value: 72.8 }]
                    foreach (var item in prop.Value.EnumerateArray())
                    {
                        if (item.ValueKind != JsonValueKind.Object) continue;

                        string? paramName = null;
                        if (item.TryGetProperty("dataParameter", out var dp)) paramName = dp.GetString();
                        else if (item.TryGetProperty("parameter", out var p2)) paramName = p2.GetString();
                        else if (item.TryGetProperty("name", out var n2)) paramName = n2.GetString();

                        string? valStr = null;
                        if (item.TryGetProperty("value", out var v)) valStr = ScalarToString(v);
                        else if (item.TryGetProperty("val", out v)) valStr = ScalarToString(v);

                        if (!string.IsNullOrEmpty(paramName) && valStr != null)
                            row[paramName] = valStr;
                    }
                }
                else
                {
                    row[prop.Name] = ScalarToString(prop.Value);
                }
            }

            return row;
        }

        private static string ScalarToString(JsonElement e) => e.ValueKind switch
        {
            JsonValueKind.Number => e.GetRawText(),
            JsonValueKind.String => e.GetString() ?? "",
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            JsonValueKind.Null => "",
            JsonValueKind.Undefined => "",
            _ => e.GetRawText()
        };

        // --- Отчётный период (экспериментальный) ---

        private void CmbReportPeriodStartDay_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_settingsGearInitialLoad || CmbReportPeriodStartDay?.SelectedItem == null) return;
            if (int.TryParse(CmbReportPeriodStartDay.SelectedItem.ToString(), out int day))
            {
                _settings.ReportPeriodStartDay = day;
                SaveUserSettings();
            }
        }

        private void CmbReportPeriodEndDay_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_settingsGearInitialLoad || CmbReportPeriodEndDay?.SelectedItem == null) return;
            if (int.TryParse(CmbReportPeriodEndDay.SelectedItem.ToString(), out int day))
            {
                _settings.ReportPeriodEndDay = day;
                SaveUserSettings();
            }
        }

        // --- Экспорт / импорт настроек ---

        private void BtnExportSettings_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "Файл настроек LersMonitor (*.lers.json)|*.lers.json|Все файлы (*.*)|*.*",
                FileName = "LersMonitor_Settings.lers.json",
                Title = "Экспорт настроек"
            };
            if (dlg.ShowDialog() != true) return;

            try
            {
                // Создаём копию настроек без учётных данных
                var exportObj = new UserSettings
                {
                    Host = _settings.Host,
                    Port = _settings.Port,
                    // НЕ копируем Login, PasswordBase64, RememberCredentials
                    ThemeMode = _settings.ThemeMode,
                    TimeLightStr = _settings.TimeLightStr,
                    TimeDarkStr = _settings.TimeDarkStr,
                    UiScale = _settings.UiScale,
                    SelectedPointIds = _settings.SelectedPointIds,
                    TnvSourcePointId = _settings.TnvSourcePointId,
                    PointLimits = _settings.PointLimits,
                    LastResults = _settings.LastResults,
                    PodpitkaPointIds = _settings.PodpitkaPointIds,
                    PodpitkaIntervalMin = _settings.PodpitkaIntervalMin,
                    PodpitkaLimits = _settings.PodpitkaLimits,
                    TnvCorrection = _settings.TnvCorrection,
                    HideGeneral = _settings.HideGeneral,
                    HideTrend = _settings.HideTrend,
                    HideDashboard = _settings.HideDashboard,
                    HidePodpitka = _settings.HidePodpitka,
                    ExperimentalArchive = _settings.ExperimentalArchive,
                    ExperimentalReportPeriod = _settings.ExperimentalReportPeriod,
                    ReportPeriodStartDay = _settings.ReportPeriodStartDay,
                    ReportPeriodEndDay = _settings.ReportPeriodEndDay
                };

                var opts = new JsonSerializerOptions { WriteIndented = true };
                var json = JsonSerializer.Serialize(exportObj, opts);
                File.WriteAllText(dlg.FileName, json);
                MessageBox.Show($"Настройки успешно сохранены в файл:\n{dlg.FileName}\n\nЛогин, пароль, сервер и порт НЕ включены в экспорт.",
                    "Экспорт настроек", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Ошибка при экспорте настроек:\n" + ex.Message,
                    "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void BtnImportSettings_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Filter = "Файл настроек LersMonitor (*.lers.json)|*.lers.json|Все файлы (*.*)|*.*",
                Title = "Импорт настроек"
            };
            if (dlg.ShowDialog() != true) return;

            try
            {
                var json = File.ReadAllText(dlg.FileName);
                var imported = JsonSerializer.Deserialize<UserSettings>(json);
                if (imported == null)
                {
                    MessageBox.Show("Не удалось прочитать файл настроек.", "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }

                // Сохраняем текущие учётные данные
                var savedHost = _settings.Host;
                var savedPort = _settings.Port;
                var savedLogin = _settings.Login;
                var savedPassword = _settings.PasswordBase64;
                var savedRemember = _settings.RememberCredentials;

                // Применяем импортированные настройки
                _settings.ThemeMode = imported.ThemeMode;
                _settings.TimeLightStr = imported.TimeLightStr;
                _settings.TimeDarkStr = imported.TimeDarkStr;
                _settings.UiScale = imported.UiScale;
                _settings.SelectedPointIds = imported.SelectedPointIds ?? new();
                _settings.TnvSourcePointId = imported.TnvSourcePointId;
                _settings.PointLimits = imported.PointLimits ?? new();
                _settings.LastResults = imported.LastResults ?? new();
                _settings.PodpitkaPointIds = imported.PodpitkaPointIds ?? new();
                _settings.PodpitkaIntervalMin = imported.PodpitkaIntervalMin;
                _settings.PodpitkaLimits = imported.PodpitkaLimits ?? new();
                _settings.TnvCorrection = imported.TnvCorrection;
                _settings.HideGeneral = imported.HideGeneral;
                _settings.HideTrend = imported.HideTrend;
                _settings.HideDashboard = imported.HideDashboard;
                _settings.HidePodpitka = imported.HidePodpitka;
                _settings.ExperimentalArchive = imported.ExperimentalArchive;
                _settings.ExperimentalReportPeriod = imported.ExperimentalReportPeriod;
                _settings.ReportPeriodStartDay = imported.ReportPeriodStartDay;
                _settings.ReportPeriodEndDay = imported.ReportPeriodEndDay;

                // Восстанавливаем учётные данные
                _settings.Host = savedHost;
                _settings.Port = savedPort;
                _settings.Login = savedLogin;
                _settings.PasswordBase64 = savedPassword;
                _settings.RememberCredentials = savedRemember;

                SaveUserSettings();
                MessageBox.Show($"Настройки успешно импортированы из файла:\n{dlg.FileName}\n\nУчётные данные (логин, пароль, сервер, порт) сохранены текущими.",
                    "Импорт настроек", MessageBoxButton.OK, MessageBoxImage.Information);

                // Применяем видимость разделов и тему
                ApplySectionVisibility();
                OverlayAppSettings.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                MessageBox.Show("Ошибка при импорте настроек:\n" + ex.Message,
                    "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async void BtnPodpitkaRetry_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button btn && btn.Tag is PodpitkaPointViewModel vm)
            {
                if (_podCts == null) StartPodpitkaScheduler();
                vm.State = PollState.Queued;
                var u = await _coord.PollPointAsync(new PollTarget(vm.Id, vm.NodeTitle), true, _podCts!.Token);
                if (u.State != PollState.Error)
                    try { await _volumes.RefreshAsync(vm, DateTime.Now, _podCts.Token); }
                    catch (Exception ex) when (ex is not OperationCanceledException) { vm.State = PollState.Error; vm.Message = "Ошибка: " + ex.Message; }
                foreach (var n in _podpitkaNodes) n.Refresh();
            }
        }

        private void BtnPodpitkaLimits_Click(object sender, RoutedEventArgs e)
        {
            var selected = _podpitkaNodes.SelectMany(n => n.Points).ToList();
            if (!selected.Any()) { MessageBox.Show("Нет точек подпитки."); return; }
            _editingPodpitkaPoints = _allPoints.Where(p => _settings.PodpitkaPointIds.Contains(p.Id)).ToList();

            if (_editingPodpitkaPoints.Count == 1)
            {
                var point = _editingPodpitkaPoints.First();
                TxtPodpitkaLimitsTitle.Text = $"Допуски подпитки: {point.Title}";
                TxtPodpitkaLimitsSubtitle.Text = point.NodeTitle;

                if (_settings.PodpitkaLimits.TryGetValue(point.Id, out var limits))
                {
                    TxtPodpReportMin.Text = limits.ReportMin?.ToString(); TxtPodpReportMax.Text = limits.ReportMax?.ToString();
                    TxtPodpDayMin.Text = limits.DayMin?.ToString();       TxtPodpDayMax.Text = limits.DayMax?.ToString();
                    TxtPodpTodayMin.Text = limits.TodayMin?.ToString();   TxtPodpTodayMax.Text = limits.TodayMax?.ToString();
                    TxtPodpHourMin.Text = limits.HourMin?.ToString();     TxtPodpHourMax.Text = limits.HourMax?.ToString();
                }
                else ClearPodpitkaLimitsFields();
            }
            else
            {
                TxtPodpitkaLimitsTitle.Text = $"Групповая настройка подпитки ({_editingPodpitkaPoints.Count} точек)";
                TxtPodpitkaLimitsSubtitle.Text = "Заполните только те поля, которые хотите применить";
                ClearPodpitkaLimitsFields();
            }
            OverlayPodpitkaLimits.Visibility = Visibility.Visible;
        }

        private void ClearPodpitkaLimitsFields()
        {
            TxtPodpReportMin.Text = ""; TxtPodpReportMax.Text = ""; TxtPodpDayMin.Text = ""; TxtPodpDayMax.Text = "";
            TxtPodpTodayMin.Text = ""; TxtPodpTodayMax.Text = ""; TxtPodpHourMin.Text = ""; TxtPodpHourMax.Text = "";
        }

        private void BtnCancelPodpitkaLimits_Click(object sender, RoutedEventArgs e) => OverlayPodpitkaLimits.Visibility = Visibility.Collapsed;

        private void BtnSavePodpitkaLimits_Click(object sender, RoutedEventArgs e)
        {
            if (!_editingPodpitkaPoints.Any()) return;
            var rMin = ParseDouble(TxtPodpReportMin.Text); var rMax = ParseDouble(TxtPodpReportMax.Text);
            var dMin = ParseDouble(TxtPodpDayMin.Text);    var dMax = ParseDouble(TxtPodpDayMax.Text);
            var tMin = ParseDouble(TxtPodpTodayMin.Text);  var tMax = ParseDouble(TxtPodpTodayMax.Text);
            var hMin = ParseDouble(TxtPodpHourMin.Text);   var hMax = ParseDouble(TxtPodpHourMax.Text);

            foreach (var point in _editingPodpitkaPoints)
            {
                if (!_settings.PodpitkaLimits.TryGetValue(point.Id, out var limits)) { limits = new VolumeThresholds(); _settings.PodpitkaLimits[point.Id] = limits; }
                if (!string.IsNullOrWhiteSpace(TxtPodpReportMin.Text)) limits.ReportMin = rMin; if (!string.IsNullOrWhiteSpace(TxtPodpReportMax.Text)) limits.ReportMax = rMax;
                if (!string.IsNullOrWhiteSpace(TxtPodpDayMin.Text))    limits.DayMin = dMin;    if (!string.IsNullOrWhiteSpace(TxtPodpDayMax.Text))    limits.DayMax = dMax;
                if (!string.IsNullOrWhiteSpace(TxtPodpTodayMin.Text))  limits.TodayMin = tMin;  if (!string.IsNullOrWhiteSpace(TxtPodpTodayMax.Text))  limits.TodayMax = tMax;
                if (!string.IsNullOrWhiteSpace(TxtPodpHourMin.Text))   limits.HourMin = hMin;   if (!string.IsNullOrWhiteSpace(TxtPodpHourMax.Text))   limits.HourMax = hMax;

                var vm = _podpitkaNodes.SelectMany(n => n.Points).FirstOrDefault(p => p.Id == point.Id);
                if (vm != null) { vm.Limits = limits; vm.RefreshColors(); }
            }
            foreach (var n in _podpitkaNodes) n.Refresh();
            SaveUserSettings();
            OverlayPodpitkaLimits.Visibility = Visibility.Collapsed;
        }

        private static double? ExtractParameterValue(JsonElement root, params string[] targetNames)
        {
            foreach (var name in targetNames)
            {
                if (root.TryGetProperty(name, out var prop))
                {
                    if (prop.ValueKind == JsonValueKind.Number && prop.TryGetDouble(out double val)) return val;
                    if (prop.ValueKind == JsonValueKind.String && double.TryParse(prop.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out double sVal)) return sVal;
                }
            }
            if (root.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in root.EnumerateObject())
                {
                    if (prop.Value.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in prop.Value.EnumerateArray())
                        {
                            if (item.ValueKind == JsonValueKind.Object)
                            {
                                string typeName = "";
                                if (item.TryGetProperty("dataParameter", out var dpProp)) typeName = dpProp.ToString();
                                if (string.IsNullOrEmpty(typeName) && item.TryGetProperty("parameter", out var pProp)) typeName = pProp.ToString();
                                if (string.IsNullOrEmpty(typeName) && item.TryGetProperty("name", out var nProp)) typeName = nProp.ToString();
                                
                                bool matchesName = targetNames.Any(tn => typeName.Equals(tn, StringComparison.OrdinalIgnoreCase));
                                if (matchesName && (item.TryGetProperty("value", out var valProp) || item.TryGetProperty("val", out valProp)))
                                {
                                    if (valProp.ValueKind == JsonValueKind.Number && valProp.TryGetDouble(out double v)) return v;
                                    if (valProp.ValueKind == JsonValueKind.String && double.TryParse(valProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out double sv)) return sv;
                                }
                            }
                        }
                    }
                }
            }
            return null;
        }

        private static DateTime? TryGetDate(JsonElement elem, params string[] names)
        {
            foreach (var n in names)
            {
                if (elem.TryGetProperty(n, out var prop))
                {
                    if (prop.TryGetDateTime(out var dt)) return dt;
                    if (prop.ValueKind == JsonValueKind.String && DateTime.TryParse(prop.GetString(), out var sDt)) return sDt;
                }
            }
            return null;
        }
    }

    public class TempSchedulePoint
    {
        public double Tnv { get; set; }
        public double T1 { get; set; }
        public double T2 { get; set; }
    }

    /// <summary>Общая математика температурного графика: интерполяция T1/T2 по Тнв.</summary>
    public static class TempScheduleMath
    {
        /// <summary>Допуск по умолчанию для настроек, сохранённых до появления этого поля.</summary>
        public const double DefaultTolerance = 3.0;

        /// <summary>Ожидаемые по графику T1/T2 для заданной температуры наружного воздуха.</summary>
        public static (double? expT1, double? expT2) Expected(double? tnv, IEnumerable<TempSchedulePoint>? schedule)
        {
            if (!tnv.HasValue || schedule == null) return (null, null);
            try
            {
                var points = schedule.OrderBy(p => p.Tnv).ToList();
                if (points.Count == 0) return (null, null);

                var exact = points.FirstOrDefault(p => Math.Abs(p.Tnv - tnv.Value) < 0.2);
                if (exact != null) return (exact.T1, exact.T2);

                var first = points[0];
                var last = points[points.Count - 1];
                if (tnv.Value <= first.Tnv) return (first.T1, first.T2);
                if (tnv.Value >= last.Tnv) return (last.T1, last.T2);

                for (int i = 0; i < points.Count - 1; i++)
                {
                    if (tnv.Value >= points[i].Tnv && tnv.Value <= points[i + 1].Tnv)
                    {
                        double x1 = points[i].Tnv, y1 = points[i].T1, z1 = points[i].T2;
                        double x2 = points[i + 1].Tnv, y2 = points[i + 1].T1, z2 = points[i + 1].T2;
                        if (Math.Abs(x2 - x1) < 0.001) return (y1, z1);
                        double ratio = (tnv.Value - x1) / (x2 - x1);
                        return (y1 + ratio * (y2 - y1), z1 + ratio * (z2 - z1));
                    }
                }
            }
            catch { }
            return (null, null);
        }
    }

    public class TempSchedulePointViewModel : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string prop = "") => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));

        private double _tnv;
        public double Tnv { get => _tnv; set { _tnv = value; OnPropertyChanged(); } }

        private double _t1;
        public double T1 { get => _t1; set { _t1 = value; OnPropertyChanged(); OnPropertyChanged(nameof(T1Band)); } }

        private double _t2;
        public double T2 { get => _t2; set { _t2 = value; OnPropertyChanged(); OnPropertyChanged(nameof(T2Band)); } }

        /// <summary>Допустимое отклонение (±°C), общее для всех точек графика.</summary>
        private double _tolerance = TempScheduleMath.DefaultTolerance;
        [JsonIgnore]
        public double Tolerance
        {
            get => _tolerance;
            set { _tolerance = value; OnPropertyChanged(); OnPropertyChanged(nameof(T1Band)); OnPropertyChanged(nameof(T2Band)); }
        }

        /// <summary>Рассчитанный допустимый диапазон для отображения в таблице графика.</summary>
        [JsonIgnore]
        public string T1Band => Band(T1);
        [JsonIgnore]
        public string T2Band => Band(T2);

        private string Band(double v) => string.Format(CultureInfo.CurrentCulture,
            "{0:0.#} … {1:0.#}", v - _tolerance, v + _tolerance);
    }

    /// <summary>Точка-источник уже сохранённого температурного графика (для окна выбора).</summary>
    public sealed class ScheduleSourceItem
    {
        public int PointId { get; init; }
        public string DisplayName { get; init; } = "";
        public string Description { get; init; } = "";
        public List<TempSchedulePoint> Schedule { get; init; } = new();
        public double Tolerance { get; init; } = TempScheduleMath.DefaultTolerance;
    }

    public class MeasurePointItem
    {
        public int Id { get; set; }
        public string Title { get; set; } = string.Empty;
        public string NodeTitle { get; set; } = string.Empty;
        public string DisplayName => $"{NodeTitle} — {Title}";
    }

    public class PointThresholds
    {
        public double? T1Min { get; set; } public double? T1Max { get; set; }
        public double? T2Min { get; set; } public double? T2Max { get; set; }
        public double? P1Min { get; set; } public double? P1Max { get; set; }
        public double? P2Min { get; set; } public double? P2Max { get; set; }
        public double? V1Min { get; set; } public double? V1Max { get; set; }
        public double? V2Min { get; set; } public double? V2Max { get; set; }
        public double? M1Min { get; set; } public double? M1Max { get; set; }
        public double? M2Min { get; set; } public double? M2Max { get; set; }
        public double? QMin { get; set; } public double? QMax { get; set; }
        public List<TempSchedulePoint> Schedule { get; set; } = new();

        /// <summary>Допустимое отклонение от температурного графика, ±°C (для T1 и T2).</summary>
        public double ScheduleTolerance { get; set; } = TempScheduleMath.DefaultTolerance;
    }

    public class UserSettings
    {
        public string Host { get; set; } = "localhost";
        public ushort Port { get; set; } = 10000;
        public string Login { get; set; } = "";
        public string PasswordBase64 { get; set; } = "";
        public bool RememberCredentials { get; set; } = true;
        public int ThemeMode { get; set; } = 0; // 0=Светлая, 1=Тёмная, 2=Авто
        public string TimeLightStr { get; set; } = "08:00";
        public string TimeDarkStr { get; set; } = "20:00";
        public double UiScale { get; set; } = 1.0;
        public List<int> SelectedPointIds { get; set; } = new();
        public int? TnvSourcePointId { get; set; }
        public Dictionary<int, PointThresholds> PointLimits { get; set; } = new();
        public List<PointResultViewModel> LastResults { get; set; } = new();
        public List<int> PodpitkaPointIds { get; set; } = new();
        public int PodpitkaIntervalMin { get; set; } = 30;
        public Dictionary<int, VolumeThresholds> PodpitkaLimits { get; set; } = new();
        public double TnvCorrection { get; set; } = 0;
        public bool HideGeneral { get; set; } = false;
        public bool HideTrend { get; set; } = false;
        public bool HideDashboard { get; set; } = false;
        public bool HidePodpitka { get; set; } = false;
        public bool ExperimentalArchive { get; set; } = false;
        public bool ExperimentalReportPeriod { get; set; } = false;
        public int ReportPeriodStartDay { get; set; } = 25;
        public int ReportPeriodEndDay { get; set; } = 24;
    }

    public class DashboardNodeViewModel : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        public string NodeTitle { get; set; } = string.Empty;
        public ObservableCollection<PointResultViewModel> Points { get; } = new();
        
        private bool _isPaused;
        public bool IsPaused { get => _isPaused; set { _isPaused = value; Refresh(); } }
        
        public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

        public string ToggleIcon => IsPaused ? "▶" : "✕";
        public Brush ToggleBg => IsPaused 
            ? new SolidColorBrush(Color.FromArgb(180, 40, 167, 69))
            : new SolidColorBrush(Color.FromArgb(210, 255, 59, 48));
        public string ToggleTooltip => IsPaused 
            ? "Опрос объекта остановлен (нажмите, чтобы включить)" 
            : "Объект опрашивается (нажмите, чтобы остановить)";

        public Brush TileBackground
        {
            get
            {
                if (IsPaused) return (Brush)Application.Current.MainWindow.FindResource("AccentGray");
                if (Points.Any(p => !p.IsDone)) return (Brush)Application.Current.MainWindow.FindResource("AccentGray");
                if (Points.Any(p => p.HasBreach)) return (Brush)Application.Current.MainWindow.FindResource("AccentRed");
                if (Points.Any(p => p.HasError)) return (Brush)Application.Current.MainWindow.FindResource("AccentOrange");
                return (Brush)Application.Current.MainWindow.FindResource("AccentGreen");
            }
        }
        public Brush TileForeground => Brushes.White;
        public DateTime? MaxDeviceTime => Points.Max(p => p.DeviceTime);
        public string GeneralStatus
        {
            get
            {
                if (IsPaused) return "Опрос приостановлен";
                if (Points.Any(p => !p.IsDone)) return $"Опрошено {Points.Count(p => p.IsDone)} из {Points.Count}";
                var errPoint = Points.FirstOrDefault(p => p.HasError); if (errPoint != null) return errPoint.Status;
                return "Опрошено успешно";
            }
        }
    }

    public class PointResultViewModel : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        [System.Text.Json.Serialization.JsonIgnore]
        public PointThresholds? Limits { get; set; }

        public void RefreshColors()
        {
            OnPropertyChanged(nameof(T1Color)); OnPropertyChanged(nameof(T2Color));
            OnPropertyChanged(nameof(P1Color)); OnPropertyChanged(nameof(P2Color));
            OnPropertyChanged(nameof(V1Color)); OnPropertyChanged(nameof(V2Color));
            OnPropertyChanged(nameof(M1Color)); OnPropertyChanged(nameof(M2Color)); OnPropertyChanged(nameof(QColor));
            
            OnPropertyChanged(nameof(T1DashBg)); OnPropertyChanged(nameof(T2DashBg));
            OnPropertyChanged(nameof(P1DashBg)); OnPropertyChanged(nameof(P2DashBg));
            OnPropertyChanged(nameof(V1DashBg)); OnPropertyChanged(nameof(V2DashBg));
            OnPropertyChanged(nameof(M1DashBg)); OnPropertyChanged(nameof(M2DashBg)); OnPropertyChanged(nameof(QDashBg));

            OnPropertyChanged(nameof(T1DashForeground)); OnPropertyChanged(nameof(T2DashForeground));
            OnPropertyChanged(nameof(P1DashForeground)); OnPropertyChanged(nameof(P2DashForeground));
            OnPropertyChanged(nameof(V1DashForeground)); OnPropertyChanged(nameof(V2DashForeground));
            OnPropertyChanged(nameof(M1DashForeground)); OnPropertyChanged(nameof(M2DashForeground)); OnPropertyChanged(nameof(QDashForeground));
            OnPropertyChanged(nameof(SingleStatusColor));
            OnPropertyChanged(nameof(PointTitleColor));
            OnPropertyChanged(nameof(RetryVisibility));
            OnPropertyChanged(nameof(DeltaT)); OnPropertyChanged(nameof(DeltaP));
            OnPropertyChanged(nameof(DeltaTColor)); OnPropertyChanged(nameof(DeltaPColor));
            OnPropertyChanged(nameof(DeltaTDashBg)); OnPropertyChanged(nameof(DeltaPDashBg));

            // Заданные значения по температурному графику зависят от Тнв и настроек графика.
            OnPropertyChanged(nameof(ScheduleTargetVisibility));
            OnPropertyChanged(nameof(ExpectedT1Text)); OnPropertyChanged(nameof(ExpectedT2Text));
            OnPropertyChanged(nameof(ScheduleT1Tooltip)); OnPropertyChanged(nameof(ScheduleT2Tooltip));
        }

        private PollState _state = PollState.Pending;
        [JsonIgnore] public PollState State { get => _state; set { _state = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasError)); OnPropertyChanged(nameof(IsWaiting)); OnPropertyChanged(nameof(RetryVisibility)); } }
        [JsonIgnore] public bool HasError => State == PollState.Error;
        [JsonIgnore] public bool IsWaiting => State is PollState.Pending or PollState.Queued or PollState.Polling;
        [JsonIgnore] public bool IsDone => !IsWaiting && State != PollState.Paused;

        [System.Text.Json.Serialization.JsonIgnore]
        public bool HasBreach => IsBreached(T1, Limits?.T1Min, Limits?.T1Max) || IsBreached(T2, Limits?.T2Min, Limits?.T2Max) ||
                                 IsT1ScheduleBreached(T1, Limits?.Schedule) || IsT2ScheduleBreached(T2, Limits?.Schedule) ||
                                 IsBreached(P1, Limits?.P1Min, Limits?.P1Max) || IsBreached(P2, Limits?.P2Min, Limits?.P2Max) ||
                                 IsBreached(V1, Limits?.V1Min, Limits?.V1Max) || IsBreached(V2, Limits?.V2Min, Limits?.V2Max) ||
                                 IsBreached(M1, Limits?.M1Min, Limits?.M1Max) || IsBreached(M2, Limits?.M2Min, Limits?.M2Max) ||
                                 IsBreached(Q, Limits?.QMin, Limits?.QMax);

        [System.Text.Json.Serialization.JsonIgnore]
        public Visibility RetryVisibility => HasError ? Visibility.Visible : Visibility.Collapsed;

        private Brush GetColor(double? val, double? min, double? max)
        {
            var defaultColor = Application.Current.MainWindow?.TryFindResource("LabelPrimary") as Brush ?? Brushes.Black;
            if (val == null) return defaultColor;
            return IsBreached(val, min, max) ? Brushes.Red : defaultColor;
        }

        private bool IsBreached(double? val, double? min, double? max)
        {
            if (!val.HasValue) return false;
            if (min.HasValue && val.Value < min.Value) return true;
            if (max.HasValue && val.Value > max.Value) return true;
            return false;
        }

        private (double? expT1, double? expT2) GetExpectedTemps(List<TempSchedulePoint>? schedule)
            => TempScheduleMath.Expected(MainWindow.CurrentGlobalTnv, schedule);

        /// <summary>Настроенный用户对 точки допуск; для старых настроек — 3.0 °C.</summary>
        [System.Text.Json.Serialization.JsonIgnore]
        public double ScheduleTolerance =>
            Math.Max(0, Limits?.ScheduleTolerance ?? TempScheduleMath.DefaultTolerance);

        // ---------- Заданные значения по температурному графику (для крупных плиток одиночного режима) ----------

        /// <summary>Показывать цель только когда график задан и известна температура наружного воздуха.</summary>
        [System.Text.Json.Serialization.JsonIgnore]
        public bool HasScheduleTarget =>
            Limits?.Schedule != null && Limits.Schedule.Count > 0 && MainWindow.CurrentGlobalTnv.HasValue;

        [System.Text.Json.Serialization.JsonIgnore]
        public Visibility ScheduleTargetVisibility =>
            HasScheduleTarget ? Visibility.Visible : Visibility.Collapsed;

        [System.Text.Json.Serialization.JsonIgnore]
        public string ExpectedT1Text => FormatExpected(GetExpectedTemps(Limits?.Schedule).expT1);

        [System.Text.Json.Serialization.JsonIgnore]
        public string ExpectedT2Text => FormatExpected(GetExpectedTemps(Limits?.Schedule).expT2);

        [System.Text.Json.Serialization.JsonIgnore]
        public string ScheduleT1Tooltip => ScheduleTooltip(GetExpectedTemps(Limits?.Schedule).expT1);

        [System.Text.Json.Serialization.JsonIgnore]
        public string ScheduleT2Tooltip => ScheduleTooltip(GetExpectedTemps(Limits?.Schedule).expT2);

        private static string FormatExpected(double? value) =>
            value.HasValue ? value.Value.ToString("F1", CultureInfo.CurrentCulture) : "";

        private string ScheduleTooltip(double? expected)
        {
            if (!expected.HasValue)
                return "Температурный график не задан или не получена температура наружного воздуха (Тнв)";
            return string.Format(CultureInfo.CurrentCulture,
                "По графику: {0:F1} °C при Тнв = {1:F1} °C. Допустимое отклонение ±{2:0.##} °C",
                expected.Value, MainWindow.CurrentGlobalTnv ?? 0, ScheduleTolerance);
        }

        private bool IsT1ScheduleBreached(double? t1, List<TempSchedulePoint>? schedule)
        {
            if (!t1.HasValue) return false;
            var exp = GetExpectedTemps(schedule).expT1;
            return exp.HasValue && Math.Abs(t1.Value - exp.Value) > ScheduleTolerance;
        }

        private bool IsT2ScheduleBreached(double? t2, List<TempSchedulePoint>? schedule)
        {
            if (!t2.HasValue) return false;
            var exp = GetExpectedTemps(schedule).expT2;
            return exp.HasValue && Math.Abs(t2.Value - exp.Value) > ScheduleTolerance;
        }

        private Brush GetDashBg(double? val, double? min, double? max, bool isT1 = false, bool isT2 = false)
        {
            if (IsBreached(val, min, max) || 
               (isT1 && IsT1ScheduleBreached(T1, Limits?.Schedule)) || 
               (isT2 && IsT2ScheduleBreached(T2, Limits?.Schedule))) 
                return (Brush)Application.Current.MainWindow.FindResource("AccentRed");
                
            if (!IsDone) return (Brush)Application.Current.MainWindow.FindResource("AccentGray");
            if (HasError) return (Brush)Application.Current.MainWindow.FindResource("AccentOrange");
            return (Brush)Application.Current.MainWindow.FindResource("AccentGreen");
        }

        [System.Text.Json.Serialization.JsonIgnore] public Brush T1DashBg => GetDashBg(T1, Limits?.T1Min, Limits?.T1Max, true, false);
        [System.Text.Json.Serialization.JsonIgnore] public Brush T2DashBg => GetDashBg(T2, Limits?.T2Min, Limits?.T2Max, false, true);
        [System.Text.Json.Serialization.JsonIgnore] public Brush P1DashBg => GetDashBg(P1, Limits?.P1Min, Limits?.P1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush P2DashBg => GetDashBg(P2, Limits?.P2Min, Limits?.P2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush V1DashBg => GetDashBg(V1, Limits?.V1Min, Limits?.V1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush V2DashBg => GetDashBg(V2, Limits?.V2Min, Limits?.V2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush M1DashBg => GetDashBg(M1, Limits?.M1Min, Limits?.M1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush M2DashBg => GetDashBg(M2, Limits?.M2Min, Limits?.M2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush QDashBg => GetDashBg(Q, Limits?.QMin, Limits?.QMax);

        private Brush DashFore(double? val, double? min, double? max, bool isT1 = false, bool isT2 = false) => 
            (IsBreached(val, min, max) || (isT1 && IsT1ScheduleBreached(T1, Limits?.Schedule)) || (isT2 && IsT2ScheduleBreached(T2, Limits?.Schedule))) 
            ? Brushes.Yellow : Brushes.White;

        [System.Text.Json.Serialization.JsonIgnore] public Brush T1DashForeground => DashFore(T1, Limits?.T1Min, Limits?.T1Max, true, false);
        [System.Text.Json.Serialization.JsonIgnore] public Brush T2DashForeground => DashFore(T2, Limits?.T2Min, Limits?.T2Max, false, true);
        [System.Text.Json.Serialization.JsonIgnore] public Brush P1DashForeground => DashFore(P1, Limits?.P1Min, Limits?.P1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush P2DashForeground => DashFore(P2, Limits?.P2Min, Limits?.P2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush V1DashForeground => DashFore(V1, Limits?.V1Min, Limits?.V1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush V2DashForeground => DashFore(V2, Limits?.V2Min, Limits?.V2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush M1DashForeground => DashFore(M1, Limits?.M1Min, Limits?.M1Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush M2DashForeground => DashFore(M2, Limits?.M2Min, Limits?.M2Max);
        [System.Text.Json.Serialization.JsonIgnore] public Brush QDashForeground => DashFore(Q, Limits?.QMin, Limits?.QMax);

        [System.Text.Json.Serialization.JsonIgnore]
        public Brush SingleStatusColor
        {
            get
            {
                if (HasBreach) return (Brush)Application.Current.MainWindow.FindResource("AccentRed");
                if (HasError) return (Brush)Application.Current.MainWindow.FindResource("AccentOrange");
                if (!IsDone) return (Brush)Application.Current.MainWindow.FindResource("AccentGray");
                return (Brush)Application.Current.MainWindow.FindResource("AccentGreen");
            }
        }
        
        [System.Text.Json.Serialization.JsonIgnore]
        public Brush PointTitleColor
        {
            get
            {
                if (HasBreach) return (Brush)Application.Current.MainWindow.FindResource("AccentRed");
                if (HasError) return (Brush)Application.Current.MainWindow.FindResource("AccentOrange");
                if (!IsDone) return (Brush)Application.Current.MainWindow.FindResource("AccentGray");
                return Brushes.White;
            }
        }
        
        [System.Text.Json.Serialization.JsonIgnore]
        public Brush TileForeground => Brushes.White;

        private int _id; public int Id { get => _id; set { _id = value; OnPropertyChanged(); } }
        private string _nodeTitle = string.Empty; public string NodeTitle { get => _nodeTitle; set { _nodeTitle = value; OnPropertyChanged(); } }
        private string _title = string.Empty; public string Title { get => _title; set { _title = value; OnPropertyChanged(); } }
        private DateTime? _deviceTime; public DateTime? DeviceTime { get => _deviceTime; set { _deviceTime = value; OnPropertyChanged(); } }
        
        private double? _t1; public double? T1 { get => _t1; set { _t1 = value; OnPropertyChanged(); OnPropertyChanged(nameof(T1Color)); OnPropertyChanged(nameof(T1DashBg)); OnPropertyChanged(nameof(T1DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); OnPropertyChanged(nameof(DeltaT)); OnPropertyChanged(nameof(DeltaTColor)); OnPropertyChanged(nameof(DeltaTDashBg)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush T1Color => (IsBreached(T1, Limits?.T1Min, Limits?.T1Max) || IsT1ScheduleBreached(T1, Limits?.Schedule)) ? Brushes.Red : ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelPrimary") ?? Brushes.Black);
        
        private double? _t2; public double? T2 { get => _t2; set { _t2 = value; OnPropertyChanged(); OnPropertyChanged(nameof(T2Color)); OnPropertyChanged(nameof(T2DashBg)); OnPropertyChanged(nameof(T2DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); OnPropertyChanged(nameof(DeltaT)); OnPropertyChanged(nameof(DeltaTColor)); OnPropertyChanged(nameof(DeltaTDashBg)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush T2Color => (IsBreached(T2, Limits?.T2Min, Limits?.T2Max) || IsT2ScheduleBreached(T2, Limits?.Schedule)) ? Brushes.Red : ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelPrimary") ?? Brushes.Black);
        
        private double? _p1; public double? P1 { get => _p1; set { _p1 = value; OnPropertyChanged(); OnPropertyChanged(nameof(P1Color)); OnPropertyChanged(nameof(P1DashBg)); OnPropertyChanged(nameof(P1DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); OnPropertyChanged(nameof(DeltaP)); OnPropertyChanged(nameof(DeltaPColor)); OnPropertyChanged(nameof(DeltaPDashBg)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush P1Color => GetColor(P1, Limits?.P1Min, Limits?.P1Max);
        
        private double? _p2; public double? P2 { get => _p2; set { _p2 = value; OnPropertyChanged(); OnPropertyChanged(nameof(P2Color)); OnPropertyChanged(nameof(P2DashBg)); OnPropertyChanged(nameof(P2DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); OnPropertyChanged(nameof(DeltaP)); OnPropertyChanged(nameof(DeltaPColor)); OnPropertyChanged(nameof(DeltaPDashBg)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush P2Color => GetColor(P2, Limits?.P2Min, Limits?.P2Max);
        
        private double? _v1; public double? V1 { get => _v1; set { _v1 = value; OnPropertyChanged(); OnPropertyChanged(nameof(V1Color)); OnPropertyChanged(nameof(V1DashBg)); OnPropertyChanged(nameof(V1DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush V1Color => GetColor(V1, Limits?.V1Min, Limits?.V1Max);
        
        private double? _v2; public double? V2 { get => _v2; set { _v2 = value; OnPropertyChanged(); OnPropertyChanged(nameof(V2Color)); OnPropertyChanged(nameof(V2DashBg)); OnPropertyChanged(nameof(V2DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush V2Color => GetColor(V2, Limits?.V2Min, Limits?.V2Max);
        
        private double? _m1; public double? M1 { get => _m1; set { _m1 = value; OnPropertyChanged(); OnPropertyChanged(nameof(M1Color)); OnPropertyChanged(nameof(M1DashBg)); OnPropertyChanged(nameof(M1DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush M1Color => GetColor(M1, Limits?.M1Min, Limits?.M1Max);
        
        private double? _m2; public double? M2 { get => _m2; set { _m2 = value; OnPropertyChanged(); OnPropertyChanged(nameof(M2Color)); OnPropertyChanged(nameof(M2DashBg)); OnPropertyChanged(nameof(M2DashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush M2Color => GetColor(M2, Limits?.M2Min, Limits?.M2Max);
        
        private double? _q; public double? Q { get => _q; set { _q = value; OnPropertyChanged(); OnPropertyChanged(nameof(QColor)); OnPropertyChanged(nameof(QDashBg)); OnPropertyChanged(nameof(QDashForeground)); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); } }
        [System.Text.Json.Serialization.JsonIgnore] public Brush QColor => GetColor(Q, Limits?.QMin, Limits?.QMax);
        
        [System.Text.Json.Serialization.JsonIgnore] public double? DeltaT => (T1.HasValue && T2.HasValue) ? T1 - T2 : null;
        [System.Text.Json.Serialization.JsonIgnore] public double? DeltaP => (P1.HasValue && P2.HasValue) ? P1 - P2 : null;
        [System.Text.Json.Serialization.JsonIgnore] public Brush DeltaTColor => DeltaT.HasValue ? ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelPrimary") ?? Brushes.Black) : ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelSecondary") ?? Brushes.Gray);
        [System.Text.Json.Serialization.JsonIgnore] public Brush DeltaPColor => DeltaP.HasValue ? ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelPrimary") ?? Brushes.Black) : ((Brush?)Application.Current.MainWindow?.TryFindResource("LabelSecondary") ?? Brushes.Gray);
        [System.Text.Json.Serialization.JsonIgnore] public Brush DeltaTDashBg => GetDashBg(null, null, null);
        [System.Text.Json.Serialization.JsonIgnore] public Brush DeltaPDashBg => GetDashBg(null, null, null);
        
        private string _status = string.Empty; public string Status { get => _status; set { _status = value; OnPropertyChanged(); OnPropertyChanged(nameof(SingleStatusColor)); OnPropertyChanged(nameof(PointTitleColor)); OnPropertyChanged(nameof(RetryVisibility)); } }
    }

    // ==================== Poll Log ====================

    public sealed class PollLogEntry
    {
        public DateTime Timestamp { get; init; } = DateTime.Now;
        public PollState State { get; init; }
        public string Message { get; init; } = "";
        public string Phase { get; init; } = "";     // "Ожидание", "Дозвон", "Опрос", "Снятие данных", "Отключение", "Готово", "Ошибка"
    }

    public sealed class PollLogStore
    {
        private readonly ConcurrentDictionary<int, List<PollLogEntry>> _logs = new();
        private const int MaxEntries = 200;

        public void Add(int pointId, PollState state, string message, string phase)
        {
            var list = _logs.GetOrAdd(pointId, _ => new List<PollLogEntry>());
            lock (list)
            {
                list.Add(new PollLogEntry { State = state, Message = message, Phase = phase });
                if (list.Count > MaxEntries) list.RemoveRange(0, list.Count - MaxEntries);
            }
        }

        public List<PollLogEntry> Get(int pointId)
        {
            if (_logs.TryGetValue(pointId, out var list))
                lock (list) return new List<PollLogEntry>(list);
            return new List<PollLogEntry>();
        }

        public void Clear(int pointId)
        {
            if (_logs.TryGetValue(pointId, out var list))
                lock (list) list.Clear();
        }
    }

    // ==================== PollCoordinator ====================

    public enum PollState { Pending, Queued, Polling, Ok, OkCached, Error, Paused }

    /// <summary>Что опрашиваем. NodeKey — ключ канала связи (по умолчанию название объекта).</summary>
    public sealed record PollTarget(int PointId, string NodeKey);

    public sealed class PointSnapshot
    {
        public int PointId { get; init; }
        public DateTime? DeviceTime { get; init; }          // время записи в ЛЭРС
        public string RawJson { get; init; } = "";          // UI разбирает существующим UpdatePointValues
        public DateTime ReadAtUtc { get; init; }            // когда мы прочитали запись
        public DateTime? PolledOkAtUtc { get; init; }       // когда прибор реально ответил на наш опрос

        /// <summary>Возраст данных: берём самый свежий из признаков (часы прибора могут отставать/спешить).</summary>
        public TimeSpan Age(DateTime nowUtc)
        {
            var best = PolledOkAtUtc ?? DateTime.MinValue;
            if (DeviceTime.HasValue)
            {
                var dev = DeviceTime.Value.Kind == DateTimeKind.Utc ? DeviceTime.Value : DeviceTime.Value.ToUniversalTime();
                if (dev > best) best = dev;
            }
            return best == DateTime.MinValue ? TimeSpan.MaxValue : nowUtc - best;
        }
    }

    public sealed record PollUpdate(int PointId, PollState State, string Message, PointSnapshot? Snapshot);

    public sealed class PollCoordinator
    {
        private readonly HttpClient _http;
        private readonly Func<string> _baseUrl;
        private readonly SemaphoreSlim _deviceSlots;   // одновременных «живых» опросов приборов
        private readonly SemaphoreSlim _httpSlots;     // одновременных лёгких GET
        private readonly ConcurrentDictionary<string, SemaphoreSlim> _channelLocks = new();
        private readonly ConcurrentDictionary<int, Lazy<Task<PollUpdate>>> _inFlight = new();
        private readonly ConcurrentDictionary<int, PointSnapshot> _cache = new();
        private static readonly Random Rng = new();

        public PollLogStore Log { get; } = new PollLogStore();

        public TimeSpan CacheTtl { get; set; } = TimeSpan.FromMinutes(3);
        public TimeSpan PollTimeout { get; set; } = TimeSpan.FromMinutes(3);
        public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(30);

        /// <summary>Вызывается из потоков пула! Подписчик обязан маршалить в UI.</summary>
        public event Action<PollUpdate>? Updated;

        public PollCoordinator(HttpClient http, Func<string> baseUrl, int maxDevicePolls = 6, int maxHttp = 16)
        {
            _http = http; _baseUrl = baseUrl;
            _deviceSlots = new SemaphoreSlim(maxDevicePolls);
            _httpSlots = new SemaphoreSlim(maxHttp);
        }

        public bool TryGetCached(int pointId, out PointSnapshot snap) => _cache.TryGetValue(pointId, out snap!);

        // ---------- публичный API ----------

        public Task<PollUpdate> PollPointAsync(PollTarget t, bool ignoreCache, CancellationToken ct)
        {
            // Дедупликация: плановый опрос + ручной «повтор» одной точки делят один запрос.
            var lazy = _inFlight.GetOrAdd(t.PointId, _ => new Lazy<Task<PollUpdate>>(() => RunAsync(t, ignoreCache, ct)));
            return lazy.Value;
        }

        public Task<PollUpdate[]> PollManyAsync(IEnumerable<PollTarget> targets, bool ignoreCache, CancellationToken ct)
            => Task.WhenAll(targets.Select(t => PollPointAsync(t, ignoreCache, ct)));

        /// <summary>Только прочитать то, что уже лежит в ЛЭРС (без опроса прибора).</summary>
        public async Task<PollUpdate> ReadOnlyAsync(PollTarget t, CancellationToken ct)
        {
            var snap = await GetLastAsync(t.PointId, ct);
            if (snap == null) return new PollUpdate(t.PointId, PollState.Error, "Нет данных в ЛЭРС", null);
            _cache[t.PointId] = snap;
            return Publish(new PollUpdate(t.PointId, PollState.Ok, $"Снято {Fmt(snap)}", snap));
        }

        // ---------- ядро ----------

        private async Task<PollUpdate> RunAsync(PollTarget t, bool ignoreCache, CancellationToken ct)
        {
            try
            {
                Publish(new PollUpdate(t.PointId, PollState.Queued, "В очереди", null));

                if (!ignoreCache && _cache.TryGetValue(t.PointId, out var c) && c.Age(DateTime.UtcNow) <= CacheTtl)
                    return Publish(CachedUpdate(t.PointId, c));

                var chanLock = _channelLocks.GetOrAdd(t.NodeKey, _ => new SemaphoreSlim(1, 1));
                await chanLock.WaitAsync(ct).ConfigureAwait(false);        // 1 прибор/канал за раз
                try
                {
                    await _deviceSlots.WaitAsync(ct).ConfigureAwait(false); // глобальный потолок
                    try { return await PollDeviceAsync(t, ignoreCache, ct).ConfigureAwait(false); }
                    finally { _deviceSlots.Release(); }
                }
                finally { chanLock.Release(); }
            }
            catch (OperationCanceledException) { return Publish(new PollUpdate(t.PointId, PollState.Error, "Ошибка: отменено", null)); }
            catch (Exception ex) { return Publish(new PollUpdate(t.PointId, PollState.Error, "Ошибка: " + ex.Message, null)); }
            finally { _inFlight.TryRemove(t.PointId, out _); }
        }

        private async Task<PollUpdate> PollDeviceAsync(PollTarget t, bool ignoreCache, CancellationToken ct)
        {
            // Повторная проверка: пока стояли в очереди, мог опросить кто-то другой / ЛЭРС сам.
            Log.Add(t.PointId, PollState.Polling, "Проверка актуальных данных в базе ЛЭРС", "Снятие данных");
            var first = await GetLastAsync(t.PointId, ct);
            if (first != null && !ignoreCache && first.Age(DateTime.UtcNow) <= CacheTtl)
            {
                _cache[t.PointId] = first;
                return Publish(CachedUpdate(t.PointId, first));
            }

            DateTime? before = first?.DeviceTime;
            string lastError = "Нет ответа от прибора";
            int hardErrors = 0;
            var deadline = DateTime.UtcNow + PollTimeout;
            var nextPostAt = DateTime.UtcNow;
            var delay = TimeSpan.FromSeconds(2);

            while (DateTime.UtcNow < deadline)
            {
                ct.ThrowIfCancellationRequested();

                if (DateTime.UtcNow >= nextPostAt)
                {
                    Log.Add(t.PointId, PollState.Polling, "Отправка команды опроса прибору (дозвон)", "Дозвон");
                    var (ok, code, err) = await PostPollAsync(t.PointId, ct);
                    if (ok)
                    {
                        nextPostAt = DateTime.UtcNow.AddSeconds(30);        // не долбим прибор повторными POST
                        Publish(new PollUpdate(t.PointId, PollState.Polling, "Идёт опрос прибора...", null));
                    }
                    else
                    {
                        lastError = err;
                        if (IsBusy(code, err))   // канал занят — ждём с jitter, это НЕ ошибка
                        {
                            nextPostAt = DateTime.UtcNow.AddSeconds(5 + Rng.Next(0, 6));
                            Publish(new PollUpdate(t.PointId, PollState.Polling, "Ожидание канала...", null));
                        }
                        else
                        {
                            if (++hardErrors >= 5) break;                   // быстрый отказ
                            nextPostAt = DateTime.UtcNow.AddSeconds(Math.Min(30, 3 * hardErrors * hardErrors));
                            Publish(new PollUpdate(t.PointId, PollState.Polling, $"Повтор ({err})", null));
                        }
                    }
                }

                await Task.Delay(delay, ct);
                delay = TimeSpan.FromMilliseconds(Math.Min(6000, delay.TotalMilliseconds * 1.5)); // 2→3→4.5→6 c

                Log.Add(t.PointId, PollState.Polling, "Проверка снятых данных из базы ЛЭРС", "Снятие данных");
                var snap = await GetLastAsync(t.PointId, ct);
                if (snap?.DeviceTime != null && (before == null || snap.DeviceTime > before))
                {
                    var fresh = new PointSnapshot { PointId = snap.PointId, DeviceTime = snap.DeviceTime, RawJson = snap.RawJson,
                                                    ReadAtUtc = snap.ReadAtUtc, PolledOkAtUtc = DateTime.UtcNow };
                    _cache[t.PointId] = fresh;

                    // Отключаем прибор после успешного опроса — освобождаем канал связи
                    // для других устройств на том же канале.
                    Log.Add(t.PointId, PollState.Polling, "Отключение прибора, освобождение канала", "Отключение");
                    try { await DisconnectAsync(t.PointId, ct).ConfigureAwait(false); }
                    catch { /* best-effort */ }
                    Log.Add(t.PointId, PollState.Ok, "Прибор отключён, канал свободен", "Готово");

                    return Publish(new PollUpdate(t.PointId, PollState.Ok, $"Опрошено {Fmt(fresh)}", fresh));
                }
            }
            // Отключаем прибор даже при таймауте — канал должен быть освобождён
            Log.Add(t.PointId, PollState.Error, "Отключение прибора после таймаута", "Отключение");
            try { await DisconnectAsync(t.PointId, ct).ConfigureAwait(false); }
            catch { /* best-effort */ }

            return Publish(new PollUpdate(t.PointId, PollState.Error, $"Таймаут: {lastError}", first));
        }

        private PollUpdate CachedUpdate(int id, PointSnapshot s)
        {
            var age = DateTime.UtcNow - (s.PolledOkAtUtc ?? s.ReadAtUtc);
            return new PollUpdate(id, PollState.OkCached,
                $"Снято {Fmt(s)} (данные {(int)Math.Max(0, age.TotalMinutes)} мин назад, повторно не опрашивали)", s);
        }

        private static string Fmt(PointSnapshot s) => (s.DeviceTime ?? s.ReadAtUtc.ToLocalTime()).ToString("HH:mm:ss");

        private PollUpdate Publish(PollUpdate u)
        {
            Log.Add(u.PointId, u.State, u.Message, PhaseForState(u.State, u.Message));
            try { Updated?.Invoke(u); } catch { }
            return u;
        }

        private static string PhaseForState(PollState state, string message)
        {
            if (string.IsNullOrEmpty(message)) return "";
            var msgLower = message.ToLowerInvariant();
            if (state == PollState.Queued) return "Ожидание";
            if (msgLower.Contains("канал") || msgLower.Contains("очеред")) return "Дозвон";
            if (msgLower.Contains("опрос") || state == PollState.Polling) return "Опрос";
            if (msgLower.Contains("снят") || msgLower.Contains("данные")) return "Снятие данных";
            if (msgLower.Contains("отключ")) return "Отключение";
            if (state is PollState.Ok or PollState.OkCached) return "Готово";
            if (state == PollState.Error) return "Ошибка";
            return "";
        }

        // ---------- HTTP ----------

        private async Task<PointSnapshot?> GetLastAsync(int id, CancellationToken ct)
        {
            await _httpSlots.WaitAsync(ct);
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(RequestTimeout);
                using var res = await _http.GetAsync($"{_baseUrl()}/Data/MeasurePoints/{id}/Consumption/Last", cts.Token);
                if (!res.IsSuccessStatusCode) return null;
                var json = await res.Content.ReadAsStringAsync(cts.Token);
                if (string.IsNullOrWhiteSpace(json) || json.Trim() == "null") return null;
                using var doc = JsonDocument.Parse(json);
                return new PointSnapshot { PointId = id, RawJson = json, ReadAtUtc = DateTime.UtcNow,
                                           DeviceTime = TryGetDate(doc.RootElement, "dateTime", "deviceTime", "date") };
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return null; } // таймаут запроса
            catch (HttpRequestException) { return null; }
            finally { _httpSlots.Release(); }
        }

        private async Task<(bool ok, int code, string err)> PostPollAsync(int id, CancellationToken ct)
        {
            await _httpSlots.WaitAsync(ct);
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(RequestTimeout);
                using var req = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl()}/Poll/MeasurePoints/{id}/Currents?once=true")
                { Content = new ByteArrayContent(Array.Empty<byte>()) };
                using var res = await _http.SendAsync(req, cts.Token);
                if (res.IsSuccessStatusCode) return (true, (int)res.StatusCode, "");
                var body = await res.Content.ReadAsStringAsync(cts.Token);
                return (false, (int)res.StatusCode, ParseLersError(body, (int)res.StatusCode));
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return (false, 0, "Сбой сети (таймаут запроса)"); }
            catch (HttpRequestException) { return (false, 0, "Сбой сети"); }
            finally { _httpSlots.Release(); }
        }

        /// <summary>
        /// Отключает прибор после опроса, освобождая канал связи.
        /// Пробует несколько вариантов эндпоинтов отключения.
        /// Ошибки тихо игнорируются — отключение best-effort.
        /// </summary>
        public async Task DisconnectAsync(int pointId, CancellationToken ct)
        {
            await _httpSlots.WaitAsync(ct);
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(15));

                // Вариант 1: POST /Poll/MeasurePoints/{id}/Disconnect (наиболее вероятный по схеме API)
                using var req1 = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl()}/Poll/MeasurePoints/{pointId}/Disconnect")
                { Content = new ByteArrayContent(Array.Empty<byte>()) };
                using var res1 = await _http.SendAsync(req1, cts.Token);
                if (res1.IsSuccessStatusCode) return;

                // Вариант 2: DELETE /Poll/MeasurePoints/{id}/Currents
                using var req2 = new HttpRequestMessage(HttpMethod.Delete, $"{_baseUrl()}/Poll/MeasurePoints/{pointId}/Currents");
                using var res2 = await _http.SendAsync(req2, cts.Token);
                if (res2.IsSuccessStatusCode) return;

                // Вариант 3: POST /Poll/MeasurePoints/{id}/Stop
                using var req3 = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl()}/Poll/MeasurePoints/{pointId}/Stop")
                { Content = new ByteArrayContent(Array.Empty<byte>()) };
                using var res3 = await _http.SendAsync(req3, cts.Token);
                // Результат игнорируем — best-effort
            }
            catch
            {
                // Тихо игнорируем — отключение не критично
            }
            finally
            {
                _httpSlots.Release();
            }
        }

        private static bool IsBusy(int code, string msg) =>
            code == 409 || code == 423 ||
            msg.Contains("занят", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("already", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("используется", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("ожидани", StringComparison.OrdinalIgnoreCase);

        private static string ParseLersError(string json, int status)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(json)) return $"Отказ ({status})";
                using var d = JsonDocument.Parse(json);
                if (d.RootElement.TryGetProperty("errorDescription", out var a)) return a.GetString() ?? "";
                if (d.RootElement.TryGetProperty("errorMessage", out var b)) return b.GetString() ?? "";
            }
            catch { }
            return $"Отказ ({status})";
        }

        private static DateTime? TryGetDate(JsonElement e, params string[] names)
        {
            foreach (var n in names)
                if (e.TryGetProperty(n, out var p))
                {
                    if (p.TryGetDateTime(out var dt)) return dt;
                    if (p.ValueKind == JsonValueKind.String && DateTime.TryParse(p.GetString(), out var s)) return s;
                }
            return null;
        }
    }

    /// <summary>Планировщик без дрейфа: тик каждые N минут независимо от длительности цикла.</summary>
    public sealed class PollScheduler
    {
        private readonly PollCoordinator _coord;
        private readonly Func<IReadOnlyList<PollTarget>> _targets;   // только НЕ приостановленные
        public DateTime NextRunLocal { get; private set; }

        public PollScheduler(PollCoordinator coord, Func<IReadOnlyList<PollTarget>> targets) { _coord = coord; _targets = targets; }

        public async Task RunAsync(TimeSpan interval, CancellationToken ct)
        {
            using var timer = new PeriodicTimer(interval);
            _ = _coord.PollManyAsync(_targets(), false, ct);               // первый цикл сразу (с учётом кэша)
            NextRunLocal = DateTime.Now + interval;
            try
            {
                while (await timer.WaitForNextTickAsync(ct))
                {
                    NextRunLocal = DateTime.Now + interval;
                    _ = _coord.PollManyAsync(_targets(), false, ct);       // не ждём: пересечения гасит дедупликация
                }
            }
            catch (OperationCanceledException) { }
        }

        /// <summary>Кнопка «Принудительный опрос». Кэш &lt; 3 мин уважается — такие точки не дёргаются.</summary>
        public Task ForceNowAsync(CancellationToken ct) => _coord.PollManyAsync(_targets(), false, ct);
    }

    // ==================== MasonryPanel ====================

    public class MasonryPanel : Panel
    {
        private const double Unit = 4;   // гранулярность сетки по X, px

        public static readonly DependencyProperty SpacingProperty =
            DependencyProperty.Register(nameof(Spacing), typeof(double), typeof(MasonryPanel),
                new FrameworkPropertyMetadata(6.0, FrameworkPropertyMetadataOptions.AffectsMeasure));
        public static readonly DependencyProperty MaxCardWidthProperty =
            DependencyProperty.Register(nameof(MaxCardWidth), typeof(double), typeof(MasonryPanel),
                new FrameworkPropertyMetadata(420.0, FrameworkPropertyMetadataOptions.AffectsMeasure));
        public static readonly DependencyProperty MinCardWidthProperty =
            DependencyProperty.Register(nameof(MinCardWidth), typeof(double), typeof(MasonryPanel),
                new FrameworkPropertyMetadata(220.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

        public double Spacing { get => (double)GetValue(SpacingProperty); set => SetValue(SpacingProperty, value); }
        public double MaxCardWidth { get => (double)GetValue(MaxCardWidthProperty); set => SetValue(MaxCardWidthProperty, value); }
        public double MinCardWidth { get => (double)GetValue(MinCardWidthProperty); set => SetValue(MinCardWidthProperty, value); }

        /// <summary>Сколько колонок влезет так, чтобы карточки были не шире MaxCardWidth,
        /// но при этом ЗАПОЛНЯЛИ всю доступную ширину (без пустой полосы справа).</summary>
        private int CalcColumns(double totalWidth)
        {
            double sp = Spacing;
            // ceil — в отличие от floor, даёт столько колонок, что cardW <= MaxCardWidth
            int cols = Math.Max(1, (int)Math.Ceiling((totalWidth + sp) / (MaxCardWidth + sp)));

            // Не держим пустые колонки, если карточек меньше, чем колонок:
            // одна карточка должна занимать всю строку, а не треть ширины.
            int visible = 0;
            foreach (UIElement c in InternalChildren)
                if (c.Visibility != Visibility.Collapsed) visible++;
            cols = Math.Clamp(cols, 1, Math.Max(1, visible));

            double cardW = (totalWidth - sp * (cols - 1)) / cols;
            // Если карточки получились уже минимума — уменьшаем число колонок
            while (cols > 1 && cardW < MinCardWidth)
            {
                cols--;
                cardW = (totalWidth - sp * (cols - 1)) / cols;
            }
            return cols;
        }

        private double CalcCardWidth(double totalWidth)
        {
            int cols = CalcColumns(totalWidth);
            double w = (totalWidth - Spacing * (cols - 1)) / cols;
            // Если карточек мало (одна на очень широком экране), не растягиваем её
            // до бесконечности — иначе внутри снова появится пустое пространство.
            return Math.Min(w, Math.Max(MinCardWidth, MaxCardWidth * 1.5));
        }

        protected override Size MeasureOverride(Size available)
        {
            double w = double.IsInfinity(available.Width) ? 1200 : available.Width;
            double cardW = CalcCardWidth(w);
            foreach (UIElement c in InternalChildren)
            {
                if (c.Visibility == Visibility.Collapsed) continue;
                c.Measure(new Size(cardW, double.PositiveInfinity));
            }
            var (_, size) = Pack(w, cardW);
            return new Size(Math.Min(size.Width, w), size.Height);
        }

        protected override Size ArrangeOverride(Size final)
        {
            double cardW = CalcCardWidth(final.Width);
            var (rects, size) = Pack(final.Width, cardW);
            for (int i = 0; i < rects.Count; i++)
                if (rects[i] is Rect r) InternalChildren[i].Arrange(r);
            return new Size(final.Width, size.Height);
        }

        /// <summary>Кладём карточки в самый короткий столбец. Ширина столбца фиксирована,
        /// поэтому вся строка заполняется целиком — пустой полосы справа нет.</summary>
        private (List<Rect?> rects, Size size) Pack(double totalWidth, double cardW)
        {
            double sp = Spacing;
            int cols = CalcColumns(totalWidth);
            var colHeights = new double[cols];
            var rects = new List<Rect?>(InternalChildren.Count);

            foreach (UIElement c in InternalChildren)
            {
                if (c.Visibility == Visibility.Collapsed) { rects.Add(null); continue; }

                // Самый короткий столбец (при равенстве — левый)
                int best = 0;
                for (int i = 1; i < cols; i++)
                    if (colHeights[i] < colHeights[best] - 0.01) best = i;

                double x = best * (cardW + sp);
                double y = colHeights[best];
                double h = c.DesiredSize.Height;

                rects.Add(new Rect(x, y, cardW, h));
                colHeights[best] = y + h + sp;
            }

            double maxH = 0;
            foreach (var h in colHeights) if (h > maxH) maxH = h;
            return (rects, new Size(totalWidth, Math.Max(0, maxH - sp)));
        }
    }

    // ==================== CompactColumnsPanel ====================

    /// <summary>
    /// Компактная сетка плиток ВНУТРИ карточки объекта. В отличие от UniformGrid:
    ///  - число колонок подбирается по ширине и по реальному числу плиток
    ///    (одна точка = одна колонка, а не пустая половина карточки);
    ///  - высота строки равна самой высокой плитке в ней, без растягивания;
    ///  - скрытые (Collapsed) элементы не занимают место.
    /// </summary>
    public class CompactColumnsPanel : Panel
    {
        public static readonly DependencyProperty SpacingProperty =
            DependencyProperty.Register(nameof(Spacing), typeof(double), typeof(CompactColumnsPanel),
                new FrameworkPropertyMetadata(4.0, FrameworkPropertyMetadataOptions.AffectsMeasure));
        public static readonly DependencyProperty MinColumnWidthProperty =
            DependencyProperty.Register(nameof(MinColumnWidth), typeof(double), typeof(CompactColumnsPanel),
                new FrameworkPropertyMetadata(180.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

        public double Spacing { get => (double)GetValue(SpacingProperty); set => SetValue(SpacingProperty, value); }
        public double MinColumnWidth { get => (double)GetValue(MinColumnWidthProperty); set => SetValue(MinColumnWidthProperty, value); }

        private int VisibleCount()
        {
            int n = 0;
            foreach (UIElement c in InternalChildren)
                if (c.Visibility != Visibility.Collapsed) n++;
            return n;
        }

        private int CalcColumns(double width, int visible)
        {
            if (visible <= 0) return 1;
            double sp = Math.Max(0, Spacing);
            double min = Math.Max(40, MinColumnWidth);
            int byWidth = (int)Math.Floor((width + sp) / (min + sp));
            return Math.Clamp(byWidth, 1, visible);
        }

        /// <summary>Считает прямоугольники плиток по уже измеренным DesiredSize.</summary>
        private (List<Rect?> rects, Size size) Layout(double width)
        {
            double sp = Math.Max(0, Spacing);
            int visible = VisibleCount();
            int cols = CalcColumns(width, visible);
            double cellW = Math.Max(1, (width - sp * (cols - 1)) / cols);

            var rowHeights = new List<double>();
            int idx = 0;
            foreach (UIElement c in InternalChildren)
            {
                if (c.Visibility == Visibility.Collapsed) continue;
                int row = idx / cols;
                while (rowHeights.Count <= row) rowHeights.Add(0);
                double h = c.DesiredSize.Height;
                if (h > rowHeights[row]) rowHeights[row] = h;
                idx++;
            }

            var rowY = new List<double>();
            double y = 0;
            foreach (double h in rowHeights) { rowY.Add(y); y += h + sp; }

            var rects = new List<Rect?>(InternalChildren.Count);
            idx = 0;
            foreach (UIElement c in InternalChildren)
            {
                if (c.Visibility == Visibility.Collapsed) { rects.Add(null); continue; }
                int row = idx / cols;
                int col = idx % cols;
                double rh = row < rowHeights.Count ? rowHeights[row] : c.DesiredSize.Height;
                double ry = row < rowY.Count ? rowY[row] : 0;
                rects.Add(new Rect(col * (cellW + sp), ry, cellW, rh));
                idx++;
            }

            double totalH = rowHeights.Count == 0
                ? 0
                : rowHeights.Sum() + sp * (rowHeights.Count - 1);
            return (rects, new Size(width, totalH));
        }

        protected override Size MeasureOverride(Size available)
        {
            double w = double.IsInfinity(available.Width) || available.Width <= 0
                ? 420
                : available.Width;
            int visible = VisibleCount();
            int cols = CalcColumns(w, visible);
            double cellW = Math.Max(1, (w - Math.Max(0, Spacing) * (cols - 1)) / cols);

            foreach (UIElement c in InternalChildren)
            {
                if (c.Visibility == Visibility.Collapsed) continue;
                c.Measure(new Size(cellW, double.PositiveInfinity));
            }

            var (_, size) = Layout(w);
            return size;
        }

        protected override Size ArrangeOverride(Size final)
        {
            double w = final.Width > 0 ? final.Width : 420;
            var (rects, size) = Layout(w);
            for (int i = 0; i < rects.Count; i++)
                if (rects[i] is Rect r) InternalChildren[i].Arrange(r);
            return new Size(w, size.Height);
        }
    }

    // ==================== PodpitkaModule ====================

    // ---------- Периоды ----------
    public readonly record struct Period(DateTime From, DateTime ToExclusive);

    public static class PodpitkaPeriods
    {
        public static readonly int[] IntervalsMin = { 10, 20, 30, 40, 50, 60, 120 };

        /// <summary>Последний ЗАКРЫТЫЙ отчётный период.
        /// По умолчанию 25-е → 24-е. Если заданы startDay/endDay — используются они.
        /// Поддерживаются любые комбинации, например: 1→31, 25→24, 15→14 и т.д.</summary>
        public static Period Report(DateTime now) => Report(now, 25, 24);

        public static Period Report(DateTime now, int startDay) => Report(now, startDay, startDay == 1 ? 31 : startDay - 1);

        /// <summary>
        /// Вычисляет последний ЗАКРЫТЫЙ отчётный период по произвольной паре день-начала / день-конца.
        /// startDay и endDay — числа от 1 до 31.
        /// Если startDay &lt;= endDay: период в пределах одного месяца (например 1→31, 1→15).
        /// Если startDay &gt; endDay: период переходит через границу месяца (например 25→24).
        /// Период считается закрытым, когда прошёл день-конца текущего кандидата.
        /// </summary>
        public static Period Report(DateTime now, int startDay, int endDay)
        {
            startDay = Math.Clamp(startDay, 1, 31);
            endDay = Math.Clamp(endDay, 1, 31);

            // Реальный день конца с учётом длины месяца (например, endDay=31 в феврале → 28/29)
            int LastDayOfMonth(DateTime d) => DateTime.DaysInMonth(d.Year, d.Month);
            int ClampDayToMonth(int day, DateTime monthDate) => Math.Min(day, LastDayOfMonth(monthDate));

            if (startDay <= endDay)
            {
                // Период в одном месяце: startDay..endDay этого месяца.
                // Закрыт, если сегодня > endDay (с учётом длины месяца).
                var candidateMonth = new DateTime(now.Year, now.Month, 1);
                int realEnd = ClampDayToMonth(endDay, candidateMonth);
                var endDate = new DateTime(now.Year, now.Month, realEnd);
                // Если конец ещё не наступил — берём предыдущий месяц
                if (now <= endDate)
                    candidateMonth = candidateMonth.AddMonths(-1);

                int realStart = ClampDayToMonth(startDay, candidateMonth);
                int realEndFinal = ClampDayToMonth(endDay, candidateMonth);
                var from = new DateTime(candidateMonth.Year, candidateMonth.Month, realStart);
                var toExclusive = new DateTime(candidateMonth.Year, candidateMonth.Month, realEndFinal).AddDays(1);
                return new Period(from, toExclusive);
            }
            else
            {
                // Период переходит через месяц: startDay в месяце A, endDay в месяце A+1.
                // Например 25→24: с 25 сентября по 24 октября.
                // Закрыт, когда прошёл endDay в месяце, следующем за месяцем старта.
                // Текущий кандидат: старт в прошлом месяце, конец в текущем.
                var startMonth = now.AddMonths(-1);
                int realStart = ClampDayToMonth(startDay, startMonth);
                var from = new DateTime(startMonth.Year, startMonth.Month, realStart);

                var endMonth = startMonth.AddMonths(1);
                int realEnd = ClampDayToMonth(endDay, endMonth);
                var endDate = new DateTime(endMonth.Year, endMonth.Month, realEnd);

                // Если период ещё не закрыт (сегодня <= endDate) — сдвигаем на месяц назад
                if (now <= endDate)
                {
                    startMonth = startMonth.AddMonths(-1);
                    realStart = ClampDayToMonth(startDay, startMonth);
                    from = new DateTime(startMonth.Year, startMonth.Month, realStart);
                    endMonth = startMonth.AddMonths(1);
                    realEnd = ClampDayToMonth(endDay, endMonth);
                    endDate = new DateTime(endMonth.Year, endMonth.Month, realEnd);
                }

                var toExclusive = endDate.AddDays(1);
                return new Period(from, toExclusive);
            }
        }

        /// <summary>Вчерашние сутки: 00:00 вчерашнего дня → 00:00 сегодняшнего дня (эксклюзивно).</summary>
        public static Period Yesterday(DateTime now) => new(now.Date.AddDays(-1), now.Date);

        /// <summary>Сегодня с 00:00 до начала текущего часа (эксклюзивно).
        /// Например, 15:30 → период 00:00–15:00 (15 полных часов).</summary>
        public static Period Today(DateTime now)
        {
            var hourStart = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 0);
            return new Period(now.Date, hourStart);
        }

        /// <summary>Прошлый полный час: от (час-1):00 до (час):00.
        /// Например, 15:30 → период 14:00–15:00.</summary>
        public static Period PrevHour(DateTime now)
        {
            var h = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 0);
            return new Period(h.AddHours(-1), h);
        }
    }

    // ---------- Пороги (сохраняются в settings.json) ----------
    public class VolumeThresholds
    {
        public double? ReportMin { get; set; } public double? ReportMax { get; set; }
        public double? DayMin { get; set; }    public double? DayMax { get; set; }
        public double? TodayMin { get; set; }  public double? TodayMax { get; set; }
        public double? HourMin { get; set; }   public double? HourMax { get; set; }
    }

   // ---------- Чтение объёмов (ЛЭРС УЧЁТ REST API) ----------
    public sealed class PodpitkaVolumeService
    {
        private readonly HttpClient _http;
        private readonly Func<string> _baseUrl;
        private readonly SemaphoreSlim _gate = new(6);

        private static readonly string[] TargetVolumeKeys =
        {
            "v_in", "V_in", "v1", "V1", "v_mu", "V_mu", "volume1", "volume", "v", "V",
            "m_in", "M_in", "m1", "M1", "m_mu", "M_mu", "mass1", "mass", "m", "M",
            "v_delta", "V_delta", "m_delta", "M_delta", "v_out", "V_out", "v2", "V2"
        };

        public PodpitkaVolumeService(HttpClient http, Func<string> baseUrl)
        {
            _http = http;
            _baseUrl = baseUrl;
        }

        /// <summary>
        /// Чтение суммарного объёма V1 за период через LERS REST API.
        /// Эндпоинт: /Data/MeasurePoints/{id}/Consumption/{start}/{end}
        /// Дата в формате yyyy-MM-dd (или yyyy-MM-ddTHH:mm:ss для часового).
        /// </summary>
        /// <param name="hourFilterFrom">Если задано — фильтровать почасовые записи по времени (от).</param>
        /// <param name="hourFilterTo">Если задано — фильтровать почасовые записи по времени (до, эксклюзивно).</param>
        public async Task<double?> SumV1Async(int pointId, DateTime from, DateTime to, bool hourly, CancellationToken ct,
            DateTime? hourFilterFrom = null, DateTime? hourFilterTo = null)
        {
            await _gate.WaitAsync(ct);
            try
            {
                string fromDate = from.ToString("yyyy-MM-dd");
                string toDate = to.ToString("yyyy-MM-dd");
                string kind = hourly ? "Hour" : "Day";

                // Основной формат: path-based (документированный в LERS REST API)
                string url = $"{_baseUrl()}/Data/MeasurePoints/{pointId}/Consumption/{fromDate}/{toDate}";

                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                using var res = await _http.SendAsync(req, ct);

                if (res.IsSuccessStatusCode)
                {
                    return await ParseLersConsumptionArray(res, hourFilterFrom, hourFilterTo);
                }

                // Фолбэк 1: query-based с dataKind
                string altUrl = $"{_baseUrl()}/Data/MeasurePoints/{pointId}/Consumption?start={fromDate}&end={toDate}&dataKind={kind}";
                using var altReq = new HttpRequestMessage(HttpMethod.Get, altUrl);
                using var altRes = await _http.SendAsync(altReq, ct);
                if (altRes.IsSuccessStatusCode)
                {
                    return await ParseLersConsumptionArray(altRes, hourFilterFrom, hourFilterTo);
                }

                // Фолбэк 2: startDate/endDate (старый формат)
                string altUrl2 = $"{_baseUrl()}/Data/MeasurePoints/{pointId}/Consumption?startDate={fromDate}&endDate={toDate}&dataKind={kind}";
                using var altReq2 = new HttpRequestMessage(HttpMethod.Get, altUrl2);
                using var altRes2 = await _http.SendAsync(altReq2, ct);
                if (altRes2.IsSuccessStatusCode)
                {
                    return await ParseLersConsumptionArray(altRes2, hourFilterFrom, hourFilterTo);
                }

                return null;
            }
            catch
            {
                return null;
            }
            finally
            {
                _gate.Release();
            }
        }

        /// <summary>
        /// Парсинг массива данных потребления из ответа LERS.
        /// Если заданы hourFilterFrom/hourFilterTo — фильтрует записи по timestamp,
        /// оставляя только те, что попадают в указанный часовой интервал.
        /// </summary>
        private static async Task<double?> ParseLersConsumptionArray(HttpResponseMessage response,
            DateTime? hourFilterFrom = null, DateTime? hourFilterTo = null)
        {
            var json = await response.Content.ReadAsStringAsync();
            if (string.IsNullOrWhiteSpace(json) || json.Trim() == "null" || json.Trim() == "[]") return null;

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            // Если сервер вернул один объект, а не массив — пробуем извлечь из него
            if (root.ValueKind == JsonValueKind.Object)
            {
                var singleVal = ExtractVolume(root);
                if (singleVal.HasValue) return singleVal;
            }

            JsonElement array = root;
            if (root.ValueKind != JsonValueKind.Array)
            {
                bool found = false;
                foreach (var prop in root.EnumerateObject())
                {
                    if (prop.Value.ValueKind == JsonValueKind.Array && prop.Value.GetArrayLength() > 0)
                    {
                        array = prop.Value;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            }

            double total = 0;
            bool hasData = false;

            foreach (var record in array.EnumerateArray())
            {
                // Фильтрация по времени записи (для часовых архивов)
                if (hourFilterFrom.HasValue || hourFilterTo.HasValue)
                {
                    if (!TryGetRecordDateTime(record, out var recDate)) continue;
                    if (hourFilterFrom.HasValue && recDate < hourFilterFrom.Value) continue;
                    if (hourFilterTo.HasValue && recDate >= hourFilterTo.Value) continue;
                }

                var val = ExtractVolume(record);
                if (val.HasValue)
                {
                    total += val.Value;
                    hasData = true;
                }
            }

            return hasData ? total : null;
        }

        /// <summary>Извлекает дату/время из записи потребления LERS.
        /// LERS использует поля: dateTime, date, targetDate, hour, timestamp.</summary>
        private static bool TryGetRecordDateTime(JsonElement record, out DateTime result)
        {
            // Прямые поля с датой
            foreach (var name in new[] { "dateTime", "date", "targetDate", "timestamp", "d" })
            {
                if (record.TryGetProperty(name, out var p))
                {
                    if (p.TryGetDateTime(out var dt)) { result = dt; return true; }
                    if (p.ValueKind == JsonValueKind.String && DateTime.TryParse(p.GetString(), out var s)) { result = s; return true; }
                }
            }
            result = default;
            return false;
        }

        public async Task<double?> GetLastInstantVolumeAsync(int pointId, CancellationToken ct)
        {
            await _gate.WaitAsync(ct);
            try
            {
                using var res = await _http.GetAsync($"{_baseUrl()}/Data/MeasurePoints/{pointId}/Consumption/Last", ct);
                if (!res.IsSuccessStatusCode) return null;
                var json = await res.Content.ReadAsStringAsync(ct);
                if (string.IsNullOrWhiteSpace(json) || json.Trim() == "null") return null;
                using var doc = JsonDocument.Parse(json);
                return ExtractVolume(doc.RootElement);
            }
            catch
            {
                return null;
            }
            finally
            {
                _gate.Release();
            }
        }

        public static double? ExtractVolume(JsonElement elem)
        {
            if (elem.ValueKind != JsonValueKind.Object) return null;

            // 1. Прямые поля объекта
            foreach (var key in TargetVolumeKeys)
            {
                if (elem.TryGetProperty(key, out var prop))
                {
                    if (prop.ValueKind == JsonValueKind.Number && prop.TryGetDouble(out var d)) return d;
                    if (prop.ValueKind == JsonValueKind.String && double.TryParse(prop.GetString()?.Replace(",", "."), NumberStyles.Any, CultureInfo.InvariantCulture, out var s)) return s;
                }
            }

            // 2. Вложенные массивы параметров ЛЭРС [{ dataParameter: "V_in", value: 11.0 }]
            foreach (var prop in elem.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in prop.Value.EnumerateArray())
                    {
                        if (item.ValueKind != JsonValueKind.Object) continue;
                        string param = "";
                        if (item.TryGetProperty("dataParameter", out var dp)) param = dp.GetString() ?? "";
                        else if (item.TryGetProperty("parameter", out var p)) param = p.GetString() ?? "";
                        else if (item.TryGetProperty("name", out var n)) param = n.GetString() ?? "";

                        if (TargetVolumeKeys.Any(k => k.Equals(param, StringComparison.OrdinalIgnoreCase)))
                        {
                            if (item.TryGetProperty("value", out var valProp) || item.TryGetProperty("val", out valProp))
                            {
                                if (valProp.ValueKind == JsonValueKind.Number && valProp.TryGetDouble(out var d)) return d;
                                if (valProp.ValueKind == JsonValueKind.String && double.TryParse(valProp.GetString()?.Replace(",", "."), NumberStyles.Any, CultureInfo.InvariantCulture, out var s)) return s;
                            }
                        }
                    }
                }
            }

            // 3. Если есть поле value и нет других параметров — пробуем как прямой объём
            if (elem.TryGetProperty("value", out var vProp) && vProp.ValueKind == JsonValueKind.Number && vProp.TryGetDouble(out var v))
                return v;

            return null;
        }

        public async Task RefreshAsync(PodpitkaPointViewModel vm, DateTime now, CancellationToken ct)
        {
            int startDay = MainWindow.AppSettings?.ReportPeriodStartDay ?? 25;
            int endDay = MainWindow.AppSettings?.ReportPeriodEndDay ?? 24;
            var r = PodpitkaPeriods.Report(now, startDay, endDay);
            var y = PodpitkaPeriods.Yesterday(now);
            var t = PodpitkaPeriods.Today(now);
            var h = PodpitkaPeriods.PrevHour(now);

            // 1. Отчётный период (например 25→24): суточный архив Day за весь период
            var taskReport = SumV1Async(vm.Id, r.From, r.ToExclusive.AddDays(-1), false, ct);

            // 2. Вчера: суточный архив Day за вчерашний день
            var taskDay = SumV1Async(vm.Id, y.From, y.From, false, ct);

            // 3. Сегодня: часовой архив Hour, суммируем только часы с 00:00 до текущего часа
            //    LERS вернёт все часы за день → фильтруем по t.From..t.ToExclusive
            var taskToday = now.Hour > 0
                ? SumV1Async(vm.Id, t.From, t.ToExclusive, true, ct, t.From, t.ToExclusive)
                : Task.FromResult<double?>(null);

            // 4. Прошлый час: часовой архив Hour за один конкретный час
            //    LERS вернёт все часы за день → фильтруем по h.From..h.ToExclusive (один час)
            var taskHour = SumV1Async(vm.Id, h.From, h.ToExclusive, true, ct, h.From, h.ToExclusive);

            await Task.WhenAll(taskReport, taskDay, taskToday, taskHour);

            double? rep = taskReport.Result;
            double? day = taskDay.Result;
            double? today = taskToday.Result;
            double? hour = taskHour.Result;

            // Если часовой архив за неполный час ещё не успел записаться в базу, берём оперативный срез
            if (!hour.HasValue)
            {
                hour = await GetLastInstantVolumeAsync(vm.Id, ct);
            }

            // Если "сегодня" не вернуло данных, но есть часовой срез — используем его
            if (!today.HasValue && hour.HasValue)
            {
                today = hour;
            }

            // Не перезаписываем day значением today!
            vm.SetVolumes(rep, day, today, hour, DateTime.Now);
        }
    }
    // ---------- ViewModel ----------
    public class PodpitkaPointViewModel : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        private void On([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

        public int Id { get; init; }
        public string Title { get; init; } = "";
        public string NodeTitle { get; init; } = "";
        public VolumeThresholds? Limits { get; set; }

        private PollState _state = PollState.Pending; public PollState State { get => _state; set { _state = value; On(); On(nameof(IsDone)); On(nameof(HasError)); On(nameof(RetryVisibility)); On(nameof(PointTitleColor)); } }
        private string _message = "Ожидание..."; public string Message { get => _message; set { _message = value; On(); } }
        public bool IsDone => State is PollState.Ok or PollState.OkCached or PollState.Error;
        public bool HasError => State == PollState.Error;
        public Visibility RetryVisibility => HasError ? Visibility.Visible : Visibility.Collapsed;

        public double? Report { get; private set; } public double? Day { get; private set; }
        public double? Today { get; private set; }  public double? Hour { get; private set; }
        public DateTime? UpdatedAt { get; private set; }

        public void SetVolumes(double? rep, double? day, double? today, double? hour, DateTime at)
        {
            Report = rep; Day = day; Today = today; Hour = hour; UpdatedAt = at;
            On(nameof(Report)); On(nameof(Day)); On(nameof(Today)); On(nameof(Hour)); On(nameof(UpdatedAt));
            RefreshColors();
        }

        /// <summary>Обновить часовой срез и "сегодня" после опроса прибора.</summary>
        public void UpdateHour(double? today, double hourValue)
        {
            Hour = hourValue;
            if (today.HasValue) Today = today;
            else if (!Today.HasValue) Today = hourValue;
            UpdatedAt = DateTime.Now;
            On(nameof(Hour)); On(nameof(Today)); On(nameof(UpdatedAt));
            RefreshColors();
        }

        public static bool Out(double? v, double? min, double? max) =>
            v.HasValue && ((min.HasValue && v < min) || (max.HasValue && v > max));

        public bool ReportBreach => Out(Report, Limits?.ReportMin, Limits?.ReportMax);
        public bool DayBreach    => Out(Day,    Limits?.DayMin,    Limits?.DayMax);
        public bool TodayBreach  => Out(Today,  Limits?.TodayMin,  Limits?.TodayMax);
        public bool HourBreach   => Out(Hour,   Limits?.HourMin,   Limits?.HourMax);
        public bool HasBreach => ReportBreach || DayBreach || TodayBreach || HourBreach;

        private static Brush Res(string k) => (Brush)Application.Current.MainWindow.FindResource(k);
        private Brush Bg(bool breach) => breach ? Res("AccentRed") : (IsDone ? (HasError ? Res("AccentOrange") : Res("AccentGreen")) : Res("AccentGray"));
        public Brush ReportBg => Bg(ReportBreach); public Brush DayBg => Bg(DayBreach);
        public Brush TodayBg => Bg(TodayBreach);   public Brush HourBg => Bg(HourBreach);
        public Brush ReportFg => ReportBreach ? Brushes.Yellow : Brushes.White; public Brush DayFg => DayBreach ? Brushes.Yellow : Brushes.White;
        public Brush TodayFg => TodayBreach ? Brushes.Yellow : Brushes.White;   public Brush HourFg => HourBreach ? Brushes.Yellow : Brushes.White;
        public Brush PointTitleColor => HasBreach ? Res("AccentRed") : HasError ? Res("AccentOrange") : !IsDone ? Res("AccentGray") : Brushes.White;

        public void RefreshColors() => On(null);
    }

    public class PodpitkaNodeViewModel : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        public string NodeTitle { get; init; } = "";
        public ObservableCollection<PodpitkaPointViewModel> Points { get; } = new();
        public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

        public Brush TileBackground
        {
            get
            {
                Brush R(string k) => (Brush)Application.Current.MainWindow.FindResource(k);
                if (Points.Any(p => !p.IsDone)) return R("AccentGray");
                if (Points.Any(p => p.HasBreach)) return R("AccentRed");
                if (Points.Any(p => p.HasError)) return R("AccentOrange");
                return R("AccentGreen");
            }
        }
        public string GeneralStatus =>
            Points.Any(p => !p.IsDone) ? $"Опрошено {Points.Count(p => p.IsDone)} из {Points.Count}" :
            Points.FirstOrDefault(p => p.HasError)?.Message ?? "Опрошено успешно";
    }

    // ==================== Poll Details Window ====================

    public sealed class PollDetailsWindow : Window
    {
        private readonly System.Windows.Threading.DispatcherTimer _timer;
        private readonly int _pointId;
        private readonly string _pointTitle;
        private readonly PollLogStore _logStore;
        private readonly ScrollViewer _scrollViewer;
        private readonly StackPanel _logPanel;

        public PollDetailsWindow(int pointId, string pointTitle, PollLogStore logStore)
        {
            _pointId = pointId;
            _pointTitle = pointTitle;
            _logStore = logStore;

            Title = $"Ход опроса — {pointTitle}";
            Width = 560;
            Height = 500;
            MinWidth = 380;
            MinHeight = 260;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.CanResize;

            // Try to get theme brushes, fallback to safe defaults
            var bgBrush = TryFindRes("SystemBackground") ?? TryFindRes("CardBackground") ?? Brushes.White;
            var fgBrush = TryFindRes("LabelPrimary") ?? Brushes.Black;

            Background = bgBrush;

            var grid = new Grid { Margin = new Thickness(10) };
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            // Header
            var header = new TextBlock
            {
                Text = $"Точка: {pointTitle} (ID: {pointId})",
                FontSize = 14,
                FontWeight = FontWeights.Bold,
                Foreground = fgBrush,
                Margin = new Thickness(0, 0, 0, 8)
            };
            Grid.SetRow(header, 0);
            grid.Children.Add(header);

            // Scrollable log panel
            _logPanel = new StackPanel { Orientation = Orientation.Vertical };
            _scrollViewer = new ScrollViewer
            {
                Content = _logPanel,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                Background = bgBrush,
                Padding = new Thickness(4),
                BorderThickness = new Thickness(1),
                BorderBrush = TryFindRes("AccentGray") ?? Brushes.LightGray,
            };
            Grid.SetRow(_scrollViewer, 1);
            grid.Children.Add(_scrollViewer);

            // Buttons panel
            var btnPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 8, 0, 0)
            };

            var btnRefresh = new Button { Content = "Обновить", Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(12, 4, 12, 4) };
            btnRefresh.Click += (s, e) => RefreshLog();
            btnPanel.Children.Add(btnRefresh);

            var btnClear = new Button { Content = "Очистить", Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(12, 4, 12, 4) };
            btnClear.Click += (s, e) => { _logStore.Clear(_pointId); RefreshLog(); };
            btnPanel.Children.Add(btnClear);

            var btnClose = new Button { Content = "Закрыть", Padding = new Thickness(12, 4, 12, 4), IsCancel = true };
            btnClose.Click += (s, e) => Close();
            btnPanel.Children.Add(btnClose);

            Grid.SetRow(btnPanel, 2);
            grid.Children.Add(btnPanel);

            Content = grid;

            // Auto-refresh timer
            _timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (s, e) => RefreshLog();
            _timer.Start();

            Closed += (s, e) => _timer.Stop();

            Loaded += (s, e) => RefreshLog();
        }

        private static Brush? TryFindRes(string key)
        {
            try
            {
                if (Application.Current?.MainWindow != null)
                    return Application.Current.MainWindow.TryFindResource(key) as Brush;
            }
            catch { }
            return null;
        }

        private static Brush StateBrush(PollState state)
        {
            return state switch
            {
                PollState.Ok or PollState.OkCached => TryFindRes("AccentGreen") ?? Brushes.Green,
                PollState.Error => TryFindRes("AccentRed") ?? Brushes.Red,
                PollState.Polling => TryFindRes("AccentOrange") ?? Brushes.Orange,
                PollState.Queued => TryFindRes("AccentGray") ?? Brushes.Gray,
                _ => TryFindRes("AccentGray") ?? Brushes.Gray,
            };
        }

        private void RefreshLog()
        {
            var entries = _logStore.Get(_pointId);
            _logPanel.Children.Clear();

            var fgBrush = TryFindRes("LabelPrimary") ?? Brushes.Black;

            if (entries.Count == 0)
            {
                _logPanel.Children.Add(new TextBlock
                {
                    Text = "Записей нет. Запустите опрос точки.",
                    FontSize = 12,
                    Foreground = fgBrush,
                    Margin = new Thickness(4),
                    FontStyle = FontStyles.Italic,
                    Opacity = 0.6
                });
                return;
            }

            foreach (var entry in entries)
            {
                // Each entry: a horizontal row with colored dot + text
                var row = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Margin = new Thickness(2),
                };

                // Colored dot (small ellipse via Border)
                var dot = new Border
                {
                    Width = 8,
                    Height = 8,
                    CornerRadius = new CornerRadius(4),
                    Background = StateBrush(entry.State),
                    Margin = new Thickness(0, 4, 6, 0),
                    VerticalAlignment = VerticalAlignment.Top
                };
                row.Children.Add(dot);

                // Text
                var text = new TextBlock
                {
                    Text = $"{entry.Timestamp:HH:mm:ss}  [{entry.Phase}]  {entry.Message}",
                    FontFamily = new FontFamily("Consolas, Courier New"),
                    FontSize = 12,
                    Foreground = fgBrush,
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Top
                };
                row.Children.Add(text);

                _logPanel.Children.Add(row);
            }

            // Auto-scroll to bottom
            _scrollViewer.ScrollToBottom();
        }
    }

    /// <summary>Мелкие вспомогательные расширения строк.</summary>
    internal static class StringExtensions
    {
        /// <summary>Первая буква заглавная, остальные — как есть. "часовые" → "Часовые".</summary>
        public static string capitalize(this string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            return char.ToUpper(s[0], CultureInfo.CurrentCulture) + s.Substring(1);
        }
    }

}
