package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func validCDNPlan(mode RouteMode) InstallPlan {
	plan := validGrayPlan()
	plan.Preferences.RouteMode = mode
	plan.Orange = RouteIdentity{Domain: "orange.example.net", Email: "cdn@example.net"}
	if mode == RouteOrange {
		plan.Gray = RouteIdentity{}
	}
	return plan
}

func TestPrepareCDNPrerequisitesKeepAndGrayAreNoOps(t *testing.T) {
	original := cdnLookupIP
	defer func() { cdnLookupIP = original }()
	called := false
	cdnLookupIP = func(string) ([]net.IP, error) { called = true; return nil, errors.New("unexpected") }
	app := &App{}
	for _, mode := range []RouteMode{RouteKeep, RouteGray} {
		plan := defaultInstallPlan()
		plan.Preferences.RouteMode = mode
		if err := app.prepareCDNPrerequisites(Connection{}, plan, "not-an-ip"); err != nil {
			t.Fatalf("%s must be a CDN prerequisite no-op: %v", mode, err)
		}
	}
	if called {
		t.Fatal("keep/gray unexpectedly performed an orange DNS lookup")
	}
}

func TestPrepareCDNPrerequisitesRejectsOrangeOriginLeak(t *testing.T) {
	original := cdnLookupIP
	defer func() { cdnLookupIP = original }()
	cdnLookupIP = func(string) ([]net.IP, error) { return []net.IP{net.ParseIP("192.0.2.10")}, nil }
	err := (&App{}).prepareCDNPrerequisites(Connection{}, validCDNPlan(RouteOrange), "192.0.2.10")
	if err == nil || !strings.Contains(err.Error(), "Cloudflare") {
		t.Fatalf("expected an origin-leak error, got %v", err)
	}
}

func TestPrepareCDNPrerequisitesAcceptsProxiedOrange(t *testing.T) {
	original := cdnLookupIP
	defer func() { cdnLookupIP = original }()
	cdnLookupIP = func(string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("198.51.100.20"), net.ParseIP("2001:db8::20")}, nil
	}
	if err := (&App{}).prepareCDNPrerequisites(Connection{}, validCDNPlan(RouteDual), "192.0.2.10"); err != nil {
		t.Fatalf("proxied orange route should pass local prerequisites: %v", err)
	}
}

func TestCDNRouteActionsCoverEveryMode(t *testing.T) {
	tests := []struct {
		mode RouteMode
		want string
	}{
		{RouteKeep, ""},
		{RouteGray, "--to-gray 'cover.example.com'"},
		{RouteOrange, "staged"},
		{RouteDual, "staged"},
	}
	for _, test := range tests {
		got, err := cdnRouteAction(test.mode, "cover.example.com")
		if err != nil || !strings.Contains(got, test.want) {
			t.Fatalf("route %s: got %q, %v; want substring %q", test.mode, got, err, test.want)
		}
	}
	if _, err := cdnRouteAction(RouteMode("mystery"), "cover.example.com"); err == nil {
		t.Fatal("unknown route mode must fail closed")
	}
}

func TestBuildCDNRouteInputCopyCommandUsesOnlyRootOneRunInput(t *testing.T) {
	command, err := buildCDNRouteInputCopyCommand(
		"/tmp/text-node-assistant-auto-input-001122",
		cdnRouteInputDir+"/cdn-route-aabbcc.env",
		RouteOrange,
		"192.0.2.10",
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"TNA_CDN_ROUTE_INPUT_VERSION=1",
		"ORANGE_DOMAIN_B64",
		"ORANGE_EMAIL_B64",
		"GRAY_DOMAIN_B64",
		"stat -c",
		"0:600",
		"install -m 600",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("root-only input copy is missing %q: %s", required, command)
		}
	}
	for _, forbidden := range []string{"orange.example.net", "cdn@example.net", "33285"} {
		if strings.Contains(command, forbidden) {
			t.Fatalf("input copy command leaked or used forbidden value %q", forbidden)
		}
	}
	if _, err := buildCDNRouteInputCopyCommand("/tmp/not-owned", cdnRouteInputDir+"/cdn-route-a.env", RouteOrange, "192.0.2.10"); err == nil {
		t.Fatal("unexpected source path must be rejected")
	}
}

func TestValidateCDNShareLinkForcesOrange8443TLSXHTTP(t *testing.T) {
	good := "vless://12345678-1234-1234-1234-123456789abc@orange.example.net:8443?type=xhttp&security=tls&sni=orange.example.net&host=orange.example.net&path=%2F0123456789abcdef0123456789abcdef%2F#TNA-CDN-XHTTP-ORANGE"
	if err := validateCDNShareLink(good, "orange.example.net"); err != nil {
		t.Fatalf("known-good CDN link rejected: %v", err)
	}
	bad := []string{
		strings.Replace(good, ":8443", ":33285", 1),
		strings.Replace(good, "orange.example.net:8443", "cover.example.com:8443", 1),
		strings.Replace(good, "security=tls", "security=none", 1),
		strings.Replace(good, "type=xhttp", "type=tcp", 1),
	}
	for _, value := range bad {
		if err := validateCDNShareLink(value, "orange.example.net"); err == nil {
			t.Fatalf("invalid CDN link unexpectedly accepted: %s", value)
		}
	}
}

func TestFirstVLESSLinkReadsOnlyRawOrNamedCredentialLines(t *testing.T) {
	link := "vless://12345678-1234-1234-1234-123456789abc@orange.example.net:8443?type=xhttp&security=tls&path=%2Fx%2F"
	if got := firstVLESSLink("__TNA_XHTTP_LINK_BEGIN__\nXHTTP_LINK=" + link + "\n__TNA_XHTTP_LINK_END__\n"); got != link {
		t.Fatalf("named XHTTP link was not parsed: %q", got)
	}
	if got := firstVLESSLink("diagnostic contains " + link + " but is not a handoff field\n"); got != "" {
		t.Fatalf("arbitrary diagnostic text was treated as a credential: %q", got)
	}
}

func TestValidateCDNEdgeResponseRequiresCloudflareManaged8443Proof(t *testing.T) {
	requestURL, _ := url.Parse("https://orange.example.net:8443/")
	response := &http.Response{
		StatusCode: 200,
		Header: http.Header{
			"Cf-Ray":               []string{"abc-SJC"},
			"X-Tna-Managed-Origin": []string{"cdn-xhttp-v095"},
			"X-Tna-Origin-Port":    []string{"8443"},
		},
		Request: &http.Request{URL: requestURL},
	}
	if err := validateCDNEdgeResponse(response, "orange.example.net"); err != nil {
		t.Fatalf("known-good edge proof rejected: %v", err)
	}
	response.Header.Del("Cf-Ray")
	if err := validateCDNEdgeResponse(response, "orange.example.net"); err == nil {
		t.Fatal("response without Cf-Ray must be rejected")
	}
}

type stubConn struct{}

func (stubConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (stubConn) Write(p []byte) (int, error)      { return len(p), nil }
func (stubConn) Close() error                     { return nil }
func (stubConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (stubConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (stubConn) SetDeadline(time.Time) error      { return nil }
func (stubConn) SetReadDeadline(time.Time) error  { return nil }
func (stubConn) SetWriteDeadline(time.Time) error { return nil }

func withCDNReconcileStubs(t *testing.T, mode RouteMode, failEdge bool) *[]string {
	t.Helper()
	originalCapture := cdnRootCapture
	originalPublicIP := cdnRemotePublicIP
	originalLookup := cdnLookupIP
	originalHTTP := cdnHTTPDo
	originalDial := cdnDial
	originalClientProof := cdnRequestClientProof
	t.Cleanup(func() {
		cdnRootCapture = originalCapture
		cdnRemotePublicIP = originalPublicIP
		cdnLookupIP = originalLookup
		cdnHTTPDo = originalHTTP
		cdnDial = originalDial
		cdnRequestClientProof = originalClientProof
	})
	commands := []string{}
	cdnRemotePublicIP = func(*App, Connection) (string, error) { return "192.0.2.10", nil }
	cdnLookupIP = func(string) ([]net.IP, error) { return []net.IP{net.ParseIP("198.51.100.20")}, nil }
	cdnDial = func(string, string, time.Duration) (net.Conn, error) { return nil, errors.New("blocked as intended") }
	cdnRequestClientProof = func(*App, string) error { return nil }
	cdnHTTPDo = func(request *http.Request) (*http.Response, error) {
		if failEdge {
			return nil, errors.New("edge unavailable")
		}
		return &http.Response{
			StatusCode: 200,
			Header: http.Header{
				"Cf-Ray":               []string{"abc-SJC"},
				"X-Tna-Managed-Origin": []string{"cdn-xhttp-v095"},
				"X-Tna-Origin-Port":    []string{"8443"},
			},
			Request: request,
			Body:    io.NopCloser(strings.NewReader("ok")),
		}, nil
	}
	cdnRootCapture = func(_ *App, _ Connection, command string) ProcessResult {
		commands = append(commands, command)
		switch {
		case strings.Contains(command, "--apply-input"):
			return ProcessResult{Stdout: "TNA_TOPOLOGY_STAGED=1\nCDN_EDGE_PORT=8443\n", ExitCode: 0}
		case strings.Contains(command, "04f-xhttp-cdn-api.sh link"):
			return ProcessResult{Stdout: "vless://12345678-1234-1234-1234-123456789abc@orange.example.net:8443?type=xhttp&security=tls&sni=orange.example.net&host=orange.example.net&path=%2F0123456789abcdef0123456789abcdef%2F\n", ExitCode: 0}
		case strings.Contains(command, "--confirm-client"):
			return ProcessResult{Stdout: "CDN_CLIENT_CONFIRMED=1\n", ExitCode: 0}
		case strings.Contains(command, "--finalize"):
			return ProcessResult{Stdout: "TNA_TOPOLOGY_RECONCILED=1\nTOPOLOGY_MODE=" + string(mode) + "\n", ExitCode: 0}
		case strings.Contains(command, "--rollback-pending"):
			return ProcessResult{Stdout: "TNA_TOPOLOGY_ROLLED_BACK=1\n", ExitCode: 0}
		default:
			return ProcessResult{ExitCode: 0}
		}
	}
	return &commands
}

func TestReconcileOrangeAndDualCommitOnlyAfterValidation(t *testing.T) {
	for _, mode := range []RouteMode{RouteOrange, RouteDual} {
		t.Run(string(mode), func(t *testing.T) {
			commands := withCDNReconcileStubs(t, mode, false)
			plan := validCDNPlan(mode)
			err := (&App{}).reconcileCDNRoute(Connection{}, plan, "/tmp/text-node-assistant-auto-input-aabbcc")
			if err != nil {
				t.Fatalf("%s convergence failed: %v", mode, err)
			}
			joined := strings.Join(*commands, "\n")
			stage := strings.Index(joined, "--apply-input")
			confirm := strings.Index(joined, "--confirm-client")
			finalize := strings.Index(joined, "--finalize")
			if stage < 0 || confirm < stage || finalize < confirm {
				t.Fatalf("%s did not stage, validate and finalize in order:\n%s", mode, joined)
			}
			if strings.Contains(joined, "--rollback-pending") {
				t.Fatalf("successful %s convergence unexpectedly rolled back", mode)
			}
		})
	}
}

func TestReconcileOrangeRollsBackWhenExternalEdgeValidationFails(t *testing.T) {
	commands := withCDNReconcileStubs(t, RouteOrange, true)
	err := (&App{}).reconcileCDNRoute(Connection{}, validCDNPlan(RouteOrange), "/tmp/text-node-assistant-auto-input-aabbcc")
	if err == nil || !strings.Contains(err.Error(), "edge unavailable") {
		t.Fatalf("expected edge validation failure, got %v", err)
	}
	joined := strings.Join(*commands, "\n")
	if !strings.Contains(joined, "--rollback-pending") || strings.Contains(joined, "--finalize") {
		t.Fatalf("failed orange staging did not roll back before finalization:\n%s", joined)
	}
}

func TestReconcileDoesNotTreatNothingPendingAsRollbackProof(t *testing.T) {
	commands := withCDNReconcileStubs(t, RouteOrange, true)
	baseCapture := cdnRootCapture
	cdnRootCapture = func(app *App, connection Connection, command string) ProcessResult {
		if strings.Contains(command, "--rollback-pending") {
			*commands = append(*commands, command)
			return ProcessResult{Stdout: "TNA_TOPOLOGY_ROLLBACK=NOTHING_PENDING\n", ExitCode: 0}
		}
		return baseCapture(app, connection, command)
	}
	err := (&App{}).reconcileCDNRoute(Connection{}, validCDNPlan(RouteOrange), "/tmp/text-node-assistant-auto-input-aabbcc")
	if err == nil || !strings.Contains(err.Error(), "automatic CDN rollback also failed") {
		t.Fatalf("ambiguous no-pending response was accepted as rollback proof: %v", err)
	}
}

func TestReconcileDoesNotRepeatRemoteStageTrapRollback(t *testing.T) {
	commands := withCDNReconcileStubs(t, RouteOrange, false)
	baseCapture := cdnRootCapture
	cdnRootCapture = func(app *App, connection Connection, command string) ProcessResult {
		if strings.Contains(command, "--apply-input") {
			*commands = append(*commands, command)
			return ProcessResult{
				Stderr:   "apply failed\nTNA_TOPOLOGY_ROLLED_BACK=1\n",
				ExitCode: 1,
				Err:      errors.New("remote apply failed"),
			}
		}
		return baseCapture(app, connection, command)
	}
	err := (&App{}).reconcileCDNRoute(Connection{}, validCDNPlan(RouteOrange), "/tmp/text-node-assistant-auto-input-aabbcc")
	if err == nil || !strings.Contains(err.Error(), "CDN route staging failed") {
		t.Fatalf("expected the original stage failure, got %v", err)
	}
	if strings.Contains(strings.Join(*commands, "\n"), "--rollback-pending") {
		t.Fatalf("client repeated a rollback already completed by the remote stage trap:\n%s", strings.Join(*commands, "\n"))
	}
}

func TestReconcileOrangeRequiresRealClientProofBeforeRemoteConfirmation(t *testing.T) {
	commands := withCDNReconcileStubs(t, RouteOrange, false)
	cdnRequestClientProof = func(*App, string) error { return errors.New("real browse was not confirmed") }
	err := (&App{}).reconcileCDNRoute(Connection{}, validCDNPlan(RouteOrange), "/tmp/text-node-assistant-auto-input-aabbcc")
	if err == nil || !strings.Contains(err.Error(), "real browse was not confirmed") {
		t.Fatalf("expected real-client proof failure, got %v", err)
	}
	joined := strings.Join(*commands, "\n")
	if !strings.Contains(joined, "04f-xhttp-cdn-api.sh link") || !strings.Contains(joined, "--rollback-pending") {
		t.Fatalf("proof failure did not occur after link export and roll back:\n%s", joined)
	}
	if strings.Contains(joined, "--confirm-client") || strings.Contains(joined, "--finalize") {
		t.Fatalf("remote confirmation/finalization ran without real client proof:\n%s", joined)
	}
}

func TestReconcileGrayRemovesOnlyManagedCDNRoute(t *testing.T) {
	originalCapture := cdnRootCapture
	defer func() { cdnRootCapture = originalCapture }()
	var command string
	cdnRootCapture = func(_ *App, _ Connection, value string) ProcessResult {
		command = value
		return ProcessResult{Stdout: "TNA_TOPOLOGY_RECONCILED=1\nTOPOLOGY_MODE=gray\n", ExitCode: 0}
	}
	if err := (&App{}).reconcileCDNRoute(Connection{}, validCDNPlan(RouteGray), "/tmp/ignored"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(command, "28-topology-reconcile.sh --to-gray") || !strings.Contains(command, "cover.example.com") {
		t.Fatalf("gray route used unexpected command: %s", command)
	}
}

func TestReconcileKeepIsTrueNoOp(t *testing.T) {
	originalCapture := cdnRootCapture
	defer func() { cdnRootCapture = originalCapture }()
	called := false
	cdnRootCapture = func(_ *App, _ Connection, _ string) ProcessResult { called = true; return ProcessResult{} }
	plan := defaultInstallPlan()
	plan.Preferences.RouteMode = RouteKeep
	if err := (&App{}).reconcileCDNRoute(Connection{}, plan, "not-even-a-path"); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("RouteKeep performed a remote mutation")
	}
}

func TestLeanCDNScriptsContainNoRetiredSubsystemDependency(t *testing.T) {
	files := []string{
		"04f-xhttp-cdn-api.sh", "05e-cdn-xhttp-nginx.sh", "05f-cloudflare-origin-lock.sh",
		"05g-cdn-xhttp-validate.sh", "05h-ensure-cdn-certificate.sh", "28-topology-reconcile.sh",
		"32-subscription-rewrite.py", "lib-deployment-state.sh", "lib-dns-quorum.sh",
	}
	base := filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux")
	for _, name := range files {
		data, err := os.ReadFile(filepath.Join(base, name))
		if err != nil {
			t.Fatal(err)
		}
		lower := strings.ToLower(string(data))
		for _, forbidden := range []string{
			"controller", "device-registry", "invite", "invitation", "admission",
			"drive", "copyparty", "local-admin", "private drive",
		} {
			if strings.Contains(lower, forbidden) {
				t.Fatalf("%s retains retired subsystem token %q", name, forbidden)
			}
		}
		if strings.Contains(lower, ":33285") {
			t.Fatalf("%s retains the broken public port 33285", name)
		}
	}
}

func TestSubscriptionRewriteHardFailsNon8443Metadata(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux", "32-subscription-rewrite.py"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, "if xhttp_port != 8443") || !strings.Contains(text, "XHTTP public port must be 8443") {
		t.Fatal("subscription rewriter does not fail closed on stale/random public ports")
	}
}

func TestCertificateBootstrapUsesOnlyNormalHTTP01BeforeOrigin8443(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux", "05h-ensure-cdn-certificate.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, required := range []string{"listen 80;", "cf-ray:", "certbot certonly", "PUBLIC_ACME_PREFLIGHT_FAILED"} {
		if !strings.Contains(strings.ToLower(text), strings.ToLower(required)) {
			t.Fatalf("certificate bootstrap is missing %q", required)
		}
	}
	for _, forbidden := range []string{"--prepare-public-origin", "TNA_MANAGED_ACME_ORIGIN_HTTP", "listen ${PUBLIC_IP}:8443", "05f-cloudflare-origin-lock.sh"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("certificate bootstrap still mutates the staged origin/firewall via %q", forbidden)
		}
	}
}

func TestTopologyRollbackRestoresManagedFirewallRealityAndRouteState(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("runbook", "text-node-assistant-v0.9.5", "linux", "28-topology-reconcile.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, required := range []string{
		"previous_cf_applied=1",
		"bash \"$cf_helper\" remove",
		"restore_path /etc/x-ui x-ui",
		"restore_path /etc/text-node-assistant/cloudflare cloudflare",
		"bash \"$cf_helper\" apply",
		"ROLLBACK_INCOMPLETE_TRANSACTION_PRESERVED",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("topology rollback is missing %q", required)
		}
	}
}
