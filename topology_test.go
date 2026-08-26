package main

import (
	"strings"
	"testing"
)

func TestTopologyPlanBodyMatrix(t *testing.T) {
	tests := []struct {
		name string
		plan topologyPlan
		mode string
	}{
		{
			name: "gray",
			plan: topologyPlan{Mode: topologyGray, GrayDomain: "gray.example.com", GrayEmail: "gray@example.com"},
			mode: "gray",
		},
		{
			name: "orange",
			plan: topologyPlan{Mode: topologyOrange, OrangeDomain: "edge.example.com", OrangeEmail: "edge@example.com"},
			mode: "orange",
		},
		{
			name: "dual",
			plan: topologyPlan{Mode: topologyDual, GrayDomain: "gray.example.com", GrayEmail: "gray@example.com", OrangeDomain: "edge.example.com", OrangeEmail: "edge@example.com"},
			mode: "dual",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body, err := topologyPlanBody(test.plan)
			if err != nil {
				t.Fatalf("topologyPlanBody: %v", err)
			}
			if !strings.Contains(body, "TOPOLOGY_STATE_VERSION=1\n") || !strings.Contains(body, "TOPOLOGY_MODE="+test.mode+"\n") {
				t.Fatalf("state header mismatch:\n%s", body)
			}
			if strings.Count(body, "\n") != 6 {
				t.Fatalf("expected exactly six records, got:\n%s", body)
			}
		})
	}
}

func TestTopologyPlanBodyRejectsIncompleteOrAmbiguousPlans(t *testing.T) {
	tests := []topologyPlan{
		{},
		{Mode: topologyGray, GrayDomain: "", GrayEmail: "gray@example.com"},
		{Mode: topologyOrange, OrangeDomain: "edge.example.com", OrangeEmail: "not-an-email"},
		{Mode: topologyDual, GrayDomain: "same.example.com", GrayEmail: "gray@example.com", OrangeDomain: "same.example.com", OrangeEmail: "edge@example.com"},
	}
	for _, plan := range tests {
		if body, err := topologyPlanBody(plan); err == nil {
			t.Fatalf("invalid plan unexpectedly serialized: %q", body)
		}
	}
}
