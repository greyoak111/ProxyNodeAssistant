package main

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func dnsTestDependencies(system []net.IP, systemErr error, public map[string][]net.IP, publicErr map[string]error) dnsProbeDependencies {
	return dnsProbeDependencies{
		SystemLookup: func(context.Context, string) ([]net.IP, error) {
			return system, systemErr
		},
		PublicLookup: func(_ context.Context, provider, _ string) ([]net.IP, error) {
			return public[provider], publicErr[provider]
		},
		Timeout: 100 * time.Millisecond,
	}
}

func TestDNSProbeAcceptsSystemResolverMatch(t *testing.T) {
	deps := dnsTestDependencies(
		[]net.IP{net.ParseIP("203.0.113.10")}, nil,
		map[string][]net.IP{}, map[string]error{"cloudflare": errors.New("offline"), "google": errors.New("offline")},
	)
	result := probeDomainDNS("cover.example.com", "203.0.113.10", deps)
	if !result.Accepted() || !result.System {
		t.Fatalf("system match was rejected: %+v", result)
	}
}

func TestDNSProbeAcceptsPublicQuorumWhenWindowsResolverFails(t *testing.T) {
	wanted := []net.IP{net.ParseIP("203.0.113.10")}
	deps := dnsTestDependencies(nil, errors.New("Windows DNS timeout"), map[string][]net.IP{
		"cloudflare": wanted,
		"google":     wanted,
	}, nil)
	result := probeDomainDNS("Cover.Example.com.", "203.0.113.10", deps)
	if !result.Accepted() || result.System || !result.Cloudflare || !result.Google {
		t.Fatalf("public resolver quorum was rejected: %+v", result)
	}
}

func TestDNSProbeRejectsOnePublicResolverOnly(t *testing.T) {
	deps := dnsTestDependencies(nil, errors.New("timeout"), map[string][]net.IP{
		"cloudflare": {net.ParseIP("203.0.113.10")},
		"google":     {net.ParseIP("203.0.113.11")},
	}, nil)
	if result := probeDomainDNS("cover.example.com", "203.0.113.10", deps); result.Accepted() {
		t.Fatalf("single public match was accepted: %+v", result)
	}
}

func TestDNSProbeRequiresExactIPv4(t *testing.T) {
	deps := dnsTestDependencies([]net.IP{net.ParseIP("203.0.113.100")}, nil, map[string][]net.IP{
		"cloudflare": {net.ParseIP("203.0.113.100")},
		"google":     {net.ParseIP("203.0.113.100")},
	}, nil)
	if result := probeDomainDNS("cover.example.com", "203.0.113.10", deps); result.Accepted() {
		t.Fatalf("prefix-like address mismatch was accepted: %+v", result)
	}
}

func TestDNSProbeTimeoutIsBounded(t *testing.T) {
	blocking := func(ctx context.Context) ([]net.IP, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	deps := dnsProbeDependencies{
		SystemLookup: func(ctx context.Context, _ string) ([]net.IP, error) { return blocking(ctx) },
		PublicLookup: func(ctx context.Context, _, _ string) ([]net.IP, error) { return blocking(ctx) },
		Timeout:      30 * time.Millisecond,
	}
	started := time.Now()
	result := probeDomainDNS("cover.example.com", "203.0.113.10", deps)
	if result.Accepted() {
		t.Fatalf("timed-out probes were accepted: %+v", result)
	}
	if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
		t.Fatalf("probe exceeded bounded timeout: %s", elapsed)
	}
}

func TestOrangeDNSProbeAcceptsSystemResolverWhenPublicDoHIsBlocked(t *testing.T) {
	deps := dnsTestDependencies([]net.IP{net.ParseIP("192.0.2.44")}, nil, map[string][]net.IP{}, map[string]error{
		"cloudflare": errors.New("DoH timeout"),
		"google":     errors.New("DoH timeout"),
	})
	result := probeOrangeDNS("edge.example.com", deps)
	if !result.Accepted() || !result.System {
		t.Fatalf("system resolver fallback was rejected: %+v", result)
	}
}

func TestOrangeDNSProbeAcceptsSinglePublicResolver(t *testing.T) {
	deps := dnsTestDependencies(nil, errors.New("local resolver unavailable"), map[string][]net.IP{
		"cloudflare": {net.ParseIP("198.51.100.12")},
	}, map[string]error{"google": errors.New("DoH timeout")})
	result := probeOrangeDNS("edge.example.com", deps)
	if !result.Accepted() || !result.Cloudflare || result.Google {
		t.Fatalf("single public resolver answer was not preserved: %+v", result)
	}
}

func TestOrangeDNSProbeRejectsNoIPv4Answer(t *testing.T) {
	deps := dnsTestDependencies([]net.IP{}, errors.New("no A record"), map[string][]net.IP{}, map[string]error{
		"cloudflare": errors.New("timeout"),
		"google":     errors.New("timeout"),
	})
	if result := probeOrangeDNS("edge.example.com", deps); result.Accepted() {
		t.Fatalf("empty DNS observations were accepted: %+v", result)
	}
}
