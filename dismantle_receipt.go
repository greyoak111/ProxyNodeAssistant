package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// dismantleReceiptSchemaVersion is intentionally separate from the remote
// state schema.  A receipt is local evidence that a rescue archive was saved
// and a baseline operation completed; it is not a credential or a remote
// admission record.
const dismantleReceiptSchemaVersion = 1

// DismantleReceipt is deliberately secret-free.  It contains enough stable
// identity and rescue evidence to recognise a previously restored VPS, while
// never persisting passwords, private keys, subscription links, API tokens,
// or handoff text.
type DismantleReceipt struct {
	SchemaVersion        int      `json:"schemaVersion"`
	Product              string   `json:"product"`
	ProductVersion       string   `json:"productVersion"`
	DesktopBuildID       string   `json:"desktopBuildId"`
	ReceiptStatus        string   `json:"receiptStatus"`
	CompletedAtUTC       string   `json:"completedAtUtc"`
	TransactionID        string   `json:"transactionId"`
	Mode                 string   `json:"mode"`
	Action               string   `json:"action"`
	RestoreGrade         string   `json:"restoreGrade"`
	RemovedResourceIDs   []string `json:"removedResourceIds"`
	PreservedResourceIDs []string `json:"preservedResourceIds"`
	PostLifecycle        string   `json:"postLifecycle"`
	PostVerification     string   `json:"postVerification"`

	NodeID              string `json:"nodeId"`
	ServerID            string `json:"serverId"`
	MachineIDHash       string `json:"machineIdSha256"`
	SSHHostKeyAlgorithm string `json:"sshHostKeyAlgorithm"`
	SSHHostKeySHA256    string `json:"sshHostKeySha256"`
	FirstKnownPublicIP  string `json:"firstKnownPublicIp"`
	CurrentPublicIP     string `json:"currentPublicIp"`

	ConnectionHost string `json:"connectionHost"`
	ConnectionUser string `json:"connectionUser"`
	ConnectionPort int    `json:"connectionPort"`

	RescueArchivePath   string `json:"rescueArchivePath"`
	RescueArchiveSHA256 string `json:"rescueArchiveSha256"`
	RescueArchiveBytes  int64  `json:"rescueArchiveBytes"`
}

var receiptModePattern = regexp.MustCompile(`^(?:FULL_BASELINE|LEGACY_FULL_BASELINE)$`)

func splitReceiptIDs(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

func validReceiptText(value string) bool {
	value = strings.TrimSpace(value)
	return value != "" && len(value) <= 256 && !strings.ContainsAny(value, "\x00\r\n")
}

func validateDismantleReceipt(receipt DismantleReceipt) error {
	if receipt.SchemaVersion != dismantleReceiptSchemaVersion || receipt.Product != productName || receipt.ProductVersion != version {
		return errors.New("dismantle receipt product/schema mismatch")
	}
	if !nodeIDPattern.MatchString(receipt.NodeID) || !serverIDPattern.MatchString(receipt.ServerID) ||
		!sha256HexPattern.MatchString(receipt.MachineIDHash) || !sha256FingerprintPattern.MatchString(receipt.SSHHostKeySHA256) {
		return errors.New("dismantle receipt has an invalid stable node identity")
	}
	if receipt.SSHHostKeyAlgorithm != "ssh-ed25519" && receipt.SSHHostKeyAlgorithm != "ssh-rsa" && !strings.HasPrefix(receipt.SSHHostKeyAlgorithm, "ecdsa-sha2-nistp") {
		return errors.New("dismantle receipt has an invalid SSH host-key algorithm")
	}
	if !validReceiptText(receipt.ConnectionHost) || !userPartPattern.MatchString(receipt.ConnectionUser) || receipt.ConnectionPort < 1 || receipt.ConnectionPort > 65535 {
		return errors.New("dismantle receipt has an invalid non-secret connection identity")
	}
	if !receiptModePattern.MatchString(receipt.Mode) {
		return errors.New("dismantle receipt has an invalid removal mode")
	}
	if receipt.ReceiptStatus != "VERIFIED" && receipt.ReceiptStatus != "POST_VERIFY_FAILED" {
		return errors.New("dismantle receipt has an invalid completion status")
	}
	if receipt.CompletedAtUTC == "" {
		return errors.New("dismantle receipt completion timestamp is missing")
	}
	if _, err := time.Parse(time.RFC3339Nano, receipt.CompletedAtUTC); err != nil {
		return errors.New("dismantle receipt completion timestamp is invalid")
	}
	for label, value := range map[string]string{
		"transaction": receipt.TransactionID, "action": receipt.Action, "restore grade": receipt.RestoreGrade,
		"post lifecycle": receipt.PostLifecycle, "post verification": receipt.PostVerification,
		"rescue path": receipt.RescueArchivePath,
	} {
		if !validReceiptText(value) {
			return fmt.Errorf("dismantle receipt %s is invalid", label)
		}
	}
	if !sha256HexPattern.MatchString(strings.ToLower(receipt.RescueArchiveSHA256)) || receipt.RescueArchiveBytes < 1 {
		return errors.New("dismantle receipt has invalid rescue evidence")
	}
	return nil
}

func dismantleReceiptRoot() (string, error) {
	root, err := productConfigRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "dismantle-receipts"), nil
}

func writeDismantleReceipt(receipt DismantleReceipt) (string, error) {
	if err := validateDismantleReceipt(receipt); err != nil {
		return "", err
	}
	root, err := dismantleReceiptRoot()
	if err != nil {
		return "", err
	}
	directory := filepath.Join(root, receipt.NodeID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	stamp, err := time.Parse(time.RFC3339Nano, receipt.CompletedAtUTC)
	if err != nil {
		return "", fmt.Errorf("invalid dismantle completion timestamp: %w", err)
	}
	name := stamp.UTC().Format("20060102T150405.000000000Z") + "-" + strings.ToLower(receipt.Mode) + ".json"
	path := filepath.Join(directory, name)
	payload, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	payload = append(payload, '\n')
	temporary, err := os.CreateTemp(directory, ".dismantle-receipt-*.new")
	if err != nil {
		return "", err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if _, err := temporary.Write(payload); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if err := temporary.Close(); err != nil {
		return "", err
	}
	// Do not overwrite an existing receipt: the timestamp/transaction pair is
	// immutable evidence, and a duplicate write should remain observable.
	if _, err := os.Stat(path); err == nil {
		return "", os.ErrExist
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return "", err
	}
	return path, nil
}

func readMatchingDismantleReceipts(machineIDHash, hostKeySHA256 string) ([]DismantleReceipt, error) {
	if !sha256HexPattern.MatchString(machineIDHash) || !sha256FingerprintPattern.MatchString(hostKeySHA256) {
		return nil, errors.New("invalid receipt lookup identity")
	}
	root, err := dismantleReceiptRoot()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var matches []DismantleReceipt
	for _, nodeDirectory := range entries {
		if !nodeDirectory.IsDir() || !nodeIDPattern.MatchString(nodeDirectory.Name()) {
			continue
		}
		files, readErr := os.ReadDir(filepath.Join(root, nodeDirectory.Name()))
		if readErr != nil {
			continue
		}
		for _, file := range files {
			if file.IsDir() || !strings.HasSuffix(strings.ToLower(file.Name()), ".json") {
				continue
			}
			path := filepath.Join(root, nodeDirectory.Name(), file.Name())
			info, statErr := os.Lstat(path)
			if statErr != nil || !info.Mode().IsRegular() {
				continue
			}
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				continue
			}
			var receipt DismantleReceipt
			if json.Unmarshal(data, &receipt) != nil || validateDismantleReceipt(receipt) != nil || receipt.NodeID != nodeDirectory.Name() {
				continue
			}
			if receipt.MachineIDHash == machineIDHash && receipt.SSHHostKeySHA256 == hostKeySHA256 {
				matches = append(matches, receipt)
			}
		}
	}
	sort.Slice(matches, func(i, j int) bool { return matches[i].CompletedAtUTC > matches[j].CompletedAtUTC })
	return matches, nil
}

// planArgValue extracts one line-oriented value from a remote plan/result.
// It is intentionally strict about the key shape and never evaluates shell
// syntax; receipt fields are evidence only.
func planArgValue(output, key string) string {
	if !regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`).MatchString(key) {
		return ""
	}
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, key+"=") {
			return strings.TrimSpace(strings.TrimPrefix(line, key+"="))
		}
	}
	return ""
}

// newDismantleReceipt accepts the historical trailing arguments as opaque
// compatibility values.  The reset line no longer inventories or preserves a
// separate data service; only the rescue archive and baseline evidence are
// recorded.  The final bool, when supplied, controls post-verification status.
func newDismantleReceipt(identity NodeIdentity, c Connection, mode, planOutput, resultOutput, rescuePath, rescueSHA string, rescueBytes int64, compatibility ...interface{}) DismantleReceipt {
	verified := true
	for index := len(compatibility) - 1; index >= 0; index-- {
		if value, ok := compatibility[index].(bool); ok {
			verified = value
			break
		}
	}
	if mode != "FULL_BASELINE" && mode != "LEGACY_FULL_BASELINE" {
		mode = "FULL_BASELINE"
	}
	status := "VERIFIED"
	postVerification := "PNA_POST_DISMANTLE_VERIFY_OK"
	if !verified {
		status = "POST_VERIFY_FAILED"
		postVerification = "FAILED"
	}
	return DismantleReceipt{
		SchemaVersion: dismantleReceiptSchemaVersion, Product: productName, ProductVersion: version, DesktopBuildID: desktopBuildID,
		ReceiptStatus: status, CompletedAtUTC: time.Now().UTC().Format(time.RFC3339Nano), TransactionID: planArgValue(resultOutput, "REMOVAL_TRANSACTION_ID"),
		Mode: mode, Action: planArgValue(planOutput, "ACTION"), RestoreGrade: planArgValue(planOutput, "RESTORE_GRADE"),
		RemovedResourceIDs: splitReceiptIDs(planArgValue(planOutput, "REMOVED_RESOURCE_IDS")), PreservedResourceIDs: splitReceiptIDs(planArgValue(planOutput, "PRESERVED_RESOURCE_IDS")),
		PostLifecycle: "BASELINE_UNMANAGED", PostVerification: postVerification,
		NodeID: identity.NodeID, ServerID: identity.ServerID, MachineIDHash: identity.MachineIDHash,
		SSHHostKeyAlgorithm: identity.HostKeyAlg, SSHHostKeySHA256: identity.HostKeySHA256,
		FirstKnownPublicIP: identity.FirstPublicIP, CurrentPublicIP: identity.CurrentPublicIP,
		ConnectionHost: c.Host, ConnectionUser: c.User, ConnectionPort: c.Port,
		RescueArchivePath: rescuePath, RescueArchiveSHA256: rescueSHA, RescueArchiveBytes: rescueBytes,
	}
}

// unmanagedNodeProof is retained for baseline reinstallation checks.  It is
// a one-shot proof of machine/SSH identity, not a device admission token.
type unmanagedNodeProof struct {
	MachineIDHash       string
	SSHHostKeyAlgorithm string
	SSHHostKeySHA256    string
}

func (a *App) fetchUnmanagedNodeProof(c Connection) (unmanagedNodeProof, error) {
	command := "set -eu; pub=; " +
		"for candidate in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do [ ! -s \"$candidate\" ] || { pub=\"$candidate\"; break; }; done; " +
		"[ -n \"$pub\" ] && [ -s /etc/machine-id ]; " +
		"printf 'MACHINE_ID_SHA256=%s\\n' \"$(sha256sum /etc/machine-id | awk '{print $1}')\"; " +
		"printf 'SSH_HOST_KEY_ALGORITHM=%s\\n' \"$(awk '{print $1}' \"$pub\")\"; " +
		"printf 'SSH_HOST_KEY_SHA256=%s\\n' \"$(ssh-keygen -E sha256 -lf \"$pub\" | awk '{print $2}')\""
	result := a.rootCapture(c, command)
	if !result.OK() {
		return unmanagedNodeProof{}, fmt.Errorf("unmanaged node proof failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	proof := unmanagedNodeProof{MachineIDHash: values["MACHINE_ID_SHA256"], SSHHostKeyAlgorithm: values["SSH_HOST_KEY_ALGORITHM"], SSHHostKeySHA256: values["SSH_HOST_KEY_SHA256"]}
	if !sha256HexPattern.MatchString(proof.MachineIDHash) || !sha256FingerprintPattern.MatchString(proof.SSHHostKeySHA256) || proof.SSHHostKeyAlgorithm == "" {
		return unmanagedNodeProof{}, errors.New("unmanaged node proof returned invalid evidence")
	}
	return proof, nil
}
