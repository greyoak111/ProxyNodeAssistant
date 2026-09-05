package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseMacOSProxyOutput(t *testing.T) {
	state, err := parseMacOSProxyOutput("Enabled: Yes\nServer: 127.0.0.1\nPort: 10808\nAuthenticated Proxy Enabled: 0\n")
	if err != nil {
		t.Fatal(err)
	}
	if !state.Enabled || state.Server != "127.0.0.1" || state.Port != 10808 || state.Authenticated {
		t.Fatalf("unexpected proxy state: %#v", state)
	}
	disabled, err := parseMacOSProxyOutput("Enabled: No\nServer: Empty\nPort: 0\nAuthenticated Proxy Enabled: 0\n")
	if err != nil {
		t.Fatal(err)
	}
	if disabled.Enabled || disabled.Server != "" || disabled.Port != 0 {
		t.Fatalf("unexpected disabled proxy state: %#v", disabled)
	}
	if _, err := parseMacOSProxyOutput("Enabled: Yes\nServer: 127.0.0.1\nPort: nope\n"); err == nil {
		t.Fatal("malformed proxy port was accepted")
	}
}

func TestParseMacOSNetworkServicesSkipsDisabledAndHeader(t *testing.T) {
	got := parseMacOSNetworkServices("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Ethernet\nWi-Fi\nBridge\n")
	if len(got) != 2 || got[0] != "Wi-Fi" || got[1] != "Bridge" {
		t.Fatalf("unexpected network services: %#v", got)
	}
}

func TestParseMacOSBypassOutput(t *testing.T) {
	got, err := parseMacOSBypassOutput("localhost\r\n127.0.0.1\n::1\n")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != "localhost,127.0.0.1,::1" {
		t.Fatalf("unexpected bypass domains: %#v", got)
	}
	empty, err := parseMacOSBypassOutput("There aren't any bypass domains set.\n")
	if err != nil || len(empty) != 0 {
		t.Fatalf("expected empty bypass list, got %#v, %v", empty, err)
	}
}

func TestParseMacOSAutomaticProxyOutput(t *testing.T) {
	url, enabled, err := parseMacOSAutoProxyOutput("URL: https://proxy.example/pac.pac\nEnabled: Yes\n")
	if err != nil || url != "https://proxy.example/pac.pac" || !enabled {
		t.Fatalf("unexpected automatic proxy state: %q, %t, %v", url, enabled, err)
	}
	url, enabled, err = parseMacOSAutoProxyOutput("URL: (null)\nEnabled: No\n")
	if err != nil || url != "" || enabled {
		t.Fatalf("unexpected disabled automatic proxy state: %q, %t, %v", url, enabled, err)
	}
	discovery, err := parseMacOSAutoDiscoveryOutput("Auto Proxy Discovery: Off\n")
	if err != nil || discovery {
		t.Fatalf("unexpected automatic discovery state: %t, %v", discovery, err)
	}
}

func TestMacOSProxyConfigurePlanUsesSystemNetworksetupAndNoSecrets(t *testing.T) {
	services := []macOSProxyServiceState{{Name: "Wi-Fi"}}
	commands, err := macOSProxyConfigureCommands(services)
	if err != nil {
		t.Fatal(err)
	}
	script, err := macOSProxyAdminScript(commands)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(script, "/usr/sbin/networksetup") || !strings.Contains(script, "-setwebproxy") || !strings.Contains(script, "-setsecurewebproxy") || !strings.Contains(script, "-setsocksfirewallproxy") {
		t.Fatalf("system networksetup commands missing: %s", script)
	}
	if !strings.Contains(script, "'-setautoproxystate' 'Wi-Fi' 'off'") || !strings.Contains(script, "'-setproxyautodiscovery' 'Wi-Fi' 'off'") {
		t.Fatalf("automatic proxy controls missing: %s", script)
	}
	if !strings.Contains(script, "127.0.0.1") || !strings.Contains(script, "10808") {
		t.Fatalf("proxy endpoint missing: %s", script)
	}
	for _, forbidden := range []string{"password", "PNA_PASSWORD", "sudo -S"} {
		if strings.Contains(strings.ToLower(script), strings.ToLower(forbidden)) {
			t.Fatalf("admin plan contains secret/unsafe marker %q: %s", forbidden, script)
		}
	}
}

func TestMacOSProxyRestorePlanPreservesDisabledStateAndBypass(t *testing.T) {
	state := macOSProxyState{
		Schema:   macOSProxyStateSchema,
		Endpoint: "127.0.0.1:10808",
		Captured: "2026-01-01T00:00:00Z",
		Services: []macOSProxyServiceState{{
			Name:                 "Wi-Fi",
			Web:                  macOSProxyEndpoint{Enabled: false},
			SecureWeb:            macOSProxyEndpoint{Enabled: true, Server: "proxy.example", Port: 8443},
			Socks:                macOSProxyEndpoint{Enabled: true, Server: "socks.example", Port: 1080},
			BypassDomains:        []string{"localhost", "example.org"},
			AutoProxyURL:         "https://proxy.example/pac.pac",
			AutoProxyEnabled:     true,
			AutoDiscoveryEnabled: true,
		}},
	}
	commands, err := macOSProxyRestoreCommands(state)
	if err != nil {
		t.Fatal(err)
	}
	script, err := macOSProxyAdminScript(commands)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(script, "'Empty' '0' 'off'") || !strings.Contains(script, "'proxy.example' '8443'") || !strings.Contains(script, "'socks.example' '1080'") || !strings.Contains(script, "'example.org'") {
		t.Fatalf("restore plan did not retain the saved state: %s", script)
	}
	if !strings.Contains(script, "'-setwebproxystate' 'Wi-Fi' 'off'") || !strings.Contains(script, "'-setsecurewebproxystate' 'Wi-Fi' 'on'") {
		t.Fatalf("restore enable states missing: %s", script)
	}
	if !strings.Contains(script, "'-setautoproxyurl' 'Wi-Fi' 'https://proxy.example/pac.pac'") || !strings.Contains(script, "'-setautoproxystate' 'Wi-Fi' 'on'") || !strings.Contains(script, "'-setproxyautodiscovery' 'Wi-Fi' 'on'") {
		t.Fatalf("automatic proxy restore missing: %s", script)
	}
}

func TestMacOSProxyStateRoundTripIsUserPrivateAndContainsNoPassword(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PNA_CONFIG_ROOT", root)
	state := macOSProxyState{
		Schema:   macOSProxyStateSchema,
		Endpoint: "127.0.0.1:10808",
		Captured: "2026-01-01T00:00:00Z",
		Services: []macOSProxyServiceState{{Name: "Wi-Fi", Web: macOSProxyEndpoint{Server: "proxy.example", Port: 3128}}},
	}
	if err := writeMacOSProxyState(state); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, macOSProxyStateName)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("state file mode is %o, want 0600", info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(string(data)), "password") {
		t.Fatalf("state file contains a password marker: %s", data)
	}
	loaded, exists, err := loadMacOSProxyState()
	if err != nil || !exists || len(loaded.Services) != 1 || loaded.Services[0].Name != "Wi-Fi" {
		t.Fatalf("state round trip failed: %#v, %t, %v", loaded, exists, err)
	}
}

func TestMacOSProxyServiceForcedAcceptsLoopbackRange(t *testing.T) {
	service := macOSProxyServiceState{
		Name:          "Wi-Fi",
		Web:           macOSProxyEndpoint{Enabled: true, Server: "127.0.0.1", Port: 10808},
		SecureWeb:     macOSProxyEndpoint{Enabled: true, Server: "127.0.0.1", Port: 10808},
		Socks:         macOSProxyEndpoint{Enabled: true, Server: "127.0.0.1", Port: 10808},
		BypassDomains: []string{"localhost", "127.0.0.0/8", "::1"},
	}
	if !macOSProxyServiceForced(service) {
		t.Fatal("loopback CIDR bypass should count as a forced local proxy")
	}
}
