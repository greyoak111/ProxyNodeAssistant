package main

import (
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
		{UUID: "11111111-1111-4111-8111-111111111111", Domain: "edge.example.com", Port: 443, Path: "/0123456789abcdef0123456789abcdef/", Label: "TNA-CDN-XHTTP"},
		{UUID: "22222222-2222-4222-8222-222222222222", Domain: "edge.example.com", Port: 8443, Path: "/fedcba9876543210fedcba9876543210/", Label: "TNA-CDN-XHTTP-STAGE"},
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
	base := "vless://11111111-1111-4111-8111-111111111111@edge.example.com:443?encryption=none&security=tls&sni=edge.example.com&fp=chrome&type=xhttp&host=edge.example.com&path=%2F0123456789abcdef0123456789abcdef%2F&mode=packet-up#TNA-CDN-XHTTP"
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
	if !canTransitionDeploymentState(StateDualInstalledActiveDirect, StateActiveDirect) {
		t.Fatal("verified managed-component removal must be able to return dual/direct to plain direct")
	}
}
