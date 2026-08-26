package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type localUISecuritySettings struct {
	AdvancedGateEnabled   bool `json:"advancedGateEnabled"`
	SessionTimeoutMinutes int  `json:"sessionTimeoutMinutes"`
}

func defaultLocalUISecuritySettings() localUISecuritySettings {
	return localUISecuritySettings{AdvancedGateEnabled: true, SessionTimeoutMinutes: 15}
}

func localUISecuritySettingsPath() (string, error) {
	root := strings.TrimSpace(os.Getenv("APPDATA"))
	if root == "" {
		return "", errors.New("APPDATA is unavailable")
	}
	return filepath.Join(root, "TextNodeAssistant", "ui-security.json"), nil
}

func loadLocalUISecuritySettings() localUISecuritySettings {
	settings := defaultLocalUISecuritySettings()
	path, err := localUISecuritySettingsPath()
	if err != nil {
		return settings
	}
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &settings) != nil || settings.SessionTimeoutMinutes < 1 || settings.SessionTimeoutMinutes > 120 {
		return defaultLocalUISecuritySettings()
	}
	return settings
}

func saveLocalUISecuritySettings(settings localUISecuritySettings) error {
	if settings.SessionTimeoutMinutes < 1 || settings.SessionTimeoutMinutes > 120 {
		return errors.New("advanced-console timeout must be 1-120 minutes")
	}
	path, err := localUISecuritySettingsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(settings, "", "  ")
	temporary := path + ".new"
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func (a *App) manageLocalAdminGate() error {
	settings := loadLocalUISecuritySettings()
	a.println(a.msg("高级控制台本机 admin 门禁：", "Advanced-console local-admin gate:") + " " + map[bool]string{true: "ON", false: "OFF"}[settings.AdvancedGateEnabled])
	a.println(a.msg("解锁会话超时（分钟）：", "Unlock session timeout (minutes):") + " " + strconv.Itoa(settings.SessionTimeoutMinutes))
	a.println(a.msg("[1] 开启门禁（推荐）", "[1] Enable the gate (recommended)"))
	a.println(a.msg("[2] 关闭门禁（本机任何用户可打开高级控制台）", "[2] Disable the gate (any local user can open advanced operations)"))
	a.println(a.msg("[3] 修改解锁会话超时（1—120 分钟）", "[3] Change unlock-session timeout (1-120 minutes)"))
	choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
	switch choice {
	case "1":
		settings.AdvancedGateEnabled = true
	case "2":
		if !a.yes(a.msg("关闭门禁会降低本机保护。确认关闭？", "Disabling the gate weakens local protection. Confirm?"), false) {
			return nil
		}
		settings.AdvancedGateEnabled = false
	case "3":
		value, err := strconv.Atoi(strings.TrimSpace(a.prompt(a.msg("超时分钟数 [15]", "Timeout minutes [15]"))))
		if err != nil || value < 1 || value > 120 {
			return errors.New(a.msg("超时必须为 1—120 分钟。", "Timeout must be 1-120 minutes."))
		}
		settings.SessionTimeoutMinutes = value
	default:
		return nil
	}
	if err := saveLocalUISecuritySettings(settings); err != nil {
		return err
	}
	a.println(a.msg("本机门禁设置已原子保存；下次进入高级控制台时生效。", "Local gate settings were saved atomically and apply on the next advanced-console entry."))
	return nil
}
