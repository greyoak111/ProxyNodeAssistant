package main

import (
	"crypto/ecdh"
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

const (
	deviceIdentityCredentialTarget   = "TextNodeAssistant/device-identity/v2"
	deviceEncryptionCredentialTarget = "TextNodeAssistant/device-encryption/v2"
)

type DeviceIdentity struct {
	Version          int       `json:"version"`
	DeviceID         string    `json:"deviceId"`
	PublicKey        string    `json:"publicKey"`
	EncryptionPublic string    `json:"encryptionPublic,omitempty"`
	CreatedAt        time.Time `json:"createdAt"`
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
	ExpiresEpoch int64  `json:"expires,omitempty"`
	Host         string `json:"host,omitempty"`
	User         string `json:"user,omitempty"`
	Port         int    `json:"port,omitempty"`
	KnownHosts   string `json:"knownHosts,omitempty"`
}

type DeviceEnrollmentResponse struct {
	Version          int    `json:"v"`
	NodeID           string `json:"node"`
	Nonce            string `json:"nonce"`
	DeviceID         string `json:"device"`
	PublicKey        string `json:"public"`
	Label            string `json:"label"`
	Role             string `json:"role"`
	SSHUser          string `json:"sshUser,omitempty"`
	SSHPublic        string `json:"sshPublic,omitempty"`
	EncryptionPublic string `json:"encryptionPublic,omitempty"`
	Signature        string `json:"signature"`
}

var deviceIDPattern = regexp.MustCompile(`^(?:tna|pna)-device-[a-z2-7]{26}$`)
var nodeIDPattern = regexp.MustCompile(`^(?:tna|pna)-node-[0-9a-f]{32}$`)
var devicePublicPattern = regexp.MustCompile(`^(?:tna|pna)-ed25519:[A-Za-z0-9_-]{43}$`)
var deviceLabelPattern = regexp.MustCompile(`^[A-Za-z0-9._ -]{1,64}$`)
var deviceSSHPublicPattern = regexp.MustCompile(`^ssh-ed25519 [A-Za-z0-9+/]{68}$`)
var deviceEncryptionPublicPattern = regexp.MustCompile(`^tna-x25519:[A-Za-z0-9_-]{43}$`)

func deviceIdentityMetadataPath() (string, error) {
	base, err := productConfigRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "device-identity.json"), nil
}

func deriveDeviceIdentity(private ed25519.PrivateKey, created time.Time) (DeviceIdentity, error) {
	return deriveDeviceIdentityVersion(private, created, 2)
}

func deriveDeviceIdentityVersion(private ed25519.PrivateKey, created time.Time, version int) (DeviceIdentity, error) {
	if len(private) != ed25519.PrivateKeySize {
		return DeviceIdentity{}, errors.New("invalid local device private key length")
	}
	prefix := "tna"
	if version == 1 {
		prefix = "pna"
	} else if version != 2 {
		return DeviceIdentity{}, errors.New("unsupported local device identity version")
	}
	public := private.Public().(ed25519.PublicKey)
	digest := sha256.Sum256(public)
	return DeviceIdentity{
		Version:   version,
		DeviceID:  prefix + "-device-" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])),
		PublicKey: prefix + "-ed25519:" + base64.RawURLEncoding.EncodeToString(public),
		CreatedAt: created.UTC(),
	}, nil
}

func validateDeviceIdentity(identity DeviceIdentity) error {
	if (identity.Version != 1 && identity.Version != 2) || !deviceIDPattern.MatchString(identity.DeviceID) || !devicePublicPattern.MatchString(identity.PublicKey) || identity.CreatedAt.IsZero() {
		return errors.New("local device identity metadata is invalid")
	}
	prefix := "tna"
	if identity.Version == 1 {
		prefix = "pna"
	}
	if !strings.HasPrefix(identity.DeviceID, prefix+"-device-") || !strings.HasPrefix(identity.PublicKey, prefix+"-ed25519:") {
		return errors.New("local device identity prefix does not match its version")
	}
	if identity.EncryptionPublic != "" && !deviceEncryptionPublicPattern.MatchString(identity.EncryptionPublic) {
		return errors.New("local device encryption public key is invalid")
	}
	public, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(identity.PublicKey, prefix+"-ed25519:"))
	if err != nil || len(public) != ed25519.PublicKeySize {
		return errors.New("local device public key is invalid")
	}
	digest := sha256.Sum256(public)
	if identity.DeviceID != prefix+"-device-"+strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])) {
		return errors.New("local device ID does not match its public key")
	}
	return nil
}

func ensureDeviceEncryptionIdentity(path string, identity DeviceIdentity) (DeviceIdentity, error) {
	curve := ecdh.X25519()
	secret, readErr := credentialRead(deviceEncryptionCredentialTarget)
	if readErr == nil && secret != "" {
		raw, err := base64.RawStdEncoding.DecodeString(secret)
		if err != nil {
			return identity, errors.New("the local device encryption private key is corrupt")
		}
		private, err := curve.NewPrivateKey(raw)
		if err != nil {
			return identity, errors.New("the local device encryption private key is invalid")
		}
		public := "tna-x25519:" + base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes())
		if identity.EncryptionPublic != "" && identity.EncryptionPublic != public {
			return identity, errors.New("the local device encryption key does not match its metadata")
		}
		if identity.EncryptionPublic == "" {
			identity.EncryptionPublic = public
			if err := writeDeviceIdentityMetadata(path, identity); err != nil {
				return identity, err
			}
		}
		return identity, nil
	}
	if readErr != nil && !errors.Is(readErr, errCredentialManagerUnsupported) && identity.EncryptionPublic != "" {
		return identity, errors.New("the local device encryption credential is unavailable; refusing silent rotation")
	}
	if identity.EncryptionPublic != "" {
		return identity, errors.New("the local device encryption private key is missing; refusing silent rotation")
	}
	private, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return identity, err
	}
	secret = base64.RawStdEncoding.EncodeToString(private.Bytes())
	identity.EncryptionPublic = "tna-x25519:" + base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes())
	if err := credentialWrite(deviceEncryptionCredentialTarget, identity.DeviceID, secret); err != nil {
		return identity, fmt.Errorf("could not protect the device encryption key in Windows Credential Manager: %w", err)
	}
	if err := writeDeviceIdentityMetadata(path, identity); err != nil {
		_ = credentialDelete(deviceEncryptionCredentialTarget)
		return identity, err
	}
	return identity, nil
}

func loadDeviceEncryptionPrivate(identity DeviceIdentity) (*ecdh.PrivateKey, error) {
	secret, err := credentialRead(deviceEncryptionCredentialTarget)
	if err != nil || secret == "" {
		return nil, errors.New("the local device encryption private key is unavailable")
	}
	raw, err := base64.RawStdEncoding.DecodeString(secret)
	if err != nil {
		return nil, errors.New("the local device encryption private key is corrupt")
	}
	private, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil || "tna-x25519:"+base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes()) != identity.EncryptionPublic {
		return nil, errors.New("the local device encryption key does not match its metadata")
	}
	return private, nil
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
	derived, err := deriveDeviceIdentityVersion(private, identity.CreatedAt, identity.Version)
	if err != nil || derived.DeviceID != identity.DeviceID || derived.PublicKey != identity.PublicKey {
		return nil, errors.New("the local device private identity does not match its metadata")
	}
	return private, nil
}

func deviceEnrollmentSigningBytes(response DeviceEnrollmentResponse) []byte {
	header := "TNA-DEVICE-ENROLL-V2\n"
	if response.Version == 1 {
		header = "PNA-DEVICE-ENROLL-V1\n"
	}
	return []byte(header +
		"NODE_ID=" + response.NodeID + "\n" +
		"NONCE=" + response.Nonce + "\n" +
		"DEVICE_ID=" + response.DeviceID + "\n" +
		"PUBLIC_KEY=" + response.PublicKey + "\n" +
		"LABEL=" + response.Label + "\n" +
		"ROLE=" + response.Role + "\n" +
		func() string {
			if response.Version == 2 {
				return "ENCRYPTION_PUBLIC_KEY=" + response.EncryptionPublic + "\n" +
					"SSH_LOGIN_USER=" + response.SSHUser + "\n" +
					"SSH_PUBLIC_KEY=" + response.SSHPublic + "\n"
			}
			return ""
		}())
}

func signDeviceEnrollment(response DeviceEnrollmentResponse, private ed25519.PrivateKey) (DeviceEnrollmentResponse, error) {
	if len(private) != ed25519.PrivateKeySize {
		return response, errors.New("invalid device signing key")
	}
	response.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, deviceEnrollmentSigningBytes(response)))
	return response, nil
}

func controllerEncryptionKeySigningBytes(nodeID, deviceID, encryptionPublic string) []byte {
	return []byte("TNA-CONTROLLER-ENCRYPTION-KEY-V1\n" +
		"NODE_ID=" + nodeID + "\n" +
		"DEVICE_ID=" + deviceID + "\n" +
		"ENCRYPTION_PUBLIC_KEY=" + encryptionPublic + "\n")
}

func (a *App) ensureServerControllerEncryptionKey(c Connection, status DeviceStatus, identity DeviceIdentity) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh controller-encryption-keys "+shQuote(identity.DeviceID))
	if result.OK() {
		keys, err := parseControllerEncryptionKeys(result.Stdout)
		if err != nil {
			return err
		}
		for _, key := range keys {
			if key.DeviceID == identity.DeviceID && key.Public == identity.EncryptionPublic {
				return nil
			}
		}
		return errors.New("active controller encryption-key readback is inconsistent")
	}
	private, err := loadDevicePrivateKey(identity)
	if err != nil {
		return err
	}
	signature := base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, controllerEncryptionKeySigningBytes(status.NodeID, identity.DeviceID, identity.EncryptionPublic)))
	input := []byte(identity.EncryptionPublic + "\n" + signature + "\n")
	result = a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh refresh-controller-encryption-key "+shQuote(identity.DeviceID), input)
	if !result.OK() || !strings.Contains(result.Stdout, "CONTROLLER_ENCRYPTION_KEY_READY=1") {
		return fmt.Errorf("controller encryption-key migration failed: %s", processFailureDetail(result))
	}
	return nil
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
		derived, err := deriveDeviceIdentityVersion(ed25519.PrivateKey(privateBytes), identity.CreatedAt, identity.Version)
		if err != nil || derived.DeviceID != identity.DeviceID || derived.PublicKey != identity.PublicKey {
			return DeviceIdentity{}, errors.New("local device private identity does not match its metadata")
		}
		return ensureDeviceEncryptionIdentity(path, identity)
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
	return ensureDeviceEncryptionIdentity(path, identity)
}

func parseDeviceStatus(stdout string) (DeviceStatus, error) {
	var status DeviceStatus
	stdout = strings.ReplaceAll(stdout, "__TNA_DEVICE_STATUS_V1_BEGIN__", "__PNA_DEVICE_STATUS_V1_BEGIN__")
	stdout = strings.ReplaceAll(stdout, "__TNA_DEVICE_STATUS_V1_END__", "__PNA_DEVICE_STATUS_V1_END__")
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
				(parts[3] != "active" && parts[3] != "paused" && parts[3] != "revoked" && parts[3] != "pending-verification") || !deviceLabelPattern.MatchString(parts[4]) {
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
	value := strings.TrimSpace(bundle)
	prefix, version := "", 0
	if strings.HasPrefix(value, "TNAINV2.") {
		prefix, version = "TNAINV2.", 2
	} else if strings.HasPrefix(value, "PNAINV1.") {
		prefix, version = "PNAINV1.", 1
	} else {
		return invite, errors.New("invalid device invitation prefix")
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, prefix))
	if err != nil || len(data) > 8192 || json.Unmarshal(data, &invite) != nil {
		return invite, errors.New("invalid device invitation encoding")
	}
	if invite.Version != version || !nodeIDPattern.MatchString(invite.NodeID) || len(invite.Nonce) != 64 {
		return invite, errors.New("invalid device invitation fields")
	}
	if _, err := hex.DecodeString(invite.Nonce); err != nil {
		return invite, errors.New("device invitation is invalid")
	}
	if invite.Version == 1 && (invite.ExpiresEpoch <= time.Now().Unix() || invite.ExpiresEpoch > time.Now().Add(11*time.Minute).Unix()) {
		return invite, errors.New("device invitation is expired or invalid")
	}
	if invite.Version == 2 && invite.ExpiresEpoch != 0 {
		return invite, errors.New("bind-until-success invitation has an unexpected expiry")
	}
	if invite.Version == 2 {
		if !validRecentTarget(RecentTarget{Host: invite.Host, User: invite.User, Port: invite.Port}) || strings.TrimSpace(invite.KnownHosts) == "" {
			return invite, errors.New("device invitation has no usable SSH endpoint")
		}
		c := Connection{Host: invite.Host, User: invite.User, Port: invite.Port}
		for _, line := range strings.Split(strings.TrimSpace(invite.KnownHosts), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 3 || !hostTokenMatchesConnection(fields[0], &c) || !supportedHostKeyType(fields[1]) {
				return invite, errors.New("device invitation contains an invalid pinned host key")
			}
			if _, err := decodedHostKey(fields[2]); err != nil {
				return invite, errors.New("device invitation contains an invalid pinned host key")
			}
		}
	}
	return invite, nil
}

func decodeDeviceResponse(bundle string) (DeviceEnrollmentResponse, error) {
	var response DeviceEnrollmentResponse
	value := strings.TrimSpace(bundle)
	prefix, version, identityPrefix := "", 0, ""
	if strings.HasPrefix(value, "TNARESP2.") {
		prefix, version, identityPrefix = "TNARESP2.", 2, "tna"
	} else if strings.HasPrefix(value, "PNARESP1.") {
		prefix, version, identityPrefix = "PNARESP1.", 1, "pna"
	} else {
		return response, errors.New("invalid enrollment response prefix")
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, prefix))
	if err != nil || len(data) > 4096 || json.Unmarshal(data, &response) != nil {
		return response, errors.New("invalid enrollment response encoding")
	}
	if response.Version != version || !nodeIDPattern.MatchString(response.NodeID) || !deviceIDPattern.MatchString(response.DeviceID) ||
		!devicePublicPattern.MatchString(response.PublicKey) || !deviceLabelPattern.MatchString(response.Label) ||
		(response.Role != "controller" && response.Role != "traffic-only") || len(response.Nonce) != 64 || len(response.Signature) != 86 {
		return response, errors.New("invalid enrollment response fields")
	}
	if !strings.HasPrefix(response.DeviceID, identityPrefix+"-device-") || !strings.HasPrefix(response.PublicKey, identityPrefix+"-ed25519:") {
		return response, errors.New("enrollment identity generation does not match the bundle version")
	}
	if response.Version == 2 {
		if !deviceEncryptionPublicPattern.MatchString(response.EncryptionPublic) {
			return response, errors.New("enrollment encryption public key is invalid")
		}
		if !userPartPattern.MatchString(response.SSHUser) {
			return response, errors.New("enrollment SSH login user is invalid")
		}
		if !deviceSSHPublicPattern.MatchString(response.SSHPublic) {
			return response, errors.New("enrollment SSH public key is invalid")
		}
	}
	public, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(response.PublicKey, identityPrefix+"-ed25519:"))
	if err != nil || len(public) != ed25519.PublicKeySize {
		return response, errors.New("invalid enrollment public key")
	}
	digest := sha256.Sum256(public)
	if response.DeviceID != identityPrefix+"-device-"+strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:16])) {
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

func parseDeviceInviteOutput(stdout string, c Connection) (DeviceInvite, error) {
	block, err := extractMarkerBlock(stdout, "__TNA_DEVICE_INVITE_V2_BEGIN__", "__TNA_DEVICE_INVITE_V2_END__")
	if err != nil {
		return DeviceInvite{}, err
	}
	values := parseDeviceKV(block)
	if values["EXPIRES_ON_SUCCESSFUL_BIND"] != "1" {
		return DeviceInvite{}, errors.New("invalid invitation consumption policy")
	}
	knownHosts, readErr := os.ReadFile(knownHostsPath(c))
	if readErr != nil || len(knownHosts) == 0 || len(knownHosts) > 6144 {
		return DeviceInvite{}, errors.New("the controller has no usable pinned SSH host-key bundle")
	}
	invite := DeviceInvite{Version: 2, NodeID: values["NODE_ID"], Nonce: values["ENROLLMENT_NONCE"], Host: c.Host, User: c.User, Port: c.Port, KnownHosts: strings.TrimSpace(string(knownHosts))}
	bundle, _ := encodeDeviceBundle("TNAINV2.", invite)
	return decodeDeviceInvite(bundle)
}

func normalizeDeviceSSHPublic(value string) (string, error) {
	fields := strings.Fields(strings.TrimSpace(value))
	if len(fields) < 2 {
		return "", errors.New("SSH public key is incomplete")
	}
	normalized := fields[0] + " " + fields[1]
	if !deviceSSHPublicPattern.MatchString(normalized) {
		return "", errors.New("only a valid Ed25519 SSH public key is accepted")
	}
	return normalized, nil
}

func prepareInvitationSSH(invite DeviceInvite) (Connection, string, error) {
	keyPath, err := defaultKeyPath(invite.Host, invite.User)
	if err != nil {
		return Connection{}, "", err
	}
	dir := filepath.Dir(keyPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return Connection{}, "", err
	}
	knownPath := filepath.Join(dir, "known_hosts")
	if current, readErr := os.ReadFile(knownPath); readErr == nil {
		if strings.TrimSpace(string(current)) != strings.TrimSpace(invite.KnownHosts) {
			return Connection{}, "", errors.New("the existing pinned host keys differ from the controller invitation; refusing to overwrite trust")
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return Connection{}, "", readErr
	} else if err := os.WriteFile(knownPath, []byte(strings.TrimSpace(invite.KnownHosts)+"\n"), 0600); err != nil {
		return Connection{}, "", err
	}
	if !fileExists(keyPath) && !fileExists(keyPath+".pub") {
		if err := generateKey(keyPath, "text-node-assistant-device-enrollment"); err != nil {
			return Connection{}, "", err
		}
	} else if !fileExists(keyPath) || !fileExists(keyPath+".pub") {
		return Connection{}, "", errors.New("the pending enrollment SSH key pair is incomplete; refusing silent replacement")
	}
	if err := validatePrivatePublicKeyPair(keyPath); err != nil {
		return Connection{}, "", err
	}
	public, err := readPublicKey(keyPath)
	if err != nil {
		return Connection{}, "", err
	}
	public, err = normalizeDeviceSSHPublic(public)
	if err != nil {
		return Connection{}, "", err
	}
	c := Connection{Host: invite.Host, User: invite.User, Port: invite.Port, KeyPath: keyPath, AuthMode: AuthManagedKey, Ready: true}
	if err := writeManagedKeyMetadata(dir, c, "PENDING_DEVICE_BIND"); err != nil {
		return Connection{}, "", err
	}
	return c, public, nil
}

func (a *App) joinDeviceWithInvitation() error {
	bundle, inputErr := a.required(a.msg("粘贴 controller 创建的 TNAINV2 邀请", "Paste the TNAINV2 invitation created by a controller"))
	if inputErr != nil {
		return inputErr
	}
	bundle = strings.TrimSpace(bundle)
	invite, err := decodeDeviceInvite(bundle)
	if err != nil {
		return err
	}
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return err
	}
	label := strings.TrimSpace(a.prompt(a.msg("设备显示名称（1-64 个安全字符）", "Device label (1-64 safe characters)")))
	if !deviceLabelPattern.MatchString(label) {
		return errors.New(a.msg("设备名称无效。", "Invalid device label."))
	}
	roleChoice := strings.TrimSpace(a.prompt(a.msg("角色：1=仅流量/网盘，2=controller [1]", "Role: 1=traffic/drive only, 2=controller [1]")))
	role := "traffic-only"
	if roleChoice == "2" {
		role = "controller"
	} else if roleChoice != "" && roleChoice != "1" {
		return errors.New(a.msg("角色无效。", "Invalid role."))
	}
	c, sshPublic, err := prepareInvitationSSH(invite)
	if err != nil {
		return err
	}
	private, err := loadDevicePrivateKey(identity)
	if err != nil {
		return err
	}
	response := DeviceEnrollmentResponse{Version: 2, NodeID: invite.NodeID, Nonce: invite.Nonce, DeviceID: identity.DeviceID, PublicKey: identity.PublicKey, Label: label, Role: role, SSHUser: invite.User, SSHPublic: sshPublic, EncryptionPublic: identity.EncryptionPublic}
	response, err = signDeviceEnrollment(response, private)
	if err != nil {
		return err
	}
	encoded, _ := encodeDeviceBundle("TNARESP2.", response)
	if err := a.secretHandoff("DEVICE ENROLLMENT RESPONSE", encoded); err != nil {
		return err
	}
	a.println(a.msg("请把响应交给现有 controller，在其设备准入菜单 [5] 批准。批准只会预登记，不会消费邀请。", "Give the response to an existing controller and approve it with device-admission menu [5]. Approval only pre-registers the device and does not consume the invitation."))
	a.prompt(a.msg("controller 显示 pending-verification 后，回到这里按 Enter 发起首次 key 登录", "After the controller shows pending-verification, return here and press Enter to make the first key login"))
	result := a.sshCapture(c, "true")
	if !result.OK() || !strings.Contains(result.Stdout, "__TNA_DEVICE_BIND_V2_END__") || !strings.Contains(result.Stdout, "NONCE_CONSUMED=1") {
		return fmt.Errorf("%s: %s", a.msg("首次设备 key 登录尚未完成；邀请仍可重试，私钥保留在本机", "The first device-key login has not completed; the invitation remains retryable and the private key remains local"), processFailureDetail(result))
	}
	if err := writeManagedKeyMetadata(filepath.Dir(c.KeyPath), c, "BOUND_DEVICE_VERIFIED"); err != nil {
		return err
	}
	if err := rememberRecentTarget(RecentTarget{Host: c.Host, User: c.User, Port: c.Port}); err != nil {
		a.println(a.msg("节点已绑定，但保存登录历史失败：", "The node was bound, but saving login history failed: ") + err.Error())
	}
	block, blockErr := extractMarkerBlock(result.Stdout, "__TNA_DEVICE_HANDOFF_V1_BEGIN__", "__TNA_DEVICE_HANDOFF_V1_END__")
	if blockErr == nil {
		values := parseDeviceKV(block)
		drivePort, portErr := strconv.Atoi(values["DRIVE_LOOPBACK_PORT"])
		if values["DEVICE_ID"] != identity.DeviceID || values["DEVICE_ROLE"] != role || portErr != nil {
			return errors.New("bound-device handoff metadata failed validation")
		}
		if err := saveLocalDeviceAdmission(c, localDeviceAdmission{NodeID: invite.NodeID, DeviceID: identity.DeviceID, Role: role, DrivePort: drivePort}); err != nil {
			return fmt.Errorf("device was bound but local admission state could not be committed: %w", err)
		}
		if err := a.secretHandoff("CURRENT DEVICE NODES", block); err != nil {
			return err
		}
	}
	a.println(a.msg("设备 key、独立 VLESS 与网盘回环权限均已实际绑定；邀请现已失效。", "The device key, independent VLESS, and loopback-drive permission are now actually bound; the invitation is consumed."))
	return nil
}

func extractMarkerBlockCurrentOrLegacy(stdout, begin, end, legacyBegin, legacyEnd string) (string, error) {
	block, err := extractMarkerBlock(stdout, begin, end)
	if err == nil {
		return block, nil
	}
	return extractMarkerBlock(stdout, legacyBegin, legacyEnd)
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

// ensureCurrentControllerAfterInstall closes the bootstrap gap between a
// successfully converged node and the device-admission model.  Menu [1] is
// the only installation entry point, so a brand-new node must leave that
// workflow with the installing device registered as its first controller.
// Existing nodes are never silently claimed by a different device.
func (a *App) ensureCurrentControllerAfterInstall(c Connection) error {
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return fmt.Errorf("local device identity is unavailable: %w", err)
	}
	status, err := a.getDeviceStatus(c)
	if err != nil {
		return err
	}
	for _, device := range status.Devices {
		if device.DeviceID != identity.DeviceID {
			continue
		}
		if device.Role == "controller" && device.Status == "active" {
			if err := a.ensureServerControllerEncryptionKey(c, status, identity); err != nil {
				return err
			}
			if err := a.refreshManagedDeviceSSHKeys(c, identity.DeviceID); err != nil {
				return err
			}
			if err := a.recordLocalAdmissionFromRemote(c, status.NodeID, identity.DeviceID, "controller"); err != nil {
				return err
			}
			a.println(a.msg("当前设备已经是此节点的 active controller。", "This device is already an active controller for this node."))
			return nil
		}
		return fmt.Errorf(a.msg(
			"当前设备在节点登记中为 %s/%s；菜单 [1] 不会静默提升或覆盖它，请由现有 controller 在设备准入中处理",
			"This device is registered on the node as %s/%s; menu [1] will not silently elevate or overwrite it. Use device admission from an existing controller",
		), device.Role, device.Status)
	}
	if status.ActiveController != 0 {
		return errors.New(a.msg(
			"此节点已经有 controller，但当前设备尚未获准入。请在当前设备首页使用 [J] 响应一次性邀请；菜单 [1] 不会绕过批准流程",
			"This node already has a controller but this device is not admitted. Use [J] on this device with a single-use invitation; menu [1] will not bypass approval",
		))
	}
	label := strings.TrimSpace(a.prompt(a.msg("为当前首个 controller 输入设备显示名称（1—64 个安全字符）", "Enter a display label for this first controller (1-64 safe characters)")))
	if a.inputClosed {
		return errInputClosed
	}
	if !deviceLabelPattern.MatchString(label) {
		return errors.New(a.msg("设备显示名称无效；节点已施工，但尚未交付 controller，重新运行 [1] 可继续收敛。", "The device label is invalid; the node is converged but no controller was delivered. Run [1] again to resume."))
	}
	sshPublic, err := readPublicKey(c.KeyPath)
	if err != nil {
		return err
	}
	sshPublic, err = normalizeDeviceSSHPublic(sshPublic)
	if err != nil {
		return err
	}
	input := []byte("\n" + identity.PublicKey + "\n" + label + "\ncontroller\n" + identity.EncryptionPublic + "\n" + c.User + "\n" + sshPublic + "\n\n")
	result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh bootstrap-controller", input)
	if !result.OK() || (!strings.Contains(result.Stdout, "__TNA_DEVICE_BOOTSTRAP_V1_END__") && !strings.Contains(result.Stdout, "__PNA_DEVICE_BOOTSTRAP_V1_END__")) {
		return fmt.Errorf("first-controller bootstrap failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	status, err = a.getDeviceStatus(c)
	if err != nil {
		return err
	}
	for _, device := range status.Devices {
		if device.DeviceID == identity.DeviceID && device.Role == "controller" && device.Status == "active" {
			if err := a.ensureServerControllerEncryptionKey(c, status, identity); err != nil {
				return err
			}
			if err := a.refreshManagedDeviceSSHKeys(c, identity.DeviceID); err != nil {
				return err
			}
			if err := a.recordLocalAdmissionFromRemote(c, status.NodeID, identity.DeviceID, "controller"); err != nil {
				return err
			}
			a.println(a.msg("当前设备已作为首个 controller 完成真实登记。", "This device was verified as the first active controller."))
			return nil
		}
	}
	return errors.New("first-controller bootstrap did not pass status readback")
}

func (a *App) refreshManagedDeviceSSHKeys(c Connection, controllerDeviceID string) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh refresh-device-ssh-keys "+shQuote(controllerDeviceID))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_DEVICE_SSH_KEYS_REFRESHED=") {
		return fmt.Errorf("managed device SSH restriction refresh failed: %s", processFailureDetail(result))
	}
	return nil
}

func (a *App) recordLocalAdmissionFromRemote(c Connection, nodeID, deviceID, role string) error {
	drive, err := a.driveStatus(c)
	if err != nil {
		return fmt.Errorf("mandatory drive status could not be recorded for this device: %w", err)
	}
	port, err := validatedDrivePort(drive["COPYPARTY_LOOPBACK_PORT"])
	if err != nil {
		return err
	}
	return saveLocalDeviceAdmission(c, localDeviceAdmission{NodeID: nodeID, DeviceID: deviceID, Role: role, DrivePort: port})
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
			sshPublic, pubErr := readPublicKey(c.KeyPath)
			if pubErr != nil {
				return pubErr
			}
			sshPublic, pubErr = normalizeDeviceSSHPublic(sshPublic)
			if pubErr != nil {
				return pubErr
			}
			input := []byte("\n" + identity.PublicKey + "\n" + label + "\ncontroller\n" + identity.EncryptionPublic + "\n" + c.User + "\n" + sshPublic + "\n\n")
			result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh bootstrap-controller", input)
			if !result.OK() || (!strings.Contains(result.Stdout, "__TNA_DEVICE_BOOTSTRAP_V1_END__") && !strings.Contains(result.Stdout, "__PNA_DEVICE_BOOTSTRAP_V1_END__")) {
				return fmt.Errorf("first-controller bootstrap failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(a.msg("首个 controller 已登记并生成独立 VLESS 凭据。", "The first controller was registered with independent VLESS credentials."))
			continue
		}

		a.println(a.msg("[1] 刷新状态", "[1] Refresh status"))
		a.println(a.msg("[2] 复制当前设备公开身份（不含私钥）", "[2] Copy this device's public identity (no private key)"))
		a.println(a.msg("[3] controller 创建一次性邀请（新设备成功绑定后才失效）", "[3] Controller: create a single-use invitation consumed only after successful binding"))
		a.println(a.msg("[4] 新设备响应邀请（请在新设备首页使用 [J]，此处仅说明）", "[4] New device response (use [J] on the new device home screen; guidance only here)"))
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
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh create-invite "+shQuote(identity.DeviceID)+" "+shQuote(c.User))
			if !result.OK() {
				return fmt.Errorf("device invitation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			invite, err := parseDeviceInviteOutput(result.Stdout, c)
			if err != nil {
				return err
			}
			bundle, _ := encodeDeviceBundle("TNAINV2.", invite)
			if err := a.secretHandoff("DEVICE ENROLLMENT INVITATION", bundle); err != nil {
				return err
			}
		case "4":
			a.println(a.msg("请在尚未获准入的新设备首页选择 [J]。该入口不要求先登录 VPS，会生成本机独享 SSH key 和响应包。", "On the not-yet-admitted device, choose [J] on the home screen. It does not require prior VPS login and creates a device-local SSH key and response bundle."))
		case "5":
			bundle := strings.TrimSpace(a.prompt(a.msg("粘贴 TNARESP2 响应", "Paste the TNARESP2 response")))
			response, err := decodeDeviceResponse(bundle)
			if err != nil || response.NodeID != status.NodeID {
				a.println(a.msg("响应无效，或不属于当前节点。", "The response is invalid or belongs to another node."))
				continue
			}
			input := []byte(response.Nonce + "\n" + response.PublicKey + "\n" + response.Label + "\n" + response.Role + "\n" + response.EncryptionPublic + "\n" + response.SSHUser + "\n" + response.SSHPublic + "\n" + response.Signature + "\n")
			result := a.rootCaptureWithInput(c, "bash "+remoteRoot+"/linux/26-device-admission.sh enroll", input)
			if !result.OK() || !strings.Contains(result.Stdout, "STATUS=pending-verification") || !strings.Contains(result.Stdout, "NONCE_CONSUMED=0") {
				return fmt.Errorf("device enrollment failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			if response.Role == "controller" {
				if err := a.preparePendingControllerEscrow(c, identity, response.DeviceID); err != nil {
					return fmt.Errorf(a.msg(
						"controller 已保持 pending-verification，但已有网盘凭据尚未全部安全封装给它；邀请未消费，可修复后重试批准：%w",
						"The controller remains pending-verification, but existing drive credentials were not fully rewrapped for it. The invitation was not consumed; fix the issue and retry approval: %w",
					), err)
				}
			}
			a.println(a.msg("设备已预登记为 pending-verification；邀请仍未消费。让新设备回到 [J] 流程按 Enter，首次 key 登录成功后才会激活。", "The device is pre-registered as pending-verification and the invitation is not consumed. Have the new device return to [J] and press Enter; activation occurs only after its first key login succeeds."))
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
			if !result.OK() || (!strings.Contains(result.Stdout, "__TNA_DEVICE_STATE_V1_END__") && !strings.Contains(result.Stdout, "__PNA_DEVICE_STATE_V1_END__")) {
				return fmt.Errorf("device state change failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
		case "9":
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/26-device-admission.sh handoff "+shQuote(identity.DeviceID))
			if !result.OK() {
				return fmt.Errorf("device handoff failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			block, err := extractMarkerBlockCurrentOrLegacy(result.Stdout, "__TNA_DEVICE_HANDOFF_V1_BEGIN__", "__TNA_DEVICE_HANDOFF_V1_END__", "__PNA_DEVICE_HANDOFF_V1_BEGIN__", "__PNA_DEVICE_HANDOFF_V1_END__")
			if err != nil || (!strings.Contains(block, "DIRECT_REALITY_LINK=vless://") && !strings.Contains(block, "CDN_XHTTP_LINK=vless://")) {
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
