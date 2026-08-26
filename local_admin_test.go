package main

import (
	"testing"
	"time"
)

func TestLocalAdminVerifierAndRecoveryRoundTrip(t *testing.T) {
	deviceID := "tna-device-abcdefghijklmnopqrstuvwxyz"
	password := "A correct admin passphrase 42!"
	pkg, code, err := makeLocalAdminRecovery(deviceID, password)
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := newLocalAdminVerifier(deviceID, password, pkg.PackageID, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if !verifyLocalAdminPassword(verifier, password) || verifyLocalAdminPassword(verifier, password+"x") {
		t.Fatal("scrypt verifier did not distinguish the password")
	}
	payload, err := decryptLocalAdminRecovery(pkg, code)
	if err != nil {
		t.Fatal(err)
	}
	if payload.Password != password || payload.DeviceID != deviceID || payload.Username != localAdminUsername {
		t.Fatalf("unexpected recovery payload: %+v", payload)
	}
	if _, err := decryptLocalAdminRecovery(pkg, code+"X"); err == nil {
		t.Fatal("wrong recovery code was accepted")
	}
}
