package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const deviceIdentityCredentialTarget = "ProxyNodeAssistant/device-identity/v1"

type DeviceIdentity struct {
	Version   int       `json:"version"`
	DeviceID  string    `json:"deviceId"`
	PublicKey string    `json:"publicKey"`
	CreatedAt time.Time `json:"createdAt"`
}

type DeviceRecord struct {
	DeviceID  string
	Role      string
	Status    string
	Label     string
	CreatedAt string
}

type DeviceStatus struct {
	NodeID           string
	ActiveController int
	ActiveDevices    int
	Devices          []DeviceRecord
}

type DeviceInvite struct {
	Version      int    `json:"v"`
	NodeID       string `json:"node"`
	Nonce        string `json:"nonce"`
	ExpiresEpoch int64  `json:"expires"`
}

type DeviceEnrollmentResponse struct {
	Version   int    `json:"v"`
	NodeID    string `json:"node"`
	Nonce     string `json:"nonce"`
	DeviceID  string `json:"device"`
	PublicKey string `json:"public"`
	Label     string `json:"label"`
	Role      string `json:"role"`
	Signature string `json:"signature"`
}

var deviceIDPattern = regexp.MustCompile(`^pna-device-[a-z2-7]{26}$`)
var nodeIDPattern = regexp.MustCompile(`^pna-node-[0-9a-f]{32}$`)
var devicePublicPattern = regexp.MustCompile(`^pna-ed25519:[A-Za-z0-9_-]{43}$`)
var deviceLabelPattern = regexp.MustCompile(`^[A-Za-z0-9._ -]{1,64}$`)

func deviceIdentityMetadataPath() (string, error) {
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, "ProxyNodeAssistant", "device-identity.json"), nil
}

func deriveDeviceIdentity(private ed25519.PrivateKey, created time.Time) (DeviceIdentity, error) {
	if len(private) != ed25519.PrivateKeySize {
		return DeviceIdentity{}, errors.New("invalid local device private key length")
	}
	public := private.Public().(ed25519.PublicKey)
	digest := sha256.Sum256(public)
	return DeviceIdentity{
		Version:   1,
		DeviceID:  "pna-device-" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])),
		PublicKey: "pna-ed25519:" + base64.RawURLEncoding.EncodeToString(public),
		CreatedAt: created.UTC(),
	}, nil
}

func validateDeviceIdentity(identity DeviceIdentity) error {
	if identity.Version != 1 || !deviceIDPattern.MatchString(identity.DeviceID) || !devicePublicPattern.MatchString(identity.PublicKey) || identity.CreatedAt.IsZero() {
		return errors.New("local device identity metadata is invalid")
	}
	public, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(identity.PublicKey, "pna-ed25519:"))
	if err != nil || len(public) != ed25519.PublicKeySize {
		return errors.New("local device public key is invalid")
	}
	digest := sha256.Sum256(public)
	if identity.DeviceID != "pna-device-"+strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])) {
		return errors.New("local device ID does not match its public key")
	}
	return nil
}

func loadDevicePrivateKey(identity DeviceIdentity) (ed25519.PrivateKey, error) {
	secret, err := credentialRead(deviceIdentityCredentialTarget)
	if err != nil || secret == "" {
		return nil, errors.New("the local device private identity is unavailable")
	}
	privateBytes, err := base64.RawStdEncoding.DecodeString(secret)
	if err != nil || len(privateBytes) != ed25519.PrivateKeySize {
		return nil, errors.New("the local device private identity is corrupt")
	}
	private := ed25519.PrivateKey(privateBytes)
	derived, err := deriveDeviceIdentity(private, identity.CreatedAt)
	if err != nil || derived.DeviceID != identity.DeviceID || derived.PublicKey != identity.PublicKey {
		return nil, errors.New("the local device private identity does not match its metadata")
	}
	return private, nil
}

func deviceEnrollmentSigningBytes(response DeviceEnrollmentResponse) []byte {
	return []byte("PNA-DEVICE-ENROLL-V1\n" +
		"NODE_ID=" + response.NodeID + "\n" +
		"NONCE=" + response.Nonce + "\n" +
		"DEVICE_ID=" + response.DeviceID + "\n" +
		"PUBLIC_KEY=" + response.PublicKey + "\n" +
		"LABEL=" + response.Label + "\n" +
		"ROLE=" + response.Role + "\n")
}

func signDeviceEnrollment(response DeviceEnrollmentResponse, private ed25519.PrivateKey) (DeviceEnrollmentResponse, error) {
	if len(private) != ed25519.PrivateKeySize {
		return response, errors.New("invalid device signing key")
	}
	response.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, deviceEnrollmentSigningBytes(response)))
	return response, nil
}

func writeDeviceIdentityMetadata(path string, identity DeviceIdentity) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".device-identity-*.tmp")
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

func loadOrCreateDeviceIdentity() (DeviceIdentity, error) {
	path, err := deviceIdentityMetadataPath()
	if err != nil {
		return DeviceIdentity{}, err
	}
	metadata, metadataErr := os.ReadFile(path)
	if metadataErr == nil {
		var identity DeviceIdentity
		if err := json.Unmarshal(metadata, &identity); err != nil || validateDeviceIdentity(identity) != nil {
			return DeviceIdentity{}, errors.New("local device identity metadata is corrupt; refusing silent rotation")
		}
		secret, err := credentialRead(deviceIdentityCredentialTarget)
		if err != nil || secret == "" {
			return DeviceIdentity{}, errors.New("the local device private identity is missing from Windows Credential Manager; refusing silent rotation")
		}
		privateBytes, err := base64.RawStdEncoding.DecodeString(secret)
		if err != nil {
			return DeviceIdentity{}, errors.New("the local device private identity is corrupt")
		}
		derived, err := deriveDeviceIdentity(ed25519.PrivateKey(privateBytes), identity.CreatedAt)
		if err != nil || derived.DeviceID != identity.DeviceID || derived.PublicKey != identity.PublicKey {
			return DeviceIdentity{}, errors.New("local device private identity does not match its metadata")
		}
		return identity, nil
	}
	if !errors.Is(metadataErr, os.ErrNotExist) {
		return DeviceIdentity{}, metadataErr
	}
	if orphaned, readErr := credentialRead(deviceIdentityCredentialTarget); readErr == nil && orphaned != "" {
		return DeviceIdentity{}, errors.New("an orphaned local device credential exists; refusing silent replacement")
	}
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return DeviceIdentity{}, err
	}
	identity, err := deriveDeviceIdentity(private, time.Now())
	if err != nil {
		return DeviceIdentity{}, err
	}
	secret := base64.RawStdEncoding.EncodeToString(private)
	if err := credentialWrite(deviceIdentityCredentialTarget, identity.DeviceID, secret); err != nil {
		return DeviceIdentity{}, fmt.Errorf("could not protect the device identity in Windows Credential Manager: %w", err)
	}
	if err := writeDeviceIdentityMetadata(path, identity); err != nil {
		_ = credentialDelete(deviceIdentityCredentialTarget)
		return DeviceIdentity{}, err
	}
	return identity, nil
}

func parseDeviceStatus(stdout string) (DeviceStatus, error) {
	var status DeviceStatus
	lines := strings.Split(strings.ReplaceAll(stdout, "\r\n", "\n"), "\n")
	inside, ended := false, false
	for _, line := range lines {
		switch line {
		case "__PNA_DEVICE_STATUS_V1_BEGIN__":
			if inside || ended {
				return status, errors.New("duplicate device-status begin marker")
			}
			inside = true
			continue
		case "__PNA_DEVICE_STATUS_V1_END__":
			if !inside || ended {
				return status, errors.New("invalid device-status end marker")
			}
			ended = true
			inside = false
			continue
		}
		if !inside || line == "" {
			continue
		}
		if strings.HasPrefix(line, "DEVICE\t") {
			parts := strings.Split(line, "\t")
			if len(parts) != 6 || !deviceIDPattern.MatchString(parts[1]) || (parts[2] != "controller" && parts[2] != "traffic-only") ||
				(parts[3] != "active" && parts[3] != "paused" && parts[3] != "revoked") || !deviceLabelPattern.MatchString(parts[4]) {
				return status, errors.New("invalid device-status DEVICE record")
			}
			if _, err := time.Parse(time.RFC3339, parts[5]); err != nil {
				return status, errors.New("invalid device creation timestamp")
			}
			status.Devices = append(status.Devices, DeviceRecord{DeviceID: parts[1], Role: parts[2], Status: parts[3], Label: parts[4], CreatedAt: parts[5]})
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			return status, errors.New("invalid device-status field")
		}
		switch parts[0] {
		case "NODE_ID":
			status.NodeID = parts[1]
		case "CONTROLLER_ACTIVE_COUNT":
			var err error
			status.ActiveController, err = strconv.Atoi(parts[1])
			if err != nil || status.ActiveController < 0 {
				return status, errors.New("invalid active-controller count")
			}
		case "DEVICE_ACTIVE_COUNT":
			var err error
			status.ActiveDevices, err = strconv.Atoi(parts[1])
			if err != nil || status.ActiveDevices < 0 {
				return status, errors.New("invalid active-device count")
			}
		case "PER_DEVICE_VLESS":
			if parts[1] != "SUPPORTED" {
				return status, errors.New("unexpected per-device VLESS capability")
			}
		case "CDN_MTLS_DEVICE", "WIREGUARD_DEVICE_LOCK":
			if parts[1] != "EXPERIMENTAL_BLOCKED" {
				return status, errors.New("unexpected experimental device capability")
			}
		default:
			return status, fmt.Errorf("unknown device-status field %s", parts[0])
		}
	}
	if !ended || !nodeIDPattern.MatchString(status.NodeID) || status.ActiveController < 0 || status.ActiveDevices < 0 {
		return status, errors.New("device-status protocol is incomplete")
	}
	return status, nil
}

func encodeDeviceBundle(prefix string, value interface{}) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeDeviceInvite(bundle string) (DeviceInvite, error) {
	var invite DeviceInvite
	const prefix = "PNAINV1."
	if !strings.HasPrefix(strings.TrimSpace(bundle), prefix) {
		return invite, errors.New("invalid device invitation prefix")
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(strings.TrimSpace(bundle), prefix))
	if err != nil || len(data) > 2048 || json.Unmarshal(data, &invite) != nil {
		return invite, errors.New("invalid device invitation encoding")
	}
	if invite.Version != 1 || !nodeIDPattern.MatchString(invite.NodeID) || len(invite.Nonce) != 64 {
		return invite, errors.New("invalid device invitation fields")
	}
	if _, err := hex.DecodeString(invite.Nonce); err != nil || invite.ExpiresEpoch <= time.Now().Unix() || invite.ExpiresEpoch > time.Now().Add(11*time.Minute).Unix() {
		return invite, errors.New("device invitation is expired or invalid")
	}
	return invite, nil
}

func decodeDeviceResponse(bundle string) (DeviceEnrollmentResponse, error) {
	var response DeviceEnrollmentResponse
	const prefix = "PNARESP1."
	if !strings.HasPrefix(strings.TrimSpace(bundle), prefix) {
		return response, errors.New("invalid enrollment response prefix")
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(strings.TrimSpace(bundle), prefix))
	if err != nil || len(data) > 4096 || json.Unmarshal(data, &response) != nil {
		return response, errors.New("invalid enrollment response encoding")
	}
	if response.Version != 1 || !nodeIDPattern.MatchString(response.NodeID) || !deviceIDPattern.MatchString(response.DeviceID) ||
		!devicePublicPattern.MatchString(response.PublicKey) || !deviceLabelPattern.MatchString(response.Label) ||
		(response.Role != "controller" && response.Role != "traffic-only") || len(response.Nonce) != 64 || len(response.Signature) != 86 {
		return response, errors.New("invalid enrollment response fields")
	}
	public, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(response.PublicKey, "pna-ed25519:"))
	if err != nil || len(public) != ed25519.PublicKeySize {
		return response, errors.New("invalid enrollment public key")
	}
	digest := sha256.Sum256(public)
	if response.DeviceID != "pna-device-"+strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])) {
		return response, errors.New("enrollment device ID does not match its public key")
	}
	if _, err := hex.DecodeString(response.Nonce); err != nil {
		return response, errors.New("invalid enrollment nonce")
	}
	signature, err := base64.RawURLEncoding.DecodeString(response.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || !ed25519.Verify(ed25519.PublicKey(public), deviceEnrollmentSigningBytes(response), signature) {
		return response, errors.New("enrollment response signature is invalid")
	}
	return response, nil
}

func parseDeviceInviteOutput(stdout string) (DeviceInvite, error) {
	block, err := extractMarkerBlock(stdout, "__PNA_DEVICE_INVITE_V1_BEGIN__", "__PNA_DEVICE_INVITE_V1_END__")
	if err != nil {
		return DeviceInvite{}, err
	}
	values := parseDeviceKV(block)
	expires, err := strconv.ParseInt(values["EXPIRES_EPOCH"], 10, 64)
	if err != nil {
		return DeviceInvite{}, errors.New("invalid invitation expiry")
	}
	invite := DeviceInvite{Version: 1, NodeID: values["NODE_ID"], Nonce: values["ENROLLMENT_NONCE"], ExpiresEpoch: expires}
	bundle, _ := encodeDeviceBundle("PNAINV1.", invite)
	return decodeDeviceInvite(bundle)
}

func extractMarkerBlock(stdout, begin, end string) (string, error) {
	normalized := strings.ReplaceAll(stdout, "\r\n", "\n")
	start := strings.Index(normalized, begin+"\n")
	finish := strings.Index(normalized, "\n"+end)
	if start < 0 || finish <= start || strings.Count(normalized, begin) != 1 || strings.Count(normalized, end) != 1 {
		return "", errors.New("protected protocol markers are missing or duplicated")
	}
	return normalized[start+len(begin)+1 : finish], nil
}

func parseDeviceKV(block string) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(block, "\n") {
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			values[parts[0]] = parts[1]
		}
	}
	return values
}

func (a *App) getDeviceStatus(c Connection) (DeviceStatus, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh status")
	if !result.OK() {
		return DeviceStatus{}, fmt.Errorf("device status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	status, err := parseDeviceStatus(result.Stdout)
	if err != nil {
		return DeviceStatus{}, fmt.Errorf("device status protocol rejected: %w", err)
	}
	return status, nil
}

func (a *App) printDeviceStatus(status DeviceStatus, local DeviceIdentity) {
	a.println()
	a.println("================ DEVICE ADMISSION ================")
	a.println("NODE_ID=" + status.NodeID)
	a.println("LOCAL_DEVICE_ID=" + local.DeviceID)
	a.println(fmt.Sprintf("ACTIVE_CONTROLLERS=%d ACTIVE_DEVICES=%d", status.ActiveController, status.ActiveDevices))
	for _, device := range status.Devices {
		marker := ""
		if device.DeviceID == local.DeviceID {
			marker = " [THIS DEVICE]"
		}
		a.println(fmt.Sprintf("%s role=%s status=%s label=%s%s", device.DeviceID, device.Role, device.Status, device.Label, marker))
	}
	a.println(a.msg("per-device-vless 可独立吊销，但复制整条节点仍可冒充；它不是硬件不可克隆设备锁。", "per-device-vless supports independent revocation, but a copied node can still impersonate the device; this is not an uncloneable hardware lock."))
	a.println("CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED")
	a.println("WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED")
	a.println("==================================================")
}

func (a *App) manageDeviceAdmission() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return err
	}
	for {
		status, err := a.getDeviceStatus(c)
		if err != nil {
			return err
		}
		a.printDeviceStatus(status, identity)
		if status.ActiveController == 0 && a.yes(a.msg("此节点还没有 controller。把当前 Windows 设备登记为首个 controller？", "This node has no controller. Register this Windows device as the first controller?"), true) {
			label := strings.TrimSpace(a.prompt(a.msg("设备显示名称（1-64 个安全字符）", "Device label (1-64 safe characters)")))
			if !deviceLabelPattern.MatchString(label) {
				a.println(a.msg("设备名称无效。", "Invalid device label."))
				continue
			}
			input := []byte("\n" + identity.PublicKey + "\n" + label + "\ncontroller\n")
			result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh bootstrap-controller", input)
			if !result.OK() || !strings.Contains(result.Stdout, "__PNA_DEVICE_BOOTSTRAP_V1_END__") {
				return fmt.Errorf("first-controller bootstrap failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(a.msg("首个 controller 已登记并生成独立 VLESS 凭据。", "The first controller was registered with independent VLESS credentials."))
			continue
		}

		a.println(a.msg("[1] 刷新状态", "[1] Refresh status"))
		a.println(a.msg("[2] 复制当前设备公开身份（不含私钥）", "[2] Copy this device's public identity (no private key)"))
		a.println(a.msg("[3] controller 创建 10 分钟单次邀请", "[3] Controller: create a 10-minute single-use invitation"))
		a.println(a.msg("[4] 当前设备响应邀请", "[4] This device: respond to an invitation"))
		a.println(a.msg("[5] controller 批准响应并创建每设备 VLESS", "[5] Controller: approve a response and create per-device VLESS"))
		a.println(a.msg("[6] 暂停设备", "[6] Pause a device"))
		a.println(a.msg("[7] 恢复设备", "[7] Resume a device"))
		a.println(a.msg("[8] 吊销设备（最后一个 controller 受保护）", "[8] Revoke a device (last controller is protected)"))
		a.println(a.msg("[9] 显示并复制当前设备节点", "[9] Show and copy this device's nodes"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
		if a.inputClosed {
			return errInputClosed
		}
		switch choice {
		case "1":
			continue
		case "2":
			block := "DEVICE_ID=" + identity.DeviceID + "\nPUBLIC_KEY=" + identity.PublicKey
			if err := copyClipboard(block); err != nil {
				return err
			}
			a.println(block)
			a.println(a.msg("公开身份已复制；私钥仍只在 Windows Credential Manager。", "Public identity copied; the private identity remains only in Windows Credential Manager."))
		case "3":
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh create-invite "+shQuote(identity.DeviceID))
			if !result.OK() {
				return fmt.Errorf("device invitation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			invite, err := parseDeviceInviteOutput(result.Stdout)
			if err != nil {
				return err
			}
			bundle, _ := encodeDeviceBundle("PNAINV1.", invite)
			if err := a.secretHandoff("DEVICE ENROLLMENT INVITATION", bundle); err != nil {
				return err
			}
		case "4":
			bundle := strings.TrimSpace(a.prompt(a.msg("粘贴 PNAINV1 邀请", "Paste the PNAINV1 invitation")))
			invite, err := decodeDeviceInvite(bundle)
			if err != nil {
				a.println(err.Error())
				continue
			}
			label := strings.TrimSpace(a.prompt(a.msg("设备显示名称", "Device label")))
			if !deviceLabelPattern.MatchString(label) {
				a.println(a.msg("设备名称无效。", "Invalid device label."))
				continue
			}
			roleChoice := strings.TrimSpace(a.prompt(a.msg("角色：1=traffic-only，2=controller [1]", "Role: 1=traffic-only, 2=controller [1]")))
			role := "traffic-only"
			if roleChoice == "2" {
				role = "controller"
			} else if roleChoice != "" && roleChoice != "1" {
				a.println(a.msg("角色无效。", "Invalid role."))
				continue
			}
			private, err := loadDevicePrivateKey(identity)
			if err != nil {
				return err
			}
			response := DeviceEnrollmentResponse{Version: 1, NodeID: invite.NodeID, Nonce: invite.Nonce, DeviceID: identity.DeviceID, PublicKey: identity.PublicKey, Label: label, Role: role}
			response, err = signDeviceEnrollment(response, private)
			if err != nil {
				return err
			}
			encoded, _ := encodeDeviceBundle("PNARESP1.", response)
			if err := a.secretHandoff("DEVICE ENROLLMENT RESPONSE", encoded); err != nil {
				return err
			}
		case "5":
			bundle := strings.TrimSpace(a.prompt(a.msg("粘贴 PNARESP1 响应", "Paste the PNARESP1 response")))
			response, err := decodeDeviceResponse(bundle)
			if err != nil || response.NodeID != status.NodeID {
				a.println(a.msg("响应无效，或不属于当前节点。", "The response is invalid or belongs to another node."))
				continue
			}
			input := []byte(response.Nonce + "\n" + response.PublicKey + "\n" + response.Label + "\n" + response.Role + "\n" + response.Signature + "\n")
			result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh enroll", input)
			if !result.OK() || !strings.Contains(result.Stdout, "NONCE_CONSUMED=1") {
				return fmt.Errorf("device enrollment failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(a.msg("设备已登记；邀请已消费，不能重放。", "Device enrolled; the invitation was consumed and cannot be replayed."))
		case "6", "7", "8":
			target := strings.TrimSpace(a.prompt(a.msg("目标 DEVICE_ID", "Target DEVICE_ID")))
			if !deviceIDPattern.MatchString(target) {
				a.println(a.msg("DEVICE_ID 无效。", "Invalid DEVICE_ID."))
				continue
			}
			action := map[string]string{"6": "pause", "7": "resume", "8": "revoke"}[choice]
			if action == "revoke" && !a.yes(a.msg("吊销会让该设备的受管 VLESS 立即失效；继续？", "Revocation invalidates this device's managed VLESS credentials. Continue?"), false) {
				continue
			}
			result := a.rootCapture(c, fmt.Sprintf("bash %s/linux/26-device-admission.sh %s %s %s", remoteRoot, action, shQuote(identity.DeviceID), shQuote(target)))
			if !result.OK() || !strings.Contains(result.Stdout, "__PNA_DEVICE_STATE_V1_END__") {
				return fmt.Errorf("device state change failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
		case "9":
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh handoff "+shQuote(identity.DeviceID))
			if !result.OK() {
				return fmt.Errorf("device handoff failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			block, err := extractMarkerBlock(result.Stdout, "__PNA_DEVICE_HANDOFF_V1_BEGIN__", "__PNA_DEVICE_HANDOFF_V1_END__")
			if err != nil || !strings.Contains(block, "DIRECT_REALITY_LINK=vless://") {
				return errors.New("device handoff protocol failed validation")
			}
			if err := a.secretHandoff("CURRENT DEVICE NODES", block); err != nil {
				return err
			}
		case "0", "":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
		}
	}
}
