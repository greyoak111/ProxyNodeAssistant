package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestManagedKeyMetadataRoundTrip(t *testing.T) {
	want := managedKeyMetadata{
		Host:      "vps-1.example.test",
		User:      "root",
		Port:      2222,
		Status:    "REVOKED_REMOTE_KEY",
		UpdatedAt: time.Date(2026, 8, 21, 12, 34, 56, 0, time.UTC),
	}
	encoded := encodeManagedKeyMetadata(want)
	if bytes.Contains(encoded, []byte(want.Host)) {
		t.Fatal("host should be encoded rather than stored as a free-form line")
	}
	got, err := parseManagedKeyMetadata(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got.Host != want.Host || got.User != want.User || got.Port != want.Port || got.Status != want.Status || !got.UpdatedAt.Equal(want.UpdatedAt) {
		t.Fatalf("metadata mismatch: %#v", got)
	}
}

func TestManagedKeyMetadataRejectsInvalidTarget(t *testing.T) {
	data := []byte("FORMAT=1\nHOST_B64=Li4vYmFk\nUSER_B64=cm9vdA==\nPORT=22\nSTATUS=BOUND\nUPDATED_AT=2026-08-21T00:00:00Z\n")
	if _, err := parseManagedKeyMetadata(data); err == nil {
		t.Fatal("unsafe target metadata was accepted")
	}
}

func TestListManagedKeyDirectoriesIncludesIncompleteNodesAndSkipsRestoreStaging(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"node-a-root", "node-b-ubuntu", ".restore-abandoned"} {
		if err := os.Mkdir(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "not-a-directory"), []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	directories, err := listManagedKeyDirectories(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(directories) != 2 || filepath.Base(directories[0]) != "node-a-root" || filepath.Base(directories[1]) != "node-b-ubuntu" {
		t.Fatalf("unexpected managed directories: %#v", directories)
	}
}

func TestMoveManagedKeyDirectoryToBackupLeavesBoundPositionEmpty(t *testing.T) {
	root := filepath.Join(t.TempDir(), "active")
	backupRoot := filepath.Join(t.TempDir(), "backup")
	dir := filepath.Join(root, "node-a-root")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"id_ed25519", "id_ed25519.pub", "known_hosts"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	destination, err := moveManagedKeyDirectoryToBackupAtRoots(filepath.Join(dir, "id_ed25519"), time.Date(2026, 8, 21, 1, 2, 3, 0, time.UTC), root, backupRoot)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("bound position was not emptied: %v", err)
	}
	if filepath.Base(destination) != "node-a-root-20260821-010203" {
		t.Fatalf("unexpected backup destination: %s", destination)
	}
	for _, name := range []string{"id_ed25519", "id_ed25519.pub", "known_hosts"} {
		if _, err := os.Stat(filepath.Join(destination, name)); err != nil {
			t.Fatalf("archived file %s is missing: %v", name, err)
		}
	}
}

func TestDeployCleanupPromptIsBetweenHandoffAndPanel(t *testing.T) {
	source, err := os.ReadFile("operations.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	handoff := strings.Index(text, `a.secretHandoff("CREDENTIAL HANDOFF", completeHandoff)`)
	cleanup := strings.Index(text, `"是否在打开面板前整理远端多余备份`)
	panel := strings.Index(text, `"现在无感打开 3x-ui 面板？`)
	if handoff < 0 || cleanup < 0 || panel < 0 || !(handoff < cleanup && cleanup < panel) {
		t.Fatalf("unexpected deploy finalization order: handoff=%d cleanup=%d panel=%d", handoff, cleanup, panel)
	}
	if !strings.Contains(text[cleanup:panel], "pruneBackupsAndBackupCurrentConfigWithConn(c, false)") {
		t.Fatal("deploy cleanup does not use the already-authenticated connection with y/n confirmation")
	}
}
