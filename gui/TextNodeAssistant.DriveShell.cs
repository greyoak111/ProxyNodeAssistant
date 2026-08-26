using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Xml;
using IOPath = System.IO.Path;

namespace TextNodeAssistant.Gui
{
    // These protocol DTO fields are populated by DataContractJsonSerializer
    // through reflection; the compiler cannot see those assignments.
#pragma warning disable 0649
    [DataContract]
    internal sealed class LocalAdminProtocolResult
    {
        [DataMember(Name = "status")] public string Status;
        [DataMember(Name = "deviceId")] public string DeviceId;
        [DataMember(Name = "username")] public string Username;
        [DataMember(Name = "password")] public string Password;
        [DataMember(Name = "recoveryCode")] public string RecoveryCode;
        [DataMember(Name = "recoveryPath")] public string RecoveryPath;
    }

    [DataContract]
    internal sealed class DriveSessionProtocolResult
    {
        [DataMember(Name = "version")] public int Version;
        [DataMember(Name = "nodeId")] public string NodeId;
        [DataMember(Name = "deviceId")] public string DeviceId;
        [DataMember(Name = "role")] public string Role;
        [DataMember(Name = "url")] public string Url;
        [DataMember(Name = "username")] public string Username;
        [DataMember(Name = "password")] public string Password;
        [DataMember(Name = "spacePath")] public string SpacePath;
    }

    [DataContract]
    internal sealed class DriveAccountProtocolResult
    {
        [DataMember(Name = "version")] public int Version;
        [DataMember(Name = "nodeId")] public string NodeId;
        [DataMember(Name = "accountId")] public string AccountId;
        [DataMember(Name = "spaceId")] public string SpaceId;
        [DataMember(Name = "username")] public string Username;
        [DataMember(Name = "password")] public string Password;
        [DataMember(Name = "quotaGiB")] public string QuotaGiB;
    }
#pragma warning restore 0649

    [DataContract]
    internal sealed class LocalUISecuritySettings
    {
        [DataMember(Name = "advancedGateEnabled")] public bool AdvancedGateEnabled = true;
        [DataMember(Name = "sessionTimeoutMinutes")] public int SessionTimeoutMinutes = 15;
    }

    internal sealed class DriveFileItem
    {
        public string Name { get; set; }
        public string Type { get; set; }
        public long Size { get; set; }
        public string SizeText { get; set; }
        public string Modified { get; set; }
        public string Href { get; set; }
        public bool IsDirectory { get; set; }
    }

    internal sealed class DriveMountItem
    {
        public string Letter { get; set; }
        public string Node { get; set; }
        public string Mode { get; set; }
        public string Status { get; set; }
        internal string NodeId;
        internal Process RcloneProcess;
        internal Process TunnelProcess;
        internal readonly StringBuilder Diagnostics = new StringBuilder();
    }

    internal sealed partial class MainController
    {
        private const string LocalAdminResultPrefix = "TNA_LOCAL_ADMIN_RESULT_B64=";
        private const string DriveSessionSecretPrefix = "TNA_DRIVE_SESSION_SECRET_B64=";
        private const string DriveAccountResultPrefix = "TNA_DRIVE_ACCOUNT_RESULT_B64=";

        private sealed class EngineResult
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
        }

        private sealed class DriveTargetOption
        {
            public RecentTarget Target;
            public bool Bound;
            public override string ToString()
            {
                return Target.ToString() + (Bound ? "  [BOUND]" : "  [NO KEY]");
            }
        }

        private Border driveShell;
        private Grid driveLoginView;
        private Grid driveSetupView;
        private Grid driveWorkspaceView;
        private Border driveAdminSetupPanel;
        private Border driveNoNodeBanner;
        private ComboBox driveNodeSelector;
        private TextBox driveUsernameInput;
        private PasswordBox drivePasswordInput;
        private PasswordBox driveAdminNewPassword;
        private PasswordBox driveAdminConfirmPassword;
        private Button driveLoginButton;
        private Button driveRegisterButton;
        private Button driveRecoverAdminButton;
        private Button driveShowSetupButton;
        private Button driveSetupBackButton;
        private Button driveOpenAdvancedButton;
        private Button returnToDriveButton;
        private DataGrid driveFileGrid;
        private TextBlock driveCurrentPathText;
        private TextBlock driveWorkspaceStatus;
        private TextBlock driveLoginStatus;
        private TextBlock driveSessionAccountText;
        private TextBlock driveSessionNodeText;
        private Grid driveFilesPanel;
        private Grid driveMountPanel;
        private ComboBox driveMountLetter;
        private RadioButton driveMountReadOnly;
        private RadioButton driveMountReadWrite;
        private DataGrid driveMountGrid;
        private TextBlock driveMountDependencyStatus;
        private TextBlock driveMountStatus;
        private readonly List<DriveMountItem> activeDriveMounts = new List<DriveMountItem>();
        private readonly object driveMountGate = new object();
        private Process driveSessionProcess;
        private readonly object driveSessionGate = new object();
        private readonly Dictionary<Process, StringBuilder> driveSessionDiagnostics = new Dictionary<Process, StringBuilder>();
        private DriveSessionProtocolResult driveSession;
        private DriveTargetOption driveActiveTarget;
        private string driveCurrentPath;
        private bool localAdminReady;
        private bool localAdminProbeComplete;
        private bool localAdminProbeInFlight;
        private bool advancedOpenPending;
        private bool driveBusy;
        private DateTime advancedUnlockedUntilUtc = DateTime.MinValue;

        private void InitializeDriveShell()
        {
            driveShell = Find<Border>("DriveShell");
            driveLoginView = Find<Grid>("DriveLoginView");
            driveSetupView = Find<Grid>("DriveSetupView");
            driveWorkspaceView = Find<Grid>("DriveWorkspaceView");
            driveAdminSetupPanel = Find<Border>("DriveAdminSetupPanel");
            driveNoNodeBanner = Find<Border>("DriveNoNodeBanner");
            driveNodeSelector = Find<ComboBox>("DriveNodeSelector");
            driveUsernameInput = Find<TextBox>("DriveUsernameInput");
            drivePasswordInput = Find<PasswordBox>("DrivePasswordInput");
            driveAdminNewPassword = Find<PasswordBox>("DriveAdminNewPassword");
            driveAdminConfirmPassword = Find<PasswordBox>("DriveAdminConfirmPassword");
            driveLoginButton = Find<Button>("DriveLoginButton");
            driveRegisterButton = Find<Button>("DriveRegisterButton");
            driveRecoverAdminButton = Find<Button>("DriveRecoverAdminButton");
            driveShowSetupButton = Find<Button>("DriveShowSetupButton");
            driveSetupBackButton = Find<Button>("DriveSetupBackButton");
            driveOpenAdvancedButton = Find<Button>("DriveOpenAdvancedButton");
            returnToDriveButton = Find<Button>("ReturnToDriveButton");
            driveFileGrid = Find<DataGrid>("DriveFileGrid");
            driveCurrentPathText = Find<TextBlock>("DriveCurrentPath");
            driveWorkspaceStatus = Find<TextBlock>("DriveWorkspaceStatus");
            driveLoginStatus = Find<TextBlock>("DriveLoginStatus");
            driveSessionAccountText = Find<TextBlock>("DriveSessionAccount");
            driveSessionNodeText = Find<TextBlock>("DriveSessionNode");
            driveFilesPanel = Find<Grid>("DriveFilesPanel");
            driveMountPanel = Find<Grid>("DriveMountPanel");
            driveMountLetter = Find<ComboBox>("DriveMountLetter");
            driveMountReadOnly = Find<RadioButton>("DriveMountReadOnly");
            driveMountReadWrite = Find<RadioButton>("DriveMountReadWrite");
            driveMountGrid = Find<DataGrid>("DriveMountGrid");
            driveMountDependencyStatus = Find<TextBlock>("DriveMountDependencyStatus");
            driveMountStatus = Find<TextBlock>("DriveMountStatus");

            Find<Button>("DriveLanguageButton").Click += delegate { english = !english; SaveLanguage(); UpdateLanguage(); };
            Find<Button>("DriveMinimizeButton").Click += delegate { window.WindowState = WindowState.Minimized; };
            Find<Button>("DriveMaximizeButton").Click += delegate { ToggleMaximize(); };
            Find<Button>("DriveCloseButton").Click += delegate { window.Close(); };
            Find<Button>("DriveRefreshNodesButton").Click += delegate { RefreshDriveTargets(); };
            driveLoginButton.Click += delegate { BeginDriveLogin(); };
            driveRegisterButton.Click += delegate { BeginOuterRegistration(); };
            driveRecoverAdminButton.Click += delegate { RecoverLocalAdmin(); };
            driveShowSetupButton.Click += delegate { ShowDriveSetup(); };
            driveSetupBackButton.Click += delegate { ShowDriveLogin(); };
            Find<Button>("DriveCreateAdminButton").Click += delegate { CreateLocalAdmin(); };
            driveOpenAdvancedButton.Click += delegate { RequestAdvancedConsole(); };
            Find<Button>("DriveAdvancedNavButton").Click += delegate { RequestAdvancedConsole(); };
            returnToDriveButton.Click += delegate { ShowDriveShell(); };
            Find<Button>("DriveLogoutButton").Click += delegate { EndDriveSession(true); };
            Find<Button>("DriveWorkspaceRefreshButton").Click += delegate { RefreshDriveFiles(); };
            Find<Button>("DriveUpButton").Click += delegate { NavigateDriveUp(); };
            Find<Button>("DriveNewFolderButton").Click += delegate { CreateDriveFolder(); };
            Find<Button>("DriveUploadButton").Click += delegate { UploadDriveFile(); };
            Find<Button>("DriveDownloadButton").Click += delegate { DownloadDriveFile(); };
            Find<Button>("DriveRenameButton").Click += delegate { RenameDriveItem(); };
            Find<Button>("DriveDeleteButton").Click += delegate { TrashDriveItem(); };
            Find<Button>("DriveFilesNavButton").Click += delegate { ShowDriveFilesPanel(); };
            Find<Button>("DriveTransfersNavButton").Click += delegate
            {
                MessageBox.Show(window, english ? "Transfers run in this window. Active transfers expose progress in the status bar; completed items remain in this session only." : "传输任务在当前窗口执行；进行中任务会在状态栏显示进度，已完成记录只保留到本次退出。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
            };
            Find<Button>("DriveAccountNavButton").Click += delegate { ShowOuterAccountActions(); };
            Find<Button>("DriveMountNavButton").Click += delegate { ShowDriveMountPanel(); };
            Find<Button>("DriveMountRefreshButton").Click += delegate { RefreshDriveMountStatus(); };
            Find<Button>("DriveMountInstallButton").Click += delegate { InstallOrVerifyMountDependencies(); };
            Find<Button>("DriveMountStartButton").Click += delegate { BeginDriveMount(); };
            Find<Button>("DriveUnmountButton").Click += delegate { UnmountSelectedDrive(true); };
            Find<Button>("DriveMountOpenButton").Click += delegate { OpenSelectedDriveMount(); };
            driveFileGrid.MouseDoubleClick += delegate
            {
                DriveFileItem item = driveFileGrid.SelectedItem as DriveFileItem;
                if (item != null && item.IsDirectory)
                {
                    driveCurrentPath = item.Href;
                    RefreshDriveFiles();
                }
            };

            RefreshDriveTargets();
            ProbeLocalAdminStatus();
            // Dependency probing includes extracting and validating the embedded
            // rclone/WinFsp payloads.  Do not make the login window wait for it.
            RefreshDriveMountStatus();
            driveShell.Visibility = Visibility.Visible;
            ShowDriveLogin();
        }

        private void UpdateDriveLanguage()
        {
            if (driveShell == null) return;
            Find<Button>("DriveLanguageButton").Content = english ? "中" : "EN";
            Find<TextBlock>("DriveLoginTitle").Text = english ? "Enter your private file space" : "进入私人文件空间";
            Find<TextBlock>("DriveLoginDescription").Text = english ? "Verify this device first, then enter the outer file space. No public drive port is exposed; only an SSH loopback tunnel is used." : "先验证当前设备，再进入外层文件空间。网盘不暴露公网端口，只通过 SSH 回环隧道工作。";
            Find<TextBlock>("DriveNodeLabel").Text = english ? "Node / VPS" : "节点 / VPS";
            Find<TextBlock>("DriveUserLabel").Text = english ? "Account" : "账号";
            Find<TextBlock>("DrivePasswordLabel").Text = english ? "Password" : "密码";
            Find<TextBlock>("DriveLoginHint").Text = english ? "Ordinary users enter the node drive password. admin enters the local admin password, which is never sent to the VPS." : "普通账号使用节点网盘密码；admin 使用本机 admin 密码，绝不会发送到 VPS。";
            driveLoginButton.Content = english ? "Verify device and sign in  →" : "验证设备并登录  →";
            driveRegisterButton.Content = english ? "Register ordinary account" : "注册普通账号";
            driveRecoverAdminButton.Content = english ? "Recover local admin" : "恢复本机 admin";
            driveShowSetupButton.Content = english ? "Open local setup" : "打开本机设置";
            driveSetupBackButton.Content = english ? "\uE72B  Back to sign-in" : "\uE72B  返回登录";
            driveOpenAdvancedButton.Content = english ? "Open advanced operations" : "打开高级运维控制台";
            returnToDriveButton.Content = english ? "Private drive" : "私人网盘";
            Find<TextBlock>("DriveMountTitle").Text = english ? "Mounts and nodes" : "挂载与节点";
            Find<TextBlock>("DriveMountSubtitle").Text = english ? "PINNED RCLONE + WINFSP / ONE LETTER PER VPS" : "固定校验 rclone + WinFsp · 每台 VPS 独立盘符";
            Find<TextBlock>("DriveMountDependencyTitle").Text = english ? "01 // LOCAL DEPENDENCIES" : "01 // 本机依赖";
            Find<TextBlock>("DriveMountModeTitle").Text = english ? "02 // NEW MOUNT" : "02 // 新建挂载";
            Find<TextBlock>("DriveMountLetterLabel").Text = english ? "Letter" : "盘符";
            driveMountReadOnly.Content = english ? "Read-only browser drive (recommended)" : "只读浏览盘（推荐）";
            driveMountReadWrite.Content = english ? "Small-file read/write (cache risk)" : "小文件读写盘（有缓存风险）";
            Find<Button>("DriveMountRefreshButton").Content = english ? "Refresh status" : "刷新状态";
            Find<Button>("DriveMountInstallButton").Content = english ? "Install / verify WinFsp and rclone" : "安装 / 验证 WinFsp 与 rclone";
            Find<Button>("DriveMountStartButton").Content = english ? "Mount the signed-in node" : "挂载当前已登录节点";
            Find<Button>("DriveMountOpenButton").Content = english ? "Open drive" : "打开盘符";
            Find<Button>("DriveUnmountButton").Content = english ? "Safely unmount selected" : "安全卸载所选";
            if (driveWorkspaceView.Visibility == Visibility.Visible)
                Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / SPACE" : "TNA // PRIVATE VAULT / 文件空间";
            else if (driveSetupView.Visibility == Visibility.Visible)
                Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / LOCAL SETUP" : "TNA // PRIVATE VAULT / 本机设置";
            else
                Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / SIGN-IN" : "TNA // PRIVATE VAULT / 登录";
        }

        private void ProbeLocalAdminStatus()
        {
            if (localAdminProbeInFlight) return;
            localAdminProbeInFlight = true;
            localAdminProbeComplete = false;
            Thread worker = new Thread(new ThreadStart(delegate
            {
                try
                {
                    EngineResult result = RunEngineCommand("--local-admin status", null, 15000);
                    LocalAdminProtocolResult status = DecodeFrame<LocalAdminProtocolResult>(result.Stdout, LocalAdminResultPrefix);
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        localAdminReady = result.ExitCode == 0 && status != null && status.Status == "READY";
                        localAdminProbeInFlight = false;
                        localAdminProbeComplete = true;
                        driveAdminSetupPanel.Visibility = localAdminReady ? Visibility.Collapsed : Visibility.Visible;
                        if (!localAdminReady && result.ExitCode != 0)
                            Find<TextBlock>("DriveAdminSetupDescription").Text = DescribeLocalAdminFailure(result);
                        ContinuePendingAdvancedConsole();
                    }));
                }
                catch (Exception error)
                {
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        localAdminProbeInFlight = false;
                        localAdminProbeComplete = true;
                        driveAdminSetupPanel.Visibility = Visibility.Visible;
                        Find<TextBlock>("DriveAdminSetupDescription").Text = (english ? "Local admin status could not be verified: " : "无法验证本机 admin 状态：") + error.Message;
                        ContinuePendingAdvancedConsole();
                    }));
                }
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private void ContinuePendingAdvancedConsole()
        {
            if (!advancedOpenPending) return;
            advancedOpenPending = false;
            // The first click may arrive while the status probe is still in
            // flight. Continue it only after the probe has produced an
            // authoritative READY/NOT_CONFIGURED result.
            window.Dispatcher.BeginInvoke(new Action(delegate { RequestAdvancedConsole(); }));
        }

        private void ShowDriveSetup()
        {
            driveWorkspaceView.Visibility = Visibility.Collapsed;
            driveLoginView.Visibility = Visibility.Collapsed;
            driveSetupView.Visibility = Visibility.Visible;
            Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / LOCAL SETUP" : "TNA // PRIVATE VAULT / 本机设置";
            Find<TextBlock>("DriveTopStatus").Text = english ? "LOCAL SETUP / NO VPS CONNECTION" : "本机设置 / 不连接 VPS";
        }

        private void ShowDriveLogin()
        {
            driveWorkspaceView.Visibility = Visibility.Collapsed;
            driveSetupView.Visibility = Visibility.Collapsed;
            driveLoginView.Visibility = Visibility.Visible;
            Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / SIGN-IN" : "TNA // PRIVATE VAULT / 登录";
            if (driveSession == null)
                Find<TextBlock>("DriveTopStatus").Text = english ? "LOCAL-FIRST / SSH LOOPBACK / NO PUBLIC DRIVE PORT" : "本机优先 / SSH 回环 / 不开放网盘公网端口";
        }

        private EngineResult RunEngineCommand(string arguments, string input, int timeoutMilliseconds)
        {
            RuntimeFiles runtime = EnsureRuntimeExtracted();
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = runtime.CliPath;
            start.Arguments = arguments;
            start.WorkingDirectory = IOPath.GetDirectoryName(runtime.CliPath);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.StandardOutputEncoding = new UTF8Encoding(false);
            start.StandardErrorEncoding = new UTF8Encoding(false);
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("Embedded engine did not start.");
                if (input != null) process.StandardInput.Write(input);
                process.StandardInput.Close();
                string stdout = process.StandardOutput.ReadToEnd();
                string stderr = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("Embedded engine timed out.");
                }
                return new EngineResult { ExitCode = process.ExitCode, Stdout = stdout, Stderr = stderr };
            }
        }

        private static T DecodeFrame<T>(string output, string prefix) where T : class
        {
            if (output == null) return null;
            foreach (string line in output.Replace("\r\n", "\n").Split('\n'))
            {
                if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue;
                byte[] data = Convert.FromBase64String(line.Substring(prefix.Length));
                using (MemoryStream stream = new MemoryStream(data))
                {
                    return new DataContractJsonSerializer(typeof(T)).ReadObject(stream) as T;
                }
            }
            return null;
        }

        private static bool ValidLocalAdminPassword(string value)
        {
            if (String.IsNullOrEmpty(value) || value.Length < 14 || value.Length > 128) return false;
            foreach (char character in value)
                if (character < 0x20 || character > 0x7E) return false;
            return true;
        }

        private string DescribeLocalAdminFailure(EngineResult result)
        {
            StringBuilder text = new StringBuilder();
            text.Append(english ? "embedded local-admin command failed" : "内嵌本机 admin 命令失败");
            if (result != null) text.Append(" (exit ").Append(result.ExitCode).Append(")");
            string detail = result == null ? "" : ((result.Stderr ?? "") + "\n" + (result.Stdout ?? "")).Trim();
            if (!String.IsNullOrWhiteSpace(detail)) text.Append("\n").Append(detail);
            return text.ToString();
        }

        private void CreateLocalAdmin()
        {
            string first = driveAdminNewPassword.Password;
            string second = driveAdminConfirmPassword.Password;
            if (first != second || !ValidLocalAdminPassword(first))
            {
                MessageBox.Show(window, english ? "Enter the same 14-128 character printable-ASCII local admin password twice." : "请两次输入完全相同的 14—128 位可打印 ASCII 本机 admin 密码（14—128 位）。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            driveAdminNewPassword.Clear();
            driveAdminConfirmPassword.Clear();
            Thread worker = new Thread(new ThreadStart(delegate
            {
                EngineResult result;
                try { result = RunEngineCommand("--local-admin create", first + "\n" + second + "\n\n", 60000); }
                catch (Exception error) { result = new EngineResult { ExitCode = -1, Stderr = error.Message }; }
                LocalAdminProtocolResult created = result.ExitCode == 0 ? DecodeFrame<LocalAdminProtocolResult>(result.Stdout, LocalAdminResultPrefix) : null;
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    if (created == null || created.Status != "READY" || String.IsNullOrWhiteSpace(created.RecoveryCode) || String.IsNullOrWhiteSpace(created.RecoveryPath))
                    {
                        MessageBox.Show(window, DescribeLocalAdminFailure(result), "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                        return;
                    }
                    localAdminReady = true;
                    driveAdminSetupPanel.Visibility = Visibility.Collapsed;
                    string handoff = "LOCAL_ADMIN_USERNAME=admin\r\nLOCAL_ADMIN_PASSWORD=" + first + "\r\nLOCAL_ADMIN_RECOVERY_CODE=" + created.RecoveryCode + "\r\nLOCAL_ADMIN_RECOVERY_PACKAGE=" + created.RecoveryPath;
                    Clipboard.SetText(handoff);
                    MessageBox.Show(window,
                        (english ? "Local admin is ready. The complete handoff is on the clipboard. Store the package and recovery code separately.\n\n" : "本机 admin 已创建；完整交接内容已复制。恢复包与恢复码必须分开保存。\n\n") +
                        created.RecoveryPath + "\n\nRECOVERY CODE: " + created.RecoveryCode,
                        "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private void RecoverLocalAdmin()
        {
            MessageBoxResult system = MessageBox.Show(window,
                english ? "Try recovery from Windows Credential Manager? Choose No to import a .tna recovery package instead." : "先尝试从 Windows 凭据管理器恢复？选择“否”可导入 .tna 恢复包。",
                "TextNodeAssistant", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (system == MessageBoxResult.Cancel) return;
            if (system == MessageBoxResult.Yes)
            {
                Thread worker = new Thread(new ThreadStart(delegate
                {
                    EngineResult result;
                    try { result = RunEngineCommand("--local-admin recover-system", null, 60000); }
                    catch (Exception error) { result = new EngineResult { ExitCode = -1, Stderr = error.Message }; }
                    LocalAdminProtocolResult recovered = result.ExitCode == 0 ? DecodeFrame<LocalAdminProtocolResult>(result.Stdout, LocalAdminResultPrefix) : null;
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        if (recovered == null)
                        {
                            MessageBox.Show(window, DescribeLocalAdminFailure(result) + "\n\n" + (english ? "Use the .tna package and separate recovery code if available." : "如果你保存过 .tna 恢复包和恢复码，请改用恢复包入口。"), "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                            return;
                        }
                        Clipboard.SetText("LOCAL_ADMIN_USERNAME=admin\r\nLOCAL_ADMIN_PASSWORD=" + recovered.Password);
                        MessageBox.Show(window, english ? "The original local admin credential was copied. Clear the clipboard after saving it." : "原本机 admin 凭据已复制；保存后请清空剪贴板。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                    }));
                }));
                worker.IsBackground = true;
                worker.Start();
                return;
            }
            OpenFileDialog picker = new OpenFileDialog();
            picker.Filter = "TextNodeAssistant recovery (*.tna)|*.tna";
            if (picker.ShowDialog(window) != true) return;
            string code = PromptSecret(english ? "Recovery code" : "恢复码", english ? "Enter the separately stored recovery code." : "输入与恢复包分开保存的恢复码。", null);
            if (code == null) return;
            Thread import = new Thread(new ThreadStart(delegate
            {
                EngineResult result;
                try { result = RunEngineCommand("--local-admin recover-package", picker.FileName + "\n" + code + "\n", 60000); }
                catch (Exception error) { result = new EngineResult { ExitCode = -1, Stderr = error.Message }; }
                LocalAdminProtocolResult recovered = result.ExitCode == 0 ? DecodeFrame<LocalAdminProtocolResult>(result.Stdout, LocalAdminResultPrefix) : null;
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    if (recovered == null)
                    {
                        MessageBox.Show(window, DescribeLocalAdminFailure(result), "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                        return;
                    }
                    localAdminReady = true;
                    driveAdminSetupPanel.Visibility = Visibility.Collapsed;
                    string handoff = "LOCAL_ADMIN_USERNAME=admin\r\nLOCAL_ADMIN_PASSWORD=" + recovered.Password + "\r\nLOCAL_ADMIN_RECOVERY_CODE=" + recovered.RecoveryCode + "\r\nLOCAL_ADMIN_RECOVERY_PACKAGE=" + recovered.RecoveryPath;
                    Clipboard.SetText(handoff);
                    MessageBox.Show(window, (english ? "Recovered and re-keyed. A new package and code were created:\n" : "恢复成功并已重新加密；新的恢复包与恢复码如下：\n") + recovered.RecoveryPath + "\n" + recovered.RecoveryCode, "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                }));
            }));
            import.IsBackground = true;
            import.Start();
        }

        private void RefreshDriveTargets()
        {
            try { RefreshRecentTargets(false); } catch { }
            driveNodeSelector.Items.Clear();
            foreach (RecentTarget target in recentTargets)
            {
                string safe = SafeNodePart(target.Host) + "-" + SafeNodePart(target.User);
                string key = IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "text-node-assistant", safe, "id_ed25519");
                driveNodeSelector.Items.Add(new DriveTargetOption { Target = target, Bound = File.Exists(key) && File.Exists(key + ".pub") });
            }
            if (driveNodeSelector.Items.Count > 0) driveNodeSelector.SelectedIndex = 0;
            driveNoNodeBanner.Visibility = driveNodeSelector.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private static string SafeNodePart(string value)
        {
            StringBuilder output = new StringBuilder();
            foreach (char character in value)
            {
                if (Char.IsLetterOrDigit(character) || character == '.' || character == '_' || character == '-') output.Append(character);
                else output.Append('_');
            }
            string result = output.ToString().Trim('_');
            return result.Length == 0 ? "node" : result;
        }

        private void BeginDriveLogin()
        {
            if (driveBusy) return;
            DriveTargetOption selected = driveNodeSelector.SelectedItem as DriveTargetOption;
            string username = driveUsernameInput.Text.Trim();
            string password = drivePasswordInput.Password;
            drivePasswordInput.Clear();
            if (selected == null || !selected.Bound)
            {
                MessageBox.Show(window, english ? "Choose a node with a bound key. Otherwise use Advanced operations to install, restore a key, or answer an invitation." : "请选择带 [BOUND] 的节点；否则先进入高级控制台施工、恢复 key 或响应邀请。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            bool admin = String.Equals(username, "admin", StringComparison.OrdinalIgnoreCase);
            if (admin && !localAdminReady)
            {
                MessageBox.Show(window, english ? "Create or recover the local admin first." : "请先创建或恢复本机 admin。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            if (!admin && (username.Length < 3 || password.Length < 14))
            {
                MessageBox.Show(window, english ? "Enter an ordinary drive username and its exact password." : "请输入普通网盘用户名和完整密码。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            driveBusy = true;
            driveLoginButton.IsEnabled = false;
            Find<TextBlock>("DriveTopStatus").Text = english ? "VERIFYING DEVICE / OPENING SSH LOOPBACK" : "正在验证设备 / 建立 SSH 回环";
            StartDriveSession(selected, admin ? "admin" : "ordinary", username, password);
        }

        private void StartDriveSession(DriveTargetOption target, string role, string username, string password)
        {
            Process process = null;
            try
            {
                RuntimeFiles runtime = EnsureRuntimeExtracted();
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = runtime.CliPath;
                start.Arguments = "--drive-session";
                start.WorkingDirectory = IOPath.GetDirectoryName(runtime.CliPath);
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardInput = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                start.StandardOutputEncoding = new UTF8Encoding(false);
                start.StandardErrorEncoding = new UTF8Encoding(false);
                process = new Process();
                process.StartInfo = start;
                process.EnableRaisingEvents = true;
                process.Exited += DriveSessionExited;
                StringBuilder diagnostics = new StringBuilder();
                lock (driveSessionGate)
                {
                    driveSessionProcess = process;
                    driveSessionDiagnostics[process] = diagnostics;
                }
                if (!process.Start()) throw new InvalidOperationException("Drive session backend did not start.");
                driveActiveTarget = target;
                Thread stdout = new Thread(new ThreadStart(delegate { PumpDriveSessionOutput(process.StandardOutput); }));
                Thread stderr = new Thread(new ThreadStart(delegate
                {
                    string line;
                    while ((line = process.StandardError.ReadLine()) != null)
                    {
                        lock (driveSessionGate) diagnostics.AppendLine(line);
                    }
                }));
                stdout.IsBackground = true;
                stderr.IsBackground = true;
                stdout.Start(); stderr.Start();
                process.StandardInput.WriteLine(target.Target.Host);
                process.StandardInput.WriteLine(target.Target.User);
                process.StandardInput.WriteLine(target.Target.Port.ToString(CultureInfo.InvariantCulture));
                process.StandardInput.WriteLine(role);
                process.StandardInput.WriteLine(username);
                process.StandardInput.WriteLine(password);
                process.StandardInput.Flush();
            }
            catch (Exception error)
            {
                if (process != null)
                {
                    lock (driveSessionGate)
                    {
                        driveSessionDiagnostics.Remove(process);
                        if (driveSessionProcess == process) driveSessionProcess = null;
                    }
                    try { process.Dispose(); } catch { }
                }
                driveBusy = false;
                driveLoginButton.IsEnabled = true;
                MessageBox.Show(window, error.Message, "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void PumpDriveSessionOutput(StreamReader reader)
        {
            try
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (!line.StartsWith(DriveSessionSecretPrefix, StringComparison.Ordinal)) continue;
                    DriveSessionProtocolResult session = DecodeFrame<DriveSessionProtocolResult>(line, DriveSessionSecretPrefix);
                    if (session == null || session.Version != 1) continue;
                    window.Dispatcher.BeginInvoke(new Action(delegate { ActivateDriveWorkspace(session); }));
                }
            }
            catch { }
        }

        private void DriveSessionExited(object sender, EventArgs args)
        {
            Process process = sender as Process;
            int exit = -1;
            try { exit = process.ExitCode; } catch { }
            string error = "";
            lock (driveSessionGate)
            {
                StringBuilder diagnostics;
                if (process != null && driveSessionDiagnostics.TryGetValue(process, out diagnostics)) error = diagnostics.ToString();
                if (process != null) driveSessionDiagnostics.Remove(process);
            }
            window.Dispatcher.BeginInvoke(new Action(delegate
            {
                bool isCurrent;
                lock (driveSessionGate)
                {
                    isCurrent = driveSessionProcess == process;
                    if (isCurrent) driveSessionProcess = null;
                }
                if (!isCurrent)
                {
                    MarkMountTunnelExited(process, error);
                    return;
                }
                bool hadSession = driveSession != null;
                driveBusy = false;
                driveLoginButton.IsEnabled = true;
                if (!hadSession && exit != 0)
                {
                    Find<TextBlock>("DriveTopStatus").Text = "FAIL-CLOSED / " + RedactDriveError(error);
                    MessageBox.Show(window, (english ? "Drive login did not complete.\n\n" : "网盘登录未完成。\n\n") + DescribeDriveSessionFailure(error), "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                }
                else if (hadSession && driveWorkspaceView.Visibility == Visibility.Visible)
                {
                    EndDriveSession(false);
                }
            }));
        }

        private static string RedactDriveError(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return "NO_DETAIL";
            string line = value.Trim().Replace("\r", " ").Replace("\n", " | ");
            return line.Length > 600 ? line.Substring(0, 600) : line;
        }

        private string DescribeDriveSessionFailure(string value)
        {
            string detail = RedactDriveError(value);
            if (detail.IndexOf("TNA_DRIVE_SESSION_ERROR=DRIVE_NOT_READY", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return english
                    ? "This VPS does not currently have the mandatory private drive installed and running. Return to the Advanced Console and run menu [1] once to install or repair it; after the operation completes, sign in here with account admin and the local admin password.\n\nDiagnostic: " + detail
                    : "这台 VPS 当前没有安装并运行强制私人网盘。请返回“高级控制台”，执行菜单 [1] 安装或修复网盘；操作完成后，在这里使用账号 admin 和本机 admin 密码登录。\n\n诊断信息：" + detail;
            }
            if (detail.IndexOf("TNA_DRIVE_SESSION_ERROR=LOCAL_ADMIN_AUTHENTICATION_FAILED", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return english
                    ? "The local admin password was rejected. This is the password created for this Windows device, not the VPS root password or the remote drive admin password.\n\nDiagnostic: " + detail
                    : "本机 admin 密码校验失败。这里要填的是这台 Windows 电脑创建的本机 admin 密码，不是 VPS root 密码，也不是远端网盘 admin 能力密码。\n\n诊断信息：" + detail;
            }
            if (detail.IndexOf("TNA_DRIVE_SESSION_ERROR=ADMIN_CAPABILITY_UNAVAILABLE", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return english
                    ? "This device has no locally protected capability for the remote admin space. Open the Advanced Console, run menu [1] or the private-drive admin handoff flow, and save the generated handoff before signing in again.\n\nDiagnostic: " + detail
                    : "本机没有保存可验证的远端 admin 空间能力。请进入“高级控制台”，执行菜单 [1] 或网盘 admin 能力交付流程，保存生成的交接单后再回来登录。\n\n诊断信息：" + detail;
            }
            if (detail.IndexOf("TNA_DRIVE_SESSION_ERROR=REMOTE_LOGIN_REJECTED", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return english
                    ? "The remote drive rejected the saved capability or ordinary-account password. Do not retry blindly; use the Advanced Console to verify or explicitly rotate the corresponding credential.\n\nDiagnostic: " + detail
                    : "远端网盘拒绝了已保存的能力凭据或普通账号密码。不要盲目重试；请进入“高级控制台”验证，或明确轮换对应凭据。\n\n诊断信息：" + detail;
            }
            return detail;
        }

        private void ActivateDriveWorkspace(DriveSessionProtocolResult session)
        {
            driveSession = session;
            driveBusy = false;
            driveLoginButton.IsEnabled = true;
            driveLoginView.Visibility = Visibility.Collapsed;
            driveWorkspaceView.Visibility = Visibility.Visible;
            driveSessionAccountText.Text = session.Role == "admin" ? "admin / LOCAL GATE" : session.Username;
            driveSessionNodeText.Text = driveActiveTarget == null ? session.NodeId : driveActiveTarget.Target.ToString() + "\n" + session.NodeId;
            driveCurrentPath = NormalizeDrivePath(session.SpacePath, session.SpacePath);
            Find<TextBlock>("DriveTopTitle").Text = english ? "TNA // PRIVATE VAULT / SPACE" : "TNA // PRIVATE VAULT / 文件空间";
            Find<TextBlock>("DriveTopStatus").Text = "SESSION ACTIVE / SSH LOOPBACK / " + session.Role.ToUpperInvariant();
            RefreshDriveFiles();
        }

        private void EndDriveSession(bool userInitiated)
        {
            Process process;
            lock (driveSessionGate) process = driveSessionProcess;
            bool retainedByMount = process != null && MountUsesTunnel(process);
            if (process != null && !retainedByMount)
            {
                try { process.StandardInput.WriteLine("close"); process.StandardInput.Flush(); } catch { }
                if (!process.WaitForExit(4000)) try { process.Kill(); } catch { }
            }
            lock (driveSessionGate) driveSessionProcess = null;
            if (driveSession != null) driveSession.Password = null;
            driveSession = null;
            driveCurrentPath = null;
            driveFileGrid.ItemsSource = null;
            advancedUnlockedUntilUtc = DateTime.MinValue;
            driveWorkspaceView.Visibility = Visibility.Collapsed;
            driveSetupView.Visibility = Visibility.Collapsed;
            driveLoginView.Visibility = Visibility.Visible;
            Find<TextBlock>("DriveTopStatus").Text = retainedByMount ? "BROWSER SESSION CLOSED / MOUNT TUNNEL RETAINED" : (userInitiated ? "SESSION CLOSED / SECRETS RELEASED" : "SESSION ENDED / LOGIN REQUIRED");
        }

        private void ShowDriveShell()
        {
            if (operationRunning)
            {
                MessageBox.Show(window, english ? "Finish or safely stop the active advanced workflow first." : "请先完成或安全停止当前高级工作流。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            operationWorkspace.Visibility = Visibility.Collapsed;
            driveShell.Visibility = Visibility.Visible;
            if (driveSession == null) ShowDriveLogin();
        }

        private void RequestAdvancedConsole()
        {
            LocalUISecuritySettings settings = LoadLocalUISecuritySettings();
            if (!settings.AdvancedGateEnabled || DateTime.UtcNow < advancedUnlockedUntilUtc)
            {
                OpenAdvancedConsoleAfterGate();
                return;
            }
            if (!localAdminProbeComplete)
            {
                advancedOpenPending = true;
                footerStatus.Text = english ? "Checking local admin status…" : "正在检查本机 admin 状态…";
                if (!localAdminProbeInFlight) ProbeLocalAdminStatus();
                return;
            }
            if (!localAdminReady)
            {
                MessageBox.Show(window, english ? "Create or recover local admin first." : "请先创建或恢复本机 admin。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            string password = PromptSecret(english ? "Advanced console gate" : "高级控制台门禁", english ? "Re-enter the local admin password. It remains on this PC." : "重新输入本机 admin 密码；它不会发送到 VPS。", null);
            if (password == null) return;
            EngineResult result = RunEngineCommand("--local-admin verify", password + "\n", 60000);
            if (result.ExitCode != 0)
            {
                MessageBox.Show(window, english ? "Local admin authentication failed." : "本机 admin 验证失败。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }
            advancedUnlockedUntilUtc = DateTime.UtcNow.AddMinutes(settings.SessionTimeoutMinutes);
            OpenAdvancedConsoleAfterGate();
        }

        private void OpenAdvancedConsoleAfterGate()
        {
            driveShell.Visibility = Visibility.Collapsed;
            operationWorkspace.Visibility = Visibility.Collapsed;
            footerStatus.Text = english ? "Advanced console unlocked for this local session" : "高级控制台已在本机会话中解锁";
        }

        private static string LocalUISecurityPath()
        {
            return IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TextNodeAssistant", "ui-security.json");
        }

        private static LocalUISecuritySettings LoadLocalUISecuritySettings()
        {
            try
            {
                string path = LocalUISecurityPath();
                if (!File.Exists(path)) return new LocalUISecuritySettings();
                using (FileStream stream = File.OpenRead(path))
                {
                    LocalUISecuritySettings settings = new DataContractJsonSerializer(typeof(LocalUISecuritySettings)).ReadObject(stream) as LocalUISecuritySettings;
                    if (settings == null || settings.SessionTimeoutMinutes < 1 || settings.SessionTimeoutMinutes > 120) return new LocalUISecuritySettings();
                    return settings;
                }
            }
            catch { return new LocalUISecuritySettings(); }
        }

        private string PromptSecret(string title, string description, string initial)
        {
            Window dialog = CreatePromptWindow(title, description);
            PasswordBox input = new PasswordBox { Height = 40, Margin = new Thickness(0, 14, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 8, 10, 8) };
            StackPanel body = dialog.Content as StackPanel;
            body.Children.Add(input);
            bool accepted = false;
            Button ok = new Button { Content = english ? "Confirm" : "确认", Style = window.FindResource("PrimaryButtonStyle") as Style, Height = 38, Margin = new Thickness(0, 13, 0, 0) };
            ok.Click += delegate { accepted = true; dialog.Close(); };
            body.Children.Add(ok);
            dialog.ContentRendered += delegate { input.Focus(); };
            dialog.ShowDialog();
            return accepted ? input.Password : null;
        }

        private string PromptTextValue(string title, string description, string initial)
        {
            Window dialog = CreatePromptWindow(title, description);
            TextBox input = new TextBox { Text = initial ?? "", Height = 40, Margin = new Thickness(0, 14, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 8, 10, 8) };
            StackPanel body = dialog.Content as StackPanel;
            body.Children.Add(input);
            bool accepted = false;
            Button ok = new Button { Content = english ? "Confirm" : "确认", Style = window.FindResource("PrimaryButtonStyle") as Style, Height = 38, Margin = new Thickness(0, 13, 0, 0) };
            ok.Click += delegate { accepted = true; dialog.Close(); };
            body.Children.Add(ok);
            dialog.ContentRendered += delegate { input.Focus(); input.SelectAll(); };
            dialog.ShowDialog();
            return accepted ? input.Text : null;
        }

        private Window CreatePromptWindow(string title, string description)
        {
            Window dialog = new Window();
            dialog.Title = "TextNodeAssistant";
            dialog.Owner = window;
            dialog.Width = 470;
            dialog.SizeToContent = SizeToContent.Height;
            dialog.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            dialog.ResizeMode = ResizeMode.NoResize;
            dialog.Background = Brush("#040A0E", 1);
            dialog.Foreground = Brushes.White;
            StackPanel body = new StackPanel { Margin = new Thickness(24, 22, 24, 22) };
            body.Children.Add(new TextBlock { Text = title, FontSize = 19, FontWeight = FontWeights.SemiBold });
            body.Children.Add(new TextBlock { Text = description, Foreground = Brush("#91A8B5", 1), FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 7, 0, 0) });
            dialog.Content = body;
            return dialog;
        }

        private void RefreshDriveFiles()
        {
            if (driveSession == null || driveBusy) return;
            driveBusy = true;
            driveWorkspaceStatus.Text = english ? "Reading directory through the SSH loopback…" : "正在通过 SSH 回环读取目录…";
            Thread worker = new Thread(new ThreadStart(delegate
            {
                try
                {
                    List<DriveFileItem> files = PropfindDrive(driveCurrentPath);
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        driveFileGrid.ItemsSource = files;
                        driveCurrentPathText.Text = driveCurrentPath;
                        driveWorkspaceStatus.Text = (english ? "Ready · " : "就绪 · ") + files.Count + (english ? " items · no off-node backup is configured" : " 项 · 尚未配置异机备份");
                        driveBusy = false;
                    }));
                }
                catch (Exception error)
                {
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        driveWorkspaceStatus.Text = (english ? "Directory read failed: " : "目录读取失败：") + error.Message;
                        driveBusy = false;
                    }));
                }
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private HttpWebRequest DriveRequest(string method, string path)
        {
            if (driveSession == null) throw new InvalidOperationException("Drive session is not active.");
            string safePath = NormalizeDrivePath(path, driveSession.SpacePath);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(DriveUrl(safePath));
            request.Method = method;
            request.Timeout = 30000;
            request.ReadWriteTimeout = 30000;
            request.AllowAutoRedirect = false;
            string basic = Convert.ToBase64String(Encoding.UTF8.GetBytes(driveSession.Username + ":" + driveSession.Password));
            request.Headers[HttpRequestHeader.Authorization] = "Basic " + basic;
            request.UserAgent = "TextNodeAssistant/0.9.5";
            return request;
        }

        private string DriveUrl(string path)
        {
            string[] parts = path.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            StringBuilder encoded = new StringBuilder(driveSession.Url.TrimEnd('/'));
            foreach (string part in parts) encoded.Append('/').Append(Uri.EscapeDataString(part));
            if (path.EndsWith("/", StringComparison.Ordinal)) encoded.Append('/');
            return encoded.ToString();
        }

        private static string NormalizeDrivePath(string path, string root)
        {
            if (String.IsNullOrEmpty(path)) path = root;
            Uri absolute;
            if (Uri.TryCreate(path, UriKind.Absolute, out absolute)) path = absolute.AbsolutePath;
            path = Uri.UnescapeDataString(path).Replace('\\', '/');
            if (!path.StartsWith("/", StringComparison.Ordinal)) path = "/" + path;
            List<string> clean = new List<string>();
            foreach (string part in path.Split('/'))
            {
                if (part.Length == 0 || part == ".") continue;
                if (part == "..") { if (clean.Count > 0) clean.RemoveAt(clean.Count - 1); continue; }
                clean.Add(part);
            }
            string normalized = "/" + String.Join("/", clean.ToArray());
            string normalizedRoot = "/" + String.Join("/", root.Replace('\\', '/').Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries));
            if (!normalized.StartsWith(normalizedRoot, StringComparison.Ordinal)) throw new InvalidOperationException("Remote path escaped the authorized space.");
            if (path.EndsWith("/", StringComparison.Ordinal) || normalized == normalizedRoot) normalized += "/";
            return normalized;
        }

        private List<DriveFileItem> PropfindDrive(string path)
        {
            HttpWebRequest request = DriveRequest("PROPFIND", path);
            request.Headers["Depth"] = "1";
            byte[] body = Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:prop><D:displayname/><D:resourcetype/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>");
            request.ContentType = "application/xml; charset=utf-8";
            request.ContentLength = body.Length;
            using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            string xml;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) xml = reader.ReadToEnd();
            XmlDocument document = new XmlDocument();
            document.XmlResolver = null;
            document.LoadXml(xml);
            XmlNamespaceManager ns = new XmlNamespaceManager(document.NameTable);
            ns.AddNamespace("D", "DAV:");
            List<DriveFileItem> result = new List<DriveFileItem>();
            string current = NormalizeDrivePath(path, driveSession.SpacePath).TrimEnd('/');
            foreach (XmlNode node in document.SelectNodes("//D:response", ns))
            {
                XmlNode hrefNode = node.SelectSingleNode("D:href", ns);
                if (hrefNode == null) continue;
                string href = NormalizeDrivePath(hrefNode.InnerText, driveSession.SpacePath);
                if (href.TrimEnd('/') == current) continue;
                bool directory = node.SelectSingleNode(".//D:resourcetype/D:collection", ns) != null;
                XmlNode nameNode = node.SelectSingleNode(".//D:displayname", ns);
                string name = nameNode == null || String.IsNullOrEmpty(nameNode.InnerText) ? IOPath.GetFileName(href.TrimEnd('/')) : nameNode.InnerText;
                if (name.StartsWith(".tna-upload-", StringComparison.Ordinal)) continue;
                long size = 0;
                XmlNode sizeNode = node.SelectSingleNode(".//D:getcontentlength", ns);
                if (sizeNode != null) Int64.TryParse(sizeNode.InnerText, out size);
                XmlNode modifiedNode = node.SelectSingleNode(".//D:getlastmodified", ns);
                result.Add(new DriveFileItem { Name = name, Type = directory ? (english ? "Folder" : "目录") : (english ? "File" : "文件"), Size = size, SizeText = directory ? "—" : FormatBytes(size), Modified = modifiedNode == null ? "" : modifiedNode.InnerText, Href = href, IsDirectory = directory });
            }
            return result;
        }

        private static string FormatBytes(long value)
        {
            string[] units = new string[] { "B", "KiB", "MiB", "GiB", "TiB" };
            double amount = value;
            int unit = 0;
            while (amount >= 1024 && unit < units.Length - 1) { amount /= 1024; unit++; }
            return amount.ToString(unit == 0 ? "0" : "0.##", CultureInfo.InvariantCulture) + " " + units[unit];
        }

        private void NavigateDriveUp()
        {
            if (driveSession == null) return;
            string root = NormalizeDrivePath(driveSession.SpacePath, driveSession.SpacePath).TrimEnd('/');
            string current = driveCurrentPath.TrimEnd('/');
            if (current == root) return;
            int slash = current.LastIndexOf('/');
            driveCurrentPath = NormalizeDrivePath(current.Substring(0, slash + 1), driveSession.SpacePath);
            RefreshDriveFiles();
        }

        private static bool ValidDriveName(string value)
        {
            return !String.IsNullOrWhiteSpace(value) && value != "." && value != ".." && value.IndexOfAny(new char[] { '/', '\\', '\0', ':', '*', '?', '"', '<', '>', '|' }) < 0 && value.Length <= 180;
        }

        private string ChildDrivePath(string name, bool directory)
        {
            if (!ValidDriveName(name)) throw new InvalidOperationException(english ? "The name contains unsupported characters." : "名称包含不支持的字符。" );
            return NormalizeDrivePath(driveCurrentPath.TrimEnd('/') + "/" + name + (directory ? "/" : ""), driveSession.SpacePath);
        }

        private void CreateDriveFolder()
        {
            string name = PromptTextValue(english ? "New folder" : "新建目录", english ? "Enter one folder name; paths and .. are rejected." : "只输入一层目录名；路径和 .. 会被拒绝。", "");
            if (name == null) return;
            RunDriveMutation(english ? "Creating folder…" : "正在新建目录…", delegate
            {
                HttpWebRequest request = DriveRequest("MKCOL", ChildDrivePath(name, true));
                using (request.GetResponse()) { }
            });
        }

        private void UploadDriveFile()
        {
            OpenFileDialog picker = new OpenFileDialog();
            if (picker.ShowDialog(window) != true) return;
            string source = picker.FileName;
            string name = IOPath.GetFileName(source);
            RunDriveMutation(english ? "Uploading to a managed temporary object…" : "正在上传到受管临时对象…", delegate
            {
                string destination = ChildDrivePath(name, false);
                if (DriveExists(destination))
                {
                    string stem = IOPath.GetFileNameWithoutExtension(name);
                    string extension = IOPath.GetExtension(name);
                    destination = ChildDrivePath(stem + ".conflict-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + extension, false);
                }
                string temporary = ChildDrivePath(".tna-upload-" + Guid.NewGuid().ToString("N"), false);
                FileInfo info = new FileInfo(source);
                HttpWebRequest put = DriveRequest("PUT", temporary);
                put.ContentLength = info.Length;
                put.AllowWriteStreamBuffering = false;
                using (Stream input = File.OpenRead(source))
                using (Stream output = put.GetRequestStream()) input.CopyTo(output);
                using (put.GetResponse()) { }
                long readback = DriveContentLength(temporary);
                if (readback != info.Length)
                {
                    try { using (DriveRequest("DELETE", temporary).GetResponse()) { } } catch { }
                    throw new IOException("Uploaded length verification failed.");
                }
                MoveDriveObject(temporary, destination, false);
            });
        }

        private void DownloadDriveFile()
        {
            DriveFileItem item = driveFileGrid.SelectedItem as DriveFileItem;
            if (item == null || item.IsDirectory)
            {
                MessageBox.Show(window, english ? "Select one file to download." : "请选择一个文件下载。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            SaveFileDialog picker = new SaveFileDialog { FileName = item.Name };
            if (picker.ShowDialog(window) != true) return;
            string destination = picker.FileName;
            RunDriveMutation(english ? "Downloading and verifying length…" : "正在下载并校验长度…", delegate
            {
                HttpWebRequest get = DriveRequest("GET", item.Href);
                using (HttpWebResponse response = (HttpWebResponse)get.GetResponse())
                using (Stream input = response.GetResponseStream())
                using (FileStream output = new FileStream(destination + ".tna-part", FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    input.CopyTo(output);
                    output.Flush(true);
                }
                if (new FileInfo(destination + ".tna-part").Length != item.Size) throw new IOException("Downloaded length verification failed.");
                if (File.Exists(destination)) File.Delete(destination);
                File.Move(destination + ".tna-part", destination);
            });
        }

        private void RenameDriveItem()
        {
            DriveFileItem item = driveFileGrid.SelectedItem as DriveFileItem;
            if (item == null) return;
            string name = PromptTextValue(english ? "Rename" : "重命名", english ? "Enter the new name." : "输入新名称。", item.Name);
            if (name == null || name == item.Name) return;
            RunDriveMutation(english ? "Renaming…" : "正在重命名…", delegate { MoveDriveObject(item.Href, ChildDrivePath(name, item.IsDirectory), false); });
        }

        private void TrashDriveItem()
        {
            DriveFileItem item = driveFileGrid.SelectedItem as DriveFileItem;
            if (item == null) return;
            if (MessageBox.Show(window, (english ? "Move this item to the managed trash (still counts toward quota)?\n" : "把此项目移入受管回收区（仍计入配额）？\n") + item.Name, "TextNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            RunDriveMutation(english ? "Moving to managed trash…" : "正在移入受管回收区…", delegate
            {
                string root = NormalizeDrivePath(driveSession.SpacePath, driveSession.SpacePath);
                string trash = NormalizeDrivePath(root.TrimEnd('/') + "/.tna-trash/", driveSession.SpacePath);
                if (!DriveExists(trash))
                {
                    HttpWebRequest mkcol = DriveRequest("MKCOL", trash);
                    using (mkcol.GetResponse()) { }
                }
                string destination = NormalizeDrivePath(trash + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + item.Name + (item.IsDirectory ? "/" : ""), driveSession.SpacePath);
                MoveDriveObject(item.Href, destination, false);
            });
        }

        private void RunDriveMutation(string progress, Action action)
        {
            if (driveSession == null || driveBusy) return;
            driveBusy = true;
            driveWorkspaceStatus.Text = progress;
            Thread worker = new Thread(new ThreadStart(delegate
            {
                Exception failure = null;
                try { action(); } catch (Exception error) { failure = error; }
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveBusy = false;
                    if (failure != null)
                    {
                        driveWorkspaceStatus.Text = (english ? "Operation failed: " : "操作失败：") + failure.Message;
                        return;
                    }
                    RefreshDriveFiles();
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private bool DriveExists(string path)
        {
            try
            {
                HttpWebRequest request = DriveRequest("HEAD", path);
                using (request.GetResponse()) { }
                return true;
            }
            catch (WebException error)
            {
                HttpWebResponse response = error.Response as HttpWebResponse;
                if (response != null && response.StatusCode == HttpStatusCode.NotFound) return false;
                throw;
            }
        }

        private long DriveContentLength(string path)
        {
            HttpWebRequest request = DriveRequest("HEAD", path);
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse()) return response.ContentLength;
        }

        private void MoveDriveObject(string source, string destination, bool overwrite)
        {
            HttpWebRequest move = DriveRequest("MOVE", source);
            move.Headers["Destination"] = DriveUrl(destination);
            move.Headers["Overwrite"] = overwrite ? "T" : "F";
            using (move.GetResponse()) { }
        }

        private string[] PromptOrdinaryAccountRegistration()
        {
            Window dialog = CreatePromptWindow(english ? "Register a real drive account" : "注册真实网盘账号", english ? "The node must be fully installed and this device must be an active controller. At most two ordinary accounts exist per VPS." : "节点必须已完成全部施工，且当前设备必须是 active controller；每台 VPS 最多两个普通账号。");
            StackPanel body = dialog.Content as StackPanel;
            TextBox username = new TextBox { Height = 38, Margin = new Thickness(0, 13, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            PasswordBox password = new PasswordBox { Height = 38, Margin = new Thickness(0, 9, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            PasswordBox confirmation = new PasswordBox { Height = 38, Margin = new Thickness(0, 9, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            TextBox quota = new TextBox { Text = "auto", Height = 38, Margin = new Thickness(0, 9, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            body.Children.Add(new TextBlock { Text = english ? "Username (3-32; admin/root reserved)" : "用户名（3—32 位；admin/root 保留）", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 13, 0, 0) }); body.Children.Add(username);
            body.Children.Add(new TextBlock { Text = english ? "Password (14-128 printable ASCII)" : "密码（14—128 位可打印 ASCII）", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 9, 0, 0) }); body.Children.Add(password);
            body.Children.Add(new TextBlock { Text = english ? "Confirm password" : "再次确认密码", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 9, 0, 0) }); body.Children.Add(confirmation);
            body.Children.Add(new TextBlock { Text = english ? "Quota: auto or 1-50 GiB" : "容量：auto 或 1—50 GiB", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 9, 0, 0) }); body.Children.Add(quota);
            string[] accepted = null;
            Button submit = new Button { Content = english ? "Create, verify, and escrow" : "创建、验收并加密托管", Style = window.FindResource("PrimaryButtonStyle") as Style, Height = 40, Margin = new Thickness(0, 15, 0, 0) };
            submit.Click += delegate
            {
                int quotaNumber;
                string quotaValue = quota.Text.Trim().ToLowerInvariant();
                bool quotaOK = quotaValue == "auto" || (Int32.TryParse(quotaValue, out quotaNumber) && quotaNumber >= 1 && quotaNumber <= 50);
                if (username.Text.Trim().Length < 3 || username.Text.Trim().Length > 32 || String.Equals(username.Text.Trim(), "admin", StringComparison.OrdinalIgnoreCase) || String.Equals(username.Text.Trim(), "root", StringComparison.OrdinalIgnoreCase) || password.Password.Length < 14 || password.Password.Length > 128 || password.Password != confirmation.Password || !quotaOK)
                {
                    MessageBox.Show(dialog, english ? "Correct the username, matching password, and quota before continuing." : "请修正用户名、两次一致的密码和容量后再继续。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                accepted = new string[] { username.Text.Trim(), password.Password, confirmation.Password, quotaValue };
                dialog.Close();
            };
            body.Children.Add(submit);
            dialog.ContentRendered += delegate { username.Focus(); };
            dialog.ShowDialog();
            return accepted;
        }

        private string[] PromptOrdinaryPasswordChange(string username)
        {
            Window dialog = CreatePromptWindow(english ? "Change ordinary-account password" : "修改普通账号密码", (english ? "Account: " : "账号：") + username + (english ? ". The old password is verified before any change." : "。必须先验证旧密码，失败时不会改动远端。"));
            StackPanel body = dialog.Content as StackPanel;
            PasswordBox current = new PasswordBox { Height = 38, Margin = new Thickness(0, 13, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            PasswordBox next = new PasswordBox { Height = 38, Margin = new Thickness(0, 9, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            PasswordBox confirmation = new PasswordBox { Height = 38, Margin = new Thickness(0, 9, 0, 0), Background = Brush("#071116", 1), Foreground = Brushes.White, BorderBrush = Brush("#28505D", 1), Padding = new Thickness(10, 7, 10, 7) };
            body.Children.Add(new TextBlock { Text = english ? "Current password" : "当前密码", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 13, 0, 0) }); body.Children.Add(current);
            body.Children.Add(new TextBlock { Text = english ? "New password (14-128 printable ASCII)" : "新密码（14—128 位可打印 ASCII）", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 9, 0, 0) }); body.Children.Add(next);
            body.Children.Add(new TextBlock { Text = english ? "Confirm new password" : "再次确认新密码", Foreground = Brush("#91A8B5", 1), Margin = new Thickness(0, 9, 0, 0) }); body.Children.Add(confirmation);
            string[] accepted = null;
            Button submit = new Button { Content = english ? "Verify and change" : "验证并改密", Style = window.FindResource("PrimaryButtonStyle") as Style, Height = 40, Margin = new Thickness(0, 15, 0, 0) };
            submit.Click += delegate
            {
                if (current.Password.Length < 14 || next.Password.Length < 14 || next.Password.Length > 128 || next.Password != confirmation.Password)
                {
                    MessageBox.Show(dialog, english ? "Enter the current password and the same policy-compliant new password twice." : "请输入当前密码，并两次输入一致且符合策略的新密码。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                accepted = new string[] { current.Password, next.Password, confirmation.Password };
                dialog.Close();
            };
            body.Children.Add(submit);
            dialog.ContentRendered += delegate { current.Focus(); };
            dialog.ShowDialog();
            return accepted;
        }

        private void BeginOuterRegistration()
        {
            DriveTargetOption selected = driveNodeSelector.SelectedItem as DriveTargetOption;
            if (selected == null || !selected.Bound)
            {
                MessageBox.Show(window, english ? "Bind or approve this device for a real node before registering an account." : "必须先把当前设备绑定或批准到真实节点，才能注册普通账号。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            string[] values = PromptOrdinaryAccountRegistration();
            if (values == null) return;
            driveLoginStatus.Text = english ? "Verifying node readiness and creating the real account…" : "正在核验节点就绪状态并创建真实账号…";
            driveRegisterButton.IsEnabled = false;
            Thread worker = new Thread(new ThreadStart(delegate
            {
                string stdin = selected.Target.Host + "\n" + selected.Target.User + "\n" + selected.Target.Port.ToString(CultureInfo.InvariantCulture) + "\n" + values[0] + "\n" + values[1] + "\n" + values[2] + "\n" + values[3] + "\n";
                EngineResult result = RunEngineCommand("--drive-register", stdin, 120000);
                DriveAccountProtocolResult created = result.ExitCode == 0 ? DecodeFrame<DriveAccountProtocolResult>(result.Stdout, DriveAccountResultPrefix) : null;
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveRegisterButton.IsEnabled = true;
                    if (created == null)
                    {
                        driveLoginStatus.Text = english ? "Registration failed; no ghost account was retained." : "注册失败；没有保留幽灵账号。";
                        MessageBox.Show(window, (english ? "Real account registration failed.\n" : "真实账号注册失败。\n") + result.Stderr, "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                        return;
                    }
                    string handoff = "NODE_ID=" + created.NodeId + "\r\nDRIVE_ACCOUNT_ID=" + created.AccountId + "\r\nDRIVE_SPACE_ID=" + created.SpaceId + "\r\nDRIVE_USERNAME=" + created.Username + "\r\nDRIVE_PASSWORD=" + created.Password + "\r\nDRIVE_QUOTA_GIB=" + created.QuotaGiB;
                    Clipboard.SetText(handoff);
                    driveUsernameInput.Text = created.Username;
                    drivePasswordInput.Password = created.Password;
                    driveLoginStatus.Text = english ? "Account created and authenticated; the complete handoff is on the clipboard." : "账号已创建并通过验收；完整交接单已复制到剪贴板。";
                    MessageBox.Show(window, english ? "The real account passed remote CRUD and encrypted-escrow readback. Save the clipboard handoff, then sign in." : "真实账号已通过远端 CRUD 与加密托管回读。请先保存剪贴板交接单，再登录。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private void ShowOuterAccountActions()
        {
            if (driveSession == null) return;
            if (driveSession.Role == "admin")
            {
                MessageBox.Show(window, english ? "Local admin password changes are available only under Advanced operations → Security and credentials." : "本机 admin 主动改密只允许在“高级运维 → 安全与凭据”中执行。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                string[] values = PromptOrdinaryPasswordChange(driveSession.Username);
                if (values == null) return;
                driveWorkspaceStatus.Text = english ? "Changing password through an authenticated transaction…" : "正在通过认证事务修改密码…";
                Thread worker = new Thread(new ThreadStart(delegate
                {
                    string stdin = driveActiveTarget.Target.Host + "\n" + driveActiveTarget.Target.User + "\n" + driveActiveTarget.Target.Port.ToString(CultureInfo.InvariantCulture) + "\n" + driveSession.Username + "\n" + values[0] + "\n" + values[1] + "\n" + values[2] + "\n";
                    EngineResult result = RunEngineCommand("--drive-change-password", stdin, 120000);
                    DriveAccountProtocolResult changed = result.ExitCode == 0 ? DecodeFrame<DriveAccountProtocolResult>(result.Stdout, DriveAccountResultPrefix) : null;
                    window.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        if (changed == null)
                        {
                            driveWorkspaceStatus.Text = english ? "Password was not changed." : "密码未修改。";
                            MessageBox.Show(window, (english ? "Password-change transaction failed.\n" : "改密事务失败。\n") + result.Stderr, "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Error);
                            return;
                        }
                        Clipboard.SetText("NODE_ID=" + changed.NodeId + "\r\nDRIVE_ACCOUNT_ID=" + changed.AccountId + "\r\nDRIVE_USERNAME=" + changed.Username + "\r\nDRIVE_PASSWORD=" + changed.Password);
                        MessageBox.Show(window, english ? "Password changed and verified. The updated handoff is on the clipboard; this session will now sign out." : "密码已修改并通过验收；更新后的交接单已复制。本会话现在退出，防止继续使用旧口令。", "TextNodeAssistant", MessageBoxButton.OK, MessageBoxImage.Information);
                        EndDriveSession(true);
                    }));
                }));
                worker.IsBackground = true;
                worker.Start();
            }
        }

        private void ShowDriveFilesPanel()
        {
            driveMountPanel.Visibility = Visibility.Collapsed;
            driveFilesPanel.Visibility = Visibility.Visible;
            Find<Button>("DriveFilesNavButton").Tag = "active";
            Find<Button>("DriveMountNavButton").Tag = null;
        }

        private void ShowDriveMountPanel()
        {
            driveFilesPanel.Visibility = Visibility.Collapsed;
            driveMountPanel.Visibility = Visibility.Visible;
            Find<Button>("DriveFilesNavButton").Tag = null;
            Find<Button>("DriveMountNavButton").Tag = "active";
            RefreshDriveMountStatus();
        }

        private static bool IsWinFspInstalled()
        {
            string[] keys = new string[] { @"SOFTWARE\WinFsp", @"SOFTWARE\WOW6432Node\WinFsp" };
            foreach (string name in keys)
            {
                try
                {
                    using (RegistryKey key = Registry.LocalMachine.OpenSubKey(name))
                    {
                        if (key != null) return true;
                    }
                }
                catch { }
            }
            string[] probes = new string[]
            {
                IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "WinFsp", "bin", "fsptool-x64.exe"),
                IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WinFsp", "bin", "fsptool-x64.exe")
            };
            foreach (string probe in probes) if (File.Exists(probe)) return true;
            return false;
        }

        private static bool ValidateRclone(string path, out string summary)
        {
            summary = "";
            try
            {
                ProcessStartInfo start = new ProcessStartInfo(path, "version");
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                using (Process process = Process.Start(start))
                {
                    if (process == null || !process.WaitForExit(15000))
                    {
                        if (process != null) try { process.Kill(); } catch { }
                        return false;
                    }
                    summary = process.StandardOutput.ReadToEnd().Trim();
                    return process.ExitCode == 0 && summary.IndexOf("rclone v1.75.0", StringComparison.OrdinalIgnoreCase) >= 0;
                }
            }
            catch (Exception error)
            {
                summary = error.Message;
                return false;
            }
        }

        private void RefreshDriveMountStatus()
        {
            if (driveMountDependencyStatus == null) return;
            driveMountDependencyStatus.Text = english ? "Checking local mount dependencies…" : "正在后台检查本机挂载依赖…";
            Thread worker = new Thread(new ThreadStart(delegate
            {
                string rcloneSummary = "";
                bool rcloneReady = false;
                bool winFspReady = false;
                try
                {
                    RuntimeFiles runtime = EnsureRuntimeExtracted();
                    rcloneReady = ValidateRclone(runtime.RclonePath, out rcloneSummary);
                    winFspReady = IsWinFspInstalled();
                }
                catch (Exception error)
                {
                    rcloneSummary = error.Message;
                    try { winFspReady = IsWinFspInstalled(); } catch { }
                }
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveMountDependencyStatus.Text = (winFspReady ? "[OK] WinFsp 2.1.25156" : "[NEEDED] WinFsp 2.1.25156") + "\n" +
                        (rcloneReady ? "[OK] rclone v1.75.0 (embedded + verified)" : "[FAIL] rclone v1.75.0: " + RedactDriveError(rcloneSummary));
                    RefreshMountLetterChoices();
                    RefreshMountGrid();
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private void RefreshMountLetterChoices()
        {
            string selected = driveMountLetter.SelectedItem as string;
            HashSet<char> used = new HashSet<char>();
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                if (drive.Name.Length > 0) used.Add(Char.ToUpperInvariant(drive.Name[0]));
            }
            lock (driveMountGate)
            {
                foreach (DriveMountItem item in activeDriveMounts) if (!String.IsNullOrEmpty(item.Letter)) used.Add(Char.ToUpperInvariant(item.Letter[0]));
            }
            List<string> choices = new List<string>();
            for (char letter = 'P'; letter <= 'Z'; letter++) if (!used.Contains(letter)) choices.Add(letter + ":");
            for (char letter = 'D'; letter < 'P'; letter++) if (!used.Contains(letter)) choices.Add(letter + ":");
            driveMountLetter.ItemsSource = choices;
            if (selected != null && choices.Contains(selected)) driveMountLetter.SelectedItem = selected;
            else if (choices.Count > 0) driveMountLetter.SelectedIndex = 0;
        }

        private void RefreshMountGrid()
        {
            DriveMountItem[] snapshot;
            lock (driveMountGate) snapshot = activeDriveMounts.ToArray();
            driveMountGrid.ItemsSource = null;
            driveMountGrid.ItemsSource = snapshot;
        }

        private void InstallOrVerifyMountDependencies()
        {
            if (driveBusy) return;
            driveBusy = true;
            Find<Button>("DriveMountInstallButton").IsEnabled = false;
            driveMountStatus.Text = english ? "Verifying signed embedded dependencies…" : "正在验证签名内嵌依赖…";
            Thread worker = new Thread(new ThreadStart(delegate
            {
                string failure = null;
                try
                {
                    RuntimeFiles runtime = EnsureRuntimeExtracted();
                    string version;
                    if (!ValidateRclone(runtime.RclonePath, out version)) throw new InvalidOperationException("Pinned rclone validation failed: " + version);
                    if (!IsWinFspInstalled())
                    {
                        ProcessStartInfo start = new ProcessStartInfo();
                        start.FileName = "msiexec.exe";
                        start.Arguments = "/i \"" + runtime.WinFspMsiPath.Replace("\"", "") + "\" /quiet /norestart";
                        start.UseShellExecute = true;
                        start.Verb = "runas";
                        using (Process process = Process.Start(start))
                        {
                            if (process == null) throw new InvalidOperationException("WinFsp installer did not start.");
                            if (!process.WaitForExit(600000))
                            {
                                try { process.Kill(); } catch { }
                                throw new TimeoutException("WinFsp installation timed out.");
                            }
                            if (process.ExitCode != 0 && process.ExitCode != 3010) throw new InvalidOperationException("WinFsp installer exit " + process.ExitCode.ToString(CultureInfo.InvariantCulture));
                        }
                    }
                    if (!IsWinFspInstalled()) throw new InvalidOperationException("WinFsp installation completed but the installed product could not be verified.");
                }
                catch (Exception error) { failure = error.Message; }
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveBusy = false;
                    Find<Button>("DriveMountInstallButton").IsEnabled = true;
                    RefreshDriveMountStatus();
                    driveMountStatus.Text = failure == null ? (english ? "Dependencies are ready. Choose an unused letter and mount mode." : "依赖已经就绪。请选择空闲盘符和挂载模式。") : ((english ? "Dependency setup failed: " : "依赖安装失败：") + failure);
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private static string RcloneObscure(string rclonePath, string password)
        {
            ProcessStartInfo start = new ProcessStartInfo(rclonePath, "obscure -");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("rclone obscure did not start.");
                process.StandardInput.WriteLine(password);
                process.StandardInput.Close();
                string output = process.StandardOutput.ReadToEnd().Trim();
                string error = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(15000))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("rclone obscure timed out.");
                }
                if (process.ExitCode != 0 || output.Length == 0) throw new InvalidOperationException("rclone password preparation failed: " + RedactDriveError(error));
                return output;
            }
        }

        private static void ApplyRcloneSessionEnvironment(ProcessStartInfo start, DriveSessionProtocolResult session, string url, string obscuredPassword)
        {
            start.EnvironmentVariables["RCLONE_CONFIG_TNA_TYPE"] = "webdav";
            start.EnvironmentVariables["RCLONE_CONFIG_TNA_URL"] = url;
            start.EnvironmentVariables["RCLONE_CONFIG_TNA_VENDOR"] = "other";
            start.EnvironmentVariables["RCLONE_CONFIG_TNA_USER"] = session.Username;
            start.EnvironmentVariables["RCLONE_CONFIG_TNA_PASS"] = obscuredPassword;
            start.EnvironmentVariables["NO_PROXY"] = "localhost,127.0.0.1,::1";
            start.EnvironmentVariables["no_proxy"] = "localhost,127.0.0.1,::1";
        }

        private static void VerifyRcloneRemote(string rclonePath, DriveSessionProtocolResult session, string url, string obscuredPassword)
        {
            ProcessStartInfo start = new ProcessStartInfo(rclonePath, "lsjson tna: --max-depth 1 --config NUL --timeout 20s --contimeout 10s");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            ApplyRcloneSessionEnvironment(start, session, url, obscuredPassword);
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("rclone WebDAV verification did not start.");
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(30000))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("rclone WebDAV verification timed out.");
                }
                if (process.ExitCode != 0 || String.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("rclone WebDAV verification failed: " + RedactDriveError(error));
            }
        }

        private void BeginDriveMount()
        {
            if (driveBusy || driveSession == null || driveActiveTarget == null) return;
            string letter = driveMountLetter.SelectedItem as string;
            if (String.IsNullOrEmpty(letter))
            {
                driveMountStatus.Text = english ? "No unused drive letter is available." : "没有可用盘符。";
                return;
            }
            bool readOnly = driveMountReadOnly.IsChecked == true;
            if (!readOnly && MessageBox.Show(window,
                english ? "Read/write mounting is for small files only. Open files and write cache must be closed before unmounting; large uploads should use the transfer queue. Continue?" : "读写挂载只适合小文件。卸载前必须关闭文件并等待写缓存；大文件应走传输队列。继续？",
                "TextNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            lock (driveMountGate)
            {
                foreach (DriveMountItem existing in activeDriveMounts)
                {
                    if (String.Equals(existing.NodeId, driveSession.NodeId, StringComparison.Ordinal))
                    {
                        driveMountStatus.Text = english ? "This node already has an independent mounted letter." : "此节点已经有独立挂载盘符。";
                        return;
                    }
                }
            }
            if (!IsWinFspInstalled())
            {
                driveMountStatus.Text = english ? "Install and verify WinFsp first." : "请先安装并验证 WinFsp。";
                return;
            }
            Process tunnel;
            lock (driveSessionGate) tunnel = driveSessionProcess;
            if (tunnel == null || tunnel.HasExited)
            {
                driveMountStatus.Text = english ? "The authenticated SSH drive tunnel is no longer active. Sign in again." : "已认证 SSH 网盘隧道已失效，请重新登录。";
                return;
            }
            DriveSessionProtocolResult session = driveSession;
            DriveTargetOption target = driveActiveTarget;
            driveBusy = true;
            Find<Button>("DriveMountStartButton").IsEnabled = false;
            driveMountStatus.Text = english ? "Verifying WebDAV and creating the independent mount…" : "正在验收 WebDAV 并创建独立挂载…";
            Thread worker = new Thread(new ThreadStart(delegate
            {
                DriveMountItem created = null;
                string failure = null;
                try
                {
                    RuntimeFiles runtime = EnsureRuntimeExtracted();
                    string version;
                    if (!ValidateRclone(runtime.RclonePath, out version)) throw new InvalidOperationException("Pinned rclone validation failed.");
                    string password = RcloneObscure(runtime.RclonePath, session.Password);
                    string url = DriveUrlForSession(session, session.SpacePath);
                    VerifyRcloneRemote(runtime.RclonePath, session, url, password);
                    string mode = readOnly ? (english ? "READ ONLY" : "只读") : (english ? "SMALL FILE R/W" : "小文件读写");
                    created = new DriveMountItem { Letter = letter, Node = target.Target.ToString(), NodeId = session.NodeId, Mode = mode, Status = "STARTING", TunnelProcess = tunnel };
                    ProcessStartInfo start = new ProcessStartInfo();
                    start.FileName = runtime.RclonePath;
                    start.Arguments = "mount tna: " + letter + " --config NUL --network-mode --dir-cache-time 10s --poll-interval 0 --volname TNA_" + SafeNodePart(session.NodeId) +
                        (readOnly ? " --read-only --vfs-cache-mode off" : " --vfs-cache-mode writes --vfs-cache-max-size 512M --vfs-write-back 5s");
                    start.UseShellExecute = false;
                    start.CreateNoWindow = true;
                    start.RedirectStandardOutput = true;
                    start.RedirectStandardError = true;
                    ApplyRcloneSessionEnvironment(start, session, url, password);
                    Process process = new Process();
                    process.StartInfo = start;
                    process.EnableRaisingEvents = true;
                    created.RcloneProcess = process;
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args) { if (!String.IsNullOrEmpty(args.Data)) lock (created.Diagnostics) created.Diagnostics.AppendLine(args.Data); };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args) { if (!String.IsNullOrEmpty(args.Data)) lock (created.Diagnostics) created.Diagnostics.AppendLine(args.Data); };
                    process.Exited += DriveMountProcessExited;
                    if (!process.Start()) throw new InvalidOperationException("rclone mount did not start.");
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    DateTime deadline = DateTime.UtcNow.AddSeconds(20);
                    while (DateTime.UtcNow < deadline && !Directory.Exists(letter + "\\"))
                    {
                        if (process.HasExited) break;
                        Thread.Sleep(150);
                    }
                    if (process.HasExited || !Directory.Exists(letter + "\\"))
                    {
                        string diagnostic;
                        lock (created.Diagnostics) diagnostic = created.Diagnostics.ToString();
                        if (!process.HasExited) try { process.Kill(); } catch { }
                        throw new IOException("Mount verification failed: " + RedactDriveError(diagnostic));
                    }
                    created.Status = "ACTIVE";
                    lock (driveMountGate) activeDriveMounts.Add(created);
                }
                catch (Exception error) { failure = error.Message; }
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveBusy = false;
                    Find<Button>("DriveMountStartButton").IsEnabled = true;
                    driveMountStatus.Text = failure == null ? (english ? "Mount verified. Its SSH tunnel is now owned by this letter and remains independent of later node logins." : "挂载已验收。该盘符独占自己的 SSH 隧道，不受之后登录其他节点影响。") : ((english ? "Mount failed: " : "挂载失败：") + failure);
                    RefreshDriveMountStatus();
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private static string DriveUrlForSession(DriveSessionProtocolResult session, string path)
        {
            string[] parts = path.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            StringBuilder encoded = new StringBuilder(session.Url.TrimEnd('/'));
            foreach (string part in parts) encoded.Append('/').Append(Uri.EscapeDataString(part));
            return encoded.Append('/').ToString();
        }

        private bool MountUsesTunnel(Process process)
        {
            lock (driveMountGate)
            {
                foreach (DriveMountItem item in activeDriveMounts) if (item.TunnelProcess == process && item.Status != "STOPPED") return true;
            }
            return false;
        }

        private void MarkMountTunnelExited(Process process, string detail)
        {
            DriveMountItem affected = null;
            lock (driveMountGate)
            {
                foreach (DriveMountItem item in activeDriveMounts) if (item.TunnelProcess == process) { affected = item; break; }
            }
            if (affected == null) return;
            affected.Status = "TUNNEL FAILED";
            if (affected.RcloneProcess != null && !affected.RcloneProcess.HasExited) try { affected.RcloneProcess.Kill(); } catch { }
            driveMountStatus.Text = (english ? "A mount tunnel ended: " : "一个挂载隧道已退出：") + RedactDriveError(detail);
            RefreshMountGrid();
        }

        private void DriveMountProcessExited(object sender, EventArgs args)
        {
            Process process = sender as Process;
            window.Dispatcher.BeginInvoke(new Action(delegate
            {
                DriveMountItem affected = null;
                lock (driveMountGate)
                {
                    foreach (DriveMountItem item in activeDriveMounts) if (item.RcloneProcess == process) { affected = item; break; }
                }
                if (affected == null || affected.Status == "STOPPING" || affected.Status == "STOPPED") return;
                affected.Status = "MOUNT FAILED";
                try { affected.TunnelProcess.StandardInput.WriteLine("close"); affected.TunnelProcess.StandardInput.Flush(); } catch { }
                driveMountStatus.Text = english ? "A mounted drive stopped unexpectedly. Its SSH tunnel was released." : "挂载盘异常停止；对应 SSH 隧道已经释放。";
                RefreshMountGrid();
            }));
        }

        private void UnmountSelectedDrive(bool ask)
        {
            DriveMountItem selected = driveMountGrid.SelectedItem as DriveMountItem;
            if (selected == null)
            {
                driveMountStatus.Text = english ? "Select one mounted drive first." : "请先选择一个挂载盘。";
                return;
            }
            if (ask && MessageBox.Show(window, english ? "Close all files on " + selected.Letter + " and unmount it now?" : "请先关闭 " + selected.Letter + " 上的所有文件。现在安全卸载？", "TextNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            driveMountStatus.Text = english ? "Stopping rclone, releasing WinFsp, then closing the SSH tunnel…" : "正在停止 rclone、释放 WinFsp，再关闭 SSH 隧道…";
            Thread worker = new Thread(new ThreadStart(delegate
            {
                bool released = StopDriveMount(selected);
                window.Dispatcher.BeginInvoke(new Action(delegate
                {
                    driveMountStatus.Text = released ? (english ? "Unmount verified; drive letter and tunnel were released." : "卸载已验收；盘符和隧道均已释放。") : (english ? "Unmount ended but Windows still reports the letter. Close open handles and refresh." : "卸载已结束，但 Windows 仍报告盘符存在；请关闭占用后刷新。" );
                    RefreshDriveMountStatus();
                }));
            }));
            worker.IsBackground = true;
            worker.Start();
        }

        private bool StopDriveMount(DriveMountItem item)
        {
            item.Status = "STOPPING";
            Process mount = item.RcloneProcess;
            if (mount != null && !mount.HasExited)
            {
                try { mount.Kill(); } catch { }
                try { mount.WaitForExit(8000); } catch { }
            }
            DateTime deadline = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < deadline && Directory.Exists(item.Letter + "\\")) Thread.Sleep(150);
            bool released = !Directory.Exists(item.Letter + "\\");
            Process tunnel = item.TunnelProcess;
            if (tunnel != null && !tunnel.HasExited)
            {
                try { tunnel.StandardInput.WriteLine("close"); tunnel.StandardInput.Flush(); } catch { }
                try { if (!tunnel.WaitForExit(5000)) tunnel.Kill(); } catch { }
            }
            item.Status = released ? "STOPPED" : "UNMOUNT VERIFY FAILED";
            if (released) lock (driveMountGate) activeDriveMounts.Remove(item);
            return released;
        }

        private void OpenSelectedDriveMount()
        {
            DriveMountItem selected = driveMountGrid.SelectedItem as DriveMountItem;
            if (selected == null || !Directory.Exists(selected.Letter + "\\"))
            {
                driveMountStatus.Text = english ? "Select one active mounted drive." : "请选择一个活动挂载盘。";
                return;
            }
            try { Process.Start(new ProcessStartInfo(selected.Letter + "\\") { UseShellExecute = true }); }
            catch (Exception error) { driveMountStatus.Text = error.Message; }
        }

        private void PrepareDriveShellForWindowClose(CancelEventArgs args)
        {
            DriveMountItem[] mounts;
            lock (driveMountGate) mounts = activeDriveMounts.ToArray();
            if (mounts.Length > 0 && MessageBox.Show(window,
                english ? "Closing TextNodeAssistant will safely unmount all managed letters and close their SSH tunnels. Continue?" : "关闭 TextNodeAssistant 将安全卸载全部受管盘符并关闭各自 SSH 隧道。继续？",
                "TextNodeAssistant", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                args.Cancel = true;
                return;
            }
            foreach (DriveMountItem item in mounts) StopDriveMount(item);
            if (driveSessionProcess != null && !driveSessionProcess.HasExited)
            {
                try { driveSessionProcess.StandardInput.WriteLine("close"); driveSessionProcess.StandardInput.Flush(); } catch { }
                try { if (!driveSessionProcess.WaitForExit(4000)) driveSessionProcess.Kill(); } catch { }
            }
        }
    }
}
