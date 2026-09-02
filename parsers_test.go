package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPromptMarksClosedInput(t *testing.T) {
	app := &App{reader: bufio.NewReader(strings.NewReader("")), lang: LangEN}
	if value := app.prompt("test"); value != "" {
		t.Fatalf("expected empty value, got %q", value)
	}
	if !app.inputClosed {
		t.Fatal("EOF must be marked so the menu exits instead of busy-looping")
	}
}
func TestGUIPromptFrameRoundTripsUnicodeAndIsLineSafe(t *testing.T) {
	label := "输入备份编号；0 取消"
	frame := guiPromptFrame(label)
	if !strings.HasPrefix(frame, guiPromptPrefix) || strings.ContainsAny(frame, "\r\n") {
		t.Fatalf("invalid GUI prompt frame: %q", frame)
	}
	payload := strings.TrimPrefix(frame, guiPromptPrefix)
	decoded, err := base64.StdEncoding.DecodeString(payload)
	if err != nil || string(decoded) != label {
		t.Fatalf("prompt frame round trip failed: decoded=%q err=%v", decoded, err)
	}
}

func TestRequiredReturnsImmediatelyWhenInputCloses(t *testing.T) {
	app := &App{reader: bufio.NewReader(strings.NewReader("")), lang: LangEN}
	value, err := app.required("required test")
	if value != "" || !errors.Is(err, errInputClosed) {
		t.Fatalf("required input returned value=%q err=%v", value, err)
	}
}

func TestDomainEmailPromptDoesNotBusyLoopOnClosedInput(t *testing.T) {
	app := &App{reader: bufio.NewReader(strings.NewReader("")), lang: LangEN}
	domain, email, err := app.askDomainEmail()
	if domain != "" || email != "" || !errors.Is(err, errInputClosed) {
		t.Fatalf("closed input returned domain=%q email=%q err=%v", domain, email, err)
	}
}

func TestGUIRejectsBlankRequiredInputAndSerializesSubmissions(t *testing.T) {
	source, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"PNA_GUI_PROMPT_B64=",
		"TryDecodeGuiPrompt",
		"reader.ReadLine()",
		"suppressedPromptFrames = prefilledInput.Count",
		"hasFramedPrompt && !suppressFramedPrompt",
		"LooksLikeRequiredPrompt(operationPromptText.Text)",
		"String.IsNullOrWhiteSpace(value)",
		"if (operationInputPending) return",
		"operationInputPending = true",
		"SetOperationInputReady(false)",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("GUI input guard is missing %q", required)
		}
	}
}

func TestGUIUsesCustomHardcoreScrollbarsAndSquareActionCards(t *testing.T) {
	source, err := os.ReadFile("gui/MainWindow.xaml")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		`x:Key="VerticalScrollThumbStyle"`,
		`x:Key="HorizontalScrollThumbStyle"`,
		`TargetType="{x:Type ScrollBar}"`,
		`ScrollBar.PageUpCommand`,
		`ScrollBar.PageLeftCommand`,
		`Property="IsDragging"`,
		`x:Key="ActionCardStyle"`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("hardcore GUI theme is missing %q", required)
		}
	}
	cardStart := strings.Index(text, `x:Key="ActionCardStyle"`)
	cardEnd := strings.Index(text[cardStart:], `</Style>`)
	if cardStart < 0 || cardEnd < 0 {
		t.Fatal("action-card style could not be isolated")
	}
	cardBlock := text[cardStart : cardStart+cardEnd]
	if strings.Contains(cardBlock, "CornerRadius") {
		t.Fatal("action cards regressed to rounded consumer-dashboard styling")
	}
}

func TestRequestedDirectAction(t *testing.T) {
	tests := []struct {
		args []string
		want string
	}{
		{[]string{"--action", "1"}, "1"},
		{[]string{"ignored", "--action", "K"}, "k"},
		{[]string{"--action", " 14 "}, "14"},
		{[]string{"--action"}, ""},
		{nil, ""},
	}
	for _, test := range tests {
		if got := requestedDirectAction(test.args); got != test.want {
			t.Fatalf("requestedDirectAction(%q) = %q, want %q", test.args, got, test.want)
		}
	}
}

func TestRequestedGUIAction(t *testing.T) {
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"--gui-action", "1"}, "1"},
		{[]string{"ignored", "--gui-action", "K"}, "k"},
		{[]string{"--gui-action"}, ""},
	} {
		if got := requestedGUIAction(test.args); got != test.want {
			t.Fatalf("requestedGUIAction(%q) = %q, want %q", test.args, got, test.want)
		}
	}
}

func TestRequestedInputCloseSmoke(t *testing.T) {
	if !requestedInputCloseSmoke([]string{"--input-close-smoke"}) {
		t.Fatal("closed-input smoke flag was not recognized")
	}
	if requestedInputCloseSmoke([]string{"--other"}) {
		t.Fatal("unrelated flag enabled closed-input smoke")
	}
}

func TestRequestedPromptSequenceSmoke(t *testing.T) {
	if !requestedPromptSequenceSmoke([]string{"--prompt-sequence-smoke"}) {
		t.Fatal("multi-step prompt smoke flag was not recognized")
	}
	if requestedPromptSequenceSmoke([]string{"--other"}) {
		t.Fatal("unrelated flag enabled multi-step prompt smoke")
	}
}

func TestRequestedTunnelCloseSmoke(t *testing.T) {
	if !requestedTunnelCloseSmoke([]string{"--tunnel-close-smoke"}) {
		t.Fatal("tunnel close smoke flag was not recognized")
	}
	if requestedTunnelCloseSmoke([]string{"--tunnel-lifetime-smoke"}) {
		t.Fatal("GUI wrapper smoke flag must not be mistaken for the embedded close protocol")
	}
	app := &App{reader: bufio.NewReader(strings.NewReader("\n")), lang: LangEN}
	if code := app.runTunnelCloseSmoke(); code != 0 {
		t.Fatalf("tunnel close protocol rejected an empty close line: %d", code)
	}
}

func TestRequestedOpenSSHPreflight(t *testing.T) {
	if !requestedOpenSSHPreflight([]string{"ignored", "--openssh-preflight"}) {
		t.Fatal("OpenSSH preflight flag was not recognized")
	}
	if requestedOpenSSHPreflight([]string{"--gui-action", "1"}) {
		t.Fatal("normal GUI actions must not be mistaken for an OpenSSH-only preflight")
	}
}

func TestEveryEntryPointHoldsCreatedPanelTunnels(t *testing.T) {
	tests := []struct {
		handled bool
		err     error
		tunnels int
		want    bool
	}{
		{true, nil, 1, true}, // menu [2]
		{true, nil, 2, true}, // menu [1] or any future action that opened a tunnel
		{true, nil, 0, false},
		{true, fmt.Errorf("failed"), 1, false},
		{false, nil, 1, false},
	}
	for _, test := range tests {
		if got := shouldHoldCreatedPanelTunnel(test.handled, test.err, test.tunnels); got != test.want {
			t.Fatalf("shouldHoldCreatedPanelTunnel(%v, %v, %d) = %v, want %v", test.handled, test.err, test.tunnels, got, test.want)
		}
	}
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"PANEL_TUNNEL_SESSION_ACTIVE", "len(a.tunnels)", "a.killTunnels()"} {
		if !strings.Contains(string(source), required) {
			t.Fatalf("direct tunnel lifetime contract is missing %q", required)
		}
	}
	app := &App{
		reader:  bufio.NewReader(strings.NewReader("\n")),
		lang:    LangEN,
		tunnels: []*exec.Cmd{{}},
	}
	if !app.holdCreatedPanelTunnelsIfNeeded(true, nil) {
		t.Fatal("an actual panel tunnel was not held")
	}
	if len(app.tunnels) != 0 {
		t.Fatal("the explicit close action did not clear the held tunnel list")
	}
}

func TestGUIActionMapMatchesConsoleActions(t *testing.T) {
	guiSource, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	guiText := string(guiSource)
	mainSource, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	mainText := string(mainSource)
	for _, id := range []string{"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "K"} {
		if !strings.Contains(guiText, `Op("`+id+`",`) {
			t.Fatalf("GUI action map is missing action %s", id)
		}
		consoleID := strings.ToLower(id)
		if !strings.Contains(mainText, `case "`+consoleID+`":`) {
			t.Fatalf("console direct-action dispatcher is missing action %s", id)
		}
	}
	for _, required := range []string{
		"--gui-action", "--openssh-preflight", "UseShellExecute = false", "CreateNoWindow = true",
		"RedirectStandardInput = true", "RedirectStandardOutput = true",
		"NamedPipeServerStream", "AskPassResourceName", "PasswordBox", "SHA256.Create",
		"PANEL_TUNNEL_SESSION_ACTIVE", "Close panel tunnel", "tunnelSessionActive",
		"--tunnel-close-smoke", "PNA_GUI_TUNNEL_CLOSE_ACK", "Button.ClickEvent",
	} {
		if !strings.Contains(guiText, required) {
			t.Fatalf("fully graphical launch contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{"UseShellExecute = true", "LaunchConsole(", "runInteractiveConsole", `EnvironmentVariables["PNA_PASSWORD"]`, `mode == null ? "2"`} {
		if strings.Contains(guiText, forbidden) {
			t.Fatalf("GUI still contains console/plaintext-password behavior %q", forbidden)
		}
	}
	xaml, err := os.ReadFile("gui/MainWindow.xaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"OperationWorkspace", "RemoteConnectionForm", "OperationInputPanel", "AskPassOverlay", "AskPassPassword", "请选择登录方式", `Tag="1"`, `Tag="2"`} {
		if !strings.Contains(string(xaml), required) {
			t.Fatalf("fully graphical XAML is missing %q", required)
		}
	}
}

func TestLocalProxyConstantsAndParser(t *testing.T) {
	if localProxyURL != "http://127.0.0.1:10808" {
		t.Fatalf("unexpected local proxy URL %q", localProxyURL)
	}
	if localProxyBypass != "localhost,127.0.0.1,::1" {
		t.Fatalf("unexpected NO_PROXY value %q", localProxyBypass)
	}
	values := parseEnvironmentLines("HTTP_PROXY=http://127.0.0.1:10808\r\nHTTPS_PROXY=http://127.0.0.1:10808\r\nNO_PROXY=localhost,127.0.0.1,::1\r\n")
	for _, name := range localProxyNames {
		if values[name] != expectedLocalProxyValue(name) {
			t.Fatalf("%s parsed as %q", name, values[name])
		}
	}
}

func TestLocalProxyMenuNeverUsesRemoteActionWrapper(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	if !strings.Contains(text, `case "14":`) || !strings.Contains(text, `return true, a.manageLocalProxy()`) {
		t.Fatal("local proxy menu action is missing")
	}
	if strings.Contains(text, `runRemoteAction(a.manageLocalProxy)`) {
		t.Fatal("local proxy menu must never request a VPS connection")
	}
}

func TestRemoteBackupCleanupMenuUsesStandardActionWrapper(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	if !strings.Contains(text, `case "15":`) || !strings.Contains(text, `runRemoteAction(a.pruneBackupsAndBackupCurrentConfig)`) {
		t.Fatal("remote backup cleanup menu must use the standard dual-login action wrapper")
	}
	operations, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"confirmation != \"CLEAN\"", "CURRENT_CONFIG_BACKUP_OK", "MANIFEST_VERIFY_OK=1", "HISTORICAL_FILES_IN_ARCHIVE=0", "SERVICES_UNCHANGED=1"} {
		if !strings.Contains(string(operations), required) {
			t.Fatalf("remote backup cleanup operation is missing %q", required)
		}
	}
}

func TestCurrentConfigBackupValidatesBeforeLimitedCleanup(t *testing.T) {
	path := "runbook/proxy-node-assistant-v1.0.0/linux/19-prune-backups-current-config.sh"
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		`[ -s "$PAYLOAD/etc/x-ui/x-ui.db" ]`,
		`gzip -t "$ARCHIVE"`,
		`tar -xzf "$ARCHIVE" -C "$VERIFY"`,
		`sha256sum -c MANIFEST.sha256`,
		`! -path "$ARCHIVE" -print0`,
		`/root/.config/proxy-runbook/xray-template-before-warp-*.json`,
		`CURRENT_CONFIG_ARCHIVES=1`,
		`HISTORICAL_FILES_IN_ARCHIVE=0`,
		`SERVICES_UNCHANGED=1`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("current-config backup script is missing %q", required)
		}
	}
	validate := strings.Index(text, `sha256sum -c MANIFEST.sha256`)
	cleanup := strings.Index(text, `mapfile -d '' targets`)
	if validate < 0 || cleanup < 0 || validate > cleanup {
		t.Fatal("the new archive must be fully validated before cleanup targets are enumerated")
	}
	for _, forbidden := range []string{`rm -rf -- /root`, `find /root -delete`, `find / -delete`} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("unsafe broad cleanup remains: %q", forbidden)
		}
	}

	fullBackup, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/01-safe-backup.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(fullBackup), "cleanup_expanded_backup") || !strings.Contains(string(fullBackup), "trap cleanup_expanded_backup EXIT") {
		t.Fatal("the full disaster backup must not leave an expanded duplicate directory")
	}
}

func TestOpenSSHPreflightRunsBeforeMenuLoop(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	preflight := strings.Index(text, "a.startupOpenSSHPreflight()")
	menuLoop := strings.Index(text, "for {\n\t\ta.printMenu()")
	if preflight < 0 || menuLoop < 0 || preflight > menuLoop {
		t.Fatal("OpenSSH preflight must finish before the main menu loop")
	}
	remoteSource, err := os.ReadFile("remote.go")
	if err != nil {
		t.Fatal(err)
	}
	remoteText := string(remoteSource)
	if strings.Count(remoteText, "installOpenSSHClientOnce()") != 2 {
		t.Fatal("OpenSSH installer must have one function definition and one startup call site")
	}
	if strings.Contains(remoteText, "Windows OpenSSH Client 未安装。现在安装？") {
		t.Fatal("per-action OpenSSH installation prompt must not remain")
	}
}

func TestEveryActionAuthModeRequiresExplicitChoice(t *testing.T) {
	tests := []struct {
		input string
		mode  AuthMode
		ok    bool
	}{
		{"1\n", AuthTemporaryPassword, true},
		{"2\n", AuthManagedKey, true},
		{"0\n", "", false},
		{"\ninvalid\n1\n", AuthTemporaryPassword, true},
	}
	for _, test := range tests {
		app := &App{reader: bufio.NewReader(strings.NewReader(test.input)), lang: LangEN}
		mode, ok := app.chooseActionAuthMode()
		if mode != test.mode || ok != test.ok {
			t.Fatalf("input %q: expected (%q,%v), got (%q,%v)", test.input, test.mode, test.ok, mode, ok)
		}
	}
}

func TestActionConnectionDoesNotReuseCachedVPS(t *testing.T) {
	t.Setenv("PNA_HISTORY_PATH", filepath.Join(t.TempDir(), "empty-history.tsv"))
	old := &Connection{Host: "old.example.invalid", User: "root", Port: 22, AuthMode: AuthManagedKey}
	app := &App{
		reader: bufio.NewReader(strings.NewReader("1\nnew.example.invalid\nroot\n22\n")),
		lang:   LangEN,
		conn:   old,
	}
	c, err := app.getActionConnection()
	if err != nil {
		t.Fatal(err)
	}
	if c.Host != "new.example.invalid" || c.AuthMode != AuthTemporaryPassword {
		t.Fatalf("an action silently reused cached state: %#v", c)
	}
	if c.Temporary == nil || !validTemporaryKeyDir(c.Temporary.Dir) {
		t.Fatalf("temporary session did not get a guarded temp directory: %#v", c.Temporary)
	}
	if err := app.cleanupActionTemporaryAuth(); err != nil {
		t.Fatal(err)
	}
	if app.conn != nil || app.activeTemporary != nil {
		t.Fatal("temporary connection remained cached after cleanup")
	}
}

func TestAllRemoteMenuItemsUseUniversalActionLifecycle(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, action := range []string{
		"a.deployOptimize", "a.openPanel", "a.diagnose", "a.safeRepair",
		"a.rotateVPSPassword", "a.rotatePanelCredentials", "a.showHandoff",
		"a.optimizeCover", "a.backupNode", "a.emergencyReport", "a.rotateSSHKey",
		"a.uninstallRemoteToolkit",
	} {
		if !strings.Contains(text, "runRemoteAction("+action+")") {
			t.Fatalf("remote menu action bypasses the universal dual-auth lifecycle: %s", action)
		}
	}
}

func TestTemporaryKeyCleanupPathGuard(t *testing.T) {
	dir, err := os.MkdirTemp("", sessionTempPrefix)
	if err != nil {
		t.Fatal(err)
	}
	if !validTemporaryKeyDir(dir) {
		t.Fatalf("generated session directory was rejected: %s", dir)
	}
	if validTemporaryKeyDir(os.TempDir()) || validTemporaryKeyDir(`C:\`) || validTemporaryKeyDir("") {
		t.Fatal("unsafe broad path passed the temporary cleanup guard")
	}
	if err := removeTemporaryKeyDir(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("temporary session directory still exists: %v", err)
	}
}

func TestTemporaryAuthorizedKeyRemovalIsExactAndMarked(t *testing.T) {
	publicKey := "ssh-ed25519 AAAATEST temporary-session"
	command := temporaryAuthorizedKeyRemovalCommand(publicKey)
	if strings.Contains(command, publicKey) {
		t.Fatal("raw public key should be base64-wrapped before shell transport")
	}
	for _, required := range []string{"grep -vxF", "TEMPORARY_SSH_KEY_REMOVED", base64.StdEncoding.EncodeToString([]byte(publicKey))} {
		if !strings.Contains(command, required) {
			t.Fatalf("temporary-key removal command is missing %q", required)
		}
	}
}

func TestManagedAuthorizedKeyRemovalIsExactAndMarked(t *testing.T) {
	publicKey := "ssh-ed25519 AAAAMANAGED managed-binding"
	command := authorizedKeyRemovalCommand(publicKey, "MANAGED_SSH_KEY_REMOVED")
	for _, required := range []string{"grep -vxF", "MANAGED_SSH_KEY_REMOVED", base64.StdEncoding.EncodeToString([]byte(publicKey))} {
		if !strings.Contains(command, required) {
			t.Fatalf("managed-key removal command is missing %q", required)
		}
	}
	if strings.Contains(command, publicKey) {
		t.Fatal("raw managed public key should be base64-wrapped before shell transport")
	}
}

func TestTemporaryAuthorizedKeyRemovalExecutesWithoutTouchingOtherKeys(t *testing.T) {
	bash, err := exec.LookPath("bash.exe")
	if err != nil {
		bash, err = exec.LookPath("bash")
	}
	if err != nil {
		t.Skip("bash is not available for temporary-key removal integration")
	}
	temporaryKey := "ssh-ed25519 AAAATEMP temporary-session"
	otherKey := "ssh-ed25519 AAAAKEEP permanent-key"
	script := "set -eu; test_home=$(mktemp -d); trap 'rm -rf -- \"$test_home\"' EXIT; export HOME=\"$test_home\"; " +
		"mkdir -p \"$HOME/.ssh\"; printf '%s\\n' " + shQuote(otherKey) + " " + shQuote(temporaryKey) + " > \"$HOME/.ssh/authorized_keys\"; " +
		temporaryAuthorizedKeyRemovalCommand(temporaryKey) + "; " +
		"grep -qxF " + shQuote(otherKey) + " \"$HOME/.ssh/authorized_keys\"; " +
		"! grep -qxF " + shQuote(temporaryKey) + " \"$HOME/.ssh/authorized_keys\""
	var command *exec.Cmd
	if runtime.GOOS == "windows" {
		if wsl, findErr := exec.LookPath("wsl.exe"); findErr == nil {
			command = exec.Command(wsl, "--exec", "bash", "-c", script)
		}
	}
	if command == nil {
		command = exec.Command(bash, "-c", script)
	}
	if output, runErr := command.CombinedOutput(); runErr != nil {
		t.Fatalf("temporary key removal failed or changed another key: %v: %s", runErr, strings.TrimSpace(string(output)))
	}
}

func TestTemporaryPasswordFlowNeverHandsOffPrivateKey(t *testing.T) {
	remoteSource, err := os.ReadFile("remote.go")
	if err != nil {
		t.Fatal(err)
	}
	remoteText := string(remoteSource)
	start := strings.Index(remoteText, "func (a *App) prepareTemporaryPasswordAuth")
	end := strings.Index(remoteText, "func (a *App) cleanupTemporaryConnection")
	if start < 0 || end <= start {
		t.Fatal("temporary authentication functions are missing")
	}
	block := remoteText[start:end]
	for _, required := range []string{"generateKey(", "installPublicKey(", "Temporary.Installed"} {
		if !strings.Contains(block, required) {
			t.Fatalf("temporary authentication is missing %q", required)
		}
	}
	for _, forbidden := range []string{"showKeyHandoff", "secretHandoff", "copyClipboard"} {
		if strings.Contains(block, forbidden) {
			t.Fatalf("temporary private key must not be displayed or copied: %q", forbidden)
		}
	}

	authStart := strings.Index(remoteText, "func (a *App) authenticateActionConnection")
	authEnd := strings.Index(remoteText, "func (a *App) promptlessTemporaryConnection")
	if authStart < 0 || authEnd <= authStart {
		t.Fatal("universal action authentication block is missing")
	}
	authBlock := remoteText[authStart:authEnd]
	bindPrompt := strings.Index(authBlock, "if a.yes(")
	promote := strings.Index(authBlock, "a.promoteTemporaryConnection(c)")
	if bindPrompt < 0 || promote <= bindPrompt {
		t.Fatal("a temporary key may be promoted only after the explicit post-password bind prompt")
	}
	for _, required := range []string{"prepareTemporaryPasswordAuth(c)", "defaultBind := requestedMode == AuthManagedKey"} {
		if !strings.Contains(authBlock, required) {
			t.Fatalf("universal password/bootstrap flow is missing %q", required)
		}
	}
}

func TestManagedPromotionNeverOverwritesAndPreservesFiles(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source")
	destination := filepath.Join(dir, "destination")
	if err := os.WriteFile(source, []byte("private-material"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := copyFileExclusive(source, destination, 0600); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(destination); err != nil || string(data) != "private-material" {
		t.Fatalf("exclusive copy did not preserve content: %q, %v", data, err)
	}
	if err := copyFileExclusive(source, destination, 0600); err == nil {
		t.Fatal("exclusive promotion overwrote an existing managed key")
	}
}

func TestManagedKeyDirectoryMovesToRecoverableBackup(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	t.Setenv("HOME", home)
	keyPath := filepath.Join(home, ".ssh", "proxy-runbook", "example.invalid-root", "id_ed25519")
	if err := os.MkdirAll(filepath.Dir(keyPath), 0700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{keyPath, keyPath + ".pub", filepath.Join(filepath.Dir(keyPath), "known_hosts")} {
		if err := os.WriteFile(path, []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	backup, err := moveManagedKeyDirectoryToBackup(keyPath, time.Date(2026, 8, 17, 12, 34, 56, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(backup, "proxy-runbook-revoked") {
		t.Fatalf("backup is not under the recoverable revoked-key root: %s", backup)
	}
	if _, err := os.Stat(keyPath); !os.IsNotExist(err) {
		t.Fatalf("active managed key remained after backup move: %v", err)
	}
	if _, err := os.Stat(filepath.Join(backup, "id_ed25519")); err != nil {
		t.Fatalf("recoverable key backup is missing: %v", err)
	}
}

func TestKnownHostEntryCount(t *testing.T) {
	key1 := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 64)))
	key2 := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("b", 64)))
	input := strings.Join([]string{
		"# scan comment",
		"example.invalid ssh-ed25519 " + key1,
		"[example.invalid]:2222 ssh-rsa " + key2,
		"",
		"malformed",
		"example.invalid unsupported-key-type " + key1,
		"example.invalid ssh-ed25519 not-base64!",
	}, "\r\n")
	if got := knownHostEntryCount(input); got != 2 {
		t.Fatalf("expected 2 valid known-host entries, got %d", got)
	}
}

func TestParsedHostKeysAcceptsValidOutputWithNonzeroExit(t *testing.T) {
	c := Connection{Host: "example.invalid", User: "root", Port: 22}
	key := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 64)))
	result := ProcessResult{
		Stdout:   "# comment\nexample.invalid ssh-ed25519 " + key + "\n",
		Stderr:   "transient scanner warning\n",
		ExitCode: 1,
		Err:      fmt.Errorf("exit status 1"),
	}
	keys := parsedHostKeys(result, c)
	if knownHostEntryCount(keys) != 1 {
		t.Fatalf("valid host key was discarded because of the process exit code: %q", keys)
	}
}

func TestParsedHostKeysRejectsWrongHostAndNoise(t *testing.T) {
	c := Connection{Host: "example.invalid", User: "root", Port: 2222}
	key := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 64)))
	result := ProcessResult{Stdout: strings.Join([]string{
		"other.invalid ssh-ed25519 " + key,
		"[example.invalid]:22 ssh-ed25519 " + key,
		"Connection to example.invalid closed.",
	}, "\n")}
	if keys := parsedHostKeys(result, c); keys != "" {
		t.Fatalf("unexpected host-key lines survived filtering: %q", keys)
	}
}

func TestWin32KeyscanUnsupportedKEXDetection(t *testing.T) {
	broken := "choose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com"
	if !win32KeyscanUnsupportedKEX(broken) {
		t.Fatal("the documented Win32 ssh-keyscan sntrup defect was not recognized")
	}
	for _, other := range []string{
		"no matching key exchange method found",
		"choose_kex: unsupported KEX method another-algorithm",
		"sntrup761x25519-sha512@openssh.com",
	} {
		if win32KeyscanUnsupportedKEX(other) {
			t.Fatalf("unrelated diagnostic was misclassified: %q", other)
		}
	}
}

func TestIsolatedSSHHostKeyFallbackNeverUsesCredentialsOrPersistentTrust(t *testing.T) {
	c := Connection{Host: "example.invalid", User: "root", Port: 2222, KeyPath: `C:\Users\Test\.ssh\proxy-runbook\example-root\id_ed25519`}
	temporaryKnownHosts := `C:\Temp\pna-hostkey\known_hosts`
	args := strings.Join(isolatedSSHHostKeyArgs(c, temporaryKnownHosts), "\n")
	for _, required := range []string{
		"StrictHostKeyChecking=accept-new",
		"UserKnownHostsFile=C:/Temp/pna-hostkey/known_hosts",
		"GlobalKnownHostsFile=NUL",
		"BatchMode=yes",
		"PubkeyAuthentication=no",
		"PasswordAuthentication=no",
		"KbdInteractiveAuthentication=no",
		"PreferredAuthentications=none",
		"NumberOfPasswordPrompts=0",
	} {
		if !strings.Contains(args, required) {
			t.Fatalf("isolated host-key fallback is missing %q", required)
		}
	}
	for _, forbidden := range []string{c.KeyPath, knownHostsPath(c), "StrictHostKeyChecking=no"} {
		if strings.Contains(args, forbidden) {
			t.Fatalf("isolated host-key fallback contains unsafe persistent/credential input %q", forbidden)
		}
	}
}

func TestOpenSSHVersionParsingAndOrdering(t *testing.T) {
	if compareOpenSSHVersion([3]int{10, 0, 2}, [3]int{9, 8, 3}) <= 0 {
		t.Fatal("newer OpenSSH suite was not preferred")
	}
	if compareOpenSSHVersion([3]int{9, 2, 1}, [3]int{9, 2, 1}) != 0 {
		t.Fatal("equal OpenSSH versions compared unequal")
	}
	for input, want := range map[string][3]int{
		"OpenSSH_for_Windows_9.2p1, LibreSSL 3.7.2":       {9, 2, 1},
		"OpenSSH_for_Windows_10.0p2 Win32-OpenSSH-GitHub": {10, 0, 2},
	} {
		match := openSSHVersionPattern.FindStringSubmatch(input)
		if len(match) < 3 {
			t.Fatalf("version regex rejected %q", input)
		}
		got := [3]int{}
		for index := 1; index <= 3 && index < len(match); index++ {
			if match[index] != "" {
				got[index-1], _ = strconv.Atoi(match[index])
			}
		}
		if got != want {
			t.Fatalf("version %q parsed as %v, want %v", input, got, want)
		}
	}
}

func TestScanHostKeysIntegration(t *testing.T) {
	host := strings.TrimSpace(os.Getenv("PNA_TEST_HOST"))
	if host == "" {
		t.Skip("set PNA_TEST_HOST for an opt-in, public-host-key-only integration test")
	}
	port := 22
	if value := strings.TrimSpace(os.Getenv("PNA_TEST_PORT")); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 1 || parsed > 65535 {
			t.Fatalf("invalid PNA_TEST_PORT %q", value)
		}
		port = parsed
	}
	var paths map[string]string
	if directory := strings.TrimSpace(os.Getenv("PNA_TEST_OPENSSH_DIR")); directory != "" {
		paths = map[string]string{}
		for _, name := range requiredOpenSSHExecutables {
			path := filepath.Join(directory, name)
			if !fileExists(path) {
				t.Fatalf("PNA_TEST_OPENSSH_DIR is incomplete: %s is missing", path)
			}
			paths[strings.ToLower(name)] = path
		}
	} else {
		var ok bool
		paths, ok = resolveOpenSSHSuite()
		if !ok {
			t.Fatal("no complete Windows OpenSSH suite found")
		}
	}
	openSSHExecutablePaths = paths
	keys, attempts := scanHostKeys(Connection{Host: host, User: "test", Port: port})
	if knownHostEntryCount(keys) == 0 {
		t.Fatalf("host-key scan returned no valid keys: %s", formatHostKeyScanAttempts(attempts))
	}
	if os.Getenv("PNA_EXPECT_KEYSCAN_FALLBACK") == "1" {
		found := false
		for _, attempt := range attempts {
			if attempt.Method == "isolated-ssh-fallback" && attempt.ValidKeys > 0 {
				found = true
			}
		}
		if !found {
			t.Fatalf("the expected isolated ssh.exe fallback was not used: %s", formatHostKeyScanAttempts(attempts))
		}
	}
}

func TestSSHBasePinsDedicatedKnownHosts(t *testing.T) {
	c := Connection{Host: "example.invalid", User: "root", Port: 22, KeyPath: `C:\Users\Test User\.ssh\proxy-runbook\example-root\id_ed25519`}
	args := strings.Join(sshBase(c, false, false, ""), "\n")
	for _, required := range []string{
		`UserKnownHostsFile=C:/Users/Test\ User/.ssh/proxy-runbook/example-root/known_hosts`,
		"StrictHostKeyChecking=yes",
		"UpdateHostKeys=no",
	} {
		if !strings.Contains(args, required) {
			t.Fatalf("SSH arguments do not contain %q", required)
		}
	}
	for _, forbidden := range []string{"StrictHostKeyChecking=no", "accept-new"} {
		if strings.Contains(args, forbidden) {
			t.Fatalf("unsafe host-key behavior remains: %q", forbidden)
		}
	}
}

func TestSCPBasePinsDedicatedKnownHostsAndBatchMode(t *testing.T) {
	c := Connection{Host: "example.invalid", User: "root", Port: 2222, KeyPath: `C:\Users\Test User\.ssh\proxy-runbook\example-root\id_ed25519`}
	args := strings.Join(scpBase(c, c.KeyPath), "\n")
	for _, required := range []string{
		`UserKnownHostsFile=C:/Users/Test\ User/.ssh/proxy-runbook/example-root/known_hosts`,
		"StrictHostKeyChecking=yes", "UpdateHostKeys=no", "BatchMode=yes", "2222",
	} {
		if !strings.Contains(args, required) {
			t.Fatalf("SCP arguments do not contain %q", required)
		}
	}
}

func TestPasswordSSHSupportsGUIAskPassAndHostTrustPrecedesKeyGeneration(t *testing.T) {
	processSource, err := os.ReadFile("process.go")
	if err != nil {
		t.Fatal(err)
	}
	processText := string(processSource)
	for _, required := range []string{
		"func runInteractiveSSH",
		"cmd.Stdin = os.Stdin",
		"cmd.Stdout = os.Stdout",
		"cmd.Stderr = os.Stderr",
	} {
		if !strings.Contains(processText, required) {
			t.Fatalf("interactive SSH runner is missing %q", required)
		}
	}

	remoteSource, err := os.ReadFile("remote.go")
	if err != nil {
		t.Fatal(err)
	}
	remoteText := string(remoteSource)
	ensureStart := strings.Index(remoteText, "func (a *App) ensureKey")
	prepareStart := strings.Index(remoteText, "func (a *App) prepareTemporaryPasswordAuth")
	cleanupStart := strings.Index(remoteText, "func (a *App) cleanupTemporaryConnection")
	installStart := strings.Index(remoteText, "func (a *App) installPublicKey")
	if ensureStart < 0 || installStart < 0 || prepareStart < 0 || cleanupStart <= prepareStart {
		t.Fatal("SSH key functions are missing")
	}
	prepareBlock := remoteText[prepareStart:cleanupStart]
	if trust := strings.Index(prepareBlock, "a.ensureHostKey(*c)"); trust < 0 || trust > strings.Index(prepareBlock, "generateKey(") {
		t.Fatal("host-key trust must complete before generating a login private key")
	}
	installBlock := remoteText[installStart:ensureStart]
	if !strings.Contains(installBlock, `runInteractiveSSH("ssh.exe", args)`) {
		t.Fatal("password-based public-key installation must use the interactive SSH path")
	}
	if strings.Contains(installBlock, "installConn.KeyPath = authKeyPath") {
		t.Fatal("identity override must not erase the key path that anchors known_hosts")
	}
	if !strings.Contains(installBlock, "sshBase(c, !interactivePassword, false, authKeyPath)") {
		t.Fatal("public-key installation must retain the canonical connection for known_hosts")
	}
}

func TestValidateHandoffRejectsSSHNoise(t *testing.T) {
	for _, input := range []string{
		"Connection to example.invalid closed.\r\n",
		handoffBegin + "\n\n" + handoffEnd + "\nConnection to example.invalid closed.\n",
		handoffBegin + "\nHANDOFF_RUN_STARTED=now\n" + handoffEnd,
	} {
		if _, err := validateHandoff(input); err == nil {
			t.Fatalf("expected handoff rejection for %q", input)
		}
	}
}

func TestValidateHandoffAcceptsMarkedCredentialData(t *testing.T) {
	input := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=2026-08-16T00:00:00Z",
		"PANEL_PORT=27654",
		"PANEL_PASSWORD=a-real-value",
		handoffEnd,
	}, "\n")
	payload, err := validateHandoff(input)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(payload, "Connection to") {
		t.Fatal("SSH noise leaked into handoff")
	}
}

func TestParsePanelMetadata(t *testing.T) {
	input := panelBegin + "\nPANEL_PORT=27654\nWEB_BASE_PATH=random/path\nPANEL_METADATA_SOURCE=x-ui-setting\n" + panelEnd
	meta, err := parsePanelMetadata(input)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Port != 27654 || meta.Path != "/random/path/" || meta.Source != "x-ui-setting" {
		t.Fatalf("unexpected metadata: %#v", meta)
	}
}

func TestParsePanelMetadataRejectsEmptyPort(t *testing.T) {
	input := panelBegin + "\nPANEL_PORT=\nWEB_BASE_PATH=/abc/\n" + panelEnd
	if _, err := parsePanelMetadata(input); err == nil {
		t.Fatal("expected empty panel port to be rejected")
	}
}

func TestFailureBranchStopsFollowOnActions(t *testing.T) {
	if shouldContinueAfterWizard(23) {
		t.Fatal("non-zero wizard exit must stop handoff/panel follow-on actions")
	}
	if !shouldContinueAfterWizard(0) {
		t.Fatal("successful wizard should allow follow-on actions")
	}
}

func TestRunCapturedSeparatesStdoutAndStderr(t *testing.T) {
	if os.Getenv("PNA_TEST_HELPER") == "1" {
		fmt.Fprint(os.Stdout, handoffBegin+"\nHANDOFF_RUN_STARTED=now\nPANEL_PORT=12345\n"+handoffEnd+"\n")
		fmt.Fprintln(os.Stderr, "Connection to example.invalid closed.")
		os.Exit(0)
	}
	if err := os.Setenv("PNA_TEST_HELPER", "1"); err != nil {
		t.Fatal(err)
	}
	defer os.Unsetenv("PNA_TEST_HELPER")
	result := runCaptured(os.Args[0], []string{"-test.run=TestRunCapturedSeparatesStdoutAndStderr"}, nil, false)
	if result.ExitCode != 0 {
		t.Fatalf("helper failed: %#v", result)
	}
	if strings.Contains(result.Stdout, "Connection to") {
		t.Fatal("stderr was mixed into stdout")
	}
	if !strings.Contains(result.Stderr, "Connection to") {
		t.Fatal("expected SSH close notice to remain isolated in stderr")
	}
}

func TestRunCapturedNonzeroExit(t *testing.T) {
	if os.Getenv("PNA_TEST_FAIL_HELPER") == "1" {
		fmt.Fprintln(os.Stdout, "partial business output")
		fmt.Fprintln(os.Stderr, "remote failure")
		os.Exit(17)
	}
	if err := os.Setenv("PNA_TEST_FAIL_HELPER", "1"); err != nil {
		t.Fatal(err)
	}
	defer os.Unsetenv("PNA_TEST_FAIL_HELPER")
	result := runCaptured(os.Args[0], []string{"-test.run=TestRunCapturedNonzeroExit"}, nil, false)
	if result.ExitCode != 17 || result.Err == nil {
		t.Fatalf("expected exit 17, got %#v", result)
	}
	if !strings.Contains(result.Stdout, "partial business output") || !strings.Contains(result.Stderr, "remote failure") {
		t.Fatalf("streams were not preserved separately: %#v", result)
	}
}

func TestProcessFailureDetailFallsBackToStdout(t *testing.T) {
	result := ProcessResult{
		Stdout:   `{"fatal":"jq missing"}`,
		Stderr:   "Connection to example.invalid closed.\n",
		ExitCode: 1,
		Err:      fmt.Errorf("exit status 1"),
	}
	detail := processFailureDetail(result)
	if !strings.Contains(detail, "jq missing") {
		t.Fatalf("stdout reason was lost: %q", detail)
	}
	if strings.Contains(detail, "Connection to") {
		t.Fatalf("SSH close noise leaked into failure detail: %q", detail)
	}
}

func TestParseDiagnosticProtocolWithoutJSONDependency(t *testing.T) {
	input := strings.Join([]string{
		diagBegin,
		"PASS\tSSH\tSSH 正常\tSSH is healthy",
		"ISSUE\tNGINX_DOWN\tERROR\tSTART_NGINX\ttrue\tNginx 未运行\tNginx is down",
		diagEnd,
	}, "\n")
	result, err := parseDiagnosticProtocol(input)
	if err != nil {
		t.Fatal(err)
	}
	if result.OK || len(result.Passes) != 1 || len(result.Issues) != 1 || !result.Issues[0].AutoRepair {
		t.Fatalf("unexpected diagnosis: %#v", result)
	}
}

func TestParseDiagnosticProtocolRejectsPartialOutput(t *testing.T) {
	for _, input := range []string{
		`{"fatal":"jq missing"}`,
		diagBegin + "\nISSUE\tBAD\tUNKNOWN\tNONE\tfalse\t坏\tbad\n" + diagEnd,
		diagBegin + "\n" + diagEnd,
	} {
		if _, err := parseDiagnosticProtocol(input); err == nil {
			t.Fatalf("expected protocol rejection for %q", input)
		}
	}
}

func TestOnlyDeployActionUploadsToolkit(t *testing.T) {
	source, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	// Both upload call sites belong to menu [1]: the normal reviewed install
	// path and the bounded same-version package refresh.  Keep this guard
	// function-aware so a future action cannot silently gain an upload side
	// effect while still allowing the two intentional menu-[1] branches.
	deployStart := strings.Index(text, "func (a *App) deployOptimize() error {")
	uninstallStart := strings.Index(text, "func (a *App) uninstallRemoteToolkit() error {")
	if deployStart < 0 || uninstallStart <= deployStart {
		t.Fatal("could not locate menu [1] operation boundaries")
	}
	deployText := text[deployStart:uninstallStart]
	if calls := strings.Count(deployText, "a.uploadToolkit(c)"); calls != 2 {
		t.Fatalf("menu [1] must retain exactly two upload branches, found %d", calls)
	}
	if outside := strings.Count(text[:deployStart], "a.uploadToolkit(c)") + strings.Count(text[uninstallStart:], "a.uploadToolkit(c)"); outside != 0 {
		t.Fatalf("toolkit upload leaked outside menu [1], found %d call(s)", outside)
	}
}

func TestToolkitVersionComparisonIsNumeric(t *testing.T) {
	tests := []struct {
		left  string
		right string
		want  int
	}{
		{"0.8.3", "0.8.3", 0},
		{"v0.8.3", "0.8.3.0", 0},
		{"0.6.4", "0.8.3", -1},
		{"0.6.10", "0.8.3", -1},
		{"0.8.4", "0.8.3", 1},
		{"0.7", "0.8.3", -1},
	}
	for _, test := range tests {
		got, err := compareToolkitVersions(test.left, test.right)
		if err != nil {
			t.Fatalf("compare %s to %s: %v", test.left, test.right, err)
		}
		if got != test.want {
			t.Fatalf("compare %s to %s: got %d, want %d", test.left, test.right, got, test.want)
		}
	}
	for _, invalid := range []string{"", "0", "0.6.x", "0.8.3-beta", "0.8.3.1.2"} {
		if _, err := compareToolkitVersions(invalid, toolkitVersion); err == nil {
			t.Fatalf("invalid version %q was accepted", invalid)
		}
	}
}

func TestToolkitClassificationCoversInstallAndNoDowngrade(t *testing.T) {
	tests := []struct {
		probe ToolkitProbe
		want  ToolkitRelation
	}{
		{ToolkitProbe{}, ToolkitMissing},
		{ToolkitProbe{Present: true, Version: "0.6.4", Complete: true}, ToolkitOlder},
		{ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "different-build", Complete: true}, ToolkitSameComplete},
		{ToolkitProbe{Present: true, Version: toolkitVersion, Complete: false}, ToolkitSameIncomplete},
		{ToolkitProbe{Present: true, Version: "1.0.1", Complete: true}, ToolkitNewer},
	}
	for _, test := range tests {
		got, err := classifyToolkit(test.probe, toolkitVersion)
		if err != nil {
			t.Fatal(err)
		}
		if got != test.want {
			t.Fatalf("probe %#v classified as %q, want %q", test.probe, got, test.want)
		}
	}
}

func TestParseToolkitProbeUsesMarkedValidatedData(t *testing.T) {
	input := strings.Join([]string{
		toolkitBegin,
		"TOOLKIT_PRESENT=1",
		"TOOLKIT_VERSION=0.8.3",
		"TOOLKIT_BUILD_ID=different-build",
		"TOOLKIT_BUILD_REVISION=2",
		"TOOLKIT_COMPLETE=1",
		toolkitEnd,
	}, "\n")
	probe, err := parseToolkitProbe(input)
	if err != nil {
		t.Fatal(err)
	}
	if !probe.Present || !probe.Complete || probe.Version != "0.8.3" || probe.BuildID != "different-build" || probe.BuildRevision != 2 {
		t.Fatalf("unexpected probe: %#v", probe)
	}
	for _, invalid := range []string{
		"TOOLKIT_PRESENT=1\nTOOLKIT_VERSION=0.8.3",
		toolkitBegin + "\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=garbage\nTOOLKIT_COMPLETE=1\n" + toolkitEnd,
		toolkitBegin + "\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=0.8.3\nTOOLKIT_COMPLETE=maybe\n" + toolkitEnd,
		toolkitBegin + "\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=0.8.3\nTOOLKIT_BUILD_REVISION=-1\nTOOLKIT_COMPLETE=1\n" + toolkitEnd,
	} {
		if _, err := parseToolkitProbe(invalid); err == nil {
			t.Fatalf("invalid toolkit probe was accepted: %q", invalid)
		}
	}
}

func TestSameVersionBuildRevisionUpdatesOnlyWhenOlder(t *testing.T) {
	for _, test := range []struct {
		probe ToolkitProbe
		want  int
	}{
		{ToolkitProbe{BuildID: toolkitBuildID, BuildRevision: toolkitBuildRevision}, 0},
		{ToolkitProbe{BuildID: "legacy-build", BuildRevision: 0}, -1},
		{ToolkitProbe{BuildID: "older-build", BuildRevision: toolkitBuildRevision - 1}, -1},
		{ToolkitProbe{BuildID: "newer-build", BuildRevision: toolkitBuildRevision + 1}, 1},
	} {
		if got := compareToolkitBuild(test.probe, toolkitBuildID, toolkitBuildRevision); got != test.want {
			t.Fatalf("build probe %#v comparison=%d want=%d", test.probe, got, test.want)
		}
	}
	source, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	sameStart := strings.Index(text, "case ToolkitSameComplete:")
	if sameStart < 0 {
		t.Fatal("same-version control-flow branch is missing")
	}
	incompleteStart := strings.Index(text[sameStart:], "case ToolkitSameIncomplete:")
	if incompleteStart < 0 {
		t.Fatal("same-version control-flow branches are missing")
	}
	sameBlock := text[sameStart : sameStart+incompleteStart]
	for _, required := range []string{"updateSameVersionBuild = true", "禁止重复安装", "远端同版本构建比当前 EXE 新"} {
		if !strings.Contains(sameBlock, required) {
			t.Fatalf("same-version build control is missing %q", required)
		}
	}
}

func TestSameVersionToolkitOnlyUpdateGuard(t *testing.T) {
	tests := []struct {
		name  string
		probe ToolkitProbe
		want  bool
	}{
		{
			name:  "complete older revision",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "old-build", BuildRevision: toolkitBuildRevision - 1, Complete: true},
			want:  true,
		},
		{
			name:  "complete current build",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: toolkitBuildID, BuildRevision: toolkitBuildRevision, Complete: true},
			want:  false,
		},
		{
			name:  "complete newer revision",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "future-build", BuildRevision: toolkitBuildRevision + 1, Complete: true},
			want:  false,
		},
		{
			name:  "incomplete allowed repair",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildRevision: toolkitBuildRevision, Complete: false},
			want:  true,
		},
		{
			name:  "legacy version stays on migration path",
			probe: ToolkitProbe{Present: true, Version: "0.9.5", BuildRevision: toolkitBuildRevision - 1, Complete: true},
			want:  false,
		},
		{
			name:  "missing toolkit",
			probe: ToolkitProbe{},
			want:  false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := sameVersionToolkitOnlyUpdateRequired(test.probe); got != test.want {
				t.Fatalf("toolkit-only guard for %#v = %v, want %v", test.probe, got, test.want)
			}
		})
	}
}

func TestSameVersionIncompleteRepairAllowsOnlyInterruptedOrOlderBuilds(t *testing.T) {
	tests := []struct {
		name  string
		probe ToolkitProbe
		want  bool
	}{
		{
			name:  "missing revision from interrupted upload",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, Complete: false},
			want:  true,
		},
		{
			name:  "older revision",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "old-build", BuildRevision: toolkitBuildRevision - 1, Complete: false},
			want:  true,
		},
		{
			name:  "current revision and id",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: toolkitBuildID, BuildRevision: toolkitBuildRevision, Complete: false},
			want:  true,
		},
		{
			name:  "current revision with missing id",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildRevision: toolkitBuildRevision, Complete: false},
			want:  true,
		},
		{
			name:  "newer revision",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "future-build", BuildRevision: toolkitBuildRevision + 1, Complete: false},
			want:  false,
		},
		{
			name:  "different current build",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: "different-build", BuildRevision: toolkitBuildRevision, Complete: false},
			want:  false,
		},
		{
			name:  "complete toolkit",
			probe: ToolkitProbe{Present: true, Version: toolkitVersion, BuildID: toolkitBuildID, BuildRevision: toolkitBuildRevision, Complete: true},
			want:  false,
		},
		{
			name:  "different version",
			probe: ToolkitProbe{Present: true, Version: "0.9.5", Complete: false},
			want:  false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := sameVersionIncompleteRepairAllowed(test.probe); got != test.want {
				t.Fatalf("repair policy for %#v = %v, want %v", test.probe, got, test.want)
			}
		})
	}
}

func TestDeployActionRepairsSameVersionIncompleteAfterApply(t *testing.T) {
	source, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"repairSameVersionToolkit := false",
		"repairSameVersionToolkit = true",
		"|| repairSameVersionToolkit",
		"菜单 [1] 在 APPLY 确认后将原位修复",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("menu [1] same-version repair guard is missing %q", required)
		}
	}
	confirm := strings.Index(text, "if err := a.confirmInstallPlan(plan); err != nil")
	upload := strings.Index(text, "if relation == ToolkitOlder || relation == ToolkitMissing || updateSameVersionBuild || repairSameVersionToolkit")
	if confirm < 0 || upload < 0 || upload < confirm {
		t.Fatal("same-version repair must upload only after the APPLY confirmation")
	}
}

func TestDeployActionUsesBoundedToolkitOnlyPathForSameVersionRefresh(t *testing.T) {
	source, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"toolkitOnlyUpdate := false",
		"toolkitOnlyUpdate = true",
		"TOOLKIT_ONLY_UPDATE_REQUIRED",
		"TOOLKIT_ONLY_UPDATE_CONFIRMED",
		"TOOLKIT_ONLY_UPDATE_COMPLETE",
		"return a.updateToolkitOnly(c, toolkitOnlyReason)",
		"a.recoverInterruptedInstallTransaction(c)",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("bounded same-version toolkit refresh is missing %q", required)
		}
	}
	branch := strings.Index(text, "if toolkitOnlyUpdate {")
	fullPlan := strings.Index(text, "plan, err := a.collectInstallPlan(existingNode, existingSSPort)")
	if branch < 0 || fullPlan < 0 || branch >= fullPlan {
		t.Fatal("same-version toolkit refresh must branch before collecting route or credential settings")
	}
	existingNode := strings.Index(text, "existingNode, err := a.existingNodeInstalled(c)")
	if existingNode < 0 || existingNode <= branch {
		t.Fatal("could not locate the full-path node inspection after the bounded branch")
	}

	// Inspect the helper itself rather than the entire remainder of deployOptimize;
	// the full path necessarily performs node inspection after the bounded branch.
	helperStart := strings.Index(text, "func (a *App) updateToolkitOnly(c Connection, reason string) error {")
	helperEnd := strings.Index(text, "func (a *App) uninstallRemoteToolkit() error {")
	if helperStart < 0 || helperEnd <= helperStart {
		t.Fatal("could not locate bounded toolkit-only helper")
	}
	helper := text[helperStart:helperEnd]
	for _, forbidden := range []string{
		"collectInstallPlan(",
		"existingNodeInstalled(",
		"xui_password_login_works",
		"00-auto-install-or-optimize.sh",
	} {
		if strings.Contains(helper, forbidden) {
			t.Fatalf("toolkit-only helper must not invoke full-plan operation %q", forbidden)
		}
	}
	prompt := strings.Index(helper, "confirmation := a.prompt(")
	recover := strings.Index(helper, "a.recoverInterruptedInstallTransaction(c)")
	upload := strings.Index(helper, "a.uploadToolkit(c)")
	verify := strings.Index(helper, "a.remoteToolkitProbe(c)")
	if prompt < 0 || recover < prompt || upload < recover || verify < upload {
		t.Fatal("toolkit-only helper must confirm APPLY before recovery, upload, and verification")
	}
}

func TestRemoteGUIConfirmationUsesFramedLineAndStripsANSI(t *testing.T) {
	runbook, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"lib-gui-prompt.sh", "proxy_runbook_read_answer", "EXISTING_${REALITY_SHADOW_PORT}_SHADOW_REUSED", "show-shadow \"$REALITY_SHADOW_PORT\"", "human_yesq"} {
		if !strings.Contains(string(runbook), required) {
			t.Fatalf("remote GUI confirmation/resume contract is missing %q", required)
		}
	}
	realityAPI, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"TEST_PORT|PORT", "REALITY_SHADOW_REUSABLE", "get_by_port"} {
		if !strings.Contains(string(realityAPI), required) {
			t.Fatalf("interrupted shadow resume compatibility is missing %q", required)
		}
	}
	library, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/lib-gui-prompt.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"PNA_GUI_PROMPT_B64=", "PROXY_RUNBOOK_GUI_MODE", ">&2", "IFS= read -r answer"} {
		if !strings.Contains(string(library), required) {
			t.Fatalf("remote GUI prompt library is missing %q", required)
		}
	}
	gui, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"StripAnsi", `"\\x1B\\[[0-?]*[ -/]*[@-~]"`, "StripAnsi(chunk.Replace"} {
		if !strings.Contains(string(gui), required) {
			t.Fatalf("GUI ANSI cleanup is missing %q", required)
		}
	}
}

func TestMenuMarksOneAsOnlyInstallerAndDispatchesUninstall(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"[1] 【唯一安装入口】",
		"[1] [ONLY INSTALL ENTRY]",
		"[13] 卸载远端内嵌包",
		"[13] Uninstall the remote embedded toolkit",
		`case "13":`,
		"runRemoteAction(a.uninstallRemoteToolkit)",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("menu/dispatch is missing %q", required)
		}
	}
}

func TestToolkitUninstallCommandIsScopedAndFailClosed(t *testing.T) {
	command := toolkitUninstallCommand()
	for _, required := range []string{
		"PROXY_RUNBOOK_UNINSTALL_BEGIN",
		"PROXY_RUNBOOK_UNINSTALL_END",
		"REFUSED_UNMANAGED_CURRENT",
		"REFUSED_UNMANAGED_LAUNCHER",
		"/opt/proxy-runbook-current",
		"/usr/local/sbin/proxy-node",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("uninstall command is missing safety element %q", required)
		}
	}
	for _, path := range append(append([]string{}, managedToolkitDirs...), managedToolkitArchives...) {
		if !strings.Contains(command, path) {
			t.Fatalf("managed toolkit path is missing from uninstall command: %s", path)
		}
	}
	for _, forbidden := range []string{
		"rm -rf /opt",
		"rm -rf -- /opt",
		"/etc/proxy-runbook",
		"/root/.config/proxy-runbook",
		"/etc/x-ui",
		"/etc/nginx",
		"/etc/letsencrypt",
		"systemctl stop",
		"systemctl disable",
	} {
		if strings.Contains(command, forbidden) {
			t.Fatalf("uninstall command reaches outside toolkit scope: %q", forbidden)
		}
	}
}

func TestFullDismantleIsExplicitRescueFirstAndPreservesSSH(t *testing.T) {
	mainSource, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"[18] 全量拆除本工具施工并恢复原始基线",
		"[18] Fully dismantle managed construction and restore the original baseline",
		`case "18":`,
		"runRemoteAction(a.dismantleManagedNode)",
	} {
		if !strings.Contains(string(mainSource), required) {
			t.Fatalf("full dismantle menu/dispatch is missing %q", required)
		}
	}
	operationSource, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"downloadDismantleRescue",
		`exec.Command(managedCommandPath("ssh.exe")`,
		"RESTORE ORIGINAL",
		"LEGACY FULL RESTORE",
		"fileSHA256",
		"PNA_POST_DISMANTLE_VERIFY_OK",
	} {
		if !strings.Contains(string(operationSource), required) {
			t.Fatalf("rescue-first dismantle operation is missing %q", required)
		}
	}
	script, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/22-dismantle-managed-node.sh")
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, required := range []string{
		"--capture-baseline",
		"BASELINE_MODE=EXACT",
		"BASELINE_MODE=LEGACY_UNCERTAIN",
		"PNA_DISMANTLE_PLAN_BEGIN",
		"PNA_DISMANTLE_CONFIRM",
		"SSH_ACCESS_PRESERVED=1",
		"PRESERVED_SHARED_BASE_PACKAGES=1",
		"LEGACY_MANAGED_LISTENERS_ABSENT=1",
		"PNA_DISMANTLE_END",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("dismantle safety contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"authorized_keys",
		"/etc/ssh",
		"apt-get autoremove",
		"ufw --force reset",
		"rm -rf -- /opt ",
		"rm -rf -- /root ",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("dismantle script contains forbidden broad/destructive behavior %q", forbidden)
		}
	}
	auto, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(auto), "22-dismantle-managed-node.sh\" --capture-baseline") {
		t.Fatal("the install workflow does not capture the original baseline before convergence")
	}
	gui, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(gui), `Op("18", "security"`) {
		t.Fatal("the fully graphical client is missing operation 18")
	}
}

func TestPostInstallCleanupPreservesCurrentToolkit(t *testing.T) {
	command := toolkitPostInstallCleanupCommand()
	if strings.Contains(command, "obsolete_dirs=( "+shQuote(toolkitInstallDir)) {
		t.Fatal("current toolkit must not be listed as obsolete")
	}
	for _, path := range managedToolkitDirs {
		if path == toolkitInstallDir {
			continue
		}
		if !strings.Contains(command, path) {
			t.Fatalf("old toolkit directory is not cleaned after install: %s", path)
		}
	}
	if !strings.Contains(command, "TOOLKIT_POST_INSTALL_CLEANUP_OK") {
		t.Fatal("post-install cleanup completion marker is missing")
	}
}

func TestManagedToolkitHistoryIncludesImmediatePredecessors(t *testing.T) {
	dirs := strings.Join(managedToolkitDirs, "\n")
	archives := strings.Join(managedToolkitArchives, "\n")
	for _, oldVersion := range []string{"v0.6.7", "v0.6.8", "v0.6.9", "v0.7.0", "v0.7.1", "v0.7.2", "v0.7.3"} {
		if !strings.Contains(dirs, oldVersion) || !strings.Contains(archives, oldVersion) {
			t.Fatalf("upgrade/uninstall history lost immediate predecessor %s", oldVersion)
		}
	}
	buildID, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_ID")
	if err != nil {
		t.Fatal(err)
	}
	if string(buildID) != toolkitBuildID+"\n" {
		t.Fatalf("EXE and embedded runbook build IDs differ or are not one LF-terminated line: %q vs %q", toolkitBuildID, string(buildID))
	}
	revision, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/TOOLKIT_BUILD_REVISION")
	if err != nil {
		t.Fatal(err)
	}
	if string(revision) != strconv.Itoa(toolkitBuildRevision)+"\n" {
		t.Fatalf("EXE and embedded runbook build revisions differ: %d vs %q", toolkitBuildRevision, string(revision))
	}
	version, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/TOOLKIT_VERSION")
	if err != nil {
		t.Fatal(err)
	}
	if string(version) != toolkitVersion+"\n" {
		t.Fatalf("EXE and embedded runbook versions differ or are not one LF-terminated line: %q vs %q", toolkitVersion, string(version))
	}
}

func TestGeneratedToolkitCommandsHaveValidBashSyntax(t *testing.T) {
	bash, err := exec.LookPath("bash.exe")
	if err != nil {
		bash, err = exec.LookPath("bash")
	}
	if err != nil {
		t.Skip("bash is not available for generated-command syntax validation")
	}
	commands := map[string]string{
		"uninstall":             toolkitUninstallCommand(),
		"post-install-cleanup":  toolkitPostInstallCleanupCommand(),
		"temporary-key-removal": temporaryAuthorizedKeyRemovalCommand("ssh-ed25519 AAAATEST temporary-session"),
		"managed-key-removal":   authorizedKeyRemovalCommand("ssh-ed25519 AAAATEST managed-binding", "MANAGED_SSH_KEY_REMOVED"),
	}
	for name, script := range commands {
		command := exec.Command(bash, "-n")
		command.Stdin = strings.NewReader(script)
		if output, runErr := command.CombinedOutput(); runErr != nil {
			t.Fatalf("%s command is not valid Bash: %v: %s", name, runErr, strings.TrimSpace(string(output)))
		}
	}
}

func TestRunbookAvoidsKnownInitializationSIGPIPE(t *testing.T) {
	path := "runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh"
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, forbidden := range []string{"awk '$1==\"port\"{print $2; exit}'", "| head -1", "| head -n1"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("known pipefail/SIGPIPE pattern remains: %s", forbidden)
		}
	}
}

func TestCertificateIssuanceRequiresPublicACMEPreflight(t *testing.T) {
	path := "runbook/proxy-node-assistant-v1.0.0/linux/05-cover-bootstrap.sh"
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"umask 022", "install -d -m 755", "auth_basic off", "allow all", "PUBLIC_ACME_HTTP_PREFLIGHT",
		"PUBLIC_ACME_HTTP_PREFLIGHT_OK", "--noproxy '*'", "PROXY_RUNBOOK_ACME_PUBLIC_PREFLIGHT_FAILURE",
		"for attempt in $(seq 1 40)", "for attempt in $(seq 1 10)", "-H 'Connection: close'",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("ACME public preflight is missing %q", required)
		}
	}
	preflight := strings.Index(text, "PUBLIC_ACME_HTTP_PREFLIGHT_OK")
	certbot := strings.Index(text, "certbot certonly")
	if preflight < 0 || certbot <= preflight {
		t.Fatal("Certbot may run before the public random-challenge preflight succeeds")
	}
	probeWrite := strings.Index(text, `printf '%s\n' "$PROBE_VALUE" > "$PROBE_PATH"`)
	reload := strings.Index(text, "systemctl reload nginx")
	localRetry := strings.Index(text, "for attempt in $(seq 1 40)")
	if probeWrite < 0 || reload <= probeWrite || localRetry <= reload {
		t.Fatal("ACME probe must exist before nginx reload and be retried after reload")
	}
	diagnosis, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/16-auto-diagnose.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"COVER_HTTP_FORBIDDEN", "--write-out '%{http_code}'", "REBUILD_COVER false"} {
		if !strings.Contains(string(diagnosis), required) {
			t.Fatalf("public HTTP diagnosis is missing %q", required)
		}
	}
}

func TestWARPInstallerRefreshesRotatedKeyBeforeRepositoryUpdate(t *testing.T) {
	path := "runbook/proxy-node-assistant-v1.0.0/linux/06-warp-install.sh"
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		"pkg.cloudflareclient.com/pubkey.gpg",
		"CLOUDFLARE_WARP_KEYRING_REFRESHED",
		".proxy-runbook-disabled",
		"install -o root -g root -m 644",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("WARP signing-key refresh is missing %q", required)
		}
	}
	keyRefresh := strings.Index(text, "CLOUDFLARE_WARP_KEYRING_REFRESHED")
	finalUpdate := strings.LastIndex(text, "apt-get update")
	if keyRefresh < 0 || finalUpdate <= keyRefresh {
		t.Fatal("Cloudflare repository update may run before the rotated signing key is installed")
	}
}

func TestRealityUUIDParsingAcceptsStringOrObjectAndRejectsJSONBlob(t *testing.T) {
	library, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh")
	if err != nil {
		t.Fatal(err)
	}
	text := string(library)
	for _, required := range []string{"xui_new_uuid", `(.obj | type) == "string"`, `(.obj | type) == "object"`, ".obj.uuid", "invalid UUID shape"} {
		if !strings.Contains(text, required) {
			t.Fatalf("3x-ui UUID compatibility parser is missing %q", required)
		}
	}
	for _, path := range []string{
		"runbook/proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh",
		"runbook/proxy-node-assistant-v1.0.0/linux/04d-optimize-existing-reality-shadow.sh",
	} {
		source, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatal(readErr)
		}
		if !strings.Contains(string(source), "xui_new_uuid") {
			t.Fatalf("%s bypasses the strict UUID compatibility parser", path)
		}
	}
}

func TestToolkitManifestIsLinuxCompatibleAndMatchesFiles(t *testing.T) {
	root := "runbook/proxy-node-assistant-v1.0.0"
	manifestPath := filepath.Join(root, "SHA256SUMS.txt")
	manifest, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(manifest, []byte{'\r'}) {
		t.Fatal("toolkit SHA256SUMS.txt uses CRLF; sha256sum -c on Linux will treat carriage returns as part of file names")
	}
	scanner := bufio.NewScanner(bytes.NewReader(manifest))
	count := 0
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), "  ", 2)
		if len(parts) != 2 || len(parts[0]) != 64 || parts[1] == "" {
			t.Fatalf("invalid SHA256 manifest line %q", scanner.Text())
		}
		content, readErr := os.ReadFile(filepath.Join(root, filepath.FromSlash(parts[1])))
		if readErr != nil {
			t.Fatalf("manifest entry %q cannot be read: %v", parts[1], readErr)
		}
		actual := fmt.Sprintf("%x", sha256.Sum256(content))
		if actual != parts[0] {
			t.Fatalf("manifest hash mismatch for %s: got %s want %s", parts[1], actual, parts[0])
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("toolkit SHA256 manifest is empty")
	}
}

func TestXUIAPITokenGenerationIsLastResortOnly(t *testing.T) {
	libraryPath := "runbook/proxy-node-assistant-v1.0.0/linux/lib-xui-api.sh"
	source, err := os.ReadFile(libraryPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	if count := strings.Count(text, "setting -getApiToken"); count != 1 {
		t.Fatalf("3x-ui token generation must have exactly one controlled call site, got %d", count)
	}
	for _, required := range []string{
		"xui_token_works",
		"XUI_API_TOKEN_SOURCE",
		"XUI_API_TOKEN",
		"PANEL_API_TOKEN",
		"XUI_API_TOKEN=", // install-result fallback
		"xui_store_token",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("x-ui API context is missing %q", required)
		}
	}

	for _, path := range []string{
		"runbook/proxy-node-assistant-v1.0.0/linux/03c-rotate-panel-credentials.sh",
		"runbook/proxy-node-assistant-v1.0.0/linux/03d-export-panel-handoff.sh",
	} {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatal(readErr)
		}
		body := string(data)
		if strings.Contains(body, "setting -getApiToken") {
			t.Fatalf("%s must not generate a token directly", path)
		}
		if !strings.Contains(body, "xui_api_context") {
			t.Fatalf("%s must use the shared validated API context", path)
		}
	}
}

func TestWarpRouteHasNoOpBeforeBackupAndUpdate(t *testing.T) {
	path := "runbook/proxy-node-assistant-v1.0.0/linux/07a-apply-warp-route-local.sh"
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	marker := strings.Index(text, "XRAY_WARP_ROUTE_ALREADY_OPTIMAL")
	backup := strings.Index(text, "xray-template-before-warp")
	update := strings.Index(text, "/panel/api/xray/update")
	if marker < 0 || backup < 0 || update < 0 {
		t.Fatal("WARP route no-op, backup, or update marker is missing")
	}
	if marker > backup || marker > update {
		t.Fatal("WARP route no-op must run before backup and API update")
	}
	for _, required := range []string{
		`.tag == "warp-masque"`,
		`.protocol == "socks"`,
		`.settings.address == "127.0.0.1"`,
		`.settings.port == $port`,
		`.ruleTag == "openai-via-warp"`,
		`.outboundTag == "warp-masque"`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("WARP route no-op is missing %q", required)
		}
	}
}

func TestRealitySubscriptionShareAddressCannotFallBackToLocalhost(t *testing.T) {
	paths := []string{
		"runbook/proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh",
		"runbook/proxy-node-assistant-v1.0.0/linux/04d-optimize-existing-reality-shadow.sh",
	}
	for _, path := range paths {
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		text := string(source)
		for _, required := range []string{`shareAddrStrategy`, `"custom"`, `shareAddr`} {
			if !strings.Contains(text, required) {
				t.Fatalf("%s is missing subscription share-address contract %q", path, required)
			}
		}
	}
	apiSource, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/04a-reality-api.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"REALITY_443_SHARE_ADDRESS_DRIFT", "normalize-share", "REALITY_443_SHARE_ADDRESS_NORMALIZED"} {
		if !strings.Contains(string(apiSource), required) {
			t.Fatalf("Reality API script is missing %q", required)
		}
	}
}

func TestSubscriptionServiceUsesLocalListenerAndCoverTLSProxy(t *testing.T) {
	backend, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/05c-optimize-cover-backend.sh")
	if err != nil {
		t.Fatal(err)
	}
	configure, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/05d-configure-subscription.sh")
	if err != nil {
		t.Fatal(err)
	}
	diagnosis, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/16-auto-diagnose.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"location ^~ /sub/", "proxy_pass http://127.0.0.1:2096;", "X-Forwarded-Proto https"} {
		if !strings.Contains(string(backend), required) {
			t.Fatalf("cover backend is missing %q", required)
		}
	}
	for _, required := range []string{`.subListen="127.0.0.1"`, `.subURI=$uri`, "SUBSCRIPTION_PROXY_OPTIMAL"} {
		if !strings.Contains(string(configure), required) {
			t.Fatalf("subscription convergence is missing %q", required)
		}
	}
	for _, required := range []string{"REALITY_SHARE_ADDRESS_BAD", "SUBSCRIPTION_PUBLIC_BAD", "NORMALIZE_SUBSCRIPTION"} {
		if !strings.Contains(string(diagnosis), required) {
			t.Fatalf("subscription diagnosis is missing %q", required)
		}
	}
}

func TestCoverTemplateChoiceNormalization(t *testing.T) {
	tests := map[string]string{
		"": "random", "R": "random", "random": "random",
		"A": "auto", "stable": "auto", "01": "1", "15": "15",
	}
	for input, want := range tests {
		got, ok := normalizeCoverTemplateChoice(input)
		if !ok || got != want {
			t.Fatalf("normalizeCoverTemplateChoice(%q) = %q, %v; want %q, true", input, got, ok, want)
		}
	}
	for _, invalid := range []string{"0", "16", "-1", "one", "1;touch /tmp/bad"} {
		if got, ok := normalizeCoverTemplateChoice(invalid); ok {
			t.Fatalf("invalid cover selector %q was accepted as %q", invalid, got)
		}
	}
}

func TestCoverTemplateLibraryHasFifteenDistinctLocalFullPages(t *testing.T) {
	root := "runbook/proxy-node-assistant-v1.0.0/templates/cover-sites"
	manifestData, err := os.ReadFile(filepath.Join(root, "MANIFEST.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(manifestData)), "\n")
	if len(lines) != 15 {
		t.Fatalf("cover template manifest has %d entries, want 15", len(lines))
	}
	files, err := filepath.Glob(filepath.Join(root, "*.html"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 15 {
		t.Fatalf("cover template library has %d HTML files, want 15", len(files))
	}
	seenHashes := map[[sha256.Size]byte]string{}
	for index, line := range lines {
		fields := strings.Split(strings.TrimSuffix(line, "\r"), "\t")
		if len(fields) != 4 {
			t.Fatalf("manifest line %d is malformed: %q", index+1, line)
		}
		id, err := strconv.Atoi(fields[0])
		if err != nil || id != index+1 {
			t.Fatalf("manifest line %d has non-sequential ID %q", index+1, fields[0])
		}
		path := filepath.Join(root, fields[3])
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("manifest template %d cannot be read: %v", id, err)
		}
		text := string(body)
		if len(body) < 2500 {
			t.Fatalf("template %d is too short to be a full page: %d bytes", id, len(body))
		}
		for _, required := range []string{"proxy-runbook-cover-library-v2", "name=\"viewport\"", "{{DOMAIN}}", "{{YEAR}}", "{{UPDATED}}", "@media"} {
			if !strings.Contains(text, required) {
				t.Fatalf("template %d is missing %q", id, required)
			}
		}
		lower := strings.ToLower(text)
		for _, forbidden := range []string{"src=\"http://", "src=\"https://", "href=\"http://", "href=\"https://", "url(http://", "url(https://"} {
			if strings.Contains(lower, forbidden) {
				t.Fatalf("template %d depends on an external resource: %q", id, forbidden)
			}
		}
		hash := sha256.Sum256(body)
		if previous, exists := seenHashes[hash]; exists {
			t.Fatalf("templates are byte-identical: %s and %s", previous, path)
		}
		seenHashes[hash] = path
	}
}

func TestSignalRunnerIsAnOriginalLocalInteractiveTemplate(t *testing.T) {
	body, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/templates/cover-sites/15-signal-runner.html")
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, required := range []string{"<canvas", "requestAnimationFrame", "pointerdown", "localStorage", "SPACE / ↑ / TAP", "No Google artwork"} {
		if !strings.Contains(text, required) {
			t.Fatalf("Signal Runner is missing %q", required)
		}
	}
}

func TestCoverTemplateSelectionIsWiredThroughDeployAndMaintenance(t *testing.T) {
	installer, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/05b-cover-site-polished.sh")
	if err != nil {
		t.Fatal(err)
	}
	installerText := string(installer)
	for _, required := range []string{"COVER_TEMPLATE_LIBRARY_V2 count=%s", "r|random", "a|auto|stable", "template_id=", "TEMPLATE_ID % TOTAL + 1", "templates/cover-sites"} {
		if !strings.Contains(installerText, required) {
			t.Fatalf("cover installer is missing %q", required)
		}
	}
	auto, err := os.ReadFile("runbook/proxy-node-assistant-v1.0.0/linux/00-auto-install-or-optimize.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(auto), "PROXY_RUNBOOK_COVER_TEMPLATE") || strings.Count(string(auto), "COVER_TEMPLATE_CHOICE") < 5 {
		t.Fatal("adaptive deployment does not propagate the selected cover template through every managed-site branch")
	}
	operations, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"collectInstallPlan(existingNode, existingSSPort)", "confirmInstallPlan(plan)"} {
		if !strings.Contains(string(operations), required) {
			t.Fatalf("Windows menu integration is missing %q", required)
		}
	}
	flow, err := os.ReadFile("install_flow.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"TNA_COVER_TEMPLATE=", "chooseLocalCoverTemplate", "1—15"} {
		if !strings.Contains(string(flow), required) {
			t.Fatalf("install-plan template integration is missing %q", required)
		}
	}
	remote, err := os.ReadFile("remote.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"templates/cover-sites/MANIFEST.tsv", "templates/cover-sites/15-signal-runner.html"} {
		if !strings.Contains(string(remote), required) {
			t.Fatalf("same-version completeness probe is missing %q", required)
		}
	}
}
