package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCDNXHTTPProfileUsesPNALabelsAndImportsLegacyLabels(t *testing.T) {
	profiles := []CDNXHTTPLink{
		{UUID: "11111111-1111-4111-8111-111111111111", Domain: "edge.example.com", Port: 443, Path: "/0123456789abcdef0123456789abcdef/", Label: cdnXHTTPLabel},
		{UUID: "22222222-2222-4222-8222-222222222222", Domain: "edge.example.com", Port: 8443, Path: "/fedcba9876543210fedcba9876543210/", Label: cdnXHTTPStageLabel},
		{UUID: "33333333-3333-4333-8333-333333333333", Domain: "edge.example.com", Port: 8443, Path: "/abcdefabcdefabcdefabcdefabcdefab/", Label: cdnXHTTPOrangeLabel},
	}
	for _, profile := range profiles {
		link, err := buildCDNXHTTPLink(profile)
		if err != nil {
			t.Fatalf("canonical profile rejected: %v", err)
		}
		if strings.Contains(link, "#TNA-") {
			t.Fatalf("new link still emits a TNA fragment: %s", link)
		}
		parsed, err := parseCDNXHTTPLink(link)
		if err != nil || parsed.Label != profile.Label {
			t.Fatalf("canonical link did not round-trip: %#v err=%v", parsed, err)
		}
	}

	legacy := []CDNXHTTPLink{
		{UUID: "44444444-4444-4444-8444-444444444444", Domain: "edge.example.com", Port: 443, Path: "/0123456789abcdef0123456789abcdef/", Label: "TNA-CDN-XHTTP"},
		{UUID: "55555555-5555-4555-8555-555555555555", Domain: "edge.example.com", Port: 8443, Path: "/fedcba9876543210fedcba9876543210/", Label: "TNA-CDN-XHTTP-STAGE"},
		{UUID: "66666666-6666-4666-8666-666666666666", Domain: "edge.example.com", Port: 8443, Path: "/abcdefabcdefabcdefabcdefabcdefab/", Label: "TNA-CDN-XHTTP-ORANGE"},
	}
	for _, profile := range legacy {
		link, err := buildCDNXHTTPLink(profile)
		if err != nil {
			t.Fatalf("legacy profile should remain importable: %v", err)
		}
		if _, err := parseCDNXHTTPLink(link); err != nil {
			t.Fatalf("legacy link should remain parseable: %v", err)
		}
	}
}

func TestCDNXHTTPCanonicalizerMigratesLegacyPrefix(t *testing.T) {
	cases := []struct {
		port       int
		inputLabel string
		wantLabel  string
	}{
		{443, "TNA-CDN-XHTTP", cdnXHTTPLabel},
		{443, "TNA-CDN-XHTTP-ORANGE", cdnXHTTPOrangeLabel},
		{8443, "TNA-CDN-XHTTP-STAGE", cdnXHTTPStageLabel},
		{8443, "TNA-CDN-XHTTP-ORANGE", cdnXHTTPOrangeLabel},
		{443, cdnXHTTPLabel, cdnXHTTPLabel},
		{8443, cdnXHTTPStageLabel, cdnXHTTPStageLabel},
	}
	for _, tc := range cases {
		profile := CDNXHTTPLink{
			UUID:   "77777777-7777-4777-8777-777777777777",
			Domain: "edge.example.com",
			Port:   tc.port,
			Path:   "/0123456789abcdef0123456789abcdef/",
			Label:  tc.inputLabel,
		}
		canonical, err := canonicalizeCDNXHTTPProfile(profile)
		if err != nil {
			t.Fatalf("canonicalizer rejected %q: %v", tc.inputLabel, err)
		}
		if canonical.Label != tc.wantLabel {
			t.Fatalf("canonical label mismatch for %q: got %q want %q", tc.inputLabel, canonical.Label, tc.wantLabel)
		}
		link, err := buildCanonicalCDNXHTTPLink(profile)
		if err != nil {
			t.Fatalf("canonical builder rejected %q: %v", tc.inputLabel, err)
		}
		if strings.Contains(link, "#TNA-") || !strings.HasSuffix(link, "#"+tc.wantLabel) {
			t.Fatalf("canonical builder emitted wrong fragment for %q: %s", tc.inputLabel, link)
		}
	}
	if _, err := canonicalizeCDNXHTTPProfile(CDNXHTTPLink{
		UUID:   "77777777-7777-4777-8777-777777777777",
		Domain: "edge.example.com",
		Port:   8443,
		Path:   "/0123456789abcdef0123456789abcdef/",
		Label:  "TNA-CDN-XHTTP",
	}); err == nil {
		t.Fatal("canonicalizer accepted a port/label combination that the parser rejects")
	}
}

func TestCDNXHTTPURLCanonicalizerPreservesOptionalQuery(t *testing.T) {
	legacy := "vless://77777777-7777-4777-8777-777777777777@edge.example.com:8443?type=xhttp&encryption=none&path=%2F0123456789abcdef0123456789abcdef%2F&host=edge.example.com&mode=packet-up&security=tls&sni=edge.example.com&fp=chrome&x_padding_bytes=100-1000&extra=%7B%22mode%22%3A%22packet-up%22%7D#TNA-CDN-XHTTP-ORANGE"
	canonical, err := canonicalizeCDNXHTTPURL(legacy)
	if err != nil {
		t.Fatalf("legacy URL rejected: %v", err)
	}
	if !strings.Contains(canonical, "x_padding_bytes=100-1000") || !strings.Contains(canonical, "extra=%7B%22mode%22%3A%22packet-up%22%7D") {
		t.Fatalf("canonicalization dropped optional XHTTP query parameters: %s", canonical)
	}
	if !strings.HasSuffix(canonical, "#PNA-CDN-XHTTP-ORANGE") || strings.Contains(canonical, "#TNA-") {
		t.Fatalf("canonicalization did not migrate only the fragment: %s", canonical)
	}
	if _, err := parseCDNXHTTPLink(canonical); err != nil {
		t.Fatalf("canonical URL no longer parses: %v", err)
	}
}

func TestCDNXHTTPRunbookEmitsPNAAndKeepsExactLegacyMatcher(t *testing.T) {
	path := filepath.Join("runbook", "proxy-node-assistant-v1.0.0", "linux", "04f-xhttp-cdn-api.sh")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, required := range []string{
		`REMARK="pna-cdn-xhttp"`,
		`LEGACY_REMARK="tna-cdn-xhttp"`,
		`EXTERNAL_PROXY_REMARK="pna-cdn-xhttp-orange"`,
		`CLIENT_COMMENT="pna-cdn-xhttp-v1.0.0"`,
		`label='PNA-CDN-XHTTP-ORANGE'`,
		`--arg client_comment "$CLIENT_COMMENT"`,
		`--arg comment "$CLIENT_COMMENT"`,
		`--arg external_remark "$EXTERNAL_PROXY_REMARK"`,
		`group_id="$(jq -r '.groupId // empty' <<<"$group")"`,
		`/hosts/del/${group_id}`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("runbook is missing canonical PNA emission %q", required)
		}
	}
	for _, forbidden := range []string{
		`comment:"tna-cdn-xhttp-v0.9.5"`,
		`label='TNA-CDN-XHTTP-ORANGE'`,
		`externalProxy=[{forceTls:"tls",dest:$domain,port:$public_port,remark:"tna-cdn-xhttp-orange"}]`,
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("runbook still emits retired CDN label %q", forbidden)
		}
	}
}
