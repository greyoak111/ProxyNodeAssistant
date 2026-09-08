package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPanelPreflightUsesOneSSHInvocation(t *testing.T) {
	dir := t.TempDir()
	countPath := filepath.Join(dir, "count")
	script := filepath.Join(dir, "ssh-fixture")
	fixture := "#!/bin/sh\n" +
		"n=0; [ -r '" + countPath + "' ] && n=$(cat '" + countPath + "'); n=$((n+1)); printf '%s' \"$n\" > '" + countPath + "'\n" +
		"cat <<'EOF'\n" +
		"__PNA_TOOLKIT_PROBE_BEGIN__\n" +
		"TOOLKIT_PRESENT=1\nTOOLKIT_VERSION=1.0.0\nTOOLKIT_BUILD_ID=20260901-v100-ss2022-r112\nTOOLKIT_BUILD_REVISION=112\nTOOLKIT_COMPLETE=1\n" +
		"__PNA_TOOLKIT_PROBE_END__\n" +
		"__PNA_PANEL_META_BEGIN__\nPANEL_PORT=2053\nWEB_BASE_PATH=/panel/\nPANEL_METADATA_SOURCE=fixture\n__PNA_PANEL_META_END__\n" +
		"__PNA_HANDOFF_BEGIN__\nHANDOFF_RUN_STARTED=fixture\nPANEL_PORT=2053\n__PNA_HANDOFF_END__\n" +
		"EOF\n"
	if err := os.WriteFile(script, []byte(fixture), 0700); err != nil {
		t.Fatal(err)
	}
	old := openSSHExecutablePaths
	openSSHExecutablePaths = map[string]string{"ssh.exe": script}
	t.Cleanup(func() { openSSHExecutablePaths = old })

	app := &App{lang: LangZH}
	_, meta, handoff, err := app.panelPreflight(Connection{Host: "fixture", User: "root", Port: 22, KeyPath: filepath.Join(dir, "id_ed25519")})
	if err != nil {
		t.Fatal(err)
	}
	if meta.Port != 2053 || meta.Path != "/panel/" || handoff == "" {
		t.Fatalf("unexpected preflight result: meta=%+v handoff=%q", meta, handoff)
	}
	count, err := os.ReadFile(countPath)
	if err != nil || strings.TrimSpace(string(count)) != "1" {
		t.Fatalf("panel preflight opened %q SSH sessions, want one", strings.TrimSpace(string(count)))
	}
}
