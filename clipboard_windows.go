//go:build windows

package main

import (
	"fmt"
	"strings"
)

func copyClipboardPlatform(value string) error {
	command := `[Console]::InputEncoding = [Text.UTF8Encoding]::new($false); [Console]::In.ReadToEnd() | Set-Clipboard`
	result := runCaptured("powershell.exe", []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command}, []byte(value), true)
	if !result.OK() {
		return fmt.Errorf("clipboard command failed (exit %d): %s", result.ExitCode, strings.TrimSpace(result.Stderr))
	}
	return nil
}

func clearClipboardPlatform() error {
	result := runCaptured("powershell.exe", []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value $null"}, nil, true)
	if !result.OK() {
		return fmt.Errorf("clipboard clear failed (exit %d): %s", result.ExitCode, strings.TrimSpace(result.Stderr))
	}
	return nil
}
