//go:build !windows

package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func writeExecutable(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestTrimCredentialOutput(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "newline", input: "secret\n", want: "secret"},
		{name: "windows newline", input: "secret\r\n", want: "secret"},
		{name: "meaningful whitespace", input: " secret \n", want: " secret "},
		{name: "no newline", input: "secret", want: "secret"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := trimCredentialOutput(test.input); got != test.want {
				t.Fatalf("trimCredentialOutput(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestCredentialNotFound(t *testing.T) {
	if !credentialNotFound(errors.New("The specified item could not be found in the keychain")) {
		t.Fatal("expected keychain not-found error to be recognized")
	}
	if credentialNotFound(errors.New("permission denied")) {
		t.Fatal("permission errors must not be treated as not-found")
	}
}

func TestUnixCredentialSecretToolRoundTrip(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("secret-tool backend test is Linux-specific")
	}
	dir := t.TempDir()
	logPath := filepath.Join(dir, "invocations")
	secretPath := filepath.Join(dir, "stdin-secret")
	writeExecutable(t, filepath.Join(dir, "secret-tool"), `
printf '%s\n' "$*" >> "$PNA_TEST_LOG"
case "$1" in
  store) cat > "$PNA_TEST_SECRET"; exit 0 ;;
  lookup) printf 'round-trip-secret\n'; exit 0 ;;
  clear) exit 0 ;;
  *) exit 2 ;;
esac`)
	t.Setenv("PNA_TEST_LOG", logPath)
	t.Setenv("PNA_TEST_SECRET", secretPath)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	if err := credentialWrite("profile-target", "profile-user", "round-trip-secret"); err != nil {
		t.Fatalf("credentialWrite failed: %v", err)
	}
	stored, err := os.ReadFile(secretPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(stored) != "round-trip-secret\n" {
		t.Fatalf("secret-tool stdin = %q, want secret plus one newline", stored)
	}
	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(logBytes), "round-trip-secret") {
		t.Fatalf("secret leaked into secret-tool argv: %q", logBytes)
	}

	got, err := credentialRead("profile-target")
	if err != nil {
		t.Fatalf("credentialRead failed: %v", err)
	}
	if got != "round-trip-secret" {
		t.Fatalf("credentialRead = %q, want round-trip-secret", got)
	}
	if err := credentialDelete("profile-target"); err != nil {
		t.Fatalf("credentialDelete failed: %v", err)
	}
	logBytes, err = os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	logText := string(logBytes)
	if !strings.Contains(logText, "store") || !strings.Contains(logText, "lookup") || !strings.Contains(logText, "clear") {
		t.Fatalf("store/lookup/clear invocation missing: %q", logText)
	}
	if strings.Count(logText, "proxy-node-assistant-target profile-target") != 3 {
		t.Fatalf("secret-tool target attribute was not consistent across operations: %q", logText)
	}
	if strings.Contains(logText, "proxy-node-assistant-user") || strings.Contains(logText, "round-trip-secret") {
		t.Fatalf("secret-tool invocation leaked unsupported/user or secret data: %q", logText)
	}
}

func TestUnixCredentialBackendMissingIsExplicit(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("backend availability test is Linux-specific")
	}
	t.Setenv("PATH", t.TempDir())
	_, err := credentialRead("profile-target")
	if err == nil {
		t.Fatal("credentialRead unexpectedly succeeded without secret-tool")
	}
	if !errors.Is(err, errCredentialManagerUnsupported) {
		t.Fatalf("error = %v, want errCredentialManagerUnsupported", err)
	}
	message := strings.ToLower(err.Error())
	if !strings.Contains(message, "secret-tool") || !strings.Contains(message, "install") {
		t.Fatalf("error lacks actionable secret-tool guidance: %v", err)
	}
}
