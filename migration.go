package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Schema 2 adds an explicit retirement boundary for the old local-admin,
// device-identity/admission, and private-drive state. Bumping the journal
// schema makes an already-completed migration run once more under the new
// boundary instead of silently treating those files as active configuration.
const localMigrationSchema = 2

type localMigrationRecord struct {
	Schema      int      `json:"schema"`
	StartedAt   string   `json:"started_at"`
	CompletedAt string   `json:"completed_at,omitempty"`
	Copied      []string `json:"copied,omitempty"`
	Warnings    []string `json:"warnings,omitempty"`
}

func writeJSONAtomic(path string, value interface{}, mode os.FileMode) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".tna-write-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, path)
}

func copyLegacyFile(source, destination string) (bool, error) {
	if _, err := os.Stat(destination); err == nil {
		return false, nil
	} else if !os.IsNotExist(err) {
		return false, err
	}
	info, err := os.Lstat(source)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("legacy migration refused non-regular file %s", source)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return false, err
	}
	in, err := os.Open(source)
	if err != nil {
		return false, err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		if os.IsExist(err) {
			return false, nil
		}
		return false, err
	}
	committed := false
	defer func() {
		out.Close()
		if !committed {
			os.Remove(destination)
		}
	}()
	if _, err := io.Copy(out, in); err != nil {
		return false, err
	}
	if err := out.Sync(); err != nil {
		return false, err
	}
	if err := out.Close(); err != nil {
		return false, err
	}
	committed = true
	return true, nil
}

func copyLegacyTree(source, destination string, copied *[]string) error {
	info, err := os.Lstat(source)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("legacy migration refused symlink %s", source)
	}
	if info.Mode().IsRegular() {
		ok, err := copyLegacyFile(source, destination)
		if ok {
			*copied = append(*copied, destination)
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("legacy migration refused special file %s", source)
	}
	if err := os.MkdirAll(destination, 0700); err != nil {
		return err
	}
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := copyLegacyTree(filepath.Join(source, entry.Name()), filepath.Join(destination, entry.Name()), copied); err != nil {
			return err
		}
	}
	return nil
}

// retiredLegacyConfigEntry reports names that belonged exclusively to the
// over-scoped v0.9.5 local-admin/device-admission/private-drive experiment.
// The local migration remains copy-first for ordinary settings/history and
// handoff material, but copying one of these entries into the current product
// root could resurrect a removed gate. Keep this predicate limited to the
// config-root migration below: managed SSH key and revoked-key trees still use
// copyLegacyTree unchanged so no key is filtered by a user-chosen filename.
func retiredLegacyConfigEntry(name string) bool {
	base := strings.ToLower(strings.TrimSpace(filepath.Base(name)))
	if base == "" || base == "." || base == ".." {
		return false
	}
	// Exact names cover the files emitted by v0.9.5 and the intermediate reset
	// builds.  The token checks cover nested state directories and harmlessly
	// catch renamed variants such as private-drive-state.json.
	for _, exact := range []string{
		"local-admin-verifier.json",
		"ui-security.json",
		"device-identity.json",
		"tna-device-admission.json",
		"pna-device-admission.json",
		"device-admission.json",
		"device-registry.json",
		"private-drive.env",
		"copyparty.conf",
		"drive-accounts.tsv",
		"drive-credential-escrow",
		"copyparty",
		"admission",
		"controller",
		"invite",
		"invites",
		"drive",
		"drives",
	} {
		if base == exact {
			return true
		}
	}
	for _, token := range []string{
		"local-admin",
		"ui-security",
		"device-identity",
		"device-admission",
		"device-registry",
		"private-drive",
		"copyparty",
		"drive-account",
		"drive-credential",
		"controller-invite",
	} {
		if strings.Contains(base, token) {
			return true
		}
	}
	return false
}

// copyLegacyConfigTree is the guarded variant used for the old per-user
// configuration root. It keeps ordinary settings/history and handoff material
// while omitting retired local-admin/UI-gate/device-identity and
// drive/admission entries. A skipped path is recorded for auditability; no
// source data is removed.
func copyLegacyConfigTree(source, destination string, copied, warnings *[]string) error {
	return copyLegacyConfigTreeAt(source, destination, copied, warnings, "")
}

func copyLegacyConfigTreeAt(source, destination string, copied, warnings *[]string, relative string) error {
	info, err := os.Lstat(source)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("legacy migration refused symlink %s", source)
	}
	if info.Mode().IsRegular() {
		ok, err := copyLegacyFile(source, destination)
		if ok {
			*copied = append(*copied, destination)
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("legacy migration refused special file %s", source)
	}
	if err := os.MkdirAll(destination, 0700); err != nil {
		return err
	}
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		entryRelative := entry.Name()
		if relative != "" {
			entryRelative = filepath.Join(relative, entry.Name())
		}
		if retiredLegacyConfigEntry(entry.Name()) {
			if warnings != nil {
				*warnings = append(*warnings, "retired legacy config skipped: "+entryRelative)
			}
			continue
		}
		if err := copyLegacyConfigTreeAt(filepath.Join(source, entry.Name()), filepath.Join(destination, entry.Name()), copied, warnings, entryRelative); err != nil {
			return err
		}
	}
	return nil
}

func managedKeyRootsForMigration() (newRoot, legacyRoot, newRevoked, legacyRevoked string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", "", err
	}
	// ProxyNodeAssistant is the canonical v1 path.  v0.9.5 used the
	// TextNodeAssistant name; migration is copy-first and never removes the
	// legacy tree.  Keeping this direction explicit is important because an
	// earlier reset build accidentally reversed the two names and could make
	// an upgrade appear to lose every bound key.
	return filepath.Join(home, ".ssh", "proxy-runbook"),
		filepath.Join(home, ".ssh", "text-node-assistant"),
		filepath.Join(home, ".ssh", "proxy-runbook-revoked"),
		filepath.Join(home, ".ssh", "text-node-assistant-revoked"), nil
}

// migrateLegacyLocalState is copy-first and deliberately leaves legacy data in
// place. New code writes only PNA paths; deletion of the recoverable legacy
// snapshot is a separate, explicit maintenance action.
func migrateLegacyLocalState() (localMigrationRecord, error) {
	currentRoot, err := productConfigRoot()
	if err != nil {
		return localMigrationRecord{}, err
	}
	legacyRoot, err := legacyConfigRoot()
	if err != nil {
		return localMigrationRecord{}, err
	}
	record := localMigrationRecord{Schema: localMigrationSchema, StartedAt: time.Now().UTC().Format(time.RFC3339Nano)}
	journal := filepath.Join(currentRoot, "migration", "legacy-pna-v1.json")
	if data, readErr := os.ReadFile(journal); readErr == nil {
		var completed localMigrationRecord
		if json.Unmarshal(data, &completed) == nil && completed.Schema == localMigrationSchema && completed.CompletedAt != "" {
			return completed, nil
		}
	}
	if err := os.MkdirAll(currentRoot, 0700); err != nil {
		return record, err
	}
	if err := copyLegacyConfigTree(legacyRoot, currentRoot, &record.Copied, &record.Warnings); err != nil {
		return record, err
	}
	newKeys, legacyKeys, newRevoked, legacyRevoked, err := managedKeyRootsForMigration()
	if err != nil {
		return record, err
	}
	if err := copyLegacyTree(legacyKeys, newKeys, &record.Copied); err != nil {
		return record, err
	}
	if err := copyLegacyTree(legacyRevoked, newRevoked, &record.Copied); err != nil {
		return record, err
	}
	record.CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if err := writeJSONAtomic(journal, record, 0600); err != nil {
		return record, err
	}
	return record, nil
}
