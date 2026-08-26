package main

import (
	"bufio"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func testDeviceIdentity(t *testing.T) DeviceIdentity {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for index := range seed {
		seed[index] = byte(index + 1)
	}
	identity, err := deriveDeviceIdentity(ed25519.NewKeyFromSeed(seed), time.Unix(1720000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	return identity
}

func TestDeviceIdentityDerivation(t *testing.T) {
	identity := testDeviceIdentity(t)
	if err := validateDeviceIdentity(identity); err != nil {
		t.Fatal(err)
	}
	if !deviceIDPattern.MatchString(identity.DeviceID) || !devicePublicPattern.MatchString(identity.PublicKey) {
		t.Fatalf("unexpected identity: %#v", identity)
	}
}

func TestDeviceBundlesRoundTrip(t *testing.T) {
	identity := testDeviceIdentity(t)
	sshBlob := "AAAAC3NzaC1lZDI1NTE5AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g"
	invite := DeviceInvite{Version: 2, NodeID: "tna-node-0123456789abcdef0123456789abcdef", Nonce: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", Host: "node.example", User: "root", Port: 22, KnownHosts: "node.example ssh-ed25519 " + sshBlob}
	bundle, err := encodeDeviceBundle("TNAINV2.", invite)
	if err != nil {
		t.Fatal(err)
	}
	parsedInvite, err := decodeDeviceInvite(bundle)
	if err != nil || parsedInvite.NodeID != invite.NodeID {
		t.Fatalf("invite round trip failed: %#v %v", parsedInvite, err)
	}
	response := DeviceEnrollmentResponse{Version: 2, NodeID: invite.NodeID, Nonce: invite.Nonce, DeviceID: identity.DeviceID, PublicKey: identity.PublicKey, Label: "Laptop 01", Role: "traffic-only", SSHUser: "root", SSHPublic: "ssh-ed25519 " + sshBlob, EncryptionPublic: "tna-x25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
	seed := make([]byte, ed25519.SeedSize)
	for index := range seed {
		seed[index] = byte(index + 1)
	}
	response, err = signDeviceEnrollment(response, ed25519.NewKeyFromSeed(seed))
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := encodeDeviceBundle("TNARESP2.", response)
	parsedResponse, err := decodeDeviceResponse(encoded)
	if err != nil || parsedResponse.DeviceID != identity.DeviceID {
		t.Fatalf("response round trip failed: %#v %v", parsedResponse, err)
	}
}

func TestJoinDeviceRequiresInvitationBeforeDecoding(t *testing.T) {
	app := &App{reader: bufio.NewReader(strings.NewReader("\n")), lang: LangEN}
	if err := app.joinDeviceWithInvitation(); !errors.Is(err, errInputClosed) {
		t.Fatalf("blank invitation must remain a required prompt, got %v", err)
	}
}

func TestDeviceResponseRejectsMismatchedIdentity(t *testing.T) {
	identity := testDeviceIdentity(t)
	publicBytes, _ := base64.RawURLEncoding.DecodeString(stringsTrimPrefixForTest(identity.PublicKey, "tna-ed25519:"))
	publicBytes[0] ^= 1
	response := DeviceEnrollmentResponse{
		Version: 2, NodeID: "tna-node-0123456789abcdef0123456789abcdef",
		Nonce:    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		DeviceID: identity.DeviceID, PublicKey: "tna-ed25519:" + base64.RawURLEncoding.EncodeToString(publicBytes),
		Label: "Laptop", Role: "controller", SSHUser: "root", SSHPublic: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g", EncryptionPublic: "tna-x25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		Signature: base64.RawURLEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)),
	}
	bundle, _ := encodeDeviceBundle("TNARESP2.", response)
	if _, err := decodeDeviceResponse(bundle); err == nil {
		t.Fatal("expected mismatched device identity to be rejected")
	}
}

func stringsTrimPrefixForTest(value, prefix string) string {
	if len(value) >= len(prefix) && value[:len(prefix)] == prefix {
		return value[len(prefix):]
	}
	return value
}

func TestParseDeviceStatus(t *testing.T) {
	text := "__TNA_DEVICE_STATUS_V1_BEGIN__\n" +
		"NODE_ID=tna-node-0123456789abcdef0123456789abcdef\n" +
		"CONTROLLER_ACTIVE_COUNT=1\nDEVICE_ACTIVE_COUNT=1\n" +
		"DEVICE\ttna-device-abcdefghijklmnopqrstuvwxyz\tcontroller\tactive\tLaptop 01\t2026-08-24T12:00:00Z\n" +
		"PER_DEVICE_VLESS=SUPPORTED\nCDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED\nWIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED\n" +
		"__TNA_DEVICE_STATUS_V1_END__\n"
	status, err := parseDeviceStatus(text)
	if err != nil || len(status.Devices) != 1 || status.ActiveController != 1 {
		t.Fatalf("unexpected status: %#v %v", status, err)
	}
}

func TestParseLegacyPNADeviceStatus(t *testing.T) {
	text := "__TNA_DEVICE_STATUS_V1_BEGIN__\n" +
		"NODE_ID=pna-node-0123456789abcdef0123456789abcdef\n" +
		"CONTROLLER_ACTIVE_COUNT=1\nDEVICE_ACTIVE_COUNT=1\n" +
		"DEVICE\tpna-device-abcdefghijklmnopqrstuvwxyz\tcontroller\tactive\tLegacy Laptop\t2026-08-24T12:00:00Z\n" +
		"PER_DEVICE_VLESS=SUPPORTED\nCDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED\nWIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED\n" +
		"__TNA_DEVICE_STATUS_V1_END__\n"
	status, err := parseDeviceStatus(text)
	if err != nil || status.NodeID != "pna-node-0123456789abcdef0123456789abcdef" || len(status.Devices) != 1 {
		t.Fatalf("legacy PNA status was rejected: %#v %v", status, err)
	}
}
