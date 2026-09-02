package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCredentialPolicyBlankPreservesOnlyAfterReadOnlyCompleteDetection(t *testing.T) {
	complete := CredentialReadiness{
		VPSUserPresent:       true,
		VPSPasswordPresent:   true,
		PanelUserPresent:      true,
		PanelPasswordPresent:  true,
		Complete:              true,
		Source:                "handoff",
	}
	app := &App{
		reader:             bufio.NewReader(strings.NewReader("\n")),
		lang:               LangEN,
		credentialReadiness: complete,
	}
	mode, err := app.chooseCredentialMode("VPS login", "VPS login", true)
	if err != nil {
		t.Fatalf("complete readiness should allow a blank preserve shortcut: %v", err)
	}
	if mode != CredentialPreserve {
		t.Fatalf("blank input selected %q, want preserve", mode)
	}

	unknown := &App{
		reader: bufio.NewReader(strings.NewReader("\n")),
		lang:   LangEN,
	}
	if _, err := unknown.chooseCredentialMode("VPS login", "VPS login", true); err == nil {
		t.Fatal("blank input must remain invalid when readiness is unknown")
	}
	if !unknown.inputClosed {
		t.Fatal("EOF after the rejected blank input should stop the prompt loop")
	}
}

func TestRandomOneRunInputPathIsBoundedAndUnique(t *testing.T) {
	first, err := randomOneRunInputPath()
	if err != nil {
		t.Fatal(err)
	}
	second, err := randomOneRunInputPath()
	if err != nil {
		t.Fatal(err)
	}
	const prefix = "/tmp/proxy-node-assistant-auto-input-"
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

func TestParseExistingSS2022Port(t *testing.T) {
	tests := []struct {
		name    string
		output  string
		want    int
		wantErr bool
	}{
		{name: "formal", output: "noise\nTNA_EXISTING_SS2022_PORT=32443\n", want: 32443},
		{name: "legacy trial", output: "TNA_EXISTING_SS2022_PORT=30443\n", want: 30443},
		{name: "absent", output: "TNA_EXISTING_SS2022_PORT=0\n", want: 0},
		{name: "missing marker", output: "", wantErr: true},
		{name: "invalid", output: "TNA_EXISTING_SS2022_PORT=443\n", wantErr: true},
		{name: "duplicate", output: "TNA_EXISTING_SS2022_PORT=32443\nTNA_EXISTING_SS2022_PORT=32443\n", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, present, err := parseExistingSS2022Port(test.output)
			if test.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got port=%d present=%v", got, present)
				}
				return
			}
			if err != nil || !present || got != test.want {
				t.Fatalf("got port=%d present=%v err=%v, want %d", got, present, err, test.want)
			}
		})
	}
}

func TestInstallEnvironmentCarriesOnlyModesPortsAndRandomInput(t *testing.T) {
	app := &App{lang: LangZH}
	plan := validGrayPlan()
	plan.Preferences.RouteMode = RouteDual
	plan.Orange = RouteIdentity{Domain: "cdn.example.com", Email: "cdn-ops@example.com"}
	plan.Credentials = CredentialPlan{
		VPSMode:       CredentialCustom,
		VPSPassword:   "vps-secret-not-in-command",
		PanelMode:     CredentialCustom,
		PanelAccount:  "operator_1",
		PanelPassword: "panel-secret-not-in-command",
	}
	environment := app.installEnvironment(Connection{User: "root"}, plan, "/tmp/proxy-node-assistant-auto-input-001122", "1")
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
		"PNA_SS2022_PORT='32443'",
		"TNA_VPS_PASSWORD_MODE='custom'",
		"TNA_PANEL_CREDENTIAL_MODE='custom'",
		"TNA_AUTO_INPUT='/tmp/proxy-node-assistant-auto-input-001122'",
	} {
		if !strings.Contains(environment, required) {
			t.Fatalf("install environment is missing %q: %s", required, environment)
		}
	}
	for _, secretOrIdentity := range []string{plan.Gray.Domain, plan.Gray.Email, plan.Orange.Domain, plan.Orange.Email, plan.Credentials.VPSPassword, plan.Credentials.PanelPassword, plan.Credentials.PanelAccount} {
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
		"/opt/proxy-node-assistant-current/linux/13-maintenance-menu.sh",
		// The legacy launcher is only accepted when it forwards to the
		// managed ProxyNodeAssistant launcher.
		"exec /usr/local/sbin/proxy-node \"$@\"",
		"REFUSED_UNMANAGED_LAUNCHER",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("uninstall command is missing launcher ownership guard %q", required)
		}
	}
}
