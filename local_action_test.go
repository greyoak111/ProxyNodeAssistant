package main

import (
	"os"
	"strings"
	"testing"
)

func TestLocalGUIActionsSkipOpenSSHPreflight(t *testing.T) {
	for _, choice := range []string{"12", "14", "T", "h", "K"} {
		if actionNeedsOpenSSH(choice) {
			t.Fatalf("local action %q unexpectedly requires OpenSSH", choice)
		}
	}
	for _, choice := range []string{"1", "2", "11", "13", "15", "0", "unknown"} {
		if !actionNeedsOpenSSH(choice) {
			t.Fatalf("remote-capable action %q was classified as local-only", choice)
		}
	}
}

func TestDirectActionUsesLocalSessionForLocalEntries(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	start := strings.Index(text, "func (a *App) runDirectAction")
	if start < 0 {
		t.Fatal("runDirectAction is missing")
	}
	end := strings.Index(text[start:], "\nfunc (a *App) run()")
	if end < 0 {
		t.Fatal("runDirectAction boundary is missing")
	}
	text = text[start : start+end]
	if !strings.Contains(text, "actionNeedsOpenSSH(choice)") ||
		!strings.Contains(text, "a.prepareLocalConsoleSession()") {
		t.Fatal("direct GUI action dispatch does not split local and SSH sessions")
	}
}
