package main

import (
	"strings"
	"testing"
)

func TestParseSS2022AllowlistAcceptsCanonicalEntries(t *testing.T) {
	output := strings.Join([]string{
		"noise emitted by ssh",
		ss2022AllowlistBegin,
		"SOURCE=203.0.113.7",
		"SOURCE=198.51.100.42",
		ss2022AllowlistEnd,
	}, "\n")
	got, err := parseSS2022Allowlist(output)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"203.0.113.7", "198.51.100.42"}
	if len(got) != len(want) {
		t.Fatalf("entries = %#v, want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("entries = %#v, want %#v", got, want)
		}
	}
}

func TestParseSS2022AllowlistAllowsAnEmptyList(t *testing.T) {
	got, err := parseSS2022Allowlist(ss2022AllowlistBegin + "\n" + ss2022AllowlistEnd + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("empty allowlist parsed as %#v", got)
	}
}

func TestParseSS2022AllowlistRejectsInvalidOrDuplicateEntries(t *testing.T) {
	cases := []string{
		ss2022AllowlistBegin + "\nSOURCE=192.168.1.2\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nSOURCE=203.0.113.7/32\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nSOURCE=203.0.113.7\nSOURCE=203.0.113.7\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\n203.0.113.7\n" + ss2022AllowlistEnd,
		ss2022AllowlistBegin + "\nSOURCE=203.0.113.7\n",
	}
	for _, output := range cases {
		if _, err := parseSS2022Allowlist(output); err == nil {
			t.Fatalf("invalid allowlist output was accepted: %q", output)
		}
	}
}

func TestSS2022ScriptCommandQuotesMutationSource(t *testing.T) {
	command := ss2022ScriptCommand("allow", "203.0.113.7")
	if !strings.Contains(command, "23-ss2022-tcp.sh") || !strings.Contains(command, "allow") || !strings.Contains(command, "203.0.113.7") {
		t.Fatalf("unexpected SS2022 command: %s", command)
	}
	if strings.Contains(command, "allow 203.0.113.7;\n") {
		t.Fatal("source argument was not kept as one shell word")
	}
}
