package main

import (
	"bufio"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const cdnRouteInputDir = "/root/.config/proxy-node-assistant/runtime-input"

var (
	cdnLookupIP    = net.LookupIP
	cdnDial        = net.DialTimeout
	cdnRootCapture = func(a *App, c Connection, command string) ProcessResult {
		return a.rootCapture(c, command)
	}
	cdnRemotePublicIP = func(a *App, c Connection) (string, error) {
		return a.remotePublicIP(c)
	}
	cdnRequestClientProof = func(a *App, link string) error {
		// Existing nodes may still emit the v0.9.x TNA fragment.  Keep the
		// legacy URI readable for validation, but canonicalize its presentation
		// label before it is shown/copied by the protected handoff.  The helper
		// preserves the raw query (including optional XHTTP x_padding_bytes and
		// extra parameters) instead of rebuilding a reduced URI.
		canonicalLink, canonicalErr := canonicalizeCDNXHTTPHandoffURL(link)
		if canonicalErr != nil {
			return fmt.Errorf("CDN validation link could not be canonicalized: %w", canonicalErr)
		}
		link = canonicalLink
		if err := a.secretHandoff("CDN XHTTP 8443 VALIDATION LINK", link); err != nil {
			return fmt.Errorf("could not hand off the CDN validation link: %w", err)
		}
		answer := a.prompt(a.msg(
			"把上面的 8443 XHTTP 链接导入客户端并真实浏览成功后，精确输入大写 REAL BROWSE OK；其他输入会回滚本次线路切换",
			"Import the 8443 XHTTP link, browse through it successfully, then type uppercase REAL BROWSE OK exactly; any other input rolls back this route change",
		))
		if a.inputClosed {
			return errInputClosed
		}
		if answer != "REAL BROWSE OK" {
			return errors.New(a.msg("未收到真实客户端验货确认。", "Real client validation was not confirmed."))
		}
		return nil
	}
	cdnHTTPDo = func(request *http.Request) (*http.Response, error) {
		client := &http.Client{
			Transport: &http.Transport{Proxy: nil},
			Timeout:   35 * time.Second,
			CheckRedirect: func(next *http.Request, previous []*http.Request) error {
				if len(previous) >= 5 {
					return errors.New("too many CDN validation redirects")
				}
				if !strings.EqualFold(next.URL.Hostname(), previous[0].URL.Hostname()) || next.URL.Port() != "8443" {
					return errors.New("CDN validation redirect left the selected hostname:8443")
				}
				return nil
			},
		}
		return client.Do(request)
	}
)

// prepareCDNPrerequisites performs only local, read-only checks. RouteKeep is
// deliberately a true no-op, while gray does not depend on Cloudflare.
func (a *App) prepareCDNPrerequisites(c Connection, plan InstallPlan, publicIP string) error {
	_ = c
	if plan.Preferences.RouteMode == RouteKeep || plan.Preferences.RouteMode == RouteGray {
		return nil
	}
	if err := plan.validateFor(true); err != nil {
		return fmt.Errorf("invalid CDN route plan: %w", err)
	}
	origin := net.ParseIP(strings.TrimSpace(publicIP))
	if origin == nil || origin.To4() == nil {
		return errors.New(a.msg("CDN 施工前无法确认 VPS 公网 IPv4。", "The VPS public IPv4 could not be confirmed before CDN construction."))
	}
	addresses, err := cdnLookupIP(plan.Orange.Domain)
	if err != nil || len(addresses) == 0 {
		return fmt.Errorf(a.msg("橙云域名无法通过本机公网 DNS 解析：%s", "The orange-cloud hostname did not resolve through public DNS: %s"), plan.Orange.Domain)
	}
	for _, address := range addresses {
		if address.To4() != nil && address.Equal(origin) {
			return fmt.Errorf(a.msg("橙云域名仍直接暴露源站 IPv4；请先开启 Cloudflare 代理：%s", "The orange-cloud hostname still exposes the origin IPv4; enable Cloudflare proxying first: %s"), plan.Orange.Domain)
		}
	}
	return nil
}

func randomCDNRouteInputPath() (string, error) {
	path, err := randomOneRunInputPath()
	if err != nil {
		return "", err
	}
	token := strings.TrimPrefix(path, "/tmp/proxy-node-assistant-auto-input-")
	if token == path || token == "" || strings.ContainsAny(token, "/\\\r\n") {
		return "", errors.New("could not create a safe CDN route input name")
	}
	return cdnRouteInputDir + "/cdn-route-" + token + ".env", nil
}

func buildCDNRouteInputCopyCommand(sourcePath, destinationPath string, mode RouteMode, publicIP string) (string, error) {
	if !strings.HasPrefix(sourcePath, "/tmp/proxy-node-assistant-auto-input-") || strings.ContainsAny(sourcePath, "\r\n") {
		return "", errors.New("unsafe core input path")
	}
	if !strings.HasPrefix(destinationPath, cdnRouteInputDir+"/cdn-route-") || !strings.HasSuffix(destinationPath, ".env") || strings.ContainsAny(destinationPath, "\r\n") {
		return "", errors.New("unsafe CDN input path")
	}
	if mode != RouteOrange && mode != RouteDual {
		return "", fmt.Errorf("CDN input is not valid for route %q", mode)
	}
	parsed := net.ParseIP(publicIP)
	if parsed == nil || parsed.To4() == nil {
		return "", errors.New("invalid public IPv4")
	}
	encode := func(value string) string { return base64.StdEncoding.EncodeToString([]byte(value)) }
	return "set -Eeuo pipefail; umask 077; " +
		"case " + shQuote(sourcePath) + " in /tmp/proxy-node-assistant-auto-input-*) ;; *) exit 143;; esac; " +
		"[ -f " + shQuote(sourcePath) + " ] && [ ! -L " + shQuote(sourcePath) + " ] && [ \"$(stat -c '%u:%a' " + shQuote(sourcePath) + ")\" = 0:600 ]; " +
		"install -d -m 700 " + shQuote(cdnRouteInputDir) + "; test ! -e " + shQuote(destinationPath) + "; " +
		"{ printf '%s\\n' " + shQuote("TNA_CDN_ROUTE_INPUT_VERSION=1") + " " +
		shQuote("ROUTE_MODE_B64="+encode(string(mode))) + " " + shQuote("PUBLIC_IPV4_B64="+encode(parsed.String())) +
		"; awk -F= '$1 == \"ORANGE_DOMAIN_B64\" || $1 == \"ORANGE_EMAIL_B64\" || $1 == \"GRAY_DOMAIN_B64\" {print}' " + shQuote(sourcePath) +
		"; } | install -m 600 /dev/stdin " + shQuote(destinationPath), nil
}

func cdnRouteAction(mode RouteMode, grayDomain string) (string, error) {
	switch mode {
	case RouteKeep:
		return "", nil
	case RouteGray:
		if !validDomain(grayDomain) {
			return "", errors.New("gray route requires a valid domain")
		}
		return "bash " + remoteRoot + "/linux/28-topology-reconcile.sh --to-gray " + shQuote(grayDomain), nil
	case RouteOrange, RouteDual:
		return "staged", nil
	default:
		return "", fmt.Errorf("unsupported route mode %q", mode)
	}
}

func validateCDNEdgeResponse(response *http.Response, expectedDomain string) error {
	if response == nil {
		return errors.New("CDN edge returned no response")
	}
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return fmt.Errorf("CDN edge returned HTTP %d", response.StatusCode)
	}
	if response.Request == nil || response.Request.URL == nil || !strings.EqualFold(response.Request.URL.Hostname(), expectedDomain) || response.Request.URL.Port() != "8443" {
		return errors.New("CDN edge response did not remain on the selected hostname:8443")
	}
	if strings.TrimSpace(response.Header.Get("Cf-Ray")) == "" {
		return errors.New("CDN edge response has no Cf-Ray proof")
	}
	if !strings.EqualFold(strings.TrimSpace(response.Header.Get("X-TNA-Managed-Origin")), "cdn-xhttp-v095") {
		return errors.New("CDN edge response did not prove the managed origin")
	}
	if strings.TrimSpace(response.Header.Get("X-TNA-Origin-Port")) != "8443" {
		return errors.New("CDN edge response did not prove origin port 8443")
	}
	return nil
}

func validateCDNEdge(domain string) error {
	request, err := http.NewRequest(http.MethodGet, "https://"+domain+":8443/", nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "ProxyNodeAssistant-CDN-Validator/1.0.0")
	response, err := cdnHTTPDo(request)
	if err != nil {
		return fmt.Errorf("CDN edge HTTPS validation failed: %w", err)
	}
	defer response.Body.Close()
	return validateCDNEdgeResponse(response, domain)
}

func validateCDNOriginLocked(publicIP string) error {
	connection, err := cdnDial("tcp", net.JoinHostPort(publicIP, "8443"), 5*time.Second)
	if err != nil {
		return nil
	}
	_ = connection.Close()
	return errors.New("direct origin TCP/8443 is reachable outside Cloudflare")
}

func firstVLESSLink(output string) string {
	scanner := bufio.NewScanner(strings.NewReader(strings.ReplaceAll(output, "\r\n", "\n")))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(strings.ToLower(line), "vless://") {
			return line
		}
		// The remote exporter uses a named protocol field rather than printing
		// a naked URI.  Accept only that exact field name; treating arbitrary
		// log text containing vless:// as a credential would repeat the old
		// handoff-parsing bug.
		if strings.HasPrefix(line, "XHTTP_LINK=") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "XHTTP_LINK="))
			if strings.HasPrefix(strings.ToLower(value), "vless://") {
				return value
			}
		}
	}
	return ""
}

func validateCDNShareLink(raw, expectedDomain string) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || !strings.EqualFold(parsed.Scheme, "vless") {
		return errors.New("CDN share link is not a valid VLESS URI")
	}
	if !strings.EqualFold(parsed.Hostname(), expectedDomain) || parsed.Port() != "8443" {
		return errors.New("CDN share link must use the selected orange hostname on port 8443")
	}
	query := parsed.Query()
	if !strings.EqualFold(query.Get("type"), "xhttp") {
		return errors.New("CDN share link is not XHTTP")
	}
	if !strings.EqualFold(query.Get("security"), "tls") {
		return errors.New("CDN share link does not require TLS")
	}
	if sni := query.Get("sni"); sni != "" && !strings.EqualFold(sni, expectedDomain) {
		return errors.New("CDN share link SNI does not match the orange hostname")
	}
	if host := query.Get("host"); host != "" && !strings.EqualFold(host, expectedDomain) {
		return errors.New("CDN share link Host does not match the orange hostname")
	}
	if path := query.Get("path"); path == "" || !strings.HasPrefix(path, "/") {
		return errors.New("CDN share link has no valid XHTTP path")
	}
	if parsed.User == nil || strings.TrimSpace(parsed.User.Username()) == "" {
		return errors.New("CDN share link has no client identity")
	}
	return nil
}

func cdnProcessHasMarker(result ProcessResult, marker string) bool {
	return strings.Contains(result.Stdout, marker) || strings.Contains(result.Stderr, marker)
}

// reconcileCDNRoute is the only CDN topology mutation entry point. It stages
// orange/dual behind Cloudflare, validates it from Windows, and only then
// commits the topology. Any failure after staging asks the remote transaction
// helper to restore the pre-change state.
func (a *App) reconcileCDNRoute(c Connection, plan InstallPlan, inputPath string) error {
	mode := plan.Preferences.RouteMode
	action, err := cdnRouteAction(mode, plan.Gray.Domain)
	if err != nil {
		return err
	}
	if mode == RouteKeep {
		return nil
	}
	if err := plan.validateFor(true); err != nil {
		return fmt.Errorf("invalid route reconciliation plan: %w", err)
	}
	if mode == RouteGray {
		result := cdnRootCapture(a, c, action)
		if !result.OK() || !strings.Contains(result.Stdout, "TNA_TOPOLOGY_RECONCILED=1") || !strings.Contains(result.Stdout, "TOPOLOGY_MODE=gray") {
			return fmt.Errorf("gray route reconciliation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
		}
		return nil
	}

	publicIP, err := cdnRemotePublicIP(a, c)
	if err != nil {
		return err
	}
	if err := a.prepareCDNPrerequisites(c, plan, publicIP); err != nil {
		return err
	}
	runtimeInput, err := randomCDNRouteInputPath()
	if err != nil {
		return err
	}
	copyCommand, err := buildCDNRouteInputCopyCommand(inputPath, runtimeInput, mode, publicIP)
	if err != nil {
		return err
	}
	copyResult := cdnRootCapture(a, c, copyCommand)
	if !copyResult.OK() {
		return fmt.Errorf("could not prepare root-only CDN route input (exit %d): %s", copyResult.ExitCode, processFailureDetail(copyResult))
	}
	defer cdnRootCapture(a, c, "rm -f -- "+shQuote(runtimeInput))

	staged := false
	rollback := func(cause error) error {
		if !staged {
			return cause
		}
		result := cdnRootCapture(a, c, "bash "+remoteRoot+"/linux/28-topology-reconcile.sh --rollback-pending")
		// NOTHING_PENDING is deliberately not accepted as proof of rollback. It
		// is ambiguous after a lost finalize response: the remote side may have
		// committed and removed the transaction before the SSH channel failed.
		// Only the marker emitted after a complete restore is safe evidence.
		if !result.OK() || !cdnProcessHasMarker(result, "TNA_TOPOLOGY_ROLLED_BACK=1") {
			return fmt.Errorf("%v; automatic CDN rollback also failed (exit %d): %s", cause, result.ExitCode, processFailureDetail(result))
		}
		return cause
	}
	stageResult := cdnRootCapture(a, c, "bash "+remoteRoot+"/linux/28-topology-reconcile.sh --apply-input "+shQuote(runtimeInput))
	// Even a zero exit without the full success marker may have crossed the
	// transaction boundary.  Rollback is idempotent and is therefore safer.
	staged = true
	if !stageResult.OK() || !strings.Contains(stageResult.Stdout, "TNA_TOPOLOGY_STAGED=1") || !strings.Contains(stageResult.Stdout, "CDN_EDGE_PORT=8443") {
		cause := fmt.Errorf("CDN route staging failed (exit %d): %s", stageResult.ExitCode, processFailureDetail(stageResult))
		// The remote apply helper has its own ERR/INT/TERM trap and reports a
		// completed restore on stderr. Do not issue a second rollback after that
		// positive proof; all other incomplete/markerless stage failures still
		// go through the explicit rollback path above.
		if cdnProcessHasMarker(stageResult, "TNA_TOPOLOGY_ROLLED_BACK=1") {
			return cause
		}
		return rollback(cause)
	}
	if err := validateCDNEdge(plan.Orange.Domain); err != nil {
		return rollback(err)
	}
	if err := validateCDNOriginLocked(publicIP); err != nil {
		return rollback(err)
	}
	linkResult := cdnRootCapture(a, c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh link "+shQuote(plan.Orange.Domain)+" 8443")
	if !linkResult.OK() {
		return rollback(fmt.Errorf("CDN share link export failed (exit %d): %s", linkResult.ExitCode, processFailureDetail(linkResult)))
	}
	link := firstVLESSLink(linkResult.Stdout)
	if err := validateCDNShareLink(link, plan.Orange.Domain); err != nil {
		return rollback(err)
	}
	if err := cdnRequestClientProof(a, link); err != nil {
		return rollback(err)
	}
	confirmResult := cdnRootCapture(a, c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh --confirm-client "+shQuote(plan.Orange.Domain))
	if !confirmResult.OK() || !strings.Contains(confirmResult.Stdout, "CDN_CLIENT_CONFIRMED=1") {
		return rollback(fmt.Errorf("CDN client confirmation failed (exit %d): %s", confirmResult.ExitCode, processFailureDetail(confirmResult)))
	}
	finalResult := cdnRootCapture(a, c, "bash "+remoteRoot+"/linux/28-topology-reconcile.sh --finalize")
	if !finalResult.OK() || !strings.Contains(finalResult.Stdout, "TNA_TOPOLOGY_RECONCILED=1") || !strings.Contains(finalResult.Stdout, "TOPOLOGY_MODE="+string(mode)) {
		return rollback(fmt.Errorf("CDN route finalization failed (exit %d): %s", finalResult.ExitCode, processFailureDetail(finalResult)))
	}
	return nil
}
