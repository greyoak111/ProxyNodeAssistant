package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestNormalizePublicIPv4(t *testing.T) {
	if got, ok := normalizePublicIPv4(" 8.8.8.8\n"); !ok || got != "8.8.8.8" {
		t.Fatalf("expected normalized public IPv4, got %q %t", got, ok)
	}
	for _, value := range []string{"127.0.0.1", "10.0.0.1", "::1", "not-an-ip"} {
		if _, ok := normalizePublicIPv4(value); ok {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestDetectCurrentPublicIPv4UsesMajority(t *testing.T) {
	values := []string{"8.8.8.8", "8.8.8.8", "1.1.1.1"}
	var servers []*httptest.Server
	for _, value := range values {
		value := value
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = fmt.Fprintln(w, value)
		}))
		servers = append(servers, server)
		defer server.Close()
	}
	endpoints := make([]string, 0, len(servers))
	for _, server := range servers {
		endpoints = append(endpoints, server.URL)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	result, err := detectCurrentPublicIPv4(ctx, endpoints)
	if err != nil {
		t.Fatal(err)
	}
	if result.IP != "8.8.8.8" || len(result.Sources) != 2 || result.Total != 3 {
		t.Fatalf("unexpected majority result: %#v", result)
	}
}

func TestParseSS2022Allowlist(t *testing.T) {
	output := "noise\n" + ss2022AllowlistBegin + "\nSOURCE=8.8.8.8\nSOURCE=1.1.1.1\n" + ss2022AllowlistEnd + "\n"
	entries, err := parseSS2022Allowlist(output)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0] != "8.8.8.8" || entries[1] != "1.1.1.1" {
		t.Fatalf("unexpected allowlist entries: %#v", entries)
	}
}

func TestParseSS2022AllowlistAcceptsEmptyBlock(t *testing.T) {
	entries, err := parseSS2022Allowlist(ss2022AllowlistBegin + "\n" + ss2022AllowlistEnd + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected an empty allowlist, got %#v", entries)
	}
}

func TestParseSS2022AllowlistRejectsMalformedEntries(t *testing.T) {
	for _, value := range []string{
		ss2022AllowlistBegin + "\nSOURCE=10.0.0.1\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nSOURCE=8.8.8.8/32\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nSOURCE=8.8.8.8\nSOURCE=8.8.8.8\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nNOT_SOURCE=8.8.8.8\n" + ss2022AllowlistEnd,
	} {
		if _, err := parseSS2022Allowlist(value); err == nil {
			t.Fatalf("malformed allowlist was accepted: %q", value)
		}
	}
}

func TestSS2022ScriptCommandQuotesArgumentsAndSupportsLegacyRoots(t *testing.T) {
	command := ss2022ScriptCommand("allow", "8.8.8.8")
	for _, required := range []string{
		"root='/opt/proxy-node-assistant-current'",
		"root='/opt/text-node-assistant-current'",
		"root='/opt/proxy-runbook-current'",
		"bash \"$root/linux/23-ss2022-tcp.sh\" 'allow' '8.8.8.8'",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("SS2022 command missing %q: %s", required, command)
		}
	}
	malicious := ss2022ScriptCommand("allow", "8.8.8.8; touch /tmp/pwned")
	if !strings.Contains(malicious, `bash "$root/linux/23-ss2022-tcp.sh" 'allow' '8.8.8.8; touch /tmp/pwned'`) {
		t.Fatalf("SS2022 source was not shell-quoted as one argument: %s", malicious)
	}
}

func TestSS2022AllowlistMenuHasSeparateCRUDEntry(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		`[19] SS2022 来源白名单：识别本机 IP / 对照 VPS / 添加当前来源`,
		`[24] SS2022 白名单管理：查看 / 添加指定 IPv4 / 删除`,
		`case "24":`,
		`a.manageSS2022AllowlistEntries`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("CLI SS2022 allowlist menu is missing %q", required)
		}
	}
}
