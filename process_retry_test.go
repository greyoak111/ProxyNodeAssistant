package main

import (
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestHasControlSocketArgsRecognizesOpenSSHForms(t *testing.T) {
	cases := []struct {
		args []string
		want bool
	}{
		{[]string{"-o", "ControlPath=/tmp/pna/c"}, true},
		{[]string{"-oControlPath=/tmp/pna/c"}, true},
		{[]string{"-S", "/tmp/pna/c"}, true},
		{[]string{"-o", "ControlMaster=auto"}, false},
		{[]string{"echo", "ControlPath=/not-an-option"}, false},
	}
	for _, test := range cases {
		if got := hasControlSocketArgs(test.args); got != test.want {
			t.Fatalf("hasControlSocketArgs(%q) = %v, want %v", test.args, got, test.want)
		}
	}
}

func TestRunCapturedRetriesStaleControlSocketFailure(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "ssh-fixture")
	count := filepath.Join(dir, "count")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"+
		"n=0; [ -f \"$PNA_RETRY_COUNT\" ] && n=$(cat \"$PNA_RETRY_COUNT\")\n"+
		"n=$((n+1)); printf '%s' \"$n\" > \"$PNA_RETRY_COUNT\"\n"+
		"echo 'Connection timed out during banner exchange' >&2\nexit 255\n"), 0700); err != nil {
		t.Fatal(err)
	}
	previous := openSSHExecutablePaths
	openSSHExecutablePaths = map[string]string{"ssh.exe": script, "ssh": script}
	t.Cleanup(func() { openSSHExecutablePaths = previous })
	t.Setenv("PNA_RETRY_COUNT", count)
	// Model a dead control socket left by the first action attempt.  The path is
	// in the same private shape produced by newSSHControlPath, so the retry
	// helper is allowed to remove it and let OpenSSH recreate one connection.
	control := filepath.Join(dir, "pna-ssh-stale", "c")
	if err := os.MkdirAll(filepath.Dir(control), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(control, []byte("socket-placeholder"), 0600); err != nil {
		t.Fatal(err)
	}
	result := runCaptured("ssh.exe", []string{"-o", "ControlPath=" + control}, nil, true)
	if result.ExitCode != 255 || !strings.Contains(result.Stderr, "banner exchange") {
		t.Fatalf("unexpected result: %+v", result)
	}
	data, err := os.ReadFile(count)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(data)); got != "2" {
		t.Fatalf("stale control-socket failure was retried %s times", got)
	}
}

func TestRunCapturedRetriesOnlyInitialControlTransportFailure(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "ssh-fixture")
	count := filepath.Join(dir, "count")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"+
		"n=0; [ -f \"$PNA_RETRY_COUNT\" ] && n=$(cat \"$PNA_RETRY_COUNT\")\n"+
		"n=$((n+1)); printf '%s' \"$n\" > \"$PNA_RETRY_COUNT\"\n"+
		"if [ \"$n\" -eq 1 ]; then echo 'Connection timed out during banner exchange' >&2; exit 255; fi\n"+
		"printf 'CONTROL_RETRY_OK\\n'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	previous := openSSHExecutablePaths
	openSSHExecutablePaths = map[string]string{"ssh.exe": script, "ssh": script}
	t.Cleanup(func() { openSSHExecutablePaths = previous })
	t.Setenv("PNA_RETRY_COUNT", count)
	control := filepath.Join(dir, "missing", "c")
	result := runCaptured("ssh.exe", []string{"-o", "ControlMaster=auto", "-o", "ControlPath=" + control}, nil, true)
	if !result.OK() || strings.TrimSpace(result.Stdout) != "CONTROL_RETRY_OK" {
		t.Fatalf("initial control transport retry did not recover: %+v", result)
	}
	data, err := os.ReadFile(count)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(data)); got != "2" {
		t.Fatalf("expected exactly one delayed retry, got %s attempts", got)
	}
}

func TestInitialControlSocketRetryRejectsControlRequestsAndDisabledMaster(t *testing.T) {
	dir := t.TempDir()
	if initialControlSocketRetryAllowed([]string{"-S", filepath.Join(dir, "missing"), "-O", "check"}) {
		t.Fatal("-O control requests must never be retried")
	}
	if initialControlSocketRetryAllowed([]string{"-o", "ControlPath=" + filepath.Join(dir, "missing"), "-o", "ControlMaster=no"}) {
		t.Fatal("disabled ControlMaster must never be retried")
	}
}

func TestPrepareControlSocketRetryRemovesOnlyStaleManagedSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix control sockets")
	}
	dir := t.TempDir()
	control := filepath.Join(dir, "pna-ssh-stale", "c")
	if err := os.MkdirAll(filepath.Dir(control), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(control, []byte("stale"), 0600); err != nil {
		t.Fatal(err)
	}
	prepareControlSocketRetry([]string{"-o", "ControlPath=" + control})
	if _, err := os.Stat(control); !os.IsNotExist(err) {
		t.Fatalf("stale managed control path was not removed: %v", err)
	}
	outside := filepath.Join(dir, "unmanaged", "c")
	if err := os.MkdirAll(filepath.Dir(outside), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outside, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	prepareControlSocketRetry([]string{"-o", "ControlPath=" + outside})
	if _, err := os.Stat(outside); err != nil {
		t.Fatalf("unmanaged control path changed: %v", err)
	}
}

func TestControlSocketAliveDetectsLocalMaster(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix control sockets")
	}
	dir, err := os.MkdirTemp("/tmp", "pna-ssh-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	control := filepath.Join(dir, "c")
	listener, err := net.Listen("unix", control)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if !controlSocketAlive(control) {
		t.Fatal("live Unix control socket was reported dead")
	}
	listener.Close()
	if controlSocketAlive(control) {
		t.Fatal("closed Unix control socket was reported live")
	}
}
