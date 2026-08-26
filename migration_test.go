package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestLegacyLocalMigrationIsCopyFirstAndIdempotent(t *testing.T) {
	root := t.TempDir()
	legacy := filepath.Join(root, "legacy")
	current := filepath.Join(root, "current")
	home := filepath.Join(root, "home")
	t.Setenv("TNA_LEGACY_CONFIG_ROOT", legacy)
	t.Setenv("TNA_CONFIG_ROOT", current)
	t.Setenv("TNA_DISABLE_CREDENTIAL_MIGRATION", "1")
	t.Setenv("USERPROFILE", home)
	t.Setenv("HOME", home)
	if err := os.MkdirAll(legacy, 0700); err != nil {
		t.Fatal(err)
	}
	legacySettings := filepath.Join(legacy, "settings.json")
	if err := os.WriteFile(legacySettings, []byte(`{"language":"en"}`), 0600); err != nil {
		t.Fatal(err)
	}
	legacyKey := filepath.Join(home, ".ssh", "proxy-runbook", "node-root", "id_ed25519")
	if err := os.MkdirAll(filepath.Dir(legacyKey), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyKey, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	record, err := migrateLegacyLocalState()
	if err != nil {
		t.Fatal(err)
	}
	if record.CompletedAt == "" || len(record.Copied) != 2 {
		t.Fatalf("unexpected migration record: %#v", record)
	}
	for _, path := range []string{
		filepath.Join(current, "settings.json"),
		filepath.Join(home, ".ssh", "text-node-assistant", "node-root", "id_ed25519"),
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("migrated file is missing: %s: %v", path, err)
		}
	}
	if _, err := os.Stat(legacySettings); err != nil {
		t.Fatalf("copy-first migration removed the legacy source: %v", err)
	}
	second, err := migrateLegacyLocalState()
	if err != nil || second.CompletedAt != record.CompletedAt {
		t.Fatalf("migration was not idempotent: %#v %v", second, err)
	}
}

func TestLegacyMigrationRefusesSymlinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows developer-mode symlink permissions are environment-dependent")
	}
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	if err := os.MkdirAll(source, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(source, "link")); err != nil {
		t.Skip(err)
	}
	copied := []string{}
	if err := copyLegacyTree(source, destination, &copied); err == nil {
		t.Fatal("migration accepted a symlink")
	}
}

func TestRemoteLegacyMigrationNeverRechmodsExistingSystemParents(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux", "00-migrate-legacy-state.sh"))
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	if strings.Contains(source, `install -d -m 700 "$(dirname "$target")"`) {
		t.Fatal("remote migration would chmod an existing system parent such as /etc")
	}
	for _, fragment := range []string{`parent="$(dirname "$target")"`, `if [ -e "$parent" ]`, `[ -d "$parent" ]`, `install -d -m 700 "$parent"`} {
		if !strings.Contains(source, fragment) {
			t.Fatalf("safe parent-preservation contract missing %q", fragment)
		}
	}
}
