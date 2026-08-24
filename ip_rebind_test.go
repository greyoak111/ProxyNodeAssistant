package main

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestCanonicalPublicIPv4RejectsUnsafeInputs(t *testing.T) {
	for _, value := range []string{"", "127.0.0.1", "10.0.0.1", "100.64.0.1", "192.0.2.1", "203.0.113.10", "8.8.8.8 ", "example.com", "::1"} {
		if _, err := canonicalPublicIPv4(value); err == nil {
			t.Fatalf("unsafe IP accepted: %q", value)
		}
	}
	if got, err := canonicalPublicIPv4("8.8.8.8"); err != nil || got != "8.8.8.8" {
		t.Fatalf("public IPv4 rejected: got=%q err=%v", got, err)
	}
}

func TestPinnedHostKeyLinesRequireExactOldFingerprint(t *testing.T) {
	blob := make([]byte, 48)
	for index := range blob {
		blob[index] = byte(index + 1)
	}
	line := "203.0.113.9 ssh-ed25519 " + base64.StdEncoding.EncodeToString(blob)
	fingerprint, err := hostKeyLineFingerprint(line)
	if err != nil {
		t.Fatal(err)
	}
	lines, err := pinnedHostKeyLines(line+"\n", fingerprint)
	if err != nil || len(lines) != 1 || lines[0] != line {
		t.Fatalf("exact fingerprint was not retained: %#v %v", lines, err)
	}
	if _, err := pinnedHostKeyLines(line, "SHA256:not-the-old-key"); err == nil || !strings.Contains(err.Error(), "HOST_KEY_MISMATCH") {
		t.Fatalf("mismatched host key was not blocked: %v", err)
	}
}

func TestIPRebindPreflightProtocolIsStrict(t *testing.T) {
	valid := `noise
__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__
IP_REBIND_STATUS=IP_REBIND_PREPARED
OLD_IP=8.8.8.8
NEW_IP=1.1.1.1
OLD_CONSTRUCTION_DOMAIN=old.example.com
NEW_CONSTRUCTION_DOMAIN=old.example.com
SERVER_ID_MATCH=1
NODE_ID_UNCHANGED=1
MACHINE_ID_MATCH=1
REMOTE_PUBLIC_IP_MATCH=1
DEPLOYMENT_MODE=direct-reality
ACTIVE_MODE=ACTIVE_DIRECT
SNAPSHOT_CREATED=1
DNS_MUTATED=0
CLOUDFLARE_MUTATION=NONE
__PNA_IP_REBIND_PREFLIGHT_V1_END__
`
	ctx, err := parseIPRebindPreflight(valid)
	if err != nil || ctx.NewIP != "1.1.1.1" || ctx.Mode != "direct-reality" {
		t.Fatalf("valid preflight rejected: %#v %v", ctx, err)
	}
	if _, err := parseIPRebindPreflight(strings.Replace(valid, "DNS_MUTATED=0", "DNS_MUTATED=1", 1)); err == nil {
		t.Fatal("preflight that already mutated DNS was accepted")
	}
	if _, err := parseIPRebindPreflight(strings.Replace(valid, "SERVER_ID_MATCH=1", "SERVER_ID_MATCH=0", 1)); err == nil {
		t.Fatal("server identity mismatch was accepted")
	}
}

func TestManagedKeyMetadataV2PreservesStableRebindIdentity(t *testing.T) {
	want := managedKeyMetadata{
		Host: "8.8.8.8", User: "root", Port: 22, Status: "BOUND", UpdatedAt: time.Unix(42, 0).UTC(),
		NodeID: "pna-node-0123456789abcdef0123456789abcdef", ServerID: "pna-srv-0123456789abcdef0123456789abcdef",
		HostKeySHA256: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", MachineIDHash: strings.Repeat("a", 64),
		FirstKnownPublic: "8.8.8.8", CurrentPublic: "1.1.1.1", SSHAuthKeyID: "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
	}
	got, err := parseManagedKeyMetadata(encodeManagedKeyMetadata(want))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("stable metadata changed:\n got=%#v\nwant=%#v", got, want)
	}
}
