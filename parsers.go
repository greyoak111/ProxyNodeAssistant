package main

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const (
	handoffBegin = "__TNA_HANDOFF_BEGIN__"
	handoffEnd   = "__TNA_HANDOFF_END__"
	panelBegin   = "__TNA_PANEL_META_BEGIN__"
	panelEnd     = "__TNA_PANEL_META_END__"
	statusBegin  = "__TNA_RUN_STATUS_BEGIN__"
	statusEnd    = "__TNA_RUN_STATUS_END__"
	diagBegin    = "__TNA_DIAG_V1_BEGIN__"
	diagEnd      = "__TNA_DIAG_V1_END__"
	toolkitBegin = "__TNA_TOOLKIT_PROBE_BEGIN__"
	toolkitEnd   = "__TNA_TOOLKIT_PROBE_END__"

	legacyHandoffBegin = "__PNA_HANDOFF_BEGIN__"
	legacyHandoffEnd   = "__PNA_HANDOFF_END__"
	legacyPanelBegin   = "__PNA_PANEL_META_BEGIN__"
	legacyPanelEnd     = "__PNA_PANEL_META_END__"
	legacyStatusBegin  = "__PNA_RUN_STATUS_BEGIN__"
	legacyStatusEnd    = "__PNA_RUN_STATUS_END__"
	legacyDiagBegin    = "__PNA_DIAG_V1_BEGIN__"
	legacyDiagEnd      = "__PNA_DIAG_V1_END__"
	legacyToolkitBegin = "__PNA_TOOLKIT_PROBE_BEGIN__"
	legacyToolkitEnd   = "__PNA_TOOLKIT_PROBE_END__"
)

var ansiPattern = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)
var closedPattern = regexp.MustCompile(`(?i)^Connection to .+ closed\.$`)
var diagCodePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
var toolkitVersionPattern = regexp.MustCompile(`^v?[0-9]+(?:\.[0-9]+){1,3}$`)
var toolkitBuildPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
var uuidPattern = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$`)
var cdnHostnamePattern = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$`)
var xhttpPathPattern = regexp.MustCompile(`^/[0-9a-f]{32}/$`)

type CDNXHTTPLink struct {
	UUID   string
	Domain string
	Port   int
	Path   string
	Label  string
}

func validateCDNXHTTPProfile(profile CDNXHTTPLink) error {
	if !uuidPattern.MatchString(profile.UUID) {
		return errors.New("CDN XHTTP link has an invalid UUID")
	}
	if !cdnHostnamePattern.MatchString(profile.Domain) {
		return errors.New("CDN XHTTP link has an invalid hostname")
	}
	if profile.Port != 443 && profile.Port != 8443 {
		return errors.New("CDN XHTTP link port must be 443 or 8443")
	}
	if !xhttpPathPattern.MatchString(profile.Path) {
		return errors.New("CDN XHTTP link path must be / plus 32 lowercase hex characters plus /")
	}
	expectedLabel := "TNA-CDN-XHTTP"
	if profile.Port == 8443 {
		expectedLabel = "TNA-CDN-XHTTP-STAGE"
	}
	if profile.Label != expectedLabel {
		return fmt.Errorf("CDN XHTTP link label must be %s", expectedLabel)
	}
	return nil
}

func buildCDNXHTTPLink(profile CDNXHTTPLink) (string, error) {
	if err := validateCDNXHTTPProfile(profile); err != nil {
		return "", err
	}
	query := url.Values{}
	query.Set("encryption", "none")
	query.Set("security", "tls")
	query.Set("sni", profile.Domain)
	query.Set("fp", "chrome")
	query.Set("type", "xhttp")
	query.Set("host", profile.Domain)
	query.Set("path", profile.Path)
	query.Set("mode", "packet-up")
	parsed := url.URL{
		Scheme:   "vless",
		User:     url.User(profile.UUID),
		Host:     net.JoinHostPort(profile.Domain, strconv.Itoa(profile.Port)),
		RawQuery: query.Encode(),
		Fragment: profile.Label,
	}
	return parsed.String(), nil
}

func parseCDNXHTTPLink(value string) (CDNXHTTPLink, error) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme != "vless" || parsed.User == nil {
		return CDNXHTTPLink{}, errors.New("invalid VLESS URL")
	}
	if parsed.User.String() == "" || parsed.User.Username() != parsed.User.String() {
		return CDNXHTTPLink{}, errors.New("VLESS userinfo must contain only the UUID")
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil {
		return CDNXHTTPLink{}, errors.New("VLESS port is missing or invalid")
	}
	query := parsed.Query()
	required := map[string]string{
		"encryption": "none",
		"security":   "tls",
		"sni":        parsed.Hostname(),
		"fp":         "chrome",
		"type":       "xhttp",
		"host":       parsed.Hostname(),
		"mode":       "packet-up",
	}
	for key, expected := range required {
		values := query[key]
		if len(values) != 1 || values[0] != expected {
			return CDNXHTTPLink{}, fmt.Errorf("CDN XHTTP link field %s is missing, duplicated, or invalid", key)
		}
	}
	paths := query["path"]
	if len(paths) != 1 {
		return CDNXHTTPLink{}, errors.New("CDN XHTTP link path is missing or duplicated")
	}
	profile := CDNXHTTPLink{
		UUID:   parsed.User.Username(),
		Domain: parsed.Hostname(),
		Port:   port,
		Path:   paths[0],
		Label:  parsed.Fragment,
	}
	if err := validateCDNXHTTPProfile(profile); err != nil {
		return CDNXHTTPLink{}, err
	}
	return profile, nil
}

type ToolkitProbe struct {
	Present       bool
	Brand         string
	Root          string
	Version       string
	BuildID       string
	BuildRevision int
	Complete      bool
}

type ToolkitRelation string

const (
	ToolkitMissing        ToolkitRelation = "missing"
	ToolkitOlder          ToolkitRelation = "older"
	ToolkitSameComplete   ToolkitRelation = "same-complete"
	ToolkitSameIncomplete ToolkitRelation = "same-incomplete"
	ToolkitNewer          ToolkitRelation = "newer"
)

func stripANSI(value string) string {
	return ansiPattern.ReplaceAllString(value, "")
}

func extractMarkedBlock(stdout, begin, end string) (string, error) {
	lines := strings.Split(strings.ReplaceAll(stripANSI(stdout), "\r\n", "\n"), "\n")
	inside := false
	foundEnd := false
	var payload []string
	for _, raw := range lines {
		line := strings.TrimSuffix(raw, "\r")
		if !inside {
			if strings.TrimSpace(line) == begin {
				inside = true
			}
			continue
		}
		if strings.TrimSpace(line) == end {
			foundEnd = true
			break
		}
		payload = append(payload, line)
	}
	if !inside || !foundEnd {
		return "", errors.New("required output markers were not found")
	}
	result := strings.TrimSpace(strings.Join(payload, "\n"))
	if result == "" {
		return "", errors.New("marked output was empty")
	}
	return result, nil
}

func extractCurrentOrLegacyBlock(stdout, begin, end, legacyBegin, legacyEnd string) (string, error) {
	payload, err := extractMarkedBlock(stdout, begin, end)
	if err == nil {
		return payload, nil
	}
	legacyPayload, legacyErr := extractMarkedBlock(stdout, legacyBegin, legacyEnd)
	if legacyErr == nil {
		return legacyPayload, nil
	}
	return "", err
}

func parseKV(value string) map[string]string {
	result := make(map[string]string)
	for _, raw := range strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`).MatchString(key) {
			result[key] = strings.TrimSpace(val)
		}
	}
	return result
}

func validateHandoff(stdout string) (string, error) {
	payload, err := extractCurrentOrLegacyBlock(stdout, handoffBegin, handoffEnd, legacyHandoffBegin, legacyHandoffEnd)
	if err != nil {
		return "", fmt.Errorf("credential handoff rejected: %w", err)
	}
	kv := parseKV(payload)
	if kv["HANDOFF_RUN_STARTED"] == "" {
		return "", errors.New("credential handoff rejected: run marker is missing")
	}
	useful := []string{
		"PANEL_PORT", "PANEL_USERNAME", "PANEL_PASSWORD", "PANEL_API_TOKEN",
		"VPS_LOGIN_PASSWORD", "UUID", "REALITY_PRIVATE_KEY", "REALITY_PUBLIC_KEY",
		"VLESS_LINK", "COVER_DOMAIN", "PUBLIC_IP_AT_HANDOFF",
	}
	for _, key := range useful {
		if strings.TrimSpace(kv[key]) != "" {
			return payload, nil
		}
	}
	return "", errors.New("credential handoff rejected: no credential or verified runtime field was present")
}

type PanelMetadata struct {
	Port   int
	Path   string
	Source string
}

func parsePanelMetadata(stdout string) (PanelMetadata, error) {
	payload, err := extractCurrentOrLegacyBlock(stdout, panelBegin, panelEnd, legacyPanelBegin, legacyPanelEnd)
	if err != nil {
		return PanelMetadata{}, fmt.Errorf("panel metadata rejected: %w", err)
	}
	kv := parseKV(payload)
	port, err := strconv.Atoi(kv["PANEL_PORT"])
	if err != nil || port < 1 || port > 65535 {
		return PanelMetadata{}, errors.New("panel metadata rejected: invalid or empty panel port")
	}
	path, err := normalizePanelPath(kv["WEB_BASE_PATH"])
	if err != nil {
		return PanelMetadata{}, fmt.Errorf("panel metadata rejected: %w", err)
	}
	return PanelMetadata{Port: port, Path: path, Source: kv["PANEL_METADATA_SOURCE"]}, nil
}

func normalizePanelPath(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("empty panel path")
	}
	if strings.ContainsAny(value, "\r\n\t ?#\\") {
		return "", errors.New("unsafe panel path")
	}
	if !strings.HasPrefix(value, "/") {
		value = "/" + value
	}
	if !strings.HasSuffix(value, "/") {
		value += "/"
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.IsAbs() || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("invalid panel path")
	}
	return value, nil
}

func parseRunStatus(stdout string) (map[string]string, error) {
	payload, err := extractCurrentOrLegacyBlock(stdout, statusBegin, statusEnd, legacyStatusBegin, legacyStatusEnd)
	if err != nil {
		return nil, err
	}
	kv := parseKV(payload)
	if kv["RUN_STATUS"] == "" {
		return nil, errors.New("run status is missing")
	}
	return kv, nil
}

func parseToolkitProbe(stdout string) (ToolkitProbe, error) {
	payload, err := extractCurrentOrLegacyBlock(stdout, toolkitBegin, toolkitEnd, legacyToolkitBegin, legacyToolkitEnd)
	if err != nil {
		return ToolkitProbe{}, fmt.Errorf("toolkit probe rejected: %w", err)
	}
	kv := parseKV(payload)
	switch kv["TOOLKIT_PRESENT"] {
	case "0":
		return ToolkitProbe{}, nil
	case "1":
	default:
		return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid presence flag")
	}
	version := strings.TrimSpace(kv["TOOLKIT_VERSION"])
	if !toolkitVersionPattern.MatchString(version) {
		return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid version")
	}
	brand := strings.TrimSpace(kv["TOOLKIT_BRAND"])
	root := strings.TrimSpace(kv["TOOLKIT_ROOT"])
	switch brand {
	case "TNA":
		if root != remoteRoot {
			return ToolkitProbe{}, errors.New("toolkit probe rejected: current brand/root mismatch")
		}
	case "PNA_LEGACY":
		if root != legacyRemoteRoot {
			return ToolkitProbe{}, errors.New("toolkit probe rejected: legacy brand/root mismatch")
		}
	default:
		return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid brand")
	}
	buildID := strings.TrimSpace(kv["TOOLKIT_BUILD_ID"])
	if buildID != "" && !toolkitBuildPattern.MatchString(buildID) {
		return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid build id")
	}
	buildRevision := 0
	if rawRevision := strings.TrimSpace(kv["TOOLKIT_BUILD_REVISION"]); rawRevision != "" {
		parsedRevision, parseErr := strconv.Atoi(rawRevision)
		if parseErr != nil || parsedRevision < 1 || parsedRevision > 1000000000 {
			return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid build revision")
		}
		buildRevision = parsedRevision
	}
	complete := false
	switch kv["TOOLKIT_COMPLETE"] {
	case "0":
	case "1":
		complete = true
	default:
		return ToolkitProbe{}, errors.New("toolkit probe rejected: invalid completeness flag")
	}
	return ToolkitProbe{Present: true, Brand: brand, Root: root, Version: strings.TrimPrefix(version, "v"), BuildID: buildID, BuildRevision: buildRevision, Complete: complete}, nil
}

func compareToolkitBuild(probe ToolkitProbe, localBuildID string, localRevision int) int {
	if probe.BuildRevision > 0 {
		if probe.BuildRevision < localRevision {
			return -1
		}
		if probe.BuildRevision > localRevision {
			return 1
		}
	}
	if probe.BuildID == localBuildID {
		return 0
	}
	// Builds predating TOOLKIT_BUILD_REVISION are safely treated as older by a
	// revision-aware EXE. Older EXEs do not know this rule and therefore cannot
	// downgrade a newer revision-aware remote toolkit.
	if probe.BuildRevision == 0 && localRevision > 0 {
		return -1
	}
	return 1
}

func compareToolkitVersions(left, right string) (int, error) {
	parse := func(value string) ([]uint64, error) {
		value = strings.TrimPrefix(strings.TrimSpace(value), "v")
		if !toolkitVersionPattern.MatchString(value) {
			return nil, fmt.Errorf("invalid toolkit version %q", value)
		}
		parts := strings.Split(value, ".")
		parsed := make([]uint64, len(parts))
		for i, part := range parts {
			number, parseErr := strconv.ParseUint(part, 10, 32)
			if parseErr != nil {
				return nil, fmt.Errorf("invalid toolkit version %q", value)
			}
			parsed[i] = number
		}
		return parsed, nil
	}
	leftParts, err := parse(left)
	if err != nil {
		return 0, err
	}
	rightParts, err := parse(right)
	if err != nil {
		return 0, err
	}
	width := len(leftParts)
	if len(rightParts) > width {
		width = len(rightParts)
	}
	for i := 0; i < width; i++ {
		var leftPart, rightPart uint64
		if i < len(leftParts) {
			leftPart = leftParts[i]
		}
		if i < len(rightParts) {
			rightPart = rightParts[i]
		}
		if leftPart < rightPart {
			return -1, nil
		}
		if leftPart > rightPart {
			return 1, nil
		}
	}
	return 0, nil
}

func classifyToolkit(probe ToolkitProbe, localVersion string) (ToolkitRelation, error) {
	if !probe.Present {
		return ToolkitMissing, nil
	}
	comparison, err := compareToolkitVersions(probe.Version, localVersion)
	if err != nil {
		return "", err
	}
	if comparison < 0 {
		return ToolkitOlder, nil
	}
	if comparison > 0 {
		return ToolkitNewer, nil
	}
	if !probe.Complete {
		return ToolkitSameIncomplete, nil
	}
	return ToolkitSameComplete, nil
}

func parseDiagnosticProtocol(stdout string) (DiagResult, error) {
	payload, err := extractCurrentOrLegacyBlock(stdout, diagBegin, diagEnd, legacyDiagBegin, legacyDiagEnd)
	if err != nil {
		return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: %w", err)
	}
	result := DiagResult{OK: true}
	records := 0
	for _, raw := range strings.Split(payload, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		switch fields[0] {
		case "PASS":
			if len(fields) != 4 || !diagCodePattern.MatchString(fields[1]) || (fields[2] == "" && fields[3] == "") {
				return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: malformed PASS record")
			}
			result.Passes = append(result.Passes, DiagItem{Code: fields[1], ZH: fields[2], EN: fields[3]})
		case "ISSUE":
			if len(fields) != 7 || !diagCodePattern.MatchString(fields[1]) {
				return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: malformed ISSUE record")
			}
			severity := fields[2]
			if severity != "INFO" && severity != "WARN" && severity != "ERROR" {
				return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: invalid severity %q", severity)
			}
			autoRepair, boolErr := strconv.ParseBool(fields[4])
			if boolErr != nil || (fields[5] == "" && fields[6] == "") {
				return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: malformed ISSUE fields")
			}
			result.Issues = append(result.Issues, DiagItem{
				Code: fields[1], Severity: severity, Action: fields[3], AutoRepair: autoRepair, ZH: fields[5], EN: fields[6],
			})
			if severity == "ERROR" {
				result.OK = false
			}
		default:
			return DiagResult{}, fmt.Errorf("diagnostic protocol rejected: unknown record type %q", fields[0])
		}
		records++
	}
	if records == 0 {
		return DiagResult{}, errors.New("diagnostic protocol rejected: no records")
	}
	return result, nil
}

func sanitizeSSHStderr(value string) string {
	var kept []string
	for _, raw := range strings.Split(strings.ReplaceAll(stripANSI(value), "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || closedPattern.MatchString(line) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

func shouldContinueAfterWizard(exitCode int) bool {
	return exitCode == 0
}
