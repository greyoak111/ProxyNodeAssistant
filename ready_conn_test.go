package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadyConnAuthenticatesWithoutStandaloneTCPProbe(t *testing.T) {
	source, err := os.ReadFile("remote.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	start := strings.Index(text, "func (a *App) readyConn() (Connection, error) {")
	if start < 0 {
		t.Fatal("readyConn function is missing")
	}
	endMarker := "\n}\n\n// remoteToolkitProbeCommand"
	end := strings.Index(text[start:], endMarker)
	if end < 0 {
		t.Fatal("readyConn function boundary is missing")
	}
	block := text[start : start+end+2]

	if strings.Contains(block, "tcpReachable(") {
		t.Fatal("readyConn must not perform a standalone tcpReachable probe")
	}
	if !strings.Contains(block, "a.ensureOpenSSH()") {
		t.Fatal("readyConn must retain OpenSSH availability verification")
	}
	authIndex := strings.Index(block, "a.authenticateActionConnection(c)")
	if authIndex < 0 {
		t.Fatal("readyConn must authenticate the selected connection")
	}
	getIndex := strings.Index(block, "a.getActionConnection()")
	if getIndex < 0 {
		t.Fatal("readyConn must retain action-connection selection")
	}
	if getIndex > authIndex {
		t.Fatal("readyConn must select the action connection before authenticating it")
	}
}

func TestNewSSHControlPathUsesShortUnixSocketName(t *testing.T) {
	path := newSSHControlPath()
	if path == "" {
		t.Skip("ControlPath is intentionally disabled on Windows or unavailable on this host")
	}
	defer os.RemoveAll(filepath.Dir(path))
	if len(path) >= 100 {
		t.Fatalf("ControlPath is too long for sockaddr_un: %d bytes (%q)", len(path), path)
	}
	if filepath.Base(path) != "c" {
		t.Fatalf("ControlPath should use a short socket basename, got %q", filepath.Base(path))
	}
}

func TestManagedKeyVerificationErrorClassificationDoesNotArchiveOnTransportFailure(t *testing.T) {
	transport := []string{
		"ssh: connect to host example port 22: Operation timed out",
		"Connection timed out during banner exchange",
		"Host key verification failed",
		"Connection closed by remote host",
	}
	for _, detail := range transport {
		if isRecoverableManagedKeyDetail(detail) {
			t.Fatalf("transport diagnostic was classified as recoverable key rejection: %q", detail)
		}
	}
	for _, detail := range []string{
		"Permission denied (publickey,password)",
		"Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password).\r\n",
		"Load key /tmp/id_ed25519: invalid format",
		"Warning: Identity file /tmp/id_ed25519 not accessible: No such file or directory.",
	} {
		if !isRecoverableManagedKeyDetail(detail) {
			t.Fatalf("authentication/key diagnostic was not classified as recoverable: %q", detail)
		}
	}
}

func TestManagedKeyVerificationClassificationIgnoresRemoteCommandOutput(t *testing.T) {
	// The verification command's remote stderr is delivered through the same
	// captured stream as OpenSSH's own diagnostics.  These are valid command
	// outputs after authentication and must never move the managed key aside.
	for _, detail := range []string{
		"Permission denied",
		"stderr:\nPermission denied\nstdout:\n",
		"No such file or directory",
		"invalid format",
		"identity_file /tmp/id_ed25519 type 3",
		"Permission denied (remote command)",
	} {
		if isRecoverableManagedKeyDetail(detail) {
			t.Fatalf("remote command diagnostic was classified as recoverable key failure: %q", detail)
		}
	}
}
