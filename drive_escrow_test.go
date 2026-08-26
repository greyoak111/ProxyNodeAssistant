package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"testing"
)

func TestDriveCredentialEscrowRoundTripAndWrongController(t *testing.T) {
	curve := ecdh.X25519()
	private, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	identity := DeviceIdentity{
		DeviceID:         "tna-device-abcdefghijklmnopqrstuvwxyz",
		EncryptionPublic: "tna-x25519:" + base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes()),
	}
	controllers := []controllerEncryptionKey{{DeviceID: identity.DeviceID, Public: identity.EncryptionPublic}}
	escrow, err := encryptDriveCredential(
		"tna-node-0123456789abcdef0123456789abcdef",
		"tna-account-0123456789abcdef0123456789abcdef",
		"tna-space-fedcba9876543210fedcba9876543210",
		"alice", "correct-horse-battery-staple", controllers,
	)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := encodeDriveEscrow(escrow)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeDriveEscrow(encoded)
	if err != nil {
		t.Fatal(err)
	}
	password, err := decryptDriveCredential(decoded, identity, private)
	if err != nil || password != "correct-horse-battery-staple" {
		t.Fatalf("unexpected decrypted credential %q: %v", password, err)
	}
	other, _ := curve.GenerateKey(rand.Reader)
	if _, err := decryptDriveCredential(decoded, DeviceIdentity{DeviceID: identity.DeviceID, EncryptionPublic: identity.EncryptionPublic}, other); err == nil {
		t.Fatal("a different controller private key decrypted the escrow")
	}
}

func TestParseControllerEncryptionKeysRejectsDuplicates(t *testing.T) {
	text := "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__\n" +
		"CONTROLLER\ttna-device-abcdefghijklmnopqrstuvwxyz\ttna-x25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" +
		"CONTROLLER\ttna-device-abcdefghijklmnopqrstuvwxyz\ttna-x25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" +
		"__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__\n"
	if _, err := parseControllerEncryptionKeys(text); err == nil {
		t.Fatal("duplicate controller encryption keys were accepted")
	}
}
