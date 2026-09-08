package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type NodeIdentity struct {
	ServerID        string
	NodeID          string
	MachineIDHash   string
	HostKeyAlg      string
	HostKeySHA256   string
	FirstPublicIP   string
	CurrentPublicIP string
}

var serverIDPattern = regexp.MustCompile(`^(?:tna|pna)-srv-[0-9a-f]{32}$`)

// nodeIDPattern is shared by the stable node identity and operation protocol.
// It is intentionally independent of the (retired) device-admission gate.
var nodeIDPattern = regexp.MustCompile(`^(?:tna|pna)-node-[0-9a-f]{32}$`)
var sha256FingerprintPattern = regexp.MustCompile(`^SHA256:[A-Za-z0-9+/]+$`)
var sha256HexPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func parseNodeIdentity(stdout string) (NodeIdentity, error) {
	block, err := extractMarkerBlockCurrentOrLegacy(stdout, "__TNA_NODE_IDENTITY_V1_BEGIN__", "__TNA_NODE_IDENTITY_V1_END__", "__PNA_NODE_IDENTITY_V1_BEGIN__", "__PNA_NODE_IDENTITY_V1_END__")
	if err != nil {
		return NodeIdentity{}, err
	}
	values := parseDeviceKV(block)
	identity := NodeIdentity{
		ServerID: values["SERVER_ID"], NodeID: values["NODE_ID"], MachineIDHash: values["MACHINE_ID_SHA256"],
		HostKeyAlg: values["SSH_HOST_KEY_ALGORITHM"], HostKeySHA256: values["SSH_HOST_KEY_SHA256"],
		FirstPublicIP: values["FIRST_KNOWN_PUBLIC_IP"], CurrentPublicIP: values["CURRENT_PUBLIC_IP"],
	}
	if !serverIDPattern.MatchString(identity.ServerID) || !nodeIDPattern.MatchString(identity.NodeID) || !sha256HexPattern.MatchString(identity.MachineIDHash) ||
		!sha256FingerprintPattern.MatchString(identity.HostKeySHA256) || values["MACHINE_ID_MATCH"] != "1" || values["SSH_HOST_KEY_MATCH"] != "1" {
		return NodeIdentity{}, errors.New("stable node identity protocol failed validation")
	}
	if _, err := canonicalPublicIPv4(identity.FirstPublicIP); err != nil {
		return NodeIdentity{}, errors.New("stable node identity contains an invalid first public IPv4")
	}
	if _, err := canonicalPublicIPv4(identity.CurrentPublicIP); err != nil {
		return NodeIdentity{}, errors.New("stable node identity contains an invalid current public IPv4")
	}
	if identity.HostKeyAlg != "ssh-ed25519" && identity.HostKeyAlg != "ssh-rsa" && !strings.HasPrefix(identity.HostKeyAlg, "ecdsa-sha2-nistp") {
		return NodeIdentity{}, errors.New("unsupported stable SSH host-key algorithm")
	}
	return identity, nil
}

func (a *App) fetchNodeIdentity(c Connection) (NodeIdentity, error) {
	// Keep identity readback usable during an in-place upgrade.  v0.9.x nodes
	// may expose only the legacy compatibility symlink; selecting the first
	// root that actually contains the helper avoids minting a replacement
	// identity merely because the new path is not linked yet.
	command := "set -u; root=" + shQuote(remoteRoot) + "; " +
		"[ -x \"$root/linux/23-node-identity.sh\" ] || root=" + shQuote(legacyTextRemoteRoot) + "; " +
		"[ -x \"$root/linux/23-node-identity.sh\" ] || root=" + shQuote(legacyRunbookRemoteRoot) + "; " +
		"[ -x \"$root/linux/23-node-identity.sh\" ] || { echo TNA_NODE_IDENTITY_ERROR=SCRIPT_MISSING >&2; exit 62; }; " +
		"bash \"$root/linux/23-node-identity.sh\" --show"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return NodeIdentity{}, fmt.Errorf("stable node identity readback failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parseNodeIdentity(result.Stdout)
}

func (a *App) syncManagedKeyIdentity(c Connection) error {
	if c.AuthMode != AuthManagedKey || !fileExists(c.KeyPath) || !fileExists(c.KeyPath+".pub") {
		return nil
	}
	identity, err := a.fetchNodeIdentity(c)
	if err != nil {
		return err
	}
	authKeyID, err := sshAuthenticationKeyID(c.KeyPath)
	if err != nil {
		return err
	}
	dir := filepath.Dir(c.KeyPath)
	info := managedKeyMetadata{
		Host: c.Host, User: c.User, Port: c.Port, Status: "BOUND", UpdatedAt: time.Now().UTC(),
		NodeID: identity.NodeID, ServerID: identity.ServerID, HostKeySHA256: identity.HostKeySHA256,
		MachineIDHash: identity.MachineIDHash, FirstKnownPublic: identity.FirstPublicIP, CurrentPublic: identity.CurrentPublicIP,
		SSHAuthKeyID: authKeyID,
	}
	return os.WriteFile(filepath.Join(dir, managedKeyInfoFile), encodeManagedKeyMetadata(info), 0600)
}

func sshAuthenticationKeyID(keyPath string) (string, error) {
	public, err := readPublicKey(keyPath)
	if err != nil {
		return "", err
	}
	fields := strings.Fields(public)
	if len(fields) < 2 || !supportedHostKeyType(fields[0]) {
		return "", errors.New("SSH public key has an unsupported shape")
	}
	blob, err := decodedHostKey(fields[1])
	if err != nil || len(blob) < 32 {
		return "", errors.New("SSH public key blob is invalid")
	}
	digest := sha256.Sum256(blob)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:]), nil
}
