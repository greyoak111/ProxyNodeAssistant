package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

const (
	remoteRoot              = "/opt/proxy-node-assistant-current"
	legacyTextRemoteRoot    = "/opt/text-node-assistant-current"
	legacyRunbookRemoteRoot = "/opt/proxy-runbook-current"
	toolkitVersion          = "1.0.0"
	toolkitBuildID          = "20260901-v100-ss2022-r104"
	toolkitBuildRevision    = 104
	toolkitInstallDir       = "/opt/proxy-node-assistant-v1.0.0"
	toolkitArchive          = "proxy-node-assistant-toolkit-v1.0.0.tar.gz"
	sessionTempPrefix       = "ProxyNodeAssistant-v1.0.0-session-"
	legacySessionTempPrefix = "ProxyNodeAssistant-v0.9.0-session-"
	hostKeyTempPrefix       = "ProxyNodeAssistant-v1.0.0-hostkey-"
)

var managedToolkitDirs = []string{
	"/opt/proxy-runbook-v0.5",
	"/opt/proxy-runbook-v0.6",
	"/opt/proxy-runbook-v0.6.1",
	"/opt/proxy-runbook-v0.6.2",
	"/opt/proxy-runbook-v0.6.3",
	"/opt/proxy-runbook-v0.6.4",
	"/opt/proxy-runbook-v0.6.5",
	"/opt/proxy-runbook-v0.6.6",
	"/opt/proxy-runbook-v0.6.7",
	"/opt/proxy-runbook-v0.6.8",
	"/opt/proxy-runbook-v0.6.9",
	"/opt/proxy-runbook-v0.7.0",
	"/opt/proxy-runbook-v0.7.1",
	"/opt/proxy-runbook-v0.7.2",
	"/opt/proxy-runbook-v0.7.3",
	"/opt/proxy-runbook-v0.7.4",
	"/opt/proxy-runbook-v0.7.5",
	"/opt/proxy-runbook-v0.8.0",
	"/opt/proxy-runbook-v0.8.1",
	"/opt/proxy-runbook-v0.8.2",
	"/opt/proxy-runbook-v0.8.3",
	"/opt/proxy-runbook-v0.9.0",
	"/opt/text-node-assistant-v0.9.5",
	"/opt/proxy-node-assistant-v1.0.0",
}

var managedToolkitArchives = []string{
	"/tmp/proxy-runbook-toolkit-v0.5.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.1.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.2.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.3.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.4.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.5.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.6.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.7.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.8.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.6.9.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.0.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.1.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.2.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.3.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.4.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.7.5.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.8.0.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.8.1.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.8.2.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.8.3.tar.gz",
	"/tmp/proxy-runbook-toolkit-v0.9.0.tar.gz",
	"/tmp/text-node-assistant-toolkit-v0.9.5.tar.gz",
	"/tmp/proxy-node-assistant-toolkit-v1.0.0.tar.gz",
}

var requiredOpenSSHExecutables = []string{
	"ssh.exe",
	"scp.exe",
	"ssh-keygen.exe",
	"ssh-keyscan.exe",
}

var openSSHExecutablePaths = map[string]string{}

type AuthMode string

const (
	AuthManagedKey        AuthMode = "managed-key"
	AuthTemporaryPassword AuthMode = "temporary-password"
)

type TemporaryAuth struct {
	Dir       string
	PublicKey string
	Installed bool
	Cleaned   bool
}

type Connection struct {
	Host       string
	User       string
	Port       int
	KeyPath    string
	AuthMode   AuthMode
	Temporary  *TemporaryAuth
	Ready      bool
	NewlyBound bool
}

var errConnectionSelectionCancelled = errors.New("connection selection cancelled")

var hostPartPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]+$`)
var userPartPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.-]*$`)

func safePart(value string) string {
	value = regexp.MustCompile(`[^A-Za-z0-9._-]+`).ReplaceAllString(value, "_")
	value = strings.Trim(value, "_")
	if value == "" {
		return "node"
	}
	return value
}

func target(c Connection) string {
	return c.User + "@" + c.Host
}

func scpTarget(c Connection, remotePath string) string {
	host := c.Host
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return c.User + "@" + host + ":" + remotePath
}

func shQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func defaultKeyPath(host, user string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".ssh", "proxy-runbook", safePart(host)+"-"+safePart(user), "id_ed25519"), nil
}

func knownHostsPath(c Connection) string {
	return filepath.Join(filepath.Dir(c.KeyPath), "known_hosts")
}

func openSSHOptionPath(path string) string {
	// OpenSSH parses -o values using ssh_config token rules even when Windows
	// CreateProcess delivered one argv item. Normalize separators and escape
	// characters that would otherwise split or comment the path.
	value := filepath.ToSlash(path)
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, " ", "\\ ")
	value = strings.ReplaceAll(value, "\t", "\\\t")
	value = strings.ReplaceAll(value, "#", "\\#")
	return value
}

func supportedHostKeyType(value string) bool {
	switch value {
	case "ssh-rsa", "ssh-ed25519",
		"ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
		"sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com":
		return true
	default:
		return false
	}
}

func decodedHostKey(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err == nil {
		return decoded, nil
	}
	return base64.RawStdEncoding.DecodeString(value)
}

func hostTokenMatchesConnection(value string, c *Connection) bool {
	if c == nil {
		return true
	}
	host := strings.TrimSuffix(strings.TrimPrefix(c.Host, "["), "]")
	want := map[string]bool{
		host:                                     true,
		"[" + host + "]:" + strconv.Itoa(c.Port): true,
	}
	for _, token := range strings.Split(value, ",") {
		if want[token] {
			return true
		}
	}
	return false
}

func validKnownHostLines(value string, c *Connection) []string {
	var lines []string
	seen := map[string]bool{}
	for _, line := range strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 || !hostTokenMatchesConnection(fields[0], c) || !supportedHostKeyType(fields[1]) {
			continue
		}
		decoded, err := decodedHostKey(fields[2])
		if err != nil || len(decoded) < 32 {
			continue
		}
		clean := strings.Join(fields[:3], " ")
		if !seen[clean] {
			seen[clean] = true
			lines = append(lines, clean)
		}
	}
	return lines

}

func knownHostEntryCount(value string) int {
	return len(validKnownHostLines(value, nil))
}

func managedCommandPath(name string) string {
	if filepath.IsAbs(name) {
		return name
	}
	logical := name
	if path := openSSHExecutablePaths[strings.ToLower(logical)]; path != "" {
		return path
	}
	// The Windows implementation historically passes the .exe suffix for all
	// OpenSSH tools.  Keep those logical names in the rest of the code (and in
	// the Windows compatibility tests), but resolve them to native command
	// names on Unix-like hosts where the binaries are named without .exe.
	name = nativeCommandName(name)
	if path := openSSHExecutablePaths[strings.ToLower(name)]; path != "" {
		return path
	}
	return name
}

func addUniqueDirectory(dirs *[]string, seen map[string]bool, path string) {
	if path == "" {
		return
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return
	}
	key := strings.ToLower(filepath.Clean(abs))
	if !seen[key] {
		seen[key] = true
		*dirs = append(*dirs, abs)
	}
}

type openSSHSuiteCandidate struct {
	paths        map[string]string
	version      [3]int
	versionKnown bool
	trusted      bool
	order        int
}

var openSSHVersionPattern = regexp.MustCompile(`(?i)OpenSSH(?:_for_Windows)?[_-]?(\d+)\.(\d+)(?:p(\d+))?`)

func probeOpenSSHVersion(path string) ([3]int, bool) {
	var parsed [3]int
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, path, "-V").CombinedOutput()
	if ctx.Err() != nil || (err != nil && len(output) == 0) {
		return parsed, false
	}
	match := openSSHVersionPattern.FindStringSubmatch(string(output))
	if len(match) < 3 {
		return parsed, false
	}
	for index := 1; index <= 3 && index < len(match); index++ {
		if match[index] == "" {
			continue
		}
		value, convErr := strconv.Atoi(match[index])
		if convErr != nil {
			return [3]int{}, false
		}
		parsed[index-1] = value
	}
	return parsed, true
}

func compareOpenSSHVersion(left, right [3]int) int {
	for index := range left {
		if left[index] < right[index] {
			return -1
		}
		if left[index] > right[index] {
			return 1
		}
	}
	return 0
}

func openSSHSuiteCandidates() []openSSHSuiteCandidate {
	var dirs []string
	seen := map[string]bool{}
	trustedDirs := map[string]bool{}
	addTrustedDirectory := func(path string) {
		addUniqueDirectory(&dirs, seen, path)
		if abs, err := filepath.Abs(path); err == nil {
			trustedDirs[strings.ToLower(filepath.Clean(abs))] = true
		}
	}
	// Prefer newer suites inside Windows/Program Files. PATH remains a fallback,
	// but a user-writable PATH entry must not outrank an OS-managed installation.
	if windowsDir := strings.TrimSpace(os.Getenv("WINDIR")); windowsDir != "" {
		// A 32-bit process on 64-bit Windows is redirected away from System32.
		// Sysnative reaches the native OpenSSH installation without weakening the
		// trusted-directory ordering used by the suite selector.
		if runtime.GOARCH == "386" && strings.TrimSpace(os.Getenv("PROCESSOR_ARCHITEW6432")) != "" {
			addTrustedDirectory(filepath.Join(windowsDir, "Sysnative", "OpenSSH"))
		}
		addTrustedDirectory(filepath.Join(windowsDir, "System32", "OpenSSH"))
	}
	if programFiles := strings.TrimSpace(os.Getenv("ProgramFiles")); programFiles != "" {
		addTrustedDirectory(filepath.Join(programFiles, "OpenSSH"))
	}
	for _, name := range requiredOpenSSHExecutables {
		if path, err := exec.LookPath(nativeCommandName(name)); err == nil {
			addUniqueDirectory(&dirs, seen, filepath.Dir(path))
		}
	}

	var candidates []openSSHSuiteCandidate
	for order, dir := range dirs {
		paths := map[string]string{}
		complete := true
		for _, name := range requiredOpenSSHExecutables {
			path := filepath.Join(dir, nativeCommandName(name))
			if !fileExists(path) {
				complete = false
				break
			}
			paths[strings.ToLower(name)] = path
		}
		if complete {
			version, known := probeOpenSSHVersion(paths["ssh.exe"])
			trusted := trustedDirs[strings.ToLower(filepath.Clean(dir))]
			candidates = append(candidates, openSSHSuiteCandidate{paths: paths, version: version, versionKnown: known, trusted: trusted, order: order})
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := candidates[i], candidates[j]
		if left.trusted != right.trusted {
			return left.trusted
		}
		if left.versionKnown != right.versionKnown {
			return left.versionKnown
		}
		if left.versionKnown {
			if compared := compareOpenSSHVersion(left.version, right.version); compared != 0 {
				return compared > 0
			}
		}
		return left.order < right.order
	})
	return candidates
}

func resolveOpenSSHSuite() (map[string]string, bool) {
	candidates := openSSHSuiteCandidates()
	if len(candidates) == 0 {
		return nil, false
	}
	return candidates[0].paths, true
}

func executableLaunches(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "-?")
	err := cmd.Run()
	if ctx.Err() != nil {
		return fmt.Errorf("%s launch probe timed out", filepath.Base(path))
	}
	if err == nil {
		return nil
	}
	if _, ok := err.(*exec.ExitError); ok {
		// OpenSSH tools commonly use a non-zero status after printing usage for -?.
		// Reaching that exit status proves the executable loaded successfully.
		return nil
	}
	return fmt.Errorf("%s could not start: %w", filepath.Base(path), err)
}

func validateOpenSSHSuite(paths map[string]string) error {
	for _, name := range requiredOpenSSHExecutables {
		path := strings.TrimSpace(paths[strings.ToLower(name)])
		if path == "" || !fileExists(path) {
			return fmt.Errorf("%s is missing", name)
		}
		if err := executableLaunches(path); err != nil {
			return err
		}
	}
	return nil
}

func resolveVerifiedOpenSSHSuite() (map[string]string, error) {
	candidates := openSSHSuiteCandidates()
	if len(candidates) == 0 {
		return nil, fmt.Errorf("a complete OpenSSH client suite is required: %s", strings.Join(requiredOpenSSHExecutables, ", "))
	}
	var failures []string
	for _, candidate := range candidates {
		if err := validateOpenSSHSuite(candidate.paths); err == nil {
			return candidate.paths, nil
		} else {
			failures = append(failures, err.Error())
		}
	}
	return nil, fmt.Errorf("no complete OpenSSH suite passed launch verification: %s", strings.Join(failures, "; "))
}

func openSSHSuiteSummary(paths map[string]string) string {
	sshPath := strings.TrimSpace(paths["ssh.exe"])
	if sshPath == "" {
		return ""
	}
	version := "version unavailable"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, sshPath, "-V").CombinedOutput(); ctx.Err() == nil && (err == nil || len(output) > 0) {
		if cleaned := strings.TrimSpace(stripANSI(string(output))); cleaned != "" {
			version = strings.ReplaceAll(cleaned, "\n", " | ")
		}
	}
	return version + " | " + filepath.Dir(sshPath)
}

func powershellEncodedCommand(script string) string {
	units := utf16.Encode([]rune(script))
	raw := make([]byte, len(units)*2)
	for index, unit := range units {
		raw[index*2] = byte(unit)
		raw[index*2+1] = byte(unit >> 8)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func installOpenSSHClientOnce() ProcessResult {
	child := strings.Join([]string{
		`$ErrorActionPreference = 'Stop'`,
		`$name = 'OpenSSH.Client~~~~0.0.1.0'`,
		`$capability = Get-WindowsCapability -Online -Name $name`,
		`if ($capability.State -ne 'Installed') { Add-WindowsCapability -Online -Name $name | Out-Null }`,
		`$capability = Get-WindowsCapability -Online -Name $name`,
		`$directory = Join-Path $env:WINDIR 'System32\OpenSSH'`,
		`$required = @('ssh.exe','scp.exe','ssh-keygen.exe','ssh-keyscan.exe')`,
		`$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $directory $_) -PathType Leaf) })`,
		`if ($capability.State -ne 'Installed' -or $missing.Count -ne 0) { throw ('OpenSSH verification failed. State={0}; Missing={1}' -f $capability.State, ($missing -join ',')) }`,
	}, "; ")
	encoded := powershellEncodedCommand(child)
	parent := fmt.Sprintf(`$process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','%s'); exit $process.ExitCode`, encoded)
	powershellPath := "powershell.exe"
	if runtime.GOARCH == "386" && strings.TrimSpace(os.Getenv("PROCESSOR_ARCHITEW6432")) != "" {
		candidate := filepath.Join(os.Getenv("WINDIR"), "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe")
		if fileExists(candidate) {
			powershellPath = candidate
		}
	}
	return runStreaming(powershellPath, []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", parent}, os.Stdin, false)
}

func (a *App) startupOpenSSHPreflight() error {
	if paths, err := resolveVerifiedOpenSSHSuite(); err == nil {
		openSSHExecutablePaths = paths
		a.println(a.msg("[GOOD] OpenSSH 客户端已安装并通过启动验证。", "[GOOD] OpenSSH client is installed and passed launch verification."))
		a.println("OpenSSH=" + openSSHSuiteSummary(paths))
		return nil
	}
	if runtime.GOOS != "windows" {
		return fmt.Errorf("OpenSSH client suite is unavailable; install ssh, scp, ssh-keygen, and ssh-keyscan with the system package manager, then restart")
	}

	a.println(a.msg("[INFO] 未找到可用的完整 Windows OpenSSH Client；现在申请管理员权限安装一次并复验。", "[INFO] A usable complete Windows OpenSSH Client was not found. Administrator permission will be requested once, followed by verification."))
	result := installOpenSSHClientOnce()
	if !result.OK() {
		return fmt.Errorf("one-time OpenSSH installation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	paths, err := resolveVerifiedOpenSSHSuite()
	if err != nil {
		return fmt.Errorf("OpenSSH installer returned success but verification failed: %w", err)
	}
	openSSHExecutablePaths = paths
	a.println(a.msg("[GOOD] Windows OpenSSH 已一次性安装完成，四个组件均可启动。", "[GOOD] Windows OpenSSH was installed in one attempt and all four components can start."))
	a.println("OpenSSH=" + openSSHSuiteSummary(paths))
	return nil
}

func sshBase(c Connection, batch, tty bool, keyOverride string) []string {
	args := []string{
		"-o", "ConnectTimeout=12",
		"-o", "ServerAliveInterval=30",
		"-o", "ServerAliveCountMax=3",
		"-o", "LogLevel=ERROR",
		"-o", "UserKnownHostsFile=" + openSSHOptionPath(knownHostsPath(c)),
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UpdateHostKeys=no",
	}
	key := keyOverride
	if key == "" {
		key = c.KeyPath
	}
	if key != "" && fileExists(key) {
		args = append(args, "-i", key, "-o", "IdentitiesOnly=yes")
	}
	if batch {
		args = append(args, "-o", "BatchMode=yes")
	}
	if tty {
		args = append(args, "-tt")
	} else {
		args = append(args, "-T")
	}
	args = append(args, "-p", strconv.Itoa(c.Port))
	return args
}

func scpBase(c Connection, keyPath string) []string {
	args := []string{
		"-o", "ConnectTimeout=12",
		"-o", "LogLevel=ERROR",
		"-o", "UserKnownHostsFile=" + openSSHOptionPath(knownHostsPath(c)),
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UpdateHostKeys=no",
		"-o", "BatchMode=yes",
	}
	if keyPath != "" && fileExists(keyPath) {
		args = append(args, "-i", keyPath, "-o", "IdentitiesOnly=yes")
	}
	return append(args, "-P", strconv.Itoa(c.Port))
}

func wrapRoot(c Connection, command string, nonInteractive bool) string {
	wrapped := "bash -lc " + shQuote(command)
	if c.User == "root" {
		return wrapped
	}
	if nonInteractive {
		return "sudo -n " + wrapped
	}
	return "sudo " + wrapped
}

func (a *App) sshCapture(c Connection, command string) ProcessResult {
	args := sshBase(c, true, false, "")
	args = append(args, target(c), command)
	return runCaptured("ssh.exe", args, nil, true)
}

func (a *App) sshCaptureWithInput(c Connection, command string, input []byte) ProcessResult {
	args := sshBase(c, true, false, "")
	args = append(args, target(c), command)
	return runCaptured("ssh.exe", args, input, true)
}

func (a *App) rootCapture(c Connection, command string) ProcessResult {
	return a.sshCapture(c, wrapRoot(c, command, true))
}

func (a *App) rootCaptureWithInput(c Connection, command string, input []byte) ProcessResult {
	args := sshBase(c, true, false, "")
	args = append(args, target(c), wrapRoot(c, command, true))
	return runCaptured("ssh.exe", args, input, true)
}

func (a *App) runRootInteractive(c Connection, command string) ProcessResult {
	args := sshBase(c, false, true, "")
	args = append(args, target(c), wrapRoot(c, command, false))
	return runStreaming("ssh.exe", args, os.Stdin, false)
}

func tcpReachable(host string, port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 8*time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func (a *App) promptConnection(mode AuthMode) (Connection, error) {
	host, user, port, err := a.chooseConnectionDetails()
	if err != nil {
		return Connection{}, err
	}
	if err := rememberRecentTarget(RecentTarget{Host: host, User: user, Port: port}); err != nil {
		a.println(a.msg("[WARN] 无法保存本次 VPS 登录历史：", "[WARN] Could not save this VPS target to history:") + " " + err.Error())
	}
	c := Connection{Host: host, User: user, Port: port, AuthMode: mode}
	if mode == AuthTemporaryPassword {
		dir, err := os.MkdirTemp("", sessionTempPrefix)
		if err != nil {
			return Connection{}, err
		}
		c.KeyPath = filepath.Join(dir, "id_ed25519")
		c.Temporary = &TemporaryAuth{Dir: dir}
	} else {
		keyPath, err := defaultKeyPath(host, user)
		if err != nil {
			return Connection{}, err
		}
		c.KeyPath = keyPath
	}
	return c, nil
}

func (a *App) chooseActionAuthMode() (AuthMode, bool) {
	a.println(a.msg("本项操作的 SSH 登录方式（每项都重新选择）：", "SSH login method for this action (re-selected for every action):"))
	a.println(a.msg("[1] 临时密码：密码只交给 OpenSSH；一次性 key 在本项结束时自动撤销并删除", "[1] Temporary password: the password goes only to OpenSSH; the one-time key is revoked and deleted when this action ends"))
	a.println(a.msg("[2] 已绑定/节点长期 key：按 VPS + 用户分别查找；若尚未绑定，会先询问一次密码再问是否绑定", "[2] Bound/per-node key: looked up separately by VPS + user; if absent, one password is requested and then binding is offered"))
	a.println(a.msg("[0] 取消", "[0] Cancel"))
	for {
		choice := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("请选择登录方式", "Choose login method"))))
		if a.inputClosed {
			return "", false
		}
		switch choice {
		case "1", "p", "password":
			return AuthTemporaryPassword, true
		case "2", "k", "key":
			return AuthManagedKey, true
		case "0", "q":
			return "", false
		default:
			a.println(a.msg("请输入 1、2 或 0。", "Enter 1, 2, or 0."))
		}
	}
}

func (a *App) registerTemporaryConnection(c *Connection) {
	a.tempCleanupMu.Lock()
	a.activeTemporary = c
	a.tempCleanupMu.Unlock()
}

func (a *App) getActionConnection() (*Connection, error) {
	if a.actionConnection != nil {
		return a.actionConnection, nil
	}
	mode, ok := a.chooseActionAuthMode()
	if !ok {
		return nil, errConnectionSelectionCancelled
	}
	// Never silently reuse a previous target. Key lookup remains convenient
	// because the derived managed path is per VPS + user.
	a.conn = nil
	c, err := a.promptConnection(mode)
	if err != nil {
		return nil, err
	}
	a.actionConnection = &c
	if mode == AuthTemporaryPassword {
		a.registerTemporaryConnection(&c)
	}
	return &c, nil
}

func (a *App) ensureOpenSSH() error {
	paths, err := resolveVerifiedOpenSSHSuite()
	if err != nil {
		return fmt.Errorf("OpenSSH became unavailable after startup verification: %w", err)
	}
	openSSHExecutablePaths = paths
	return nil
}

type hostKeyScanAttempt struct {
	Method     string
	ExitCode   int
	ValidKeys  int
	Diagnostic string
}

func hostKeyScanDiagnostic(result ProcessResult) string {
	detail := clipFailureText(sanitizeSSHStderr(result.Stderr))
	if detail == "" && result.Err != nil && result.ExitCode < 0 {
		detail = result.Err.Error()
	}
	return detail
}

func parsedHostKeys(result ProcessResult, c Connection) string {
	// ssh-keyscan can return useful keys together with a non-zero process exit
	// on some Windows/OpenSSH/network combinations. Valid parsed key material is
	// authoritative; an exit code by itself must not discard it.
	return strings.Join(validKnownHostLines(result.Stdout, &c), "\n")
}

func win32KeyscanUnsupportedKEX(value string) bool {
	text := strings.ToLower(value)
	return strings.Contains(text, "choose_kex: unsupported kex method") &&
		strings.Contains(text, "sntrup761x25519-sha512@openssh.com")
}

// scanHostKeysViaSSH is a compatibility fallback for the documented
// Win32-OpenSSH ssh-keyscan bug that proposes sntrup even when that particular
// executable was built without the implementation. ssh.exe does not have the
// bug. It performs only key exchange and a deliberately non-interactive,
// no-credential authentication attempt. The discovered key is written to a
// fresh temporary known_hosts file, parsed, shown to the user, and is not moved
// into the persistent node directory until the user explicitly confirms its
// fingerprint in ensureHostKey.
func isolatedSSHHostKeyArgs(c Connection, path string) []string {
	return []string{
		"-F", nullDevicePath(),
		"-o", "ConnectTimeout=12",
		"-o", "ConnectionAttempts=1",
		"-o", "LogLevel=ERROR",
		"-o", "UserKnownHostsFile=" + openSSHOptionPath(path),
		"-o", "GlobalKnownHostsFile=" + nullDevicePath(),
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UpdateHostKeys=no",
		"-o", "HashKnownHosts=no",
		"-o", "CheckHostIP=no",
		"-o", "BatchMode=yes",
		"-o", "PubkeyAuthentication=no",
		"-o", "PasswordAuthentication=no",
		"-o", "KbdInteractiveAuthentication=no",
		"-o", "PreferredAuthentications=none",
		"-o", "NumberOfPasswordPrompts=0",
		"-T", "-p", strconv.Itoa(c.Port), target(c), "true",
	}
}

func scanHostKeysViaSSH(c Connection) (string, hostKeyScanAttempt) {
	attempt := hostKeyScanAttempt{Method: "isolated-ssh-fallback", ExitCode: -1}
	dir, err := os.MkdirTemp("", hostKeyTempPrefix)
	if err != nil {
		attempt.Diagnostic = err.Error()
		return "", attempt
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "known_hosts")
	args := isolatedSSHHostKeyArgs(c, path)
	result := runCaptured("ssh.exe", args, nil, true)
	attempt.ExitCode = result.ExitCode
	attempt.Diagnostic = hostKeyScanDiagnostic(result)
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		if !os.IsNotExist(readErr) && attempt.Diagnostic == "" {
			attempt.Diagnostic = readErr.Error()
		}
		return "", attempt
	}
	keys := strings.Join(validKnownHostLines(string(data), &c), "\n")
	attempt.ValidKeys = knownHostEntryCount(keys)
	return keys, attempt
}

func scanHostKeys(c Connection) (string, []hostKeyScanAttempt) {
	family := []string{}
	hostForIP := strings.TrimSuffix(strings.TrimPrefix(c.Host, "["), "]")
	if ip := net.ParseIP(hostForIP); ip != nil {
		if ip.To4() != nil {
			family = []string{"-4"}
		} else {
			family = []string{"-6"}
		}
	}
	plans := [][]string{
		{"-T", "8", "-p", strconv.Itoa(c.Port), c.Host},
		{"-T", "12", "-t", "rsa,ecdsa,ed25519", "-p", strconv.Itoa(c.Port), c.Host},
		{"-T", "15", "-p", strconv.Itoa(c.Port), c.Host},
	}
	var attempts []hostKeyScanAttempt
	for index, plan := range plans {
		args := append(append([]string{}, family...), plan...)
		result := runCaptured("ssh-keyscan.exe", args, nil, true)
		keys := parsedHostKeys(result, c)
		count := knownHostEntryCount(keys)
		diagnostic := hostKeyScanDiagnostic(result)
		attempts = append(attempts, hostKeyScanAttempt{
			Method:     "ssh-keyscan",
			ExitCode:   result.ExitCode,
			ValidKeys:  count,
			Diagnostic: diagnostic,
		})
		if count > 0 {
			return keys, attempts
		}
		if win32KeyscanUnsupportedKEX(diagnostic) {
			break
		}
		if index+1 < len(plans) {
			time.Sleep(250 * time.Millisecond)
		}
	}
	keys, fallback := scanHostKeysViaSSH(c)
	attempts = append(attempts, fallback)
	if knownHostEntryCount(keys) > 0 {
		return keys, attempts
	}
	return "", attempts
}

func formatHostKeyScanAttempts(attempts []hostKeyScanAttempt) string {
	var lines []string
	for index, attempt := range attempts {
		method := attempt.Method
		if method == "" {
			method = "ssh-keyscan"
		}
		line := fmt.Sprintf("attempt=%d method=%s exit=%d valid_keys=%d", index+1, method, attempt.ExitCode, attempt.ValidKeys)
		if attempt.Diagnostic != "" {
			line += " error=" + strings.ReplaceAll(attempt.Diagnostic, "\n", " | ")
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

func (a *App) ensureHostKey(c Connection) error {
	path := knownHostsPath(c)
	if fileExists(path) {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		keys := strings.Join(validKnownHostLines(string(data), &c), "\n")
		if knownHostEntryCount(keys) == 0 {
			return errors.New(a.msg("专用 known_hosts 文件无有效主机密钥；为防止中间人攻击，本次停止。核对 VPS 厂商指纹后删除该空文件再重试。", "The dedicated known_hosts file has no valid host key; stopping to prevent a MITM. Verify the provider fingerprint, remove the empty file, and retry."))
		}
		fingerprint := runCaptured("ssh-keygen.exe", []string{"-lf", "-"}, []byte(keys+"\n"), true)
		if !fingerprint.OK() || strings.TrimSpace(fingerprint.Stdout) == "" {
			return fmt.Errorf(a.msg("无法读取已保存的 VPS Host 指纹：%s", "Could not read the saved VPS host fingerprint: %s"), processFailureDetail(fingerprint))
		}
		a.println(a.msg("已保存的 VPS SSH Host 公钥指纹：", "Saved VPS SSH host public-key fingerprint:"))
		a.println(strings.TrimSpace(fingerprint.Stdout))
		return nil
	}

	keys, attempts := scanHostKeys(c)
	if knownHostEntryCount(keys) == 0 {
		return fmt.Errorf("%s\nssh-keyscan=%s\nssh=%s\n%s", a.msg("无法通过 ssh-keyscan 或隔离 ssh.exe 握手取得 VPS SSH Host 公钥；本次不会生成登录私钥或尝试密码登录。请检查地址、端口、sshd、本地网络和安全软件。", "Could not obtain the VPS SSH host key through ssh-keyscan or the isolated ssh.exe handshake; no login private key or password attempt was made. Check the host, port, sshd, local network, and security software."), managedCommandPath("ssh-keyscan.exe"), managedCommandPath("ssh.exe"), formatHostKeyScanAttempts(attempts))
	}
	usedFallback := false
	detectedKEXBug := false
	for _, attempt := range attempts {
		if attempt.Method == "isolated-ssh-fallback" && attempt.ValidKeys > 0 {
			usedFallback = true
		}
		if win32KeyscanUnsupportedKEX(attempt.Diagnostic) {
			detectedKEXBug = true
		}
	}
	if usedFallback {
		if detectedKEXBug {
			a.println(a.msg("[INFO] 已识别 Windows ssh-keyscan 的 sntrup KEX 兼容缺陷；已改用隔离、无密码的 ssh.exe 握手取得 Host 公钥。", "[INFO] Detected the Windows ssh-keyscan sntrup KEX compatibility defect; an isolated, credential-free ssh.exe handshake obtained the host key instead."))
		} else {
			a.println(a.msg("[INFO] ssh-keyscan 未返回可用公钥；已由隔离、无密码的 ssh.exe 握手安全回退取得。", "[INFO] ssh-keyscan returned no usable key; an isolated, credential-free ssh.exe handshake safely obtained it instead."))
		}
	}
	fingerprint := runCaptured("ssh-keygen.exe", []string{"-lf", "-"}, []byte(keys+"\n"), true)
	if !fingerprint.OK() || strings.TrimSpace(fingerprint.Stdout) == "" {
		return fmt.Errorf(a.msg("无法计算 VPS SSH Host 指纹：%s", "Could not calculate the VPS SSH host fingerprint: %s"), processFailureDetail(fingerprint))
	}
	a.println(a.msg("首次连接发现以下 VPS SSH Host 公钥指纹：", "The following VPS SSH host fingerprint was discovered for the first connection:"))
	a.println(strings.TrimSpace(fingerprint.Stdout))
	a.println(a.msg("有厂商控制台指纹时必须逐项核对。确认后程序会保存到这台节点专用的 known_hosts；OpenSSH 不再弹出无法输入的 yes/no。", "Compare every fingerprint with the provider console when available. After confirmation it is saved in a node-specific known_hosts file, so OpenSSH will not show its own yes/no prompt."))
	if !a.yes(a.msg("确认这些指纹确实属于你的 VPS 并保存？", "Do these fingerprints belong to your VPS, and should they be saved?"), false) {
		return errors.New(a.msg("未信任 VPS Host 公钥；没有生成或安装 SSH 登录密钥。", "The VPS host key was not trusted; no SSH login key was generated or installed."))
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(keys+"\n"), 0600); err != nil {
		return err
	}
	a.println(a.msg("VPS Host 公钥已保存：", "VPS host key saved:") + " " + path)
	return nil
}

func verifyKey(c Connection, keyPath string) ProcessResult {
	args := sshBase(c, true, false, keyPath)
	args = append(args, target(c), "printf SSH_KEY_OK")
	return runCaptured("ssh.exe", args, nil, true)
}

func generateKey(keyPath, comment string) error {
	if err := os.MkdirAll(filepath.Dir(keyPath), 0700); err != nil {
		return err
	}
	result := runCaptured("ssh-keygen.exe", []string{"-q", "-t", "ed25519", "-f", keyPath, "-N", "", "-C", comment}, nil, true)
	if !result.OK() {
		return fmt.Errorf("ssh-keygen failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return nil
}

func readPublicKey(keyPath string) (string, error) {
	data, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func (a *App) installPublicKey(c Connection, keyPath, authKeyPath string, onInstalled func()) error {
	pub, err := readPublicKey(keyPath)
	if err != nil {
		return err
	}
	encoded := base64.StdEncoding.EncodeToString([]byte(pub))
	remote := "umask 077; mkdir -p \"$HOME/.ssh\"; touch \"$HOME/.ssh/authorized_keys\"; " +
		"k=$(printf %s " + shQuote(encoded) + " | base64 -d); " +
		"grep -qxF \"$k\" \"$HOME/.ssh/authorized_keys\" || printf '%s\\n' \"$k\" >> \"$HOME/.ssh/authorized_keys\"; " +
		"chmod 700 \"$HOME/.ssh\"; chmod 600 \"$HOME/.ssh/authorized_keys\""
	interactivePassword := authKeyPath == ""
	// Keep c.KeyPath intact: it anchors the node-specific known_hosts path.
	// authKeyPath selects only the login identity. On first install it is empty,
	// so the newly generated canonical key may be offered before password
	// fallback without changing host-key verification state.
	args := sshBase(c, !interactivePassword, false, authKeyPath)
	args = append(args, target(c), remote)
	var result ProcessResult
	if interactivePassword {
		if os.Getenv("PNA_GUI_MODE") == "1" {
			a.println(a.msg("OpenSSH 即将请求 VPS 密码；请在图形遮罩密码框中输入并提交。密码不会进入日志、参数、剪贴板或磁盘。", "OpenSSH is about to request the VPS password. Enter it in the graphical masked password dialog. It is not written to logs, arguments, the clipboard, or disk."))
		} else {
			a.println(a.msg("下面是 OpenSSH 的 VPS 密码输入。输入时屏幕不会显示字符，这是正常的；输入完成按 Enter。", "OpenSSH will now ask for the VPS password. No characters are shown while typing; press Enter when finished."))
		}
		result = runInteractiveSSH("ssh.exe", args)
	} else {
		result = runCaptured("ssh.exe", args, nil, true)
	}
	if !result.OK() {
		return fmt.Errorf("public-key install failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	if onInstalled != nil {
		onInstalled()
	}
	verified := verifyKey(c, keyPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		return fmt.Errorf("SSH key verification failed (exit %d): %s", verified.ExitCode, processFailureDetail(verified))
	}
	return nil
}

func authorizedKeyRemovalCommand(publicKey, marker string) string {
	if !regexp.MustCompile(`^[A-Z0-9_]+$`).MatchString(marker) {
		panic("invalid authorized-key removal marker")
	}
	encoded := base64.StdEncoding.EncodeToString([]byte(strings.TrimSpace(publicKey)))
	return "set -eu; f=\"$HOME/.ssh/authorized_keys\"; " +
		"if [ -f \"$f\" ]; then old=$(printf %s " + shQuote(encoded) + " | base64 -d); " +
		"tmp=$(mktemp); grep -vxF \"$old\" \"$f\" > \"$tmp\" || true; cat \"$tmp\" > \"$f\"; rm -f \"$tmp\"; chmod 600 \"$f\"; fi; " +
		"printf '" + marker + "\\n'"
}

func temporaryAuthorizedKeyRemovalCommand(publicKey string) string {
	return authorizedKeyRemovalCommand(publicKey, "TEMPORARY_SSH_KEY_REMOVED")
}

func validTemporaryKeyDir(dir string) bool {
	if dir == "" {
		return false
	}
	base, err := filepath.Abs(os.TempDir())
	if err != nil {
		return false
	}
	candidate, err := filepath.Abs(dir)
	baseName := filepath.Base(candidate)
	if err != nil || (!strings.HasPrefix(baseName, sessionTempPrefix) && !strings.HasPrefix(baseName, legacySessionTempPrefix)) {
		return false
	}
	relative, err := filepath.Rel(base, candidate)
	return err == nil && relative != "." && relative != ".." && !filepath.IsAbs(relative) && !strings.HasPrefix(relative, ".."+string(os.PathSeparator))
}

func removeTemporaryKeyDir(dir string) error {
	if !validTemporaryKeyDir(dir) {
		return fmt.Errorf("refused unsafe temporary-key cleanup path: %s", dir)
	}
	return os.RemoveAll(dir)
}

func (a *App) prepareTemporaryPasswordAuth(c *Connection) error {
	if c == nil || c.AuthMode != AuthTemporaryPassword || c.Temporary == nil {
		return errors.New("temporary password authentication state is missing")
	}
	if err := a.ensureHostKey(*c); err != nil {
		return err
	}
	if err := generateKey(c.KeyPath, "proxy-node-assistant-temporary-session"); err != nil {
		return err
	}
	publicKey, err := readPublicKey(c.KeyPath)
	if err != nil {
		return err
	}
	c.Temporary.PublicKey = publicKey
	if os.Getenv("PNA_GUI_MODE") == "1" {
		a.println(a.msg("临时密码模式：稍后在图形遮罩密码框中输入一次 VPS 密码；它只通过本机受限命名管道交给 OpenSSH。", "Temporary password mode: enter the VPS password once in the graphical masked dialog; it is passed to OpenSSH only through a restricted local named pipe."))
	} else {
		a.println(a.msg("临时密码模式：下面只向 OpenSSH 输入一次 VPS 密码；程序不会读取或保存密码。", "Temporary password mode: enter the VPS password once into OpenSSH; this program never reads or stores it."))
	}
	a.println(a.msg("为支持本项多步 SSH/SCP，程序会安装一次性公钥；若不绑定，会在本项结束前从 VPS 撤销，并删除本机临时私钥。", "A one-time public key is installed for this multi-step SSH/SCP action; unless you bind it, it is revoked from the VPS and the local temporary private key is deleted before the action returns."))
	if err := a.installPublicKey(*c, c.KeyPath, "", func() { c.Temporary.Installed = true }); err != nil {
		return err
	}
	a.println("TEMPORARY_SSH_KEY_OK")
	return nil
}

func (a *App) cleanupTemporaryConnection(c *Connection) error {
	if c == nil || c.AuthMode != AuthTemporaryPassword || c.Temporary == nil {
		return nil
	}
	a.tempCleanupMu.Lock()
	defer a.tempCleanupMu.Unlock()
	temporary := c.Temporary
	if temporary.Cleaned {
		return nil
	}
	temporary.Cleaned = true
	var remoteErr error
	if temporary.Installed && temporary.PublicKey != "" && fileExists(c.KeyPath) {
		a.println(a.msg("正在撤销 VPS 上的本次一次性 SSH 公钥…", "Revoking this session's one-time SSH public key from the VPS..."))
		result := a.sshCapture(*c, temporaryAuthorizedKeyRemovalCommand(temporary.PublicKey))
		if !result.OK() || !strings.Contains(result.Stdout, "TEMPORARY_SSH_KEY_REMOVED") {
			remoteErr = fmt.Errorf("temporary public-key revocation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
		} else {
			a.println(a.msg("一次性 SSH 公钥已从 VPS 撤销。", "The one-time SSH public key was revoked from the VPS."))
		}
	}
	localErr := removeTemporaryKeyDir(temporary.Dir)
	if localErr == nil {
		a.println(a.msg("本机临时私钥和临时 known_hosts 已删除。", "The local temporary private key and temporary known_hosts were deleted."))
	}
	if a.activeTemporary != nil && a.activeTemporary.Temporary != nil && a.activeTemporary.Temporary.Dir == temporary.Dir {
		a.activeTemporary = nil
	}
	if a.conn != nil && a.conn.Temporary != nil && a.conn.Temporary.Dir == temporary.Dir {
		a.conn = nil
	}
	if remoteErr != nil && localErr != nil {
		return fmt.Errorf("%v; local cleanup also failed: %w", remoteErr, localErr)
	}
	if remoteErr != nil {
		return remoteErr
	}
	return localErr
}

func (a *App) cleanupActiveTemporaryAuth() error {
	a.tempCleanupMu.Lock()
	c := a.activeTemporary
	a.tempCleanupMu.Unlock()
	return a.cleanupTemporaryConnection(c)
}

func copyFileExclusive(source, destination string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		_ = output.Close()
		if !complete {
			_ = os.Remove(destination)
		}
	}()
	if _, err := io.Copy(output, input); err != nil {
		return err
	}
	if err := output.Sync(); err != nil {
		return err
	}
	if err := output.Close(); err != nil {
		return err
	}
	complete = true
	return nil
}

func (a *App) promoteTemporaryConnection(c *Connection) error {
	if c == nil || c.AuthMode != AuthTemporaryPassword || c.Temporary == nil || !c.Temporary.Installed {
		return errors.New(a.msg("没有已验证的临时登录可绑定。", "There is no verified temporary login to bind."))
	}
	managedPath, err := defaultKeyPath(c.Host, c.User)
	if err != nil {
		return err
	}
	if fileExists(managedPath) || fileExists(managedPath+".pub") {
		return errors.New(a.msg("目标位置已经存在长期 key；为防止覆盖，本次拒绝绑定。请用 [K] 管理旧绑定。", "A managed key already exists at the target path; binding is refused to prevent overwrite. Use [K] to manage the old binding."))
	}
	if err := os.MkdirAll(filepath.Dir(managedPath), 0700); err != nil {
		return err
	}
	created := []string{}
	rollback := func() {
		for _, path := range created {
			_ = os.Remove(path)
		}
	}
	if err := copyFileExclusive(c.KeyPath, managedPath, 0600); err != nil {
		return fmt.Errorf("managed private-key promotion failed: %w", err)
	}
	created = append(created, managedPath)
	if err := copyFileExclusive(c.KeyPath+".pub", managedPath+".pub", 0600); err != nil {
		rollback()
		return fmt.Errorf("managed public-key promotion failed: %w", err)
	}
	created = append(created, managedPath+".pub")
	managed := Connection{Host: c.Host, User: c.User, Port: c.Port, KeyPath: managedPath, AuthMode: AuthManagedKey}
	sourceHosts := knownHostsPath(*c)
	destinationHosts := knownHostsPath(managed)
	if !fileExists(destinationHosts) {
		if err := copyFileExclusive(sourceHosts, destinationHosts, 0600); err != nil {
			rollback()
			return fmt.Errorf("known_hosts promotion failed: %w", err)
		}
		created = append(created, destinationHosts)
	}
	verified := verifyKey(managed, managedPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		rollback()
		return fmt.Errorf("promoted managed key failed verification (exit %d): %s", verified.ExitCode, processFailureDetail(verified))
	}
	if err := writeManagedKeyMetadata(filepath.Dir(managedPath), managed, "BOUND"); err != nil {
		a.println(a.msg("长期 key 已验证，但写入节点说明文件失败：", "The managed key was verified, but its node metadata could not be written:") + " " + err.Error())
	}
	temporary := c.Temporary
	temporary.Installed = false // The same public key is intentionally retained as the managed binding.
	temporary.Cleaned = true
	if err := removeTemporaryKeyDir(temporary.Dir); err != nil {
		a.println(a.msg("长期 key 已验证并保留，但临时副本目录删除失败，请手工删除：", "The managed key was verified and retained, but the temporary copy directory could not be removed; delete it manually:") + " " + temporary.Dir)
	}
	managed.Ready = true
	managed.NewlyBound = true
	*c = managed
	a.tempCleanupMu.Lock()
	a.activeTemporary = nil
	a.tempCleanupMu.Unlock()
	a.conn = c
	a.println(a.msg("已绑定为这台 VPS + SSH 用户专属的长期 key。以后选择 [2] 即可使用。", "The key is now bound to this VPS + SSH user. Choose [2] in later actions to use it."))
	return a.showKeyHandoff(c.KeyPath, a.msg("已绑定 SSH 登录密钥（必须保存）", "Bound SSH login key (save this)"))
}

func (a *App) authenticateActionConnection(c *Connection) error {
	if c == nil {
		return errors.New("action connection is missing")
	}
	if c.Ready {
		return nil
	}
	requestedMode := c.AuthMode
	if requestedMode == AuthManagedKey && (fileExists(c.KeyPath) || fileExists(c.KeyPath+".pub")) {
		if err := a.ensureKey(*c); err != nil {
			return err
		}
		c.Ready = true
		a.conn = c
		return nil
	}
	if requestedMode == AuthManagedKey {
		a.println(a.msg("这台 VPS + SSH 用户在本机尚无长期 key。先用一次初始密码建立临时会话；密码验证成功后再明确询问是否绑定。", "No managed key exists locally for this VPS + SSH user. A one-time password session will be established first; binding is offered only after verification."))
		temporary, err := a.promptlessTemporaryConnection(c.Host, c.User, c.Port)
		if err != nil {
			return err
		}
		*c = temporary
		a.registerTemporaryConnection(c)
	}
	if err := a.prepareTemporaryPasswordAuth(c); err != nil {
		return err
	}
	c.Ready = true
	defaultBind := requestedMode == AuthManagedKey
	if a.yes(a.msg("密码登录已验证成功。是否把本次 key 绑定为这台 VPS 的长期 key？", "Password authentication succeeded. Bind this key as the managed key for this VPS?"), defaultBind) {
		if err := a.promoteTemporaryConnection(c); err != nil {
			return err
		}
	} else {
		a.println(a.msg("保持临时模式：本项结束时会撤销远端一次性公钥并删除本机临时私钥。", "Remaining temporary: the one-time remote public key and local temporary private key are removed when this action ends."))
		a.conn = c
	}
	return nil
}

func (a *App) promptlessTemporaryConnection(host, user string, port int) (Connection, error) {
	dir, err := os.MkdirTemp("", sessionTempPrefix)
	if err != nil {
		return Connection{}, err
	}
	return Connection{
		Host: host, User: user, Port: port,
		KeyPath: filepath.Join(dir, "id_ed25519"), AuthMode: AuthTemporaryPassword,
		Temporary: &TemporaryAuth{Dir: dir},
	}, nil
}

func (a *App) cleanupActionTemporaryAuth() error {
	c := a.actionConnection
	a.actionConnection = nil
	return a.cleanupTemporaryConnection(c)
}

// runRemoteAction is the lifecycle wrapper for every remote action.  Each
// action still selects ordinary SSH password/key authentication independently;
// there is deliberately no local controller identity, admission gate, or
// remote operation lease in the reset line.
func (a *App) runRemoteAction(action func() error) (returnErr error) {
	a.actionConnection = nil
	defer func() {
		if cleanupErr := a.cleanupActionTemporaryAuth(); cleanupErr != nil {
			if returnErr == nil {
				returnErr = fmt.Errorf(a.msg("本项操作结束，但临时登录清理不完整：%w", "The action ended, but temporary-login cleanup was incomplete: %w"), cleanupErr)
			} else {
				a.println(a.msg("临时登录清理警告：", "Temporary-login cleanup warning:") + " " + cleanupErr.Error())
			}
		}
	}()
	returnErr = action()
	if errors.Is(returnErr, errConnectionSelectionCancelled) {
		a.println(a.msg("已取消；没有连接 VPS。", "Cancelled; no VPS connection was made."))
		return nil
	}
	return returnErr
}

func managedKeyRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".ssh", "proxy-runbook"), nil
}

func revokedKeyRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".ssh", "proxy-runbook-revoked"), nil
}

const managedKeyInfoFile = "PNA-KEY-INFO.txt"

// v0.9.5 wrote the same metadata under the old product name.  Keep it as a
// read-only fallback so an in-place upgrade can recover stable identity data.
const legacyManagedKeyInfoFile = "TNA-KEY-INFO.txt"

type managedKeyMetadata struct {
	Host             string
	User             string
	Port             int
	Status           string
	UpdatedAt        time.Time
	NodeID           string
	ServerID         string
	HostKeySHA256    string
	MachineIDHash    string
	FirstKnownPublic string
	CurrentPublic    string
	SSHAuthKeyID     string
}

type managedKeyEntry struct {
	Dir      string
	KeyPath  string
	Metadata managedKeyMetadata
	Modified time.Time
}

func encodeManagedKeyMetadata(info managedKeyMetadata) []byte {
	format := "1"
	extra := ""
	if info.NodeID != "" || info.ServerID != "" || info.HostKeySHA256 != "" || info.MachineIDHash != "" {
		format = "2"
		extra = fmt.Sprintf("NODE_ID=%s\nSERVER_ID=%s\nHOST_KEY_SHA256=%s\nMACHINE_ID_SHA256=%s\nFIRST_KNOWN_PUBLIC_IP=%s\nCURRENT_PUBLIC_IP=%s\nSSH_AUTH_KEY_ID=%s\n",
			info.NodeID, info.ServerID, info.HostKeySHA256, info.MachineIDHash, info.FirstKnownPublic, info.CurrentPublic, info.SSHAuthKeyID)
	}
	return []byte(fmt.Sprintf("FORMAT=%s\nHOST_B64=%s\nUSER_B64=%s\nPORT=%d\nSTATUS=%s\nUPDATED_AT=%s\n%s",
		format,
		base64.StdEncoding.EncodeToString([]byte(info.Host)),
		base64.StdEncoding.EncodeToString([]byte(info.User)), info.Port, info.Status,
		info.UpdatedAt.UTC().Format(time.RFC3339Nano), extra))
}

func parseManagedKeyMetadata(data []byte) (managedKeyMetadata, error) {
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "=", 2)
		if len(parts) == 2 {
			values[parts[0]] = parts[1]
		}
	}
	hostData, hostErr := base64.StdEncoding.DecodeString(values["HOST_B64"])
	userData, userErr := base64.StdEncoding.DecodeString(values["USER_B64"])
	port, portErr := strconv.Atoi(values["PORT"])
	updated, timeErr := time.Parse(time.RFC3339Nano, values["UPDATED_AT"])
	info := managedKeyMetadata{
		Host: string(hostData), User: string(userData), Port: port, Status: values["STATUS"], UpdatedAt: updated,
		NodeID: values["NODE_ID"], ServerID: values["SERVER_ID"], HostKeySHA256: values["HOST_KEY_SHA256"],
		MachineIDHash: values["MACHINE_ID_SHA256"], FirstKnownPublic: values["FIRST_KNOWN_PUBLIC_IP"], CurrentPublic: values["CURRENT_PUBLIC_IP"],
		SSHAuthKeyID: values["SSH_AUTH_KEY_ID"],
	}
	if (values["FORMAT"] != "1" && values["FORMAT"] != "2") || hostErr != nil || userErr != nil || portErr != nil || timeErr != nil ||
		!validRecentTarget(RecentTarget{Host: info.Host, User: info.User, Port: info.Port}) {
		return managedKeyMetadata{}, errors.New("invalid managed-key metadata")
	}
	if values["FORMAT"] == "2" {
		_, firstErr := canonicalPublicIPv4(info.FirstKnownPublic)
		_, currentErr := canonicalPublicIPv4(info.CurrentPublic)
		if !nodeIDPattern.MatchString(info.NodeID) || !serverIDPattern.MatchString(info.ServerID) ||
			!sha256FingerprintPattern.MatchString(info.HostKeySHA256) || !sha256HexPattern.MatchString(info.MachineIDHash) ||
			firstErr != nil || currentErr != nil || (info.SSHAuthKeyID != "" && !sha256FingerprintPattern.MatchString(info.SSHAuthKeyID)) {
			return managedKeyMetadata{}, errors.New("invalid stable node identity metadata")
		}
	}
	return info, nil
}

func writeManagedKeyMetadata(dir string, c Connection, status string) error {
	info := managedKeyMetadata{Host: c.Host, User: c.User, Port: c.Port, Status: status, UpdatedAt: time.Now().UTC()}
	if existing, err := loadManagedKeyMetadata(dir); err == nil {
		// Preserve the stable node identity while status/endpoint metadata is
		// refreshed (for example after an IP rebind or key archival).
		info.NodeID = existing.NodeID
		info.ServerID = existing.ServerID
		info.HostKeySHA256 = existing.HostKeySHA256
		info.MachineIDHash = existing.MachineIDHash
		info.FirstKnownPublic = existing.FirstKnownPublic
		info.CurrentPublic = existing.CurrentPublic
		info.SSHAuthKeyID = existing.SSHAuthKeyID
	}
	if !validRecentTarget(RecentTarget{Host: info.Host, User: info.User, Port: info.Port}) {
		return errors.New("invalid managed-key metadata target")
	}
	return os.WriteFile(filepath.Join(dir, managedKeyInfoFile), encodeManagedKeyMetadata(info), 0600)
}

func loadManagedKeyMetadata(dir string) (managedKeyMetadata, error) {
	data, err := os.ReadFile(filepath.Join(dir, managedKeyInfoFile))
	if os.IsNotExist(err) {
		data, err = os.ReadFile(filepath.Join(dir, legacyManagedKeyInfoFile))
	}
	if err != nil {
		return managedKeyMetadata{}, err
	}
	return parseManagedKeyMetadata(data)
}

func listManagedKeyEntries(root string) ([]managedKeyEntry, error) {
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return []managedKeyEntry{}, nil
	}
	if err != nil {
		return nil, err
	}
	result := []managedKeyEntry{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(root, entry.Name())
		keyPath := filepath.Join(dir, "id_ed25519")
		if !fileExists(keyPath) || !fileExists(keyPath+".pub") {
			continue
		}
		modified := time.Time{}
		if stat, statErr := os.Stat(keyPath); statErr == nil {
			modified = stat.ModTime()
		}
		metadata, _ := loadManagedKeyMetadata(dir)
		result = append(result, managedKeyEntry{Dir: dir, KeyPath: keyPath, Metadata: metadata, Modified: modified})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Modified.After(result[j].Modified) })
	return result, nil
}

func listManagedKeyDirectories(root string) ([]string, error) {
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	result := []string{}
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".restore-") {
			result = append(result, filepath.Join(root, entry.Name()))
		}
	}
	sort.Strings(result)
	return result, nil
}

func validatePrivatePublicKeyPair(keyPath string) error {
	if !fileExists(keyPath) || !fileExists(keyPath+".pub") {
		return errors.New("private/public key pair is incomplete")
	}
	derived := runCaptured("ssh-keygen.exe", []string{"-y", "-f", keyPath}, nil, true)
	if !derived.OK() {
		return fmt.Errorf("private-key validation failed: %s", processFailureDetail(derived))
	}
	publicKey, err := readPublicKey(keyPath)
	if err != nil {
		return err
	}
	derivedFields := strings.Fields(strings.TrimSpace(derived.Stdout))
	publicFields := strings.Fields(publicKey)
	if len(derivedFields) < 2 || len(publicFields) < 2 || derivedFields[0] != publicFields[0] || derivedFields[1] != publicFields[1] {
		return errors.New("private key does not match the saved public key")
	}
	return nil
}

func (a *App) printManagedKeyEntries(entries []managedKeyEntry, backups bool) {
	if len(entries) == 0 {
		a.println(a.msg("没有找到完整的 key 对。", "No complete key pairs were found."))
		return
	}
	for index, entry := range entries {
		label := filepath.Base(entry.Dir)
		if entry.Metadata.Host != "" {
			label = fmt.Sprintf("%s@%s:%d", entry.Metadata.User, entry.Metadata.Host, entry.Metadata.Port)
		}
		a.println(fmt.Sprintf("[%d] %s", index+1, label))
		a.println(a.msg("    私钥：", "    Private key:") + " " + entry.KeyPath)
		a.println(a.msg("    公钥：", "    Public key:") + " " + entry.KeyPath + ".pub")
		if backups {
			a.println(a.msg("    备份目录：", "    Backup folder:") + " " + entry.Dir)
			if entry.Metadata.Status != "" {
				a.println(a.msg("    状态：", "    Status:") + " " + entry.Metadata.Status)
			}
		}
	}
}

func moveManagedKeyDirectoryToBackup(keyPath string, when time.Time) (string, error) {
	root, err := managedKeyRoot()
	if err != nil {
		return "", err
	}
	backupRoot, err := revokedKeyRoot()
	if err != nil {
		return "", err
	}
	return moveManagedKeyDirectoryToBackupAtRoots(keyPath, when, root, backupRoot)
}

func moveManagedKeyDirectoryToBackupAtRoots(keyPath string, when time.Time, root, backupRoot string) (string, error) {
	root = filepath.Clean(root)
	backupRoot = filepath.Clean(backupRoot)
	dir := filepath.Clean(filepath.Dir(keyPath))
	if filepath.Base(keyPath) != "id_ed25519" {
		return "", fmt.Errorf("refused unexpected managed key filename: %s", keyPath)
	}
	relative, err := filepath.Rel(root, dir)
	if err != nil || relative == "." || relative == ".." || filepath.IsAbs(relative) || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) || strings.Contains(relative, string(os.PathSeparator)) {
		return "", fmt.Errorf("refused key directory outside the managed-key root: %s", dir)
	}
	if err := os.MkdirAll(backupRoot, 0700); err != nil {
		return "", err
	}
	destination := filepath.Join(backupRoot, filepath.Base(dir)+"-"+when.Format("20060102-150405"))
	if _, err := os.Stat(destination); err == nil {
		return "", fmt.Errorf("recoverable backup destination already exists: %s", destination)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.Rename(dir, destination); err != nil {
		return "", err
	}
	return destination, nil
}

func sameConnectionTarget(left, right *Connection) bool {
	return left != nil && right != nil && strings.EqualFold(left.Host, right.Host) && left.User == right.User && left.Port == right.Port
}

func (a *App) unbindManagedKey() error {
	if err := a.ensureOpenSSH(); err != nil {
		return err
	}
	a.println(a.msg("请输入要解绑的 VPS。只会处理由本工具按 VPS + 用户保存的长期 key。", "Enter the VPS to unbind. Only a managed key stored by this tool for that VPS + user is affected."))
	c, err := a.promptConnection(AuthManagedKey)
	if err != nil {
		return err
	}
	if !fileExists(c.KeyPath) || !fileExists(c.KeyPath+".pub") {
		return fmt.Errorf(a.msg("没有找到该目标的已绑定 key：%s", "No bound key was found for this target: %s"), c.KeyPath)
	}
	if !tcpReachable(c.Host, c.Port) {
		return errors.New(a.msg("SSH TCP 不可达。为避免只删本机却把远端公钥遗留，本次不执行解绑。", "SSH TCP is unreachable. Unbinding is refused so the remote public key is not left behind while only the local key disappears."))
	}
	if err := a.ensureHostKey(c); err != nil {
		return err
	}
	verified := verifyKey(c, c.KeyPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		return fmt.Errorf(a.msg("已绑定 key 无法登录，不能确认远端撤销；本机文件保持不动：%s", "The bound key cannot log in, so remote revocation cannot be confirmed; local files were left untouched: %s"), processFailureDetail(verified))
	}
	publicKey, err := readPublicKey(c.KeyPath)
	if err != nil {
		return err
	}
	a.println(a.msg("将从远端 authorized_keys 精确删除这一条公钥，然后把本机整套 key/known_hosts 移入可恢复备份。", "The exact public-key line will be removed remotely, then the local key set and known_hosts will be moved into a recoverable backup."))
	a.println(a.msg("本机 key：", "Local key:") + " " + c.KeyPath)
	if backupRoot, rootErr := revokedKeyRoot(); rootErr == nil {
		a.println(a.msg("可恢复备份总目录：", "Recoverable-backup root:") + " " + backupRoot)
	}
	if a.prompt(a.msg("确认请输入大写 UNBIND；其他输入取消", "Type uppercase UNBIND to confirm; anything else cancels")) != "UNBIND" {
		a.println(a.msg("已取消；远端和本机均未修改。", "Cancelled; neither remote nor local state was changed."))
		return nil
	}
	result := a.sshCapture(c, authorizedKeyRemovalCommand(publicKey, "MANAGED_SSH_KEY_REMOVED"))
	if !result.OK() || !strings.Contains(result.Stdout, "MANAGED_SSH_KEY_REMOVED") {
		return fmt.Errorf(a.msg("远端公钥撤销未确认（退出码 %d）；本机 key 保持不动：%s", "Remote key revocation was not confirmed (exit %d); the local key was left untouched: %s"), result.ExitCode, processFailureDetail(result))
	}
	backupPath, err := moveManagedKeyDirectoryToBackup(c.KeyPath, time.Now())
	if err != nil {
		return fmt.Errorf(a.msg("远端公钥已撤销，但本机 key 移入可恢复备份失败；请立刻手工保护该目录：%w", "The remote key was revoked, but moving the local key into a recoverable backup failed; protect the directory manually now: %w"), err)
	}
	if err := writeManagedKeyMetadata(backupPath, c, "REVOKED_REMOTE_KEY"); err != nil {
		a.println(a.msg("[WARN] 备份已保留，但节点说明文件写入失败；恢复时需要手工选择目标：", "[WARN] The backup was retained, but its node metadata could not be written; restoration will require manual target selection:") + " " + err.Error())
	}
	if sameConnectionTarget(a.conn, &c) {
		a.conn = nil
	}
	a.killTunnels()
	a.println(a.msg("解绑完成。远端公钥已精确撤销；本机文件没有销毁，已移到：", "Unbinding completed. The remote public key was revoked exactly; local files were preserved at:") + " " + backupPath)
	return nil
}

func (a *App) listBoundKeys() error {
	root, err := managedKeyRoot()
	if err != nil {
		return err
	}
	entries, err := listManagedKeyEntries(root)
	if err != nil {
		return err
	}
	a.println(a.msg("已绑定 key 总目录：", "Bound-key root:") + " " + root)
	a.printManagedKeyEntries(entries, false)
	return nil
}

func (a *App) listRecoverableKeyBackups() error {
	root, err := revokedKeyRoot()
	if err != nil {
		return err
	}
	entries, err := listManagedKeyEntries(root)
	if err != nil {
		return err
	}
	a.println(a.msg("可恢复备份总目录：", "Recoverable-backup root:") + " " + root)
	a.printManagedKeyEntries(entries, true)
	return nil
}

func (a *App) archiveAllManagedKeys() error {
	activeRoot, err := managedKeyRoot()
	if err != nil {
		return err
	}
	backupRoot, err := revokedKeyRoot()
	if err != nil {
		return err
	}
	directories, err := listManagedKeyDirectories(activeRoot)
	if err != nil {
		return err
	}
	a.println(a.msg("此操作不登录任何 VPS：会把已绑定目录中的所有节点 key/known_hosts 移入本机备份态，并让绑定目录变空。远端 authorized_keys 中的公钥保持不动。", "This does not log in to any VPS. Every node key/known_hosts directory is moved into local backup state, leaving the bound-key directory empty. Remote authorized_keys entries are retained."))
	a.println(a.msg("已绑定 key 总目录：", "Bound-key root:") + " " + activeRoot)
	a.println(a.msg("目标备份总目录：", "Destination backup root:") + " " + backupRoot)
	if len(directories) == 0 {
		a.println(a.msg("绑定目录已经为空；没有需要转入备份态的节点。", "The bound-key directory is already empty; nothing needs to be archived."))
		return nil
	}
	for _, dir := range directories {
		a.println("  - " + dir)
	}
	if !a.yes(a.msg("确认把以上全部目录转入本机备份态？", "Move every directory above into local backup state?"), false) {
		a.println(a.msg("已取消；绑定目录和备份目录均未修改。", "Cancelled; neither the bound-key nor backup directory was changed."))
		return nil
	}
	a.killTunnels()
	a.conn = nil
	a.actionConnection = nil
	when := time.Now()
	moved := 0
	failures := []string{}
	warnings := []string{}
	for _, dir := range directories {
		metadata, metadataErr := loadManagedKeyMetadata(dir)
		destination, moveErr := moveManagedKeyDirectoryToBackup(filepath.Join(dir, "id_ed25519"), when)
		if moveErr != nil {
			failures = append(failures, filepath.Base(dir)+": "+moveErr.Error())
			continue
		}
		moved++
		if metadataErr == nil {
			c := Connection{Host: metadata.Host, User: metadata.User, Port: metadata.Port}
			if metadataWriteErr := writeManagedKeyMetadata(destination, c, "LOCAL_ARCHIVED_REMOTE_KEY_RETAINED"); metadataWriteErr != nil {
				warnings = append(warnings, filepath.Base(dir)+" metadata: "+metadataWriteErr.Error())
			}
		} else {
			warnings = append(warnings, filepath.Base(dir)+": no valid target metadata")
		}
		a.println(a.msg("已转入备份态：", "Archived locally:") + " " + destination)
	}
	if len(failures) > 0 {
		a.println(fmt.Sprintf(a.msg("批量归档部分完成：%d 个目录已移入备份；失败目录仍留在原绑定位置。", "Bulk archive partially completed: %d directories were archived; failed directories remain in their original bound positions."), moved))
		return fmt.Errorf(a.msg("部分目录移动失败：%s", "Some directory moves failed: %s"), strings.Join(failures, " | "))
	}
	a.println(fmt.Sprintf(a.msg("批量归档完成：%d 个绑定目录已移出；绑定位置保持为空，不会自动填充。", "Bulk archive completed: %d bound directories were moved out; bound locations remain empty and are not auto-populated."), moved))
	if len(warnings) > 0 {
		a.println(a.msg("[WARN] 部分旧目录没有可更新的节点说明；恢复时需要手工选择目标：", "[WARN] Some legacy directories lack updatable node metadata; their target must be selected manually during restore:") + " " + strings.Join(warnings, " | "))
	}
	return nil
}

func restoreManagedKeyFiles(entry managedKeyEntry, c Connection, sourceKnownHosts string) (string, error) {
	root, err := managedKeyRoot()
	if err != nil {
		return "", err
	}
	destinationKey, err := defaultKeyPath(c.Host, c.User)
	if err != nil {
		return "", err
	}
	destinationDir := filepath.Dir(destinationKey)
	if fileExists(destinationKey) || fileExists(destinationKey+".pub") {
		return "", fmt.Errorf("managed-key destination already exists: %s", destinationDir)
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	stage, err := os.MkdirTemp(root, ".restore-")
	if err != nil {
		return "", err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(stage)
		}
	}()
	if err := copyFileExclusive(entry.KeyPath, filepath.Join(stage, "id_ed25519"), 0600); err != nil {
		return "", err
	}
	if err := copyFileExclusive(entry.KeyPath+".pub", filepath.Join(stage, "id_ed25519.pub"), 0600); err != nil {
		return "", err
	}
	if err := copyFileExclusive(sourceKnownHosts, filepath.Join(stage, "known_hosts"), 0600); err != nil {
		return "", err
	}
	if err := writeManagedKeyMetadata(stage, c, "BOUND_RESTORED"); err != nil {
		return "", err
	}
	if _, err := os.Stat(destinationDir); err == nil {
		return "", fmt.Errorf("managed-key directory already exists: %s", destinationDir)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.Rename(stage, destinationDir); err != nil {
		return "", err
	}
	complete = true
	return destinationKey, nil
}

func (a *App) restoreManagedKeyBackup() (returnErr error) {
	if err := a.ensureOpenSSH(); err != nil {
		return err
	}
	root, err := revokedKeyRoot()
	if err != nil {
		return err
	}
	entries, err := listManagedKeyEntries(root)
	if err != nil {
		return err
	}
	a.println(a.msg("选择要恢复的备份。原备份目录会继续保留，恢复成功后会把可用副本放回已绑定 key 目录。", "Choose a backup to restore. The backup folder is retained; after verification, a working copy is placed back into the bound-key directory."))
	a.println(a.msg("可恢复备份总目录：", "Recoverable-backup root:") + " " + root)
	a.printManagedKeyEntries(entries, true)
	if len(entries) == 0 {
		return nil
	}
	index, parseErr := strconv.Atoi(strings.TrimSpace(a.prompt(a.msg("输入备份编号；0 取消", "Enter backup number; 0 cancels"))))
	if parseErr != nil || index < 0 || index > len(entries) {
		return errors.New(a.msg("备份编号无效；没有修改任何 key。", "Invalid backup number; no key was changed."))
	}
	if index == 0 {
		return nil
	}
	entry := entries[index-1]
	if err := validatePrivatePublicKeyPair(entry.KeyPath); err != nil {
		return fmt.Errorf(a.msg("备份 key 对校验失败；没有连接 VPS：%w", "The backup key pair failed validation; no VPS connection was made: %w"), err)
	}
	var host, user string
	var port int
	if entry.Metadata.Host != "" {
		a.println(fmt.Sprintf(a.msg("备份记录的目标：%s@%s:%d", "Target recorded in backup: %s@%s:%d"), entry.Metadata.User, entry.Metadata.Host, entry.Metadata.Port))
		if a.yes(a.msg("使用这个目标恢复？", "Restore to this target?"), true) {
			host, user, port = entry.Metadata.Host, entry.Metadata.User, entry.Metadata.Port
		}
	}
	if host == "" {
		host, user, port, err = a.chooseConnectionDetails()
		if err != nil {
			return err
		}
	}
	if err := rememberRecentTarget(RecentTarget{Host: host, User: user, Port: port}); err != nil {
		a.println(a.msg("[WARN] 无法更新 VPS 登录历史：", "[WARN] Could not update VPS login history:") + " " + err.Error())
	}
	managedPath, err := defaultKeyPath(host, user)
	if err != nil {
		return err
	}
	if fileExists(managedPath) || fileExists(managedPath+".pub") {
		return fmt.Errorf(a.msg("目标已有长期 key，拒绝覆盖：%s", "A managed key already exists for this target; refusing to overwrite: %s"), managedPath)
	}
	backupConnection := Connection{Host: host, User: user, Port: port, KeyPath: entry.KeyPath, AuthMode: AuthManagedKey}
	if fileExists(knownHostsPath(backupConnection)) {
		direct := verifyKey(backupConnection, entry.KeyPath)
		if direct.OK() && strings.TrimSpace(direct.Stdout) == "SSH_KEY_OK" {
			a.println(a.msg("备份公钥仍在 VPS 上有效；无需输入密码，直接恢复本机绑定位置并做最终验证。", "The backup public key is still valid on the VPS; restoring the local bound position without a password, followed by final verification."))
			restoredPath, restoreErr := restoreManagedKeyFiles(entry, Connection{Host: host, User: user, Port: port}, knownHostsPath(backupConnection))
			if restoreErr != nil {
				return restoreErr
			}
			restored := Connection{Host: host, User: user, Port: port, KeyPath: restoredPath, AuthMode: AuthManagedKey}
			verified := verifyKey(restored, restoredPath)
			if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
				_ = os.RemoveAll(filepath.Dir(restoredPath))
				return fmt.Errorf("directly restored managed key failed final verification: %s", processFailureDetail(verified))
			}
			_ = writeManagedKeyMetadata(entry.Dir, restored, "RESTORED_COPY_RETAINED")
			a.conn = &restored
			a.println(a.msg("恢复成功：绑定位置已经重新建立，原备份仍保留。", "Restore succeeded: the bound position was recreated and the original backup was retained."))
			a.println(a.msg("当前长期私钥：", "Active managed private key:") + " " + restoredPath)
			a.println(a.msg("仍保留的恢复源备份：", "Retained source backup:") + " " + entry.Dir)
			return nil
		}
		a.println(a.msg("备份 key 不能直接登录；可能已从远端撤销。下面改用一次临时密码会话重新绑定。", "The backup key cannot log in directly and may have been revoked remotely. Falling back to one temporary password session for rebinding."))
	}
	temporary, err := a.promptlessTemporaryConnection(host, user, port)
	if err != nil {
		return err
	}
	defer func() {
		if cleanupErr := a.cleanupTemporaryConnection(&temporary); cleanupErr != nil {
			a.println(a.msg("[WARN] 恢复流程已结束，但一次性登录清理不完整：", "[WARN] Restoration finished, but one-time login cleanup was incomplete:") + " " + cleanupErr.Error())
			if returnErr == nil {
				returnErr = cleanupErr
			}
		}
	}()
	if err := a.prepareTemporaryPasswordAuth(&temporary); err != nil {
		return err
	}
	a.println(a.msg("备份 key 对已在本机匹配校验。现在把备份公钥重新安装到 VPS，并用备份私钥实测登录。", "The backup key pair matches locally. Its public key will now be reinstalled on the VPS and the private key will be tested."))
	if err := a.installPublicKey(temporary, entry.KeyPath, temporary.KeyPath, nil); err != nil {
		return err
	}
	backupPublicKey, _ := readPublicKey(entry.KeyPath)
	restoredPath, err := restoreManagedKeyFiles(entry, Connection{Host: host, User: user, Port: port}, knownHostsPath(temporary))
	if err != nil {
		_ = a.sshCapture(temporary, authorizedKeyRemovalCommand(backupPublicKey, "RESTORE_ROLLBACK_KEY_REMOVED"))
		return fmt.Errorf("local restore failed after remote key install: %w", err)
	}
	restored := Connection{Host: host, User: user, Port: port, KeyPath: restoredPath, AuthMode: AuthManagedKey}
	verified := verifyKey(restored, restoredPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		_ = a.sshCapture(temporary, authorizedKeyRemovalCommand(backupPublicKey, "RESTORE_ROLLBACK_KEY_REMOVED"))
		_ = os.RemoveAll(filepath.Dir(restoredPath))
		return fmt.Errorf("restored managed key failed final verification: %s", processFailureDetail(verified))
	}
	_ = writeManagedKeyMetadata(entry.Dir, restored, "RESTORED_COPY_RETAINED")
	a.conn = &restored
	a.println(a.msg("恢复成功：备份公钥已重新绑定，长期私钥已验证可登录。", "Restore succeeded: the backup public key was rebound and the managed private key was verified."))
	a.println(a.msg("当前长期私钥：", "Active managed private key:") + " " + restoredPath)
	a.println(a.msg("仍保留的恢复源备份：", "Retained source backup:") + " " + entry.Dir)
	return nil
}

func (a *App) openManagedKeyFolders() error {
	activeRoot, err := managedKeyRoot()
	if err != nil {
		return err
	}
	backupRoot, err := revokedKeyRoot()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(activeRoot, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(backupRoot, 0700); err != nil {
		return err
	}
	a.println(a.msg("已绑定 key 总目录：", "Bound-key root:") + " " + activeRoot)
	a.println(a.msg("可恢复备份总目录：", "Recoverable-backup root:") + " " + backupRoot)
	for _, path := range []string{activeRoot, backupRoot} {
		if err := openDirectory(path); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) manageBoundKeys() error {
	a.println(a.msg("绑定 key 管理：", "Bound-key management:"))
	a.println(a.msg("[1] 查看全部已绑定 key 和准确路径", "[1] List every bound key and its exact path"))
	a.println(a.msg("[2] 解绑指定 VPS：远端撤销公钥，本机 key 移入可恢复备份", "[2] Unbind a VPS: revoke remotely and move the local key into a recoverable backup"))
	a.println(a.msg("[3] 查看可恢复备份和准确路径", "[3] List recoverable backups and exact paths"))
	a.println(a.msg("[4] 从备份恢复并重新绑定：校验 key 对，密码登录一次，实测后生效", "[4] Restore and rebind: validate the pair, authenticate once by password, then verify"))
	a.println(a.msg("[5] 在资源管理器打开已绑定 key 与备份目录", "[5] Open bound-key and backup folders in Explorer"))
	a.println(a.msg("[6] 全部转入本机备份态：清空所有绑定位置，不自动填充（不登录 VPS）", "[6] Archive all locally: empty every bound position without auto-fill (no VPS login)"))
	a.println(a.msg("[7] 切换 VPS：清空当前选择与隧道，不删除 key", "[7] Switch VPS: clear current selection and tunnels without deleting keys"))
	a.println(a.msg("[0] 取消", "[0] Cancel"))
	switch strings.ToLower(strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))) {
	case "1":
		return a.listBoundKeys()
	case "2":
		return a.unbindManagedKey()
	case "3":
		return a.listRecoverableKeyBackups()
	case "4":
		return a.restoreManagedKeyBackup()
	case "5":
		return a.openManagedKeyFolders()
	case "6":
		return a.archiveAllManagedKeys()
	case "7":
		a.killTunnels()
		a.conn = nil
		a.actionConnection = nil
		a.println(a.msg("已清空当前选择。下一项操作会重新询问登录模式、VPS、用户和端口；其他 VPS 的绑定互不影响。", "The current selection was cleared. The next action asks again for login mode, VPS, user, and port; bindings for different VPS targets are independent."))
		return nil
	case "0", "":
		a.println(a.msg("已取消。", "Cancelled."))
		return nil
	default:
		return errors.New(a.msg("无效选择；没有修改任何 key。", "Invalid choice; no key was changed."))
	}
}

func (a *App) showKeyHandoff(keyPath, heading string) error {
	privateData, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	publicData, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		return err
	}
	block := fmt.Sprintf("SSH_PRIVATE_KEY_FILE=%s\nSSH_PUBLIC_KEY_FILE=%s.pub\n\n--- REAL SSH PRIVATE KEY ---\n%s\n--- REAL SSH PUBLIC KEY ---\n%s", keyPath, keyPath, strings.TrimSpace(string(privateData)), strings.TrimSpace(string(publicData)))
	return a.secretHandoff(heading, block)
}

func (a *App) ensureKey(c Connection) error {
	if err := a.ensureHostKey(c); err != nil {
		return err
	}
	if !fileExists(c.KeyPath) || !fileExists(c.KeyPath+".pub") {
		return errors.New(a.msg("长期 key 文件不完整；本次不会覆盖。请用 [K] 检查/解绑旧目录，再选择密码模式重新绑定。", "The managed key files are incomplete and will not be overwritten. Use [K] to inspect/unbind the old directory, then select password mode and bind again."))
	}
	verified := verifyKey(c, c.KeyPath)
	if verified.OK() && strings.TrimSpace(verified.Stdout) == "SSH_KEY_OK" {
		if err := writeManagedKeyMetadata(filepath.Dir(c.KeyPath), c, "BOUND"); err != nil {
			a.println(a.msg("[WARN] key 可用，但无法更新本机节点说明文件：", "[WARN] The key works, but its local node metadata could not be updated:") + " " + err.Error())
		}
		a.println(a.msg("SSH_KEY_OK：已使用这台 VPS 专属的长期 key。", "SSH_KEY_OK: the managed key for this VPS was used."))
		return nil
	}
	return errors.New(a.msg("本机已有 SSH key，但当前节点验证失败；请改选临时密码，或用 [K] 解绑后重新绑定。旧 key 不会被覆盖。", "A local SSH key exists but does not verify; choose temporary password, or unbind it with [K] and bind again. The old key will not be overwritten."))
}

func (a *App) readyConn() (Connection, error) {
	if err := a.ensureOpenSSH(); err != nil {
		return Connection{}, err
	}
	c, err := a.getActionConnection()
	if err != nil {
		return Connection{}, err
	}
	if !tcpReachable(c.Host, c.Port) {
		return Connection{}, fmt.Errorf(a.msg("SSH 未就绪：无法连接 %s:%d", "SSH is not ready: cannot reach %s:%d"), c.Host, c.Port)
	}
	if err := a.authenticateActionConnection(c); err != nil {
		return Connection{}, err
	}
	return *c, nil
}

// remoteToolkitProbeCommand is kept separate from the SSH call so the
// completeness contract can be unit-tested without a live VPS.  The command
// is read-only: it selects the first known current/legacy root, reads marker
// files, and checks every script/data file required by the v1 menus.
func remoteToolkitProbeCommand() string {
	command := "printf '%s\\n' " + shQuote(toolkitBegin) + "; " +
		"probe_root=" + shQuote(remoteRoot) + "; " +
		"[ -r \"$probe_root/TOOLKIT_VERSION\" ] || probe_root=" + shQuote(legacyTextRemoteRoot) + "; " +
		"[ -r \"$probe_root/TOOLKIT_VERSION\" ] || probe_root=" + shQuote(legacyRunbookRemoteRoot) + "; " +
		"if [ -r \"$probe_root/TOOLKIT_VERSION\" ]; then " +
		"version=''; IFS= read -r version < \"$probe_root/TOOLKIT_VERSION\" || true; version=${version%$'\\r'}; " +
		"build=''; if [ -r \"$probe_root/TOOLKIT_BUILD_ID\" ]; then IFS= read -r build < \"$probe_root/TOOLKIT_BUILD_ID\" || true; build=${build%$'\\r'}; fi; " +
		"revision=''; if [ -r \"$probe_root/TOOLKIT_BUILD_REVISION\" ]; then IFS= read -r revision < \"$probe_root/TOOLKIT_BUILD_REVISION\" || true; revision=${revision%$'\\r'}; fi; " +
		// Keep this list aligned with the scripts called by the desktop menus
		// and by 00-auto-install-or-optimize.sh.  A version file alone is not a
		// usable toolkit: treating a partial upload as complete is what strands
		// in-place upgrades on the legacy root.  Drive/device-admission helpers
		// are intentionally absent from the v1 reset line and therefore are not
		// completeness requirements.
		"complete=0; test -s \"$probe_root/THIRD_PARTY_LOCK.env\" && test -x \"$probe_root/linux/00-bootstrap-toolkit.sh\" && test -x \"$probe_root/linux/00-preflight-vps.sh\" && test -x \"$probe_root/linux/00-migrate-legacy-state.sh\" && test -x \"$probe_root/linux/00-auto-install-or-optimize.sh\" && test -x \"$probe_root/linux/00c-retire-v095-device-drive.sh\" && test -x \"$probe_root/linux/01-safe-backup.sh\" && test -x \"$probe_root/linux/01a-rotate-vps-password.sh\" && test -x \"$probe_root/linux/02-install-base.sh\" && test -x \"$probe_root/linux/02b-firewall-safe.sh\" && test -x \"$probe_root/linux/03-install-3xui.sh\" && test -x \"$probe_root/linux/03b-lockdown-panel.sh\" && test -x \"$probe_root/linux/03c-rotate-panel-credentials.sh\" && test -x \"$probe_root/linux/03d-export-panel-handoff.sh\" && test -x \"$probe_root/linux/04-generate-reality.sh\" && test -x \"$probe_root/linux/04a-reality-api.sh\" && test -x \"$probe_root/linux/04b-open-test-port-current-ssh.sh\" && test -x \"$probe_root/linux/04c-close-test-port.sh\" && test -x \"$probe_root/linux/04d-optimize-existing-reality-shadow.sh\" && test -x \"$probe_root/linux/04e-export-reality-handoff.sh\" && test -x \"$probe_root/linux/04f-xhttp-cdn-api.sh\" && test -x \"$probe_root/linux/05-cover-bootstrap.sh\" && test -x \"$probe_root/linux/05a-cloudflare-dns-upsert.sh\" && test -x \"$probe_root/linux/05b-cover-site-polished.sh\" && test -x \"$probe_root/linux/05c-optimize-cover-backend.sh\" && test -x \"$probe_root/linux/05d-configure-subscription.sh\" && test -x \"$probe_root/linux/05e-cdn-xhttp-nginx.sh\" && test -x \"$probe_root/linux/05f-cloudflare-origin-lock.sh\" && test -x \"$probe_root/linux/05g-cdn-xhttp-validate.sh\" && test -x \"$probe_root/linux/05h-ensure-cdn-certificate.sh\" && test -x \"$probe_root/linux/06-warp-install.sh\" && test -x \"$probe_root/linux/07-warp-configure-proxy.sh\" && test -x \"$probe_root/linux/07a-apply-warp-route-local.sh\" && test -x \"$probe_root/linux/08-warp-check.sh\" && test -x \"$probe_root/linux/09-status-node.sh\" && test -x \"$probe_root/linux/10-emergency-network-dump.sh\" && test -x \"$probe_root/linux/11-safe-upgrade-audit.sh\" && test -x \"$probe_root/linux/12-restore-iptables-vnc-only.sh\" && test -x \"$probe_root/linux/13-maintenance-menu.sh\" && test -x \"$probe_root/linux/14-node-doctor.sh\" && test -x \"$probe_root/linux/15-show-current-node.sh\" && test -x \"$probe_root/linux/16-auto-diagnose.sh\" && test -x \"$probe_root/linux/17-safe-auto-repair.sh\" && test -x \"$probe_root/linux/18-panel-metadata.sh\" && test -x \"$probe_root/linux/19-prune-backups-current-config.sh\" && test -x \"$probe_root/linux/20-adaptive-performance.sh\" && test -x \"$probe_root/linux/21-traffic-status.sh\" && test -x \"$probe_root/linux/22-dismantle-managed-node.sh\" && test -x \"$probe_root/linux/23-node-identity.sh\" && test -x \"$probe_root/linux/23-ss2022-tcp.sh\" && test -x \"$probe_root/linux/24-security-baseline.sh\" && test -x \"$probe_root/linux/25-security-events.sh\" && test -x \"$probe_root/linux/27-ip-rebind.sh\" && test -x \"$probe_root/linux/28-topology-reconcile.sh\" && test -x \"$probe_root/linux/28a-install-transaction.sh\" && test -x \"$probe_root/linux/lib-deployment-state.sh\" && test -x \"$probe_root/linux/lib-dns-quorum.sh\" && test -x \"$probe_root/linux/lib-gui-prompt.sh\" && test -x \"$probe_root/linux/lib-handoff.sh\" && test -x \"$probe_root/linux/lib-third-party.sh\" && test -x \"$probe_root/linux/lib-xui-api.sh\" && test -s \"$probe_root/linux/32-subscription-rewrite.py\" && test -s \"$probe_root/templates/cover-sites/MANIFEST.tsv\" && test -s \"$probe_root/templates/cover-sites/15-signal-runner.html\" && test -s \"$probe_root/TOOLKIT_BUILD_ID\" && test -s \"$probe_root/TOOLKIT_BUILD_REVISION\" && complete=1; " +
		"printf 'TOOLKIT_PRESENT=1\\nTOOLKIT_VERSION=%s\\nTOOLKIT_BUILD_ID=%s\\nTOOLKIT_BUILD_REVISION=%s\\nTOOLKIT_COMPLETE=%s\\n' \"$version\" \"$build\" \"$revision\" \"$complete\"; " +
		"else printf 'TOOLKIT_PRESENT=0\\n'; fi; " +
		"printf '%s\\n' " + shQuote(toolkitEnd)
	return command
}

func (a *App) remoteToolkitProbe(c Connection) (ToolkitProbe, error) {
	command := remoteToolkitProbeCommand()
	result := a.rootCapture(c, command)
	if !result.OK() {
		return ToolkitProbe{}, fmt.Errorf("toolkit version probe failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parseToolkitProbe(result.Stdout)
}

// remoteCredentialReadinessCommand performs a read-only, secret-free scan of
// the protected login handoff. It emits presence bits only; passwords never
// cross the SSH stdout channel during this preflight. The full installer later
// reads the root-only store and verifies the preserve choice, so a stale
// handoff can never silently be accepted.
func remoteCredentialReadinessCommand() string {
	command := "printf '%s\\n' " + shQuote(credentialReadinessBegin) + `
# The probe must work before the v1 package is uploaded.  A v0.9.0 toolkit
# has a lib-handoff.sh, but it does not have credential_value_from_file or
# handoff_all_candidate_files; sourcing it and calling those newer helpers
# would silently report every existing credential as absent.  Keep this
# scanner self-contained and read-only so old and new toolkits share the same
# detection contract.
credential_value_present() {
  local file="$1" wanted="$2"
  awk -v wanted="$wanted" '
    function matches(candidate) {
      if (wanted == "VPS_LOGIN_USER")
        return candidate == "VPS_LOGIN_USER" || candidate == "VPS_ACCOUNT" || candidate == "FORM_VPS_ACCOUNT"
      if (wanted == "VPS_LOGIN_PASSWORD")
        return candidate == "VPS_LOGIN_PASSWORD" || candidate == "VPS_PASSWORD" || candidate == "FORM_VPS_PASSWORD"
      if (wanted == "PANEL_USERNAME")
        return candidate == "PANEL_USERNAME" || candidate == "PANEL_ACCOUNT" || candidate == "XUI_USERNAME" || candidate == "FORM_PANEL_ACCOUNT"
      if (wanted == "PANEL_PASSWORD")
        return candidate == "PANEL_PASSWORD" || candidate == "XUI_PASSWORD" || candidate == "FORM_PANEL_PASSWORD"
      return candidate == wanted
    }
    {
      separator=index($0, "=")
      if (separator <= 0) next
      name=substr($0, 1, separator-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (!matches(name)) next
      value=substr($0, separator+1)
      # Check a trimmed probe so an all-whitespace field cannot make the
      # read-only readiness result look complete.  The probe emits only a
      # presence bit, so preserving edge spaces in the eventual handoff is
      # left to the full credential parser.
      probe=value
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", probe)
      upper=toupper(probe)
      if (probe != "" && upper !~ /^(UNKNOWN|NOT_RETAINED|SSH_KEY_ONLY)/) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$file" >/dev/null 2>&1
}

credential_candidate_files() {
  local dir
  # These are the only handoff roots used by the reset line and the v0.9.x
  # compatibility line.  Keep the protected stores first, then current files,
  # then newest archives.  Paths are consumed internally and never printed in
  # the readiness payload.
  for dir in /root/.config/proxy-runbook /root/.config/text-node-assistant /root/.config/proxy-node-assistant; do
    printf '%s\n' "$dir/CURRENT-LOGIN-CREDENTIALS.env" "$dir/HANDOFF-SECRETS.txt"
    if [ -d "$dir/handoff-archive" ]; then
      find "$dir/handoff-archive" -maxdepth 1 -type f -name 'HANDOFF-*.txt' \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | while IFS= read -r entry; do
          printf '%s\n' "${entry#* }"
        done
    fi
  done
}

value_present() {
  local key="$1" file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -r "$file" ] || continue
    if credential_value_present "$file" "$key"; then
      return 0
    fi
  done < <(credential_candidate_files)
  return 1
}
vps_user=0; vps_password=0; panel_user=0; panel_password=0
value_present VPS_LOGIN_USER && vps_user=1 || true
value_present VPS_LOGIN_PASSWORD && vps_password=1 || true
value_present PANEL_USERNAME && panel_user=1 || true
value_present PANEL_PASSWORD && panel_password=1 || true
complete=0
if [ "$vps_user" = 1 ] && [ "$vps_password" = 1 ] && [ "$panel_user" = 1 ] && [ "$panel_password" = 1 ]; then complete=1; fi
source_name=unavailable
if [ "$complete" = 1 ] || [ "$vps_user" = 1 ] || [ "$vps_password" = 1 ] || [ "$panel_user" = 1 ] || [ "$panel_password" = 1 ]; then
  source_name=handoff
fi
printf 'VPS_LOGIN_USER_PRESENT=%s\nVPS_LOGIN_PASSWORD_PRESENT=%s\nPANEL_USERNAME_PRESENT=%s\nPANEL_PASSWORD_PRESENT=%s\nCOMPLETE=%s\nSOURCE=%s\n' "$vps_user" "$vps_password" "$panel_user" "$panel_password" "$complete" "$source_name"
` + "printf '%s\\n' " + shQuote(credentialReadinessEnd) + "\n"
	return command
}

// remoteCredentialReadiness is intentionally best-effort. A missing or
// legacy handoff leaves the install form usable with an explicit policy
// choice; only a validated complete block enables the convenient
// Enter=preserve default.
func (a *App) remoteCredentialReadiness(c Connection) (CredentialReadiness, error) {
	result := a.rootCapture(c, remoteCredentialReadinessCommand())
	if !result.OK() {
		return CredentialReadiness{}, fmt.Errorf("credential readiness probe failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parseCredentialReadiness(result.Stdout)
}

func (a *App) toolkitInstalled(c Connection) bool {
	probe, err := a.remoteToolkitProbe(c)
	if err != nil {
		return false
	}
	relation, err := classifyToolkit(probe, toolkitVersion)
	return err == nil && relation == ToolkitSameComplete && compareToolkitBuild(probe, toolkitBuildID, toolkitBuildRevision) == 0
}

func (a *App) ensureToolkit(c Connection) error {
	probe, err := a.remoteToolkitProbe(c)
	if err != nil {
		return err
	}
	relation, err := classifyToolkit(probe, toolkitVersion)
	if err != nil {
		return fmt.Errorf(a.msg("无法安全识别远端工具包版本：%w", "Could not safely classify the remote toolkit version: %w"), err)
	}
	switch relation {
	case ToolkitSameComplete:
		switch compareToolkitBuild(probe, toolkitBuildID, toolkitBuildRevision) {
		case 0:
			return nil
		case -1:
			return fmt.Errorf(a.msg("远端同版本构建较旧；请先运行菜单 [1] 更新一次", "The remote same-version build is older; run menu [1] once to update it"))
		default:
			return fmt.Errorf(a.msg("远端同版本构建比当前 EXE 新；请换用更新的 EXE", "The remote same-version build is newer than this EXE; use a newer EXE"))
		}
	case ToolkitSameIncomplete:
		return fmt.Errorf(a.msg(
			"远端已有同版本 v%s，但文件不完整；请运行菜单 [1] 在 APPLY 确认后原位修复，其他菜单不会自动上传",
			"Remote toolkit v%s matches this EXE but is incomplete; run menu [1] and confirm APPLY for an in-place repair. Other actions never upload it automatically",
		), toolkitVersion)
	case ToolkitNewer:
		return fmt.Errorf(a.msg(
			"远端工具包 v%s 比当前 EXE v%s 新；已禁止降级。请改用 v%s 或更新版本的 EXE",
			"Remote toolkit v%s is newer than this EXE v%s; downgrade is blocked. Use an EXE matching v%s or newer",
		), probe.Version, toolkitVersion, probe.Version)
	}
	return fmt.Errorf(a.msg(
		"远端工具包缺失或版本较旧。请只执行一次菜单 [1] 完成按需安装/升级，然后重试当前操作",
		"The remote toolkit is missing or older. Run menu [1] once for an on-demand install/upgrade, then retry this operation",
	))
}

func (a *App) uploadToolkit(c Connection) error {
	probe, err := a.remoteToolkitProbe(c)
	if err != nil {
		return err
	}
	relation, err := classifyToolkit(probe, toolkitVersion)
	if err != nil {
		return err
	}
	switch relation {
	case ToolkitSameComplete:
		switch compareToolkitBuild(probe, toolkitBuildID, toolkitBuildRevision) {
		case 0:
			return nil
		case 1:
			return fmt.Errorf("remote toolkit v%s build revision %d is newer than EXE build revision %d; downgrade refused", probe.Version, probe.BuildRevision, toolkitBuildRevision)
		}
	case ToolkitSameIncomplete:
		// uploadToolkit is reachable only from menu [1], after the explicit
		// APPLY confirmation.  Repairing the managed program directory is
		// therefore allowed for an interrupted/partial same-version upload,
		// while the monotonic build guard still rejects newer or divergent
		// metadata.
		if !sameVersionIncompleteRepairAllowed(probe) {
			return fmt.Errorf("same-version toolkit v%s is incomplete but has a newer or different build; downgrade refused", toolkitVersion)
		}
	case ToolkitNewer:
		return fmt.Errorf("remote toolkit v%s is newer than EXE v%s; downgrade refused", probe.Version, toolkitVersion)
	}
	archive, err := a.extractEmbeddedTar()
	if err != nil {
		return err
	}
	a.println(a.msg("正在上传内嵌工具包…", "Uploading embedded toolkit..."))
	remoteArchive := "/tmp/" + toolkitArchive
	args := scpBase(c, c.KeyPath)
	args = append(args, archive, scpTarget(c, remoteArchive))
	upload := runStreaming("scp.exe", args, os.Stdin, false)
	if !upload.OK() {
		return fmt.Errorf("SCP upload failed (exit %d): %s", upload.ExitCode, processFailureDetail(upload))
	}
	bootstrap := "mkdir -p /opt; rm -rf " + shQuote(toolkitInstallDir) + "; " +
		"tar -xzf " + shQuote(remoteArchive) + " -C /opt; " +
		"PROXY_RUNBOOK_LOGIN_USER=" + shQuote(c.User) + " PROXY_RUNBOOK_SSH_KEY_INSTALLED=1 " +
		"bash " + toolkitInstallDir + "/linux/00-bootstrap-toolkit.sh"
	result := a.runRootInteractive(c, bootstrap)
	if !result.OK() {
		return fmt.Errorf("remote bootstrap failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	if !a.toolkitInstalled(c) {
		return fmt.Errorf("remote bootstrap returned success but the v%s version probe is missing", toolkitVersion)
	}
	cleanup := a.rootCapture(c, toolkitPostInstallCleanupCommand())
	if !cleanup.OK() || !strings.Contains(cleanup.Stdout, "TOOLKIT_POST_INSTALL_CLEANUP_OK") {
		return fmt.Errorf("toolkit v%s is installed, but obsolete-copy cleanup failed (exit %d): %s", toolkitVersion, cleanup.ExitCode, processFailureDetail(cleanup))
	}
	return nil
}

func toolkitPostInstallCleanupCommand() string {
	var script strings.Builder
	script.WriteString("set -Eeuo pipefail\n")
	script.WriteString("obsolete_dirs=(")
	for _, path := range managedToolkitDirs {
		if path != toolkitInstallDir {
			script.WriteString(" " + shQuote(path))
		}
	}
	script.WriteString(" )\n")
	script.WriteString("toolkit_archives=(")
	for _, path := range managedToolkitArchives {
		script.WriteString(" " + shQuote(path))
	}
	script.WriteString(" )\n")
	script.WriteString(`
for target in "${obsolete_dirs[@]}"; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] && [ ! -L "$target" ] || { printf 'REFUSED_UNEXPECTED_OLD_DIR=%s\n' "$target" >&2; exit 71; }
  fi
done
for target in "${toolkit_archives[@]}"; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || { printf 'REFUSED_UNEXPECTED_ARCHIVE=%s\n' "$target" >&2; exit 72; }
  fi
done
for target in "${obsolete_dirs[@]}"; do
  [ ! -d "$target" ] || rm -rf -- "$target"
done
for target in "${toolkit_archives[@]}"; do
  [ ! -f "$target" ] || rm -f -- "$target"
done
printf 'TOOLKIT_POST_INSTALL_CLEANUP_OK\n'
`)
	return script.String()
}

func toolkitUninstallCommand() string {
	var script strings.Builder
	script.WriteString("set -Eeuo pipefail\n")
	script.WriteString("toolkit_dirs=(")
	for _, path := range managedToolkitDirs {
		script.WriteString(" " + shQuote(path))
	}
	script.WriteString(" )\n")
	script.WriteString("toolkit_archives=(")
	for _, path := range managedToolkitArchives {
		script.WriteString(" " + shQuote(path))
	}
	script.WriteString(" )\n")
	script.WriteString(`
current_link='/opt/proxy-node-assistant-current'
legacy_text_link='/opt/text-node-assistant-current'
legacy_runbook_link='/opt/proxy-runbook-current'
launcher='/usr/local/sbin/proxy-node'
legacy_launcher='/usr/local/sbin/text-node'

# Complete ownership/type validation happens before the first deletion.
for target in "${toolkit_dirs[@]}"; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] && [ ! -L "$target" ] || { printf 'REFUSED_UNEXPECTED_DIR=%s\n' "$target" >&2; exit 61; }
  fi
done
for target in "${toolkit_archives[@]}"; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || { printf 'REFUSED_UNEXPECTED_ARCHIVE=%s\n' "$target" >&2; exit 62; }
  fi
done
for link in "$current_link" "$legacy_text_link" "$legacy_runbook_link"; do
if [ -e "$link" ] || [ -L "$link" ]; then
  [ -L "$link" ] || { printf 'REFUSED_CURRENT_NOT_SYMLINK=%s\n' "$link" >&2; exit 63; }
  current_target="$(readlink -f "$link" 2>/dev/null || true)"
  target_allowed=false
  for target in "${toolkit_dirs[@]}"; do
    [ "$current_target" = "$target" ] && target_allowed=true
  done
  $target_allowed || { printf 'REFUSED_UNMANAGED_CURRENT=%s\n' "$current_target" >&2; exit 64; }
fi
done
for command_path in "$launcher" "$legacy_launcher"; do
if [ -e "$command_path" ] || [ -L "$command_path" ]; then
  [ -f "$command_path" ] && [ ! -L "$command_path" ] || { printf 'REFUSED_UNEXPECTED_LAUNCHER=%s\n' "$command_path" >&2; exit 65; }
  if [ "$command_path" = "$launcher" ]; then
    grep -qF '/opt/proxy-node-assistant-current/linux/13-maintenance-menu.sh' "$command_path" || { printf 'REFUSED_UNMANAGED_LAUNCHER=%s\n' "$command_path" >&2; exit 66; }
  else
    # The compatibility launcher is an intentionally tiny forwarding wrapper.
    # Accept only the exact managed target; never remove an arbitrary user script.
    grep -qF 'exec /usr/local/sbin/proxy-node "$@"' "$command_path" || { printf 'REFUSED_UNMANAGED_LAUNCHER=%s\n' "$command_path" >&2; exit 66; }
  fi
fi
done

printf 'PROXY_RUNBOOK_UNINSTALL_BEGIN\n'
for link in "$current_link" "$legacy_text_link" "$legacy_runbook_link"; do
  if [ -L "$link" ]; then rm -f -- "$link"; printf 'REMOVED=%s\n' "$link"; fi
done
for command_path in "$launcher" "$legacy_launcher"; do
  if [ -f "$command_path" ]; then rm -f -- "$command_path"; printf 'REMOVED=%s\n' "$command_path"; fi
done
for target in "${toolkit_dirs[@]}"; do
  if [ -d "$target" ]; then
    rm -rf -- "$target"
    printf 'REMOVED=%s\n' "$target"
  fi
done
for target in "${toolkit_archives[@]}"; do
  if [ -f "$target" ]; then
    rm -f -- "$target"
    printf 'REMOVED=%s\n' "$target"
  fi
done

[ ! -e "$current_link" ] && [ ! -L "$current_link" ]
[ ! -e "$legacy_text_link" ] && [ ! -L "$legacy_text_link" ]
[ ! -e "$legacy_runbook_link" ] && [ ! -L "$legacy_runbook_link" ]
[ ! -e "$launcher" ] && [ ! -L "$launcher" ]
[ ! -e "$legacy_launcher" ] && [ ! -L "$legacy_launcher" ]
for target in "${toolkit_dirs[@]}" "${toolkit_archives[@]}"; do
  [ ! -e "$target" ] && [ ! -L "$target" ] || { printf 'UNINSTALL_VERIFY_FAILED=%s\n' "$target" >&2; exit 67; }
done
printf 'PRESERVED=NODE_SERVICES_AND_CONFIG\n'
printf 'PRESERVED=ETC_PROXY_RUNBOOK\n'
printf 'PRESERVED=ROOT_CREDENTIAL_HANDOFF\n'
printf 'PRESERVED=BACKUP_ARCHIVES\n'
printf 'PROXY_RUNBOOK_UNINSTALL_END\n'
`)
	return script.String()
}

// remoteHandoffCommand returns the read-only exporter used by the protected
// handoff panel and by the final install verification.  Keep it separate from
// the SSH call so the compatibility roots and protected-store coverage can be
// tested without a live VPS.
func remoteHandoffCommand() string {
	// A v0.9.x node may still keep its truth handoff under the legacy
	// text-node-assistant directory.  Emit archived runs first (oldest to
	// newest by mtime), then the live files and finally the protected login
	// stores.  A failed run can clear HANDOFF-SECRETS.txt before restoring the
	// store, so omitting CURRENT-LOGIN-CREDENTIALS.env makes the next form look
	// incomplete even though all four credentials are still safely retained.
	// parseKV's last-value-wins behavior lets a newer run override stale fields
	// while preserving protocol fields absent from that run.  The find
	// expressions are intentionally read-only and only target root-owned
	// handoff directories; no arbitrary paths or secret values enter argv.
	command := "printf '%s\\n' " + shQuote(handoffBegin) + "; " +
		// CURRENT-LOGIN-CREDENTIALS.env is a protected key/value store and does
		// not carry the run marker that validateHandoff requires.  Add a
		// transport-local marker so a store-only recovery remains renderable
		// after an interrupted run.  It contains no account or password value;
		// a real HANDOFF_RUN_STARTED value from an archive/live file still wins
		// under parseKV's last-value-wins semantics.
		"printf 'HANDOFF_RUN_STARTED=read-only-export\\n'; " +
		// Stored handoffs can contain a complete marker block copied from an
		// older run.  Do not let those nested markers terminate the outer
		// transport block before newer archive/live files are emitted.  Keep the
		// filtering in the remote command so raw files remain untouched.
		"emit_file() { [ -r \"$1\" ] || return 0; awk '!/^[[:space:]]*__(PNA|TNA)_HANDOFF_(BEGIN|END)__[[:space:]]*$/' \"$1\"; }; " +
		"emit_archive() { find \"$1\" -maxdepth 1 -type f -name 'HANDOFF-*.txt' -printf '%T@ %p\\n' 2>/dev/null | sort -n | while IFS= read -r entry; do f=\"${entry#* }\"; [ -f \"$f\" ] && emit_file \"$f\"; done; }; " +
		// Compatibility roots are emitted before the canonical proxy-runbook
		// root.  The credential/form merger is intentionally last-usable-value
		// wins, so a current proxy-runbook store must override stale values left
		// by either v0.9.x root (including the early product-named v1 root).
		"emit_archive /root/.config/text-node-assistant/handoff-archive; " +
		"[ -r /root/.config/text-node-assistant/HANDOFF-SECRETS.txt ] && emit_file /root/.config/text-node-assistant/HANDOFF-SECRETS.txt || true; " +
		"[ -r /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env || true; " +
		"emit_archive /root/.config/proxy-node-assistant/handoff-archive; " +
		"[ -r /root/.config/proxy-node-assistant/HANDOFF-SECRETS.txt ] && emit_file /root/.config/proxy-node-assistant/HANDOFF-SECRETS.txt || true; " +
		"[ -r /root/.config/proxy-node-assistant/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/proxy-node-assistant/CURRENT-LOGIN-CREDENTIALS.env || true; " +
		// Keep the canonical root last so duplicate credentials and protocol
		// fields from compatibility roots cannot shadow the active run.
		"emit_archive /root/.config/proxy-runbook/handoff-archive; " +
		"[ -r /root/.config/proxy-runbook/HANDOFF-SECRETS.txt ] && emit_file /root/.config/proxy-runbook/HANDOFF-SECRETS.txt || true; " +
		"[ -r /root/.config/proxy-runbook/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/proxy-runbook/CURRENT-LOGIN-CREDENTIALS.env || true; " +
		"printf '%s\\n' " + shQuote(handoffEnd)
	return command
}

func (a *App) fetchHandoff(c Connection) (string, error) {
	command := remoteHandoffCommand()
	result := a.rootCapture(c, command)
	if !result.OK() {
		return "", fmt.Errorf("handoff fetch failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return validateHandoff(result.Stdout)
}

func (a *App) panelMetadata(c Connection) (PanelMetadata, error) {
	command := "set -u; root=" + shQuote(remoteRoot) + "; " +
		"[ -x \"$root/linux/18-panel-metadata.sh\" ] || root=" + shQuote(legacyTextRemoteRoot) + "; " +
		"[ -x \"$root/linux/18-panel-metadata.sh\" ] || root=" + shQuote(legacyRunbookRemoteRoot) + "; " +
		"[ -x \"$root/linux/18-panel-metadata.sh\" ] || { echo PANEL_METADATA_ERROR=SCRIPT_MISSING >&2; exit 12; }; " +
		"bash \"$root/linux/18-panel-metadata.sh\""
	result := a.rootCapture(c, command)
	if !result.OK() {
		return PanelMetadata{}, fmt.Errorf("panel metadata command failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parsePanelMetadata(result.Stdout)
}

func (a *App) remoteRunStatus(c Connection) map[string]string {
	command := "printf '%s\\n' " + shQuote(statusBegin) + "; " +
		"cat /etc/text-node-assistant/last-run.env 2>/dev/null || true; " +
		"cat /etc/text-node-assistant/cover-last-run.env 2>/dev/null || true; " +
		"cat /etc/proxy-runbook/last-run.env 2>/dev/null || true; " +
		"cat /etc/proxy-runbook/cover-last-run.env 2>/dev/null || true; " +
		"printf '%s\\n' " + shQuote(statusEnd)
	result := a.rootCapture(c, command)
	if !result.OK() {
		return nil
	}
	status, err := parseRunStatus(result.Stdout)
	if err != nil {
		return nil
	}
	return status
}

func pickLocalPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func (a *App) startTunnel(c Connection, remotePort int) (int, error) {
	localPort, err := pickLocalPort()
	if err != nil {
		return 0, err
	}
	forward := fmt.Sprintf("127.0.0.1:%d:127.0.0.1:%d", localPort, remotePort)
	args := sshBase(c, true, false, "")
	args = append(args, "-N", "-o", "ExitOnForwardFailure=yes", "-L", forward, target(c))
	cmd := exec.Command(managedCommandPath("ssh.exe"), args...)
	hideChildWindow(cmd)
	var stderr bytes.Buffer
	cmd.Stdout = io.Discard
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			return 0, fmt.Errorf("SSH tunnel exited before listening: %v: %s", waitErr, sanitizeSSHStderr(stderr.String()))
		default:
		}
		conn, dialErr := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", localPort), 250*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			a.tunnels = append(a.tunnels, cmd)
			return localPort, nil
		}
		time.Sleep(150 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	<-done
	return 0, fmt.Errorf("SSH tunnel did not listen within 8 seconds: %s", sanitizeSSHStderr(stderr.String()))
}

func (a *App) killTunnels() {
	for _, cmd := range a.tunnels {
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	a.tunnels = nil
}
