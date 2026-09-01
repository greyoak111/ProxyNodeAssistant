package main

import (
	"strings"
	"testing"
)

func TestRemoteToolkitProbeChecksCurrentAndLegacyRoots(t *testing.T) {
	command := remoteToolkitProbeCommand()
	for _, root := range []string{remoteRoot, legacyTextRemoteRoot, legacyRunbookRemoteRoot} {
		if !strings.Contains(command, root) {
			t.Fatalf("toolkit probe lost compatibility root %q: %s", root, command)
		}
	}
	for _, required := range []string{
		"THIRD_PARTY_LOCK.env",
		"00-migrate-legacy-state.sh",
		"00-auto-install-or-optimize.sh",
		"00c-retire-v095-device-drive.sh",
		"01-safe-backup.sh",
		"04a-reality-api.sh",
		"04e-export-reality-handoff.sh",
		"04f-xhttp-cdn-api.sh",
		"05h-ensure-cdn-certificate.sh",
		"14-node-doctor.sh",
		"22-dismantle-managed-node.sh",
		"23-node-identity.sh",
		"23-ss2022-tcp.sh",
		"24-security-baseline.sh",
		"25-security-events.sh",
		"27-ip-rebind.sh",
		"28-topology-reconcile.sh",
		"28a-install-transaction.sh",
		"lib-deployment-state.sh",
		"lib-handoff.sh",
		"lib-xui-api.sh",
		"TOOLKIT_BUILD_ID",
		"TOOLKIT_BUILD_REVISION",
		"TOOLKIT_COMPLETE",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("toolkit probe does not verify %q: %s", required, command)
		}
	}
	if strings.Contains(command, "26-device-admission.sh") || strings.Contains(command, "lib-drive.sh") || strings.Contains(command, "29-copyparty-drive.sh") {
		t.Fatal("reset-line toolkit probe must not make retired device/drive features completeness requirements")
	}
}
