package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const localDNSProbeTimeout = 10 * time.Second

type dnsProbeResult struct {
	System     bool
	Cloudflare bool
	Google     bool
}

func (r dnsProbeResult) Accepted() bool {
	return r.System || (r.Cloudflare && r.Google)
}

func (r dnsProbeResult) Summary() string {
	state := func(ok bool) string {
		if ok {
			return "MATCH"
		}
		return "MISS"
	}
	return fmt.Sprintf("system=%s cloudflare=%s google=%s", state(r.System), state(r.Cloudflare), state(r.Google))
}

type dnsProbeDependencies struct {
	SystemLookup func(context.Context, string) ([]net.IP, error)
	PublicLookup func(context.Context, string, string) ([]net.IP, error)
	Timeout      time.Duration
}

func defaultDNSProbeDependencies() dnsProbeDependencies {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// DNS verification must not silently depend on the optional local 10808
	// proxy environment. A broken local proxy would otherwise look like bad DNS.
	transport.Proxy = nil
	client := &http.Client{Transport: transport, Timeout: localDNSProbeTimeout}
	return dnsProbeDependencies{
		SystemLookup: func(ctx context.Context, domain string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip4", domain)
		},
		PublicLookup: func(ctx context.Context, provider, domain string) ([]net.IP, error) {
			return lookupPublicDNS(ctx, client, provider, domain)
		},
		Timeout: localDNSProbeTimeout,
	}
}

type dnsJSONResponse struct {
	Status int `json:"Status"`
	Answer []struct {
		Type int    `json:"type"`
		Data string `json:"data"`
	} `json:"Answer"`
}

func lookupPublicDNS(ctx context.Context, client *http.Client, provider, domain string) ([]net.IP, error) {
	var endpoint string
	switch provider {
	case "cloudflare":
		// Use the provider's certificate-covered IP endpoint so the fallback
		// still works when the Windows resolver cannot resolve DoH hostnames.
		endpoint = "https://1.1.1.1/dns-query"
	case "google":
		endpoint = "https://8.8.8.8/resolve"
	default:
		return nil, fmt.Errorf("unsupported DNS provider %q", provider)
	}
	query := url.Values{"name": {domain}, "type": {"A"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/dns-json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("DNS-over-HTTPS returned HTTP %d", resp.StatusCode)
	}
	var decoded dnsJSONResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		return nil, err
	}
	if decoded.Status != 0 {
		return nil, fmt.Errorf("DNS-over-HTTPS status %d", decoded.Status)
	}
	addresses := make([]net.IP, 0, len(decoded.Answer))
	for _, answer := range decoded.Answer {
		if answer.Type != 1 {
			continue
		}
		if parsed := net.ParseIP(strings.TrimSpace(answer.Data)); parsed != nil && parsed.To4() != nil {
			addresses = append(addresses, parsed.To4())
		}
	}
	if len(addresses) == 0 {
		return nil, errors.New("DNS-over-HTTPS response contained no IPv4 answer")
	}
	return addresses, nil
}

func addressesContainIPv4(addresses []net.IP, expected net.IP) bool {
	expected4 := expected.To4()
	if expected4 == nil {
		return false
	}
	for _, address := range addresses {
		if address4 := address.To4(); address4 != nil && address4.Equal(expected4) {
			return true
		}
	}
	return false
}

func probeDomainDNS(domain, publicIP string, deps dnsProbeDependencies) dnsProbeResult {
	domain = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(domain)), ".")
	expected := net.ParseIP(strings.TrimSpace(publicIP))
	if !validDomain(domain) || expected == nil || expected.To4() == nil || deps.SystemLookup == nil || deps.PublicLookup == nil {
		return dnsProbeResult{}
	}
	timeout := deps.Timeout
	if timeout <= 0 {
		timeout = localDNSProbeTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	type observation struct {
		provider string
		match    bool
	}
	results := make(chan observation, 3)
	launch := func(provider string, lookup func(context.Context) ([]net.IP, error)) {
		go func() {
			addresses, err := lookup(ctx)
			results <- observation{provider: provider, match: err == nil && addressesContainIPv4(addresses, expected)}
		}()
	}
	launch("system", func(ctx context.Context) ([]net.IP, error) {
		return deps.SystemLookup(ctx, domain)
	})
	for _, provider := range []string{"cloudflare", "google"} {
		provider := provider
		launch(provider, func(ctx context.Context) ([]net.IP, error) {
			return deps.PublicLookup(ctx, provider, domain)
		})
	}

	var result dnsProbeResult
	for received := 0; received < 3; received++ {
		var observation observation
		select {
		case observation = <-results:
		case <-ctx.Done():
			return result
		}
		switch observation.provider {
		case "system":
			result.System = observation.match
		case "cloudflare":
			result.Cloudflare = observation.match
		case "google":
			result.Google = observation.match
		}
	}
	return result
}

func domainDNSProbe(domain, publicIP string) dnsProbeResult {
	return probeDomainDNS(domain, publicIP, defaultDNSProbeDependencies())
}
