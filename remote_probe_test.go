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

func TestCredentialReadinessAndHandoffCommandsKeepProtectedStoresInScope(t *testing.T) {
	readiness := remoteCredentialReadinessCommand()
	for _, required := range []string{
		"__PNA_CREDENTIAL_READINESS_BEGIN__",
		"__PNA_CREDENTIAL_READINESS_END__",
		"/root/.config/proxy-runbook",
		"/root/.config/text-node-assistant",
		"/root/.config/proxy-node-assistant",
		"CURRENT-LOGIN-CREDENTIALS.env",
		"FORM_VPS_ACCOUNT",
		"FORM_VPS_PASSWORD",
		"FORM_PANEL_ACCOUNT",
		"FORM_PANEL_PASSWORD",
	} {
		if !strings.Contains(readiness, required) {
			t.Fatalf("credential readiness probe lost %q", required)
		}
	}
	// The preflight may report only presence bits.  It must never stream a
	// file, variable, or canonical secret field to stdout.
	for _, forbidden := range []string{
		"cat \"$file\"",
		"printf '%s\\n' \"$value\"",
		"VPS_LOGIN_PASSWORD=%s",
		"PANEL_PASSWORD=%s",
	} {
		if strings.Contains(readiness, forbidden) {
			t.Fatalf("credential readiness probe may expose secret material via %q", forbidden)
		}
	}

	handoff := remoteHandoffCommand()
	for _, required := range []string{
		"/root/.config/proxy-runbook/CURRENT-LOGIN-CREDENTIALS.env",
		"/root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env",
		"/root/.config/proxy-node-assistant/CURRENT-LOGIN-CREDENTIALS.env",
	} {
		if !strings.Contains(handoff, required) {
			t.Fatalf("handoff exporter lost protected store %q", required)
		}
	}
}
