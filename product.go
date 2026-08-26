package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

var errCredentialManagerUnsupported = errors.New("Windows Credential Manager is unavailable on this platform")

const (
	productName         = "TextNodeAssistant"
	productAbbreviation = "TNA"
	version             = "0.9.5"

	stateSchemaVersion           = "1"
	driveSchemaVersion           = "1"
	deviceAdmissionSchemaVersion = "2"
	desktopBuildID               = "tna-v095-dev"
	androidBuildID               = "tna-android-v095-dev"

	legacyProductName = "ProxyNodeAssistant"
)

const (
	guiPromptPrefix       = "TNA_GUI_PROMPT_B64="
	guiSecretPromptPrefix = "TNA_GUI_SECRET_B64="

	legacyGUIPromptPrefix       = "PNA_GUI_PROMPT_B64="
	legacyGUISecretPromptPrefix = "PNA_GUI_SECRET_B64="
)

func productConfigRoot() (string, error) {
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
	return os.Getenv("TNA_GUI_MODE") == "1" || os.Getenv("PNA_GUI_MODE") == "1"
}

func firstEnvironment(names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return ""
}
