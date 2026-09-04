//go:build !windows

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Unix desktops do not share a single clipboard utility. Prefer the native
// macOS utility, then the two common Linux Wayland/X11 utilities. The command
// is deliberately selected with LookPath and receives the payload on stdin;
// no shell interpolation is involved.
func clipboardCandidates() []string {
	// Tests can supply a deterministic backend list without ever touching the
	// real pasteboard.  This is intentionally opt-in and is not used by the
	// application in normal operation.
	if override := strings.TrimSpace(os.Getenv("PNA_TEST_CLIPBOARD_CANDIDATES")); override != "" {
		var overridden []string
		for _, candidate := range strings.Split(override, ",") {
			candidate = strings.TrimSpace(candidate)
			if candidate != "" {
				overridden = append(overridden, candidate)
			}
		}
		if len(overridden) > 0 {
			return overridden
		}
	}
	candidates := []string{"wl-copy", "xclip", "xsel"}
	if runtime.GOOS == "darwin" {
		// Finder-launched apps do not always inherit a shell PATH.  Keep the
		// command name first for normal shells and tests, then fall back to the
		// canonical system path when PATH is empty or trimmed.
		candidates = []string{"pbcopy", "/usr/bin/pbcopy", "wl-copy", "xclip", "xsel"}
	}
	seen := make(map[string]struct{}, len(candidates))
	result := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		result = append(result, candidate)
	}
	return result
}

func clipboardCommand() (string, error) {
	for _, candidate := range clipboardCandidates() {
		if path, err := exec.LookPath(candidate); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("no clipboard utility found (install pbcopy, wl-copy, xclip, or xsel)")
}

func clipboardCommandArgs(path string) []string {
	args := []string{}
	switch filepath.Base(path) {
	case "xclip":
		args = []string{"-selection", "clipboard"}
	case "xsel":
		args = []string{"--clipboard", "--input"}
	}
	return args
}

func clipboardFailureText(output []byte, value []byte) string {
	detail := clipFailureText(string(output))
	// A broken helper should not be able to echo the clipboard payload into a
	// user-visible error. Redact an exact payload match while retaining useful
	// diagnostics from stderr.
	if len(value) > 0 && detail != "" {
		detail = strings.ReplaceAll(detail, string(value), "[clipboard payload redacted]")
	}
	return detail
}

// runClipboardCommand retries each available backend in preference order. A
// utility can be present in PATH yet unusable (for example wl-copy without a
// Wayland session), so selecting only the first LookPath result is not enough.
func runClipboardCommand(value []byte, clear bool) error {
	if clear {
		value = nil
	}
	var failures []string
	for _, candidate := range clipboardCandidates() {
		path, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		cmd := exec.Command(path, clipboardCommandArgs(path)...)
		cmd.Stdin = bytes.NewReader(value)
		hideChildWindow(cmd)
		output, err := cmd.CombinedOutput()
		if err == nil {
			return nil
		}
		detail := clipboardFailureText(output, value)
		if detail == "" {
			failures = append(failures, fmt.Sprintf("%s: %v", candidate, err))
		} else {
			failures = append(failures, fmt.Sprintf("%s: %v: %s", candidate, err, detail))
		}
	}
	if len(failures) == 0 {
		return fmt.Errorf("no clipboard utility found (install pbcopy, wl-copy, xclip, or xsel)")
	}
	return fmt.Errorf("all clipboard utilities failed: %s", strings.Join(failures, "; "))
}

// verifyClipboardReadback waits briefly for the pasteboard server to publish
// the new value, then compares bytes in memory.  It deliberately reports only
// lengths on failure; neither the expected handoff nor pbpaste output can
// reach a log or an error string.
func verifyClipboardReadback(expected []byte) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	pastePath := "/usr/bin/pbpaste"
	if info, err := os.Stat(pastePath); err != nil || info.Mode()&0111 == 0 {
		var err error
		pastePath, err = exec.LookPath("pbpaste")
		if err != nil {
			return fmt.Errorf("clipboard readback utility unavailable")
		}
	}
	actualLength := 0
	var lastErr error
	for attempt := 0; attempt < 8; attempt++ {
		cmd := exec.Command(pastePath)
		hideChildWindow(cmd)
		actual, err := cmd.Output()
		if err == nil {
			actualLength = len(actual)
			if bytes.Equal(actual, expected) {
				return nil
			}
		} else {
			lastErr = err
		}
		// pbcopy returns before the pasteboard daemon necessarily makes the
		// value visible to a separate pbpaste process.  A short bounded retry
		// handles that handoff without leaving the SSH operation hanging.
		time.Sleep(40 * time.Millisecond)
	}
	if lastErr != nil && actualLength == 0 {
		return fmt.Errorf("clipboard readback failed")
	}
	return fmt.Errorf("clipboard readback mismatch (expected %d bytes, got %d)", len(expected), actualLength)
}

func copyClipboardPlatform(value string) error {
	payload := []byte(value)
	if err := runClipboardCommand(payload, false); err != nil {
		return err
	}
	return verifyClipboardReadback(payload)
}

func clearClipboardPlatform() error { return runClipboardCommand(nil, true) }
