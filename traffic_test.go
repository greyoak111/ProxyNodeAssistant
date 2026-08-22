package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestTrafficWarningThresholds(t *testing.T) {
	tests := []struct {
		percent float64
		want    string
	}{
		{0, "GOOD"}, {69.99, "GOOD"},
		{70, "NOTICE"}, {84.99, "NOTICE"},
		{85, "WARNING"}, {94.99, "WARNING"},
		{95, "CRITICAL"}, {120, "CRITICAL"},
	}
	for _, test := range tests {
		if got := trafficWarning(test.percent); got != test.want {
			t.Fatalf("trafficWarning(%v) = %q, want %q", test.percent, got, test.want)
		}
	}
}

func TestTrafficPeriodUsesConfiguredResetDay(t *testing.T) {
	location := time.FixedZone("test", 8*60*60)
	start, next := trafficPeriod(time.Date(2026, 8, 22, 12, 0, 0, 0, location), 23)
	if want := time.Date(2026, 7, 23, 0, 0, 0, 0, location); !start.Equal(want) {
		t.Fatalf("start = %s, want %s", start, want)
	}
	if want := time.Date(2026, 8, 23, 0, 0, 0, 0, location); !next.Equal(want) {
		t.Fatalf("next = %s, want %s", next, want)
	}
}

func TestParseVnStatTrafficCountsOnlyCurrentPeriod(t *testing.T) {
	payload := `{"interfaces":[{"name":"eth0","traffic":{"day":[` +
		`{"date":{"year":2026,"month":7,"day":22},"rx":100,"tx":200},` +
		`{"date":{"year":2026,"month":7,"day":23},"rx":10,"tx":20},` +
		`{"date":{"year":2026,"month":8,"day":22},"rx":30,"tx":40}` +
		`]}}]}`
	now := time.Date(2026, 8, 22, 12, 0, 0, 0, time.UTC)
	snapshot, err := parseVnStatTraffic([]byte(payload), 1000, 23, now)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.RXBytes != 40 || snapshot.TXBytes != 60 || snapshot.UsedBytes != 100 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestKiwiVMMultiplierAppliesToCounterAndAllowance(t *testing.T) {
	decoder := json.NewDecoder(strings.NewReader(`{
		"data_counter": 100,
		"plan_monthly_data": 1000,
		"monthly_data_multiplier": 2,
		"data_next_reset": 1787443200
	}`))
	decoder.UseNumber()
	var payload interface{}
	if err := decoder.Decode(&payload); err != nil {
		t.Fatal(err)
	}
	snapshot, err := parseKiwiVMSnapshot(payload)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.UsedBytes != 200 || snapshot.QuotaBytes != 2000 {
		t.Fatalf("multiplied values are wrong: %#v", snapshot)
	}
}

func TestProviderEndpointIsHTTPSAndSecretFree(t *testing.T) {
	for _, invalid := range []string{
		"http://example.test/traffic",
		"https://user:secret@example.test/traffic",
		"https://example.test/traffic?token=secret",
		"https://example.test/traffic#secret",
	} {
		if _, err := validProviderEndpoint(invalid); err == nil {
			t.Fatalf("unsafe endpoint was accepted: %s", invalid)
		}
	}
	if got, err := validProviderEndpoint("https://example.test/v1/traffic"); err != nil || got == "" {
		t.Fatalf("safe endpoint was rejected: %q, %v", got, err)
	}
}

func TestProviderTrafficSnapshotCanBeCachedAndViewedOffline(t *testing.T) {
	checked := time.Date(2026, 8, 23, 3, 6, 0, 0, time.UTC)
	profile := TrafficProfile{ID: "node-a", Provider: "kiwivm", Label: "node-a"}
	want := TrafficSnapshot{
		Source:     "KiwiVM API",
		UsedBytes:  123456,
		QuotaBytes: 987654321,
		RXBytes:    111,
		TXBytes:    222,
		ResetAt:    checked.Add(24 * time.Hour),
		Detail:     "cached test",
	}
	cacheTrafficSnapshot(&profile, want, checked)
	got, ok := cachedTrafficSnapshot(profile)
	if !ok {
		t.Fatal("cached snapshot was not marked as available")
	}
	if got != want {
		t.Fatalf("cached snapshot = %#v, want %#v", got, want)
	}
	if !profile.LastCheckedUTC.Equal(checked) {
		t.Fatalf("checked time = %s, want %s", profile.LastCheckedUTC, checked)
	}
}

func TestOldProviderProfileDoesNotPretendZeroUsageIsCached(t *testing.T) {
	profile := TrafficProfile{ID: "legacy", Provider: "kiwivm", QuotaBytes: 1024, LastCheckedUTC: time.Now()}
	if _, ok := cachedTrafficSnapshot(profile); ok {
		t.Fatal("legacy metadata without hasLastSnapshot must not be shown as a zero-usage cache")
	}
}

func TestVersion090WiresTrafficAndPerformanceIntoGUI(t *testing.T) {
	mainSource, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	guiSource, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{`case "16":`, `case "17":`, `case "t":`} {
		if !strings.Contains(string(mainSource), required) {
			t.Fatalf("main dispatcher is missing %s", required)
		}
	}
	for _, required := range []string{`Op("16"`, `Op("17"`, `Op("T"`, `GuiSecretPromptPrefix`} {
		if !strings.Contains(string(guiSource), required) {
			t.Fatalf("GUI integration is missing %s", required)
		}
	}
}

func TestRemote090ScriptsAreRollbackCapableAndBounded(t *testing.T) {
	performance, err := os.ReadFile("runbook/proxy-runbook-v0.9.0/linux/20-adaptive-performance.sh")
	if err != nil {
		t.Fatal(err)
	}
	traffic, err := os.ReadFile("runbook/proxy-runbook-v0.9.0/linux/21-traffic-status.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"PERFORMANCE_APPLY_OK", "PERFORMANCE_ROLLBACK_OK", "restore_backup", "--apply auto|low|standard|high"} {
		if !strings.Contains(string(performance), required) {
			t.Fatalf("performance script is missing %q", required)
		}
	}
	for _, required := range []string{"VNSTAT_INSTALL_OK", "--status", "--json", "PROXY_RUNBOOK_TRAFFIC_INTERFACE"} {
		if !strings.Contains(string(traffic), required) {
			t.Fatalf("traffic script is missing %q", required)
		}
	}
}
