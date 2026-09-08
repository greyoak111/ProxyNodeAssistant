package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fakeSSHForIdentityTests records each argv and returns the marker expected by
// verifyKey.  It never opens a socket or contacts a host, so these tests cover
// the password-to-key command boundary without touching a real VPS.
func fakeSSHForIdentityTests(t *testing.T, dir string) string {
	t.Helper()
	script := filepath.Join(dir, "ssh-fixture")
	body := `#!/bin/sh
count_file="$PNA_IDENTITY_TEST_COUNT"
args_file="$PNA_IDENTITY_TEST_ARGS"
count=0
if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf 'BEGIN %s\n' "$count" >> "$args_file"
for arg in "$@"; do printf '%s\n' "$arg" >> "$args_file"; done
printf 'END\n' >> "$args_file"
if [ "$count" -ge 2 ]; then printf 'SSH_KEY_OK\n'; fi
exit 0
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	return script
}

func withIdentityTestSSH(t *testing.T, script string) {
	t.Helper()
	previous := openSSHExecutablePaths
	openSSHExecutablePaths = map[string]string{"ssh.exe": script, "ssh": script}
	t.Cleanup(func() { openSSHExecutablePaths = previous })
}

func TestPasswordInstallDisablesControlMasterBeforeKeyVerification(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix ControlMaster lifecycle")
	}
	dir := t.TempDir()
	argsLog := filepath.Join(dir, "args.log")
	countFile := filepath.Join(dir, "count")
	t.Setenv("PNA_IDENTITY_TEST_ARGS", argsLog)
	t.Setenv("PNA_IDENTITY_TEST_COUNT", countFile)
	script := fakeSSHForIdentityTests(t, dir)
	withIdentityTestSSH(t, script)

	keyPath := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(keyPath+".pub", []byte("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE fixture\n"), 0600); err != nil {
		t.Fatal(err)
	}
	controlPath := filepath.Join(dir, "control", "c")
	c := Connection{
		Host:        "fixture",
		User:        "root",
		Port:        22,
		KeyPath:     keyPath,
		ControlPath: controlPath,
		AuthMode:    AuthTemporaryPassword,
	}
	if err := (&App{}).installPublicKey(c, keyPath, "", nil); err != nil {
		t.Fatalf("installPublicKey: %v", err)
	}
	data, err := os.ReadFile(argsLog)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	first := strings.Index(text, "BEGIN 1\n")
	second := strings.Index(text, "BEGIN 2\n")
	if first < 0 || second < 0 || second <= first {
		t.Fatalf("expected password install and key verification invocations, got:\n%s", text)
	}
	passwordArgs := text[first:second]
	if !strings.Contains(passwordArgs, "-o\nControlMaster=no\n") || !strings.Contains(passwordArgs, "-o\nControlPath=none\n") {
		t.Fatalf("password install did not disable ControlMaster:\n%s", passwordArgs)
	}
	if strings.Contains(passwordArgs, "ControlMaster=auto") || strings.Contains(passwordArgs, "ControlPath="+controlPath) {
		t.Fatalf("password install still carried the action ControlMaster settings:\n%s", passwordArgs)
	}
	verificationArgs := text[second:]
	if !strings.Contains(verificationArgs, "-o\nControlMaster=auto\n") || !strings.Contains(verificationArgs, "-o\nControlPath="+controlPath+"\n") {
		t.Fatalf("key verification did not create a fresh reusable master:\n%s", verificationArgs)
	}
	if _, err := os.Stat(controlPath); !os.IsNotExist(err) {
		t.Fatalf("fake SSH unexpectedly created a control socket: %v", err)
	}
}

func TestVerifyKeyRecreatesControlSocketDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix ControlMaster lifecycle")
	}
	dir := t.TempDir()
	argsLog := filepath.Join(dir, "args.log")
	countFile := filepath.Join(dir, "count")
	t.Setenv("PNA_IDENTITY_TEST_ARGS", argsLog)
	t.Setenv("PNA_IDENTITY_TEST_COUNT", countFile)
	script := fakeSSHForIdentityTests(t, dir)
	withIdentityTestSSH(t, script)
	// The fixture emits SSH_KEY_OK on its second invocation; seed the counter
	// so this direct verifyKey call exercises the successful path.
	if err := os.WriteFile(countFile, []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}

	controlDir := filepath.Join(dir, "fresh-control")
	controlPath := filepath.Join(controlDir, "c")
	c := Connection{Host: "fixture", User: "root", Port: 22, ControlPath: controlPath, AuthMode: AuthManagedKey}
	result := verifyKey(c, filepath.Join(dir, "managed-key"))
	if !result.OK() || strings.TrimSpace(result.Stdout) != "SSH_KEY_OK" {
		t.Fatalf("verifyKey failed: %+v", result)
	}
	if info, err := os.Stat(controlDir); err != nil || !info.IsDir() {
		t.Fatalf("verifyKey did not recreate control directory: %v", err)
	}
}
