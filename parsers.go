package main

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const (
	handoffBegin = "__PNA_HANDOFF_BEGIN__"
	handoffEnd   = "__PNA_HANDOFF_END__"
	panelBegin   = "__PNA_PANEL_META_BEGIN__"
	panelEnd     = "__PNA_PANEL_META_END__"
	statusBegin  = "__PNA_RUN_STATUS_BEGIN__"
	statusEnd    = "__PNA_RUN_STATUS_END__"
	diagBegin    = "__PNA_DIAG_V1_BEGIN__"
	diagEnd      = "__PNA_DIAG_V1_END__"
	toolkitBegin = "__PNA_TOOLKIT_PROBE_BEGIN__"
	toolkitEnd   = "__PNA_TOOLKIT_PROBE_END__"

	// v0.9.5 used the TNA marker namespace.  Keep these aliases while the
	// reset line emits PNA markers so an existing toolkit can still be queried
	// and its handoff/diagnostic payload can be validated during migration.
	legacyHandoffBegin = "__TNA_HANDOFF_BEGIN__"
	legacyHandoffEnd   = "__TNA_HANDOFF_END__"
	legacyPanelBegin   = "__TNA_PANEL_META_BEGIN__"
	legacyPanelEnd     = "__TNA_PANEL_META_END__"
	legacyStatusBegin  = "__TNA_RUN_STATUS_BEGIN__"
	legacyStatusEnd    = "__TNA_RUN_STATUS_END__"
	legacyDiagBegin    = "__TNA_DIAG_V1_BEGIN__"
	legacyDiagEnd      = "__TNA_DIAG_V1_END__"
	legacyToolkitBegin = "__TNA_TOOLKIT_PROBE_BEGIN__"
	legacyToolkitEnd   = "__TNA_TOOLKIT_PROBE_END__"
)

var ansiPattern = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)
var closedPattern = regexp.MustCompile(`(?i)^Connection to .+ closed\.$`)
var diagCodePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
var toolkitVersionPattern = regexp.MustCompile(`^v?[0-9]+(?:\.[0-9]+){1,3}$`)
var toolkitBuildPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

type ToolkitProbe struct {
	Present       bool
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
	depth := 0
	foundEnd := false
	var payload []string
	for _, raw := range lines {
		line := strings.TrimSuffix(raw, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == begin {
			depth++
			continue
		}
		if depth > 0 && trimmed == end {
			depth--
			if depth == 0 {
				foundEnd = true
				break
			}
			continue
		}
		if depth > 0 {
			payload = append(payload, line)
		}
	}
	if depth != 0 || !foundEnd {
		return "", errors.New("required output markers were not found")
	}
	result := strings.TrimSpace(strings.Join(payload, "\n"))
	if result == "" {
		return "", errors.New("marked output was empty")
	}
	return result, nil
}

// Compatibility spelling used by the v0.9.5 protocol helpers.
func extractMarkerBlock(stdout, begin, end string) (string, error) {
	return extractMarkedBlock(stdout, begin, end)
}

// extractMarkerBlockCurrentOrLegacy accepts the current protocol marker pair
// and falls back to the v0.9.x/PNA marker pair.  A few remote helpers retain
// the legacy marker names so an existing node can be upgraded in place; keep
// the fallback in one place instead of making every caller duplicate it.
func extractMarkerBlockCurrentOrLegacy(stdout, begin, end, legacyBegin, legacyEnd string) (string, error) {
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

// extractCurrentOrLegacyBlock is the historical helper name used by a few
// v0.9.x callers.  Keep it as a thin alias so an in-place upgrade can compile
// and parse old protocol output without carrying a second implementation.
func extractCurrentOrLegacyBlock(stdout, begin, end, legacyBegin, legacyEnd string) (string, error) {
	return extractMarkerBlockCurrentOrLegacy(stdout, begin, end, legacyBegin, legacyEnd)
}

// parseDeviceKV parses the line-oriented key/value payload emitted by the
// remote identity, operation, and IP-rebind scripts.  It intentionally shares
// parseKV's newline handling and last-value-wins semantics with the rest of
// the protocol parsers while retaining the historical helper name used by the
// v0.9.x code.
func parseDeviceKV(block string) map[string]string {
	return parseKV(block)
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
	payload, err := extractMarkerBlockCurrentOrLegacy(stdout, handoffBegin, handoffEnd, legacyHandoffBegin, legacyHandoffEnd)
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
		"SS2022_PASSWORD", "SS2022_LINK", "SS2022_SERVER_ADDRESS",
		"CDN_XHTTP_LINK", "CDN_XHTTP_STAGE_LINK", "CDN_XHTTP_SUBSCRIPTION_URL",
		"CDN_XHTTP_UUID", "CDN_XHTTP_PATH", "SUBSCRIPTION_URL", "SUBSCRIPTION_LINK",
		"REALITY_CLIENT_1_LINK", "REALITY_CLIENT_1_SUBSCRIPTION_URL",
	}
	for _, key := range useful {
		if strings.TrimSpace(kv[key]) != "" {
			return payload, nil
		}
	}
	// Client indexes are intentionally open-ended.  A node may disable its
	// first client while retaining a later one; rejecting that handoff would
	// strand valid credentials and subscription links during migration.
	for key, value := range kv {
		if strings.TrimSpace(value) == "" {
			continue
		}
		if strings.HasPrefix(key, "REALITY_CLIENT_") && (strings.HasSuffix(key, "_LINK") || strings.HasSuffix(key, "_SUBSCRIPTION_URL") || strings.HasSuffix(key, "_UUID")) {
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
	payload, err := extractMarkerBlockCurrentOrLegacy(stdout, panelBegin, panelEnd, legacyPanelBegin, legacyPanelEnd)
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
	payload, err := extractMarkerBlockCurrentOrLegacy(stdout, statusBegin, statusEnd, legacyStatusBegin, legacyStatusEnd)
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
	payload, err := extractMarkerBlockCurrentOrLegacy(stdout, toolkitBegin, toolkitEnd, legacyToolkitBegin, legacyToolkitEnd)
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
	return ToolkitProbe{Present: true, Version: strings.TrimPrefix(version, "v"), BuildID: buildID, BuildRevision: buildRevision, Complete: complete}, nil
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

// sameVersionIncompleteRepairAllowed is the narrow overwrite policy used by
// menu [1].  A partial toolkit cannot be used by the other actions, but it is
// safe for the explicit deploy flow to replace the managed program directory
// after the user confirms APPLY.  Keep the monotonic build guard: a partial
// probe carrying a newer revision (or the same revision with a different,
// non-empty build ID) must not be downgraded by an older EXE.  Revision 0 and
// an empty ID mean the metadata was not written before the interrupted upload;
// those are precisely the cases this repair path is intended to recover.
func sameVersionIncompleteRepairAllowed(probe ToolkitProbe) bool {
	if !probe.Present || probe.Complete || probe.Version != toolkitVersion || probe.BuildRevision < 0 {
		return false
	}
	if probe.BuildRevision > toolkitBuildRevision {
		return false
	}
	if probe.BuildRevision == toolkitBuildRevision && probe.BuildID != "" && probe.BuildID != toolkitBuildID {
		return false
	}
	return true
}

// sameVersionToolkitOnlyUpdateRequired identifies the narrow package-refresh
// path used by menu [1].  A clearly older complete build or an allowed
// interrupted same-version upload may be replaced after APPLY; older 0.9.x
// versions and divergent/newer v1 builds must continue through the full
// migration or downgrade guard instead.
func sameVersionToolkitOnlyUpdateRequired(probe ToolkitProbe) bool {
	if !probe.Present || probe.Version != toolkitVersion {
		return false
	}
	if !probe.Complete {
		return sameVersionIncompleteRepairAllowed(probe)
	}
	return compareToolkitBuild(probe, toolkitBuildID, toolkitBuildRevision) == -1
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
	payload, err := extractMarkerBlockCurrentOrLegacy(stdout, diagBegin, diagEnd, legacyDiagBegin, legacyDiagEnd)
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
