//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestClipboardFallsBackAfterPreferredCommandFails(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "clipboard-payload")
	preferred := "wl-copy"
	if runtime.GOOS == "darwin" {
		preferred = "pbcopy"
	}
	writeExecutable(t, filepath.Join(dir, preferred), "exit 17")
	writeExecutable(t, filepath.Join(dir, "xclip"), `cat > "$PNA_TEST_CLIPBOARD_MARKER"`)
	t.Setenv("PNA_TEST_CLIPBOARD_MARKER", marker)
	t.Setenv("PNA_TEST_CLIPBOARD_CANDIDATES", preferred+",xclip")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	const payload = "fallback-payload"
	if err := runClipboardCommand([]byte(payload), false); err != nil {
		t.Fatalf("runClipboardCommand failed after fallback: %v", err)
	}
	got, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != payload {
		t.Fatalf("fallback clipboard payload = %q, want %q", got, payload)
	}
}

func TestClipboardReportsAllBackendFailures(t *testing.T) {
	dir := t.TempDir()
	candidates := clipboardCandidates()
	for _, candidate := range candidates {
		writeExecutable(t, filepath.Join(dir, filepath.Base(candidate)), "printf 'backend failed: %s\\n' \"$0\" >&2; exit 19")
	}
	t.Setenv("PATH", dir)
	// Keep absolute candidates deterministic in the test: the fake executable
	// lives in the temporary PATH directory, while production still retains
	// /usr/bin/pbcopy as its no-PATH fallback.
	var testCandidates []string
	for _, candidate := range candidates {
		testCandidates = append(testCandidates, filepath.Base(candidate))
	}
	t.Setenv("PNA_TEST_CLIPBOARD_CANDIDATES", strings.Join(testCandidates, ","))
	err := runClipboardCommand([]byte("payload-not-in-error"), false)
	if err == nil {
		t.Fatal("runClipboardCommand unexpectedly succeeded")
	}
	message := err.Error()
	for _, candidate := range clipboardCandidates() {
		if !strings.Contains(message, candidate) {
			t.Fatalf("error %q does not mention failed backend %q", message, candidate)
		}
	}
	if strings.Contains(message, "payload-not-in-error") {
		t.Fatalf("clipboard payload leaked into error: %q", message)
	}
}
