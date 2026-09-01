package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
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
