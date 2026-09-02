using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Xml;
using IOPath = System.IO.Path;

[assembly: AssemblyTitle("ProxyNodeAssistant")]
[assembly: AssemblyProduct("ProxyNodeAssistant")]
[assembly: AssemblyDescription("Privacy-first graphical VPS node assistant")]
[assembly: AssemblyVersion("1.0.0.100")]
[assembly: AssemblyFileVersion("1.0.0.100")]
[assembly: AssemblyInformationalVersion("1.0.0-reset-r105")]

namespace ProxyNodeAssistant.Gui
{
    internal sealed class OperationInfo
    {
        public string Id;
        public string Category;
        public string ZhTitle;
        public string EnTitle;
        public string ZhDescription;
        public string EnDescription;
        public string Accent;

        public string Title(bool english)
        {
            return english ? EnTitle : ZhTitle;
        }

        public string Description(bool english)
        {
            return english ? EnDescription : ZhDescription;
        }
    }

    internal sealed class MainController
    {
        private const string Version = "1.0.0";
        private const string CliResourceName = "ProxyNodeAssistant.Cli.exe";
        private const string AskPassResourceName = "ProxyNodeAssistant.AskPass.exe";
        private const string TunnelSessionMarker = "PANEL_TUNNEL_SESSION_ACTIVE";
        private const string GuiPromptPrefix = "PNA_GUI_PROMPT_B64=";
        private const string GuiSecretPromptPrefix = "PNA_GUI_SECRET_B64=";

        // The ARM64 GUI is compiled as AnyCPU by the legacy .NET Framework
        // compiler.  That means it can start on an x64 machine even though
        // its embedded Go workflow engine is ARM64-only.  Windows otherwise
        // reports this late as a generic "invalid image" dialog.  Inspect the
        // embedded PE machine before extracting/starting it so the user gets
        // an actionable architecture message instead.
        private const ushort ImageFileMachineI386 = 0x014c;
        private const ushort ImageFileMachineAmd64 = 0x8664;
        private const ushort ImageFileMachineArm64 = 0xAA64;
        private const ushort ProcessorArchitectureIntel = 0;
        private const ushort ProcessorArchitectureAmd64 = 9;
        private const ushort ProcessorArchitectureArm64 = 12;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSystemInfo
        {
            public ushort ProcessorArchitecture;
            public ushort Reserved;
            public uint PageSize;
            public IntPtr MinimumApplicationAddress;
            public IntPtr MaximumApplicationAddress;
            public IntPtr ActiveProcessorMask;
            public uint NumberOfProcessors;
            public uint ProcessorType;
            public uint AllocationGranularity;
            public ushort ProcessorLevel;
            public ushort ProcessorRevision;
        }

        [DllImport("kernel32.dll")]
        private static extern void GetNativeSystemInfo(out NativeSystemInfo systemInfo);

        private sealed class RuntimeFiles
        {
            public string CliPath;
            public string AskPassPath;
        }

        private sealed class AskPassRequest
        {
            public readonly ManualResetEvent Completed = new ManualResetEvent(false);
            public string Prompt;
            public string Password;
            public bool Cancelled;
        }

        private sealed class RecentTarget
        {
            public string Host;
            public string User;
            public int Port;
            public DateTime LastUsedUtc;

            public override string ToString()
            {
                return User + "@" + Host + ":" + Port + "  ·  " + LastUsedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm");
            }
        }

        private readonly Application app;
        private readonly Window window;
        private readonly List<OperationInfo> operations;
        private readonly Dictionary<string, Button> navigation = new Dictionary<string, Button>();
        private WrapPanel cardsPanel;
        private TextBlock openSSHStatusText;
        private Ellipse openSSHDot;
        private TextBlock footerStatus;
        private TextBlock visibleCount;
        private Border operationWorkspace;
        private Border operationLaunchPanel;
        private Border operationLogPanel;
        private Border operationInputPanel;
        private Grid remoteConnectionForm;
        private TextBlock operationHeaderTitle;
        private TextBlock operationHeaderSubtitle;
        private TextBlock operationSetupTitle;
        private TextBlock operationSetupDescription;
        private TextBlock operationLaunchHint;
        private TextBlock operationStatusText;
        private TextBlock operationPromptText;
        private TextBlock operationFooterText;
        private Ellipse operationStatusDot;
        private TextBox connectionHostInput;
        private TextBox connectionUserInput;
        private TextBox connectionPortInput;
        private ComboBox connectionAuthMode;
        private ComboBox connectionHistory;
        private Button historyUseButton;
        private Button historyDeleteButton;
        private Button historyClearButton;
        private TextBlock historyFieldLabel;
        private TextBlock historyPrivacyNote;
        private readonly List<RecentTarget> recentTargets = new List<RecentTarget>();
        private TextBox operationLog;
        private TextBox operationInput;
        private PasswordBox operationSecretInput;
        private Button operationStartButton;
        private Button operationBackButton;
        private Button operationSendButton;
        private Button operationStopButton;
        private Button operationYesButton;
        private Button operationNoButton;
        private Button operationEnterButton;
        private Grid askPassOverlay;
        private TextBlock askPassPrompt;
        private PasswordBox askPassPassword;
        private Process activeProcess;
        private OperationInfo activeOperation;
        private bool operationRunning;
        private bool fullMenuMode;
        private bool safeStopRequested;
        private bool tunnelSessionActive;
        private bool operationInputPending;
        private int suppressedPromptFrames;
        private string askPassPipeName;
        private Thread askPassThread;
        private volatile bool askPassStopping;
        private NamedPipeServerStream activePipeServer;
        private AskPassRequest currentAskPassRequest;
        private Action<int> workflowSmokeCompletion;
        private string askPassSmokeResponse;
        private string backendArgumentsOverride;
        private readonly object processGate = new object();
        private string currentCategory = "all";
        private bool english;

        public MainController(Application application, Window mainWindow)
        {
            app = application;
            window = mainWindow;
            operations = CreateOperations();
            english = LoadLanguage();
        }

        public void Initialize(bool probeOpenSSH)
        {
            cardsPanel = Find<WrapPanel>("CardsPanel");
            openSSHStatusText = Find<TextBlock>("OpenSSHStatusText");
            openSSHDot = Find<Ellipse>("OpenSSHDot");
            footerStatus = Find<TextBlock>("FooterStatus");
            visibleCount = Find<TextBlock>("VisibleCount");
            InitializeOperationWorkspace();

            Button closeButton = Find<Button>("CloseButton");
            Button minimizeButton = Find<Button>("MinimizeButton");
            Button maximizeButton = Find<Button>("MaximizeButton");
            Button languageButton = Find<Button>("LanguageButton");
            Border titleBar = Find<Border>("TitleBar");

            closeButton.Click += delegate { window.Close(); };
            minimizeButton.Click += delegate { window.WindowState = WindowState.Minimized; };
            maximizeButton.Click += delegate { ToggleMaximize(); };
            languageButton.Click += delegate { english = !english; SaveLanguage(); UpdateLanguage(); };
            window.Closing += WindowClosing;
            window.PreviewKeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.F5 && operationWorkspace.Visibility == Visibility.Visible && !operationRunning)
                {
                    args.Handled = true;
                    StartSelectedOperation();
                }
                else if (args.Key == Key.Escape && operationWorkspace.Visibility == Visibility.Visible && !operationRunning)
                {
                    args.Handled = true;
                    ReturnToDashboard();
                }
            };
            titleBar.MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs args)
            {
                if (args.ClickCount == 2)
                {
                    ToggleMaximize();
                    return;
                }
                if (args.ButtonState == MouseButtonState.Pressed)
                {
                    try { window.DragMove(); } catch { }
                }
            };

            RegisterNavigation("all", "NavAll");
            RegisterNavigation("install", "NavInstall");
            RegisterNavigation("access", "NavAccess");
            RegisterNavigation("maintain", "NavMaintain");
            RegisterNavigation("security", "NavSecurity");
            RegisterNavigation("backup", "NavBackup");
            RegisterNavigation("local", "NavLocal");

            Find<Button>("QuickInstall").Click += delegate { LaunchAction("1"); };
            Find<Button>("QuickDiagnose").Click += delegate { LaunchAction("3"); };
            Find<Button>("OpenTerminal").Click += delegate { OpenOperationWorkspace(null, true); };

            UpdateLanguage();
            if (probeOpenSSH) BeginOpenSSHProbe();
        }

        private void InitializeOperationWorkspace()
        {
            operationWorkspace = Find<Border>("OperationWorkspace");
            operationLaunchPanel = Find<Border>("OperationLaunchPanel");
            operationLogPanel = Find<Border>("OperationLogPanel");
            operationInputPanel = Find<Border>("OperationInputPanel");
            remoteConnectionForm = Find<Grid>("RemoteConnectionForm");
            operationHeaderTitle = Find<TextBlock>("OperationHeaderTitle");
            operationHeaderSubtitle = Find<TextBlock>("OperationHeaderSubtitle");
            operationSetupTitle = Find<TextBlock>("OperationSetupTitle");
            operationSetupDescription = Find<TextBlock>("OperationSetupDescription");
            operationLaunchHint = Find<TextBlock>("OperationLaunchHint");
            operationStatusText = Find<TextBlock>("OperationStatusText");
            operationPromptText = Find<TextBlock>("OperationPromptText");
            operationFooterText = Find<TextBlock>("OperationFooterText");
            operationStatusDot = Find<Ellipse>("OperationStatusDot");
            connectionHostInput = Find<TextBox>("ConnectionHostInput");
            connectionUserInput = Find<TextBox>("ConnectionUserInput");
            connectionPortInput = Find<TextBox>("ConnectionPortInput");
            connectionAuthMode = Find<ComboBox>("ConnectionAuthMode");
            connectionHistory = Find<ComboBox>("ConnectionHistory");
            historyUseButton = Find<Button>("HistoryUseButton");
            historyDeleteButton = Find<Button>("HistoryDeleteButton");
            historyClearButton = Find<Button>("HistoryClearButton");
            historyFieldLabel = Find<TextBlock>("HistoryFieldLabel");
            historyPrivacyNote = Find<TextBlock>("HistoryPrivacyNote");
            operationLog = Find<TextBox>("OperationLog");
            operationInput = Find<TextBox>("OperationInput");
            operationSecretInput = Find<PasswordBox>("OperationSecretInput");
            operationStartButton = Find<Button>("OperationStartButton");
            operationBackButton = Find<Button>("OperationBackButton");
            operationSendButton = Find<Button>("OperationSendButton");
            operationStopButton = Find<Button>("OperationStopButton");
            operationYesButton = Find<Button>("OperationYesButton");
            operationNoButton = Find<Button>("OperationNoButton");
            operationEnterButton = Find<Button>("OperationEnterButton");
            askPassOverlay = Find<Grid>("AskPassOverlay");
            askPassPrompt = Find<TextBlock>("AskPassPrompt");
            askPassPassword = Find<PasswordBox>("AskPassPassword");

            operationStartButton.Click += delegate { StartSelectedOperation(); };
            operationBackButton.Click += delegate { ReturnToDashboard(); };
            operationSendButton.Click += delegate { SendOperationInput(null); };
            operationStopButton.Click += delegate { RequestOperationStop(); };
            operationYesButton.Click += delegate { SendOperationInput("y"); };
            operationNoButton.Click += delegate { SendOperationInput("n"); };
            operationEnterButton.Click += delegate { SendOperationInput(""); };
            historyUseButton.Click += delegate { ApplySelectedRecentTarget(); };
            historyDeleteButton.Click += delegate { RunHistoryAction(new Action(DeleteSelectedRecentTarget)); };
            historyClearButton.Click += delegate { RunHistoryAction(new Action(ClearRecentTargetsWithConfirmation)); };
            connectionHistory.SelectionChanged += delegate { UpdateHistoryButtons(); };
            Find<Button>("OperationCopyLogButton").Click += delegate { CopyOperationLog(); };
            Find<Button>("OperationClearLogButton").Click += delegate { operationLog.Clear(); };
            Find<Button>("OperationMinimizeButton").Click += delegate { window.WindowState = WindowState.Minimized; };
            Find<Button>("OperationMaximizeButton").Click += delegate { ToggleMaximize(); };
            Find<Button>("OperationCloseButton").Click += delegate { window.Close(); };
            Find<Button>("AskPassSubmitButton").Click += delegate { CompleteAskPass(false); };
            Find<Button>("AskPassCancelButton").Click += delegate { CompleteAskPass(true); };

            operationInput.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Enter)
                {
                    args.Handled = true;
                    SendOperationInput(null);
                }
            };
            operationSecretInput.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Enter)
                {
                    args.Handled = true;
                    SendOperationInput(null);
                }
            };
            askPassPassword.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.Key == Key.Enter)
                {
                    args.Handled = true;
                    CompleteAskPass(false);
                }
            };
        }

        private void WindowClosing(object sender, CancelEventArgs args)
        {
            if (!operationRunning) return;
            args.Cancel = true;
            MessageBox.Show(window,
                english ? "An operation is still running. Use Safe stop in the operation workspace before closing the app."
                        : "当前仍有操作正在执行。请先在操作工作区使用“安全停止”，再关闭程序。",
                "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private T Find<T>(string name) where T : class
        {
            T value = window.FindName(name) as T;
            if (value == null)
            {
                throw new InvalidOperationException("GUI element is missing: " + name);
            }
            return value;
        }

        private static string RecentTargetsPath()
        {
            string overridePath = Environment.GetEnvironmentVariable("PNA_HISTORY_PATH");
            if (!String.IsNullOrWhiteSpace(overridePath)) return IOPath.GetFullPath(overridePath.Trim());
            string root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return IOPath.Combine(root, "ProxyNodeAssistant", "recent-targets.tsv");
        }

        private static List<string> RecentTargetsReadPaths()
        {
            string overridePath = Environment.GetEnvironmentVariable("PNA_HISTORY_PATH");
            if (!String.IsNullOrWhiteSpace(overridePath)) return new List<string> { RecentTargetsPath() };
            string root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return new List<string>
            {
                IOPath.Combine(root, "ProxyNodeAssistant", "recent-targets.tsv"),
                IOPath.Combine(root, "TextNodeAssistant", "recent-targets.tsv")
            };
        }

        private static bool ValidRecentTarget(RecentTarget target)
        {
            return target != null && Regex.IsMatch(target.Host ?? "", "^[A-Za-z0-9._:-]+$") &&
                   Regex.IsMatch(target.User ?? "", "^[A-Za-z_][A-Za-z0-9_.-]*$") &&
                   target.Port >= 1 && target.Port <= 65535;
        }

        private static string RecentTargetKey(RecentTarget target)
        {
            return (target.Host ?? "").ToLowerInvariant() + "\0" + (target.User ?? "") + "\0" + target.Port;
        }

        // Keep the GUI's managed-key probe aligned with the toolkit's
        // per-node key layout.  This is intentionally a presence-only check:
        // private-key contents are never read or displayed, and a missing key
        // leaves authentication unselected so the user must choose a method.
        private static string ManagedKeyPart(string value)
        {
            string cleaned = Regex.Replace(value ?? "", "[^A-Za-z0-9._-]+", "_").Trim('_');
            return String.IsNullOrEmpty(cleaned) ? "node" : cleaned;
        }

        private static bool HasManagedKey(RecentTarget target)
        {
            if (target == null) return false;
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (String.IsNullOrWhiteSpace(home)) return false;
            string leaf = ManagedKeyPart(target.Host) + "-" + ManagedKeyPart(target.User);
            string[] roots =
            {
                IOPath.Combine(home, ".ssh", "proxy-runbook"),
                IOPath.Combine(home, ".ssh", "text-node-assistant")
            };
            foreach (string root in roots)
            {
                string privateKey = IOPath.Combine(root, leaf, "id_ed25519");
                if (File.Exists(privateKey) && File.Exists(privateKey + ".pub")) return true;
            }
            return false;
        }

        private static List<RecentTarget> LoadRecentTargets()
        {
            List<RecentTarget> values = new List<RecentTarget>();
            foreach (string path in RecentTargetsReadPaths())
            {
                if (!File.Exists(path)) continue;
                foreach (string line in File.ReadAllLines(path, Encoding.UTF8))
                {
                    string[] fields = line.Split('\t');
                    int port;
                    DateTime used;
                    if (fields.Length != 4 || !Int32.TryParse(fields[2], out port) ||
                        !DateTime.TryParse(fields[3], null, System.Globalization.DateTimeStyles.RoundtripKind, out used)) continue;
                    RecentTarget target = new RecentTarget { Host = fields[0].Trim(), User = fields[1].Trim(), Port = port, LastUsedUtc = used.ToUniversalTime() };
                    if (ValidRecentTarget(target)) values.Add(target);
                }
            }
            values.Sort(delegate(RecentTarget left, RecentTarget right) { return right.LastUsedUtc.CompareTo(left.LastUsedUtc); });
            List<RecentTarget> normalized = new List<RecentTarget>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (RecentTarget target in values)
            {
                if (seen.Add(RecentTargetKey(target))) normalized.Add(target);
                if (normalized.Count == 20) break;
            }
            return normalized;
        }

        private static void SaveRecentTargets(List<RecentTarget> values)
        {
            string path = RecentTargetsPath();
            Directory.CreateDirectory(IOPath.GetDirectoryName(path));
            StringBuilder data = new StringBuilder();
            int count = 0;
            foreach (RecentTarget target in values)
            {
                if (!ValidRecentTarget(target)) continue;
                data.Append(target.Host).Append('\t').Append(target.User).Append('\t').Append(target.Port).Append('\t')
                    .Append(target.LastUsedUtc.ToUniversalTime().ToString("o")).Append('\n');
                if (++count == 20) break;
            }
            string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temporary, data.ToString(), new UTF8Encoding(false));
            try
            {
                if (File.Exists(path)) File.Delete(path);
                File.Move(temporary, path);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
            // Once the canonical file is written, remove only the old
            // non-secret history file so deleted legacy entries cannot return
            // on the next merged read.
            foreach (string legacy in RecentTargetsReadPaths())
            {
                if (!String.Equals(legacy, path, StringComparison.OrdinalIgnoreCase))
                {
                    try { if (File.Exists(legacy)) File.Delete(legacy); } catch { }
                }
            }
        }

        private void RefreshRecentTargets(bool applyLatest)
        {
            recentTargets.Clear();
            connectionHistory.Items.Clear();
            try
            {
                recentTargets.AddRange(LoadRecentTargets());
                foreach (RecentTarget target in recentTargets) connectionHistory.Items.Add(target);
                if (recentTargets.Count > 0)
                {
                    connectionHistory.SelectedIndex = 0;
                    if (applyLatest) ApplySelectedRecentTarget();
                }
            }
            catch (Exception error)
            {
                footerStatus.Text = (english ? "Could not read VPS history: " : "读取 VPS 历史失败：") + error.Message;
            }
            UpdateHistoryButtons();
        }

        private void UpdateHistoryButtons()
        {
            bool selected = connectionHistory != null && connectionHistory.SelectedItem is RecentTarget;
            if (historyUseButton != null) historyUseButton.IsEnabled = selected;
            if (historyDeleteButton != null) historyDeleteButton.IsEnabled = selected;
            if (historyClearButton != null) historyClearButton.IsEnabled = recentTargets.Count > 0;
        }

        private void ApplySelectedRecentTarget()
        {
            RecentTarget target = connectionHistory.SelectedItem as RecentTarget;
            if (target == null) return;
            connectionHostInput.Text = target.Host;
            connectionUserInput.Text = target.User;
            connectionPortInput.Text = target.Port.ToString();
            // Selecting a target may change which local managed key is
            // available.  A key is selected only when its pair is present;
            // otherwise the user must explicitly choose a login method.
            connectionAuthMode.SelectedIndex = HasManagedKey(target) ? 2 : 0;
        }

        private void RunHistoryAction(Action action)
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                MessageBox.Show(window,
                    (english ? "VPS history could not be changed:\n\n" : "无法修改 VPS 历史：\n\n") + error.Message,
                    "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void RememberRecentTarget(string host, string user, int port)
        {
            RecentTarget latest = new RecentTarget { Host = host, User = user, Port = port, LastUsedUtc = DateTime.UtcNow };
            List<RecentTarget> values = LoadRecentTargets();
            string key = RecentTargetKey(latest);
            values.RemoveAll(delegate(RecentTarget value) { return RecentTargetKey(value) == key; });
            values.Insert(0, latest);
            if (values.Count > 20) values.RemoveRange(20, values.Count - 20);
            SaveRecentTargets(values);
            RefreshRecentTargets(false);
        }

        private void DeleteSelectedRecentTarget()
        {
            RecentTarget selected = connectionHistory.SelectedItem as RecentTarget;
            if (selected == null) return;
            List<RecentTarget> values = LoadRecentTargets();
            string key = RecentTargetKey(selected);
            values.RemoveAll(delegate(RecentTarget value) { return RecentTargetKey(value) == key; });
            SaveRecentTargets(values);
            RefreshRecentTargets(false);
            // Deleting a row must never implicitly copy another saved target
            // into the active form.  Only the explicit Use button is allowed
            // to populate host/user/port; keep the form at its safe defaults.
            connectionHostInput.Text = "";
            connectionUserInput.Text = "root";
            connectionPortInput.Text = "22";
            connectionAuthMode.SelectedIndex = 0;
            footerStatus.Text = english ? "Selected VPS history entry deleted" : "已删除所选 VPS 历史";
        }

        private void ClearRecentTargetsWithConfirmation()
        {
            if (recentTargets.Count == 0) return;
            MessageBoxResult answer = MessageBox.Show(window,
                english ? "Clear all VPS login history? Bound keys will not be changed."
                        : "确定清空全部 VPS 登录历史？已绑定 key 不会改变。",
                "ProxyNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;
            foreach (string path in RecentTargetsReadPaths())
            {
                if (File.Exists(path)) File.Delete(path);
            }
            RefreshRecentTargets(false);
            connectionHostInput.Text = "";
            connectionUserInput.Text = "root";
            connectionPortInput.Text = "22";
            connectionAuthMode.SelectedIndex = 0;
            footerStatus.Text = english ? "All VPS login history cleared" : "VPS 登录历史已全部清空";
        }

        private void ToggleMaximize()
        {
            window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        }

        private void RegisterNavigation(string category, string elementName)
        {
            Button button = Find<Button>(elementName);
            navigation[category] = button;
            button.Click += delegate { SelectCategory(category); };
        }

        private void SelectCategory(string category)
        {
            currentCategory = category;
            foreach (KeyValuePair<string, Button> pair in navigation)
            {
                pair.Value.Tag = pair.Key == category ? "active" : null;
            }
            BuildCards();
            UpdateSectionLabels();
        }

        private void BuildCards()
        {
            cardsPanel.Children.Clear();
            int count = 0;
            foreach (OperationInfo operation in operations)
            {
                if (currentCategory != "all" && operation.Category != currentCategory)
                {
                    continue;
                }
                cardsPanel.Children.Add(CreateCard(operation));
                count++;
            }
            visibleCount.Text = english ? count + " actions" : count + " 项";
        }

        private Button CreateCard(OperationInfo operation)
        {
            Button card = new Button();
            card.Style = (Style)window.FindResource("ActionCardStyle");
            card.ToolTip = operation.Title(english);
            card.Click += delegate { LaunchAction(operation.Id); };

            Grid shell = new Grid();
            shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3) });
            shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            Border rail = new Border();
            rail.Background = Brush("#12CBE8", 0.88);
            shell.Children.Add(rail);

            Grid layout = new Grid();
            layout.Margin = new Thickness(13, 11, 13, 10);
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetColumn(layout, 1);
            shell.Children.Add(layout);

            string operationCode;
            int numericCode;
            operationCode = Int32.TryParse(operation.Id, out numericCode) ? numericCode.ToString("00") : operation.Id.ToUpperInvariant();

            Grid top = new Grid();
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock code = new TextBlock();
            code.Text = "// OP:" + operationCode;
            code.Foreground = Brush("#39DCF2", 1);
            code.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            code.FontSize = 9.5;
            code.FontWeight = FontWeights.Bold;
            top.Children.Add(code);
            TextBlock categoryText = new TextBlock();
            categoryText.Text = CategoryLabel(operation.Category).ToUpperInvariant() + "::" + (UsesStandardRemoteForm(operation) ? "REMOTE" : "LOCAL");
            categoryText.Foreground = Brush("#526873", 1);
            categoryText.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            categoryText.FontSize = 8.5;
            Grid.SetColumn(categoryText, 1);
            top.Children.Add(categoryText);
            layout.Children.Add(top);

            TextBlock title = new TextBlock();
            title.Text = operation.Title(english);
            title.FontSize = 15;
            title.FontWeight = FontWeights.SemiBold;
            title.Foreground = Brush("#E3EFF3", 1);
            title.Margin = new Thickness(0, 10, 0, 0);
            title.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetRow(title, 1);
            layout.Children.Add(title);

            TextBlock description = new TextBlock();
            description.Text = operation.Description(english);
            description.FontSize = 10.5;
            description.Foreground = Brush("#8FA2AB", 1);
            description.TextWrapping = TextWrapping.Wrap;
            description.LineHeight = 16;
            description.Margin = new Thickness(0, 6, 0, 6);
            Grid.SetRow(description, 2);
            layout.Children.Add(description);

            Border footerLine = new Border();
            footerLine.BorderBrush = Brush("#182A32", 1);
            footerLine.BorderThickness = new Thickness(0, 1, 0, 0);
            footerLine.Padding = new Thickness(0, 7, 0, 0);
            Grid footer = new Grid();
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock ready = new TextBlock();
            ready.Text = english ? "● READY" : "● READY / 可执行";
            ready.Foreground = Brush("#4FD8AE", 1);
            ready.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            ready.FontSize = 8.5;
            footer.Children.Add(ready);
            TextBlock launch = new TextBlock();
            launch.Text = "[ EXECUTE >> ]";
            launch.Foreground = Brush("#39DCF2", 1);
            launch.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            launch.FontWeight = FontWeights.Bold;
            launch.FontSize = 8.5;
            Grid.SetColumn(launch, 2);
            footer.Children.Add(launch);
            footerLine.Child = footer;
            Grid.SetRow(footerLine, 3);
            layout.Children.Add(footerLine);

            card.Content = shell;
            return card;
        }

        private SolidColorBrush Brush(string color, double opacity)
        {
            SolidColorBrush brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
            brush.Opacity = opacity;
            if (brush.CanFreeze) brush.Freeze();
            return brush;
        }

        private string CategoryLabel(string category)
        {
            if (english)
            {
                if (category == "install") return "Install";
                if (category == "access") return "Access";
                if (category == "maintain") return "Maintain";
                if (category == "security") return "Security";
                if (category == "backup") return "Backup";
                return "Local";
            }
            if (category == "install") return "安装";
            if (category == "access") return "访问";
            if (category == "maintain") return "维护";
            if (category == "security") return "安全";
            if (category == "backup") return "备份";
            return "本地";
        }

        private void UpdateLanguage()
        {
            Find<Button>("LanguageButton").Content = english ? "中文" : "EN";
            Find<TextBlock>("NavCaption").Text = "// CONTROL MATRIX";
            navigation["all"].Content = english ? "[00]  OVERVIEW / ALL" : "[00]  总览 / 全部功能";
            navigation["install"].Content = english ? "[01]  INSTALL / UPGRADE" : "[01]  安装与升级";
            navigation["access"].Content = english ? "[02]  PANEL / ACCESS" : "[02]  面板与访问";
            navigation["maintain"].Content = english ? "[03]  MAINTAIN / REPAIR" : "[03]  维护与修复";
            navigation["security"].Content = english ? "[04]  SECURITY / CREDS" : "[04]  安全与凭据";
            navigation["backup"].Content = english ? "[05]  BACKUP / REPORT" : "[05]  备份与报告";
            navigation["local"].Content = english ? "[06]  WINDOWS / LOCAL" : "[06]  Windows 本地";
            Find<TextBlock>("TopTitle").Text = "NODE INFRASTRUCTURE / OPERATIONS";
            Find<TextBlock>("HeroEyebrow").Text = "// PNA CONTROL FABRIC  /  SESSION:LOCAL";
            Find<TextBlock>("HeroTitle").Text = english ? "Infrastructure control plane" : "节点基础设施控制台";
            Find<TextBlock>("HeroSubtitle").Text = english
                ? "Every input, confirmation, progress update, and result stays in this graphical client. No console window."
                : "连接、输入、确认、进度和结果全部留在图形客户端内，不再弹出控制台。";
            Find<Button>("QuickInstall").Content = english ? "Install / upgrade" : "安装 / 升级";
            Find<Button>("QuickDiagnose").Content = english ? "Auto diagnosis" : "自动体检";
            Find<Button>("OpenTerminal").Content = english ? "Full graphical menu" : "完整图形菜单";
            Find<TextBlock>("SecurityNote").Text = english
                ? "SSH passwords use a masked dialog and a per-run local named pipe. They never enter arguments, logs, the clipboard, or disk."
                : "SSH 密码通过遮罩弹窗和单次本机命名管道交给 OpenSSH，不进入参数、日志、剪贴板或磁盘。";
            Find<TextBlock>("PrivacyMiniText").Text = english ? "NO EMBEDDED SECRETS" : "无内置节点 / 凭据";
            footerStatus.Text = english ? "Ready · choose an action to begin" : "就绪 · 选择一项操作开始";
            operationBackButton.Content = english ? "←  Back to overview" : "←  返回总览";
            operationStartButton.Content = english ? "Start workflow  →" : "开始操作  →";
            operationSendButton.Content = english ? "Submit" : "提交";
            if (!safeStopRequested) operationStopButton.Content = english ? "Safe stop" : "安全停止";
            operationYesButton.Content = english ? "Yes / Y" : "是 / Y";
            operationNoButton.Content = english ? "No / N" : "否 / N";
            operationEnterButton.Content = tunnelSessionActive
                ? (english ? "Close panel tunnel" : "关闭面板隧道")
                : (english ? "Press Enter" : "直接回车");
            Find<Button>("OperationCopyLogButton").Content = english ? "Copy log" : "复制日志";
            Find<Button>("OperationClearLogButton").Content = english ? "Clear display" : "清空显示";
            Find<TextBlock>("HostFieldLabel").Text = english ? "VPS IP or hostname" : "VPS IP 或主机名";
            Find<TextBlock>("UserFieldLabel").Text = english ? "SSH username" : "SSH 用户名";
            Find<TextBlock>("PortFieldLabel").Text = english ? "Port" : "端口";
            Find<TextBlock>("AuthFieldLabel").Text = english ? "SSH login method for this run" : "本次 SSH 登录方式";
            historyFieldLabel.Text = english ? "Recent VPS" : "最近 VPS";
            historyPrivacyNote.Text = english
                ? "The latest target is loaded into each remote form and remains editable. Stores only host, SSH user, port, and last-used time; passwords are entered each run and never saved."
                : "每次远端表单会自动载入最近目标，可修改；只保存地址、SSH 用户、端口与最后使用时间。密码每次输入，不保存。";
            historyUseButton.Content = english ? "Use" : "使用";
            historyDeleteButton.Content = english ? "Delete" : "删除此条";
            historyClearButton.Content = english ? "Clear all" : "清空全部";
            ComboBoxItem choose = connectionAuthMode.Items[0] as ComboBoxItem;
            ComboBoxItem temporary = connectionAuthMode.Items[1] as ComboBoxItem;
            ComboBoxItem managed = connectionAuthMode.Items[2] as ComboBoxItem;
            if (choose != null) choose.Content = english ? "Choose a login method…" : "请选择登录方式…";
            if (temporary != null) temporary.Content = english ? "Temporary password (revoke one-time key afterward)" : "临时密码（操作后撤销一次性 key）";
            if (managed != null) managed.Content = english ? "Per-node key (offer binding if absent)" : "节点长期 key（没有时询问是否绑定）";
            Find<TextBlock>("AskPassTitle").Text = english ? "Enter the VPS login password" : "输入 VPS 登录密码";
            Find<TextBlock>("AskPassPrivacy").Text = english ? "Never written to arguments, logs, clipboard, or disk." : "不会写入命令行、日志、剪贴板或磁盘。";
            Find<Button>("AskPassCancelButton").Content = english ? "Cancel" : "取消";
            Find<Button>("AskPassSubmitButton").Content = english ? "Send to OpenSSH" : "交给 OpenSSH";
            if (operationWorkspace.Visibility == Visibility.Visible && !operationRunning)
            {
                if (fullMenuMode)
                {
                    operationHeaderTitle.Text = english ? "Full workflow menu" : "完整图形工作流菜单";
                    operationSetupTitle.Text = english ? "Open every workflow in this window" : "在当前窗口运行完整菜单";
                }
                else if (activeOperation != null)
                {
                    operationHeaderTitle.Text = activeOperation.Title(english);
                    operationSetupTitle.Text = activeOperation.Title(english);
                    operationSetupDescription.Text = activeOperation.Description(english);
                }
            }
            UpdateSectionLabels();
            BuildCards();
        }

        private void UpdateSectionLabels()
        {
            string title;
            if (english)
            {
                title = currentCategory == "all" ? "All actions" : CategoryLabel(currentCategory);
                Find<TextBlock>("SectionSubtitle").Text = "SELECT OPERATION / EXECUTE FAIL-CLOSED";
            }
            else
            {
                title = currentCategory == "all" ? "全部功能" : CategoryLabel(currentCategory);
                Find<TextBlock>("SectionSubtitle").Text = "选择操作 / 失败关闭执行链";
            }
            Find<TextBlock>("SectionTitle").Text = title;
        }

        private void LaunchAction(string action)
        {
            OperationInfo selected = operations.Find(delegate(OperationInfo item) { return item.Id.Equals(action, StringComparison.OrdinalIgnoreCase); });
            if (selected == null) return;
            OpenOperationWorkspace(selected, false);
        }

        private static bool UsesStandardRemoteForm(OperationInfo operation)
        {
            if (operation == null) return false;
            return operation.Id != "12" && operation.Id != "14" &&
                   !operation.Id.Equals("T", StringComparison.OrdinalIgnoreCase) &&
                   !operation.Id.Equals("K", StringComparison.OrdinalIgnoreCase) &&
                   !operation.Id.Equals("H", StringComparison.OrdinalIgnoreCase);
        }

        private void OpenOperationWorkspace(OperationInfo operation, bool fullMenu)
        {
            if (operationRunning) return;
            activeOperation = operation;
            fullMenuMode = fullMenu;
            safeStopRequested = false;
            tunnelSessionActive = false;
            operationInputPending = false;
            suppressedPromptFrames = 0;
            operationLog.Clear();
            operationWorkspace.Visibility = Visibility.Visible;
            operationLaunchPanel.Visibility = Visibility.Visible;
            operationLogPanel.Visibility = Visibility.Collapsed;
            operationInputPanel.Visibility = Visibility.Collapsed;
            operationBackButton.IsEnabled = true;
            operationStartButton.IsEnabled = true;
            operationStopButton.Content = english ? "Safe stop" : "安全停止";
            operationYesButton.IsEnabled = true;
            operationNoButton.IsEnabled = true;
            operationEnterButton.IsEnabled = true;
            operationSendButton.IsEnabled = true;
            operationInput.IsEnabled = true;
            operationSecretInput.IsEnabled = true;
            operationInput.Visibility = Visibility.Visible;
            operationSecretInput.Visibility = Visibility.Collapsed;
            operationEnterButton.Content = english ? "Press Enter" : "直接回车";
            connectionHostInput.Text = "";
            connectionUserInput.Text = "root";
            connectionPortInput.Text = "22";
            connectionAuthMode.SelectedIndex = 0;

            bool remoteForm = UsesStandardRemoteForm(operation);
            remoteConnectionForm.Visibility = remoteForm ? Visibility.Visible : Visibility.Collapsed;
            // Opening a remote form restores only the latest non-secret
            // endpoint.  It never starts a workflow or restores a password.
            // If the corresponding managed key pair is present locally, that
            // method is selected; otherwise authentication remains explicit.
            if (remoteForm) RefreshRecentTargets(true);
            if (fullMenu)
            {
                operationHeaderTitle.Text = english ? "Full workflow menu" : "完整图形工作流菜单";
                operationSetupTitle.Text = english ? "Open every workflow in this window" : "在当前窗口运行完整菜单";
                operationSetupDescription.Text = english
                    ? "All menu prompts and results remain inside the graphical client."
                    : "原菜单的选择、输入和结果也全部留在图形客户端内。";
            }
            else
            {
                operationHeaderTitle.Text = operation.Title(english);
                operationSetupTitle.Text = operation.Title(english);
                operationSetupDescription.Text = operation.Description(english);
            }
            operationHeaderSubtitle.Text = english ? "Fully graphical · no console window" : "全程图形化 · 不弹出控制台";
            operationLaunchHint.Text = remoteForm
                ? (english ? "The latest VPS target is loaded automatically and remains editable; passwords are entered each run and never saved."
                           : "已自动载入最近 VPS 目标，可修改；密码每次输入且不会保存。后续确认和选择会继续在图形输入区完成。")
                : (english ? "This workflow starts without a pre-filled VPS connection form. All prompts remain below."
                           : "本功能无需预填标准 VPS 连接表；后续提示仍全部在下方完成。");
            operationStartButton.Content = english ? "Start workflow  →" : "开始操作  →";
            footerStatus.Text = english ? "Graphical workflow ready" : "图形工作流已就绪";
            operationStartButton.Focus();
        }

        private void ReturnToDashboard()
        {
            if (operationRunning)
            {
                MessageBox.Show(window,
                    english ? "The workflow is still running. Finish it or use Safe stop first."
                            : "当前流程仍在运行。请等待完成，或先使用“安全停止”。",
                    "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            operationWorkspace.Visibility = Visibility.Collapsed;
            activeOperation = null;
            fullMenuMode = false;
            footerStatus.Text = english ? "Ready · choose an action to begin" : "就绪 · 选择一项操作开始";
        }

        private void StartSelectedOperation()
        {
            if (operationRunning) return;
            List<string> prefilledInput = new List<string>();
            if (UsesStandardRemoteForm(activeOperation))
            {
                string host = connectionHostInput.Text.Trim();
                string user = connectionUserInput.Text.Trim();
                string portText = connectionPortInput.Text.Trim();
                int port;
                if (!Regex.IsMatch(host, "^[A-Za-z0-9._:-]+$") ||
                    !Regex.IsMatch(user, "^[A-Za-z_][A-Za-z0-9_.-]*$") ||
                    !Int32.TryParse(portText, out port) || port < 1 || port > 65535)
                {
                    MessageBox.Show(window,
                        english ? "Enter a valid VPS host, SSH username, and port."
                                : "请填写有效的 VPS 地址、SSH 用户名和端口。",
                        "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                ComboBoxItem mode = connectionAuthMode.SelectedItem as ComboBoxItem;
                string auth = mode == null ? "" : Convert.ToString(mode.Tag);
                if (auth != "1" && auth != "2")
                {
                    MessageBox.Show(window,
                        english ? "Choose Temporary password or Per-node key for this operation."
                                : "请明确选择本次使用“临时密码”或“节点长期 key”。",
                        "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }
                prefilledInput.Add(auth);
                prefilledInput.Add(host);
                prefilledInput.Add(user);
                prefilledInput.Add(portText);
                try
                {
                    RememberRecentTarget(host, user, port);
                }
                catch (Exception error)
                {
                    footerStatus.Text = (english ? "Workflow will continue; VPS history could not be saved: " : "操作将继续；VPS 历史保存失败：") + error.Message;
                }
            }

            operationStartButton.IsEnabled = false;
            operationBackButton.IsEnabled = false;
            operationLaunchPanel.Visibility = Visibility.Collapsed;
            operationLogPanel.Visibility = Visibility.Visible;
            operationInputPanel.Visibility = Visibility.Visible;
            operationLog.Clear();
            operationStatusDot.Fill = Brush("#22D3EE", 1);
            operationStatusText.Text = english ? "Starting workflow…" : "正在启动工作流…";
            operationPromptText.Text = english ? "Wait for the next prompt…" : "等待下一项提示…";
            operationFooterText.Text = english ? "All input stays inside this graphical window" : "所有输入都在当前图形窗口内完成";
            operationInputPending = true;
            suppressedPromptFrames = prefilledInput.Count;
            SetOperationInputReady(false);
            try
            {
                RuntimeFiles runtime = EnsureRuntimeExtracted();
                StartAskPassServer();
                StartBackendProcess(runtime, prefilledInput);
            }
            catch (Exception error)
            {
                StopAskPassServer();
                operationRunning = false;
                operationInputPending = false;
                operationBackButton.IsEnabled = true;
                operationInputPanel.Visibility = Visibility.Collapsed;
                operationStatusDot.Fill = Brush("#F06F7B", 1);
                operationStatusText.Text = english ? "Could not start" : "启动失败";
                operationLog.AppendText((english ? "Could not start the graphical workflow:\r\n" : "无法启动图形工作流：\r\n") + error.Message);
            }
        }

        private void StartBackendProcess(RuntimeFiles runtime, List<string> prefilledInput)
        {
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = runtime.CliPath;
            start.Arguments = !String.IsNullOrEmpty(backendArgumentsOverride)
                ? backendArgumentsOverride
                : (fullMenuMode ? "" : "--gui-action " + activeOperation.Id);
            backendArgumentsOverride = null;
            start.WorkingDirectory = IOPath.GetDirectoryName(runtime.CliPath);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.StandardOutputEncoding = new UTF8Encoding(false);
            start.StandardErrorEncoding = new UTF8Encoding(false);
            start.EnvironmentVariables["SSH_ASKPASS"] = runtime.AskPassPath;
            start.EnvironmentVariables["SSH_ASKPASS_REQUIRE"] = "force";
            start.EnvironmentVariables["DISPLAY"] = "ProxyNodeAssistant";
            start.EnvironmentVariables["PNA_ASKPASS_PIPE"] = askPassPipeName;
            start.EnvironmentVariables["PNA_GUI_MODE"] = "1";
            if (prefilledInput.Count >= 4) start.EnvironmentVariables["PNA_PREFILLED_CONNECTION"] = "1";

            Process process = new Process();
            process.StartInfo = start;
            process.EnableRaisingEvents = true;
            process.Exited += BackendProcessExited;
            operationRunning = true;
            if (!process.Start())
            {
                operationRunning = false;
                throw new InvalidOperationException("The embedded workflow engine did not start.");
            }
            lock (processGate) activeProcess = process;
            Thread stdout = new Thread(new ThreadStart(delegate { PumpOutput(process.StandardOutput, false); }));
            Thread stderr = new Thread(new ThreadStart(delegate { PumpOutput(process.StandardError, true); }));
            stdout.IsBackground = true;
            stderr.IsBackground = true;
            stdout.Start();
            stderr.Start();
            foreach (string value in prefilledInput) process.StandardInput.WriteLine(value);
            process.StandardInput.Flush();
            operationInput.Focus();
        }

        private void PumpOutput(StreamReader reader, bool isError)
        {
            try
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    string chunk = line + "\n";
                    window.Dispatcher.BeginInvoke(new Action(delegate { AppendOperationOutput(chunk, isError); }));
                }
            }
            catch { }
        }

        private static bool TryDecodeGuiPrompt(string chunk, out string prompt, out bool secret)
        {
            prompt = null;
            secret = false;
            string line = (chunk ?? "").Trim();
            string payload;
            if (line.StartsWith(GuiSecretPromptPrefix, StringComparison.Ordinal))
            {
                secret = true;
                payload = line.Substring(GuiSecretPromptPrefix.Length);
            }
            else if (line.StartsWith(GuiPromptPrefix, StringComparison.Ordinal))
            {
                payload = line.Substring(GuiPromptPrefix.Length);
            }
            else return false;
            if (String.IsNullOrEmpty(payload)) return false;
            try
            {
                prompt = Encoding.UTF8.GetString(Convert.FromBase64String(payload));
                return !String.IsNullOrWhiteSpace(prompt);
            }
            catch
            {
                prompt = null;
                return false;
            }
        }

        private static string StripAnsi(string value)
        {
            return Regex.Replace(value ?? "", "\\x1B\\[[0-?]*[ -/]*[@-~]", "");
        }

        private void AppendOperationOutput(string chunk, bool isError)
        {
            string framedPrompt;
            bool framedSecret;
            bool hasFramedPrompt = TryDecodeGuiPrompt(chunk, out framedPrompt, out framedSecret);
            bool suppressFramedPrompt = hasFramedPrompt && suppressedPromptFrames > 0;
            if (suppressFramedPrompt) suppressedPromptFrames--;
            bool tunnelMarker = chunk.Contains(TunnelSessionMarker);
            string displayChunk = hasFramedPrompt ? framedPrompt + ":\n" : StripAnsi(chunk.Replace(TunnelSessionMarker, ""));
            string normalized = displayChunk.Replace("\r\n", "\n").Replace("\n", Environment.NewLine);
            operationLog.AppendText(normalized);
            if (operationLog.Text.Length > 1500000)
            {
                operationLog.Text = operationLog.Text.Substring(operationLog.Text.Length - 1000000);
            }
            operationLog.ScrollToEnd();

            if (hasFramedPrompt && !suppressFramedPrompt)
            {
                operationPromptText.Text = framedPrompt.Length > 220 ? framedPrompt.Substring(framedPrompt.Length - 220) : framedPrompt;
                if (tunnelSessionActive)
                {
                    operationInput.Visibility = Visibility.Collapsed;
                    operationSecretInput.Visibility = Visibility.Collapsed;
                    operationInputPending = false;
                    SetOperationInputReady(false);
                    operationEnterButton.IsEnabled = true;
                    operationEnterButton.Content = english ? "Close panel tunnel" : "关闭面板隧道";
                }
                else if (!safeStopRequested)
                {
                    bool secret = framedSecret || LooksLikeSecretPrompt(framedPrompt);
                    operationInput.Visibility = secret ? Visibility.Collapsed : Visibility.Visible;
                    operationSecretInput.Visibility = secret ? Visibility.Visible : Visibility.Collapsed;
                    operationInputPending = false;
                    SetOperationInputReady(true);
                    if (secret) operationSecretInput.Focus(); else operationInput.Focus();
                }
            }
            string lower = displayChunk.ToLowerInvariant();
            if (tunnelMarker)
            {
                tunnelSessionActive = true;
                operationStatusDot.Fill = Brush("#54D5B3", 1);
                operationStatusText.Text = english ? "Panel tunnel active" : "面板隧道保持中";
                operationPromptText.Text = english
                    ? "Keep this app open. Close the tunnel here after using the panel."
                    : "请保持本程序运行；面板用完后在这里关闭隧道。";
                operationInput.Clear();
                operationInput.IsEnabled = false;
                operationInput.Visibility = Visibility.Collapsed;
                operationSecretInput.Visibility = Visibility.Collapsed;
                operationSendButton.IsEnabled = false;
                operationYesButton.IsEnabled = false;
                operationNoButton.IsEnabled = false;
                operationEnterButton.IsEnabled = false;
                operationEnterButton.Content = english ? "Close panel tunnel" : "关闭面板隧道";
            }
            if (tunnelSessionActive)
            {
                operationStatusDot.Fill = Brush("#54D5B3", 1);
                operationStatusText.Text = english ? "Panel tunnel active" : "面板隧道保持中";
            }
            else if (isError && (lower.Contains("error") || lower.Contains("failed") || lower.Contains("失败")))
            {
                operationStatusDot.Fill = Brush("#F3B85B", 1);
                operationStatusText.Text = english ? "Running · attention needed" : "执行中 · 需要留意";
            }
            else if (lower.Contains("[good]") || lower.Contains("_ok"))
            {
                operationStatusDot.Fill = Brush("#54D5B3", 1);
                operationStatusText.Text = english ? "Running · checks passing" : "执行中 · 检查通过";
            }
            else if (operationRunning)
            {
                operationStatusText.Text = english ? "Workflow running" : "工作流执行中";
            }
        }

        private static bool LooksLikeSecretPrompt(string prompt)
        {
            string lower = prompt.ToLowerInvariant();
            return lower.Contains("password") || lower.Contains("passphrase") || lower.Contains("api key") ||
                   lower.Contains("api token") || lower.Contains("密码") || lower.Contains("口令") || lower.Contains("令牌");
        }

        private static bool LooksLikeRequiredPrompt(string prompt)
        {
            string lower = (prompt ?? "").ToLowerInvariant();
            return lower.Contains("没有默认值") || lower.Contains("no default") ||
                   lower.Contains("vps ip 或主机名") || lower.Contains("vps ip or hostname") ||
                   lower.Contains("ssh 用户名") || lower.Contains("ssh username") ||
                   lower.Contains("此项必须填写") || lower.Contains("this value is required");
        }

        private void SetOperationInputReady(bool ready)
        {
            operationInput.IsEnabled = ready;
            operationSecretInput.IsEnabled = ready;
            operationSendButton.IsEnabled = ready;
            operationYesButton.IsEnabled = ready;
            operationNoButton.IsEnabled = ready;
            operationEnterButton.IsEnabled = ready;
        }

        private void SendOperationInput(string forcedValue)
        {
            if (!operationRunning || activeProcess == null || activeProcess.HasExited) return;
            if (operationInputPending) return;
            bool secret = operationSecretInput.Visibility == Visibility.Visible;
            string value = forcedValue;
            if (value == null) value = secret ? operationSecretInput.Password : operationInput.Text;
            if (!secret && String.IsNullOrWhiteSpace(value) && LooksLikeRequiredPrompt(operationPromptText.Text))
            {
                operationStatusDot.Fill = Brush("#F3B85B", 1);
                operationStatusText.Text = english ? "Required input is empty" : "必填内容不能为空";
                operationPromptText.Text = english ? "This value is required. Enter it before submitting." : "此项必须填写，请输入后再提交。";
                operationInput.Focus();
                return;
            }
            try
            {
                if (tunnelSessionActive && forcedValue == "")
                {
                    operationStatusText.Text = english ? "Closing panel tunnel…" : "正在关闭面板隧道…";
                    operationEnterButton.IsEnabled = false;
                }
                activeProcess.StandardInput.WriteLine(value ?? "");
                activeProcess.StandardInput.Flush();
                operationInputPending = true;
                SetOperationInputReady(false);
                operationInput.Clear();
                operationSecretInput.Clear();
                operationPromptText.Text = english ? "Input submitted · waiting for the next step…" : "输入已提交 · 等待下一步…";
            }
            catch (Exception error)
            {
                operationInputPending = false;
                SetOperationInputReady(true);
                operationPromptText.Text = (english ? "Input could not be sent: " : "输入提交失败：") + error.Message;
            }
        }

        private void RequestOperationStop()
        {
            if (!operationRunning || activeProcess == null) return;
            if (!safeStopRequested)
            {
                safeStopRequested = true;
                operationInputPending = true;
                SetOperationInputReady(false);
                operationStopButton.Content = english ? "Force stop" : "强制结束";
                operationStatusDot.Fill = Brush("#F3B85B", 1);
                operationStatusText.Text = english ? "Safe stop requested · waiting for cleanup" : "已请求安全停止 · 正在等待清理";
                CompleteAskPass(true);
                try { activeProcess.StandardInput.Close(); } catch { }
                return;
            }
            MessageBoxResult result = MessageBox.Show(window,
                english ? "Force stopping can interrupt remote cleanup. Use it only if the workflow is genuinely stuck. Continue?"
                        : "强制结束可能中断远端清理，仅在流程确实卡死时使用。仍要继续吗？",
                "ProxyNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (result != MessageBoxResult.Yes) return;
            try
            {
                ProcessStartInfo kill = new ProcessStartInfo("taskkill.exe", "/PID " + activeProcess.Id + " /T /F");
                kill.UseShellExecute = false;
                kill.CreateNoWindow = true;
                Process.Start(kill);
            }
            catch
            {
                try { activeProcess.Kill(); } catch { }
            }
        }

        private void BackendProcessExited(object sender, EventArgs args)
        {
            Process process = sender as Process;
            int exitCode = -1;
            try { process.WaitForExit(); exitCode = process.ExitCode; } catch { }
            StopAskPassServer();
            window.Dispatcher.BeginInvoke(new Action(delegate
            {
                operationRunning = false;
                operationInputPending = false;
                tunnelSessionActive = false;
                operationBackButton.IsEnabled = true;
                operationInputPanel.Visibility = Visibility.Collapsed;
                bool stoppedSafely = safeStopRequested && exitCode == 0;
                operationStatusDot.Fill = Brush(stoppedSafely ? "#F3B85B" : (exitCode == 0 ? "#54D5B3" : "#F06F7B"), 1);
                operationStatusText.Text = stoppedSafely
                    ? (english ? "Workflow stopped safely" : "工作流已安全停止")
                    : (exitCode == 0
                        ? (english ? "Workflow completed" : "工作流已完成")
                        : (english ? "Workflow stopped with exit " + exitCode : "工作流已结束，退出码 " + exitCode));
                operationFooterText.Text = english ? "Review or copy the log, then return to the overview" : "可查看或复制日志，然后返回总览";
                footerStatus.Text = operationStatusText.Text;
                Action<int> completion = workflowSmokeCompletion;
                workflowSmokeCompletion = null;
                if (completion != null) completion(exitCode);
            }));
        }

        private void CopyOperationLog()
        {
            try
            {
                Clipboard.SetText(operationLog.Text ?? "");
                operationFooterText.Text = english ? "Log copied · clear the clipboard after saving secrets" : "日志已复制 · 若含秘密请保存后清空剪贴板";
            }
            catch (Exception error)
            {
                operationFooterText.Text = (english ? "Copy failed: " : "复制失败：") + error.Message;
            }
        }

        private void StartAskPassServer()
        {
            askPassStopping = false;
            askPassPipeName = "ProxyNodeAssistant-" + Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N");
            askPassThread = new Thread(AskPassServerLoop);
            askPassThread.IsBackground = true;
            askPassThread.Start();
        }

        private NamedPipeServerStream CreateAskPassPipe()
        {
            PipeSecurity security = new PipeSecurity();
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.ReadWrite, AccessControlType.Allow));
            return new NamedPipeServerStream(askPassPipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous, 4096, 4096, security);
        }

        private void AskPassServerLoop()
        {
            while (!askPassStopping)
            {
                NamedPipeServerStream server = null;
                try
                {
                    server = CreateAskPassPipe();
                    activePipeServer = server;
                    server.WaitForConnection();
                    if (askPassStopping) break;
                    using (BinaryReader reader = new BinaryReader(server, new UTF8Encoding(false), true))
                    using (BinaryWriter writer = new BinaryWriter(server, new UTF8Encoding(false), true))
                    {
                        AskPassRequest request = new AskPassRequest();
                        request.Prompt = reader.ReadString();
                        window.Dispatcher.BeginInvoke(new Action(delegate { ShowAskPass(request); }));
                        request.Completed.WaitOne();
                        writer.Write(request.Cancelled ? "" : (request.Password ?? ""));
                        writer.Flush();
                        request.Password = null;
                    }
                }
                catch
                {
                    if (!askPassStopping) Thread.Sleep(100);
                }
                finally
                {
                    activePipeServer = null;
                    if (server != null) server.Dispose();
                }
            }
        }

        private void ShowAskPass(AskPassRequest request)
        {
            if (!String.IsNullOrEmpty(askPassSmokeResponse))
            {
                request.Password = askPassSmokeResponse;
                askPassSmokeResponse = null;
                request.Completed.Set();
                return;
            }
            currentAskPassRequest = request;
            askPassPrompt.Text = String.IsNullOrWhiteSpace(request.Prompt)
                ? (english ? "OpenSSH requests the VPS password." : "OpenSSH 正在请求 VPS 登录密码。")
                : request.Prompt;
            askPassPassword.Clear();
            askPassOverlay.Visibility = Visibility.Visible;
            askPassPassword.Focus();
        }

        private void CompleteAskPass(bool cancelled)
        {
            AskPassRequest request = currentAskPassRequest;
            if (request == null) return;
            if (!cancelled && String.IsNullOrEmpty(askPassPassword.Password))
            {
                MessageBox.Show(window, english ? "Enter the VPS password." : "请输入 VPS 登录密码。",
                    "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            request.Cancelled = cancelled;
            request.Password = cancelled ? null : askPassPassword.Password;
            askPassPassword.Clear();
            askPassOverlay.Visibility = Visibility.Collapsed;
            currentAskPassRequest = null;
            request.Completed.Set();
        }

        private void StopAskPassServer()
        {
            askPassStopping = true;
            AskPassRequest request = currentAskPassRequest;
            if (request != null)
            {
                request.Cancelled = true;
                request.Completed.Set();
            }
            try { if (activePipeServer != null) activePipeServer.Dispose(); } catch { }
            window.Dispatcher.BeginInvoke(new Action(delegate
            {
                askPassPassword.Clear();
                askPassOverlay.Visibility = Visibility.Collapsed;
                currentAskPassRequest = null;
            }));
        }

        private static byte[] ReadEmbeddedExecutable(Assembly assembly, string resourceName, int minimumBytes)
        {
            using (Stream stream = assembly.GetManifestResourceStream(resourceName))
            {
                if (stream == null) throw new InvalidOperationException("Embedded runtime resource is missing: " + resourceName);
                using (MemoryStream memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    byte[] payload = memory.ToArray();
                    if (payload.Length < minimumBytes)
                    {
                        throw new InvalidOperationException("Embedded runtime payload is unexpectedly small: " + resourceName);
                    }
                    return payload;
                }
            }
        }

        private static string NativeWindowsArchitecture()
        {
            try
            {
                NativeSystemInfo systemInfo;
                GetNativeSystemInfo(out systemInfo);
                switch (systemInfo.ProcessorArchitecture)
                {
                    case ProcessorArchitectureAmd64: return "x64";
                    case ProcessorArchitectureArm64: return "ARM64";
                    case ProcessorArchitectureIntel: return "x86";
                }
            }
            catch
            {
                // Fall through to the documented environment fallback.  The
                // API is present on supported Windows versions, but this keeps
                // the diagnostic usable under compatibility layers as well.
            }
            string native = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432");
            if (String.IsNullOrWhiteSpace(native)) native = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            if (!String.IsNullOrWhiteSpace(native))
            {
                native = native.Trim().ToUpperInvariant();
                if (native == "AMD64" || native == "IA64") return "x64";
                if (native == "ARM64") return "ARM64";
                if (native == "X86" || native == "I386") return "x86";
            }
            return Environment.Is64BitOperatingSystem ? "x64" : "x86";
        }

        private static ushort ReadUInt16(byte[] payload, int offset)
        {
            if (payload == null || offset < 0 || offset > payload.Length - 2) return 0;
            return (ushort)(payload[offset] | (payload[offset + 1] << 8));
        }

        private static int ReadInt32(byte[] payload, int offset)
        {
            if (payload == null || offset < 0 || offset > payload.Length - 4) return -1;
            return payload[offset] |
                   (payload[offset + 1] << 8) |
                   (payload[offset + 2] << 16) |
                   (payload[offset + 3] << 24);
        }

        private static string EmbeddedPeArchitecture(byte[] payload)
        {
            if (payload == null || payload.Length < 64 || payload[0] != (byte)'M' || payload[1] != (byte)'Z') return "invalid";
            int peOffset = ReadInt32(payload, 0x3c);
            if (peOffset < 0 || peOffset > payload.Length - 6 ||
                payload[peOffset] != (byte)'P' || payload[peOffset + 1] != (byte)'E' ||
                payload[peOffset + 2] != 0 || payload[peOffset + 3] != 0) return "invalid";
            ushort machine = ReadUInt16(payload, peOffset + 4);
            switch (machine)
            {
                case ImageFileMachineI386: return "x86";
                case ImageFileMachineAmd64: return "x64";
                case ImageFileMachineArm64: return "ARM64";
                default: return "unknown (0x" + machine.ToString("X4") + ")";
            }
        }

        private static bool IsPayloadArchitectureSupported(string payloadArchitecture, string hostArchitecture)
        {
            // x86 Windows binaries are supported by x64 and ARM64 Windows via
            // their compatibility layers.  x64 is likewise supported on
            // current ARM64 Windows, while ARM64 cannot run on x86/x64.
            if (payloadArchitecture == "x86") return true;
            if (hostArchitecture == "ARM64") return payloadArchitecture == "ARM64" || payloadArchitecture == "x64";
            if (hostArchitecture == "x64") return payloadArchitecture == "x64";
            return false;
        }

        private static void ValidateEmbeddedPayloadArchitecture(byte[] payload)
        {
            string payloadArchitecture = EmbeddedPeArchitecture(payload);
            string hostArchitecture = NativeWindowsArchitecture();
            if (payloadArchitecture == "invalid")
            {
                throw new InvalidOperationException(
                    "内嵌工作流引擎不是有效的 Windows 可执行文件，请重新下载完整的 ProxyNodeAssistant v1.0.0 包。\n" +
                    "The embedded workflow engine is not a valid Windows executable. Re-download the complete ProxyNodeAssistant v1.0.0 package.");
            }
            if (payloadArchitecture.StartsWith("unknown", StringComparison.Ordinal) ||
                !IsPayloadArchitectureSupported(payloadArchitecture, hostArchitecture))
            {
                string recommended = hostArchitecture == "x86"
                    ? "ProxyNodeAssistant-v1.0.0-win32.exe"
                    : hostArchitecture == "ARM64"
                        ? "ProxyNodeAssistant-v1.0.0-win-arm64.exe"
                        : "ProxyNodeAssistant-v1.0.0-win64.exe";
                throw new InvalidOperationException(
                    "当前 Windows 是 " + hostArchitecture + "，但此文件内嵌的工作流引擎是 " + payloadArchitecture + "。请启动同目录的 " + recommended + "。\n" +
                    "This GUI embeds a " + payloadArchitecture + " workflow engine, but the current Windows installation is " + hostArchitecture + ". Launch " + recommended + " from the same directory.");
            }
        }

        // Called before WPF startup so an accidentally selected ARM64 GUI on
        // an Intel/AMD PC cannot reach Process.Start and trigger Windows'
        // opaque SystemResourceNotifyWindow dialog.
        internal static void ValidateEmbeddedRuntimeArchitecture(Assembly assembly)
        {
            byte[] payload = ReadEmbeddedExecutable(assembly, CliResourceName, 1024 * 1024);
            ValidateEmbeddedPayloadArchitecture(payload);
        }

        private RuntimeFiles EnsureRuntimeExtracted()
        {
            RuntimeFiles runtime = new RuntimeFiles();
            runtime.CliPath = ExtractEmbeddedExecutable(CliResourceName, "ProxyNodeAssistant-v" + Version + "-engine", 1024 * 1024);
            runtime.AskPassPath = ExtractEmbeddedExecutable(AskPassResourceName, "ProxyNodeAssistant-v" + Version + "-askpass", 4096);
            return runtime;
        }

        private string ExtractEmbeddedExecutable(string resourceName, string fileStem, int minimumBytes)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            byte[] payload = ReadEmbeddedExecutable(assembly, resourceName, minimumBytes);
            if (String.Equals(resourceName, CliResourceName, StringComparison.Ordinal))
            {
                ValidateEmbeddedPayloadArchitecture(payload);
            }
            string hash = Sha256(payload);
            string directory = IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProxyNodeAssistant", "v" + Version);
            Directory.CreateDirectory(directory);
            string path = IOPath.Combine(directory, fileStem + "-" + hash.Substring(0, 12) + ".exe");
            if (File.Exists(path) && Sha256(File.ReadAllBytes(path)) == hash) return path;
            string temporary = path + ".new-" + Process.GetCurrentProcess().Id;
            File.WriteAllBytes(temporary, payload);
            if (Sha256(File.ReadAllBytes(temporary)) != hash)
            {
                try { File.Delete(temporary); } catch { }
                throw new IOException("Extracted CLI hash verification failed.");
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(temporary, path);
            return path;
        }

        private static string Sha256(byte[] data)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] hash = algorithm.ComputeHash(data);
                StringBuilder builder = new StringBuilder(hash.Length * 2);
                foreach (byte value in hash) builder.Append(value.ToString("x2"));
                return builder.ToString();
            }
        }

        private void BeginOpenSSHProbe()
        {
            cardsPanel.IsEnabled = false;
            Find<Button>("QuickInstall").IsEnabled = false;
            Find<Button>("QuickDiagnose").IsEnabled = false;
            Find<Button>("OpenTerminal").IsEnabled = false;
            ThreadPool.QueueUserWorkItem(delegate
            {
                string summary = ProbeOpenSSH();
                string failure = null;
                if (String.IsNullOrEmpty(summary))
                {
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        openSSHStatusText.Text = english ? "Installing Windows OpenSSH once…" : "正在一次性安装 Windows OpenSSH…";
                        footerStatus.Text = english ? "OpenSSH setup must finish before workflows are enabled" : "OpenSSH 安装验证完成后才开放功能";
                    }));
                    try
                    {
                        RuntimeFiles runtime = EnsureRuntimeExtracted();
                        ProcessStartInfo start = new ProcessStartInfo();
                        start.FileName = runtime.CliPath;
                        start.Arguments = "--openssh-preflight";
                        start.WorkingDirectory = IOPath.GetDirectoryName(runtime.CliPath);
                        start.UseShellExecute = false;
                        start.CreateNoWindow = true;
                        start.EnvironmentVariables["PNA_GUI_MODE"] = "1";
                        using (Process process = Process.Start(start))
                        {
                            if (process == null)
                            {
                                failure = "OpenSSH preflight did not start.";
                            }
                            else if (!process.WaitForExit(600000))
                            {
                                try { process.Kill(); } catch { }
                                failure = "OpenSSH setup timed out.";
                            }
                            else if (process.ExitCode != 0)
                            {
                                failure = "OpenSSH setup returned exit " + process.ExitCode + ".";
                            }
                        }
                        if (failure == null) summary = ProbeOpenSSH();
                    }
                    catch (Exception error)
                    {
                        failure = error.Message;
                    }
                }
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    if (String.IsNullOrEmpty(summary))
                    {
                        openSSHStatusText.Text = english ? "OpenSSH setup failed" : "OpenSSH 安装或验证失败";
                        openSSHDot.Fill = Brush("#F06F7B", 1);
                        footerStatus.Text = english ? "Workflows remain disabled; restart after resolving OpenSSH" : "功能保持禁用；解决 OpenSSH 后重新启动";
                        MessageBox.Show(window,
                            (english ? "Windows OpenSSH could not be installed and verified in one pass. The app will not retry in a loop.\n\n"
                                     : "Windows OpenSSH 未能一次性安装并验证；程序不会进入重复安装死循环。\n\n") +
                            (failure ?? (english ? "No usable OpenSSH suite was found." : "没有找到可用的完整 OpenSSH 套件。")),
                            "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                        app.Shutdown(1);
                    }
                    else
                    {
                        openSSHStatusText.Text = english ? "OpenSSH ready · " + summary : "OpenSSH 就绪 · " + summary;
                        openSSHDot.Fill = Brush("#54D5B3", 1);
                        cardsPanel.IsEnabled = true;
                        Find<Button>("QuickInstall").IsEnabled = true;
                        Find<Button>("QuickDiagnose").IsEnabled = true;
                        Find<Button>("OpenTerminal").IsEnabled = true;
                        footerStatus.Text = english ? "Ready · choose an action to begin" : "就绪 · 选择一项操作开始";
                    }
                }));
            });
        }

        private string ProbeOpenSSH()
        {
            List<string> candidates = new List<string>();
            AddCandidate(candidates, IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe"));
            AddCandidate(candidates, IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "OpenSSH", "ssh.exe"));
            string pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string directory in pathValue.Split(IOPath.PathSeparator))
            {
                if (!String.IsNullOrWhiteSpace(directory)) AddCandidate(candidates, IOPath.Combine(directory.Trim(), "ssh.exe"));
            }
            foreach (string candidate in candidates)
            {
                if (!File.Exists(candidate)) continue;
                try
                {
                    ProcessStartInfo start = new ProcessStartInfo();
                    start.FileName = candidate;
                    start.Arguments = "-V";
                    start.UseShellExecute = false;
                    start.CreateNoWindow = true;
                    start.RedirectStandardError = true;
                    start.RedirectStandardOutput = true;
                    using (Process process = Process.Start(start))
                    {
                        if (process == null) continue;
                        string output = process.StandardError.ReadToEnd() + process.StandardOutput.ReadToEnd();
                        if (!process.WaitForExit(4000))
                        {
                            try { process.Kill(); } catch { }
                            continue;
                        }
                        output = output.Trim();
                        if (output.StartsWith("OpenSSH", StringComparison.OrdinalIgnoreCase))
                        {
                            int comma = output.IndexOf(',');
                            if (comma > 0) output = output.Substring(0, comma);
                            return output.Replace("OpenSSH_for_Windows_", "");
                        }
                    }
                }
                catch { }
            }
            return null;
        }

        private static void AddCandidate(List<string> candidates, string candidate)
        {
            if (String.IsNullOrWhiteSpace(candidate)) return;
            foreach (string existing in candidates)
            {
                if (String.Equals(existing, candidate, StringComparison.OrdinalIgnoreCase)) return;
            }
            candidates.Add(candidate);
        }

        private bool LoadLanguage()
        {
            try
            {
                string path = SettingsPath();
                if (!File.Exists(path)) return false;
                string text = File.ReadAllText(path, Encoding.UTF8);
                return text.IndexOf("\"language\": \"en\"", StringComparison.OrdinalIgnoreCase) >= 0 ||
                       text.IndexOf("\"language\":\"en\"", StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch { return false; }
        }

        private void SaveLanguage()
        {
            try
            {
                string path = SettingsPath();
                Directory.CreateDirectory(IOPath.GetDirectoryName(path));
                string language = english ? "en" : "zh";
                string text = File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : "";
                if (String.IsNullOrWhiteSpace(text))
                {
                    text = "{\n  \"language\": \"" + language + "\"\n}\n";
                }
                else if (Regex.IsMatch(text, "\\\"language\\\"\\s*:\\s*\\\"(?:zh|en)\\\"", RegexOptions.IgnoreCase))
                {
                    text = Regex.Replace(text, "\\\"language\\\"\\s*:\\s*\\\"(?:zh|en)\\\"", "\"language\": \"" + language + "\"", RegexOptions.IgnoreCase);
                }
                else
                {
                    int brace = text.IndexOf('{');
                    if (brace < 0) return;
                    text = text.Insert(brace + 1, "\n  \"language\": \"" + language + "\",");
                }
                File.WriteAllText(path, text, new UTF8Encoding(false));
            }
            catch { }
        }

        private static string SettingsPath()
        {
            string root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string current = IOPath.Combine(root, "ProxyNodeAssistant", "settings.json");
            string legacy = IOPath.Combine(root, "TextNodeAssistant", "settings.json");
            if (!File.Exists(current) && File.Exists(legacy))
            {
                Directory.CreateDirectory(IOPath.GetDirectoryName(current));
                File.Copy(legacy, current, false);
            }
            return current;
        }

        public void OpenActionForCommandLine(string action)
        {
            OperationInfo selected = operations.Find(delegate(OperationInfo item) { return item.Id.Equals(action, StringComparison.OrdinalIgnoreCase); });
            if (selected != null) OpenOperationWorkspace(selected, false);
        }

        public void PrepareOperationPreview()
        {
            OpenActionForCommandLine("1");
            operationLaunchPanel.Visibility = Visibility.Collapsed;
            operationLogPanel.Visibility = Visibility.Visible;
            operationInputPanel.Visibility = Visibility.Visible;
            operationLog.Text = english
                ? "[GOOD] Installation completed.\r\n[GOOD] Panel metadata validated.\r\n[GOOD] Browser opened through 127.0.0.1.\r\n"
                : "[GOOD] 施工已完成。\r\n[GOOD] 面板元数据已经校验。\r\n[GOOD] 浏览器已通过 127.0.0.1 打开。\r\n";
            AppendOperationOutput(TunnelSessionMarker + "\r\n", false);
        }

        public void BeginTunnelLifetimeSmoke(Action<bool> completion)
        {
            OperationInfo smokeOperation = new OperationInfo
            {
                Id = "14",
                Category = "local",
                ZhTitle = "面板隧道关闭按钮测试",
                EnTitle = "Panel tunnel close-button smoke",
                ZhDescription = "验证按钮真正向后端提交关闭信号并等待确认。",
                EnDescription = "Verifies the button actually submits the close signal and receives acknowledgement.",
                Accent = "#12CBE8"
            };
            OpenOperationWorkspace(smokeOperation, false);
            backendArgumentsOverride = "--tunnel-close-smoke";
            int ticks = 0;
            bool clicked = false;
            bool timedOut = false;
            DispatcherTimer timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromMilliseconds(50);
            workflowSmokeCompletion = delegate(int code)
            {
                timer.Stop();
                bool acknowledged = operationLog.Text.Contains("PNA_GUI_TUNNEL_CLOSE_ACK");
                completion(!timedOut && clicked && acknowledged && code == 0 && !tunnelSessionActive);
            };
            StartSelectedOperation();
            timer.Tick += delegate
            {
                ticks++;
                if (ticks >= 200)
                {
                    timedOut = true;
                    timer.Stop();
                    try { activeProcess.Kill(); } catch { completion(false); }
                    return;
                }
                if (!operationRunning || clicked || operationInputPending) return;
                if (tunnelSessionActive && operationEnterButton.IsEnabled &&
                    Convert.ToString(operationEnterButton.Content).IndexOf(english ? "Close panel tunnel" : "关闭面板隧道", StringComparison.Ordinal) >= 0)
                {
                    clicked = true;
                    operationEnterButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
            };
            timer.Start();
        }

        public void BeginHistorySmoke(Action<bool> completion)
        {
            window.Dispatcher.BeginInvoke(new Action(delegate
            {
                bool success = false;
                try
                {
                    RecentTarget target = new RecentTarget
                    {
                        Host = "192.0.2.10",
                        User = "root",
                        Port = 2222,
                        LastUsedUtc = DateTime.UtcNow
                    };
                    SaveRecentTargets(new List<RecentTarget> { target });
                    OpenActionForCommandLine("1");
                    success = connectionHistory.Items.Count == 1 &&
                              connectionHostInput.Text == target.Host &&
                              connectionUserInput.Text == target.User &&
                              connectionPortInput.Text == target.Port.ToString() &&
                              // No matching managed key is created by this
                              // smoke, so authentication must remain explicit.
                              connectionAuthMode.SelectedIndex == 0;
                    // The explicit Use button remains idempotent and can be
                    // used after editing or switching history rows.
                    historyUseButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    success = success &&
                              connectionHostInput.Text == target.Host &&
                              connectionUserInput.Text == target.User &&
                              connectionPortInput.Text == target.Port.ToString() &&
                              connectionAuthMode.SelectedIndex == 0;
                    DeleteSelectedRecentTarget();
                    success = success && LoadRecentTargets().Count == 0;
                    string path = RecentTargetsPath();
                    if (File.Exists(path)) File.Delete(path);
                }
                catch
                {
                    success = false;
                }
                completion(success);
            }));
        }

        public void BeginLocalWorkflowSmoke(Action<int> completion)
        {
            OpenActionForCommandLine("14");
            workflowSmokeCompletion = completion;
            StartSelectedOperation();
            int ticks = 0;
            DispatcherTimer timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromMilliseconds(50);
            timer.Tick += delegate
            {
                ticks++;
                if (!operationRunning)
                {
                    timer.Stop();
                    return;
                }
                if (!operationInputPending)
                {
                    timer.Stop();
                    SendOperationInput("0");
                    return;
                }
                if (ticks >= 200)
                {
                    timer.Stop();
                    workflowSmokeCompletion = null;
                    completion(-2);
                }
            };
            timer.Start();
        }

        public void BeginInputCloseSmoke(Action<bool> completion)
        {
            RuntimeFiles runtime = EnsureRuntimeExtracted();
            ThreadPool.QueueUserWorkItem(delegate
            {
                bool success = false;
                try
                {
                    ProcessStartInfo start = new ProcessStartInfo();
                    start.FileName = runtime.CliPath;
                    start.Arguments = "--input-close-smoke";
                    start.UseShellExecute = false;
                    start.CreateNoWindow = true;
                    start.RedirectStandardInput = true;
                    start.RedirectStandardOutput = true;
                    start.RedirectStandardError = true;
                    using (Process process = Process.Start(start))
                    {
                        Thread.Sleep(100);
                        process.StandardInput.Close();
                        string output = process.StandardOutput.ReadToEnd();
                        string error = process.StandardError.ReadToEnd();
                        bool exited = process.WaitForExit(5000);
                        string marker = "PNA_INPUT_CLOSE_SMOKE_REQUIRED";
                        int first = output.IndexOf(marker, StringComparison.Ordinal);
                        int second = first < 0 ? -1 : output.IndexOf(marker, first + marker.Length, StringComparison.Ordinal);
                        success = exited && process.ExitCode == 0 && first >= 0 && second < 0 &&
                                  error.IndexOf("input-close smoke", StringComparison.OrdinalIgnoreCase) < 0;
                        if (!exited) try { process.Kill(); } catch { }
                    }
                }
                catch { }
                window.Dispatcher.BeginInvoke(new Action(delegate { completion(success); }));
            });
        }

        public void BeginPromptSequenceSmoke(Action<int> completion)
        {
            OperationInfo smokeOperation = new OperationInfo
            {
                Id = "14",
                Category = "local",
                ZhTitle = "多级提示协议测试",
                EnTitle = "Multi-step prompt protocol smoke",
                ZhDescription = "验证路径输出后仍能解锁备份编号和恢复确认。",
                EnDescription = "Verifies prompt unlock after path output and across restore confirmation.",
                Accent = "#12CBE8"
            };
            OpenOperationWorkspace(smokeOperation, false);
            backendArgumentsOverride = "--prompt-sequence-smoke";
            int stage = 0;
            int ticks = 0;
            bool timedOut = false;
            DispatcherTimer timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromMilliseconds(50);
            workflowSmokeCompletion = delegate(int code)
            {
                timer.Stop();
                completion(timedOut ? -2 : (code == 0 && stage == 2 ? 0 : 1));
            };
            StartSelectedOperation();
            timer.Tick += delegate
            {
                ticks++;
                if (!operationRunning) return;
                if (ticks >= 200)
                {
                    timedOut = true;
                    timer.Stop();
                    try { activeProcess.Kill(); } catch { completion(-2); }
                    return;
                }
                if (operationInputPending) return;
                string prompt = operationPromptText.Text ?? "";
                if (stage == 0 && (prompt.Contains("备份编号") || prompt.IndexOf("backup number", StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    stage = 1;
                    SendOperationInput("1");
                    return;
                }
                if (stage == 1 && (prompt.Contains("目标恢复") || prompt.IndexOf("restore to this target", StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    stage = 2;
                    SendOperationInput("y");
                    return;
                }
            };
            timer.Start();
        }

        public void BeginAskPassSmoke(Action<bool> completion)
        {
            RuntimeFiles runtime = EnsureRuntimeExtracted();
            askPassSmokeResponse = "gui-secure-pipe-smoke";
            StartAskPassServer();
            ThreadPool.QueueUserWorkItem(delegate
            {
                bool success = false;
                try
                {
                    ProcessStartInfo start = new ProcessStartInfo();
                    start.FileName = runtime.AskPassPath;
                    start.Arguments = "\"GUI secure prompt\"";
                    start.UseShellExecute = false;
                    start.CreateNoWindow = true;
                    start.RedirectStandardOutput = true;
                    start.EnvironmentVariables["PNA_ASKPASS_PIPE"] = askPassPipeName;
                    using (Process helper = Process.Start(start))
                    {
                        string output = helper.StandardOutput.ReadToEnd().Trim();
                        helper.WaitForExit();
                        success = helper.ExitCode == 0 && output == "gui-secure-pipe-smoke";
                    }
                }
                catch { }
                StopAskPassServer();
                window.Dispatcher.BeginInvoke(new Action(delegate { completion(success); }));
            });
        }

        private static List<OperationInfo> CreateOperations()
        {
            return new List<OperationInfo>
            {
                Op("1", "install", "安装 / 升级 / 自适应优化", "Install / upgrade / adaptive convergence", "唯一安装入口；收尾可选整理备份，再决定是否打开面板。", "The only install entry; optionally prune backups before opening the panel.", "#22D3EE"),
                Op("2", "access", "无感打开 3x-ui 面板", "Open the 3x-ui panel", "通过 127.0.0.1 SSH 隧道打开后台，不暴露公网面板端口。", "Open through a 127.0.0.1 SSH tunnel without exposing the panel publicly.", "#38BDF8"),
                Op("3", "maintain", "自动体检与排障", "Automatic diagnosis", "结构化检查 SSH、x-ui、Nginx、WARP、订阅和端口状态。", "Structured checks for SSH, x-ui, Nginx, WARP, subscriptions, and ports.", "#34D399"),
                Op("4", "maintain", "安全自动修复", "Safe automatic repair", "先备份，再根据体检结果修复可自动处理的问题。", "Back up first, then repair issues that are safe to automate.", "#34D399"),
                Op("5", "security", "VPS 登录密码：随机或自定义", "VPS login password: random or custom", "可生成随机密码，也可遮罩输入自定义密码；输出经过校验的凭据交接单。", "Generate a random password or enter a masked custom value; produce a validated credential handoff.", "#FBBF24"),
                Op("6", "security", "3x-ui 账号密码：随机或自定义", "3x-ui credentials: random or custom", "可随机或自定义面板账号/密码；秘密只在本次 SSH 操作中使用。", "Randomize or set a custom panel account/password; secrets are used only for this SSH operation.", "#FBBF24"),
                Op("7", "access", "显示当前凭据交接单", "Show current credential handoff", "读取真实面板元数据并复制到 Windows 剪贴板。", "Read validated panel metadata and copy the handoff to the clipboard.", "#38BDF8"),
                Op("8", "maintain", "切换 15 套伪装站与优化 Nginx", "Switch 15 cover templates and optimize Nginx", "随机、按域名稳定选择或指定 1—15；包含原创离线像素跑酷。", "Choose random, stable-per-domain, or exact 1-15; includes an original offline pixel runner.", "#34D399"),
                Op("9", "backup", "完整灾难恢复备份", "Full disaster-recovery backup", "包含程序与远端节点配置，适合迁移或严重故障恢复，体积较大。", "Includes the program and remote-node configuration for migration or recovery; larger archive.", "#A78BFA"),
                Op("10", "backup", "生成紧急诊断报告", "Generate emergency report", "采集经过裁剪的故障证据并下载到当前 Windows。", "Collect a bounded diagnostic package and download it to this Windows PC.", "#A78BFA"),
                Op("11", "access", "绑定 / 重新生成 SSH key", "Bind / regenerate SSH key", "先验证新钥匙，再撤销旧公钥；避免把自己锁在 VPS 外。", "Verify the new key before revoking the old one to prevent lockout.", "#38BDF8"),
                Op("12", "local", "清空 Windows 剪贴板", "Clear Windows clipboard", "立即清除可能仍包含密码或密钥的本地剪贴板。", "Immediately remove passwords or keys that may remain on the clipboard.", "#94A3B8"),
                Op("13", "security", "卸载远端内嵌工具包", "Uninstall remote toolkit", "只删除管理工具，保留节点、配置、凭据、证书与备份。", "Remove management tooling while preserving node data, credentials, and backups.", "#FBBF24"),
                Op("14", "local", "本地 10808 代理环境", "Local 10808 proxy environment", "配置、撤销或查看 HTTP_PROXY / HTTPS_PROXY，不登录 VPS。", "Configure, remove, or inspect proxy variables without a VPS connection.", "#94A3B8"),
                Op("15", "backup", "整理远端备份", "Prune remote backups", "验证一份当前配置备份后，精确清理本工具产生的冗余旧包。", "Verify one current-config backup, then remove only known redundant archives.", "#A78BFA"),
                Op("16", "maintain", "自适应性能档位", "Adaptive performance profiles", "检测硬件后选择低配、标准、高配或自动档；改动前备份，支持一键回滚。", "Detect capacity, then apply low, standard, high, or auto settings with backup and one-step rollback.", "#34D399"),
                Op("17", "maintain", "SSH / vnStat 流量估算", "SSH / vnStat traffic estimate", "通过 VPS 本地计数估算当期流量，并在 70%、85%、95% 分级预警。", "Estimate period traffic from VPS counters with tiered warnings at 70%, 85%, and 95%.", "#34D399"),
                Op("18", "security", "全量拆除与恢复基线", "Full dismantle and baseline restore", "高风险双重确认；先把完整救援包下载到 Windows，再拆除受管节点栈并保留 SSH 救援通道。", "High-risk double confirmation; download a full Windows rescue first, then remove the managed node stack while preserving SSH rescue access.", "#FB7185"),
                Op("19", "security", "识别本机 IP 并添加 SS2022 白名单", "Detect local IP and add to SS2022 allowlist", "先在本机直连识别公网 IPv4，再与 VPS 看到的 SSH 来源核对；明确确认后才加入 SS2022 精确白名单。", "Detect the public IPv4 locally, compare it with the source seen by the VPS, and add the exact source to the SS2022 TCP allowlist only after explicit confirmation.", "#FBBF24"),
                Op("24", "security", "管理 SS2022 白名单", "Manage SS2022 allowlist", "查看当前精确 IPv4 白名单，或自由添加、删除一个公网 IPv4；不接受 CIDR 或网段。", "View the exact-IPv4 allowlist, or freely add/remove one public IPv4; CIDR ranges are never accepted.", "#FBBF24"),
                Op("20", "security", "访问与封禁日志", "Access and ban events", "按需读取 SSH、Fail2ban、防火墙和入口的聚合元数据；可明确确认后应用受管安全基线。", "Read bounded SSH, Fail2ban, firewall, and ingress metadata; apply the managed security baseline only after explicit confirmation.", "#FBBF24"),
                Op("22", "maintain", "CDN/XHTTP 线路控制中心", "CDN/XHTTP route control center", "保留灰云/橙云/XHTTP 分阶段施工、边缘验收、真实客户端提交、回滚和组件清理；每个公网变更均需明确确认。", "Retain gray/orange CDN-XHTTP staging, edge validation, real-client commit, rollback, and component cleanup; every public mutation requires explicit confirmation.", "#22D3EE"),
                Op("23", "security", "更换公网 IP 后安全重绑定", "Safely rebind a changed public IP", "复用原 SSH key，并在 Host Key、machine-id、NODE_ID/SERVER_ID 全部一致后才提交新地址。", "Reuse the original SSH key and commit a new endpoint only after host key, machine-id, and NODE_ID/SERVER_ID all match.", "#A78BFA"),
                Op("T", "local", "服务商流量中心", "Provider traffic center", "KiwiVM 精确 API、兼容 API 与 Windows Credential Manager；不保存服务商网站密码。", "Exact KiwiVM API, compatible APIs, and Windows Credential Manager; provider website passwords are never stored.", "#94A3B8"),
                Op("K", "access", "管理已绑定节点 key", "Manage bound node keys", "查看、恢复或归档；支持一次清空全部绑定位置且不自动填充。", "Inspect, restore, or archive every bound position without auto-fill.", "#38BDF8"),
                Op("H", "local", "管理 VPS 登录历史", "Manage VPS login history", "查看、删除单条或清空地址历史；不保存密码和 key。", "View, delete, or clear target history; passwords and keys are never stored.", "#94A3B8")
            };
        }

        private static OperationInfo Op(string id, string category, string zhTitle, string enTitle, string zhDescription, string enDescription, string accent)
        {
            return new OperationInfo
            {
                Id = id,
                Category = category,
                ZhTitle = zhTitle,
                EnTitle = enTitle,
                ZhDescription = zhDescription,
                EnDescription = enDescription,
                Accent = accent
            };
        }
    }

    internal static class Program
    {
        private static BitmapImage LoadApplicationIcon(Assembly assembly)
        {
            using (Stream stream = assembly.GetManifestResourceStream("ProxyNodeAssistant.AppIcon.png"))
            {
                if (stream == null) throw new InvalidOperationException("Embedded application icon is missing.");
                BitmapImage bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }
        }

        private static string ArgumentValue(string[] args, string name)
        {
            for (int index = 0; index + 1 < args.Length; index++)
            {
                if (String.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
                {
                    return args[index + 1];
                }
            }
            return null;
        }

        private static bool HasArgument(string[] args, string name)
        {
            foreach (string value in args)
            {
                if (String.Equals(value, name, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static void RenderPreview(Window window, string path)
        {
            const int width = 1280;
            const int height = 820;
            FrameworkElement content = window.Content as FrameworkElement;
            if (content == null) throw new InvalidOperationException("The GUI root content cannot be rendered.");
            content.Width = width;
            content.Height = height;
            content.Measure(new Size(width, height));
            content.Arrange(new Rect(0, 0, width, height));
            content.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            string fullPath = IOPath.GetFullPath(path);
            string parent = IOPath.GetDirectoryName(fullPath);
            if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            using (FileStream stream = File.Create(fullPath)) encoder.Save(stream);
        }

        [STAThread]
        private static void Main()
        {
            try
            {
                Assembly assembly = Assembly.GetExecutingAssembly();
                MainController.ValidateEmbeddedRuntimeArchitecture(assembly);
                Window window;
                using (Stream stream = assembly.GetManifestResourceStream("ProxyNodeAssistant.MainWindow.xaml"))
                {
                    if (stream == null) throw new InvalidOperationException("Embedded XAML resource is missing.");
                    using (XmlReader reader = XmlReader.Create(stream))
                    {
                        window = (Window)XamlReader.Load(reader);
                    }
                }
                BitmapImage applicationIcon = LoadApplicationIcon(assembly);
                window.Icon = applicationIcon;
                Image brandIcon = window.FindName("BrandIcon") as Image;
                if (brandIcon != null) brandIcon.Source = applicationIcon;
                Application application = new Application();
                application.ShutdownMode = ShutdownMode.OnMainWindowClose;
                application.MainWindow = window;
                MainController controller = new MainController(application, window);
                string[] commandLine = Environment.GetCommandLineArgs();
                string dashboardPreview = ArgumentValue(commandLine, "--render-preview");
                string operationPreview = ArgumentValue(commandLine, "--render-operation-preview");
                string openAction = ArgumentValue(commandLine, "--open-action");
                bool workflowSmoke = HasArgument(commandLine, "--workflow-smoke");
                bool inputCloseSmoke = HasArgument(commandLine, "--input-close-smoke");
                bool promptSequenceSmoke = HasArgument(commandLine, "--prompt-sequence-smoke");
                bool askPassSmoke = HasArgument(commandLine, "--askpass-smoke");
                bool tunnelLifetimeSmoke = HasArgument(commandLine, "--tunnel-lifetime-smoke");
                string historySmokePath = ArgumentValue(commandLine, "--history-smoke");
                if (!String.IsNullOrEmpty(historySmokePath)) Environment.SetEnvironmentVariable("PNA_HISTORY_PATH", historySmokePath);
                string preview = String.IsNullOrEmpty(operationPreview) ? dashboardPreview : operationPreview;
                controller.Initialize(String.IsNullOrEmpty(preview));
                if (!String.IsNullOrEmpty(operationPreview)) controller.PrepareOperationPreview();
                if (!String.IsNullOrEmpty(preview))
                {
                    RenderPreview(window, preview);
                    GC.KeepAlive(controller);
                    return;
                }
                if (!String.IsNullOrEmpty(openAction)) controller.OpenActionForCommandLine(openAction);
                if (workflowSmoke)
                {
                    controller.BeginLocalWorkflowSmoke(delegate(int code)
                    {
                        Environment.ExitCode = code;
                        window.Close();
                    });
                }
                if (inputCloseSmoke)
                {
                    controller.BeginInputCloseSmoke(delegate(bool success)
                    {
                        Environment.ExitCode = success ? 0 : 1;
                        window.Close();
                    });
                }
                if (promptSequenceSmoke)
                {
                    controller.BeginPromptSequenceSmoke(delegate(int code)
                    {
                        Environment.ExitCode = code;
                        window.Close();
                    });
                }
                if (askPassSmoke)
                {
                    controller.BeginAskPassSmoke(delegate(bool success)
                    {
                        Environment.ExitCode = success ? 0 : 1;
                        window.Close();
                    });
                }
                if (tunnelLifetimeSmoke)
                {
                    controller.BeginTunnelLifetimeSmoke(delegate(bool success)
                    {
                        Environment.ExitCode = success ? 0 : 1;
                        window.Close();
                    });
                }
                if (!String.IsNullOrEmpty(historySmokePath))
                {
                    controller.BeginHistorySmoke(delegate(bool success)
                    {
                        Environment.ExitCode = success ? 0 : 1;
                        window.Close();
                    });
                }
                application.Run(window);
                GC.KeepAlive(controller);
            }
            catch (Exception error)
            {
                // Keep startup failures actionable for end users.  A full
                // exception.ToString() here used to bury the useful
                // architecture guidance in a stack trace.
                MessageBox.Show("ProxyNodeAssistant GUI could not start:\n\n" + error.Message, "ProxyNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }
}
