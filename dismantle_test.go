package main

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestRescue(t *testing.T, includeDrive bool) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rescue.tar.gz")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	tw := tar.NewWriter(gz)
	entries := []struct {
		name string
		body string
	}{
		{"text-node-backup-test/state/dpkg-packages.tsv", "fixture\n"},
	}
	if includeDrive {
		entries = append(entries,
			struct{ name, body string }{"text-node-backup-test/files/srv/text-node-assistant/drive-data/", ""},
			struct{ name, body string }{"text-node-backup-test/files/srv/text-node-assistant/drive-data/a.txt", "abc"},
			struct{ name, body string }{"text-node-backup-test/files/srv/text-node-assistant/drive-data/nested/b.bin", "12345"},
		)
	}
	for _, entry := range entries {
		typeflag := byte(tar.TypeReg)
		mode := int64(0600)
		if entry.body == "" && entry.name[len(entry.name)-1] == '/' {
			typeflag = tar.TypeDir
			mode = 0700
		}
		if err := tw.WriteHeader(&tar.Header{Name: entry.name, Mode: mode, Size: int64(len(entry.body)), Typeflag: typeflag}); err != nil {
			t.Fatal(err)
		}
		if entry.body != "" {
			if _, err := tw.Write([]byte(entry.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDismantleReceiptIsAtomicSecretFreeAndBoundToNode(t *testing.T) {
	root := t.TempDir()
	t.Setenv("TNA_CONFIG_ROOT", root)
	rescue := writeTestRescue(t, true)
	hash, err := fileSHA256(rescue)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(rescue)
	if err != nil {
		t.Fatal(err)
	}
	identity := NodeIdentity{
		ServerID: "tna-srv-0123456789abcdef0123456789abcdef", NodeID: "tna-node-0123456789abcdef0123456789abcdef",
		MachineIDHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		HostKeyAlg:    "ssh-ed25519", HostKeySHA256: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		FirstPublicIP: "192.0.2.10", CurrentPublicIP: "192.0.2.11",
	}
	plan := "ACTION=REMOVE_PROXY_RETAIN_DRIVE\nRESTORE_GRADE=EXACT\nREMOVED_RESOURCE_IDS=PROXY_XUI,PROXY_NGINX\nPRESERVED_RESOURCE_IDS=DRIVE_DATA,SSH_ACCESS\nDRIVE_DATA_ROOT=/srv/text-node-assistant/drive-data\n"
	result := "REMOVAL_TRANSACTION_ID=tna-remove-test\n"
	receipt := newDismantleReceipt(identity, Connection{Host: "node.example", User: "root", Port: 22}, "PROXY_ONLY", plan, result, rescue, hash, info.Size(), 2, 8, true)
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
	if decoded.NodeID != identity.NodeID || decoded.PostLifecycle != "PROXY_REMOVED_DRIVE_RETAINED" || decoded.RescueArchiveSHA256 != hash || len(decoded.RemovedResourceIDs) != 2 {
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
}

func TestDismantleReceiptLookupMatchesPhysicalInstanceNewestFirst(t *testing.T) {
	root := t.TempDir()
	t.Setenv("TNA_CONFIG_ROOT", root)
	rescue := writeTestRescue(t, true)
	hash, _ := fileSHA256(rescue)
	info, _ := os.Stat(rescue)
	base := DismantleReceipt{
		SchemaVersion: 1, Product: productName, ProductVersion: version, DesktopBuildID: desktopBuildID,
		ReceiptStatus: "VERIFIED", TransactionID: "tx", Mode: "FULL_BASELINE", Action: "RESTORE_CAPTURED_BASELINE", RestoreGrade: "EXACT",
		RemovedResourceIDs: []string{"ALL_TNA_PROXY"}, PreservedResourceIDs: []string{"SSH_RECOVERY"}, PostLifecycle: "BASELINE_UNMANAGED", PostVerification: "TNA_POST_DISMANTLE_VERIFY_OK",
		NodeID: "tna-node-0123456789abcdef0123456789abcdef", ServerID: "tna-srv-0123456789abcdef0123456789abcdef",
		MachineIDHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", SSHHostKeyAlgorithm: "ssh-ed25519", SSHHostKeySHA256: "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
		FirstKnownPublicIP: "192.0.2.10", CurrentPublicIP: "192.0.2.10", ConnectionHost: "node.example", ConnectionUser: "root", ConnectionPort: 22,
		RescueArchivePath: rescue, RescueArchiveSHA256: hash, RescueArchiveBytes: info.Size(), DriveDataRoot: "/srv/text-node-assistant/drive-data",
	}
	older := base
	older.CompletedAtUTC = "2026-08-24T01:00:00Z"
	if _, err := writeDismantleReceipt(older); err != nil {
		t.Fatal(err)
	}
	newer := base
	newer.CompletedAtUTC = "2026-08-25T01:00:00Z"
	newer.TransactionID = "tx-new"
	if _, err := writeDismantleReceipt(newer); err != nil {
		t.Fatal(err)
	}
	matches, err := readMatchingDismantleReceipts(base.MachineIDHash, base.SSHHostKeySHA256)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 2 || matches[0].TransactionID != "tx-new" {
		t.Fatalf("unexpected receipt order: %+v", matches)
	}
	none, err := readMatchingDismantleReceipts(strings.Repeat("f", 64), base.SSHHostKeySHA256)
	if err != nil || len(none) != 0 {
		t.Fatalf("unexpected non-match: %+v %v", none, err)
	}
}

func TestMenuOneCapturesBaselineBeforeIdentityDriveAndWizard(t *testing.T) {
	data, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	baseline := strings.Index(source, "captureOriginalBaselineBeforeConstruction(c)")
	identity := strings.Index(source, "ensureInstallNodeIdentity(c, relation, probe)")
	drive := strings.Index(source, "prepareMandatoryDrive(c)")
	wizard := strings.Index(source, "00-auto-install-or-optimize.sh")
	recover := strings.Index(source, "recoverInterruptedInstallTransaction(c)")
	begin := strings.Index(source, "beginInstallTransaction(c)")
	commit := strings.Index(source, "commitInstallTransaction(c, transactionID)")
	handoff := strings.Index(source, `secretHandoff("CREDENTIAL HANDOFF"`)
	if baseline < 0 || identity < 0 || drive < 0 || wizard < 0 || recover < 0 || begin < 0 || commit < 0 || handoff < 0 || !(recover < baseline && baseline < identity && identity < begin && begin < drive && drive < wizard && wizard < handoff && handoff < commit) {
		t.Fatalf("unsafe construction order: baseline=%d identity=%d drive=%d wizard=%d", baseline, identity, drive, wizard)
	}
}

func TestNodeIdentityScriptPreservesLegacyStableIdentityPrefix(t *testing.T) {
	sourceBytes, err := os.ReadFile(filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux", "23-node-identity.sh"))
	if err != nil {
		t.Fatal(err)
	}
	source := string(sourceBytes)
	for _, fragment := range []string{
		`^(tna|pna)-srv-[0-9a-f]{32}$`,
		`^(tna|pna)-node-[0-9a-f]{32}$`,
		`printf 'SERVER_ID=tna-srv-%s`,
		`printf 'NODE_ID=tna-node-%s`,
	} {
		if !strings.Contains(source, fragment) {
			t.Fatalf("node identity compatibility contract missing %q", fragment)
		}
	}
}

func TestVerifyDismantleRescueContents(t *testing.T) {
	path := writeTestRescue(t, true)
	stats, err := verifyDismantleRescueContents(path, true, 2, 8)
	if err != nil {
		t.Fatalf("verification failed: %v", err)
	}
	if !stats.DriveRootSeen || stats.DriveFiles != 2 || stats.DriveBytes != 8 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
}

func TestVerifyDismantleRescueRejectsMissingOrMismatchedDrive(t *testing.T) {
	if _, err := verifyDismantleRescueContents(writeTestRescue(t, false), true, 0, 0); err == nil {
		t.Fatal("missing drive root was accepted")
	}
	if _, err := verifyDismantleRescueContents(writeTestRescue(t, true), true, 2, 9); err == nil {
		t.Fatal("mismatched drive inventory was accepted")
	}
}
