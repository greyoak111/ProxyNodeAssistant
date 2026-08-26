package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const localMigrationSchema = 1

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

func managedKeyRootsForMigration() (newRoot, legacyRoot, newRevoked, legacyRevoked string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", "", err
	}
	return filepath.Join(home, ".ssh", "text-node-assistant"),
		filepath.Join(home, ".ssh", "proxy-runbook"),
		filepath.Join(home, ".ssh", "text-node-assistant-revoked"),
		filepath.Join(home, ".ssh", "proxy-runbook-revoked"), nil
}

func migrateKnownCredential(legacyTarget, currentTarget string) error {
	if os.Getenv("TNA_DISABLE_CREDENTIAL_MIGRATION") == "1" {
		return nil
	}
	if current, err := credentialRead(currentTarget); err == nil && current != "" {
		return nil
	}
	legacy, err := credentialRead(legacyTarget)
	if err != nil || legacy == "" {
		return nil
	}
	return credentialWrite(currentTarget, productName+" migration", legacy)
}

// migrateLegacyLocalAdminState repairs the one state path that can be used
// directly by the graphical outer shell. Local-admin commands intentionally
// exit before the normal interactive App session starts, so they must still
// copy a legacy verifier and its Windows Credential Manager entry explicitly.
// Copy-first semantics keep the current TextNodeAssistant state authoritative
// and never overwrite an existing verifier or credential.
func migrateLegacyLocalAdminState() error {
	currentRoot, err := productConfigRoot()
	if err != nil {
		return err
	}
	legacyRoot, err := legacyConfigRoot()
	if err != nil {
		return err
	}
	currentVerifier := filepath.Join(currentRoot, "local-admin-verifier.json")
	legacyVerifier := filepath.Join(legacyRoot, "local-admin-verifier.json")
	if _, statErr := os.Stat(currentVerifier); errors.Is(statErr, os.ErrNotExist) {
		if _, legacyErr := os.Stat(legacyVerifier); legacyErr == nil {
			if _, copyErr := copyLegacyFile(legacyVerifier, currentVerifier); copyErr != nil {
				return copyErr
			}
		} else if !errors.Is(legacyErr, os.ErrNotExist) {
			return legacyErr
		}
	} else if statErr != nil {
		return statErr
	}

	data, readErr := os.ReadFile(currentVerifier)
	if errors.Is(readErr, os.ErrNotExist) {
		return nil
	}
	if readErr != nil {
		return readErr
	}
	var verifier localAdminVerifier
	if json.Unmarshal(data, &verifier) != nil || validateLocalAdminVerifier(verifier) != nil {
		// Let the normal status command report corruption; migration must not
		// manufacture a replacement verifier or silently rotate the password.
		return nil
	}
	legacyTarget := "ProxyNodeAssistant/v0.9.5/local-admin/" + verifier.DeviceID
	if err := migrateKnownCredential(legacyTarget, localAdminCredentialTarget(verifier.DeviceID)); err != nil && !errors.Is(err, errCredentialManagerUnsupported) {
		return err
	}
	return nil
}

// migrateLegacyLocalState is copy-first and deliberately leaves legacy data in
// place. New code writes only TNA paths; deletion of the recoverable legacy
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
	if err := migrateLegacyLocalAdminState(); err != nil {
		record.Warnings = append(record.Warnings, "local-admin migration: "+err.Error())
	}
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
	if err := copyLegacyTree(legacyRoot, currentRoot, &record.Copied); err != nil {
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
	if err := migrateKnownCredential("ProxyNodeAssistant/device-identity/v1", "TextNodeAssistant/device-identity/v2"); err != nil && !errors.Is(err, errCredentialManagerUnsupported) {
		record.Warnings = append(record.Warnings, "device credential migration: "+err.Error())
	}
	record.CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if err := writeJSONAtomic(journal, record, 0600); err != nil {
		return record, err
	}
	return record, nil
}

func currentCredentialTarget(legacy string) string {
	value := strings.TrimSpace(legacy)
	if strings.HasPrefix(value, "ProxyNodeAssistant/") {
		return "TextNodeAssistant/" + strings.TrimPrefix(value, "ProxyNodeAssistant/")
	}
	return value
}
