package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestDeploymentModeIsFailClosed(t *testing.T) {
	for _, value := range []string{"direct-reality", "cdn-xhttp-tls", "dual-hot-switch"} {
		if _, err := parseDeploymentMode(value); err != nil {
			t.Fatalf("valid deployment mode %q rejected: %v", value, err)
		}
	}
	for _, value := range []string{"", "cdn", "DIRECT", "cdn-xhttp-tls\nACTIVE_DIRECT"} {
		if _, err := parseDeploymentMode(value); err == nil {
			t.Fatalf("invalid deployment mode %q accepted", value)
		}
	}
	if deploymentNeedsCloudflareProxy(DeploymentDirectReality) {
		t.Fatal("direct mode must not require or imply Cloudflare proxying")
	}
	if !deploymentNeedsCloudflareProxy(DeploymentCDNXHTTPTLS) || !deploymentNeedsCloudflareProxy(DeploymentDualHotSwitch) {
		t.Fatal("CDN-capable modes must declare their Cloudflare dependency")
	}
}

func TestCDNXHTTPLinkRoundTrip(t *testing.T) {
	for _, profile := range []CDNXHTTPLink{
		{UUID: "11111111-1111-4111-8111-111111111111", Domain: "edge.example.com", Port: 443, Path: "/0123456789abcdef0123456789abcdef/", Label: "PNA-CDN-XHTTP"},
		{UUID: "22222222-2222-4222-8222-222222222222", Domain: "edge.example.com", Port: 8443, Path: "/fedcba9876543210fedcba9876543210/", Label: "PNA-CDN-XHTTP-STAGE"},
	} {
		link, err := buildCDNXHTTPLink(profile)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := parseCDNXHTTPLink(link)
		if err != nil {
			t.Fatalf("generated link was not parseable: %v\n%s", err, link)
		}
		if !reflect.DeepEqual(parsed, profile) {
			t.Fatalf("round trip changed profile: got %#v want %#v", parsed, profile)
		}
	}
}

func TestCDNXHTTPLinkParserRejectsDowngradesAndAmbiguity(t *testing.T) {
	base := "vless://11111111-1111-4111-8111-111111111111@edge.example.com:443?encryption=none&security=tls&sni=edge.example.com&fp=chrome&type=xhttp&host=edge.example.com&path=%2F0123456789abcdef0123456789abcdef%2F&mode=packet-up#PNA-CDN-XHTTP"
	for _, mutation := range []string{
		strings.Replace(base, "security=tls", "security=none", 1),
		strings.Replace(base, "type=xhttp", "type=ws", 1),
		strings.Replace(base, "mode=packet-up", "mode=stream-up", 1),
		base + "&security=tls",
		strings.Replace(base, "sni=edge.example.com", "sni=origin.example.com", 1),
	} {
		if _, err := parseCDNXHTTPLink(mutation); err == nil {
			t.Fatalf("unsafe or ambiguous CDN link accepted: %s", mutation)
		}
	}
}

func TestDeploymentStateTransitionsRefuseUnsafeJumps(t *testing.T) {
	if !canTransitionDeploymentState(StateDualInstalledActiveDirect, StateSwitchToCDNStaged8443) {
		t.Fatal("direct to staged CDN transition should be allowed")
	}
	if canTransitionDeploymentState(StateDualInstalledActiveDirect, StateDualInstalledActiveCDN) {
		t.Fatal("direct to CDN must not skip staged verification and 443 commit")
	}
	if canTransitionDeploymentState(StateActiveCDN, StateActiveDirect) {
		t.Fatal("CDN to direct must not skip the 24443 shadow and Cloudflare action")
	}
}

func TestCDNXHTTPControlSurfaceKeepsCloudflareAndPublicPortsBlocked(t *testing.T) {
	for path, markers := range map[string][]string{
		"cdn_xhttp.go": {
			"CLOUDFLARE_MUTATION=NONE", "PRODUCTION_443_PROMOTION=BLOCKED",
			"stage-local", "PLAN_ONLY=1", "CLOUDFLARE_FIREWALL_APPLIED=0",
		},
		"runbook/proxy-runbook-v0.9.5/linux/04f-xhttp-cdn-api.sh": {
			"PNA_XHTTP_ERROR=EXISTING_DOMAIN_MISMATCH", "PNA_XHTTP_ERROR=STATE_DOMAIN_MISMATCH",
		},
		"android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt": {
			`"22" ->`, "CDN_STAGE_SCOPE=LOCAL_ONLY", "PRODUCTION_443_PROMOTION=BLOCKED",
		},
	} {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, marker := range markers {
			if !strings.Contains(string(body), marker) {
				t.Fatalf("%s is missing fail-closed marker %q", path, marker)
			}
		}
	}
}

func TestCompleteHandoffHasByteExactLegacyPrefix(t *testing.T) {
	fixture, err := os.ReadFile("testdata/handoff-v090-golden.txt")
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := validateHandoff(string(fixture))
	if err != nil {
		t.Fatalf("golden legacy handoff rejected: %v", err)
	}
	complete, err := appendCompleteHandoff(legacy, map[string]string{
		"PNA_VERSION":     "0.9.5",
		"ACTIVE_MODE":     "ACTIVE_DIRECT",
		"DEPLOYMENT_MODE": "direct-reality",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(complete, legacy) {
		t.Fatal("complete handoff does not begin with the byte-exact legacy handoff")
	}
	if complete[:len(legacy)] != legacy {
		t.Fatal("legacy bytes were reordered, normalized, or rewritten")
	}
	for _, preserved := range []string{
		"FUTURE_UNKNOWN_FIELD=preserve-me",
		"REALITY_CLIENT_1_LINK=vless://11111111-1111-4111-8111-111111111111@example.com:443",
		"REALITY_CLIENT_2_LINK=vless://22222222-2222-4222-8222-222222222222@example.com:443",
	} {
		if !strings.Contains(complete, preserved) {
			t.Fatalf("legacy line was lost: %s", preserved)
		}
	}
	if got := complete[len(legacy):]; !strings.HasPrefix(got, "\n\n===== PNA COMPLETE HANDOFF v0.9.5 =====\n") {
		t.Fatalf("first appended bytes were unexpected: %q", got)
	}
}

func TestCompleteHandoffRejectsLineInjection(t *testing.T) {
	if _, err := appendCompleteHandoff("HANDOFF_RUN_STARTED=fixture", map[string]string{"BAD\nKEY": "x"}); err == nil {
		t.Fatal("newline in key was accepted")
	}
	if _, err := appendCompleteHandoff("HANDOFF_RUN_STARTED=fixture", map[string]string{"SAFE_KEY": "x\nSECRET=leak"}); err == nil {
		t.Fatal("newline in value was accepted")
	}
}

func TestLoginCredentialFormRequiresAllFourRealValues(t *testing.T) {
	complete := strings.Join([]string{
		"HANDOFF_RUN_STARTED=fixture",
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=vps-secret",
		"PANEL_USERNAME=panel-admin",
		"PANEL_PASSWORD=panel-secret",
	}, "\n")
	fields, err := loginCredentialFormFields(complete)
	if err != nil {
		t.Fatal(err)
	}
	if fields["FORM_VPS_ACCOUNT"] != "root" || fields["FORM_PANEL_PASSWORD"] != "panel-secret" {
		t.Fatalf("unexpected login form fields: %#v", fields)
	}
	for _, bad := range []string{
		strings.Replace(complete, "PANEL_PASSWORD=panel-secret", "", 1),
		strings.Replace(complete, "VPS_LOGIN_PASSWORD=vps-secret", "VPS_LOGIN_PASSWORD=UNKNOWN_NOT_RECOVERABLE", 1),
		strings.Replace(complete, "PANEL_PASSWORD=panel-secret", "PANEL_PASSWORD=NOT_RETAINED_BY_APPLICATION", 1),
	} {
		if _, err := loginCredentialFormFields(bad); err == nil {
			t.Fatalf("incomplete or placeholder form was accepted: %q", bad)
		}
	}
}

func TestCompleteHandoffRendersProminentLoginForm(t *testing.T) {
	legacy := "HANDOFF_RUN_STARTED=fixture\nVPS_LOGIN_USER=root\nVPS_LOGIN_PASSWORD=vps-secret\nPANEL_USERNAME=panel-admin\nPANEL_PASSWORD=panel-secret"
	form, err := loginCredentialFormFields(legacy)
	if err != nil {
		t.Fatal(err)
	}
	complete, err := appendCompleteHandoff(legacy, form)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"===== 必须保存的登录凭据 / REQUIRED LOGIN CREDENTIALS =====",
		"VPS_ACCOUNT=root",
		"VPS_PASSWORD=vps-secret",
		"PANEL_ACCOUNT=panel-admin",
		"PANEL_PASSWORD=panel-secret",
	} {
		if !strings.Contains(complete, required) {
			t.Fatalf("prominent login form is missing %q", required)
		}
	}
}
