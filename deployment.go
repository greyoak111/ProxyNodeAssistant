package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// DeploymentMode and DeploymentState are kept as wire-compatible values for
// handoff consumers from the v0.9.x line.  They describe route state only;
// they do not reintroduce the retired device-admission or private-drive
// features from that release.
type DeploymentMode string

const (
	DeploymentDirectReality DeploymentMode = "direct-reality"
	DeploymentCDNXHTTPTLS   DeploymentMode = "cdn-xhttp-tls"
	DeploymentDualHotSwitch DeploymentMode = "dual-hot-switch"
)

type DeploymentState string

const (
	StateActiveDirect                     DeploymentState = "ACTIVE_DIRECT"
	StateActiveCDN                        DeploymentState = "ACTIVE_CDN"
	StateCDNStaged8443                    DeploymentState = "CDN_STAGED_8443"
	StateWaitingForCloudflareManualAction DeploymentState = "WAITING_FOR_CLOUDFLARE_MANUAL_ACTION"
	StateDualInstalledActiveDirect        DeploymentState = "DUAL_INSTALLED_ACTIVE_DIRECT"
	StateDualInstalledActiveCDN           DeploymentState = "DUAL_INSTALLED_ACTIVE_CDN"
	StateSwitchToCDNStaged8443            DeploymentState = "SWITCH_TO_CDN_STAGED_8443"
	StateSwitchToCDNPort443Committing     DeploymentState = "SWITCH_TO_CDN_PORT_443_COMMITTING"
	StateSwitchToDirectStaged24443        DeploymentState = "SWITCH_TO_DIRECT_STAGED_24443"
	StateSwitchToDirectPort443Committing  DeploymentState = "SWITCH_TO_DIRECT_PORT_443_COMMITTING"
)

var handoffAppendixKeyPattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
var handoffUUIDPattern = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$`)
var handoffSubscriptionIDPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]+$`)
var loginFormKeys = []string{"FORM_VPS_ACCOUNT", "FORM_VPS_PASSWORD", "FORM_PANEL_ACCOUNT", "FORM_PANEL_PASSWORD"}

// These delimiters are part of the v1.0.0 handoff surface shown to the
// operator.  Keep them in one place so the desktop formatter cannot silently
// drift back to the retired v0.9.5 label while the Android formatter and
// clients use the current product/version identity.
const (
	completeHandoffHeader = "===== PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 ====="
	completeHandoffFooter = "===== END PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 ====="
)

func usableHandoffCredential(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return false
	}
	upper := strings.ToUpper(value)
	return !strings.HasPrefix(upper, "UNKNOWN") &&
		!strings.HasPrefix(upper, "NOT_RETAINED") && upper != "SSH_KEY_ONLY"
}

// handoffCredentialValue intentionally scans from start to finish and keeps
// the last usable value.  An interrupted v0.9.x run can leave a placeholder in
// the current file after a valid value in an archived handoff; the placeholder
// must not strand the operator during an in-place upgrade.  The optional alias
// spellings also let a v1 form be re-imported without requiring the retired
// VPS_LOGIN_/PANEL_USERNAME source keys to remain visible.
func handoffCredentialValue(raw string, keys ...string) string {
	wanted := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		wanted[strings.TrimSpace(key)] = struct{}{}
	}
	value := ""
	for _, line := range strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n") {
		name, candidate, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		if _, ok := wanted[strings.TrimSpace(name)]; !ok {
			continue
		}
		candidate = strings.TrimSpace(candidate)
		if usableHandoffCredential(candidate) {
			value = candidate
		}
	}
	return value
}

// handoffProtocolKeys is the small, typed subset for which an interrupted
// upgrade must be able to recover an archived value.  parseKV intentionally
// keeps the last occurrence of every key (that is the correct behaviour for
// ordinary run-state fields), but a failed rotation can append an empty or
// placeholder protocol value to the current handoff.  Without this second
// pass a valid archived Reality/XHTTP/SS2022 link would be hidden by that
// placeholder and the operator would be told to regenerate credentials.
var handoffProtocolKeys = map[string]struct{}{
	"COVER_DOMAIN":                      {},
	"PUBLIC_IP_AT_HANDOFF":              {},
	"VPS_PUBLIC_IP":                     {},
	"PUBLIC_IP":                         {},
	"REALITY_CLIENT_1_UUID":             {},
	"REALITY_TEST_UUID":                 {},
	"REALITY_GENERATED_UUID":            {},
	"REALITY_UUID":                      {},
	"UUID":                              {},
	"REALITY_SERVER_ADDRESS":            {},
	"REALITY_PUBLIC_KEY":                {},
	"REALITY_CLIENT_PUBLIC_KEY":         {},
	"REALITY_SERVER_NAME":               {},
	"REALITY_SNI":                       {},
	"REALITY_DEST_DOMAIN":               {},
	"REALITY_SHORT_ID":                  {},
	"REALITY_CLIENT_SHORT_ID":           {},
	"REALITY_GENERATED_SHORT_ID":        {},
	"REALITY_CLIENT_1_PORT":             {},
	"REALITY_PUBLIC_PORT":               {},
	"REALITY_SERVER_PORT":               {},
	"REALITY_PORT":                      {},
	"REALITY_TEST_PORT":                 {},
	"TEST_PORT":                         {},
	"REALITY_PRODUCTION_LINK":           {},
	"REALITY_LINK":                      {},
	"REALITY_TEST_LINK":                 {},
	"VLESS_LINK":                        {},
	"REALITY_CLIENT_1_LINK":             {},
	"CDN_XHTTP_UUID":                    {},
	"XHTTP_UUID":                        {},
	"CDN_XHTTP_DOMAIN":                  {},
	"XHTTP_PUBLIC_DOMAIN":               {},
	"XHTTP_DOMAIN":                      {},
	"CDN_XHTTP_PATH":                    {},
	"XHTTP_PATH":                        {},
	"CDN_XHTTP_PUBLIC_PORT":             {},
	"XHTTP_PUBLIC_PORT":                 {},
	"CDN_XHTTP_LINK":                    {},
	"CDN_XHTTP_STAGE_LINK":              {},
	"XHTTP_LINK":                        {},
	"CDN_XHTTP_SUB_ID":                  {},
	"XHTTP_SUB_ID":                      {},
	"SUB_ID":                            {},
	"SUBSCRIPTION_URL":                  {},
	"SUBSCRIPTION_LINK":                 {},
	"CDN_XHTTP_SUBSCRIPTION_URL":        {},
	"REALITY_CLIENT_1_SUBSCRIPTION_URL": {},
	"SS2022_SERVER_ADDRESS":             {},
	"SS2022_HOST":                       {},
	"SS2022_PORT":                       {},
	"SS2022_METHOD":                     {},
	"SS2022_PASSWORD":                   {},
	"SS2022_LINK":                       {},
}

// isHandoffProtocolKey recognizes the indexed/per-port protocol fields that
// the runbook emits in addition to the small set above.  They are still a
// closed vocabulary: an arbitrary key must not become part of the regenerated
// appendix merely because it happens to start with REALITY_/CDN_XHTTP_/SS2022_.
// Keeping this predicate next to handoffProtocolKeys is important because the
// remote exporter concatenates archived and current files; every recognized
// key is copied into the new appendix and removed from the raw prefix, which
// is what prevents an old value from remaining visible beside the current one.
func isHandoffProtocolKey(key string) bool {
	key = strings.TrimSpace(key)
	if _, ok := handoffProtocolKeys[key]; ok {
		return true
	}
	if regexp.MustCompile(`^REALITY_CLIENT_[0-9]+_(UUID|SUB_ID|PORT|REMARK|LINK|SUBSCRIPTION_URL)$`).MatchString(key) {
		return true
	}
	if regexp.MustCompile(`^REALITY_[0-9]+_(SERVER_NAME|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|REMARK)$`).MatchString(key) {
		return true
	}
	if strings.HasPrefix(key, "REALITY_") {
		return strings.HasSuffix(key, "_UUID") || strings.HasSuffix(key, "_PRIVATE_KEY") ||
			strings.HasSuffix(key, "_PUBLIC_KEY") || strings.HasSuffix(key, "_SHORT_ID") ||
			strings.HasSuffix(key, "_SUB_ID") || strings.HasSuffix(key, "_SUBSCRIPTION_URL") ||
			strings.HasSuffix(key, "_LINK") || strings.HasSuffix(key, "_PORT") ||
			strings.HasSuffix(key, "_SERVER_NAME") || strings.HasSuffix(key, "_SERVER_ADDRESS")
	}
	if strings.HasPrefix(key, "CDN_XHTTP_") {
		return true
	}
	if strings.HasPrefix(key, "SS2022_") {
		return true
	}
	return false
}

func validHandoffProtocolValue(key, value string) bool {
	value = strings.TrimSpace(value)
	if !usableHandoffCredential(value) || strings.ContainsAny(value, "\r\n\x00") {
		return false
	}
	if strings.HasSuffix(key, "_LINK") || strings.HasSuffix(key, "_URL") || strings.HasSuffix(key, "_SUBSCRIPTION_URL") {
		return validHandoffURL(value)
	}
	if strings.Contains(key, "UUID") || key == "UUID" {
		return handoffUUIDPattern.MatchString(value)
	}
	if strings.HasSuffix(key, "_PORT") || key == "TEST_PORT" {
		port, err := strconv.Atoi(value)
		return err == nil && port >= 1 && port <= 65535
	}
	if strings.Contains(key, "DOMAIN") || strings.Contains(key, "SERVER_NAME") || key == "REALITY_SNI" {
		return net.ParseIP(value) != nil || validDomain(value)
	}
	if strings.HasSuffix(key, "_PATH") {
		return strings.HasPrefix(value, "/") && !strings.ContainsAny(value, "\t ?#\\")
	}
	return true
}

// mergeHandoffProtocolFallbacks keeps a valid value from an older handoff
// whenever the last (current) occurrence is empty, a known placeholder, or
// malformed.  It deliberately does not alter unrelated state keys whose
// last-value-wins semantics are part of the v0.9.x protocol.
func mergeHandoffProtocolFallbacks(raw string, values map[string]string) {
	validCandidates := make(map[string]string)
	for _, line := range strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n") {
		key, candidate, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if !isHandoffProtocolKey(key) {
			continue
		}
		candidate = strings.TrimSpace(candidate)
		if validHandoffProtocolValue(key, candidate) {
			validCandidates[key] = candidate
		}
	}
	for key, candidate := range validCandidates {
		if !validHandoffProtocolValue(key, values[key]) {
			values[key] = candidate
		}
	}
}

func loginCredentialFormFields(legacy string) (map[string]string, error) {
	required := map[string]string{
		"FORM_VPS_ACCOUNT":    handoffCredentialValue(legacy, "VPS_LOGIN_USER", "VPS_ACCOUNT"),
		"FORM_VPS_PASSWORD":   handoffCredentialValue(legacy, "VPS_LOGIN_PASSWORD", "VPS_PASSWORD"),
		"FORM_PANEL_ACCOUNT":  handoffCredentialValue(legacy, "PANEL_USERNAME", "PANEL_ACCOUNT"),
		"FORM_PANEL_PASSWORD": handoffCredentialValue(legacy, "PANEL_PASSWORD"),
	}
	missing := make([]string, 0, len(required))
	for _, key := range loginFormKeys {
		value := strings.TrimSpace(required[key])
		upper := strings.ToUpper(value)
		if value == "" || strings.HasPrefix(upper, "UNKNOWN") || strings.HasPrefix(upper, "NOT_RETAINED") || upper == "SSH_KEY_ONLY" {
			missing = append(missing, strings.TrimPrefix(key, "FORM_"))
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("required login credential form is incomplete: %s", strings.Join(missing, ", "))
	}
	return required, nil
}

func parseDeploymentMode(value string) (DeploymentMode, error) {
	mode := DeploymentMode(strings.TrimSpace(value))
	switch mode {
	case DeploymentDirectReality, DeploymentCDNXHTTPTLS, DeploymentDualHotSwitch:
		return mode, nil
	default:
		return "", fmt.Errorf("unsupported deployment mode %q", value)
	}
}

func deploymentNeedsCloudflareProxy(mode DeploymentMode) bool {
	return mode == DeploymentCDNXHTTPTLS || mode == DeploymentDualHotSwitch
}

func canTransitionDeploymentState(from, to DeploymentState) bool {
	if from == to {
		return true
	}
	allowed := map[DeploymentState]map[DeploymentState]bool{
		StateActiveDirect: {
			StateCDNStaged8443:             true,
			StateDualInstalledActiveDirect: true,
		},
		StateCDNStaged8443: {
			StateWaitingForCloudflareManualAction: true,
			StateActiveDirect:                     true,
		},
		StateWaitingForCloudflareManualAction: {
			StateActiveDirect:              true,
			StateSwitchToCDNStaged8443:     true,
			StateSwitchToDirectStaged24443: true,
			StateDualInstalledActiveDirect: true,
			StateDualInstalledActiveCDN:    true,
		},
		StateDualInstalledActiveDirect: {
			StateActiveDirect:          true,
			StateSwitchToCDNStaged8443: true,
		},
		StateSwitchToCDNStaged8443: {
			StateWaitingForCloudflareManualAction: true,
			StateDualInstalledActiveDirect:        true,
			StateSwitchToCDNPort443Committing:     true,
		},
		StateSwitchToCDNPort443Committing: {
			StateDualInstalledActiveCDN:    true,
			StateDualInstalledActiveDirect: true,
		},
		StateActiveCDN: {
			StateSwitchToDirectStaged24443: true,
			StateDualInstalledActiveCDN:    true,
		},
		StateDualInstalledActiveCDN: {
			StateSwitchToDirectStaged24443: true,
		},
		StateSwitchToDirectStaged24443: {
			StateWaitingForCloudflareManualAction: true,
			StateDualInstalledActiveCDN:           true,
			StateSwitchToDirectPort443Committing:  true,
		},
		StateSwitchToDirectPort443Committing: {
			StateDualInstalledActiveDirect: true,
			StateDualInstalledActiveCDN:    true,
		},
	}
	return allowed[from][to]
}

// appendCompleteHandoff is deliberately append-only.  Existing bytes are
// preserved exactly; new fields are sorted and rendered in a separate block.
// This keeps old handoff consumers working while exposing the v1 protocol
// links and local-panel details to newer clients.
func appendCompleteHandoff(legacy string, fields map[string]string) (string, error) {
	if legacy == "" {
		return "", errors.New("legacy handoff is empty")
	}
	if strings.ContainsRune(legacy, '\x00') {
		return "", errors.New("legacy handoff contains a NUL byte")
	}
	// A saved v0.9.x handoff can contain a TNA-* CDN fragment even when the
	// current remote exporter has already switched to PNA.  Normalize the
	// values before rendering the appendix so the desktop form never presents
	// a stale fragment again.  The compatibility formatter accepts the old
	// query shape but preserves its RawQuery (including x_padding_bytes/extra).
	normalizedFields, err := canonicalizeCompleteHandoffFields(fields)
	if err != nil {
		return "", err
	}
	fields = normalizedFields
	keys := make([]string, 0, len(fields))
	for key, value := range fields {
		if !handoffAppendixKeyPattern.MatchString(key) {
			return "", fmt.Errorf("invalid handoff appendix key %q", key)
		}
		if strings.ContainsAny(value, "\r\n\x00") {
			return "", fmt.Errorf("handoff appendix value %s contains a line break or NUL", key)
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var output strings.Builder
	output.Grow(len(legacy) + 256 + len(fields)*48)
	formComplete := true
	for _, key := range loginFormKeys {
		if strings.TrimSpace(fields[key]) == "" {
			formComplete = false
			break
		}
	}
	legacy = normalizeHandoffLegacy(legacy, handoffRegeneratedKeys(fields, formComplete))
	if legacy != "" {
		output.WriteString(legacy)
	}
	if formComplete {
		output.WriteString("\n\n===== 必须保存的登录凭据 / REQUIRED LOGIN CREDENTIALS =====\n")
		output.WriteString("VPS_ACCOUNT=" + fields["FORM_VPS_ACCOUNT"] + "\n")
		output.WriteString("VPS_PASSWORD=" + fields["FORM_VPS_PASSWORD"] + "\n")
		output.WriteString("PANEL_ACCOUNT=" + fields["FORM_PANEL_ACCOUNT"] + "\n")
		output.WriteString("PANEL_PASSWORD=" + fields["FORM_PANEL_PASSWORD"] + "\n")
		if localURL := fields["FORM_PANEL_LOCAL_URL"]; localURL != "" {
			output.WriteString("PANEL_LOCAL_URL=" + localURL + "\n")
		}
		output.WriteString("===== END REQUIRED LOGIN CREDENTIALS =====")
	}
	output.WriteString("\n\n" + completeHandoffHeader + "\n")
	for _, key := range keys {
		if strings.HasPrefix(key, "FORM_") {
			continue
		}
		output.WriteString(key)
		output.WriteByte('=')
		output.WriteString(fields[key])
		output.WriteByte('\n')
	}
	output.WriteString(completeHandoffFooter)
	return output.String(), nil
}

var completeHandoffCDNLinkKeys = map[string]struct{}{
	"CDN_XHTTP_LINK":       {},
	"CDN_XHTTP_STAGE_LINK": {},
	"XHTTP_LINK":           {},
	"XHTTP_STAGE_LINK":     {},
}

func canonicalizeCompleteHandoffFields(fields map[string]string) (map[string]string, error) {
	normalized := make(map[string]string, len(fields))
	// Collapse the v0.9.x XHTTP_* aliases into the canonical CDN_XHTTP_* key
	// before sorting/rendering.  Map iteration order is deliberately ignored:
	// a valid canonical spelling wins over a legacy alias, while a malformed
	// canonical value can fall back to a valid alias during an interrupted
	// upgrade.  No alias is ever emitted in the v1 appendix.
	type candidate struct {
		key       string
		value     string
		canonical bool
	}
	candidates := make(map[string][]candidate, 2)
	for key, value := range fields {
		canonicalKey, isCDNLink := canonicalCompleteHandoffCDNKey(key)
		if !isCDNLink {
			normalized[key] = value
			continue
		}
		candidates[canonicalKey] = append(candidates[canonicalKey], candidate{key: key, value: value, canonical: key == canonicalKey})
	}
	for canonicalKey, values := range candidates {
		var firstErr error
		chosen := ""
		// Prefer the canonical key regardless of map iteration order.
		for _, item := range values {
			if !item.canonical || strings.TrimSpace(item.value) == "" {
				continue
			}
			canonical, err := canonicalizeCDNXHTTPHandoffURL(item.value)
			if err == nil {
				chosen = canonical
				break
			}
			if firstErr == nil {
				firstErr = fmt.Errorf("invalid %s in complete handoff: %w", item.key, err)
			}
		}
		if chosen == "" {
			for _, item := range values {
				if item.canonical || strings.TrimSpace(item.value) == "" {
					continue
				}
				canonical, err := canonicalizeCDNXHTTPHandoffURL(item.value)
				if err == nil {
					chosen = canonical
					break
				}
				if firstErr == nil {
					firstErr = fmt.Errorf("invalid %s in complete handoff: %w", item.key, err)
				}
			}
		}
		if chosen == "" {
			// Preserve an explicitly empty canonical field for compatibility with
			// callers that use an empty value to clear a prior link.  Non-empty
			// malformed values remain fail-closed instead of being copied.
			allEmpty := true
			for _, item := range values {
				if strings.TrimSpace(item.value) != "" {
					allEmpty = false
					break
				}
			}
			if !allEmpty {
				if firstErr == nil {
					firstErr = fmt.Errorf("invalid CDN/XHTTP link in complete handoff")
				}
				return nil, firstErr
			}
			normalized[canonicalKey] = ""
			continue
		}
		normalized[canonicalKey] = chosen
	}
	return normalized, nil
}

func canonicalCompleteHandoffCDNKey(key string) (string, bool) {
	switch key {
	case "CDN_XHTTP_LINK", "XHTTP_LINK":
		return "CDN_XHTTP_LINK", true
	case "CDN_XHTTP_STAGE_LINK", "XHTTP_STAGE_LINK":
		return "CDN_XHTTP_STAGE_LINK", true
	default:
		return "", false
	}
}

func canonicalCDNXHTTPHandoffValue(value string) (string, bool) {
	if strings.TrimSpace(value) == "" {
		return "", false
	}
	canonical, err := canonicalizeCDNXHTTPHandoffURL(value)
	if err != nil {
		return "", false
	}
	return canonical, true
}

func firstHandoffValue(values map[string]string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(values[key]); value != "" {
			return value
		}
	}
	return ""
}

func firstIndexedHandoffValue(values map[string]string, suffix string) string {
	for i := 1; i <= 128; i++ {
		if value := strings.TrimSpace(values[fmt.Sprintf("REALITY_CLIENT_%d_%s", i, suffix)]); value != "" {
			return value
		}
	}
	return ""
}

func validHandoffURL(value string) bool {
	u, err := url.Parse(strings.TrimSpace(value))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return false
	}
	return strings.EqualFold(u.Scheme, "vless") || strings.EqualFold(u.Scheme, "ss") || strings.EqualFold(u.Scheme, "https") || strings.EqualFold(u.Scheme, "http")
}

// deriveRealityHandoffLink reconstructs the first Reality client link when an
// older handoff retained the individual key fields but not the generated URI.
// It is deliberately conservative: a link is emitted only when all values
// needed by a client are present and syntactically safe.
func deriveRealityHandoffLink(values map[string]string) string {
	uuid := firstHandoffValue(values, "REALITY_CLIENT_1_UUID", "REALITY_TEST_UUID", "REALITY_GENERATED_UUID", "REALITY_UUID", "UUID")
	host := firstHandoffValue(values, "REALITY_SERVER_ADDRESS", "PUBLIC_IP_AT_HANDOFF", "VPS_PUBLIC_IP", "PUBLIC_IP")
	port := firstHandoffValue(values, "REALITY_CLIENT_1_PORT", "REALITY_PUBLIC_PORT", "REALITY_SERVER_PORT", "REALITY_PORT", "REALITY_TEST_PORT", "TEST_PORT")
	if port == "" {
		port = "443"
	}
	publicKey := firstHandoffValue(values, "REALITY_PUBLIC_KEY", "REALITY_CLIENT_PUBLIC_KEY")
	sni := firstHandoffValue(values, "REALITY_SERVER_NAME", "REALITY_SNI", "REALITY_DEST_DOMAIN")
	shortID := firstHandoffValue(values, "REALITY_SHORT_ID", "REALITY_CLIENT_SHORT_ID", "REALITY_GENERATED_SHORT_ID")
	if !handoffUUIDPattern.MatchString(uuid) || (net.ParseIP(host) == nil && !validDomain(host)) || publicKey == "" || !validDomain(sni) || shortID == "" {
		return ""
	}
	if parsedPort, err := strconv.Atoi(port); err != nil || parsedPort < 1 || parsedPort > 65535 {
		return ""
	}
	q := url.Values{}
	q.Set("type", "tcp")
	q.Set("security", "reality")
	q.Set("pbk", publicKey)
	q.Set("fp", "chrome")
	q.Set("sni", sni)
	q.Set("sid", shortID)
	q.Set("spx", "/")
	q.Set("flow", "xtls-rprx-vision")
	return "vless://" + uuid + "@" + net.JoinHostPort(host, port) + "?" + q.Encode() + "#ProxyNodeAssistant-Reality"
}

// deriveSS2022HandoffLink reconstructs a SIP002 URI from the fields emitted
// by 23-ss2022-tcp.sh.  The password never enters a shell command; it is only
// rendered here as part of the explicit credential handoff requested by the
// operator.
func deriveSS2022HandoffLink(values map[string]string) string {
	host := firstHandoffValue(values, "SS2022_SERVER_ADDRESS", "SS2022_HOST", "PUBLIC_IP_AT_HANDOFF", "VPS_PUBLIC_IP")
	port := firstHandoffValue(values, "SS2022_PORT")
	method := firstHandoffValue(values, "SS2022_METHOD")
	password := firstHandoffValue(values, "SS2022_PASSWORD")
	if host == "" || port == "" || method == "" || !usableHandoffCredential(password) {
		return ""
	}
	if net.ParseIP(host) == nil && !validDomain(host) {
		return ""
	}
	parsedPort, err := strconv.Atoi(port)
	if err != nil || parsedPort < 1 || parsedPort > 65535 {
		return ""
	}
	userinfo := base64.RawURLEncoding.EncodeToString([]byte(method + ":" + password))
	return "ss://" + userinfo + "@" + net.JoinHostPort(host, port) + "#ProxyNodeAssistant-SS2022-TCP"
}

func deriveXHTTPHandoffLink(values map[string]string) string {
	uuid := firstHandoffValue(values, "CDN_XHTTP_UUID", "XHTTP_UUID")
	domain := firstHandoffValue(values, "CDN_XHTTP_DOMAIN", "XHTTP_PUBLIC_DOMAIN", "XHTTP_DOMAIN")
	path := firstHandoffValue(values, "CDN_XHTTP_PATH", "XHTTP_PATH")
	if !handoffUUIDPattern.MatchString(uuid) || !validDomain(domain) || path == "" || !strings.HasPrefix(path, "/") {
		return ""
	}
	port := firstHandoffValue(values, "CDN_XHTTP_PUBLIC_PORT", "XHTTP_PUBLIC_PORT")
	if port == "" {
		port = "8443"
	}
	parsedPort, err := strconv.Atoi(port)
	if err != nil || parsedPort < 1 || parsedPort > 65535 {
		return ""
	}
	encodedPath := url.QueryEscape(path)
	encodedDomain := url.QueryEscape(domain)
	return fmt.Sprintf("vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%s&mode=packet-up#%s", uuid, domain, port, encodedDomain, encodedDomain, encodedPath, cdnXHTTPOrangeLabel)
}

func subscriptionHandoffURL(values map[string]string) string {
	if value := firstHandoffValue(values, "SUBSCRIPTION_URL", "SUBSCRIPTION_LINK", "CDN_XHTTP_SUBSCRIPTION_URL"); validHandoffURL(value) {
		return value
	}
	if value := firstIndexedHandoffValue(values, "SUBSCRIPTION_URL"); validHandoffURL(value) {
		return value
	}
	domain := firstHandoffValue(values, "COVER_DOMAIN", "CDN_XHTTP_DOMAIN", "XHTTP_DOMAIN")
	subID := firstHandoffValue(values, "CDN_XHTTP_SUB_ID", "XHTTP_SUB_ID", "REALITY_CLIENT_1_SUB_ID", "REALITY_TEST_SUB_ID", "REALITY_GENERATED_SUB_ID", "SUB_ID")
	if validDomain(domain) && handoffSubscriptionIDPattern.MatchString(subID) {
		return "https://" + domain + "/sub/" + subID
	}
	return ""
}

func (a *App) buildCompleteHandoff(legacy string, c Connection) (string, error) {
	loginFields, err := loginCredentialFormFields(legacy)
	if err != nil {
		return "", errors.New(a.msg(
			"登录凭据表不完整，拒绝显示或复制：必须同时具备 VPS 账号/密码和面板账号/密码；请运行 [1] 完成强制交接，或分别运行 [5]、[6] 轮换后重试",
			"Login credential form is incomplete and will not be displayed or copied: VPS account/password and panel account/password are all required. Run [1] to complete the mandatory handoff, or rotate with [5] and [6], then retry",
		))
	}
	values := parseKV(legacy)
	mergeHandoffProtocolFallbacks(legacy, values)
	fields := map[string]string{
		"PNA_VERSION":         version,
		"SSH_AUTH_MODE":       "MANAGED_KEY",
		"SSH_KEY_ONLY":        fmt.Sprintf("%t", c.AuthMode == AuthManagedKey),
		"VPS_SSH_USER":        c.User,
		"VPS_SSH_PORT":        fmt.Sprintf("%d", c.Port),
		"VPS_PASSWORD_STATUS": "PRESENT_IN_PROTECTED_HANDOFF",
	}
	if c.AuthMode == AuthTemporaryPassword {
		fields["SSH_AUTH_MODE"] = "TEMPORARY_PASSWORD_ONE_RUN"
	}
	for key, value := range loginFields {
		fields[key] = value
	}
	if c.AuthMode == AuthManagedKey && c.KeyPath != "" {
		fields["SSH_PRIVATE_KEY_FILE"] = c.KeyPath
	}
	if runtime, err := a.runtimePublicEnv(c); err == nil {
		if ip := strings.TrimSpace(firstHandoffValue(runtime, "PUBLIC_IP", "VPS_PUBLIC_IP")); net.ParseIP(ip) != nil {
			fields["VPS_PUBLIC_IP"] = ip
		}
		if domain := firstHandoffValue(runtime, "COVER_DOMAIN", "CONSTRUCTION_DOMAIN"); validDomain(domain) {
			fields["CONSTRUCTION_DOMAIN"] = domain
			if strings.TrimSpace(values["COVER_DOMAIN"]) == "" {
				values["COVER_DOMAIN"] = domain
			}
		}
	}
	// Existing v0.9.x installations may have protocol state on disk even
	// when their last handoff was interrupted before the export helpers ran.
	// Read both state roots and merge only missing values.  The current handoff
	// remains authoritative for values that are already present.
	protocolState := a.rootCapture(c, "for f in /root/.config/text-node-assistant/cdn-xhttp.env /root/.config/proxy-runbook/cdn-xhttp.env /etc/text-node-assistant/cdn-xhttp.env /etc/proxy-runbook/cdn-xhttp.env; do [ -r \"$f\" ] && cat \"$f\"; done")
	for key, value := range parseKV(protocolState.Stdout) {
		if strings.TrimSpace(value) == "" {
			continue
		}
		// XHTTP state historically used an XHTTP_* prefix; expose the stable
		// CDN_XHTTP_* names consumed by clients while retaining all original
		// handoff bytes untouched.
		alias := key
		if strings.HasPrefix(key, "XHTTP_") {
			alias = "CDN_" + key
		}
		if strings.TrimSpace(values[alias]) == "" {
			values[alias] = value
		}
		if strings.TrimSpace(values[key]) == "" {
			values[key] = value
		}
	}
	// The state files can themselves contain a stale/placeholder last line.
	// Re-run the typed fallback after merging them so a valid archived value is
	// still preferred over malformed current state.
	mergeHandoffProtocolFallbacks(protocolState.Stdout, values)
	stateResult := a.rootCapture(c, "for f in /etc/text-node-assistant/deployment-state.env /etc/proxy-runbook/deployment-state.env; do [ -r \"$f\" ] && cat \"$f\"; done")
	state := parseKV(stateResult.Stdout)
	mode := state["DEPLOYMENT_MODE"]
	if _, err := parseDeploymentMode(mode); err != nil {
		mode = string(DeploymentDirectReality)
	}
	active := firstHandoffValue(state, "ACTIVE_MODE", "ROUTE_STATE")
	if active == "" {
		active = string(StateActiveDirect)
	}
	fields["DEPLOYMENT_MODE"] = mode
	fields["ACTIVE_MODE"] = active
	fields["CURRENT_ORIGIN_CONCEALED"] = firstHandoffValue(state, "CURRENT_ORIGIN_CONCEALED")
	if fields["CURRENT_ORIGIN_CONCEALED"] == "" {
		fields["CURRENT_ORIGIN_CONCEALED"] = "false"
	}
	fields["ORIGIN_HISTORY"] = firstHandoffValue(state, "ORIGIN_HISTORY")
	if fields["ORIGIN_HISTORY"] == "" {
		fields["ORIGIN_HISTORY"] = "unknown"
	}
	// These two fields were part of the v0.9.5 handoff contract and are still
	// useful to older clients.  They describe status only; no retired drive or
	// device-admission data is reintroduced.
	fields["V095_CDN_STATUS"] = "NOT_CONFIGURED"
	fields["V095_PHASE_STATUS"] = "DIRECT_COMPATIBILITY_BASELINE"
	if mode != string(DeploymentDirectReality) {
		fields["V095_CDN_STATUS"] = active
		fields["V095_PHASE_STATUS"] = "EXPERIMENTAL_STAGED_NOT_PUBLICLY_PROMOTED"
	}

	// Re-emit every valid protocol field from the merged archive/current view.
	// The old implementation only regenerated the three primary links, leaving
	// duplicate Reality/XHTTP/SS2022 rows in the preserved prefix.  When the
	// form was copied, an operator could therefore see an old value next to a
	// current one (and older clients often picked the first one).  Copying the
	// typed fields into the appendix makes handoffRegeneratedKeys remove those
	// stale raw rows while retaining all per-client/per-port customizations.
	for key, value := range values {
		if !isHandoffProtocolKey(key) || !validHandoffProtocolValue(key, value) {
			continue
		}
		// runtimePublicEnv is the authoritative source for the current VPS IP;
		// do not let an archived PUBLIC_IP/VPS_PUBLIC_IP row overwrite it.
		if (key == "PUBLIC_IP" || key == "VPS_PUBLIC_IP") && strings.TrimSpace(fields["VPS_PUBLIC_IP"]) != "" {
			continue
		}
		if canonicalKey, isLink := canonicalCompleteHandoffCDNKey(key); isLink {
			if canonical, ok := canonicalCDNXHTTPHandoffValue(value); ok {
				fields[canonicalKey] = canonical
			}
			continue
		}
		fields[key] = strings.TrimSpace(value)
	}

	// Keep all protocol values already emitted by the runbook, and add stable
	// aliases for clients that expect one primary link/subscription URL.
	if link := firstHandoffValue(values, "VLESS_LINK", "REALITY_PRODUCTION_LINK", "REALITY_LINK", "REALITY_TEST_LINK"); validHandoffURL(link) {
		fields["VLESS_LINK"] = link
	} else if link := firstIndexedHandoffValue(values, "LINK"); validHandoffURL(link) {
		fields["VLESS_LINK"] = link
	} else if link := deriveRealityHandoffLink(values); validHandoffURL(link) {
		fields["VLESS_LINK"] = link
	}
	// Keep the direct Reality alias and the CDN/XHTTP link independently.  A
	// dual deployment normally has both; deriving XHTTP must not be skipped
	// merely because VLESS_LINK already points at Reality.  Import both the
	// current CDN_XHTTP_* spelling and the old XHTTP_* aliases, but canonicalize
	// any URI before it reaches the visible handoff.
	currentXHTTP := firstHandoffValue(values, "CDN_XHTTP_LINK", "XHTTP_LINK")
	if canonical, ok := canonicalCDNXHTTPHandoffValue(currentXHTTP); ok {
		fields["CDN_XHTTP_LINK"] = canonical
		values["CDN_XHTTP_LINK"] = canonical
	} else if link := deriveXHTTPHandoffLink(values); link != "" {
		fields["CDN_XHTTP_LINK"] = link
		values["CDN_XHTTP_LINK"] = link
	}
	currentXHTTPStage := firstHandoffValue(values, "CDN_XHTTP_STAGE_LINK", "XHTTP_STAGE_LINK")
	if canonical, ok := canonicalCDNXHTTPHandoffValue(currentXHTTPStage); ok {
		fields["CDN_XHTTP_STAGE_LINK"] = canonical
		values["CDN_XHTTP_STAGE_LINK"] = canonical
	}
	if sub := subscriptionHandoffURL(values); sub != "" {
		fields["SUBSCRIPTION_URL"] = sub
	}
	if ss := firstHandoffValue(values, "SS2022_LINK"); validHandoffURL(ss) {
		fields["SS2022_LINK"] = ss
	} else if ss := deriveSS2022HandoffLink(values); validHandoffURL(ss) {
		fields["SS2022_LINK"] = ss
	}
	if xhttp := firstHandoffValue(values, "CDN_XHTTP_LINK"); xhttp != "" {
		if canonical, ok := canonicalCDNXHTTPHandoffValue(xhttp); ok {
			fields["CDN_XHTTP_LINK"] = canonical
		}
	}
	if xhttp := firstHandoffValue(values, "CDN_XHTTP_STAGE_LINK"); xhttp != "" {
		if canonical, ok := canonicalCDNXHTTPHandoffValue(xhttp); ok {
			fields["CDN_XHTTP_STAGE_LINK"] = canonical
		}
	}

	// Stable node identity is part of the v0.9.5 handoff contract and remains
	// useful for key/host verification after an in-place upgrade.  It is not a
	// device admission gate: if an older node has no identity helper, omit the
	// optional fields rather than blocking credential/protocol export.
	if identity, identityErr := a.fetchNodeIdentity(c); identityErr == nil {
		fields["SERVER_ID"] = identity.ServerID
		fields["NODE_ID"] = identity.NodeID
		fields["MACHINE_ID_SHA256"] = identity.MachineIDHash
		fields["SSH_HOST_KEY_ALGORITHM"] = identity.HostKeyAlg
		fields["SSH_HOST_KEY_SHA256"] = identity.HostKeySHA256
		fields["FIRST_KNOWN_PUBLIC_IP"] = identity.FirstPublicIP
		fields["CURRENT_PUBLIC_IP"] = identity.CurrentPublicIP
	}
	if c.AuthMode == AuthManagedKey && c.KeyPath != "" {
		if keyID, keyErr := sshAuthenticationKeyID(c.KeyPath); keyErr == nil {
			fields["SSH_AUTH_KEY_ID"] = keyID
		}
	}

	if panel, err := a.panelMetadata(c); err == nil {
		fields["PANEL_REMOTE_LOOPBACK_PORT"] = fmt.Sprintf("%d", panel.Port)
		fields["PANEL_LOCAL_URL_TEMPLATE"] = fmt.Sprintf("http://127.0.0.1:<LOCAL_TUNNEL_PORT>%s", panel.Path)
		fields["PANEL_SSH_TUNNEL_COMMAND"] = fmt.Sprintf("ssh -N -L 127.0.0.1:<LOCAL_TUNNEL_PORT>:127.0.0.1:%d -p %d %s@%s", panel.Port, c.Port, c.User, c.Host)
		fields["FORM_PANEL_LOCAL_URL"] = fmt.Sprintf("http://127.0.0.1:<LOCAL_TUNNEL_PORT>%s", panel.Path)
	} else if path, pathErr := normalizePanelPath(firstHandoffValue(values, "PANEL_WEB_BASE_PATH", "WEB_BASE_PATH")); pathErr == nil {
		fields["PANEL_LOCAL_URL_TEMPLATE"] = "http://127.0.0.1:<LOCAL_TUNNEL_PORT>" + path
		fields["FORM_PANEL_LOCAL_URL"] = fields["PANEL_LOCAL_URL_TEMPLATE"]
	}
	return appendCompleteHandoff(legacy, fields)
}
