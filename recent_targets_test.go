package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRecentTargetsParseNormalizeAndCap(t *testing.T) {
	newer := time.Date(2026, 8, 21, 12, 0, 0, 0, time.UTC)
	older := newer.Add(-time.Hour)
	data := []byte("example.test\troot\t22\t" + older.Format(time.RFC3339Nano) + "\n" +
		"EXAMPLE.test\troot\t22\t" + newer.Format(time.RFC3339Nano) + "\n" +
		"bad host\troot\t22\t" + newer.Format(time.RFC3339Nano) + "\n" +
		"192.0.2.10\tubuntu\t2222\t" + older.Format(time.RFC3339Nano) + "\n")
	values := parseRecentTargets(data)
	if len(values) != 2 {
		t.Fatalf("expected 2 valid deduplicated targets, got %d", len(values))
	}
	if values[0].Host != "EXAMPLE.test" || values[1].Port != 2222 {
		t.Fatalf("unexpected normalized order: %#v", values)
	}
}

func TestRecentTargetsRememberDeleteAndClear(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recent-targets.tsv")
	t.Setenv("PNA_HISTORY_PATH", path)
	first := RecentTarget{Host: "192.0.2.20", User: "root", Port: 22}
	second := RecentTarget{Host: "node.example", User: "ubuntu", Port: 2222}
	if err := rememberRecentTarget(first); err != nil {
		t.Fatal(err)
	}
	if err := rememberRecentTarget(second); err != nil {
		t.Fatal(err)
	}
	values, err := loadRecentTargets()
	if err != nil || len(values) != 2 || values[0].Host != second.Host {
		t.Fatalf("unexpected remembered targets: %#v err=%v", values, err)
	}
	if err := deleteRecentTarget(0); err != nil {
		t.Fatal(err)
	}
	values, _ = loadRecentTargets()
	if len(values) != 1 || values[0].Host != first.Host {
		t.Fatalf("unexpected delete result: %#v", values)
	}
	if err := clearRecentTargets(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("history file still exists after clear: %v", err)
	}
}

func TestRecentTargetsMergeCanonicalAndLegacyLocations(t *testing.T) {
	base := t.TempDir()
	t.Setenv("APPDATA", base)
	t.Setenv("PNA_HISTORY_PATH", "")
	current := filepath.Join(base, "ProxyNodeAssistant", "recent-targets.tsv")
	legacy := filepath.Join(base, "TextNodeAssistant", "recent-targets.tsv")
	newer := time.Date(2026, 9, 2, 1, 0, 0, 0, time.UTC)
	older := newer.Add(-time.Hour)
	if err := os.MkdirAll(filepath.Dir(current), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(legacy), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(current, []byte("node.example\troot\t22\t"+newer.Format(time.RFC3339Nano)+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacy, []byte("legacy.example\tubuntu\t2222\t"+older.Format(time.RFC3339Nano)+"\n"+"node.example\troot\t22\t"+older.Format(time.RFC3339Nano)+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	values, err := loadRecentTargets()
	if err != nil {
		t.Fatal(err)
	}
	if len(values) != 2 || values[0].Host != "node.example" || values[1].Host != "legacy.example" {
		t.Fatalf("canonical and legacy histories were not merged/deduplicated: %#v", values)
	}
}
