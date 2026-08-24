package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const cloudflareDNSDashboardURL = "https://dash.cloudflare.com/?to=%2F%3Aaccount%2F%3Azone%2Fdns%2Frecords"

type ipRebindContext struct {
	OldIP, NewIP, OldDomain, NewDomain string
	Mode, ActiveMode                   string
}

var nonPublicIPv4Blocks = mustCIDRs([]string{
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
	"172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
	"198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
})

func mustCIDRs(values []string) []*net.IPNet {
	result := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic(err)
		}
		result = append(result, network)
	}
	return result
}

func canonicalPublicIPv4(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed != value {
		return "", errors.New("the IPv4 address must not contain surrounding whitespace")
	}
	ip := net.ParseIP(trimmed)
	if ip == nil || ip.To4() == nil {
		return "", errors.New("a canonical public IPv4 address is required")
	}
	ip = ip.To4()
	canonical := ip.String()
	if canonical != value {
		return "", errors.New("the IPv4 address must use canonical dotted-decimal notation")
	}
	for _, block := range nonPublicIPv4Blocks {
		if block.Contains(ip) {
			return "", errors.New("private, reserved, documentation, multicast, and loopback addresses are refused")
		}
	}
	return canonical, nil
}

func hostKeyLineFingerprint(line string) (string, error) {
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 3 || !supportedHostKeyType(fields[1]) {
		return "", errors.New("invalid known_hosts line")
	}
	blob, err := decodedHostKey(fields[2])
	if err != nil || len(blob) < 32 {
		return "", errors.New("invalid SSH host-key blob")
	}
	digest := sha256.Sum256(blob)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:]), nil
}

func pinnedHostKeyLines(keys, fingerprint string) ([]string, error) {
	var result []string
	for _, line := range strings.Split(strings.ReplaceAll(keys, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		current, err := hostKeyLineFingerprint(line)
		if err == nil && current == fingerprint {
			result = append(result, line)
		}
	}
	if len(result) == 0 {
		return nil, errors.New("HOST_KEY_MISMATCH")
	}
	return result, nil
}

func parseIPRebindPreflight(stdout string) (ipRebindContext, error) {
	block, err := extractMarkerBlock(stdout, "__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__", "__PNA_IP_REBIND_PREFLIGHT_V1_END__")
	if err != nil {
		return ipRebindContext{}, err
	}
	values := parseDeviceKV(block)
	ctx := ipRebindContext{
		OldIP: values["OLD_IP"], NewIP: values["NEW_IP"], OldDomain: values["OLD_CONSTRUCTION_DOMAIN"],
		NewDomain: values["NEW_CONSTRUCTION_DOMAIN"], Mode: values["DEPLOYMENT_MODE"], ActiveMode: values["ACTIVE_MODE"],
	}
	if values["IP_REBIND_STATUS"] != "IP_REBIND_PREPARED" || values["SERVER_ID_MATCH"] != "1" ||
		values["NODE_ID_UNCHANGED"] != "1" || values["MACHINE_ID_MATCH"] != "1" || values["REMOTE_PUBLIC_IP_MATCH"] != "1" ||
		values["SNAPSHOT_CREATED"] != "1" || values["DNS_MUTATED"] != "0" || values["CLOUDFLARE_MUTATION"] != "NONE" {
		return ipRebindContext{}, errors.New("remote IP-rebind preflight did not satisfy the fail-closed contract")
	}
	if _, err := canonicalPublicIPv4(ctx.OldIP); err != nil {
		return ipRebindContext{}, err
	}
	if _, err := canonicalPublicIPv4(ctx.NewIP); err != nil {
		return ipRebindContext{}, err
	}
	if !validDomain(ctx.OldDomain) || !validDomain(ctx.NewDomain) {
		return ipRebindContext{}, errors.New("remote IP-rebind preflight returned an invalid domain")
	}
	if _, err := parseDeploymentMode(ctx.Mode); err != nil {
		return ipRebindContext{}, err
	}
	return ctx, nil
}

func domainResolvesExclusivelyTo(domain, expected string) bool {
	addresses, err := net.LookupIP(domain)
	if err != nil || len(addresses) == 0 {
		return false
	}
	found := false
	for _, address := range addresses {
		if address.To4() == nil {
			continue
		}
		found = true
		if address.String() != expected {
			return false
		}
	}
	return found
}

func (a *App) chooseStableManagedKey() (managedKeyEntry, error) {
	root, err := managedKeyRoot()
	if err != nil {
		return managedKeyEntry{}, err
	}
	entries, err := listManagedKeyEntries(root)
	if err != nil {
		return managedKeyEntry{}, err
	}
	stable := make([]managedKeyEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.Metadata.NodeID != "" && entry.Metadata.ServerID != "" && entry.Metadata.HostKeySHA256 != "" && entry.Metadata.MachineIDHash != "" {
			stable = append(stable, entry)
		}
	}
	if len(stable) == 0 {
		return managedKeyEntry{}, errors.New(a.msg("LOCAL_KEY_RECORD_NOT_FOUND：没有带稳定 NODE_ID/SERVER_ID 的已绑定 key。若旧地址仍可用，先用该 key 成功执行任一远端操作以完成安全迁移；本项不会生成替代 key。", "LOCAL_KEY_RECORD_NOT_FOUND: no bound key has a stable NODE_ID/SERVER_ID. If the old endpoint still works, complete one remote action with that key to migrate it safely. This workflow will not generate a replacement key."))
	}
	a.println(a.msg("选择更换公网 IP 的原节点；这里只列出已具有稳定服务器身份的长期 key：", "Choose the original node whose public IP changed. Only managed keys with stable server identity are listed:"))
	a.printManagedKeyEntries(stable, false)
	answer := strings.TrimSpace(a.prompt(a.msg("输入节点编号；0 取消", "Enter the node number; 0 cancels")))
	index, err := strconv.Atoi(answer)
	if err != nil || index < 0 || index > len(stable) {
		return managedKeyEntry{}, errors.New(a.msg("节点编号无效。", "Invalid node number."))
	}
	if index == 0 {
		return managedKeyEntry{}, errConnectionSelectionCancelled
	}
	entry := stable[index-1]
	if err := validatePrivatePublicKeyPair(entry.KeyPath); err != nil {
		return managedKeyEntry{}, fmt.Errorf("LOCAL_KEY_RECORD_NOT_FOUND: %w", err)
	}
	keyID, err := sshAuthenticationKeyID(entry.KeyPath)
	if err != nil {
		return managedKeyEntry{}, err
	}
	if entry.Metadata.SSHAuthKeyID != "" && entry.Metadata.SSHAuthKeyID != keyID {
		return managedKeyEntry{}, errors.New("LOCAL_KEY_RECORD_NOT_FOUND: SSH_AUTH_KEY_ID does not match the saved key")
	}
	entry.Metadata.SSHAuthKeyID = keyID
	return entry, nil
}

func (a *App) stageReboundConnection(entry managedKeyEntry, newIP string, newPort int) (Connection, string, error) {
	root, err := managedKeyRoot()
	if err != nil {
		return Connection{}, "", err
	}
	destinationKey, err := defaultKeyPath(newIP, entry.Metadata.User)
	if err != nil {
		return Connection{}, "", err
	}
	if filepath.Clean(filepath.Dir(destinationKey)) == filepath.Clean(entry.Dir) {
		return Connection{}, "", errors.New("new endpoint resolves to the existing managed-key directory")
	}
	if _, err := os.Stat(filepath.Dir(destinationKey)); err == nil {
		return Connection{}, "", fmt.Errorf("a managed-key destination already exists for the new endpoint: %s", filepath.Dir(destinationKey))
	} else if !os.IsNotExist(err) {
		return Connection{}, "", err
	}
	stage, err := os.MkdirTemp(root, ".rebind-")
	if err != nil {
		return Connection{}, "", err
	}
	cleanup := func(failure error) (Connection, string, error) {
		_ = os.RemoveAll(stage)
		return Connection{}, "", failure
	}
	stageKey := filepath.Join(stage, "id_ed25519")
	if err := copyFileExclusive(entry.KeyPath, stageKey, 0600); err != nil {
		return cleanup(err)
	}
	if err := copyFileExclusive(entry.KeyPath+".pub", stageKey+".pub", 0600); err != nil {
		return cleanup(err)
	}
	c := Connection{Host: newIP, User: entry.Metadata.User, Port: newPort, KeyPath: stageKey, AuthMode: AuthManagedKey, Ready: true}
	keys, attempts := scanHostKeys(c)
	if knownHostEntryCount(keys) == 0 {
		return cleanup(fmt.Errorf("could not read the new endpoint SSH host key:\n%s", formatHostKeyScanAttempts(attempts)))
	}
	pinned, err := pinnedHostKeyLines(keys, entry.Metadata.HostKeySHA256)
	if err != nil {
		return cleanup(errors.New(a.msg("HOST_KEY_MISMATCH：新地址返回的 VPS Host Key 与旧节点固定指纹不一致。即使知道密码也禁止继续；请按服务器迁移/灾备恢复处理。", "HOST_KEY_MISMATCH: the new endpoint host key does not match the pinned old-node fingerprint. A password cannot override this; use server migration/disaster recovery.")))
	}
	if err := os.WriteFile(knownHostsPath(c), []byte(strings.Join(pinned, "\n")+"\n"), 0600); err != nil {
		return cleanup(err)
	}
	return c, stage, nil
}

func verifyStableIdentity(expected managedKeyMetadata, actual NodeIdentity) error {
	if expected.NodeID != actual.NodeID || expected.ServerID != actual.ServerID {
		return errors.New("NODE_ID_OR_SERVER_ID_MISMATCH")
	}
	if expected.MachineIDHash != actual.MachineIDHash {
		return errors.New("MACHINE_ID_MISMATCH")
	}
	if expected.HostKeySHA256 != actual.HostKeySHA256 {
		return errors.New("HOST_KEY_MISMATCH")
	}
	return nil
}

func (a *App) commitLocalReboundKey(entry managedKeyEntry, staged Connection, stage string, identity NodeIdentity) (Connection, string, error) {
	destinationKey, err := defaultKeyPath(staged.Host, staged.User)
	if err != nil {
		return Connection{}, "", err
	}
	info := entry.Metadata
	info.Host, info.User, info.Port = staged.Host, staged.User, staged.Port
	info.Status, info.UpdatedAt, info.CurrentPublic = "BOUND_REBOUND", time.Now().UTC(), identity.CurrentPublicIP
	if err := os.WriteFile(filepath.Join(stage, managedKeyInfoFile), encodeManagedKeyMetadata(info), 0600); err != nil {
		return Connection{}, "", err
	}
	if err := os.Rename(stage, filepath.Dir(destinationKey)); err != nil {
		return Connection{}, "", err
	}
	committed := Connection{Host: staged.Host, User: staged.User, Port: staged.Port, KeyPath: destinationKey, AuthMode: AuthManagedKey, Ready: true}
	verified := verifyKey(committed, destinationKey)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		return Connection{}, "", fmt.Errorf("new endpoint local binding failed final verification: %s", processFailureDetail(verified))
	}
	backup, backupErr := moveManagedKeyDirectoryToBackup(entry.KeyPath, time.Now())
	if backupErr == nil {
		retired := entry.Metadata
		retired.Status, retired.UpdatedAt = "RETIRED_ENDPOINT_KEY_REUSED", time.Now().UTC()
		_ = os.WriteFile(filepath.Join(backup, managedKeyInfoFile), encodeManagedKeyMetadata(retired), 0600)
	}
	return committed, backup, backupErr
}

func (a *App) rebindPublicIP() error {
	if err := a.ensureOpenSSH(); err != nil {
		return err
	}
	entry, err := a.chooseStableManagedKey()
	if err != nil {
		if errors.Is(err, errConnectionSelectionCancelled) {
			return nil
		}
		return err
	}
	oldIP, err := canonicalPublicIPv4(entry.Metadata.CurrentPublic)
	if err != nil {
		return fmt.Errorf("saved CURRENT_PUBLIC_IP is invalid: %w", err)
	}
	newIP, err := a.required(a.msg("输入服务商已经分配给同一 VPS 的新公网 IPv4", "Enter the new public IPv4 already assigned to the same VPS"))
	if err != nil {
		return err
	}
	newIP, err = canonicalPublicIPv4(newIP)
	if err != nil {
		return err
	}
	if newIP == oldIP {
		return errors.New(a.msg("新 IP 与稳定节点记录中的旧 IP 相同；没有重绑定动作可做。", "The new IP equals the stable node record's old IP; there is nothing to rebind."))
	}
	portText := strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("新地址 SSH 端口 [%d]", "New endpoint SSH port [%d]"), entry.Metadata.Port)))
	newPort := entry.Metadata.Port
	if portText != "" {
		newPort, err = strconv.Atoi(portText)
		if err != nil || newPort < 1 || newPort > 65535 {
			return errors.New(a.msg("SSH 端口无效。", "Invalid SSH port."))
		}
	}
	if !tcpReachable(newIP, newPort) {
		return fmt.Errorf(a.msg("新地址 SSH TCP 不可达：%s:%d", "The new endpoint SSH TCP is unreachable: %s:%d"), newIP, newPort)
	}
	staged, stage, err := a.stageReboundConnection(entry, newIP, newPort)
	if err != nil {
		return err
	}
	committedStage := false
	defer func() {
		if !committedStage {
			_ = os.RemoveAll(stage)
		}
	}()
	authMethod := "existing_key"
	verified := verifyKey(staged, staged.KeyPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		authMethod = "password_fallback"
		a.println(a.msg("PUBLICKEY_REJECTED：服务器身份已匹配，但该账户没有接受原公钥。仅此状态允许询问当前 VPS 密码，并会重新安装同一公钥；不会生成或轮换 key。", "PUBLICKEY_REJECTED: server identity matched, but the account rejected the original public key. Only this state permits a current-password fallback; the same public key is reinstalled without generating or rotating a key."))
		if err := a.installPublicKey(staged, staged.KeyPath, "", nil); err != nil {
			return fmt.Errorf("PUBLICKEY_REJECTED: password fallback failed: %w", err)
		}
	}
	identity, err := a.fetchNodeIdentity(staged)
	if err != nil {
		return fmt.Errorf("IP_REBIND_BLOCKED_PRE_DNS: %w", err)
	}
	if err := verifyStableIdentity(entry.Metadata, identity); err != nil {
		return fmt.Errorf("IP_REBIND_BLOCKED_PRE_DNS: %w", err)
	}
	if identity.CurrentPublicIP != oldIP {
		return errors.New("IP_REBIND_BLOCKED_PRE_DNS: saved remote CURRENT_PUBLIC_IP does not equal the old endpoint")
	}
	if err := a.ensureToolkit(staged); err != nil {
		return err
	}
	publicEnv, err := a.runtimePublicEnv(staged)
	if err != nil {
		return err
	}
	oldDomain := strings.ToLower(strings.TrimSpace(publicEnv["COVER_DOMAIN"]))
	if !validDomain(oldDomain) {
		return errors.New("IP_REBIND_BLOCKED_PRE_DNS: the managed construction domain is missing or invalid")
	}
	newDomain := strings.ToLower(strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("新施工域名 [%s]（直接回车表示不换域名）", "New construction domain [%s] (press Enter to keep it)"), oldDomain))))
	if newDomain == "" {
		newDomain = oldDomain
	}
	if !validDomain(newDomain) {
		return errors.New(a.msg("新施工域名格式无效。", "The new construction domain is invalid."))
	}
	command := fmt.Sprintf("bash %s/linux/27-ip-rebind.sh preflight %s %s %s %s", remoteRoot, shQuote(oldIP), shQuote(newIP), shQuote(oldDomain), shQuote(newDomain))
	preflight := a.rootCapture(staged, command)
	if !preflight.OK() {
		return fmt.Errorf("IP_REBIND_BLOCKED_PRE_DNS (exit %d): %s", preflight.ExitCode, processFailureDetail(preflight))
	}
	ctx, err := parseIPRebindPreflight(preflight.Stdout)
	if err != nil || ctx.OldIP != oldIP || ctx.NewIP != newIP || ctx.OldDomain != oldDomain || ctx.NewDomain != newDomain {
		return fmt.Errorf("IP_REBIND_BLOCKED_PRE_DNS: invalid preflight readback: %w", err)
	}
	a.println(strings.TrimSpace(preflight.Stdout))
	if newDomain != oldDomain {
		_ = a.rootCapture(staged, "bash "+remoteRoot+"/linux/27-ip-rebind.sh wait-cloudflare "+shQuote(oldIP)+" "+shQuote(newIP)+" "+shQuote(oldDomain)+" "+shQuote(newDomain))
		a.println(a.msg("联合换域名涉及 Cloudflare/DNS、证书和双域并行验收，已停在 WAITING_FOR_CLOUDFLARE_MANUAL_ACTION；旧域名、旧 key 位置和现有节点均未删除。", "A joint domain change requires Cloudflare/DNS, certificate, and dual-domain validation. The transaction is parked at WAITING_FOR_CLOUDFLARE_MANUAL_ACTION; the old domain, old key location, and existing node remain intact."))
		return nil
	}
	directActive := (ctx.Mode == string(DeploymentDirectReality) && ctx.ActiveMode == string(StateActiveDirect)) ||
		(ctx.Mode == string(DeploymentDualHotSwitch) && ctx.ActiveMode == string(StateDualInstalledActiveDirect))
	if !directActive {
		wait := a.rootCapture(staged, "bash "+remoteRoot+"/linux/27-ip-rebind.sh wait-cloudflare "+shQuote(oldIP)+" "+shQuote(newIP)+" "+shQuote(oldDomain)+" "+shQuote(newDomain))
		if !wait.OK() || !strings.Contains(wait.Stdout, "IP_REBIND_STATUS=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION") {
			return fmt.Errorf("could not park the CDN rebind transaction safely: %s", processFailureDetail(wait))
		}
		opened := openURL(cloudflareDNSDashboardURL) == nil
		a.println(fmt.Sprintf("CLOUDFLARE_DASHBOARD_OPENED=%t", opened))
		a.println(a.msg("橙云记录必须在一次更新中保持 Proxied；本版不会先切灰云。已停在待人工 Cloudflare 验证状态，未提交本地 endpoint。", "The orange-cloud record must remain Proxied in one update; this build never turns it DNS-only first. The transaction is waiting for manual Cloudflare validation, and the local endpoint was not committed."))
		return nil
	}
	a.println(a.msg("远端只读预检和快照已通过。现在请把施工域名 A 记录更新为新 IP，并保持 DNS only（灰云）。", "Remote read-only preflight and snapshot passed. Update the construction-domain A record to the new IP and keep it DNS only."))
	_ = openURL(cloudflareDNSDashboardURL)
	for !domainResolvesExclusivelyTo(newDomain, newIP) {
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("更新后按 Enter 重新检测；输入 q 安全停在 DNS 前", "Press Enter to re-check after updating; type q to stop safely before DNS"))))
		if answer == "q" || a.inputClosed {
			_ = a.rootCapture(staged, "bash "+remoteRoot+"/linux/27-ip-rebind.sh abort-pre-dns")
			return nil
		}
	}
	commit := a.rootCapture(staged, "bash "+remoteRoot+"/linux/27-ip-rebind.sh commit-direct "+shQuote(oldIP)+" "+shQuote(newIP)+" "+shQuote(oldDomain)+" "+shQuote(newDomain))
	if !commit.OK() || !strings.Contains(commit.Stdout, "IP_REBIND_STATUS=IP_REBIND_COMPLETE") {
		return fmt.Errorf("IP_REBIND_BLOCKED_POST_DNS (exit %d): %s", commit.ExitCode, processFailureDetail(commit))
	}
	identity, err = a.fetchNodeIdentity(staged)
	if err != nil || identity.CurrentPublicIP != newIP {
		return errors.New("IP_REBIND_BLOCKED_POST_DNS: remote identity did not commit the new public IP")
	}
	newConnection, backup, backupErr := a.commitLocalReboundKey(entry, staged, stage, identity)
	if newConnection.KeyPath == "" {
		return errors.New("IP_REBIND_BLOCKED_POST_DNS: local stable-key endpoint commit failed")
	}
	committedStage = true
	if backupErr != nil {
		a.println(a.msg("[WARN] 新 endpoint 已验证并提交，但旧 endpoint 目录未能归档；两份均保留，请稍后用 [K] 检查：", "[WARN] The verified new endpoint was committed, but the old endpoint directory could not be archived. Both remain; inspect them later with [K]:") + " " + backupErr.Error())
	} else {
		a.println(a.msg("旧 endpoint 的 key/known_hosts 审计副本已移入：", "The old endpoint key/known_hosts audit copy was archived at:") + " " + backup)
	}
	if err := rememberRecentTarget(RecentTarget{Host: newIP, User: newConnection.User, Port: newPort}); err != nil {
		a.println("[WARN] " + err.Error())
	}
	a.println(strings.TrimSpace(commit.Stdout))
	a.println("SSH_AUTH_METHOD=" + authMethod)
	a.println("SSH_PUBLICKEY_RESULT=ACCEPTED")
	a.println("SSH_HOST_KEY_MATCH=1")
	a.println("KNOWN_HOSTS_NEW_ENDPOINT_BOUND=1")
	a.println("SSH_AUTH_KEY_ID_UNCHANGED=1")
	if handoff, err := a.fetchHandoff(newConnection); err == nil {
		if complete, buildErr := a.buildCompleteHandoff(handoff, newConnection); buildErr == nil {
			_ = a.secretHandoff("CREDENTIAL HANDOFF", complete)
		}
	}
	return nil
}
