package main

import (
	"strings"
	"testing"
)

func TestCompleteHandoffPreservesLegacyBytesAndProtocolAliases(t *testing.T) {
	legacy := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=fixture",
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=vps-secret",
		"PANEL_USERNAME=panel-admin",
		"PANEL_PASSWORD=panel-secret",
		"REALITY_CLIENT_1_LINK=vless://11111111-1111-4111-8111-111111111111@example.com:443",
		"REALITY_CLIENT_1_SUB_ID=client-one",
		"FUTURE_UNKNOWN_FIELD=preserve-me",
		handoffEnd,
	}, "\n")
	validated, err := validateHandoff(legacy)
	if err != nil {
		t.Fatal(err)
	}
	complete, err := appendCompleteHandoff(validated, map[string]string{
		"VLESS_LINK":       "vless://11111111-1111-4111-8111-111111111111@example.com:443",
		"SUBSCRIPTION_URL": "https://example.com/sub/client-one",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(complete, validated) || complete[:len(validated)] != validated {
		t.Fatal("complete handoff did not preserve the validated legacy prefix")
	}
	for _, want := range []string{
		"FUTURE_UNKNOWN_FIELD=preserve-me",
		"VLESS_LINK=vless://11111111-1111-4111-8111-111111111111@example.com:443",
		"SUBSCRIPTION_URL=https://example.com/sub/client-one",
		completeHandoffHeader,
		completeHandoffFooter,
	} {
		if !strings.Contains(complete, want) {
			t.Fatalf("complete handoff is missing %q", want)
		}
	}
	retiredVisibleHeader := "TNA COMPLETE HANDOFF " + "v0.9.5"
	if strings.Contains(complete, retiredVisibleHeader) {
		t.Fatal("complete handoff still exposes the retired v0.9.5 visible header")
	}
}

func TestCompleteHandoffCanonicalizesRetiredPresentationState(t *testing.T) {
	legacy := strings.Join([]string{
		"__PNA_HANDOFF_BEGIN__",
		"HANDOFF_RUN_STARTED=legacy-run",
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=vps-secret",
		"PANEL_USERNAME=operator",
		"PANEL_PASSWORD=panel-secret",
		"PNA_VERSION=0.9.5",
		"V095_CDN_STATUS=OLD_VALUE",
		"PRIVATE_DRIVE_MODE=copyparty",
		"DRIVE_ADMIN_USERNAME=old-admin",
		"CURRENT_DEVICE_ID=old-device",
		"CONTROLLER_ACTIVE_COUNT=1",
		"FUTURE_UNKNOWN_FIELD=preserve-me",
		"===== " + "TNA COMPLETE HANDOFF v0.9.5" + " =====",
		"===== END " + "TNA COMPLETE HANDOFF v0.9.5" + " =====",
		"__PNA_HANDOFF_END__",
	}, "\n")
	validated, err := validateHandoff(legacy)
	if err != nil {
		t.Fatal(err)
	}
	complete, err := appendCompleteHandoff(validated, map[string]string{
		"PNA_VERSION":         "1.0.0",
		"V095_CDN_STATUS":     "NOT_CONFIGURED",
		"V095_PHASE_STATUS":   "DIRECT_COMPATIBILITY_BASELINE",
		"FORM_VPS_ACCOUNT":    "root",
		"FORM_VPS_PASSWORD":   "vps-secret",
		"FORM_PANEL_ACCOUNT":  "operator",
		"FORM_PANEL_PASSWORD": "panel-secret",
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(complete, "TNA COMPLETE HANDOFF "+"v0.9.5") ||
		strings.Contains(complete, "PRIVATE_DRIVE_") ||
		strings.Contains(complete, "DRIVE_ADMIN_") ||
		strings.Contains(complete, "CURRENT_DEVICE_ID=") ||
		strings.Contains(complete, "CONTROLLER_ACTIVE_COUNT=") ||
		strings.Contains(complete, "VPS_LOGIN_USER=") ||
		strings.Contains(complete, "VPS_LOGIN_PASSWORD=") ||
		strings.Contains(complete, "PANEL_USERNAME=") {
		t.Fatalf("retired handoff state leaked into canonical output:\n%s", complete)
	}
	if strings.Count(complete, completeHandoffHeader) != 1 || strings.Count(complete, completeHandoffFooter) != 1 {
		t.Fatalf("expected exactly one canonical wrapper:\n%s", complete)
	}
	if !strings.Contains(complete, "FUTURE_UNKNOWN_FIELD=preserve-me") {
		t.Fatal("ordinary unknown handoff field was discarded")
	}
	if !strings.Contains(complete, "V095_CDN_STATUS=NOT_CONFIGURED") || !strings.Contains(complete, "PNA_VERSION=1.0.0") {
		t.Fatalf("current regenerated fields are missing:\n%s", complete)
	}
	if got := strings.Count(complete, "VPS_ACCOUNT=root\n"); got != 1 {
		t.Fatalf("expected exactly one canonical VPS account, got %d:\n%s", got, complete)
	}
	if got := strings.Count(complete, "PANEL_PASSWORD=panel-secret\n"); got != 1 {
		t.Fatalf("expected exactly one canonical panel password, got %d:\n%s", got, complete)
	}
}

func TestCompleteHandoffCanonicalizesLegacyCDNFragmentAndKeepsRawQuery(t *testing.T) {
	legacyLink := "vless://11111111-1111-4111-8111-111111111111@edge.example.com:8443?type=xhttp&security=tls&sni=edge.example.com&host=edge.example.com&path=%2F0123456789abcdef0123456789abcdef%2F&x_padding_bytes=100-1000&extra=%7B%22mode%22%3A%22packet-up%22%7D#TNA-CDN-XHTTP-ORANGE"
	legacy := strings.Join([]string{
		"HANDOFF_RUN_STARTED=legacy-cdn",
		"CDN_XHTTP_LINK=" + legacyLink,
		"XHTTP_LINK=" + legacyLink,
	}, "\n")
	complete, err := appendCompleteHandoff(legacy, map[string]string{
		"CDN_XHTTP_LINK":      legacyLink,
		"XHTTP_LINK":          legacyLink,
		"FORM_VPS_ACCOUNT":    "root",
		"FORM_VPS_PASSWORD":   "vps-secret",
		"FORM_PANEL_ACCOUNT":  "operator",
		"FORM_PANEL_PASSWORD": "panel-secret",
	})
	if err != nil {
		t.Fatalf("legacy CDN handoff was rejected: %v", err)
	}
	if strings.Contains(complete, "#TNA-CDN-") {
		t.Fatalf("legacy CDN fragment was re-emitted:\n%s", complete)
	}
	if !strings.Contains(complete, "#PNA-CDN-XHTTP-ORANGE") {
		t.Fatalf("canonical CDN fragment is missing:\n%s", complete)
	}
	for _, optional := range []string{"x_padding_bytes=100-1000", "extra=%7B%22mode%22%3A%22packet-up%22%7D"} {
		if !strings.Contains(complete, optional) {
			t.Fatalf("canonical handoff dropped optional query %q:\n%s", optional, complete)
		}
	}
	if strings.Contains(complete, "\nXHTTP_LINK=") {
		t.Fatalf("legacy XHTTP alias remained visible:\n%s", complete)
	}
	if got := strings.Count(complete, "CDN_XHTTP_LINK="); got != 1 {
		t.Fatalf("expected one canonical CDN link after alias collapse, got %d:\n%s", got, complete)
	}
}

func TestCompleteHandoffRegeneratesKnownProtocolRowsInsteadOfKeepingStaleCopies(t *testing.T) {
	legacy := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=old-run",
		"REALITY_CLIENT_1_LINK=vless://11111111-1111-4111-8111-111111111111@old.example:443",
		"SUBSCRIPTION_URL=https://old.example/sub/old",
		"SS2022_PORT=30443",
		"SS2022_LINK=ss://old@example:30443#old",
		"FUTURE_UNKNOWN_FIELD=keep-this",
		handoffEnd,
	}, "\n")
	currentReality := "vless://22222222-2222-4222-8222-222222222222@new.example:443"
	currentSubscription := "https://new.example/sub/current"
	currentSS := "ss://new@example:32443#current"
	complete, err := appendCompleteHandoff(legacy, map[string]string{
		"REALITY_CLIENT_1_LINK": currentReality,
		"SUBSCRIPTION_URL":      currentSubscription,
		"SS2022_PORT":           "32443",
		"SS2022_LINK":           currentSS,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, stale := range []string{
		"REALITY_CLIENT_1_LINK=vless://11111111-1111-4111-8111-111111111111@old.example:443",
		"SUBSCRIPTION_URL=https://old.example/sub/old",
		"SS2022_PORT=30443",
		"SS2022_LINK=ss://old@example:30443#old",
	} {
		if strings.Contains(complete, stale) {
			t.Fatalf("stale protocol row survived canonicalization: %s\n%s", stale, complete)
		}
	}
	for _, current := range []string{
		"REALITY_CLIENT_1_LINK=" + currentReality,
		"SUBSCRIPTION_URL=" + currentSubscription,
		"SS2022_PORT=32443",
		"SS2022_LINK=" + currentSS,
	} {
		if got := strings.Count(complete, current); got != 1 {
			t.Fatalf("expected one regenerated row %q, got %d:\n%s", current, got, complete)
		}
	}
	if !strings.Contains(complete, "FUTURE_UNKNOWN_FIELD=keep-this") {
		t.Fatal("unknown forward-compatible field was discarded")
	}
}

func TestValidateHandoffAcceptsV095MarkerAndXHTTPOnlyPayload(t *testing.T) {
	// v0.9.5 emitted TNA markers.  An in-place upgrade must accept that
	// handoff even when it contains no Reality fields (for example an
	// XHTTP-only node).
	legacy := strings.Join([]string{
		"__TNA_HANDOFF_BEGIN__",
		"HANDOFF_RUN_STARTED=legacy-fixture",
		"CDN_XHTTP_LINK=vless://11111111-1111-4111-8111-111111111111@edge.example.com:8443?type=xhttp",
		"__TNA_HANDOFF_END__",
	}, "\n")
	payload, err := validateHandoff(legacy)
	if err != nil {
		t.Fatalf("legacy XHTTP-only handoff was rejected: %v", err)
	}
	if !strings.Contains(payload, "CDN_XHTTP_LINK=") {
		t.Fatal("validated payload lost the XHTTP link")
	}
}

func TestValidateHandoffAcceptsSubscriptionOnlyPayload(t *testing.T) {
	input := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=subscription-fixture",
		"REALITY_CLIENT_1_SUBSCRIPTION_URL=https://edge.example.com/sub/client-one",
		handoffEnd,
	}, "\n")
	if _, err := validateHandoff(input); err != nil {
		t.Fatalf("subscription-only handoff was rejected: %v", err)
	}
}

func TestValidateHandoffAcceptsLegacyCredentialAliasOnlyPayload(t *testing.T) {
	input := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=legacy-alias-fixture",
		"XUI_USERNAME=legacy-panel",
		handoffEnd,
	}, "\n")
	if _, err := validateHandoff(input); err != nil {
		t.Fatalf("legacy alias-only handoff was rejected: %v", err)
	}
}

func TestCredentialReadinessParserIsPresenceOnly(t *testing.T) {
	complete := strings.Join([]string{
		"noise",
		credentialReadinessBegin,
		"VPS_LOGIN_USER_PRESENT=1",
		"VPS_LOGIN_PASSWORD_PRESENT=1",
		"PANEL_USERNAME_PRESENT=1",
		"PANEL_PASSWORD_PRESENT=1",
		"COMPLETE=1",
		"SOURCE=handoff-archive",
		credentialReadinessEnd,
	}, "\n")
	readiness, err := parseCredentialReadiness(complete)
	if err != nil || !readiness.complete() || readiness.Source != "handoff-archive" {
		t.Fatalf("valid complete readiness rejected: %#v %v", readiness, err)
	}

	incomplete := strings.Join([]string{
		credentialReadinessBegin,
		"VPS_LOGIN_USER_PRESENT=1",
		"VPS_LOGIN_PASSWORD_PRESENT=0",
		"PANEL_USERNAME_PRESENT=1",
		"PANEL_PASSWORD_PRESENT=1",
		"COMPLETE=0",
		credentialReadinessEnd,
	}, "\n")
	readiness, err = parseCredentialReadiness(incomplete)
	if err != nil || readiness.complete() || readiness.VPSPasswordPresent {
		t.Fatalf("valid incomplete readiness was not preserved as incomplete: %#v %v", readiness, err)
	}

	for _, malformed := range []string{
		strings.Replace(complete, "COMPLETE=1", "COMPLETE=2", 1),
		strings.Replace(complete, "PANEL_PASSWORD_PRESENT=1", "PANEL_PASSWORD=secret", 1),
		strings.Replace(complete, "SOURCE=handoff-archive", "SOURCE=bad value", 1),
		strings.Replace(complete, "COMPLETE=1", "COMPLETE=0", 1),
	} {
		if _, err := parseCredentialReadiness(malformed); err == nil {
			t.Fatalf("malformed readiness was accepted: %q", malformed)
		}
	}
}

func TestValidateHandoffAcceptsProtectedStoreTransportMarker(t *testing.T) {
	// A failed run may leave only CURRENT-LOGIN-CREDENTIALS.env.  The
	// exporter adds a non-secret transport marker so this store-only payload
	// still passes the structural handoff gate and can be rendered by the
	// complete formatter.
	input := strings.Join([]string{
		handoffBegin,
		"HANDOFF_RUN_STARTED=read-only-export",
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=retained-vps",
		"PANEL_USERNAME=operator",
		"PANEL_PASSWORD=retained-panel",
		handoffEnd,
	}, "\n")
	if _, err := validateHandoff(input); err != nil {
		t.Fatalf("store-only transport handoff was rejected: %v", err)
	}
}

func TestExtractMarkedBlockDoesNotStopAtNestedSameMarkers(t *testing.T) {
	input := strings.Join([]string{
		"noise",
		handoffBegin,
		"HANDOFF_RUN_STARTED=outer",
		handoffBegin,
		"VPS_LOGIN_USER=root",
		handoffEnd,
		"SS2022_PORT=32443",
		handoffEnd,
		"tail",
	}, "\n")
	payload, err := extractMarkedBlock(input, handoffBegin, handoffEnd)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(payload, "VPS_LOGIN_USER=root") || !strings.Contains(payload, "SS2022_PORT=32443") {
		t.Fatalf("nested marker payload was truncated: %q", payload)
	}
}

func TestExtractMarkedBlockRejectsUnclosedNestedMarker(t *testing.T) {
	input := strings.Join([]string{handoffBegin, "HANDOFF_RUN_STARTED=outer", handoffBegin, "VPS_LOGIN_USER=root", handoffEnd}, "\n")
	if _, err := extractMarkedBlock(input, handoffBegin, handoffEnd); err == nil {
		t.Fatal("unclosed nested marker was accepted")
	}
}

func TestLoginCredentialFormRejectsPlaceholders(t *testing.T) {
	base := strings.Join([]string{
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=vps-secret",
		"PANEL_USERNAME=panel-admin",
		"PANEL_PASSWORD=panel-secret",
	}, "\n")
	if fields, err := loginCredentialFormFields(base); err != nil || fields["FORM_VPS_ACCOUNT"] != "root" {
		t.Fatalf("valid login fields rejected: %#v %v", fields, err)
	}
	for _, mutation := range []string{
		strings.Replace(base, "PANEL_PASSWORD=panel-secret", "PANEL_PASSWORD=UNKNOWN_NOT_RECOVERABLE", 1),
		strings.Replace(base, "VPS_LOGIN_PASSWORD=vps-secret", "VPS_LOGIN_PASSWORD=NOT_RETAINED_BY_APPLICATION", 1),
		strings.Replace(base, "PANEL_USERNAME=panel-admin", "", 1),
	} {
		if _, err := loginCredentialFormFields(mutation); err == nil {
			t.Fatalf("placeholder/incomplete login fields were accepted: %q", mutation)
		}
	}
}

func TestLoginCredentialFormRecoversUsableValueAfterArchivedPlaceholder(t *testing.T) {
	input := strings.Join([]string{
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=UNKNOWN_NOT_RECOVERABLE",
		"VPS_LOGIN_PASSWORD=archived-real-password",
		"PANEL_USERNAME=panel-admin",
		"PANEL_PASSWORD=NOT_RETAINED_BY_APPLICATION",
		"PANEL_PASSWORD=archived-panel-password",
	}, "\n")
	fields, err := loginCredentialFormFields(input)
	if err != nil {
		t.Fatalf("valid archived credentials were not recovered: %v", err)
	}
	if fields["FORM_VPS_PASSWORD"] != "archived-real-password" || fields["FORM_PANEL_PASSWORD"] != "archived-panel-password" {
		t.Fatalf("unexpected recovered credentials: %#v", fields)
	}
}

func TestLoginCredentialFormPreservesCustomCredentialEdgeSpaces(t *testing.T) {
	input := strings.Join([]string{
		"VPS_LOGIN_USER=root",
		"VPS_LOGIN_PASSWORD=  vps secret  ",
		"PANEL_USERNAME=panel-admin",
		"PANEL_PASSWORD=\t panel secret \t",
	}, "\n")
	fields, err := loginCredentialFormFields(input)
	if err != nil {
		t.Fatalf("custom credentials with edge spaces were rejected: %v", err)
	}
	if got, want := fields["FORM_VPS_PASSWORD"], "  vps secret  "; got != want {
		t.Fatalf("VPS password whitespace was not preserved: got %q want %q", got, want)
	}
	if got, want := fields["FORM_PANEL_PASSWORD"], "\t panel secret \t"; got != want {
		t.Fatalf("panel password whitespace was not preserved: got %q want %q", got, want)
	}
}

func TestLoginCredentialFormAcceptsCanonicalAliases(t *testing.T) {
	input := strings.Join([]string{
		"VPS_ACCOUNT=canonical-root",
		"VPS_PASSWORD=canonical-vps-password",
		"PANEL_ACCOUNT=canonical-panel",
		"PANEL_PASSWORD=canonical-panel-password",
	}, "\n")
	fields, err := loginCredentialFormFields(input)
	if err != nil {
		t.Fatalf("canonical credential aliases were rejected: %v", err)
	}
	if fields["FORM_VPS_ACCOUNT"] != "canonical-root" || fields["FORM_PANEL_ACCOUNT"] != "canonical-panel" {
		t.Fatalf("unexpected canonical credential fields: %#v", fields)
	}
}

func TestLoginCredentialFormAcceptsLegacyXUIAliases(t *testing.T) {
	input := strings.Join([]string{
		"VPS_ACCOUNT=legacy-root",
		"VPS_PASSWORD=legacy-vps-password",
		"XUI_USERNAME=legacy-panel",
		"XUI_PASSWORD=legacy-panel-password",
	}, "\n")
	fields, err := loginCredentialFormFields(input)
	if err != nil {
		t.Fatalf("legacy XUI credential aliases were rejected: %v", err)
	}
	if fields["FORM_VPS_ACCOUNT"] != "legacy-root" || fields["FORM_PANEL_ACCOUNT"] != "legacy-panel" {
		t.Fatalf("unexpected legacy alias fields: %#v", fields)
	}
}

func TestHandoffProtocolFallbackIgnoresMalformedCurrentValues(t *testing.T) {
	// The exporter concatenates archived runs before the current run.  A
	// failed rotation may leave the current file with placeholders or invalid
	// ports/links; those must not hide a usable archived protocol profile.
	raw := strings.Join([]string{
		"REALITY_CLIENT_1_UUID=11111111-1111-4111-8111-111111111111",
		"REALITY_PUBLIC_KEY=archived-public-key",
		"REALITY_SERVER_NAME=www.example.com",
		"REALITY_SHORT_ID=0123456789abcdef",
		"REALITY_SERVER_PORT=30443",
		"REALITY_TEST_LINK=vless://11111111-1111-4111-8111-111111111111@example.com:30443?security=reality",
		"CDN_XHTTP_UUID=22222222-2222-4222-8222-222222222222",
		"CDN_XHTTP_DOMAIN=edge.example.com",
		"CDN_XHTTP_PATH=/0123456789abcdef0123456789abcdef/",
		"CDN_XHTTP_PUBLIC_PORT=8443",
		"SS2022_SERVER_ADDRESS=192.0.2.10",
		"SS2022_PORT=32443",
		"SS2022_METHOD=2022-blake3-aes-256-gcm",
		"SS2022_PASSWORD=archived-password",
		"REALITY_PUBLIC_KEY=UNKNOWN_NOT_RETAINED",
		"REALITY_SERVER_PORT=not-a-port",
		"REALITY_TEST_LINK=not-a-link",
		"CDN_XHTTP_DOMAIN=UNKNOWN_NOT_RETAINED",
		"CDN_XHTTP_PUBLIC_PORT=70000",
		"SS2022_PASSWORD=NOT_RETAINED_BY_APPLICATION",
	}, "\n")
	values := parseKV(raw)
	mergeHandoffProtocolFallbacks(raw, values)
	if values["REALITY_PUBLIC_KEY"] != "archived-public-key" || values["REALITY_SERVER_PORT"] != "30443" || values["REALITY_TEST_LINK"] == "not-a-link" {
		t.Fatalf("malformed current Reality values were not recovered: %#v", values)
	}
	if values["CDN_XHTTP_DOMAIN"] != "edge.example.com" || values["CDN_XHTTP_PUBLIC_PORT"] != "8443" {
		t.Fatalf("malformed current XHTTP values were not recovered: %#v", values)
	}
	if values["SS2022_PASSWORD"] != "archived-password" {
		t.Fatalf("malformed current SS2022 password was not recovered: %#v", values)
	}
}

func TestProtocolHandoffDerivation(t *testing.T) {
	values := map[string]string{
		"CDN_XHTTP_UUID":        "11111111-1111-4111-8111-111111111111",
		"CDN_XHTTP_DOMAIN":      "edge.example.com",
		"CDN_XHTTP_PATH":        "/0123456789abcdef/",
		"CDN_XHTTP_PUBLIC_PORT": "8443",
		"CDN_XHTTP_SUB_ID":      "xhttp-sub",
	}
	link := deriveXHTTPHandoffLink(values)
	if !strings.HasPrefix(link, "vless://") || !strings.Contains(link, "edge.example.com:8443") || !strings.Contains(link, "type=xhttp") {
		t.Fatalf("unexpected derived XHTTP link: %s", link)
	}
	if strings.Contains(link, "TNA-") || !strings.HasSuffix(link, "#"+cdnXHTTPOrangeLabel) {
		t.Fatalf("derived XHTTP link still carries a legacy label: %s", link)
	}
	if got := subscriptionHandoffURL(values); got != "https://edge.example.com/sub/xhttp-sub" {
		t.Fatalf("unexpected derived subscription URL: %s", got)
	}
}

func TestRealityAndSS2022HandoffDerivation(t *testing.T) {
	reality := map[string]string{
		"REALITY_CLIENT_1_UUID": "11111111-1111-4111-8111-111111111111",
		"PUBLIC_IP_AT_HANDOFF":  "192.0.2.10",
		"REALITY_PUBLIC_KEY":    "public-key",
		"REALITY_SERVER_NAME":   "www.example.com",
		"REALITY_SHORT_ID":      "0123456789abcdef",
	}
	link := deriveRealityHandoffLink(reality)
	if !strings.HasPrefix(link, "vless://") || !strings.Contains(link, "192.0.2.10:443") || !strings.Contains(link, "security=reality") {
		t.Fatalf("unexpected derived Reality link: %s", link)
	}
	ss := map[string]string{
		"SS2022_SERVER_ADDRESS": "192.0.2.10",
		"SS2022_PORT":           "32443",
		"SS2022_METHOD":         "2022-blake3-aes-256-gcm",
		"SS2022_PASSWORD":       "test-password",
	}
	ssLink := deriveSS2022HandoffLink(ss)
	if !strings.HasPrefix(ssLink, "ss://") || !strings.Contains(ssLink, "@192.0.2.10:32443") {
		t.Fatalf("unexpected derived SS2022 link: %s", ssLink)
	}
	if got := deriveSS2022HandoffLink(map[string]string{"SS2022_SERVER_ADDRESS": "192.0.2.10", "SS2022_PORT": "32443", "SS2022_METHOD": "2022-blake3-aes-256-gcm", "SS2022_PASSWORD": "UNKNOWN_NOT_RETAINED"}); got != "" {
		t.Fatalf("placeholder SS2022 password produced a link: %s", got)
	}
}

func TestRealityHandoffDerivationUsesActualExportedPortAndLegacyAliases(t *testing.T) {
	values := map[string]string{
		"REALITY_TEST_UUID":          "11111111-1111-4111-8111-111111111111",
		"PUBLIC_IP_AT_HANDOFF":       "192.0.2.10",
		"REALITY_PUBLIC_KEY":         "public-key",
		"REALITY_SERVER_NAME":        "www.example.com",
		"REALITY_GENERATED_SHORT_ID": "0123456789abcdef",
		"REALITY_SERVER_PORT":        "30443",
	}
	link := deriveRealityHandoffLink(values)
	if !strings.Contains(link, "192.0.2.10:30443") {
		t.Fatalf("legacy Reality fields did not preserve actual port: %s", link)
	}
}

func TestXHTTPHandoffDerivationRejectsInvalidPortAndAcceptsLegacyDomainAlias(t *testing.T) {
	values := map[string]string{
		"XHTTP_UUID":          "11111111-1111-4111-8111-111111111111",
		"XHTTP_PUBLIC_DOMAIN": "edge.example.com",
		"XHTTP_PATH":          "/0123456789abcdef0123456789abcdef/",
		"XHTTP_PUBLIC_PORT":   "8443",
	}
	if link := deriveXHTTPHandoffLink(values); !strings.Contains(link, "edge.example.com:8443") {
		t.Fatalf("legacy XHTTP aliases were not recovered: %s", link)
	}
	values["XHTTP_PUBLIC_PORT"] = "70000"
	if link := deriveXHTTPHandoffLink(values); link != "" {
		t.Fatalf("invalid XHTTP port produced a link: %s", link)
	}
}

func TestDeploymentStateCompatibilityValues(t *testing.T) {
	for _, value := range []string{"direct-reality", "cdn-xhttp-tls", "dual-hot-switch"} {
		if _, err := parseDeploymentMode(value); err != nil {
			t.Fatalf("valid deployment mode %q rejected: %v", value, err)
		}
	}
	if canTransitionDeploymentState(StateDualInstalledActiveDirect, StateActiveCDN) {
		t.Fatal("direct-to-CDN transition must retain staged verification")
	}
}
