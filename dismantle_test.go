package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func testDismantleReceipt(t *testing.T, completed, transaction string) DismantleReceipt {
	t.Helper()
	rescue := t.TempDir() + "/rescue.tar.gz"
	if err := os.WriteFile(rescue, []byte("rescue evidence\n"), 0600); err != nil {
		t.Fatal(err)
	}
	hash, err := fileSHA256(rescue)
	if err != nil {
		t.Fatal(err)
	}
	identity := NodeIdentity{
		ServerID: "tna-srv-0123456789abcdef0123456789abcdef", NodeID: "tna-node-0123456789abcdef0123456789abcdef",
		MachineIDHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		HostKeyAlg:    "ssh-ed25519", HostKeySHA256: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		FirstPublicIP: "192.0.2.10", CurrentPublicIP: "192.0.2.11",
	}
	return DismantleReceipt{
		SchemaVersion: dismantleReceiptSchemaVersion, Product: productName, ProductVersion: version, DesktopBuildID: desktopBuildID,
		ReceiptStatus: "VERIFIED", CompletedAtUTC: completed, TransactionID: transaction, Mode: "FULL_BASELINE",
		Action: "RESTORE_CAPTURED_BASELINE", RestoreGrade: "EXACT", RemovedResourceIDs: []string{"MANAGED_NODE_STACK"},
		PreservedResourceIDs: []string{"SSH_ACCESS"}, PostLifecycle: "BASELINE_UNMANAGED", PostVerification: "PNA_POST_DISMANTLE_VERIFY_OK",
		NodeID: identity.NodeID, ServerID: identity.ServerID, MachineIDHash: identity.MachineIDHash,
		SSHHostKeyAlgorithm: identity.HostKeyAlg, SSHHostKeySHA256: identity.HostKeySHA256,
		FirstKnownPublicIP: identity.FirstPublicIP, CurrentPublicIP: identity.CurrentPublicIP,
		ConnectionHost: "node.example", ConnectionUser: "root", ConnectionPort: 22,
		RescueArchivePath: rescue, RescueArchiveSHA256: hash, RescueArchiveBytes: 16,
	}
}

func TestDismantleReceiptIsAtomicSecretFreeAndBoundToNode(t *testing.T) {
	t.Setenv("PNA_CONFIG_ROOT", t.TempDir())
	receipt := testDismantleReceipt(t, "2026-08-25T01:00:00Z", "tna-remove-test")
	path, err := writeDismantleReceipt(receipt)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var decoded DismantleReceipt
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.NodeID != receipt.NodeID || decoded.PostLifecycle != "BASELINE_UNMANAGED" || decoded.RescueArchiveSHA256 != receipt.RescueArchiveSHA256 {
		t.Fatalf("unexpected receipt: %+v", decoded)
	}
	for _, forbidden := range []string{"PASSWORD", "PRIVATE_KEY", "SUBSCRIPTION", "API_TOKEN", "VLESS://"} {
		if strings.Contains(strings.ToUpper(string(data)), forbidden) {
			t.Fatalf("receipt contains forbidden secret-bearing field %q", forbidden)
		}
	}
	if _, err := os.Stat(path + ".new"); !os.IsNotExist(err) {
		t.Fatalf("temporary receipt was left behind: %v", err)
	}
	if _, err := writeDismantleReceipt(receipt); !os.IsExist(err) {
		t.Fatalf("duplicate receipt was not rejected: %v", err)
	}
}

func TestDismantleReceiptLookupMatchesPhysicalInstanceNewestFirst(t *testing.T) {
	t.Setenv("PNA_CONFIG_ROOT", t.TempDir())
	older := testDismantleReceipt(t, "2026-08-24T01:00:00Z", "tx-old")
	newer := testDismantleReceipt(t, "2026-08-25T01:00:00Z", "tx-new")
	if _, err := writeDismantleReceipt(older); err != nil {
		t.Fatal(err)
	}
	if _, err := writeDismantleReceipt(newer); err != nil {
		t.Fatal(err)
	}
	matches, err := readMatchingDismantleReceipts(older.MachineIDHash, older.SSHHostKeySHA256)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 2 || matches[0].TransactionID != "tx-new" {
		t.Fatalf("unexpected receipt order: %+v", matches)
	}
	none, err := readMatchingDismantleReceipts(strings.Repeat("f", 64), older.SSHHostKeySHA256)
	if err != nil || len(none) != 0 {
		t.Fatalf("unexpected non-match: %+v %v", none, err)
	}
}

func TestDismantleReceiptRejectsRetiredModes(t *testing.T) {
	receipt := testDismantleReceipt(t, "2026-08-25T01:00:00Z", "tx")
	receipt.Mode = "PROXY_ONLY"
	if err := validateDismantleReceipt(receipt); err == nil {
		t.Fatal("retired partial-removal mode was accepted")
	}
}
