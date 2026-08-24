package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	driveUsernamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]{2,31}$`)
	drivePasswordPattern = regexp.MustCompile(`^[\x20-\x7e]{14,128}$`)
)

func randomDrivePassword() (string, error) {
	data := make([]byte, 30)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func (a *App) chooseDriveCredential(defaultUsername string) (string, string, error) {
	if defaultUsername == "" || !driveUsernamePattern.MatchString(defaultUsername) {
		defaultUsername = "pnaadmin"
	}
	username := strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("网盘账户名 [%s]", "Drive account username [%s]"), defaultUsername)))
	if username == "" {
		username = defaultUsername
	}
	if !driveUsernamePattern.MatchString(username) {
		return "", "", errors.New(a.msg("网盘账户名只允许 3—32 位英文字母开头的字母、数字、点、下划线和连字符。", "Drive usernames must be 3-32 characters, begin with a letter, and contain only letters, digits, dot, underscore, or hyphen."))
	}
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

func (a *App) chooseDriveQuota() (int, error) {
	value := strings.TrimSpace(a.prompt(a.msg("网盘容量上限 GiB [2]（20GB 磁盘只允许 2 或 3）", "Drive quota in GiB [2] (only 2 or 3 on a 20GB disk)")))
	if value == "" {
		return 2, nil
	}
	quota, err := strconv.Atoi(value)
	if err != nil || (quota != 2 && quota != 3) {
		return 0, errors.New(a.msg("当前安全档只允许 2GiB 或 3GiB。", "The current safety profile allows only 2GiB or 3GiB."))
	}
	return quota, nil
}

func (a *App) driveStatus(c Connection) (map[string]string, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh status")
	if !result.OK() {
		return nil, fmt.Errorf("drive status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(strings.TrimSpace(result.Stdout))
	return parseKV(result.Stdout), nil
}

func (a *App) installOrRotateDrive(c Connection, rotate bool) error {
	status, _ := a.driveStatus(c)
	defaultUsername := status["DRIVE_ACCOUNT_USERNAME"]
	if defaultUsername == "unknown" {
		defaultUsername = ""
	}
	username, password, err := a.chooseDriveCredential(defaultUsername)
	if err != nil {
		if errors.Is(err, errInputClosed) {
			return nil
		}
		return err
	}
	quota, err := a.chooseDriveQuota()
	if err != nil {
		return err
	}
	verb := "install"
	if rotate {
		verb = "rotate"
		a.println(a.msg("轮换会使旧网盘密码和旧会话失效；用户文件不会被覆盖。", "Rotation invalidates the old drive password and sessions; user files are not overwritten."))
	}
	if !a.yes(a.msg("执行前会校验固定版本与 SHA-256，并用无 Cookie 的登录、上传、下载、删除事务验收。继续？", "The pinned release and SHA-256 are checked, followed by a cookie-free login/upload/download/delete transaction. Continue?"), false) {
		return nil
	}
	command := "bash " + remoteRoot + "/linux/29-copyparty-drive.sh " + verb + " " + shQuote(username) + " " + strconv.Itoa(quota)
	result := a.rootCaptureWithInput(c, command, []byte(password+"\n"))
	if !result.OK() {
		return fmt.Errorf(a.msg("网盘事务失败（退出码 %d）：%s", "Drive transaction failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	for _, marker := range []string{"__PNA_DRIVE_RESULT_BEGIN__", "PNA_DRIVE_CREDENTIAL_CRUD_OK", "COPYPARTY_LISTEN=127.0.0.1:3923", "PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED", "__PNA_DRIVE_RESULT_END__"} {
		if !strings.Contains(result.Stdout, marker) {
			return fmt.Errorf("drive transaction returned success but marker %s is missing", marker)
		}
	}
	a.println(strings.TrimSpace(result.Stdout))
	handoff := strings.Join([]string{
		"===== PNA PRIVATE DRIVE HANDOFF v0.9.5 =====",
		"PRIVATE_DRIVE_STATUS=LOCAL_ONLY_READY_WAITING_FOR_CLOUDFLARE",
		"PRIVATE_DRIVE_ENGINE=copyparty",
		"COPYPARTY_VERSION=v1.20.21",
		"DRIVE_ACCOUNT_USERNAME=" + username,
		"DRIVE_ACCOUNT_PASSWORD=" + password,
		"PRIVATE_DRIVE_QUOTA_GIB=" + strconv.Itoa(quota),
		"PRIVATE_DRIVE_LOCAL_ORIGIN=http://127.0.0.1:3923/",
		"PRIVATE_DRIVE_PUBLIC_URL=PENDING_CLOUDFLARE_ORIGIN_RULE",
		"WEBDAV_OVER_CLOUDFLARE_LARGE_PUT=UNSUPPORTED",
		"=============================================",
	}, "\n")
	return a.secretHandoff("PRIVATE DRIVE HANDOFF", handoff)
}

func (a *App) openDriveLocalTunnel(c Connection) error {
	status, err := a.driveStatus(c)
	if err != nil {
		return err
	}
	if status["COPYPARTY_SERVICE"] != "active" || status["COPYPARTY_LOOPBACK_LISTENER"] != "1" {
		return errors.New(a.msg("copyparty 本地回源未就绪。", "The copyparty loopback origin is not ready."))
	}
	localPort, err := a.startTunnel(c, 3923)
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

func (a *App) prepareDriveNginxCandidate(c Connection) error {
	hostname := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("请亲自输入独立网盘 hostname（如 drive.example.com）", "Type the separate drive hostname (for example drive.example.com)"))))
	if !validDomain(hostname) {
		return errors.New(a.msg("网盘 hostname 格式无效。", "Invalid drive hostname."))
	}
	portText := strings.TrimSpace(a.prompt(a.msg("Cloudflare Origin Rule 目标端口 [2087]", "Cloudflare Origin Rule destination port [2087]")))
	if portText == "" {
		portText = "2087"
	}
	if portText != "2053" && portText != "2083" && portText != "2087" && portText != "2096" {
		return errors.New(a.msg("只允许 2053/2083/2087/2096；8443 和 24443 已保留。", "Only 2053/2083/2087/2096 are allowed; 8443 and 24443 are reserved."))
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/31-copyparty-nginx.sh prepare "+shQuote(hostname)+" "+portText)
	if !result.OK() || !strings.Contains(result.Stdout, "PNA_DRIVE_NGINX_NOT_ENABLED=WAITING_FOR_CLOUDFLARE_AND_CERTIFICATE") {
		return fmt.Errorf("drive Nginx candidate failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(strings.TrimSpace(result.Stdout))
	a.println(a.msg("只生成了 root-only 候选配置；没有监听公网端口，也没有改 Cloudflare。", "Only a root-only candidate was generated; no public listener or Cloudflare state was changed."))
	return nil
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
		a.println(a.msg("私人网盘（当前阶段只允许回环/SSH 隧道；橙云步骤仍被阻断）：", "Private drive (loopback/SSH tunnel only in this phase; orange-cloud steps remain blocked):"))
		a.println(a.msg("[1] 安装或重建本地回源（固定版本 + SHA-256）", "[1] Install or rebuild the loopback origin (pinned version + SHA-256)"))
		a.println(a.msg("[2] 查看脱敏状态", "[2] Show redacted status"))
		a.println(a.msg("[3] 轮换账户/密码并做 CRUD 验收", "[3] Rotate account/password and run CRUD verification"))
		a.println(a.msg("[4] 通过 127.0.0.1 SSH 隧道打开网盘", "[4] Open the drive through a 127.0.0.1 SSH tunnel"))
		a.println(a.msg("[5] 仅生成 Nginx/Origin Rule 候选（不启用）", "[5] Generate an Nginx/Origin Rule candidate only (do not enable)"))
		a.println(a.msg("[6] 卸载服务但保留全部用户文件", "[6] Uninstall the service and preserve all user files"))
		a.println(a.msg("[7] 永久删除服务和文件卷（双重确认）", "[7] Permanently delete the service and data volume (double confirmation)"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		switch strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))) {
		case "1":
			return a.installOrRotateDrive(c, false)
		case "2":
			_, err := a.driveStatus(c)
			return err
		case "3":
			return a.installOrRotateDrive(c, true)
		case "4":
			return a.openDriveLocalTunnel(c)
		case "5":
			return a.prepareDriveNginxCandidate(c)
		case "6":
			if !a.yes(a.msg("确认卸载服务但完整保留 /srv/proxy-node-assistant/drive-data？", "Uninstall the service while preserving /srv/proxy-node-assistant/drive-data in full?"), false) {
				return nil
			}
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh uninstall-preserve")
			if !result.OK() || !strings.Contains(result.Stdout, "PNA_DRIVE_UNINSTALLED_DATA_PRESERVED") {
				return fmt.Errorf("drive uninstall failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
			return nil
		case "7":
			a.println(a.msg("这会永久删除网盘文件卷，不能从配置备份恢复。", "This permanently deletes the drive data volume; configuration backups cannot restore it."))
			if strings.TrimSpace(a.prompt(a.msg("第一步请输入大写 DELETE DRIVE DATA", "First type uppercase DELETE DRIVE DATA"))) != "DELETE DRIVE DATA" {
				return nil
			}
			if strings.TrimSpace(a.prompt(a.msg("第二步请输入大写 PURGE-DATA", "Then type uppercase PURGE-DATA"))) != "PURGE-DATA" {
				return nil
			}
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh purge PURGE-DATA")
			if !result.OK() || !strings.Contains(result.Stdout, "PNA_DRIVE_PURGED") {
				return fmt.Errorf("drive purge failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
			return nil
		case "0", "":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
		}
	}
}
