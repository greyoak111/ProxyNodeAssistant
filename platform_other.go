//go:build !windows

package main

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

var consoleEchoMu sync.Mutex

// disableConsoleEcho switches the controlling terminal into no-echo mode for
// a secret prompt and returns a restoration function. Unix programs can have
// stdin redirected (for example, when driven by the GUI bridge), so always
// address /dev/tty explicitly instead of assuming os.Stdin is a terminal.
// Failure is deliberately non-fatal to preserve scripted/non-interactive
// flows; callers can still consume their supplied reader when no TTY exists.
func disableConsoleEcho() func() {
	consoleEchoMu.Lock()
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		consoleEchoMu.Unlock()
		return nil
	}
	stty, err := exec.LookPath("stty")
	if err != nil {
		_ = tty.Close()
		consoleEchoMu.Unlock()
		return nil
	}
	setMode := func(mode string) error {
		cmd := exec.Command(stty, mode)
		cmd.Stdin = tty
		cmd.Stdout = tty
		cmd.Stderr = tty
		return cmd.Run()
	}
	if err := setMode("-echo"); err != nil {
		_ = tty.Close()
		consoleEchoMu.Unlock()
		return nil
	}
	var restoreOnce sync.Once
	return func() {
		restoreOnce.Do(func() {
			// Restore echo even when the prompt itself returned an input error.
			_ = setMode("echo")
			_ = tty.Close()
			consoleEchoMu.Unlock()
		})
	}
}

func hideChildWindow(cmd *exec.Cmd) {}
func setUTF8Console()               {}

// nativeCommandName translates the logical Windows OpenSSH names used by the
// shared workflow into the native names shipped by macOS/Linux.
func nativeCommandName(name string) string {
	if strings.HasSuffix(strings.ToLower(name), ".exe") {
		return name[:len(name)-len(".exe")]
	}
	return name
}

func nullDevicePath() string { return "/dev/null" }

func openURL(rawURL string) error {
	launcher := "xdg-open"
	if runtime.GOOS == "darwin" {
		launcher = "open"
	}
	path, err := exec.LookPath(launcher)
	if err != nil {
		return fmt.Errorf("cannot open URL: %s is not installed: %w", launcher, err)
	}
	cmd := exec.Command(path, rawURL)
	hideChildWindow(cmd)
	return cmd.Start()
}

func openDirectory(path string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("directory path is empty")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	// Reuse the URL opener so spaces and non-ASCII path components are encoded
	// correctly instead of being split by a shell.
	uri := &url.URL{Scheme: "file", Path: absolute}
	return openURL(uri.String())
}
