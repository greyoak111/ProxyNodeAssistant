package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/scrypt"
)

const (
	localAdminUsername = "admin"
	localAdminScryptN  = 32768
	localAdminScryptR  = 8
	localAdminScryptP  = 1
)

var localAdminPasswordPattern = regexp.MustCompile(`^[\x20-\x7e]{14,128}$`)
var localAdminPackageIDPattern = regexp.MustCompile(`^tna-admin-recovery-[a-f0-9]{32}$`)

type localAdminVerifier struct {
	Version           int       `json:"version"`
	DeviceID          string    `json:"deviceId"`
	Username          string    `json:"username"`
	Salt              string    `json:"salt"`
	Hash              string    `json:"hash"`
	ScryptN           int       `json:"scryptN"`
	ScryptR           int       `json:"scryptR"`
	ScryptP           int       `json:"scryptP"`
	RecoveryPackageID string    `json:"recoveryPackageId"`
	CreatedAt         time.Time `json:"createdAt"`
	UpdatedAt         time.Time `json:"updatedAt"`
}

type localAdminRecoveryPayload struct {
	Version   int    `json:"version"`
	PackageID string `json:"packageId"`
	DeviceID  string `json:"deviceId"`
	Username  string `json:"username"`
	Password  string `json:"password"`
}

type localAdminRecoveryPackage struct {
	Version    int       `json:"version"`
	PackageID  string    `json:"packageId"`
	DeviceID   string    `json:"deviceId"`
	CreatedAt  time.Time `json:"createdAt"`
	KDF        string    `json:"kdf"`
	ScryptN    int       `json:"scryptN"`
	ScryptR    int       `json:"scryptR"`
	ScryptP    int       `json:"scryptP"`
	Salt       string    `json:"salt"`
	Nonce      string    `json:"nonce"`
	Ciphertext string    `json:"ciphertext"`
}

type localAdminResult struct {
	Status       string `json:"status"`
	DeviceID     string `json:"deviceId,omitempty"`
	Username     string `json:"username,omitempty"`
	Password     string `json:"password,omitempty"`
	RecoveryCode string `json:"recoveryCode,omitempty"`
	RecoveryPath string `json:"recoveryPath,omitempty"`
	Message      string `json:"message,omitempty"`
}

func localAdminVerifierPath() (string, error) {
	root, err := productConfigRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "local-admin-verifier.json"), nil
}

func localAdminCredentialTarget(deviceID string) string {
	return "TextNodeAssistant/v0.9.5/local-admin/" + deviceID
}

func defaultLocalAdminRecoveryPath(deviceID string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Documents", "TextNodeAssistant Recovery", deviceID, "local-admin-recovery.tna"), nil
}

func deriveLocalAdminHash(password string, salt []byte, n, r, p int) ([]byte, error) {
	if !localAdminPasswordPattern.MatchString(password) || len(salt) != 16 || n < 16384 || r < 8 || p < 1 {
		return nil, errors.New("local admin verifier parameters are invalid")
	}
	return scrypt.Key([]byte(password), salt, n, r, p, 32)
}

func newLocalAdminVerifier(deviceID, password, packageID string, created time.Time) (localAdminVerifier, error) {
	var value localAdminVerifier
	if !deviceIDPattern.MatchString(deviceID) || !localAdminPackageIDPattern.MatchString(packageID) || !localAdminPasswordPattern.MatchString(password) {
		return value, errors.New("local admin creation input is invalid")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return value, err
	}
	hash, err := deriveLocalAdminHash(password, salt, localAdminScryptN, localAdminScryptR, localAdminScryptP)
	if err != nil {
		return value, err
	}
	now := time.Now().UTC()
	if created.IsZero() {
		created = now
	}
	value = localAdminVerifier{
		Version: 1, DeviceID: deviceID, Username: localAdminUsername,
		Salt: base64.RawURLEncoding.EncodeToString(salt), Hash: base64.RawURLEncoding.EncodeToString(hash),
		ScryptN: localAdminScryptN, ScryptR: localAdminScryptR, ScryptP: localAdminScryptP,
		RecoveryPackageID: packageID, CreatedAt: created.UTC(), UpdatedAt: now,
	}
	return value, nil
}

func validateLocalAdminVerifier(value localAdminVerifier) error {
	if value.Version != 1 || !deviceIDPattern.MatchString(value.DeviceID) || value.Username != localAdminUsername ||
		!localAdminPackageIDPattern.MatchString(value.RecoveryPackageID) || value.ScryptN < 16384 || value.ScryptR < 8 || value.ScryptP < 1 ||
		value.CreatedAt.IsZero() || value.UpdatedAt.IsZero() {
		return errors.New("local admin verifier metadata is invalid")
	}
	salt, saltErr := base64.RawURLEncoding.DecodeString(value.Salt)
	hash, hashErr := base64.RawURLEncoding.DecodeString(value.Hash)
	if saltErr != nil || hashErr != nil || len(salt) != 16 || len(hash) != 32 {
		return errors.New("local admin verifier encoding is invalid")
	}
	return nil
}

func verifyLocalAdminPassword(value localAdminVerifier, password string) bool {
	if validateLocalAdminVerifier(value) != nil {
		return false
	}
	salt, _ := base64.RawURLEncoding.DecodeString(value.Salt)
	want, _ := base64.RawURLEncoding.DecodeString(value.Hash)
	got, err := deriveLocalAdminHash(password, salt, value.ScryptN, value.ScryptR, value.ScryptP)
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

func (a *App) requireLocalAdminReauthentication(reasonZH, reasonEN string) error {
	verifier, err := loadLocalAdminVerifier()
	if err != nil {
		return fmt.Errorf(a.msg("本机 admin 尚未建立或校验器损坏，不能执行高风险操作：%w", "The local admin is missing or its verifier is corrupt; the high-risk action is blocked: %w"), err)
	}
	a.println(a.msg(reasonZH, reasonEN))
	password := a.secretPromptExact(a.msg("请重新输入本机 admin 密码", "Re-enter the local admin password"))
	if !verifyLocalAdminPassword(verifier, password) {
		return errors.New(a.msg("本机 admin 二次验证失败；没有修改远端。", "Local-admin reauthentication failed; the remote was not changed."))
	}
	return nil
}

func loadLocalAdminVerifier() (localAdminVerifier, error) {
	var value localAdminVerifier
	path, err := localAdminVerifierPath()
	if err != nil {
		return value, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return value, err
	}
	if json.Unmarshal(data, &value) != nil || validateLocalAdminVerifier(value) != nil {
		return value, errors.New("local admin verifier is corrupt")
	}
	return value, nil
}

func writeLocalAdminVerifier(value localAdminVerifier) error {
	if err := validateLocalAdminVerifier(value); err != nil {
		return err
	}
	path, err := localAdminVerifierPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".local-admin-verifier-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func localAdminRecoveryAAD(pkg localAdminRecoveryPackage) []byte {
	return []byte("TNA-LOCAL-ADMIN-RECOVERY-V1\nPACKAGE_ID=" + pkg.PackageID + "\nDEVICE_ID=" + pkg.DeviceID + "\n")
}

func makeLocalAdminRecovery(deviceID, password string) (localAdminRecoveryPackage, string, error) {
	var pkg localAdminRecoveryPackage
	packageID, err := randomToken("tna-admin-recovery-", 16)
	if err != nil {
		return pkg, "", err
	}
	codeBytes := make([]byte, 20)
	if _, err := rand.Read(codeBytes); err != nil {
		return pkg, "", err
	}
	code := strings.ToUpper(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(codeBytes))
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return pkg, "", err
	}
	key, err := scrypt.Key([]byte(code), salt, localAdminScryptN, localAdminScryptR, localAdminScryptP, 32)
	if err != nil {
		return pkg, "", err
	}
	pkg = localAdminRecoveryPackage{
		Version: 1, PackageID: packageID, DeviceID: deviceID, CreatedAt: time.Now().UTC(), KDF: "scrypt",
		ScryptN: localAdminScryptN, ScryptR: localAdminScryptR, ScryptP: localAdminScryptP,
		Salt: base64.RawURLEncoding.EncodeToString(salt),
	}
	payload, err := json.Marshal(localAdminRecoveryPayload{Version: 1, PackageID: packageID, DeviceID: deviceID, Username: localAdminUsername, Password: password})
	if err != nil {
		return pkg, "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return pkg, "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return pkg, "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return pkg, "", err
	}
	pkg.Nonce = base64.RawURLEncoding.EncodeToString(nonce)
	pkg.Ciphertext = base64.RawURLEncoding.EncodeToString(gcm.Seal(nil, nonce, payload, localAdminRecoveryAAD(pkg)))
	return pkg, code, nil
}

func decryptLocalAdminRecovery(pkg localAdminRecoveryPackage, code string) (localAdminRecoveryPayload, error) {
	var payload localAdminRecoveryPayload
	if pkg.Version != 1 || pkg.KDF != "scrypt" || !localAdminPackageIDPattern.MatchString(pkg.PackageID) || !deviceIDPattern.MatchString(pkg.DeviceID) ||
		pkg.ScryptN < 16384 || pkg.ScryptR < 8 || pkg.ScryptP < 1 {
		return payload, errors.New("local admin recovery package metadata is invalid")
	}
	salt, err := base64.RawURLEncoding.DecodeString(pkg.Salt)
	if err != nil || len(salt) != 16 {
		return payload, errors.New("local admin recovery salt is invalid")
	}
	key, err := scrypt.Key([]byte(strings.ToUpper(strings.TrimSpace(code))), salt, pkg.ScryptN, pkg.ScryptR, pkg.ScryptP, 32)
	if err != nil {
		return payload, err
	}
	nonce, nonceErr := base64.RawURLEncoding.DecodeString(pkg.Nonce)
	sealed, sealedErr := base64.RawURLEncoding.DecodeString(pkg.Ciphertext)
	block, blockErr := aes.NewCipher(key)
	if nonceErr != nil || sealedErr != nil || blockErr != nil {
		return payload, errors.New("local admin recovery ciphertext is invalid")
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil || len(nonce) != gcm.NonceSize() {
		return payload, errors.New("local admin recovery nonce is invalid")
	}
	plain, err := gcm.Open(nil, nonce, sealed, localAdminRecoveryAAD(pkg))
	if err != nil || json.Unmarshal(plain, &payload) != nil || payload.Version != 1 || payload.PackageID != pkg.PackageID || payload.DeviceID != pkg.DeviceID || payload.Username != localAdminUsername || !localAdminPasswordPattern.MatchString(payload.Password) {
		return localAdminRecoveryPayload{}, errors.New("recovery code is wrong or the package was modified")
	}
	return payload, nil
}

func writeLocalAdminRecoveryPackage(path string, pkg localAdminRecoveryPackage) error {
	path = filepath.Clean(path)
	if !strings.EqualFold(filepath.Ext(path), ".tna") {
		return errors.New("local admin recovery package must use the .tna extension")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(pkg, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".local-admin-recovery-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func readLocalAdminRecoveryPackage(path string) (localAdminRecoveryPackage, error) {
	var pkg localAdminRecoveryPackage
	data, err := os.ReadFile(filepath.Clean(path))
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &pkg) != nil {
		return pkg, errors.New("local admin recovery package is unreadable or invalid")
	}
	return pkg, nil
}

func saveLocalAdminCredential(deviceID, password string) error {
	return credentialWrite(localAdminCredentialTarget(deviceID), localAdminUsername, password)
}

func commitLocalAdmin(password string, old localAdminVerifier, recoveryPath string) (localAdminResult, error) {
	var result localAdminResult
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return result, err
	}
	pkg, code, err := makeLocalAdminRecovery(identity.DeviceID, password)
	if err != nil {
		return result, err
	}
	if recoveryPath == "" {
		recoveryPath, err = defaultLocalAdminRecoveryPath(identity.DeviceID)
		if err != nil {
			return result, err
		}
	}
	created := old.CreatedAt
	verifier, err := newLocalAdminVerifier(identity.DeviceID, password, pkg.PackageID, created)
	if err != nil {
		return result, err
	}
	if err := os.MkdirAll(filepath.Dir(recoveryPath), 0700); err != nil {
		return result, err
	}
	pending, err := os.CreateTemp(filepath.Dir(recoveryPath), ".local-admin-recovery-pending-*.tna")
	if err != nil {
		return result, err
	}
	pendingPath := pending.Name()
	if err := pending.Close(); err != nil {
		return result, err
	}
	_ = os.Remove(pendingPath)
	defer os.Remove(pendingPath)
	// Stage the new package first. The old package, verifier and system
	// credential remain usable until every new artifact is ready to commit.
	if err := writeLocalAdminRecoveryPackage(pendingPath, pkg); err != nil {
		return result, err
	}
	oldCredential := ""
	if !old.CreatedAt.IsZero() {
		oldCredential, _ = credentialRead(localAdminCredentialTarget(old.DeviceID))
	}
	previousPath := ""
	if _, statErr := os.Stat(recoveryPath); statErr == nil {
		backup, backupErr := os.CreateTemp(filepath.Dir(recoveryPath), ".local-admin-recovery-previous-*.tna")
		if backupErr != nil {
			return result, backupErr
		}
		previousPath = backup.Name()
		_ = backup.Close()
		_ = os.Remove(previousPath)
		if backupErr = os.Rename(recoveryPath, previousPath); backupErr != nil {
			return result, backupErr
		}
	}
	rollback := func() {
		if previousPath != "" {
			_ = os.Remove(recoveryPath)
			_ = os.Rename(previousPath, recoveryPath)
		}
		if !old.CreatedAt.IsZero() {
			_ = writeLocalAdminVerifier(old)
			if oldCredential != "" {
				_ = credentialWrite(localAdminCredentialTarget(old.DeviceID), localAdminUsername, oldCredential)
			}
		} else {
			if verifierPath, pathErr := localAdminVerifierPath(); pathErr == nil {
				_ = os.Remove(verifierPath)
			}
			_ = credentialDelete(localAdminCredentialTarget(identity.DeviceID))
		}
	}
	if err := saveLocalAdminCredential(identity.DeviceID, password); err != nil {
		rollback()
		return result, err
	}
	if err := writeLocalAdminVerifier(verifier); err != nil {
		rollback()
		return result, err
	}
	if err := os.Rename(pendingPath, recoveryPath); err != nil {
		rollback()
		return result, fmt.Errorf("could not commit the local admin recovery package: %w", err)
	}
	if previousPath != "" {
		_ = os.Remove(previousPath)
	}
	return localAdminResult{Status: "READY", DeviceID: identity.DeviceID, Username: localAdminUsername, Password: password, RecoveryCode: code, RecoveryPath: recoveryPath}, nil
}

func readLocalAdminProtocolLines(input io.Reader, count int) ([]string, error) {
	reader := bufio.NewReader(input)
	values := make([]string, 0, count)
	for len(values) < count {
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			return nil, io.ErrUnexpectedEOF
		}
		line = strings.TrimSuffix(line, "\n")
		line = strings.TrimSuffix(line, "\r")
		values = append(values, line)
		if err != nil && len(values) < count {
			return nil, io.ErrUnexpectedEOF
		}
	}
	return values, nil
}

func printLocalAdminResult(value localAdminResult) {
	data, _ := json.Marshal(value)
	fmt.Println("TNA_LOCAL_ADMIN_RESULT_B64=" + base64.StdEncoding.EncodeToString(data))
}

func requestedLocalAdminCommand(args []string) string {
	for index := 0; index+1 < len(args); index++ {
		if args[index] == "--local-admin" {
			return strings.ToLower(strings.TrimSpace(args[index+1]))
		}
	}
	return ""
}

func runLocalAdminCommand(command string, input io.Reader) int {
	value, err := loadLocalAdminVerifier()
	switch command {
	case "status":
		if errors.Is(err, os.ErrNotExist) {
			printLocalAdminResult(localAdminResult{Status: "NOT_CONFIGURED", Username: localAdminUsername})
			return 0
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=VERIFIER_CORRUPT")
			return 2
		}
		printLocalAdminResult(localAdminResult{Status: "READY", DeviceID: value.DeviceID, Username: value.Username})
		return 0
	case "create":
		if err == nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=ALREADY_CONFIGURED")
			return 3
		}
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=VERIFIER_CORRUPT")
			return 2
		}
		lines, readErr := readLocalAdminProtocolLines(input, 3)
		if readErr != nil || lines[0] != lines[1] || !localAdminPasswordPattern.MatchString(lines[0]) {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=PASSWORD_POLICY_OR_CONFIRMATION")
			return 4
		}
		result, commitErr := commitLocalAdmin(lines[0], localAdminVerifier{}, lines[2])
		if commitErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR="+commitErr.Error())
			return 5
		}
		printLocalAdminResult(result)
		return 0
	case "verify":
		if err != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=NOT_CONFIGURED")
			return 6
		}
		lines, readErr := readLocalAdminProtocolLines(input, 1)
		if readErr != nil || !verifyLocalAdminPassword(value, lines[0]) {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=AUTHENTICATION_FAILED")
			return 7
		}
		printLocalAdminResult(localAdminResult{Status: "VERIFIED", DeviceID: value.DeviceID, Username: value.Username})
		return 0
	case "recover-system":
		if err != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=NOT_CONFIGURED")
			return 6
		}
		password, readErr := credentialRead(localAdminCredentialTarget(value.DeviceID))
		if readErr != nil || !verifyLocalAdminPassword(value, password) {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=SYSTEM_RECOVERY_UNAVAILABLE")
			return 8
		}
		printLocalAdminResult(localAdminResult{Status: "RECOVERED", DeviceID: value.DeviceID, Username: value.Username, Password: password})
		return 0
	case "change":
		if err != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=NOT_CONFIGURED")
			return 6
		}
		lines, readErr := readLocalAdminProtocolLines(input, 4)
		if readErr != nil || !verifyLocalAdminPassword(value, lines[0]) || lines[1] != lines[2] || !localAdminPasswordPattern.MatchString(lines[1]) {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=AUTHENTICATION_POLICY_OR_CONFIRMATION")
			return 7
		}
		result, commitErr := commitLocalAdmin(lines[1], value, lines[3])
		if commitErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR="+commitErr.Error())
			return 5
		}
		printLocalAdminResult(result)
		return 0
	case "recover-package":
		lines, readErr := readLocalAdminProtocolLines(input, 2)
		if readErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=RECOVERY_INPUT_MISSING")
			return 9
		}
		pkg, packageErr := readLocalAdminRecoveryPackage(lines[0])
		if packageErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=RECOVERY_PACKAGE_INVALID")
			return 9
		}
		payload, decryptErr := decryptLocalAdminRecovery(pkg, lines[1])
		if decryptErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=RECOVERY_AUTHENTICATION_FAILED")
			return 9
		}
		result, commitErr := commitLocalAdmin(payload.Password, localAdminVerifier{}, "")
		if commitErr != nil {
			fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR="+commitErr.Error())
			return 5
		}
		result.Status = "RECOVERED_AND_REKEYED"
		printLocalAdminResult(result)
		return 0
	default:
		fmt.Fprintln(os.Stderr, "TNA_LOCAL_ADMIN_ERROR=USAGE")
		return 2
	}
}

func (a *App) changeLocalAdminInteractive() error {
	current, err := loadLocalAdminVerifier()
	if err != nil {
		return errors.New(a.msg("本机 admin 尚未创建或记录损坏；请从外层登录页使用恢复入口。", "Local admin is not configured or its record is damaged; use recovery on the outer login page."))
	}
	oldPassword := a.secretPromptExact(a.msg("再次输入当前本机 admin 密码", "Re-enter the current local admin password"))
	newPassword := a.secretPromptExact(a.msg("输入新的本机 admin 密码（14—128 位可打印 ASCII）", "Enter the new local admin password (14-128 printable ASCII)"))
	confirmation := a.secretPromptExact(a.msg("再次输入新的本机 admin 密码", "Enter the new local admin password again"))
	if !verifyLocalAdminPassword(current, oldPassword) || newPassword != confirmation || !localAdminPasswordPattern.MatchString(newPassword) {
		return errors.New(a.msg("当前密码错误，或新密码不一致/不符合策略；本机记录未修改。", "The current password is wrong, or the new passwords differ/violate policy; local state was not changed."))
	}
	result, err := commitLocalAdmin(newPassword, current, "")
	if err != nil {
		return err
	}
	handoff := "LOCAL_ADMIN_USERNAME=admin\nLOCAL_ADMIN_PASSWORD=" + newPassword + "\nLOCAL_ADMIN_RECOVERY_CODE=" + result.RecoveryCode + "\nLOCAL_ADMIN_RECOVERY_PACKAGE=" + result.RecoveryPath
	return a.secretHandoff("UPDATED LOCAL ADMIN RECOVERY HANDOFF", handoff)
}
