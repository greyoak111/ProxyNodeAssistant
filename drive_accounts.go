package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

type driveAccountRecord struct {
	AccountID string
	SpaceID   string
	Role      string
	Status    string
	Username  string
	QuotaGiB  string
	CreatedAt string
}

type driveAccountSecretResult struct {
	Version   int    `json:"version"`
	NodeID    string `json:"nodeId"`
	AccountID string `json:"accountId"`
	SpaceID   string `json:"spaceId"`
	Username  string `json:"username"`
	Password  string `json:"password"`
	QuotaGiB  string `json:"quotaGiB,omitempty"`
}

func driveCredentialTarget(nodeID, accountID string) string {
	return "TextNodeAssistant/v0.9.5/drive/" + nodeID + "/" + accountID
}

func parseDriveAccountList(stdout string) ([]driveAccountRecord, error) {
	block, err := extractMarkerBlock(stdout, "__TNA_DRIVE_ACCOUNT_LIST_BEGIN__", "__TNA_DRIVE_ACCOUNT_LIST_END__")
	if err != nil {
		return nil, err
	}
	result := []driveAccountRecord{}
	for _, line := range strings.Split(block, "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) != 7 || !strings.HasPrefix(parts[0], "ACCOUNT=") {
			return nil, errors.New("drive account-list protocol is invalid")
		}
		record := driveAccountRecord{AccountID: strings.TrimPrefix(parts[0], "ACCOUNT="), SpaceID: parts[1], Role: parts[2], Status: parts[3], Username: parts[4], QuotaGiB: parts[5], CreatedAt: parts[6]}
		if !driveAccountIDPattern.MatchString(record.AccountID) || !driveSpaceIDPattern.MatchString(record.SpaceID) || !driveUsernamePattern.MatchString(record.Username) ||
			(record.Role != "admin" && record.Role != "ordinary") || (record.Status != "active" && record.Status != "paused" && record.Status != "revoked") {
			return nil, errors.New("drive account-list record is invalid")
		}
		result = append(result, record)
	}
	return result, nil
}

func (a *App) requireLocalActiveController(c Connection) (DeviceIdentity, DeviceStatus, error) {
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return identity, DeviceStatus{}, err
	}
	status, err := a.getDeviceStatus(c)
	if err != nil {
		return identity, status, err
	}
	for _, device := range status.Devices {
		if device.DeviceID == identity.DeviceID && device.Role == "controller" && device.Status == "active" {
			return identity, status, nil
		}
	}
	return identity, status, errors.New(a.msg("当前设备不是该节点的 active controller，不能创建或恢复网盘真实凭据。", "This device is not an active controller for the node, so it cannot create or recover real drive credentials."))
}

func (a *App) controllerEncryptionKeys(c Connection, identity DeviceIdentity) ([]controllerEncryptionKey, error) {
	return a.controllerEncryptionKeysMode(c, identity, false)
}

func (a *App) controllerEncryptionKeysMode(c Connection, identity DeviceIdentity, includePending bool) ([]controllerEncryptionKey, error) {
	command := "bash " + remoteRoot + "/linux/26-device-admission.sh controller-encryption-keys " + shQuote(identity.DeviceID)
	if includePending {
		command += " include-pending"
	}
	result := a.rootCapture(c, command)
	if !result.OK() {
		return nil, fmt.Errorf("controller encryption-key query failed: %s", processFailureDetail(result))
	}
	return parseControllerEncryptionKeys(result.Stdout)
}

// preparePendingControllerEscrow gives every pending controller a protected
// envelope for each existing ordinary drive account before its first SSH key
// login may activate it.  The VPS never sees the plaintext password: the
// current controller decrypts locally and sends only a newly authenticated
// ciphertext/envelope set back to the node.  Partial progress is retry-safe;
// claim-forced remains fail-closed until all accounts cover the new controller.
func (a *App) preparePendingControllerEscrow(c Connection, current DeviceIdentity, pendingDeviceID string) error {
	if !deviceIDPattern.MatchString(pendingDeviceID) {
		return errors.New("invalid pending controller device ID")
	}
	accounts, err := a.listDriveAccounts(c)
	if err != nil {
		return err
	}
	ordinary := make([]driveAccountRecord, 0, len(accounts))
	for _, account := range accounts {
		if account.Role == "ordinary" && (account.Status == "active" || account.Status == "paused") {
			ordinary = append(ordinary, account)
		}
	}
	if len(ordinary) == 0 {
		return nil
	}
	controllers, err := a.controllerEncryptionKeysMode(c, current, true)
	if err != nil {
		return err
	}
	pendingFound := false
	for _, controller := range controllers {
		if controller.DeviceID == pendingDeviceID {
			pendingFound = true
			break
		}
	}
	if !pendingFound {
		return errors.New("pending controller encryption key was not returned by the node")
	}
	private, err := loadDeviceEncryptionPrivate(current)
	if err != nil {
		return err
	}
	for _, account := range ordinary {
		existing, err := a.readDriveEscrow(c, account.AccountID)
		if err != nil {
			return fmt.Errorf("read escrow %s: %w", account.AccountID, err)
		}
		password, err := decryptDriveCredential(existing, current, private)
		if err != nil {
			return fmt.Errorf("decrypt escrow %s: %w", account.AccountID, err)
		}
		rewrapped, err := encryptDriveCredential(existing.NodeID, account.AccountID, account.SpaceID, account.Username, password, controllers)
		if err != nil {
			return fmt.Errorf("rewrap escrow %s: %w", account.AccountID, err)
		}
		encoded, err := encodeDriveEscrow(rewrapped)
		if err != nil {
			return err
		}
		command := "bash " + remoteRoot + "/linux/30-copyparty-account.sh replace-escrow " + shQuote(current.DeviceID) + " " + shQuote(account.AccountID)
		result := a.rootCaptureWithInput(c, command, []byte(encoded+"\n"))
		if !result.OK() || !strings.Contains(result.Stdout, "TNA_DRIVE_ESCROW_REPLACED=1") {
			return fmt.Errorf("replace escrow %s failed: %s", account.AccountID, processFailureDetail(result))
		}
		readback, err := a.readDriveEscrow(c, account.AccountID)
		if err != nil {
			return err
		}
		verified, err := decryptDriveCredential(readback, current, private)
		if err != nil || verified != password {
			return fmt.Errorf("rewrapped escrow %s failed authenticated readback", account.AccountID)
		}
	}
	return nil
}

func (a *App) readDriveEscrow(c Connection, accountID string) (driveCredentialEscrow, error) {
	if !driveAccountIDPattern.MatchString(accountID) {
		return driveCredentialEscrow{}, errors.New("invalid drive account ID")
	}
	path := "/etc/text-node-assistant/drive-credential-escrow/" + accountID + ".json"
	result := a.rootCapture(c, "set -eu; test -f "+shQuote(path)+"; base64 -w0 "+shQuote(path))
	if !result.OK() {
		return driveCredentialEscrow{}, fmt.Errorf("drive escrow readback failed: %s", processFailureDetail(result))
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(result.Stdout))
	if err != nil {
		return driveCredentialEscrow{}, errors.New("drive escrow readback encoding is invalid")
	}
	return decodeDriveEscrow(base64.RawURLEncoding.EncodeToString(raw))
}

func (a *App) chooseOrdinaryDrivePassword() (string, error) {
	a.println(a.msg("[1] 生成高强度密码并完整交接（推荐）", "[1] Generate a strong password and hand it off in full (recommended)"))
	a.println(a.msg("[2] 自定义密码（遮罩输入两次）", "[2] Custom password (masked twice)"))
	choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
	if choice == "" || choice == "1" {
		return randomDrivePassword()
	}
	if choice != "2" {
		return "", errInputClosed
	}
	first := a.secretPromptExact(a.msg("输入普通网盘密码（14—128 位可打印 ASCII）", "Enter the ordinary drive password (14-128 printable ASCII characters)"))
	second := a.secretPromptExact(a.msg("再次输入同一密码", "Enter the same password again"))
	if first != second || !drivePasswordPattern.MatchString(first) {
		return "", errors.New(a.msg("密码不一致或不符合 14—128 位可打印 ASCII 策略。", "The passwords differ or do not meet the 14-128 printable-ASCII policy."))
	}
	return first, nil
}

func (a *App) registerOrdinaryDriveAccount(c Connection) error {
	username := strings.TrimSpace(a.prompt(a.msg("普通网盘用户名（3—32 位；不能用 admin/root）", "Ordinary drive username (3-32 characters; admin/root are reserved)")))
	password, err := a.chooseOrdinaryDrivePassword()
	if err != nil {
		return err
	}
	quota, err := a.chooseDriveQuota()
	if err != nil {
		return err
	}
	result, err := a.registerOrdinaryDriveAccountValues(c, username, password, password, quota)
	if err != nil {
		return err
	}
	handoff := strings.Join([]string{
		"===== TNA ORDINARY DRIVE ACCOUNT HANDOFF v0.9.5 =====",
		"NODE_ID=" + result.NodeID,
		"DRIVE_ACCOUNT_ID=" + result.AccountID,
		"DRIVE_SPACE_ID=" + result.SpaceID,
		"DRIVE_USERNAME=" + result.Username,
		"DRIVE_PASSWORD=" + result.Password,
		"DRIVE_QUOTA_GIB=" + result.QuotaGiB,
		"DRIVE_ACCESS=TRUSTED_DEVICE_SSH_TUNNEL_ONLY",
		"======================================================",
	}, "\n")
	return a.secretHandoff("ORDINARY DRIVE ACCOUNT HANDOFF", handoff)
}

func (a *App) registerOrdinaryDriveAccountValues(c Connection, username, password, confirmation, quota string) (driveAccountSecretResult, error) {
	identity, status, err := a.requireLocalActiveController(c)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	username = strings.TrimSpace(username)
	quota = strings.ToLower(strings.TrimSpace(quota))
	if !driveUsernamePattern.MatchString(username) || strings.EqualFold(username, "admin") || strings.EqualFold(username, "root") || driveAdminPattern.MatchString(username) {
		return driveAccountSecretResult{}, errors.New(a.msg("普通网盘用户名无效或属于保留名。", "The ordinary drive username is invalid or reserved."))
	}
	if password != confirmation || !drivePasswordPattern.MatchString(password) {
		return driveAccountSecretResult{}, errors.New(a.msg("密码不一致或不符合 14—128 位可打印 ASCII 策略。", "The passwords differ or do not meet the 14-128 printable-ASCII policy."))
	}
	if quota == "" {
		quota = "auto"
	}
	if quota != "auto" {
		value, parseErr := strconv.Atoi(quota)
		if parseErr != nil || value < 1 || value > 50 {
			return driveAccountSecretResult{}, errors.New(a.msg("容量必须为 auto 或 1—50 GiB。", "Quota must be auto or 1-50 GiB."))
		}
	}
	accountID, err := randomToken("tna-account-", 16)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	spaceID, err := randomToken("tna-space-", 16)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	controllers, err := a.controllerEncryptionKeys(c, identity)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	escrow, err := encryptDriveCredential(status.NodeID, accountID, spaceID, username, password, controllers)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	encodedEscrow, err := encodeDriveEscrow(escrow)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	command := "bash " + remoteRoot + "/linux/30-copyparty-account.sh register " + shQuote(username) + " " + shQuote(quota) + " " + shQuote(accountID) + " " + shQuote(spaceID)
	result := a.rootCaptureWithInput(c, command, []byte(password+"\n"+encodedEscrow+"\n"))
	if !result.OK() || !strings.Contains(result.Stdout, "DRIVE_ACCOUNT_CREATED=1") || !strings.Contains(result.Stdout, "DRIVE_ACCOUNT_ID="+accountID) || !strings.Contains(result.Stdout, "DRIVE_SPACE_ID="+spaceID) {
		return driveAccountSecretResult{}, fmt.Errorf(a.msg("网盘账号注册事务失败：", "Drive account registration transaction failed: ") + processFailureDetail(result))
	}
	readback, err := a.readDriveEscrow(c, accountID)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	private, err := loadDeviceEncryptionPrivate(identity)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	recovered, err := decryptDriveCredential(readback, identity, private)
	if err != nil || recovered != password {
		return driveAccountSecretResult{}, errors.New("drive escrow readback did not reproduce the verified credential")
	}
	if err := credentialWrite(driveCredentialTarget(status.NodeID, accountID), username, password); err != nil {
		return driveAccountSecretResult{}, fmt.Errorf("remote registration succeeded but local credential protection failed: %w", err)
	}
	return driveAccountSecretResult{Version: 1, NodeID: status.NodeID, AccountID: accountID, SpaceID: spaceID, Username: username, Password: password, QuotaGiB: parseKV(result.Stdout)["DRIVE_ACCOUNT_QUOTA_GIB"]}, nil
}

func (a *App) listDriveAccounts(c Connection) ([]driveAccountRecord, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/30-copyparty-account.sh list")
	if !result.OK() {
		return nil, fmt.Errorf("drive account list failed: %s", processFailureDetail(result))
	}
	return parseDriveAccountList(result.Stdout)
}

func (a *App) showRecoverableDriveCredential(c Connection) error {
	identity, status, err := a.requireLocalActiveController(c)
	if err != nil {
		return err
	}
	accounts, err := a.listDriveAccounts(c)
	if err != nil {
		return err
	}
	for _, account := range accounts {
		a.println(fmt.Sprintf("%s role=%s status=%s username=%s quota=%sGiB", account.AccountID, account.Role, account.Status, account.Username, account.QuotaGiB))
	}
	accountID := strings.TrimSpace(a.prompt(a.msg("要恢复交接的普通 DRIVE_ACCOUNT_ID", "Ordinary DRIVE_ACCOUNT_ID to recover")))
	var selected *driveAccountRecord
	for index := range accounts {
		if accounts[index].AccountID == accountID && accounts[index].Role == "ordinary" && accounts[index].Status != "revoked" {
			selected = &accounts[index]
			break
		}
	}
	if selected == nil {
		return errors.New("active ordinary drive account was not found")
	}
	escrow, err := a.readDriveEscrow(c, accountID)
	if err != nil {
		return err
	}
	private, err := loadDeviceEncryptionPrivate(identity)
	if err != nil {
		return err
	}
	password, err := decryptDriveCredential(escrow, identity, private)
	if err != nil {
		return err
	}
	if err := credentialWrite(driveCredentialTarget(status.NodeID, accountID), selected.Username, password); err != nil {
		return err
	}
	return a.secretHandoff("RECOVERED ORDINARY DRIVE CREDENTIAL", "NODE_ID="+status.NodeID+"\nDRIVE_ACCOUNT_ID="+accountID+"\nDRIVE_SPACE_ID="+selected.SpaceID+"\nDRIVE_USERNAME="+selected.Username+"\nDRIVE_PASSWORD="+password)
}

func (a *App) changeOrdinaryDrivePassword(c Connection) error {
	username := strings.TrimSpace(a.prompt(a.msg("要改密的普通网盘用户名", "Ordinary drive username to update")))
	oldPassword := a.secretPromptExact(a.msg("输入当前密码", "Enter the current password"))
	newPassword := a.secretPromptExact(a.msg("输入新密码（14—128 位可打印 ASCII）", "Enter the new password (14-128 printable ASCII characters)"))
	confirmation := a.secretPromptExact(a.msg("再次输入新密码", "Enter the new password again"))
	result, err := a.changeOrdinaryDrivePasswordValues(c, username, oldPassword, newPassword, confirmation)
	if err != nil {
		return err
	}
	return a.secretHandoff("UPDATED ORDINARY DRIVE CREDENTIAL", "NODE_ID="+result.NodeID+"\nDRIVE_ACCOUNT_ID="+result.AccountID+"\nDRIVE_SPACE_ID="+result.SpaceID+"\nDRIVE_USERNAME="+result.Username+"\nDRIVE_PASSWORD="+result.Password)
}

func (a *App) changeOrdinaryDrivePasswordValues(c Connection, username, oldPassword, newPassword, confirmation string) (driveAccountSecretResult, error) {
	identity, status, err := a.requireLocalActiveController(c)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	username = strings.TrimSpace(username)
	accounts, err := a.listDriveAccounts(c)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	var selected *driveAccountRecord
	for index := range accounts {
		if accounts[index].Username == username && accounts[index].Role == "ordinary" && accounts[index].Status == "active" {
			selected = &accounts[index]
			break
		}
	}
	if selected == nil {
		return driveAccountSecretResult{}, errors.New(a.msg("没有找到 active 普通账号；admin 必须在内层单独改密。", "No active ordinary account was found; admin credentials must be changed separately in the inner console."))
	}
	if !drivePasswordPattern.MatchString(oldPassword) || newPassword != confirmation || !drivePasswordPattern.MatchString(newPassword) {
		return driveAccountSecretResult{}, errors.New(a.msg("当前密码无效，或新密码不一致/不符合策略；远端未修改。", "The current password is invalid, or the new passwords differ/violate policy; the remote account was not changed."))
	}
	controllers, err := a.controllerEncryptionKeys(c, identity)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	escrow, err := encryptDriveCredential(status.NodeID, selected.AccountID, selected.SpaceID, username, newPassword, controllers)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	encoded, err := encodeDriveEscrow(escrow)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/30-copyparty-account.sh change-password "+shQuote(username), []byte(oldPassword+"\n"+newPassword+"\n"+confirmation+"\n"+encoded+"\n"))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_DRIVE_ACCOUNT_PASSWORD_CHANGED=1") {
		return driveAccountSecretResult{}, fmt.Errorf(a.msg("普通网盘改密事务失败：", "Ordinary drive password-change transaction failed: ") + processFailureDetail(result))
	}
	readback, err := a.readDriveEscrow(c, selected.AccountID)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	private, err := loadDeviceEncryptionPrivate(identity)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	recovered, err := decryptDriveCredential(readback, identity, private)
	if err != nil || recovered != newPassword {
		return driveAccountSecretResult{}, errors.New("new drive credential escrow failed authenticated readback")
	}
	if err := credentialWrite(driveCredentialTarget(status.NodeID, selected.AccountID), username, newPassword); err != nil {
		return driveAccountSecretResult{}, fmt.Errorf("remote password changed but the local protected credential could not be updated: %w", err)
	}
	return driveAccountSecretResult{Version: 1, NodeID: status.NodeID, AccountID: selected.AccountID, SpaceID: selected.SpaceID, Username: username, Password: newPassword, QuotaGiB: selected.QuotaGiB}, nil
}

// changeOrdinaryDrivePasswordTraffic permits an active traffic-only device to
// change an ordinary account it already knows.  The forced SSH dispatcher
// exposes only public controller encryption keys and the selected account's
// non-secret IDs; the old password is authenticated transactionally by the
// remote account helper.  No general shell or controller privilege is granted.
func (a *App) changeOrdinaryDrivePasswordTraffic(c Connection, admission localDeviceAdmission, username, oldPassword, newPassword, confirmation string) (driveAccountSecretResult, error) {
	username = strings.TrimSpace(username)
	if admission.Role != "traffic-only" || !driveUsernamePattern.MatchString(username) || strings.EqualFold(username, "admin") || !drivePasswordPattern.MatchString(oldPassword) || newPassword != confirmation || !drivePasswordPattern.MatchString(newPassword) {
		return driveAccountSecretResult{}, errors.New(a.msg("当前密码无效，或新密码不一致/不符合策略；远端未修改。", "The current password is invalid, or the new passwords differ/violate policy; the remote account was not changed."))
	}
	contextResult := a.sshCapture(c, "drive-change-context "+username)
	if !contextResult.OK() {
		return driveAccountSecretResult{}, fmt.Errorf("restricted password-change context failed: %s", processFailureDetail(contextResult))
	}
	context, err := parseTrafficDriveChangeContext(contextResult.Stdout)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	if context.NodeID != admission.NodeID || context.Username != username {
		return driveAccountSecretResult{}, errors.New("restricted password-change context target mismatch")
	}
	escrow, err := encryptDriveCredential(context.NodeID, context.AccountID, context.SpaceID, username, newPassword, context.Controllers)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	encoded, err := encodeDriveEscrow(escrow)
	if err != nil {
		return driveAccountSecretResult{}, err
	}
	result := a.sshCaptureWithInput(c, "drive-change-password "+username, []byte(oldPassword+"\n"+newPassword+"\n"+confirmation+"\n"+encoded+"\n"))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_DRIVE_ACCOUNT_PASSWORD_CHANGED=1") || !strings.Contains(result.Stdout, "DRIVE_ACCOUNT_ID="+context.AccountID) {
		return driveAccountSecretResult{}, fmt.Errorf(a.msg("普通网盘改密事务失败：", "Ordinary drive password-change transaction failed: ") + processFailureDetail(result))
	}
	localPort, err := a.startTunnel(c, admission.DrivePort)
	if err != nil {
		return driveAccountSecretResult{}, fmt.Errorf("password changed but restricted tunnel verification failed: %w", err)
	}
	defer a.killTunnels()
	if err := verifyLocalDriveCredential(fmt.Sprintf("http://127.0.0.1:%d/", localPort), username, newPassword); err != nil {
		return driveAccountSecretResult{}, fmt.Errorf("password changed but authenticated endpoint readback failed: %w", err)
	}
	if err := credentialWrite(driveCredentialTarget(context.NodeID, context.AccountID), username, newPassword); err != nil {
		return driveAccountSecretResult{}, fmt.Errorf("password changed but local protected credential update failed: %w", err)
	}
	return driveAccountSecretResult{Version: 1, NodeID: context.NodeID, AccountID: context.AccountID, SpaceID: context.SpaceID, Username: username, Password: newPassword, QuotaGiB: context.QuotaGiB}, nil
}
