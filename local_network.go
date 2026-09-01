package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type publicIPObservation struct {
	IP      string
	Sources []string
	Total   int
}

type publicIPProbeResult struct {
	source string
	ip     string
	err    error
}

var publicIPv4Endpoints = []string{
	"https://api.ipify.org",
	"https://checkip.amazonaws.com",
	"https://ipv4.icanhazip.com",
	"https://ifconfig.me/ip",
}

func directHTTPTransport() *http.Transport {
	dialer := &net.Dialer{Timeout: 6 * time.Second, KeepAlive: 15 * time.Second}
	return &http.Transport{
		Proxy:                 nil,
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     false,
		TLSHandshakeTimeout:   8 * time.Second,
		ResponseHeaderTimeout: 8 * time.Second,
		DisableKeepAlives:     true,
	}
}

func normalizePublicIPv4(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if fields := strings.Fields(value); len(fields) > 0 {
		value = fields[0]
	}
	ip := net.ParseIP(value)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() || ip.IsLoopback() || ip.IsPrivate() || ip.IsMulticast() {
		return "", false
	}
	return ip.To4().String(), true
}

func detectCurrentPublicIPv4(ctx context.Context, endpoints []string) (publicIPObservation, error) {
	if len(endpoints) == 0 {
		return publicIPObservation{}, errors.New("no public-IP endpoints configured")
	}
	client := &http.Client{Transport: directHTTPTransport(), Timeout: 10 * time.Second}
	results := make(chan publicIPProbeResult, len(endpoints))
	var wg sync.WaitGroup
	for _, endpoint := range endpoints {
		endpoint := endpoint
		wg.Add(1)
		go func() {
			defer wg.Done()
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
			if err != nil {
				results <- publicIPProbeResult{source: endpoint, err: err}
				return
			}
			resp, err := client.Do(req)
			if err != nil {
				results <- publicIPProbeResult{source: endpoint, err: err}
				return
			}
			defer resp.Body.Close()
			if resp.StatusCode < 200 || resp.StatusCode >= 300 {
				results <- publicIPProbeResult{source: endpoint, err: fmt.Errorf("HTTP %d", resp.StatusCode)}
				return
			}
			body, err := io.ReadAll(io.LimitReader(resp.Body, 128))
			if err != nil {
				results <- publicIPProbeResult{source: endpoint, err: err}
				return
			}
			ip, ok := normalizePublicIPv4(string(body))
			if !ok {
				results <- publicIPProbeResult{source: endpoint, err: errors.New("invalid IPv4 response")}
				return
			}
			results <- publicIPProbeResult{source: endpoint, ip: ip}
		}()
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	counts := map[string]int{}
	sources := map[string][]string{}
	total := 0
	for result := range results {
		if result.err != nil || result.ip == "" {
			continue
		}
		total++
		counts[result.ip]++
		sources[result.ip] = append(sources[result.ip], result.source)
	}
	if total == 0 {
		return publicIPObservation{}, errors.New("all direct public-IP lookups failed")
	}
	var candidates []string
	for ip := range counts {
		candidates = append(candidates, ip)
	}
	sort.Slice(candidates, func(i, j int) bool {
		if counts[candidates[i]] == counts[candidates[j]] {
			return candidates[i] < candidates[j]
		}
		return counts[candidates[i]] > counts[candidates[j]]
	})
	chosen := candidates[0]
	return publicIPObservation{IP: chosen, Sources: sources[chosen], Total: total}, nil
}

func localPublicIPv4() (publicIPObservation, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	return detectCurrentPublicIPv4(ctx, publicIPv4Endpoints)
}

type routeProbe struct {
	Name   string
	Target string
	Layer  string
	OK     bool
	Detail string
	Took   time.Duration
}

func tcpRouteProbe(name, host string, port int) routeProbe {
	probe := routeProbe{Name: name, Target: net.JoinHostPort(host, strconv.Itoa(port)), Layer: "TCP_GATE"}
	started := time.Now()
	conn, err := net.DialTimeout("tcp4", probe.Target, 8*time.Second)
	probe.Took = time.Since(started)
	if err != nil {
		probe.Detail = err.Error()
		return probe
	}
	_ = conn.Close()
	probe.OK = true
	probe.Detail = "TCP connected"
	return probe
}

func realityTLSRouteProbe(host string, port int, serverName string) routeProbe {
	probe := routeProbe{Name: "REALITY", Target: net.JoinHostPort(host, strconv.Itoa(port)), Layer: "TLS_CLIENT_HELLO"}
	started := time.Now()
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	conn, err := tls.DialWithDialer(dialer, "tcp4", probe.Target, &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: true, // Reachability probe; trust is reported by the real client.
		MinVersion:         tls.VersionTLS12,
		NextProtos:         []string{"h2", "http/1.1"},
	})
	probe.Took = time.Since(started)
	if err != nil {
		probe.Detail = err.Error()
		return probe
	}
	state := conn.ConnectionState()
	_ = conn.Close()
	probe.OK = true
	probe.Detail = fmt.Sprintf("TLS 0x%x; SNI=%s", state.Version, serverName)
	return probe
}

func cdnHTTPRouteProbe(domain string, port int) routeProbe {
	target := "https://" + net.JoinHostPort(domain, strconv.Itoa(port)) + "/"
	probe := routeProbe{Name: "CDN_XHTTP", Target: target, Layer: "HTTPS_EDGE_ORIGIN"}
	parsed, err := url.Parse(target)
	if err != nil {
		probe.Detail = err.Error()
		return probe
	}
	client := &http.Client{Transport: directHTTPTransport(), Timeout: 12 * time.Second}
	started := time.Now()
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, parsed.String(), nil)
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := client.Do(req)
	probe.Took = time.Since(started)
	if err != nil {
		probe.Detail = err.Error()
		return probe
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	probe.OK = resp.StatusCode >= 100 && resp.StatusCode <= 599
	probe.Detail = fmt.Sprintf("HTTP %d", resp.StatusCode)
	if ray := strings.TrimSpace(resp.Header.Get("CF-Ray")); ray != "" {
		probe.Detail += "; Cloudflare edge reached"
	}
	return probe
}

func (a *App) sshObservedSourceIPv4(c Connection) (string, error) {
	result := a.rootCapture(c, `value="${SSH_CONNECTION%% *}"; printf '%s\n' "$value"`)
	if !result.OK() {
		return "", fmt.Errorf("SSH source inspection failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	ip, ok := normalizePublicIPv4(strings.TrimSpace(result.Stdout))
	if !ok {
		return "", errors.New("VPS did not report a valid public IPv4 for this SSH connection")
	}
	return ip, nil
}

func (a *App) printRouteProbe(probe routeProbe) {
	state := "FAIL"
	if probe.OK {
		state = "GOOD"
	}
	a.println(fmt.Sprintf("[%s] %-10s layer=%s target=%s time=%s", state, probe.Name, probe.Layer, probe.Target, probe.Took.Round(time.Millisecond)))
	if probe.Detail != "" {
		a.println("  " + probe.Detail)
	}
}

func (a *App) runThreeRouteReachability(c Connection) {
	metadata, err := a.runtimePublicEnv(c)
	if err != nil {
		a.println(a.msg("[WARN] 无法读取三协议运行态：", "[WARN] Could not read three-route runtime metadata: ") + err.Error())
		return
	}
	// Runtime state is spread across the public env, deployment state, edge
	// state, and (during a staged migration) both the legacy and namespaced
	// topology files.  Read all of them in a deterministic order.  The route
	// selection below deliberately gives topology/deployment state precedence
	// over the older bootstrap value in public.env.
	result := a.rootCapture(c, strings.Join([]string{
		"cat /etc/proxy-runbook/public.env 2>/dev/null || true",
		"cat /etc/proxy-runbook/deployment-state.env 2>/dev/null || true",
		"cat /etc/text-node-assistant/deployment-state.env 2>/dev/null || true",
		"cat /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null || true",
		"cat /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null || true",
		"cat /root/.config/text-node-assistant/topology.env 2>/dev/null || true",
		"cat /root/.config/proxy-node-assistant/topology.env 2>/dev/null || true",
		"cat /etc/proxy-runbook/ss2022/service.env 2>/dev/null || true",
	}, "; "))
	if result.OK() {
		for key, value := range parseKV(result.Stdout) {
			// parseKV keeps the last occurrence.  The command above intentionally
			// emits legacy files first and namespaced/current files last, so an
			// upgraded topology must be allowed to replace stale public.env data.
			metadata[key] = value
		}
	}

	a.println()
	a.println(a.msg("—— 当前本地链路 → VPS 三协议到达性 ——", "—— CURRENT LOCAL PATH -> VPS THREE-PROTOCOL REACHABILITY ——"))
	a.println(a.msg("这些是入口分层探测；GOOD 表示相应网络/TLS/边缘层已到达，不等同于代理吞吐测速。", "These are layered entry probes. GOOD means the named network/TLS/edge layer was reached; it is not a proxy throughput benchmark."))

	routeMode := ""
	for _, candidate := range []string{metadata["TOPOLOGY_MODE"], metadata["ROUTE_MODE"], metadata["INSTALL_PLAN_ROUTE_MODE"]} {
		candidate = strings.ToLower(strings.TrimSpace(candidate))
		switch candidate {
		case "managed-gray":
			candidate = "gray"
		case "managed-orange":
			candidate = "orange"
		case "managed-dual":
			candidate = "dual"
		}
		if candidate == "gray" || candidate == "orange" || candidate == "dual" {
			routeMode = candidate
			break
		}
	}
	realityPort, _ := strconv.Atoi(metadata["REALITY_PRODUCTION_PORT"])
	if realityPort == 0 {
		realityPort = 443
	}
	realitySNI := ""
	for _, candidate := range []string{metadata["GRAY_DOMAIN"], metadata["REALITY_SNI"], metadata["COVER_DOMAIN"]} {
		if validDomain(candidate) {
			realitySNI = strings.TrimSpace(candidate)
			break
		}
	}
	if routeMode == "orange" {
		a.println(a.msg("[SKIP] REALITY：当前拓扑未配置 Reality 路由。", "[SKIP] REALITY: the current topology has no Reality route."))
	} else if validDomain(realitySNI) {
		a.printRouteProbe(realityTLSRouteProbe(c.Host, realityPort, realitySNI))
	} else {
		a.printRouteProbe(tcpRouteProbe("REALITY", c.Host, realityPort))
		a.println(a.msg("  未找到 Reality SNI，因此本次只验证 TCP 层。", "  Reality SNI was unavailable, so only the TCP layer was tested."))
	}

	cdnDomain := metadata["ORANGE_DOMAIN"]
	if !validDomain(cdnDomain) {
		cdnDomain = metadata["CDN_EDGE_DOMAIN"]
	}
	cdnPort, _ := strconv.Atoi(metadata["CDN_EDGE_PORT"])
	if cdnPort == 0 {
		cdnPort = 8443
	}
	if routeMode == "gray" {
		a.println(a.msg("[SKIP] CDN_XHTTP：当前拓扑未配置橙云/XHTTP 路由。", "[SKIP] CDN_XHTTP: the current topology has no orange-cloud/XHTTP route."))
	} else if validDomain(cdnDomain) {
		a.printRouteProbe(cdnHTTPRouteProbe(cdnDomain, cdnPort))
	} else {
		a.println(a.msg("[SKIP] CDN_XHTTP：当前运行态没有橙云域名。", "[SKIP] CDN_XHTTP: no orange-cloud hostname exists in runtime metadata."))
	}

	ssPort, _ := strconv.Atoi(metadata["SS2022_PORT"])
	if ssPort == 0 {
		ssPort = defaultSS2022TCPPort
	}
	a.printRouteProbe(tcpRouteProbe("SS2022", c.Host, ssPort))
}

func (a *App) manageSS2022Allowlist() error {
	a.println(a.msg("先在本机绕过 HTTP 代理环境变量，多源识别当前公网 IPv4；随后才登录 VPS 对照 SSH 实际来源。", "First, detect the current public IPv4 locally through multiple direct lookups that bypass HTTP proxy environment variables; then log in to the VPS and compare the SSH-observed source."))
	local, localErr := localPublicIPv4()
	if localErr != nil {
		a.println(a.msg("[WARN] 本机公网 IP 多源探测失败：", "[WARN] Local public-IP detection failed: ") + localErr.Error())
	} else {
		a.println(fmt.Sprintf("LOCAL_PUBLIC_IPV4=%s (%d/%d sources agree)", local.IP, len(local.Sources), local.Total))
	}

	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	observed, err := a.sshObservedSourceIPv4(c)
	if err != nil {
		return err
	}
	a.println("VPS_SEES_SSH_SOURCE=" + observed)
	if localErr == nil && local.IP != observed {
		a.println(a.msg("[WARN] 两个结果不一致：可能存在 TUN、透明代理、多出口或运营商切换。白名单必须采用 VPS 实际看到的 SSH 来源。", "[WARN] The results differ, indicating a TUN, transparent proxy, multiple egresses, or carrier switching. The allowlist must use the source actually observed by the VPS."))
	}

	status := a.rootCapture(c, "bash "+remoteRoot+"/linux/23-ss2022-tcp.sh status; bash "+remoteRoot+"/linux/23-ss2022-tcp.sh list")
	if !status.OK() {
		return fmt.Errorf("SS2022 status failed (exit %d): %s", status.ExitCode, processFailureDetail(status))
	}
	a.println(status.Stdout)
	if !a.yes(fmt.Sprintf(a.msg("把当前精确公网 IPv4 %s 加入这台 VPS 的 SS2022 TCP 白名单？", "Add exact current public IPv4 %s to this VPS's SS2022 TCP allowlist?"), observed), false) {
		return nil
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/23-ss2022-tcp.sh allow "+shQuote(observed)+"; bash "+remoteRoot+"/linux/23-ss2022-tcp.sh status")
	if !result.OK() {
		return fmt.Errorf("SS2022 allowlist update failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(result.Stdout)
	metadata, _ := a.runtimePublicEnv(c)
	port, _ := strconv.Atoi(metadata["SS2022_PORT"])
	if port == 0 {
		port = defaultSS2022TCPPort
	}
	probe := tcpRouteProbe("SS2022", c.Host, port)
	a.printRouteProbe(probe)
	if !probe.OK {
		return errors.New(a.msg("白名单已写入并回读，但当前本地 TCP 仍未到达 SS2022；请运行菜单 [3] 比较三条线路。", "The allowlist was written and read back, but local TCP still cannot reach SS2022. Run menu [3] to compare all three routes."))
	}
	a.println(a.msg("[GOOD] 当前来源已加入白名单，SS2022 TCP 入口可达。需要链接时使用菜单 [7] 显示交接单。", "[GOOD] The current source is allowlisted and the SS2022 TCP entry is reachable. Use menu [7] to show the handoff link."))
	return nil
}
