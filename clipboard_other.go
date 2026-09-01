//go:build !windows

package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Unix desktops do not share a single clipboard utility. Prefer the native
// macOS utility, then the two common Linux Wayland/X11 utilities. The command
// is deliberately selected with LookPath and receives the payload on stdin;
// no shell interpolation is involved.
func clipboardCandidates() []string {
	candidates := []string{"wl-copy", "xclip", "xsel"}
	if runtime.GOOS == "darwin" {
		candidates = []string{"pbcopy", "wl-copy", "xclip", "xsel"}
	}
	return candidates
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

func copyClipboardPlatform(value string) error { return runClipboardCommand([]byte(value), false) }

func clearClipboardPlatform() error { return runClipboardCommand(nil, true) }
