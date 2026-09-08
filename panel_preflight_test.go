package main

import (
	"strings"
	"testing"
)

func TestPanelPreflightCommandBatchesReadOnlySSHSteps(t *testing.T) {
	command := panelPreflightCommand()
	for _, token := range []string{
		"__PNA_TOOLKIT_PROBE_BEGIN__",
		"18-panel-metadata.sh",
		"__PNA_HANDOFF_BEGIN__",
	} {
		if !strings.Contains(command, token) {
			t.Fatalf("batched panel preflight lost %q", token)
		}
	}
	if strings.Count(command, "printf '%s\\n' "+shQuote(toolkitBegin)) != 1 {
		t.Fatal("toolkit probe should be emitted once")
	}
	if strings.Count(command, "bash "+shQuote(remoteRoot)+"/linux/18-panel-metadata.sh") != 0 {
		t.Fatal("panel metadata must use the compatibility-aware command")
	}
	if strings.Count(command, `bash "$root/linux/18-panel-metadata.sh"`) != 1 {
		t.Fatal("panel metadata command should be included exactly once")
	}
}
