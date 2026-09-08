package main

import (
	"errors"
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
	legacyKey := filepath.Join(home, ".ssh", "text-node-assistant", "node-root", "id_ed25519")
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
		filepath.Join(home, ".ssh", "proxy-runbook", "node-root", "id_ed25519"),
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

func TestLegacyKeyMigrationRescansAfterCompletedJournal(t *testing.T) {
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
	firstKey := filepath.Join(home, ".ssh", "text-node-assistant", "first-root", "id_ed25519")
	if err := os.MkdirAll(filepath.Dir(firstKey), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(firstKey, []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := migrateLegacyLocalState(); err != nil {
		t.Fatal(err)
	}
	// Simulate a key imported/bound after the initial v1 startup. The journal
	// is already complete, so this specifically exercises the incremental scan.
	laterKey := filepath.Join(home, ".ssh", "text-node-assistant", "later-root", "id_ed25519")
	if err := os.MkdirAll(filepath.Dir(laterKey), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(laterKey, []byte("later"), 0600); err != nil {
		t.Fatal(err)
	}
	record, err := migrateLegacyLocalState()
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Copied) == 0 {
		t.Fatalf("completed migration did not report the newly discovered key: %#v", record)
	}
	migrated := filepath.Join(home, ".ssh", "proxy-runbook", "later-root", "id_ed25519")
	if _, err := os.Stat(migrated); err != nil {
		t.Fatalf("new legacy key was not copied after journal completion: %v", err)
	}
}

func TestLegacyConfigMigrationSkipsRetiredDriveAndAdmissionState(t *testing.T) {
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
	// Ordinary settings/history and a previously exported handoff remain useful
	// for the v1 client and must survive an upgrade.
	for _, name := range []string{"settings.json", "recent-targets.tsv", "handoff-links.env"} {
		if err := os.WriteFile(filepath.Join(legacy, name), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// These entries belong to the retired local-admin/UI gate, device identity,
	// remote admission, or private-drive experiment. They stay in the legacy
	// tree as an untouched archive but must not enter the active config root.
	retired := map[string]string{
		"local-admin-verifier.json":           "admin",
		"ui-security.json":                    "gate",
		"device-identity.json":                "identity",
		"TNA-DEVICE-ADMISSION.json":           "admission",
		"private-drive.env":                   "drive",
		"drive-credential-escrow/secret.json": "escrow",
		"nested/controller/invite.json":       "invite",
		"nested/copyparty/copyparty.conf":     "copyparty",
		"private-drive-state/manifest.json":   "state",
	}
	for name, contents := range retired {
		path := filepath.Join(legacy, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	record, err := migrateLegacyLocalState()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"settings.json", "recent-targets.tsv", "handoff-links.env"} {
		if _, err := os.Stat(filepath.Join(current, name)); err != nil {
			t.Fatalf("useful legacy state was not migrated: %s: %v", name, err)
		}
	}
	for name := range retired {
		if _, err := os.Stat(filepath.Join(current, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("retired legacy entry was copied into active config: %s", name)
		}
		if _, err := os.Stat(filepath.Join(legacy, name)); err != nil {
			t.Fatalf("copy-first migration removed retired source %s: %v", name, err)
		}
	}
	if len(record.Warnings) < len(retired) {
		t.Fatalf("retired entries were not recorded as skipped warnings: %#v", record.Warnings)
	}
	for name := range retired {
		matched := false
		topLevel := strings.SplitN(name, "/", 2)[0]
		for _, warning := range record.Warnings {
			if strings.Contains(warning, topLevel) {
				matched = true
				break
			}
		}
		if !matched {
			t.Fatalf("missing skip warning for %s: %#v", name, record.Warnings)
		}
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
	path := filepath.Join("runbook", "proxy-node-assistant-v1.0.0", "linux", "00-migrate-legacy-state.sh")
	data, err := os.ReadFile(path)
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
