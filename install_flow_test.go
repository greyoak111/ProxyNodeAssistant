package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRandomOneRunInputPathIsBoundedAndUnique(t *testing.T) {
	first, err := randomOneRunInputPath()
	if err != nil {
		t.Fatal(err)
	}
	second, err := randomOneRunInputPath()
	if err != nil {
		t.Fatal(err)
	}
	const prefix = "/tmp/text-node-assistant-auto-input-"
	if !strings.HasPrefix(first, prefix) || !strings.HasPrefix(second, prefix) {
		t.Fatalf("unexpected one-run input paths: %q %q", first, second)
	}
	if first == second {
		t.Fatal("one-run input paths must be unique")
	}
	if strings.ContainsAny(first+second, " \t\r\n;&|`$\\") {
		t.Fatalf("one-run input path contains a shell-significant character: %q %q", first, second)
	}
}

func TestInstallEnvironmentCarriesOnlyModesPortsAndRandomInput(t *testing.T) {
	app := &App{lang: LangZH}
	plan := validGrayPlan()
	plan.Preferences.RouteMode = RouteDual
	plan.Orange = RouteIdentity{Domain: "cdn.example.com", Email: "cdn-ops@example.com"}
	environment := app.installEnvironment(Connection{User: "root"}, plan, "/tmp/text-node-assistant-auto-input-001122", "1")
	for _, required := range []string{
		"TNA_ROUTE_MODE='dual'",
		"TNA_PERFORMANCE_MODE='auto'",
		"TNA_WARP_MODE='ensure-on'",
		"TNA_COVER_TEMPLATE='random'",
		"TNA_PLAN_CONFIRMED='1'",
		"TNA_REALITY_PORT='443'",
		"TNA_REALITY_SHADOW_PORT='24443'",
		"TNA_CDN_ORIGIN_PORT='8443'",
		"TNA_WARP_PORT='40000'",
		"TNA_AUTO_INPUT='/tmp/text-node-assistant-auto-input-001122'",
	} {
		if !strings.Contains(environment, required) {
			t.Fatalf("install environment is missing %q: %s", required, environment)
		}
	}
	for _, secretOrIdentity := range []string{plan.Gray.Domain, plan.Gray.Email, plan.Orange.Domain, plan.Orange.Email} {
		if strings.Contains(environment, secretOrIdentity) {
			t.Fatalf("install environment leaked route identity %q: %s", secretOrIdentity, environment)
		}
	}
}

func TestSettingsRejectUnsafeOrIncompleteInstallPreferences(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	path, err := settingsPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	unsafe := Settings{
		Language: LangEN,
		InstallPreferences: InstallPreferences{
			RouteMode:          RouteOrange,
			CoverChoice:        "999",
			Performance:        PerformanceHigh,
			WarpMode:           WarpEnsureOn,
			BackupBeforeChange: false,
			PruneAfterSuccess:  true,
			OpenPanelOnSuccess: false,
		},
	}
	data, err := json.Marshal(unsafe)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	app := &App{}
	app.loadLanguage()
	if app.lang != LangEN {
		t.Fatalf("valid language should still load, got %q", app.lang)
	}
	if app.installPrefs != defaultInstallPreferences() {
		t.Fatalf("unsafe install preferences must be replaced by defaults: %#v", app.installPrefs)
	}
}

func TestToolkitUninstallAcceptsOnlyBothManagedLaunchers(t *testing.T) {
	command := toolkitUninstallCommand()
	for _, required := range []string{
		"/opt/text-node-assistant-current/linux/13-maintenance-menu.sh",
		"exec /usr/local/sbin/text-node \"$@\"",
		"REFUSED_UNMANAGED_LAUNCHER",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("uninstall command is missing launcher ownership guard %q", required)
		}
	}
}
