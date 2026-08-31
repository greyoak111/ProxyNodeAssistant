package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func validGrayPlan() InstallPlan {
	plan := defaultInstallPlan()
	plan.Gray = RouteIdentity{Domain: "cover.example.com", Email: "ops@example.com"}
	return plan
}

func TestInstallPlanGrayValidation(t *testing.T) {
	if err := validGrayPlan().validateFor(false); err != nil {
		t.Fatalf("default gray plan should validate: %v", err)
	}
}

func TestInstallPlanKeepOnlyForExistingNode(t *testing.T) {
	plan := defaultInstallPlan()
	plan.Preferences.RouteMode = RouteKeep
	plan.Preferences.Performance = PerformancePreserve
	plan.Preferences.WarpMode = WarpPreserve
	if err := plan.validateFor(false); err == nil || !strings.Contains(err.Error(), "existing managed node") {
		t.Fatalf("fresh node must reject keep, got %v", err)
	}
	if err := plan.validateFor(true); err != nil {
		t.Fatalf("existing node should accept keep without route identity: %v", err)
	}
}

func TestInstallPlanDualNeedsDifferentDomains(t *testing.T) {
	plan := validGrayPlan()
	plan.Preferences.RouteMode = RouteDual
	plan.Orange = RouteIdentity{Domain: "cover.example.com", Email: "cdn@example.com"}
	if err := plan.validate(); err == nil || !strings.Contains(err.Error(), "different hostnames") {
		t.Fatalf("expected a distinct-hostname error, got %v", err)
	}
}

func TestInstallPlanReviewMasksEmail(t *testing.T) {
	plan := validGrayPlan()
	joined := strings.Join(plan.reviewLines(), "\n")
	if strings.Contains(joined, plan.Gray.Email) || !strings.Contains(joined, "o***@example.com") {
		t.Fatalf("review must mask email local-part: %s", joined)
	}
}

func TestInstallPreferenceSummaryContainsNoRouteIdentity(t *testing.T) {
	plan := validGrayPlan()
	joined := strings.Join(plan.preferenceSummaryLines(), "\n")
	if strings.Contains(joined, plan.Gray.Domain) || strings.Contains(joined, plan.Gray.Email) {
		t.Fatalf("diagnostic preference summary leaked route identity: %s", joined)
	}
}

func TestInstallPlanRejectsUncoordinatedPorts(t *testing.T) {
	plan := validGrayPlan()
	plan.Ports.RealityShadow = 24444
	if err := plan.validate(); err == nil || !strings.Contains(err.Error(), "coordinated port plan") {
		t.Fatalf("expected a coordinated-port error, got %v", err)
	}
}

func TestInstallPreferencesCannotSerializeRouteIdentity(t *testing.T) {
	plan := validGrayPlan()
	data, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if strings.Contains(text, plan.Gray.Domain) || strings.Contains(text, plan.Gray.Email) {
		t.Fatalf("route identity leaked into persisted JSON: %s", text)
	}
}

func TestInstallPlanRequiresBackupBeforeChange(t *testing.T) {
	plan := validGrayPlan()
	plan.Preferences.BackupBeforeChange = false
	if err := plan.validate(); err == nil || !strings.Contains(err.Error(), "cannot be disabled") {
		t.Fatalf("expected mandatory backup error, got %v", err)
	}
}
