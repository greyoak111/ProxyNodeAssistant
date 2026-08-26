package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const dismantleReceiptSchemaVersion = 1

// DismantleReceipt is deliberately secret-free. It remains useful after a
// full baseline restore has removed every TNA-owned identity file from the VPS.
// Passwords, private keys, subscription links, API tokens, and handoff text
// must never be added to this structure.
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
	DriveDataRoot       string `json:"driveDataRoot"`
	DriveFileCount      int64  `json:"driveFileCount"`
	DriveDataBytes      int64  `json:"driveDataBytes"`
}

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

func validateDismantleReceipt(receipt DismantleReceipt) error {
	if receipt.SchemaVersion != dismantleReceiptSchemaVersion || receipt.Product != productName || receipt.ProductVersion != version {
		return errors.New("dismantle receipt product/schema mismatch")
	}
	if !nodeIDPattern.MatchString(receipt.NodeID) || !serverIDPattern.MatchString(receipt.ServerID) || !sha256HexPattern.MatchString(receipt.MachineIDHash) || !sha256FingerprintPattern.MatchString(receipt.SSHHostKeySHA256) {
		return errors.New("dismantle receipt has an invalid stable node identity")
	}
	if receipt.ConnectionHost == "" || receipt.ConnectionUser == "" || receipt.ConnectionPort < 1 || receipt.ConnectionPort > 65535 {
		return errors.New("dismantle receipt has an invalid non-secret connection identity")
	}
	if receipt.Mode != "PROXY_ONLY" && receipt.Mode != "FULL_BASELINE" && receipt.Mode != "REMAINING_DRIVE" {
		return errors.New("dismantle receipt has an invalid removal mode")
	}
	if receipt.ReceiptStatus != "VERIFIED" && receipt.ReceiptStatus != "POST_VERIFY_FAILED" {
		return errors.New("dismantle receipt has an invalid completion status")
	}
	if !sha256HexPattern.MatchString(receipt.RescueArchiveSHA256) || receipt.RescueArchiveBytes < 1 || receipt.RescueArchivePath == "" {
		return errors.New("dismantle receipt has invalid rescue evidence")
	}
	if receipt.CompletedAtUTC == "" || receipt.TransactionID == "" || receipt.Action == "" || receipt.RestoreGrade == "" || receipt.PostLifecycle == "" || receipt.PostVerification == "" {
		return errors.New("dismantle receipt is incomplete")
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
	temporary := path + ".new"
	if err := os.WriteFile(temporary, payload, 0600); err != nil {
		return "", err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return "", err
	}
	return path, nil
}

func readMatchingDismantleReceipts(machineIDHash, hostKeySHA256 string) ([]DismantleReceipt, error) {
	root, err := dismantleReceiptRoot()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
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
			data, readErr := os.ReadFile(filepath.Join(root, nodeDirectory.Name(), file.Name()))
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

func (a *App) legacyIdentityBootstrapEvidence(c Connection, original ToolkitProbe) error {
	legacyProbe := original.Brand == "PNA_LEGACY" && original.Root == legacyRemoteRoot && !original.Complete
	interruptedMigrationProbe := original.Brand == "TNA" && original.Root == remoteRoot
	if !original.Present || (!legacyProbe && !interruptedMigrationProbe) {
		return errors.New("original toolkit probe is not a legacy PNA installation or its interrupted TNA migration")
	}
	command := "set -eu; journal=/var/lib/text-node-assistant/migrations/pna-to-tna-v1.env; " +
		"state=/var/lib/text-node-assistant/migrations/legacy-identity-bootstrap-v1.env; " +
		"[ -f \"$journal\" ] && [ ! -L \"$journal\" ]; " +
		"grep -Fqx 'MIGRATION_STATUS=COMMITTED' \"$journal\"; " +
		"grep -Eq '^MIGRATION_COPIED=(ETC_STATE|ROOT_STATE)$' \"$journal\"; " +
		"legacy=$(readlink -f " + legacyRemoteRoot + "); [ -n \"$legacy\" ]; [ \"$legacy\" != " + shQuote(remoteRoot) + " ]; " +
		"[ -s \"$legacy/TOOLKIT_VERSION\" ]; [ ! -x \"$legacy/linux/23-node-identity.sh\" ]; " +
		"[ ! -L \"$state\" ]; ! grep -Fqx 'IDENTITY_BOOTSTRAP_STATUS=COMMITTED' \"$state\" 2>/dev/null; " +
		"if [ ! -s \"$state\" ]; then printf 'SCHEMA_VERSION=1\\nIDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS\\n' > \"$state.tmp.$$\"; chmod 600 \"$state.tmp.$$\"; mv -f \"$state.tmp.$$\" \"$state\"; fi; " +
		"grep -Fqx 'IDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS' \"$state\"; " +
		"printf 'TNA_LEGACY_IDENTITY_BOOTSTRAP_EVIDENCE_OK\\n'"
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_LEGACY_IDENTITY_BOOTSTRAP_EVIDENCE_OK") {
		return fmt.Errorf("legacy identity-bootstrap evidence failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return nil
}

func (a *App) commitLegacyIdentityBootstrap(c Connection) error {
	command := "set -eu; state=/var/lib/text-node-assistant/migrations/legacy-identity-bootstrap-v1.env; " +
		"[ -f \"$state\" ] && [ ! -L \"$state\" ]; grep -Fqx 'IDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS' \"$state\"; " +
		"sed 's/^IDENTITY_BOOTSTRAP_STATUS=.*/IDENTITY_BOOTSTRAP_STATUS=COMMITTED/' \"$state\" > \"$state.tmp.$$\"; " +
		"chmod 600 \"$state.tmp.$$\"; mv -f \"$state.tmp.$$\" \"$state\"; printf 'TNA_LEGACY_IDENTITY_BOOTSTRAP_COMMITTED\\n'"
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_LEGACY_IDENTITY_BOOTSTRAP_COMMITTED") {
		return fmt.Errorf("legacy identity-bootstrap commit failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return nil
}

func (a *App) ensureInstallNodeIdentity(c Connection, relation ToolkitRelation, original ToolkitProbe) error {
	if _, err := a.fetchNodeIdentity(c); err == nil {
		return nil
	}
	proof, proofErr := a.fetchUnmanagedNodeProof(c)
	if proofErr != nil {
		return proofErr
	}
	matches, receiptErr := readMatchingDismantleReceipts(proof.MachineIDHash, proof.SSHHostKeySHA256)
	if receiptErr != nil {
		return fmt.Errorf("local dismantle receipt lookup failed: %w", receiptErr)
	}
	legacyBootstrap := false
	if len(matches) > 0 {
		latest := matches[0]
		a.println(a.msg("检测到这台物理实例曾由 TNA 整体拆除并恢复基线；不会把它伪装成从未施工的新机。", "This physical instance was previously dismantled by TNA and restored to baseline; it will not be presented as a never-managed VPS."))
		a.println("PREVIOUS_NODE_ID=" + latest.NodeID)
		a.println("PREVIOUS_REMOVAL_MODE=" + latest.Mode)
		a.println(a.msg("上次本地救援包：", "Previous local rescue archive:") + " " + latest.RescueArchivePath)
		if !a.yes(a.msg("确认以新的受管 NODE_ID 重新施工？旧网盘数据只在救援包中，不会自动灌回 VPS。", "Reinstall with a new managed NODE_ID? Old drive data remains only in the rescue archive and is not silently restored to the VPS."), false) {
			return errors.New(a.msg("用户取消了恢复基线后的重新施工；远端身份状态未创建。", "Reinstallation after baseline restoration was cancelled; no remote identity state was created."))
		}
	} else if relation == ToolkitSameComplete || relation == ToolkitSameIncomplete {
		if err := a.legacyIdentityBootstrapEvidence(c, original); err != nil {
			return errors.New(a.msg("同版本受管节点缺失稳定身份，且没有通过旧 PNA 迁移证据校验；拒绝生成新身份掩盖漂移。请先运行 [3] 导出诊断。", "The same-version managed node is missing its stable identity and did not pass the legacy-PNA migration evidence check. A new identity will not be generated to hide drift. Run [3] and export diagnostics first."))
		}
		legacyBootstrap = true
		a.println(a.msg("已验证旧 PNA 构建从未提供稳定身份；菜单 [1] 将基于 machine-id 与 SSH host key 一次性补建 NODE_ID。", "The legacy PNA build is verified to have never provided stable identity; menu [1] will bootstrap NODE_ID once from machine-id and the SSH host key."))
	}
	initialized := a.rootCapture(c, "bash "+remoteRoot+"/linux/23-node-identity.sh --init")
	if !initialized.OK() {
		return fmt.Errorf("stable node identity initialization failed (exit %d): %s", initialized.ExitCode, processFailureDetail(initialized))
	}
	if _, err := parseNodeIdentity(initialized.Stdout); err != nil {
		return fmt.Errorf("stable node identity initialization returned invalid evidence: %w", err)
	}
	if legacyBootstrap {
		if err := a.commitLegacyIdentityBootstrap(c); err != nil {
			return err
		}
	}
	return nil
}

func newDismantleReceipt(identity NodeIdentity, c Connection, mode, planOutput, resultOutput, rescuePath, rescueSHA string, rescueBytes, driveFiles, driveBytes int64, verified bool) DismantleReceipt {
	postLifecycle := "BASELINE_UNMANAGED"
	if mode == "PROXY_ONLY" {
		postLifecycle = "PROXY_REMOVED_DRIVE_RETAINED"
	}
	status := "VERIFIED"
	postVerification := "TNA_POST_DISMANTLE_VERIFY_OK"
	if !verified {
		status = "POST_VERIFY_FAILED"
		postVerification = "FAILED"
	}
	return DismantleReceipt{
		SchemaVersion: dismantleReceiptSchemaVersion, Product: productName, ProductVersion: version, DesktopBuildID: desktopBuildID,
		ReceiptStatus: status, CompletedAtUTC: time.Now().UTC().Format(time.RFC3339Nano), TransactionID: planArgValue(resultOutput, "REMOVAL_TRANSACTION_ID"),
		Mode: mode, Action: planArgValue(planOutput, "ACTION"), RestoreGrade: planArgValue(planOutput, "RESTORE_GRADE"),
		RemovedResourceIDs: splitReceiptIDs(planArgValue(planOutput, "REMOVED_RESOURCE_IDS")), PreservedResourceIDs: splitReceiptIDs(planArgValue(planOutput, "PRESERVED_RESOURCE_IDS")),
		PostLifecycle: postLifecycle, PostVerification: postVerification,
		NodeID: identity.NodeID, ServerID: identity.ServerID, MachineIDHash: identity.MachineIDHash,
		SSHHostKeyAlgorithm: identity.HostKeyAlg, SSHHostKeySHA256: identity.HostKeySHA256,
		FirstKnownPublicIP: identity.FirstPublicIP, CurrentPublicIP: identity.CurrentPublicIP,
		ConnectionHost: c.Host, ConnectionUser: c.User, ConnectionPort: c.Port,
		RescueArchivePath: rescuePath, RescueArchiveSHA256: rescueSHA, RescueArchiveBytes: rescueBytes,
		DriveDataRoot: planArgValue(planOutput, "DRIVE_DATA_ROOT"), DriveFileCount: driveFiles, DriveDataBytes: driveBytes,
	}
}
