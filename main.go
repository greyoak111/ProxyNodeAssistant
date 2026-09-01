package main

import (
	"bufio"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
)

const version = "1.0.0"

var errInputClosed = errors.New("interactive input was closed")

const guiPromptPrefix = "PNA_GUI_PROMPT_B64="
const guiSecretPromptPrefix = "PNA_GUI_SECRET_B64="

//go:embed assets/proxy-node-assistant-toolkit-v1.0.0.tar.gz
var embeddedToolkit []byte

type Lang string

const (
	LangZH Lang = "zh"
	LangEN Lang = "en"
)

type Settings struct {
	Language           Lang               `json:"language"`
	InstallPreferences InstallPreferences `json:"installPreferences"`
}

type App struct {
	reader           *bufio.Reader
	lang             Lang
	conn             *Connection
	actionConnection *Connection
	activeTemporary  *Connection
	tempCleanupMu    sync.Mutex
	tunnels          []*exec.Cmd
	inputClosed      bool
	installPrefs     InstallPreferences
}

func settingsPath() (string, error) {
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, "ProxyNodeAssistant", "settings.json"), nil
}

func legacySettingsPath() (string, error) {
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, "TextNodeAssistant", "settings.json"), nil
}

func (a *App) loadLanguage() {
	a.lang = LangZH
	a.installPrefs = defaultInstallPreferences()
	path, err := settingsPath()
	if err != nil {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		legacyPath, legacyErr := legacySettingsPath()
		if legacyErr != nil {
			return
		}
		data, err = os.ReadFile(legacyPath)
		if err != nil {
			return
		}
	}
	var settings Settings
	if json.Unmarshal(data, &settings) == nil && (settings.Language == LangZH || settings.Language == LangEN) {
		a.lang = settings.Language
		candidate := settings.InstallPreferences
		_, coverOK := normalizeCoverTemplateChoice(candidate.CoverChoice)
		if strings.EqualFold(strings.TrimSpace(candidate.CoverChoice), "preserve") {
			coverOK = true
		}
		if validRouteMode(candidate.RouteMode) &&
			validPerformanceMode(candidate.Performance) &&
			validWarpMode(candidate.WarpMode) &&
			coverOK &&
			candidate.BackupBeforeChange {
			a.installPrefs = candidate
		}
	}
}

func (a *App) saveLanguage() {
	path, err := settingsPath()
	if err != nil {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0700) != nil {
		return
	}
	data, _ := json.MarshalIndent(Settings{Language: a.lang, InstallPreferences: a.installPrefs}, "", "  ")
	_ = os.WriteFile(path, data, 0600)
}

func (a *App) msg(zh, en string) string {
	if a.lang == LangEN {
		return en
	}
	return zh
}

func (a *App) println(values ...interface{}) {
	fmt.Println(values...)
}

func guiPromptFrame(label string) string {
	return guiPromptPrefix + base64.StdEncoding.EncodeToString([]byte(label))
}

func guiSecretPromptFrame(label string) string {
	return guiSecretPromptPrefix + base64.StdEncoding.EncodeToString([]byte(label))
}

func (a *App) prompt(label string) string {
	if a.inputClosed {
		return ""
	}
	if os.Getenv("PNA_GUI_MODE") == "1" {
		fmt.Println(guiPromptFrame(label))
	} else {
		fmt.Print(label + ": ")
	}
	value, err := a.reader.ReadString('\n')
	if err != nil && strings.TrimSpace(value) == "" {
		a.inputClosed = true
	}
	return strings.TrimSpace(value)
}

func (a *App) secretPrompt(label string) string {
	if a.inputClosed {
		return ""
	}
	var restore func()
	if os.Getenv("PNA_GUI_MODE") == "1" {
		fmt.Println(guiSecretPromptFrame(label))
	} else {
		fmt.Print(label + ": ")
		restore = disableConsoleEcho()
	}
	value, err := a.reader.ReadString('\n')
	if restore != nil {
		restore()
		fmt.Println()
	}
	if err != nil && strings.TrimSpace(value) == "" {
		a.inputClosed = true
	}
	return strings.TrimSpace(value)
}

func (a *App) required(label string) (string, error) {
	for {
		value := a.prompt(label)
		if value != "" {
			return value, nil
		}
		if a.inputClosed {
			return "", errInputClosed
		}
		a.println(a.msg("此项必须填写。", "This value is required."))
	}
}

func (a *App) yes(label string, defaultYes bool) bool {
	suffix := "[y/N]"
	if defaultYes {
		suffix = "[Y/n]"
	}
	value := strings.ToLower(strings.TrimSpace(a.prompt(label + " " + suffix)))
	if a.inputClosed {
		return false
	}
	if value == "" {
		return defaultYes
	}
	return value == "y" || value == "yes" || value == "是"
}

func (a *App) pause() {
	a.prompt(a.msg("按 Enter 返回主菜单", "Press Enter to return to the main menu"))
}

func (a *App) toggleLanguage() {
	if a.lang == LangZH {
		a.lang = LangEN
		a.println("Language switched to English.")
	} else {
		a.lang = LangZH
		a.println("已切换为中文。")
	}
	a.saveLanguage()
}

func (a *App) banner() {
	a.println("============================================================")
	a.println(" ProxyNodeAssistant v" + version)
	a.println(a.msg(" 隐私优先 · 中英双语 · 失败不连锁", " Privacy-first · bilingual · fail-closed"))
	a.println("============================================================")
	a.println(a.msg("共享 EXE 不内置任何真实 VPS IP、域名、账户或密钥。", "The shared EXE contains no real VPS IP, domain, account, or key."))
	a.println(a.msg("可选历史只留在本机，且仅含地址/用户/端口；密码和密钥不回写 EXE。", "Optional local history stores only host/user/port; passwords and keys are never written back into the EXE."))
	a.println()
}

func (a *App) printMenu() {
	if a.lang == LangZH {
		a.println("每项远端操作都会重新选择：临时密码 / 节点长期 key；不会绑死上一台 VPS。")
		a.println("[1] 【唯一安装入口】安装 / 升级 / 自适应优化")
		a.println("[2] 无感打开 3x-ui 面板（127.0.0.1 SSH 隧道）")
		a.println("[3] 自动体检与排障")
		a.println("[4] 安全自动修复（先备份）")
		a.println("[5] 随机化 VPS 登录密码（显示真密码 + 剪贴板）")
		a.println("[6] 随机化 3x-ui 账号密码（显示真凭据 + 剪贴板）")
		a.println("[7] 显示并复制当前凭据交接单")
		a.println("[8] 切换 15 套伪装站（随机/编号）+ 优化 Nginx")
		a.println("[9] 完整灾备（含程序/身份，体积较大）")
		a.println("[10] 生成并下载紧急诊断报告")
		a.println("[11] 绑定 / 重新生成 SSH 登录密钥（先验证再换旧钥）")
		a.println("[12] 清空系统剪贴板")
		a.println("[13] 卸载远端内嵌包（保留节点、配置、凭据与备份）")
		a.println("[14] 本地 10808 代理环境变量：配置 / 撤销 / 查看（不连接 VPS）")
		a.println("[15] 清理远端多余备份 + 仅备份当前配置（只保留一份）")
		a.println("[16] 自适应性能档位：检测 / 低配 / 标准 / 高配 / 回滚")
		a.println("[17] SSH/vnStat 流量估算与 70/85/95% 预警")
		a.println("[18] 全量拆除本工具施工并恢复原始基线（高风险，先下载救援包）")
		a.println("[19] SS2022 来源白名单：识别当前本地公网 IP / 对照 VPS / 明确添加")
		a.println("[T] 服务商流量中心：KiwiVM 精确 API / 兼容 API / 凭据管理器")
		a.println("[K] 管理已绑定 key：查看 / 恢复 / 全部转入备份态并清空绑定位置")
		a.println("[H] 管理 VPS 登录历史：查看 / 删除单条 / 清空全部")
		a.println("[L] English / 中文")
		a.println("[C] 清空当前选择和隧道（不删除已绑定 key）")
		a.println("[0] 退出")
	} else {
		a.println("Every remote action re-selects temporary password / managed key; the previous VPS is never forced.")
		a.println("[1] [ONLY INSTALL ENTRY] Install / upgrade / adaptive convergence")
		a.println("[2] Open 3x-ui through a 127.0.0.1 SSH tunnel")
		a.println("[3] Automatic diagnosis")
		a.println("[4] Safe automatic repair (backup first)")
		a.println("[5] Rotate VPS login password (real password + clipboard)")
		a.println("[6] Rotate 3x-ui credentials (real values + clipboard)")
		a.println("[7] Show and copy the current credential handoff")
		a.println("[8] Switch 15 cover templates (random/ID) + optimize Nginx")
		a.println("[9] Full disaster backup (includes programs/identity; larger)")
		a.println("[10] Generate and download an emergency report")
		a.println("[11] Bind / regenerate the SSH login key (verify before replacing)")
		a.println("[12] Clear the system clipboard")
		a.println("[13] Uninstall the remote embedded toolkit (preserve node data and backups)")
		a.println("[14] Local 10808 proxy environment: configure / remove / inspect (no VPS login)")
		a.println("[15] Prune redundant remote backups + keep one current-config backup")
		a.println("[16] Adaptive performance: detect / low / standard / high / rollback")
		a.println("[17] SSH/vnStat traffic estimate with 70/85/95% warnings")
		a.println("[18] Fully dismantle managed construction and restore the original baseline (high risk; rescue first)")
		a.println("[19] SS2022 source allowlist: detect local public IP / compare VPS view / explicitly add")
		a.println("[T] Provider traffic center: exact KiwiVM API / compatible API / Credential Manager")
		a.println("[K] Manage bound keys: inspect / restore / archive all and empty bound positions")
		a.println("[H] Manage VPS login history: inspect / delete one / clear all")
		a.println("[L] English / 中文")
		a.println("[C] Clear the current selection and tunnels (keep bound keys)")
		a.println("[0] Exit")
	}
}

func copyClipboard(value string) error {
	return copyClipboardPlatform(value)
}

func (a *App) clearClipboard() error {
	if err := clearClipboardPlatform(); err != nil {
		return err
	}
	a.println(a.msg("剪贴板已清空。", "Clipboard cleared."))
	return nil
}

func (a *App) secretHandoff(title, block string) error {
	a.println()
	a.println("================ " + title + " ================")
	a.println(block)
	a.println("============================================================")
	if err := copyClipboard(block); err != nil {
		a.println(a.msg("自动复制失败，请手工保存上面的真实信息。", "Automatic copy failed; save the real values above manually."))
		return err
	}
	a.println(a.msg("已复制到系统剪贴板。请立即粘贴进密码管理器/安全笔记。", "Copied to the system clipboard. Paste it into your password manager/secure note now."))
	a.prompt(a.msg("保存好以后按 Enter", "After saving it, press Enter"))
	if a.yes(a.msg("现在清空含秘密的剪贴板？", "Clear the secret-bearing clipboard now?"), true) {
		return a.clearClipboard()
	}
	return nil
}

func (a *App) extractEmbeddedTar() (string, error) {
	if len(embeddedToolkit) < 128 {
		return "", fmt.Errorf("embedded toolkit is unexpectedly empty")
	}
	dir := filepath.Join(os.TempDir(), "ProxyNodeAssistant-v1.0.0")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "proxy-node-assistant-toolkit-v1.0.0.tar.gz")
	if err := os.WriteFile(path, embeddedToolkit, 0600); err != nil {
		return "", err
	}
	return path, nil
}

func (a *App) executeActionChoice(choice string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(choice)) {
	case "1":
		return true, a.runRemoteAction(a.deployOptimize)
	case "2":
		return true, a.runRemoteAction(a.openPanel)
	case "3":
		return true, a.runRemoteAction(a.diagnose)
	case "4":
		return true, a.runRemoteAction(a.safeRepair)
	case "5":
		return true, a.runRemoteAction(a.rotateVPSPassword)
	case "6":
		return true, a.runRemoteAction(a.rotatePanelCredentials)
	case "7":
		return true, a.runRemoteAction(a.showHandoff)
	case "8":
		return true, a.runRemoteAction(a.optimizeCover)
	case "9":
		return true, a.runRemoteAction(a.backupNode)
	case "10":
		return true, a.runRemoteAction(a.emergencyReport)
	case "11":
		return true, a.runRemoteAction(a.rotateSSHKey)
	case "12":
		return true, a.clearClipboard()
	case "13":
		return true, a.runRemoteAction(a.uninstallRemoteToolkit)
	case "14":
		return true, a.manageLocalProxy()
	case "15":
		return true, a.runRemoteAction(a.pruneBackupsAndBackupCurrentConfig)
	case "16":
		return true, a.runRemoteAction(a.performanceProfiles)
	case "17":
		return true, a.runRemoteAction(a.trafficEstimate)
	case "18":
		return true, a.runRemoteAction(a.dismantleManagedNode)
	case "19":
		return true, a.runRemoteAction(a.manageSS2022Allowlist)
	case "t":
		return true, a.providerTrafficCenter()
	case "k":
		return true, a.manageBoundKeys()
	case "h":
		return true, a.manageRecentTargets()
	default:
		return false, nil
	}
}

func (a *App) prepareConsoleSession() bool {
	a.banner()
	if err := a.startupOpenSSHPreflight(); err != nil {
		a.println()
		a.println(a.msg("OpenSSH 准备失败，程序不会反复安装或进入远端菜单：", "OpenSSH setup failed. The program will not retry in a loop or enter the remote menu:") + " " + err.Error())
		a.prompt(a.msg("按 Enter 安全退出", "Press Enter to exit safely"))
		return false
	}
	a.println()
	return true
}

func shouldHoldCreatedPanelTunnel(handled bool, actionErr error, tunnelCount int) bool {
	return handled && actionErr == nil && tunnelCount > 0
}

func (a *App) holdCreatedPanelTunnelsIfNeeded(handled bool, actionErr error) bool {
	if !shouldHoldCreatedPanelTunnel(handled, actionErr, len(a.tunnels)) {
		return false
	}
	a.println()
	a.println("PANEL_TUNNEL_SESSION_ACTIVE")
	a.prompt(a.msg("面板 SSH 隧道正在保持。浏览器使用完毕后，点击图形界面的“关闭面板隧道”", "The panel SSH tunnel is being kept alive. When finished in the browser, click Close panel tunnel in the graphical client"))
	a.println(a.msg("正在关闭本工具创建的面板隧道。", "Closing the panel tunnel created by this tool."))
	a.killTunnels()
	return true
}

func (a *App) runDirectAction(choice string, pauseAtEnd bool) {
	if !a.prepareConsoleSession() {
		return
	}
	a.println(a.msg("图形客户端已直达所选操作：", "The graphical client opened the selected action directly:") + " " + strings.ToUpper(choice))
	a.println()
	handled, err := a.executeActionChoice(choice)
	if !handled {
		a.println(a.msg("无效的图形客户端操作编号。", "Invalid graphical-client action identifier."))
	} else if err != nil {
		a.println()
		a.println(a.msg("操作未完成：", "Operation did not complete:") + " " + err.Error())
	}
	tunnelHeld := a.holdCreatedPanelTunnelsIfNeeded(handled, err)
	a.println()
	if pauseAtEnd && !tunnelHeld {
		a.pause()
	}
}

func (a *App) run() {
	if !a.prepareConsoleSession() {
		return
	}
	for {
		a.printMenu()
		choice := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))))
		if a.inputClosed {
			a.println()
			a.println(a.msg("输入已关闭，安全退出。", "Input was closed; exiting safely."))
			return
		}
		a.println()
		var err error
		switch choice {
		case "l":
			a.toggleLanguage()
			continue
		case "c":
			if cleanupErr := a.cleanupActiveTemporaryAuth(); cleanupErr != nil {
				a.println(a.msg("临时登录清理警告：", "Temporary-login cleanup warning:") + " " + cleanupErr.Error())
			}
			a.killTunnels()
			a.conn = nil
			a.actionConnection = nil
			a.println(a.msg("当前选择与隧道已清空。已绑定 key 没有删除；每项操作本来就会重新选择 VPS。", "The current selection and tunnels were cleared. Bound keys were not deleted; every action already re-selects its VPS."))
			continue
		case "0":
			a.println(a.msg("退出。所有由本工具启动的面板 SSH 隧道会一并关闭。", "Exiting. Panel SSH tunnels started by this tool will be closed."))
			return
		default:
			handled, actionErr := a.executeActionChoice(choice)
			if !handled {
				a.println(a.msg("无效选择。", "Invalid choice."))
				continue
			}
			err = actionErr
		}
		if err != nil {
			a.println()
			a.println(a.msg("操作未完成：", "Operation did not complete:") + " " + err.Error())
		}
		tunnelHeld := a.holdCreatedPanelTunnelsIfNeeded(true, err)
		a.println()
		if !tunnelHeld {
			a.pause()
		}
		a.println()
	}
}

func requestedDirectAction(args []string) string {
	for index := 0; index < len(args); index++ {
		if args[index] == "--action" && index+1 < len(args) {
			return strings.ToLower(strings.TrimSpace(args[index+1]))
		}
	}
	return ""
}

func requestedGUIAction(args []string) string {
	for index := 0; index < len(args); index++ {
		if args[index] == "--gui-action" && index+1 < len(args) {
			return strings.ToLower(strings.TrimSpace(args[index+1]))
		}
	}
	return ""
}

func requestedOpenSSHPreflight(args []string) bool {
	for _, value := range args {
		if value == "--openssh-preflight" {
			return true
		}
	}
	return false
}

func requestedInputCloseSmoke(args []string) bool {
	for _, value := range args {
		if value == "--input-close-smoke" {
			return true
		}
	}
	return false
}

func requestedPromptSequenceSmoke(args []string) bool {
	for _, value := range args {
		if value == "--prompt-sequence-smoke" {
			return true
		}
	}
	return false
}

func requestedTunnelCloseSmoke(args []string) bool {
	for _, value := range args {
		if value == "--tunnel-close-smoke" {
			return true
		}
	}
	return false
}

func (a *App) runPromptSequenceSmoke() int {
	a.println("BACKUP_ROOT=C:\\example\\managed-key-backups")
	if strings.TrimSpace(a.prompt(a.msg("输入备份编号；0 取消", "Enter backup number; 0 cancels"))) != "1" {
		return 3
	}
	a.println("BACKUP_DIRECTORY=C:\\example\\managed-key-backups\\node-001")
	answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("使用这个目标恢复？", "Restore to this target?"))))
	if answer != "y" && answer != "yes" && answer != "是" {
		return 4
	}
	a.println("PNA_GUI_PROMPT_SEQUENCE_OK")
	return 0
}

func (a *App) runTunnelCloseSmoke() int {
	a.println("PANEL_TUNNEL_SESSION_ACTIVE")
	answer := a.prompt(a.msg("面板 SSH 隧道正在保持。点击“关闭面板隧道”结束测试", "The panel SSH tunnel is active. Click Close panel tunnel to finish the smoke test"))
	if a.inputClosed {
		return 5
	}
	if answer != "" {
		return 6
	}
	a.println("PNA_GUI_TUNNEL_CLOSE_ACK")
	return 0
}

func main() {
	setUTF8Console()
	app := &App{reader: bufio.NewReader(os.Stdin)}
	app.loadLanguage()
	defer app.killTunnels()
	defer app.cleanupActiveTemporaryAuth()
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	go func() {
		<-interrupts
		_ = app.cleanupActiveTemporaryAuth()
		app.killTunnels()
		os.Exit(130)
	}()
	if requestedInputCloseSmoke(os.Args[1:]) {
		if _, err := app.required("PNA_INPUT_CLOSE_SMOKE_REQUIRED"); !errors.Is(err, errInputClosed) {
			fmt.Fprintln(os.Stderr, "input-close smoke did not observe EOF")
			os.Exit(2)
		}
		return
	}
	if requestedPromptSequenceSmoke(os.Args[1:]) {
		if code := app.runPromptSequenceSmoke(); code != 0 {
			os.Exit(code)
		}
		return
	}
	if requestedTunnelCloseSmoke(os.Args[1:]) {
		if code := app.runTunnelCloseSmoke(); code != 0 {
			os.Exit(code)
		}
		return
	}
	if requestedOpenSSHPreflight(os.Args[1:]) {
		if err := app.startupOpenSSHPreflight(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if action := requestedGUIAction(os.Args[1:]); action != "" {
		app.runDirectAction(action, false)
		return
	}
	if action := requestedDirectAction(os.Args[1:]); action != "" {
		app.runDirectAction(action, true)
		return
	}
	app.run()
}
