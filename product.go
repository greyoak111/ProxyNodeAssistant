package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// ProxyNodeAssistant is the public product name for the reset line.  The
// previous v0.9.x build used TextNodeAssistant in a number of on-disk and
// credential-store paths; that name is retained only as a migration fallback.
const (
	productName         = "ProxyNodeAssistant"
	productAbbreviation = "PNA"
	legacyProductName   = "TextNodeAssistant"

	stateSchemaVersion = "1"
	driveSchemaVersion = "1" // retained for parsing old receipts only
	desktopBuildID     = "pna-v100"
	androidBuildID     = "pna-android-v100"
)

// The platform-specific credential backends use this sentinel. Keeping it
// here makes ordinary SSH credential migration/reporting behave uniformly on
// Windows, macOS, and Linux when no native store is available.
var errCredentialManagerUnsupported = errors.New("no supported credential manager is available")

func productConfigRoot() (string, error) {
	if override := strings.TrimSpace(os.Getenv("PNA_CONFIG_ROOT")); override != "" {
		return filepath.Clean(override), nil
	}
	if override := strings.TrimSpace(os.Getenv("TNA_CONFIG_ROOT")); override != "" {
		return filepath.Clean(override), nil
	}
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, productName), nil
}

func legacyConfigRoot() (string, error) {
	if override := strings.TrimSpace(os.Getenv("PNA_LEGACY_CONFIG_ROOT")); override != "" {
		return filepath.Clean(override), nil
	}
	if override := strings.TrimSpace(os.Getenv("TNA_LEGACY_CONFIG_ROOT")); override != "" {
		return filepath.Clean(override), nil
	}
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, legacyProductName), nil
}

func guiModeEnabled() bool {
	return os.Getenv("PNA_GUI_MODE") == "1" || os.Getenv("TNA_GUI_MODE") == "1"
}

func firstEnvironment(names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return ""
}
