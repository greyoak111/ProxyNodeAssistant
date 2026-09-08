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

// CDNXHTTPLink is the strict, non-secret shape of an XHTTP VLESS handoff.
// It is retained for the manual topology controls; unrelated legacy service
// data is intentionally not represented here.
type CDNXHTTPLink struct {
	UUID   string
	Domain string
	Port   int
	Path   string
	Label  string
}

var cdnCompatUUIDPattern = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$`)
var cdnCompatHostnamePattern = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$`)
var cdnCompatXHTTPPathPattern = regexp.MustCompile(`^/[0-9a-f]{32}/$`)

// PNA labels are the only labels emitted by the v1 formatter.  The TNA
// spellings (and the historical ORANGE spelling used by early 0.9.x builds)
// remain parseable so an in-place upgrade can consume a link already present
// in a saved handoff.  They are deliberately not emitted by this package.
const (
	cdnXHTTPLabel       = "PNA-CDN-XHTTP"
	cdnXHTTPStageLabel  = "PNA-CDN-XHTTP-STAGE"
	cdnXHTTPOrangeLabel = "PNA-CDN-XHTTP-ORANGE"
)

func acceptedCDNXHTTPLabels(port int) map[string]struct{} {
	labels := map[string]struct{}{}
	if port == 8443 {
		labels[cdnXHTTPStageLabel] = struct{}{}
		labels[cdnXHTTPOrangeLabel] = struct{}{}
		labels["TNA-CDN-XHTTP-STAGE"] = struct{}{}
		labels["TNA-CDN-XHTTP-ORANGE"] = struct{}{}
		return labels
	}
	labels[cdnXHTTPLabel] = struct{}{}
	labels[cdnXHTTPOrangeLabel] = struct{}{}
	labels["TNA-CDN-XHTTP"] = struct{}{}
	labels["TNA-CDN-XHTTP-ORANGE"] = struct{}{}
	return labels
}

// canonicalCDNXHTTPLabel maps a parsed (possibly legacy) label to the
// product-neutral v1 spelling.  Parsing deliberately accepts the historical
// TNA fragments, but any code that wants to re-emit a link after importing it
// should pass the profile through this helper first.  The stage/production
// distinction is preserved; only the product prefix is migrated.
func canonicalCDNXHTTPLabel(port int, label string) (string, bool) {
	switch {
	case port == 8443 && (label == cdnXHTTPStageLabel || label == "TNA-CDN-XHTTP-STAGE"):
		return cdnXHTTPStageLabel, true
	case port == 8443 && (label == cdnXHTTPOrangeLabel || label == "TNA-CDN-XHTTP-ORANGE"):
		return cdnXHTTPOrangeLabel, true
	case port == 443 && (label == cdnXHTTPLabel || label == "TNA-CDN-XHTTP"):
		return cdnXHTTPLabel, true
	case port == 443 && (label == cdnXHTTPOrangeLabel || label == "TNA-CDN-XHTTP-ORANGE"):
		return cdnXHTTPOrangeLabel, true
	default:
		return "", false
	}
}

// canonicalizeCDNXHTTPProfile validates an imported profile and returns the
// v1 PNA label for it.  It is intentionally separate from
// buildCDNXHTTPLink: the latter remains a lossless compatibility formatter
// for callers/tests that need to round-trip an old handoff byte-for-byte.
func canonicalizeCDNXHTTPProfile(profile CDNXHTTPLink) (CDNXHTTPLink, error) {
	if err := validateCDNXHTTPProfile(profile); err != nil {
		return CDNXHTTPLink{}, err
	}
	label, ok := canonicalCDNXHTTPLabel(profile.Port, profile.Label)
	if !ok {
		// validateCDNXHTTPProfile already checked the accepted set; this guard
		// keeps the canonicalizer fail-closed if that set is extended later.
		return CDNXHTTPLink{}, errors.New("CDN XHTTP link has no canonical v1 label")
	}
	profile.Label = label
	return profile, nil
}

// buildCanonicalCDNXHTTPLink is the v1 emission path.  Legacy links may be
// imported and normalized without weakening the strict field validation.
func buildCanonicalCDNXHTTPLink(profile CDNXHTTPLink) (string, error) {
	canonical, err := canonicalizeCDNXHTTPProfile(profile)
	if err != nil {
		return "", err
	}
	return buildCDNXHTTPLink(canonical)
}

// canonicalizeCDNXHTTPURL migrates the fragment of an imported link while
// preserving every query parameter byte-for-byte.  Older XHTTP links may
// carry optional transport knobs (for example x_padding_bytes/extra) that
// are intentionally outside CDNXHTTPLink's strict identity fields.  Rebuild
// through buildCanonicalCDNXHTTPLink would silently discard those knobs, so
// output paths that start from a raw remote URI should use this helper.
func canonicalizeCDNXHTTPURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	profile, err := parseCDNXHTTPLink(trimmed)
	if err != nil {
		return "", err
	}
	label, ok := canonicalCDNXHTTPLabel(profile.Port, profile.Label)
	if !ok {
		return "", errors.New("CDN XHTTP link has no canonical v1 label")
	}
	// Replace only the fragment in the original byte sequence.  Calling
	// url.URL.String() here can normalize/escape an otherwise valid RawQuery;
	// XHTTP links may carry optional x_padding_bytes/extra knobs whose exact
	// spelling must survive an in-place handoff migration.
	fragmentStart := strings.LastIndex(trimmed, "#")
	if fragmentStart < 0 {
		return "", errors.New("CDN XHTTP link has no profile fragment")
	}
	return trimmed[:fragmentStart+1] + label, nil
}

// canonicalizeCDNXHTTPHandoffURL is a compatibility formatter for values
// recovered from a v0.9.x handoff.  Early exporters did not always include
// every query key required by the current strict parser, but they still
// carried the same authenticated XHTTP shape.  Keep this fallback limited to
// a VLESS URI, a UUID, a valid hostname/443-or-8443 endpoint, the XHTTP/TLS
// transport markers, and a recognized legacy fragment.  It is used only while
// migrating a saved handoff; newly generated links continue to use the strict
// canonicalizer above.  As with the strict path, the original RawQuery is
// retained byte-for-byte.
func canonicalizeCDNXHTTPHandoffURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if canonical, err := canonicalizeCDNXHTTPURL(trimmed); err == nil {
		return canonical, nil
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || !strings.EqualFold(parsed.Scheme, "vless") || parsed.User == nil {
		return "", errors.New("invalid legacy CDN XHTTP VLESS URL")
	}
	userinfo := parsed.User.String()
	if userinfo == "" || parsed.User.Username() != userinfo || !cdnCompatUUIDPattern.MatchString(parsed.User.Username()) {
		return "", errors.New("legacy CDN XHTTP URL has an invalid UUID")
	}
	domain := parsed.Hostname()
	if !cdnCompatHostnamePattern.MatchString(domain) {
		return "", errors.New("legacy CDN XHTTP URL has an invalid hostname")
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil || (port != 443 && port != 8443) {
		return "", errors.New("legacy CDN XHTTP URL has an invalid port")
	}
	query := parsed.Query()
	if !strings.EqualFold(query.Get("type"), "xhttp") || !strings.EqualFold(query.Get("security"), "tls") {
		return "", errors.New("legacy CDN XHTTP URL is not TLS/XHTTP")
	}
	if value := query.Get("sni"); value != "" && !strings.EqualFold(value, domain) {
		return "", errors.New("legacy CDN XHTTP URL SNI does not match its hostname")
	}
	if value := query.Get("host"); value != "" && !strings.EqualFold(value, domain) {
		return "", errors.New("legacy CDN XHTTP URL host does not match its hostname")
	}
	path := query.Get("path")
	if path == "" || !strings.HasPrefix(path, "/") || strings.ContainsAny(path, "\r\n\t ?#\\") {
		return "", errors.New("legacy CDN XHTTP URL has an invalid path")
	}
	label, ok := canonicalCDNXHTTPLabel(port, parsed.Fragment)
	if !ok {
		return "", errors.New("legacy CDN XHTTP URL has an unrecognized profile fragment")
	}
	fragmentStart := strings.LastIndex(trimmed, "#")
	if fragmentStart < 0 {
		return "", errors.New("legacy CDN XHTTP URL has no profile fragment")
	}
	return trimmed[:fragmentStart+1] + label, nil
}

func validateCDNXHTTPProfile(profile CDNXHTTPLink) error {
	if !cdnCompatUUIDPattern.MatchString(profile.UUID) {
		return errors.New("CDN XHTTP link has an invalid UUID")
	}
	if !cdnCompatHostnamePattern.MatchString(profile.Domain) {
		return errors.New("CDN XHTTP link has an invalid hostname")
	}
	if profile.Port != 443 && profile.Port != 8443 {
		return errors.New("CDN XHTTP link port must be 443 or 8443")
	}
	if !cdnCompatXHTTPPathPattern.MatchString(profile.Path) {
		return errors.New("CDN XHTTP link path must be / plus 32 lowercase hex characters plus /")
	}
	if _, ok := acceptedCDNXHTTPLabels(profile.Port)[profile.Label]; !ok {
		if profile.Port == 8443 {
			return fmt.Errorf("CDN XHTTP link label must be %s (legacy TNA labels are accepted for import)", cdnXHTTPStageLabel)
		}
		return fmt.Errorf("CDN XHTTP link label must be %s (legacy TNA labels are accepted for import)", cdnXHTTPLabel)
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
		Scheme: "vless", User: url.User(profile.UUID),
		Host:     net.JoinHostPort(profile.Domain, strconv.Itoa(profile.Port)),
		RawQuery: query.Encode(), Fragment: profile.Label,
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
		"encryption": "none", "security": "tls", "sni": parsed.Hostname(),
		"fp": "chrome", "type": "xhttp", "host": parsed.Hostname(), "mode": "packet-up",
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
	profile := CDNXHTTPLink{UUID: parsed.User.Username(), Domain: parsed.Hostname(), Port: port, Path: paths[0], Label: parsed.Fragment}
	if err := validateCDNXHTTPProfile(profile); err != nil {
		return CDNXHTTPLink{}, err
	}
	return profile, nil
}
