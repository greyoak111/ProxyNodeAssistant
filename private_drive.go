package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type driveAdminLocalCapability struct {
	Version  int    `json:"version"`
	NodeID   string `json:"nodeId"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type driveSessionResult struct {
	Version   int    `json:"version"`
	NodeID    string `json:"nodeId"`
	DeviceID  string `json:"deviceId"`
	Role      string `json:"role"`
	URL       string `json:"url"`
	Username  string `json:"username"`
	Password  string `json:"password"`
	SpacePath string `json:"spacePath"`
}

var (
	driveUsernamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]{2,31}$`)
	driveAdminPattern    = regexp.MustCompile(`^tna-admin-[a-f0-9]{12}$`)
	drivePasswordPattern = regexp.MustCompile(`^[\x20-\x7e]{14,128}$`)
)

func randomDrivePassword() (string, error) {
	data := make([]byte, 30)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func randomDriveAdminUsername() (string, error) {
	data := make([]byte, 6)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return fmt.Sprintf("tna-admin-%x", data), nil
}

func driveAdminCredentialTarget(nodeID string) string {
	return "TextNodeAssistant/v0.9.5/drive-admin/" + nodeID
}

func parseDriveAdminHandoff(handoff, nodeID string) (driveAdminLocalCapability, error) {
	values := parseKV(handoff)
	value := driveAdminLocalCapability{Version: 1, NodeID: nodeID, Username: values["DRIVE_ADMIN_USERNAME"], Password: values["DRIVE_ADMIN_PASSWORD"]}
	if !nodeIDPattern.MatchString(nodeID) || !driveAdminPattern.MatchString(value.Username) || !drivePasswordPattern.MatchString(value.Password) {
		return driveAdminLocalCapability{}, errors.New("private-drive admin handoff is incomplete")
	}
	return value, nil
}

func saveDriveAdminCapability(value driveAdminLocalCapability) error {
	if value.Version != 1 || !nodeIDPattern.MatchString(value.NodeID) || !driveAdminPattern.MatchString(value.Username) || !drivePasswordPattern.MatchString(value.Password) {
		return errors.New("private-drive admin capability is invalid")
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return credentialWrite(driveAdminCredentialTarget(value.NodeID), value.Username, base64.RawURLEncoding.EncodeToString(data))
}

func loadDriveAdminCapability(nodeID string) (driveAdminLocalCapability, error) {
	var value driveAdminLocalCapability
	encoded, err := credentialRead(driveAdminCredentialTarget(nodeID))
	if err != nil || encoded == "" {
		return value, errors.New("private-drive admin capability is not stored on this device")
	}
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || json.Unmarshal(data, &value) != nil || value.Version != 1 || value.NodeID != nodeID || !driveAdminPattern.MatchString(value.Username) || !drivePasswordPattern.MatchString(value.Password) {
		return driveAdminLocalCapability{}, errors.New("stored private-drive admin capability is invalid")
	}
	return value, nil
}

func (a *App) verifyDriveCapability(c Connection, username, password string) error {
	result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/30-copyparty-account.sh verify "+shQuote(username), []byte(password+"\n"))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_DRIVE_ACCOUNT_LOGIN_OK") {
		return fmt.Errorf("private-drive capability login readback failed: %s", processFailureDetail(result))
	}
	return nil
}

func (a *App) ensureLocalDriveAdminCapability(c Connection, handoff string) (string, error) {
	_, status, err := a.requireLocalActiveController(c)
	if err != nil {
		return handoff, err
	}
	if handoff != "" {
		capability, err := parseDriveAdminHandoff(handoff, status.NodeID)
		if err != nil {
			return handoff, err
		}
		if err := a.verifyDriveCapability(c, capability.Username, capability.Password); err != nil {
			return handoff, err
		}
		if err := saveDriveAdminCapability(capability); err != nil {
			return handoff, fmt.Errorf("drive is ready but its admin capability could not be protected locally: %w", err)
		}
		return handoff, nil
	}
	remoteStatus, err := a.driveStatus(c)
	if err != nil {
		return "", err
	}
	stored, storedErr := loadDriveAdminCapability(status.NodeID)
	if storedErr == nil && stored.Username == remoteStatus["DRIVE_ADMIN_USERNAME"] && a.verifyDriveCapability(c, stored.Username, stored.Password) == nil {
		a.println(a.msg("当前设备已有经真实登录验证的远端 admin 空间能力。", "This device already has a remote admin-space capability verified by a real login."))
		return "", nil
	}
	a.println(a.msg("远端网盘已经存在，但当前 controller 没有可验证的 admin 空间能力；必须显式轮换一次，旧会话会失效，用户文件不变。", "The remote drive exists, but this controller has no verifiable admin-space capability. One explicit rotation is required; old sessions will expire and user files remain unchanged."))
	rotated, err := a.driveAdminTransaction(c, true)
	if err != nil {
		return "", err
	}
	capability, err := parseDriveAdminHandoff(rotated, status.NodeID)
	if err != nil {
		return "", err
	}
	if err := a.verifyDriveCapability(c, capability.Username, capability.Password); err != nil {
		return "", err
	}
	if err := saveDriveAdminCapability(capability); err != nil {
		return "", err
	}
	return rotated, nil
}

func (a *App) chooseDriveCredential(defaultUsername string) (string, string, error) {
	if !driveAdminPattern.MatchString(defaultUsername) {
		generated, err := randomDriveAdminUsername()
		if err != nil {
			return "", "", err
		}
		defaultUsername = generated
	}
	username := defaultUsername
	a.println(a.msg("远端网盘 admin 能力账户将使用随机、不可猜名称：", "The remote drive admin capability uses a random, non-guessable name:") + " " + username)
	a.println(a.msg("[1] 安全随机生成（推荐）", "[1] Generate a secure random password (recommended)"))
	a.println(a.msg("[2] 自定义（遮罩输入两次，不修剪空格）", "[2] Custom (masked twice; spaces are not trimmed)"))
	a.println(a.msg("[0] 取消", "[0] Cancel"))
	choice := strings.TrimSpace(a.prompt(a.msg("请选择密码策略", "Choose a password policy")))
	switch choice {
	case "", "1":
		password, err := randomDrivePassword()
		return username, password, err
	case "2":
		first := a.secretPromptExact(a.msg("输入网盘密码（14—128 位可打印 ASCII）", "Enter the drive password (14-128 printable ASCII characters)"))
		if a.inputClosed {
			return "", "", errInputClosed
		}
		second := a.secretPromptExact(a.msg("再次输入同一密码", "Enter the same password again"))
		if first != second {
			return "", "", errors.New(a.msg("两次密码不一致；远端未修改。", "The passwords differ; the remote was not changed."))
		}
		if !drivePasswordPattern.MatchString(first) {
			return "", "", errors.New(a.msg("密码必须是 14—128 位可打印 ASCII；不会自动 trim 或规范化。", "The password must contain 14-128 printable ASCII characters; it is not trimmed or normalized."))
		}
		return username, first, nil
	case "0":
		return "", "", errInputClosed
	default:
		return "", "", errors.New(a.msg("密码策略选择无效。", "Invalid password-policy selection."))
	}
}

func (a *App) chooseDriveQuota() (string, error) {
	value := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("网盘容量 [auto]（推荐自动按磁盘与预留空间计算；也可填 1—50 GiB）", "Drive quota [auto] (recommended: calculate from disk/reserve; or enter 1-50 GiB)"))))
	if value == "" {
		return "auto", nil
	}
	quota, err := strconv.Atoi(value)
	if value != "auto" && (err != nil || quota < 1 || quota > 50) {
		return "", errors.New(a.msg("请输入 auto 或 1—50 GiB；远端还会按实际可用磁盘再次限流。", "Enter auto or 1-50 GiB; the server enforces its actual disk budget again."))
	}
	return value, nil
}

func (a *App) driveStatus(c Connection) (map[string]string, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh status")
	if !result.OK() {
		return nil, fmt.Errorf("drive status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(strings.TrimSpace(result.Stdout))
	return parseKV(result.Stdout), nil
}

func (a *App) driveAdminTransaction(c Connection, rotate bool) (string, error) {
	status, _ := a.driveStatus(c)
	defaultUsername := status["DRIVE_ADMIN_USERNAME"]
	if defaultUsername == "unknown" {
		defaultUsername = ""
	}
	username, password, err := a.chooseDriveCredential(defaultUsername)
	if err != nil {
		if errors.Is(err, errInputClosed) {
			return "", errInputClosed
		}
		return "", err
	}
	quota, err := a.chooseDriveQuota()
	if err != nil {
		return "", err
	}
	verb := "install-admin"
	if rotate {
		verb = "rotate-admin"
		a.println(a.msg("轮换会使旧网盘密码和旧会话失效；用户文件不会被覆盖。", "Rotation invalidates the old drive password and sessions; user files are not overwritten."))
	}
	if !a.yes(a.msg("执行前会校验固定版本与 SHA-256，并用无 Cookie 的登录、上传、下载、删除事务验收。继续？", "The pinned release and SHA-256 are checked, followed by a cookie-free login/upload/download/delete transaction. Continue?"), false) {
		return "", errInputClosed
	}
	command := "bash " + remoteRoot + "/linux/29-copyparty-drive.sh " + verb + " " + shQuote(username) + " " + shQuote(quota)
	result := a.rootCaptureWithInput(c, command, []byte(password+"\n"))
	if !result.OK() {
		return "", fmt.Errorf(a.msg("网盘事务失败（退出码 %d）：%s", "Drive transaction failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	for _, marker := range []string{"__TNA_DRIVE_RESULT_BEGIN__", "TNA_DRIVE_CREDENTIAL_CRUD_OK", "COPYPARTY_LOOPBACK_PORT=", "PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED", "__TNA_DRIVE_RESULT_END__"} {
		if !strings.Contains(result.Stdout, marker) {
			return "", fmt.Errorf("drive transaction returned success but marker %s is missing", marker)
		}
	}
	a.println(strings.TrimSpace(result.Stdout))
	values := parseKV(result.Stdout)
	port, err := validatedDrivePort(values["COPYPARTY_LOOPBACK_PORT"])
	if err != nil {
		return "", err
	}
	handoff := strings.Join([]string{
		"===== TNA PRIVATE DRIVE ADMIN HANDOFF v0.9.5 =====",
		"PRIVATE_DRIVE_STATUS=READY",
		"PRIVATE_DRIVE_ENGINE=copyparty",
		"COPYPARTY_VERSION=v1.20.21",
		"DRIVE_ADMIN_USERNAME=" + username,
		"DRIVE_ADMIN_PASSWORD=" + password,
		"DRIVE_ADMIN_PATH=/files/admin/",
		"PRIVATE_DRIVE_QUOTA_GIB=" + values["PRIVATE_DRIVE_QUOTA_GIB"],
		"PRIVATE_DRIVE_LOCAL_ORIGIN=http://127.0.0.1:" + strconv.Itoa(port) + "/",
		"PRIVATE_DRIVE_ACCESS=SSH_TUNNEL_ONLY_NO_DOMAIN_REQUIRED",
		"=============================================",
	}, "\n")
	return handoff, nil
}

func (a *App) installOrRotateDrive(c Connection, rotate bool) error {
	handoff, err := a.driveAdminTransaction(c, rotate)
	if errors.Is(err, errInputClosed) {
		return nil
	}
	if err != nil {
		return err
	}
	return a.secretHandoff("PRIVATE DRIVE HANDOFF", handoff)
}

func (a *App) prepareMandatoryDrive(c Connection) (string, error) {
	status, err := a.driveStatus(c)
	if err == nil && status["PRIVATE_DRIVE_STATUS"] == "READY" && status["COPYPARTY_SERVICE"] == "active" && status["COPYPARTY_LOOPBACK_LISTENER"] == "1" && driveAdminPattern.MatchString(status["DRIVE_ADMIN_USERNAME"]) {
		if _, portErr := validatedDrivePort(status["COPYPARTY_LOOPBACK_PORT"]); portErr == nil {
			a.println(a.msg("强制网盘已就绪；保持现有 admin 身份和用户文件，不重复安装或改密。", "The mandatory drive is ready; its admin identity and user files are preserved without reinstalling or rotating credentials."))
			return "", nil
		}
	}
	a.println(a.msg("未检测到兼容的强制网盘基线；先创建回环内核与 admin 空间。普通账号仍保持禁用，直到全部施工成功。", "No compatible mandatory-drive baseline was found. The loopback engine and admin space will be created first; ordinary registration stays disabled until the full workflow succeeds."))
	handoff, err := a.driveAdminTransaction(c, false)
	if errors.Is(err, errInputClosed) {
		return "", errors.New(a.msg("强制网盘未完成，整机施工已取消。", "The mandatory drive was not completed, so node convergence was cancelled."))
	}
	return handoff, err
}

func (a *App) finalizeMandatoryDrive(c Connection, lifecycle string) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh finalize-install "+shQuote(lifecycle))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_DRIVE_FINALIZED=1") || !strings.Contains(result.Stdout, "DRIVE_REGISTRATION_READY=1") {
		return fmt.Errorf(a.msg("强制网盘最终验收失败（退出码 %d）：%s", "Mandatory-drive finalization failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	a.println(strings.TrimSpace(result.Stdout))
	return nil
}

func validatedDrivePort(value string) (int, error) {
	port, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || port < 39000 || port > 39999 {
		return 0, errors.New("remote drive returned an invalid loopback port")
	}
	return port, nil
}

func (a *App) openDriveLocalTunnel(c Connection) error {
	status, err := a.driveStatus(c)
	if err != nil {
		return err
	}
	if status["COPYPARTY_SERVICE"] != "active" || status["COPYPARTY_LOOPBACK_LISTENER"] != "1" {
		return errors.New(a.msg("copyparty 本地回源未就绪。", "The copyparty loopback origin is not ready."))
	}
	remotePort, err := validatedDrivePort(status["COPYPARTY_LOOPBACK_PORT"])
	if err != nil {
		return err
	}
	localPort, err := a.startTunnel(c, remotePort)
	if err != nil {
		return err
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/", localPort)
	if err := openURL(url); err != nil {
		return err
	}
	a.println(a.msg("网盘已通过本地 SSH 隧道打开：", "The drive opened through a local SSH tunnel:") + " " + url)
	return nil
}

func requestedDriveSession(args []string) bool {
	for _, value := range args {
		if value == "--drive-session" {
			return true
		}
	}
	return false
}

func verifyLocalDriveCredential(url, username, password string) error {
	client := &http.Client{Timeout: 12 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequest(http.MethodGet, strings.TrimRight(url, "/")+"/files/"+username+"/", nil)
	if err != nil {
		return err
	}
	request.SetBasicAuth(username, password)
	request.Header.Set("User-Agent", "TextNodeAssistant/0.9.5")
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return fmt.Errorf("drive endpoint rejected authentication with HTTP %d", response.StatusCode)
	}
	return nil
}

func (a *App) serveDriveSession(input io.Reader, result driveSessionResult) int {
	data, _ := json.Marshal(result)
	fmt.Println("TNA_DRIVE_SESSION_SECRET_B64=" + base64.StdEncoding.EncodeToString(data))
	fmt.Println("TNA_DRIVE_SESSION_READY=1")
	reader := bufio.NewReader(input)
	for {
		line, readErr := reader.ReadString('\n')
		if strings.EqualFold(strings.TrimSpace(line), "close") || readErr != nil {
			break
		}
	}
	a.killTunnels()
	fmt.Println("TNA_DRIVE_SESSION_CLOSED=1")
	return 0
}

// runDriveSession is the narrow backend used by the outer graphical drive.
// Connection and account secrets arrive only on stdin; the one result frame is
// treated as secret by the GUI and is never appended to the workflow log.
func (a *App) runDriveSession(input io.Reader) int {
	lines, err := readLocalAdminProtocolLines(input, 6)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=INPUT_MISSING")
		return 2
	}
	port, portErr := strconv.Atoi(lines[2])
	if !hostPartPattern.MatchString(lines[0]) || !userPartPattern.MatchString(lines[1]) || portErr != nil || port < 1 || port > 65535 || (lines[3] != "admin" && lines[3] != "ordinary") {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=INPUT_INVALID")
		return 2
	}
	if err := a.ensureOpenSSH(); err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=OPENSSH_UNAVAILABLE")
		return 3
	}
	keyPath, err := defaultKeyPath(lines[0], lines[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=KEY_PATH_UNAVAILABLE")
		return 3
	}
	c := Connection{Host: lines[0], User: lines[1], Port: port, KeyPath: keyPath, AuthMode: AuthManagedKey, Ready: true}
	if !fileExists(keyPath) || !fileExists(keyPath+".pub") {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=NODE_NOT_BOUND")
		return 4
	}
	if err := a.ensureHostKey(c); err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=HOST_KEY:"+err.Error())
		return 4
	}
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DEVICE_IDENTITY")
		return 5
	}
	if admission, admissionErr := a.refreshTrafficDeviceAdmission(c, identity); admissionErr == nil && admission.Role == "traffic-only" {
		if admission.DeviceID != identity.DeviceID || lines[3] != "ordinary" || !driveUsernamePattern.MatchString(lines[4]) || strings.EqualFold(lines[4], "admin") || !drivePasswordPattern.MatchString(lines[5]) {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=RESTRICTED_DEVICE_INPUT_INVALID")
			return 6
		}
		localPort, tunnelErr := a.startTunnel(c, admission.DrivePort)
		if tunnelErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=RESTRICTED_TUNNEL_REJECTED")
			return 8
		}
		url := fmt.Sprintf("http://127.0.0.1:%d/", localPort)
		if verifyErr := verifyLocalDriveCredential(url, lines[4], lines[5]); verifyErr != nil {
			a.killTunnels()
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=REMOTE_LOGIN_REJECTED")
			return 7
		}
		return a.serveDriveSession(input, driveSessionResult{Version: 1, NodeID: admission.NodeID, DeviceID: identity.DeviceID, Role: "ordinary", URL: url, Username: lines[4], Password: lines[5], SpacePath: "/files/" + lines[4] + "/"})
	}
	verified := verifyKey(c, keyPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DEVICE_KEY_REJECTED")
		return 4
	}
	if err := a.requireExactInstalledToolkit(c); err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=TOOLKIT:"+err.Error())
		return 5
	}
	status, err := a.getDeviceStatus(c)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DEVICE_STATUS:"+sanitizeProtocolError(err.Error()))
		return 5
	}
	deviceRole := ""
	for _, device := range status.Devices {
		if device.DeviceID == identity.DeviceID && device.Status == "active" {
			deviceRole = device.Role
			break
		}
	}
	if deviceRole == "" {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DEVICE_NOT_ACTIVE")
		return 6
	}
	driveState, err := a.driveStatus(c)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DRIVE_NOT_READY:"+sanitizeProtocolError(err.Error()))
		return 6
	}
	remotePort, err := validatedDrivePort(driveState["COPYPARTY_LOOPBACK_PORT"])
	if err != nil || driveState["COPYPARTY_SERVICE"] != "active" || driveState["COPYPARTY_LOOPBACK_LISTENER"] != "1" {
		detail := "status=" + driveState["PRIVATE_DRIVE_STATUS"] + ",service=" + driveState["COPYPARTY_SERVICE"] + ",listener=" + driveState["COPYPARTY_LOOPBACK_LISTENER"]
		if err != nil {
			detail += ",port=" + driveState["COPYPARTY_LOOPBACK_PORT"]
		}
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=DRIVE_NOT_READY:"+sanitizeProtocolError(detail))
		return 6
	}
	username, password, spacePath := lines[4], lines[5], ""
	if lines[3] == "admin" {
		verifier, verifierErr := loadLocalAdminVerifier()
		if verifierErr != nil || !verifyLocalAdminPassword(verifier, lines[5]) {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=LOCAL_ADMIN_AUTHENTICATION_FAILED")
			return 7
		}
		if deviceRole != "controller" {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=CONTROLLER_REQUIRED_FOR_ADMIN_SPACE")
			return 7
		}
		capability, capabilityErr := loadDriveAdminCapability(status.NodeID)
		if capabilityErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=ADMIN_CAPABILITY_UNAVAILABLE")
			return 7
		}
		username, password, spacePath = capability.Username, capability.Password, "/files/admin/"
	} else {
		if !driveUsernamePattern.MatchString(username) || strings.EqualFold(username, "admin") || !drivePasswordPattern.MatchString(password) {
			fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=ORDINARY_CREDENTIAL_INVALID")
			return 7
		}
		spacePath = "/files/" + username + "/"
	}
	if err := a.verifyDriveCapability(c, username, password); err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=REMOTE_LOGIN_REJECTED")
		return 7
	}
	localPort, err := a.startTunnel(c, remotePort)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_SESSION_ERROR=TUNNEL_FAILED")
		return 8
	}
	return a.serveDriveSession(input, driveSessionResult{Version: 1, NodeID: status.NodeID, DeviceID: identity.DeviceID, Role: lines[3], URL: fmt.Sprintf("http://127.0.0.1:%d/", localPort), Username: username, Password: password, SpacePath: spacePath})
}

func (a *App) managePrivateDrive() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	for {
		a.println()
		a.println(a.msg("私人网盘（无域名、只经 127.0.0.1 SSH 隧道；安装/修复只允许从主菜单 [1] 执行）：", "Private drive (no domain; 127.0.0.1 SSH tunnel only; install/repair is available only from main menu [1]):"))
		a.println(a.msg("[1] 查看脱敏状态", "[1] Show redacted status"))
		a.println(a.msg("[2] 轮换 admin 能力账户密码并做真实 CRUD 验收", "[2] Rotate the admin capability password and run real CRUD verification"))
		a.println(a.msg("[3] 通过 127.0.0.1 SSH 隧道打开网盘", "[3] Open the drive through a 127.0.0.1 SSH tunnel"))
		a.println(a.msg("[4] 注册普通网盘账号（最多 2 个；真实 CRUD + controller 加密托管）", "[4] Register an ordinary drive account (max 2; real CRUD + controller-encrypted escrow)"))
		a.println(a.msg("[5] 恢复并完整显示普通账号真实凭据（仅 active controller）", "[5] Recover and show a real ordinary-account credential (active controller only)"))
		a.println(a.msg("[6] 普通账号改密（旧密码 + 新密码两次确认）", "[6] Change an ordinary-account password (old password + two matching new entries)"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		switch strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))) {
		case "1":
			_, err := a.driveStatus(c)
			return err
		case "2":
			return a.installOrRotateDrive(c, true)
		case "3":
			return a.openDriveLocalTunnel(c)
		case "4":
			return a.registerOrdinaryDriveAccount(c)
		case "5":
			return a.showRecoverableDriveCredential(c)
		case "6":
			return a.changeOrdinaryDrivePassword(c)
		case "0", "":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
		}
	}
}
