package main

import (
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

const cloudflareRulesDashboardURL = "https://dash.cloudflare.com/?to=%2F%3Aaccount%2F%3Azone%2Frules"

func (a *App) showCDNXHTTPPrototypeStatus(c Connection) error {
	command := ". " + remoteRoot + "/linux/lib-deployment-state.sh; " +
		"tna_state_init_direct_if_missing; tna_state_show; " +
		"if [ -r /etc/text-node-assistant/topology.env ]; then sed -n -E '/^(TOPOLOGY_MODE|GRAY_DOMAIN|ORANGE_DOMAIN|GRAY_DNS_VALIDATED|ORANGE_EDGE_VALIDATED)=/p' /etc/text-node-assistant/topology.env; fi; " +
		"if bash " + remoteRoot + "/linux/04f-xhttp-cdn-api.sh show >/dev/null 2>&1; then echo XHTTP_COMPONENT=READY_LOOPBACK; else echo XHTTP_COMPONENT=NOT_READY; fi; " +
		"if grep -qF '# TNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/tna-cdn-xhttp-stage 2>/dev/null; then " +
		"if ss -H -lntp 2>/dev/null | awk '$4 ~ /:8443$/ && $4 != \"127.0.0.1:8443\" && $4 != \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_PUBLIC_CLOUDFLARE_ONLY; " +
		"elif ss -H -lntp 2>/dev/null | awk '$4 == \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_LOOPBACK_ONLY; " +
		"else echo CDN_NGINX_STAGE=CONFIG_PRESENT_LISTENER_MISSING; fi; else echo CDN_NGINX_STAGE=NOT_READY; fi; " +
		"bash " + remoteRoot + "/linux/05f-cloudflare-origin-lock.sh status 2>/dev/null || true; " +
		"if grep -q '^CDN_EDGE_VALIDATED=1$' /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null; then echo CLOUDFLARE_EDGE_VALIDATION=PASS; else echo CLOUDFLARE_EDGE_VALIDATION=NOT_PASSED; fi; " +
		"if grep -q '^CDN_REAL_CLIENT_CONFIRMED=1$' /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null; then echo REAL_CLIENT_BROWSE=CONFIRMED; else echo REAL_CLIENT_BROWSE=NOT_CONFIRMED; fi; " +
		"echo CLOUDFLARE_API_MUTATION=NONE; echo REALITY_PUBLIC_443=UNCHANGED"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf("CDN/XHTTP redacted status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	for _, key := range []string{"TOPOLOGY_MODE", "GRAY_DOMAIN", "ORANGE_DOMAIN", "GRAY_DNS_VALIDATED", "ORANGE_EDGE_VALIDATED", "DEPLOYMENT_MODE", "ACTIVE_MODE", "PORT_443_OWNER", "ORIGIN_HISTORY", "XHTTP_COMPONENT", "CDN_NGINX_STAGE", "CLOUDFLARE_FIREWALL_APPLIED", "MANAGED_RULE_COUNT", "CLOUDFLARE_EDGE_VALIDATION", "REAL_CLIENT_BROWSE", "CLOUDFLARE_API_MUTATION", "REALITY_PUBLIC_443"} {
		value := values[key]
		if value == "" {
			value = "UNKNOWN"
		}
		a.println(key + "=" + value)
	}
	return nil
}

func (a *App) stageCDNXHTTPLocal(c Connection, domain string, copyLink bool) error {
	return a.stageCDNXHTTPLocalForTopology(c, domain, copyLink, topologyDual)
}

func cdnTargetTopologyEnv(mode topologyMode) string {
	if mode == topologyOrange {
		return "TNA_TARGET_TOPOLOGY=orange "
	}
	return "TNA_TARGET_TOPOLOGY=dual "
}

func (a *App) stageCDNXHTTPLocalForTopology(c Connection, domain string, copyLink bool, target topologyMode) error {
	if !validDomain(domain) {
		return errors.New(a.msg("CDN/XHTTP 施工域名格式无效。", "The CDN/XHTTP deployment hostname is invalid."))
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	create := a.rootCapture(c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh create "+shQuote(domain))
	if !create.OK() || (!strings.Contains(create.Stdout, "XHTTP_STATUS=READY") && !strings.Contains(create.Stdout, "TNA_XHTTP_ALREADY_READY") && !strings.Contains(create.Stdout, "TNA_XHTTP_RETARGETED=1")) {
		return fmt.Errorf("loopback XHTTP creation failed (exit %d): %s", create.ExitCode, processFailureDetail(create))
	}
	env := cdnTargetTopologyEnv(target)
	stage := a.rootCapture(c, env+"bash "+remoteRoot+"/linux/05e-cdn-xhttp-nginx.sh stage-local "+shQuote(domain)+" "+shQuote(publicIP))
	if !stage.OK() || !strings.Contains(stage.Stdout, "CDN_STAGE_SCOPE=LOCAL_ONLY") {
		return fmt.Errorf("loopback Nginx stage failed (exit %d): %s", stage.ExitCode, processFailureDetail(stage))
	}
	validate := a.rootCapture(c, env+"bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --local-only")
	if !validate.OK() || !strings.Contains(validate.Stdout, "CDN_LOCAL_VALIDATION=PASS") || !strings.Contains(validate.Stdout, "PUBLIC_ORIGIN_8443=NOT_ENABLED") {
		return fmt.Errorf("local CDN/XHTTP validation failed (exit %d): %s", validate.ExitCode, processFailureDetail(validate))
	}
	a.println(a.msg("XHTTP 与 Nginx 8443 影子已完成本机回环验收；公网端口、DNS、橙云和防火墙均未修改。", "XHTTP and the Nginx 8443 shadow passed loopback validation; public ports, DNS, orange-cloud state, and the firewall were not changed."))
	if !copyLink {
		return a.showCDNXHTTPPrototypeStatus(c)
	}
	return a.copyCDNXHTTPStageLink(c, domain)
}

func (a *App) copyCDNXHTTPStageLink(c Connection, domain string) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh link "+shQuote(domain)+" 8443")
	if !result.OK() {
		return fmt.Errorf("CDN/XHTTP staged link generation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	link := parseKV(result.Stdout)["XHTTP_LINK"]
	profile, err := parseCDNXHTTPLink(link)
	if err != nil || profile.Domain != domain || profile.Port != 8443 {
		return errors.New(a.msg("远端返回的 XHTTP 影子链接没有通过严格解析；未显示或复制。", "The remote XHTTP staged link failed strict parsing and was not shown or copied."))
	}
	// An in-place upgrade can return a legacy TNA fragment from the remote
	// exporter. Parse it for compatibility, then canonicalize only the
	// presentation fragment before placing the URI in the protected panel.
	// canonicalizeCDNXHTTPURL preserves optional query knobs such as
	// x_padding_bytes/extra; rebuilding from the reduced profile would drop
	// those transport settings.
	link, err = canonicalizeCDNXHTTPURL(link)
	if err != nil {
		return errors.New(a.msg("远端 XHTTP 影子链接无法转换为 v1 标识；未显示或复制。", "The remote XHTTP staged link could not be converted to the v1 label; it was not shown or copied."))
	}
	handoff := strings.Join([]string{
		"===== PROXYNODEASSISTANT CDN XHTTP LOCAL STAGE v1.0.0 =====",
		"DEPLOYMENT_MODE=cdn-xhttp-tls",
		"ACTIVE_MODE=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION",
		"CDN_XHTTP_STAGE_LINK=" + link,
		"CDN_XHTTP_STAGE_REACHABILITY=LOOPBACK_VALIDATED_NOT_PUBLIC",
		"CLOUDFLARE_DNS_PROXY=DEFERRED",
		"CLOUDFLARE_ORIGIN_LOCK=DEFERRED",
		"PRODUCTION_443_LINK=NOT_RELEASED",
		"===============================================",
	}, "\n")
	return a.secretHandoff("CDN XHTTP LOCAL STAGE", handoff)
}

func verifyExternalOriginLocked(publicIP string) error {
	address := net.JoinHostPort(publicIP, "8443")
	conn, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		return nil
	}
	_ = conn.Close()
	return fmt.Errorf("direct origin %s is reachable from this device", address)
}

func verifyExternalCloudflareEdge(domain string) error {
	transport := &http.Transport{
		Proxy:               nil,
		ForceAttemptHTTP2:   true,
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 20 * time.Second}).DialContext,
		TLSHandshakeTimeout: 10 * time.Second,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second}
	// Cloudflare's free plan supports the HTTPS edge port 8443 directly.  The
	// Reality listener owns :443 on the VPS, so probing/exporting :443 here
	// would only exercise the gray/Reality cover and could falsely look healthy.
	response, err := client.Get("https://" + domain + ":8443/")
	if err != nil {
		return fmt.Errorf("Cloudflare edge HTTPS probe failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return fmt.Errorf("Cloudflare edge returned HTTP %d", response.StatusCode)
	}
	if strings.TrimSpace(response.Header.Get("Cf-Ray")) == "" {
		return errors.New("Cloudflare edge response is missing Cf-Ray")
	}
	if response.Header.Get("X-TNA-Managed-Origin") != "cdn-xhttp-v095" || response.Header.Get("X-TNA-Origin-Port") != "8443" {
		return errors.New("the response did not prove the managed Cloudflare :8443 edge route")
	}
	return nil
}

func (a *App) rollbackCDNPublicOrigin(c Connection, domain, publicIP string) error {
	return a.rollbackCDNPublicOriginForTopology(c, domain, publicIP, topologyDual)
}

func (a *App) rollbackCDNPublicOriginForTopology(c Connection, domain, publicIP string, target topologyMode) error {
	result := a.rootCapture(c, cdnTargetTopologyEnv(target)+"bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --rollback-public")
	if !result.OK() || !strings.Contains(result.Stdout, "CDN_PUBLIC_ORIGIN_ROLLED_BACK=1") {
		return fmt.Errorf("public-origin rollback failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return nil
}

func (a *App) promoteCDNPublicOrigin(c Connection, domain, email string) error {
	return a.promoteCDNPublicOriginForTopology(c, domain, email, topologyDual)
}

func (a *App) cdnCertificateFailure(result ProcessResult) error {
	detail := processFailureDetail(result)
	diagnostics := result.Stdout + "\n" + result.Stderr
	if strings.Contains(diagnostics, "CLOUDFLARE_HTTP_ORIGIN_RULE_MISROUTED") {
		return fmt.Errorf(a.msg(
			"CDN 源站证书签发失败（退出码 %d）：Cloudflare 把 HTTP-01 请求改送到了 TLS 8443。请将 Origin Rule 限制为 HTTPS 请求，保留 HTTP 80→源站 80；或临时切灰云后重试。HTTPS/8443 正常不代表 HTTP-01 可用。\n底层诊断：%s",
			"CDN origin certificate failed (exit %d): Cloudflare routed the HTTP-01 request to TLS 8443. Restrict the Origin Rule to HTTPS requests and keep HTTP 80→origin 80, or temporarily switch the record to DNS-only and retry. A healthy HTTPS/8443 path does not prove HTTP-01 is reachable.\nUnderlying diagnostic: %s",
		), result.ExitCode, detail)
	}
	if strings.Contains(diagnostics, "TNA_ACME_PUBLIC_HTTP_STATUS=000") {
		return fmt.Errorf(a.msg(
			"CDN 源站证书签发失败（退出码 %d）：公网 HTTP-01 请求超时，未收到有效响应。程序已尝试自动预置“仅 Cloudflare 可访问”的临时源站 8443；请检查 DNS、橙云、Cloudflare 规则和源站连通性后重试。\n底层诊断：%s",
			"CDN origin certificate failed (exit %d): the public HTTP-01 request timed out without a valid response. The app already attempted to stage a temporary Cloudflare-only origin 8443; check DNS, orange-cloud status, Cloudflare rules, and origin reachability, then retry.\nUnderlying diagnostic: %s",
		), result.ExitCode, detail)
	}
	return fmt.Errorf(a.msg("CDN 源站证书签发失败（退出码 %d）：%s", "CDN origin certificate failed (exit %d): %s"), result.ExitCode, detail)
}

func (a *App) promoteCDNPublicOriginForTopology(c Connection, domain, email string, target topologyMode) error {
	if !validDomain(domain) {
		return errors.New(a.msg("施工域名格式无效。", "The deployment hostname is invalid."))
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if !validEmail(email) {
		_, enteredEmail, inputErr := a.askLabeledDomainEmail("请再次输入橙云子域名", "Re-enter the orange-cloud hostname")
		if inputErr != nil {
			return inputErr
		}
		email = enteredEmail
	}
	a.println(a.msg(
		"[INFO] 正在先自动准备 Cloudflare-only 源站 8443（官方 CIDR 防火墙 + 临时 ACME 监听），再开始证书公网预检。",
		"[INFO] Preparing the Cloudflare-only origin 8443 first (official CIDR firewall + temporary ACME listener), then starting the public certificate preflight.",
	))
	certificate := a.rootCapture(c, "bash "+remoteRoot+"/linux/05h-ensure-cdn-certificate.sh "+shQuote(domain)+" "+shQuote(email)+" "+shQuote(publicIP)+" --prepare-public-origin")
	if !certificate.OK() || (!strings.Contains(certificate.Stdout, "TNA_CDN_CERTIFICATE_READY=1") && !strings.Contains(certificate.Stdout, "TNA_CDN_CERTIFICATE_ALREADY_VALID=1")) {
		return a.cdnCertificateFailure(certificate)
	}
	if err := a.stageCDNXHTTPLocalForTopology(c, domain, false, target); err != nil {
		return err
	}
	status := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh status")
	if !status.OK() {
		return fmt.Errorf("Cloudflare origin-lock status failed (exit %d): %s", status.ExitCode, processFailureDetail(status))
	}
	if parseKV(status.Stdout)["CLOUDFLARE_FIREWALL_APPLIED"] != "1" {
		fetch := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh fetch")
		if !fetch.OK() {
			return fmt.Errorf("Cloudflare official CIDR fetch failed (exit %d): %s", fetch.ExitCode, processFailureDetail(fetch))
		}
		plan := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh plan "+fmt.Sprintf("%d", c.Port))
		if !plan.OK() || !strings.Contains(plan.Stdout, "KEEP_PUBLIC_TCP_443_UNCHANGED=1") || !strings.Contains(plan.Stdout, "DENY_OTHER_SOURCES_TCP=8443") {
			return errors.New(a.msg("Cloudflare 防火墙计划未通过安全门禁。", "The Cloudflare firewall plan failed its safety gate."))
		}
		a.println(strings.TrimSpace(plan.Stdout))
		apply := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh apply")
		if !apply.OK() || !strings.Contains(apply.Stdout, "CLOUDFLARE_FIREWALL_APPLIED=1") || !strings.Contains(apply.Stdout, "PUBLIC_TCP_443_POLICY=UNCHANGED") {
			return fmt.Errorf("Cloudflare-only UFW transaction failed (exit %d): %s", apply.ExitCode, processFailureDetail(apply))
		}
	}
	env := cdnTargetTopologyEnv(target)
	stage := a.rootCapture(c, env+"bash "+remoteRoot+"/linux/05e-cdn-xhttp-nginx.sh stage "+shQuote(domain)+" "+shQuote(publicIP))
	if !stage.OK() || !strings.Contains(stage.Stdout, "CDN_STAGE_SCOPE=CLOUDFLARE_ONLY") {
		_ = a.rollbackCDNPublicOriginForTopology(c, domain, publicIP, target)
		return fmt.Errorf("public 8443 origin staging failed and rollback was requested (exit %d): %s", stage.ExitCode, processFailureDetail(stage))
	}
	validate := a.rootCapture(c, env+"bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --origin-ready")
	if !validate.OK() || !strings.Contains(validate.Stdout, "CDN_ORIGIN_VALIDATION=PASS") {
		_ = a.rollbackCDNPublicOriginForTopology(c, domain, publicIP, target)
		return fmt.Errorf("public 8443 origin validation failed and rollback was requested (exit %d): %s", validate.ExitCode, processFailureDetail(validate))
	}
	if err := verifyExternalOriginLocked(publicIP); err != nil {
		_ = a.rollbackCDNPublicOriginForTopology(c, domain, publicIP, target)
		return fmt.Errorf("origin-concealment gate failed and the public origin was rolled back: %w", err)
	}
	a.println(a.msg("[GOOD] VPS 公网 8443 已启用，但只允许 Cloudflare 官方网段；本机直连源站探针已确认无法连入。该阶段不改动公网 443 和 SSH。", "[GOOD] Public origin 8443 is enabled for official Cloudflare networks only; this device confirmed that direct origin access is blocked. This stage did not change public 443 or SSH."))
	a.println(a.msg("现在到 Cloudflare 官方 Dashboard 手动完成：", "Now complete these steps manually in the official Cloudflare Dashboard:"))
	a.println(a.msg("1) 施工 hostname 的 A 记录指向本 VPS，并开启橙云 Proxied。", "1) Point the deployment hostname A record to this VPS and enable orange-cloud Proxied."))
	a.println(a.msg("2) SSL/TLS 模式设为 Full (strict)，并确认 Universal SSL 生效。", "2) Set SSL/TLS mode to Full (strict) and confirm Universal SSL is active."))
	a.println(a.msg("3) 不要创建 443→8443 Origin Rule：免费计划直接使用 hostname:8443，避免把请求送到 Reality 443。", "3) Do not create a 443-to-8443 Origin Rule: the free plan uses hostname:8443 directly, avoiding the Reality 443 listener."))
	a.println(a.msg("4) Cache Rule：该 hostname 全站 Bypass cache；不要挂 Access、Turnstile、质询、重定向或 Worker。", "4) Cache Rule: bypass cache for the entire hostname; do not attach Access, Turnstile, challenges, redirects, or Workers."))
	if err := openURL(cloudflareRulesDashboardURL); err != nil {
		a.println(a.msg("浏览器未能自动打开，请手动访问 dash.cloudflare.com。", "The browser could not be opened; visit dash.cloudflare.com manually."))
	}
	a.println(a.msg("程序不会读取或保存 Cloudflare Token；当前工作流将继续执行分项确认和严格边缘验证。", "The app never reads or stores a Cloudflare token; the current workflow will continue with stepwise confirmation and strict edge validation."))
	return nil
}

func (a *App) validateCDNEdge(c Connection, domain string) error {
	return a.validateCDNEdgeForTopology(c, domain, topologyDual)
}

func (a *App) validateCDNEdgeForTopology(c Connection, domain string, target topologyMode) error {
	if !validDomain(domain) {
		return errors.New(a.msg("施工域名格式无效。", "The deployment hostname is invalid."))
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if err := verifyExternalCloudflareEdge(domain); err != nil {
		return fmt.Errorf("this Windows device could not validate the Cloudflare edge: %w", err)
	}
	if err := verifyExternalOriginLocked(publicIP); err != nil {
		return fmt.Errorf("the edge works, but direct origin 8443 is still reachable: %w", err)
	}
	remote := a.rootCapture(c, cdnTargetTopologyEnv(target)+"bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --edge")
	if !remote.OK() || !strings.Contains(remote.Stdout, "ORIGIN_RULE_443_TO_8443=NOT_REQUIRED_CLOUDFLARE_STANDARD_PORT") || !strings.Contains(remote.Stdout, "REAL_DEVICE_BROWSE=REQUIRED") {
		return fmt.Errorf("remote Cloudflare edge validation failed (exit %d): %s", remote.ExitCode, processFailureDetail(remote))
	}
	a.println(a.msg("[GOOD] Windows 外部探针与 VPS 回读都证明：DNS 已橙云、Cf-Ray 存在、Cloudflare :8443 正确回源到受限源站 :8443，直连源站被阻断。", "[GOOD] Both the Windows probe and VPS readback proved proxied DNS, Cf-Ray, the Cloudflare :8443 edge to the restricted origin :8443, and blocked direct origin access."))
	return a.copyCDNXHTTPProductionLinkForTopology(c, domain, target)
}

func (a *App) copyCDNXHTTPProductionLink(c Connection, domain string) error {
	return a.copyCDNXHTTPProductionLinkForTopology(c, domain, topologyDual)
}

func (a *App) copyCDNXHTTPProductionLinkForTopology(c Connection, domain string, target topologyMode) error {
	gate := a.rootCapture(c, "grep -Fqx 'CDN_EDGE_VALIDATED=1' /etc/text-node-assistant/cloudflare/edge-state.env && grep -Fqx "+shQuote("CDN_EDGE_DOMAIN="+domain)+" /etc/text-node-assistant/cloudflare/edge-state.env")
	if !gate.OK() {
		return errors.New(a.msg("橙云边缘尚未通过严格验证，拒绝释放生产链接。", "The Cloudflare edge has not passed strict validation; the production link remains withheld."))
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh link "+shQuote(domain)+" 8443")
	if !result.OK() {
		return fmt.Errorf("production CDN/XHTTP link generation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	link := parseKV(result.Stdout)["XHTTP_LINK"]
	profile, err := parseCDNXHTTPLink(link)
	if err != nil || profile.Domain != domain || profile.Port != 8443 {
		return errors.New(a.msg("生产 XHTTP 链接未通过严格解析，拒绝显示或复制。", "The production XHTTP link failed strict parsing and was not shown or copied."))
	}
	// Keep legacy links readable on import, but never re-emit their TNA
	// fragment in the v1 protected handoff. Preserve the raw query so newer
	// XHTTP optional parameters survive the migration unchanged.
	link, err = canonicalizeCDNXHTTPURL(link)
	if err != nil {
		return errors.New(a.msg("生产 XHTTP 链接无法转换为 v1 标识，拒绝显示或复制。", "The production XHTTP link could not be converted to the v1 label; it remains withheld."))
	}
	mode := "dual-hot-switch"
	reality := "PRESENT_UNCHANGED_UNTIL_FINAL_RECONCILE"
	if target == topologyOrange {
		mode = "cdn-xhttp-tls"
		reality = "NOT_REQUIRED_OR_REMOVED_AT_FINAL_RECONCILE"
	}
	handoff := strings.Join([]string{
		"===== PROXYNODEASSISTANT CDN XHTTP PRODUCTION TEST v1.0.0 =====",
		"DEPLOYMENT_MODE=" + mode,
		"ACTIVE_MODE=SWITCH_TO_CDN_STAGED_8443",
		"CDN_XHTTP_LINK=" + link,
		"CDN_EDGE_8443=VALIDATED",
		"CDN_ORIGIN_8443=CLOUDFLARE_ONLY",
		"REALITY_ROUTE=" + reality,
		"REAL_DEVICE_BROWSE=REQUIRED_BEFORE_COMMIT",
		"=================================================",
	}, "\n")
	return a.secretHandoff("CDN XHTTP PRODUCTION TEST", handoff)
}

func (a *App) confirmCDNRealClient(c Connection, domain string) error {
	return a.confirmCDNRealClientForTopology(c, domain, topologyDual)
}

func (a *App) confirmCDNRealClientForTopology(c Connection, domain string, target topologyMode) error {
	confirmation := a.prompt(a.msg("把刚才的 8443 XHTTP 链接导入客户端并真实浏览后，输入大写 REAL BROWSE OK", "After importing the 8443 XHTTP link and actually browsing through it, type uppercase REAL BROWSE OK"))
	if confirmation != "REAL BROWSE OK" {
		a.println(a.msg("未提交生产状态；安装事务将回滚，不会把未经真机验收的橙云线路冒充为成功。", "Production state was not committed; the install transaction will roll back instead of claiming an unverified orange route succeeded."))
		return nil
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	result := a.rootCapture(c, cdnTargetTopologyEnv(target)+"bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --confirm-client")
	expectedState := "ACTIVE_MODE=DUAL_INSTALLED_ACTIVE_CDN"
	if target == topologyOrange {
		expectedState = "ACTIVE_MODE=ACTIVE_CDN"
		if strings.Contains(result.Stdout, "REALITY_443_PRESENT=1") {
			expectedState = "ACTIVE_MODE=DUAL_INSTALLED_ACTIVE_CDN"
		}
	}
	if !result.OK() || !strings.Contains(result.Stdout, "CDN_REAL_CLIENT_CONFIRMED=1") || !strings.Contains(result.Stdout, expectedState) {
		return fmt.Errorf("real-client confirmation commit failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	if target == topologyOrange {
		a.println(a.msg("[GOOD] CDN/XHTTP 已通过真机验收；最终收敛将确保仅保留橙云线路。", "[GOOD] CDN/XHTTP passed real-device verification; final convergence will retain only the orange route."))
	} else {
		a.println(a.msg("[GOOD] CDN/XHTTP 已标记为当前活动客户端路径；原 Reality 443 仍保留，可随时热切回。", "[GOOD] CDN/XHTTP is now marked as the active client path; the original Reality 443 remains available for hot fallback."))
	}
	return nil
}

func (a *App) removeCDNXHTTPPrototype(c Connection, domain string) error {
	confirmation := a.prompt(a.msg("输入大写 REMOVE XHTTP STAGE；将删除本工具的 XHTTP/Nginx/CDN 防火墙规则，Reality 443 保持不动", "Type uppercase REMOVE XHTTP STAGE to remove managed XHTTP, Nginx, and CDN firewall rules; Reality 443 remains untouched"))
	if confirmation != "REMOVE XHTTP STAGE" {
		a.println(a.msg("已取消。", "Cancelled."))
		return nil
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if err := a.rollbackCDNPublicOrigin(c, domain, publicIP); err != nil {
		return err
	}
	command := "bash " + remoteRoot + "/linux/05e-cdn-xhttp-nginx.sh disable-stage && " +
		"bash " + remoteRoot + "/linux/04f-xhttp-cdn-api.sh delete && " +
		". " + remoteRoot + "/linux/lib-deployment-state.sh; " +
		"ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null || { echo TNA_CDN_REMOVE_ERROR=REALITY_443_NOT_VERIFIED >&2; exit 139; }; " +
		"current=$(tna_state_env_value ACTIVE_MODE || true); " +
		"if [ \"$current\" = DUAL_INSTALLED_ACTIVE_DIRECT ]; then tna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT ACTIVE_DIRECT direct-reality xray-reality previously-exposed; " +
		"elif [ \"$current\" != ACTIVE_DIRECT ]; then echo TNA_CDN_REMOVE_ERROR=STATE_$current >&2; exit 139; fi; " +
		"echo TNA_CDN_MANAGED_COMPONENTS_REMOVED"
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_CDN_MANAGED_COMPONENTS_REMOVED") {
		return fmt.Errorf("CDN/XHTTP managed-component removal failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("本工具的 XHTTP、Nginx 8443、Cloudflare CIDR 防火墙规则和边缘状态已删除；原 Reality 443 已验证并保持。", "Managed XHTTP, Nginx 8443, Cloudflare-CIDR firewall rules, and edge state were removed; the original Reality 443 was verified and retained."))
	return nil
}

func (a *App) manageCDNXHTTPPrototype() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	a.println()
	a.println(a.msg("线路拓扑状态（只读）：", "Link-topology status (read-only):"))
	a.println(a.msg("灰云、橙云、双路的施工、互切和拆除只允许通过主菜单 [1]。本页不会修改 DNS、Cloudflare、防火墙、Xray 或 Nginx。", "Gray, orange, and dual construction, switching, and removal are allowed only through main action [1]. This page never changes DNS, Cloudflare, the firewall, Xray, or Nginx."))
	if err := a.showCDNXHTTPPrototypeStatus(c); err != nil {
		return err
	}
	a.println("TOPOLOGY_MUTATION=NONE")
	a.println("TOPOLOGY_CHANGE_ENTRY=ACTION_1")
	a.println(a.msg("需要当前设备订阅链接时，请使用 [20] → [9]。", "For this device's current subscription links, use [20] -> [9]."))
	return nil
}
