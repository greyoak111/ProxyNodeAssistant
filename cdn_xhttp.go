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
		"pna_state_init_direct_if_missing; pna_state_show; " +
		"if bash " + remoteRoot + "/linux/04f-xhttp-cdn-api.sh show >/dev/null 2>&1; then echo XHTTP_COMPONENT=READY_LOOPBACK; else echo XHTTP_COMPONENT=NOT_READY; fi; " +
		"if grep -qF '# PNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/pna-cdn-xhttp-stage 2>/dev/null; then " +
		"if ss -H -lntp 2>/dev/null | awk '$4 ~ /:8443$/ && $4 != \"127.0.0.1:8443\" && $4 != \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_PUBLIC_CLOUDFLARE_ONLY; " +
		"elif ss -H -lntp 2>/dev/null | awk '$4 == \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_LOOPBACK_ONLY; " +
		"else echo CDN_NGINX_STAGE=CONFIG_PRESENT_LISTENER_MISSING; fi; else echo CDN_NGINX_STAGE=NOT_READY; fi; " +
		"bash " + remoteRoot + "/linux/05f-cloudflare-origin-lock.sh status 2>/dev/null || true; " +
		"if grep -q '^CDN_EDGE_VALIDATED=1$' /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null; then echo CLOUDFLARE_EDGE_VALIDATION=PASS; else echo CLOUDFLARE_EDGE_VALIDATION=NOT_PASSED; fi; " +
		"if grep -q '^CDN_REAL_CLIENT_CONFIRMED=1$' /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null; then echo REAL_CLIENT_BROWSE=CONFIRMED; else echo REAL_CLIENT_BROWSE=NOT_CONFIRMED; fi; " +
		"echo CLOUDFLARE_API_MUTATION=NONE; echo REALITY_PUBLIC_443=UNCHANGED"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf("CDN/XHTTP redacted status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	for _, key := range []string{"DEPLOYMENT_MODE", "ACTIVE_MODE", "PORT_443_OWNER", "ORIGIN_HISTORY", "XHTTP_COMPONENT", "CDN_NGINX_STAGE", "CLOUDFLARE_FIREWALL_APPLIED", "MANAGED_RULE_COUNT", "CLOUDFLARE_EDGE_VALIDATION", "REAL_CLIENT_BROWSE", "CLOUDFLARE_API_MUTATION", "REALITY_PUBLIC_443"} {
		value := values[key]
		if value == "" {
			value = "UNKNOWN"
		}
		a.println(key + "=" + value)
	}
	return nil
}

func (a *App) stageCDNXHTTPLocal(c Connection, domain string, copyLink bool) error {
	if !validDomain(domain) {
		return errors.New(a.msg("CDN/XHTTP 施工域名格式无效。", "The CDN/XHTTP deployment hostname is invalid."))
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	create := a.rootCapture(c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh create "+shQuote(domain))
	if !create.OK() || (!strings.Contains(create.Stdout, "XHTTP_STATUS=READY") && !strings.Contains(create.Stdout, "PNA_XHTTP_ALREADY_READY")) {
		return fmt.Errorf("loopback XHTTP creation failed (exit %d): %s", create.ExitCode, processFailureDetail(create))
	}
	stage := a.rootCapture(c, "bash "+remoteRoot+"/linux/05e-cdn-xhttp-nginx.sh stage-local "+shQuote(domain)+" "+shQuote(publicIP))
	if !stage.OK() || !strings.Contains(stage.Stdout, "CDN_STAGE_SCOPE=LOCAL_ONLY") {
		return fmt.Errorf("loopback Nginx stage failed (exit %d): %s", stage.ExitCode, processFailureDetail(stage))
	}
	validate := a.rootCapture(c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --local-only")
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
	handoff := strings.Join([]string{
		"===== PNA CDN XHTTP LOCAL STAGE v0.9.5 =====",
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
	response, err := client.Get("https://" + domain + "/")
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
	if response.Header.Get("X-PNA-Managed-Origin") != "cdn-xhttp-v095" || response.Header.Get("X-PNA-Origin-Port") != "8443" {
		return errors.New("the response did not prove the managed 443-to-8443 Origin Rule")
	}
	return nil
}

func (a *App) rollbackCDNPublicOrigin(c Connection, domain, publicIP string) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --rollback-public")
	if !result.OK() || !strings.Contains(result.Stdout, "CDN_PUBLIC_ORIGIN_ROLLED_BACK=1") {
		return fmt.Errorf("public-origin rollback failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return nil
}

func (a *App) promoteCDNPublicOrigin(c Connection, domain string) error {
	if !validDomain(domain) {
		return errors.New(a.msg("施工域名格式无效。", "The deployment hostname is invalid."))
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if err := a.stageCDNXHTTPLocal(c, domain, false); err != nil {
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
		if !plan.OK() || !strings.Contains(plan.Stdout, "KEEP_REALITY_PUBLIC_TCP=443") || !strings.Contains(plan.Stdout, "DENY_OTHER_SOURCES_TCP=8443") {
			return errors.New(a.msg("Cloudflare 防火墙计划未通过安全门禁。", "The Cloudflare firewall plan failed its safety gate."))
		}
		a.println(strings.TrimSpace(plan.Stdout))
		apply := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh apply")
		if !apply.OK() || !strings.Contains(apply.Stdout, "CLOUDFLARE_FIREWALL_APPLIED=1") || !strings.Contains(apply.Stdout, "REALITY_443_POLICY=UNCHANGED") {
			return fmt.Errorf("Cloudflare-only UFW transaction failed (exit %d): %s", apply.ExitCode, processFailureDetail(apply))
		}
	}
	stage := a.rootCapture(c, "bash "+remoteRoot+"/linux/05e-cdn-xhttp-nginx.sh stage "+shQuote(domain)+" "+shQuote(publicIP))
	if !stage.OK() || !strings.Contains(stage.Stdout, "CDN_STAGE_SCOPE=CLOUDFLARE_ONLY") {
		_ = a.rollbackCDNPublicOrigin(c, domain, publicIP)
		return fmt.Errorf("public 8443 origin staging failed and rollback was requested (exit %d): %s", stage.ExitCode, processFailureDetail(stage))
	}
	validate := a.rootCapture(c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --origin-ready")
	if !validate.OK() || !strings.Contains(validate.Stdout, "CDN_ORIGIN_VALIDATION=PASS") {
		_ = a.rollbackCDNPublicOrigin(c, domain, publicIP)
		return fmt.Errorf("public 8443 origin validation failed and rollback was requested (exit %d): %s", validate.ExitCode, processFailureDetail(validate))
	}
	if err := verifyExternalOriginLocked(publicIP); err != nil {
		_ = a.rollbackCDNPublicOrigin(c, domain, publicIP)
		return fmt.Errorf("origin-concealment gate failed and the public origin was rolled back: %w", err)
	}
	a.println(a.msg("[GOOD] VPS 公网 8443 已启用，但只允许 Cloudflare 官方网段；本机直连源站探针已确认无法连入。Reality 443 与 SSH 未修改。", "[GOOD] Public origin 8443 is enabled for official Cloudflare networks only; this device confirmed that direct origin access is blocked. Reality 443 and SSH were not changed."))
	a.println(a.msg("现在到 Cloudflare 官方 Dashboard 手动完成：", "Now complete these steps manually in the official Cloudflare Dashboard:"))
	a.println(a.msg("1) 施工 hostname 的 A 记录指向本 VPS，并开启橙云 Proxied。", "1) Point the deployment hostname A record to this VPS and enable orange-cloud Proxied."))
	a.println(a.msg("2) SSL/TLS 模式设为 Full (strict)，并确认 Universal SSL 生效。", "2) Set SSL/TLS mode to Full (strict) and confirm Universal SSL is active."))
	a.println(a.msg("3) Origin Rule：Hostname 等于施工域名，Destination Port 重写为 8443。", "3) Origin Rule: hostname equals the deployment hostname; override Destination Port to 8443."))
	a.println(a.msg("4) Cache Rule：该 hostname 全站 Bypass cache；不要挂 Access、Turnstile、质询、重定向或 Worker。", "4) Cache Rule: bypass cache for the entire hostname; do not attach Access, Turnstile, challenges, redirects, or Workers."))
	if err := openURL(cloudflareRulesDashboardURL); err != nil {
		a.println(a.msg("浏览器未能自动打开，请手动访问 dash.cloudflare.com。", "The browser could not be opened; visit dash.cloudflare.com manually."))
	}
	a.println(a.msg("完成后回到 [22] 选择“验证橙云边缘”。程序不会读取或保存 Cloudflare Token。", "When finished, return to [22] and choose Validate Cloudflare edge. The app never reads or stores a Cloudflare token."))
	return nil
}

func (a *App) validateCDNEdge(c Connection, domain string) error {
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
	remote := a.rootCapture(c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --edge")
	if !remote.OK() || !strings.Contains(remote.Stdout, "ORIGIN_RULE_443_TO_8443=PASS") || !strings.Contains(remote.Stdout, "REAL_DEVICE_BROWSE=REQUIRED") {
		return fmt.Errorf("remote Cloudflare edge validation failed (exit %d): %s", remote.ExitCode, processFailureDetail(remote))
	}
	a.println(a.msg("[GOOD] Windows 外部探针与 VPS 回读都证明：DNS 已橙云、Cf-Ray 存在、边缘 443 正确回源到受限 8443，直连源站 8443 被阻断。", "[GOOD] Both the Windows probe and VPS readback proved proxied DNS, Cf-Ray, the edge 443-to-restricted-8443 route, and blocked direct origin access."))
	return a.copyCDNXHTTPProductionLink(c, domain)
}

func (a *App) copyCDNXHTTPProductionLink(c Connection, domain string) error {
	gate := a.rootCapture(c, "grep -Fqx 'CDN_EDGE_VALIDATED=1' /etc/proxy-runbook/cloudflare/edge-state.env && grep -Fqx "+shQuote("CDN_EDGE_DOMAIN="+domain)+" /etc/proxy-runbook/cloudflare/edge-state.env")
	if !gate.OK() {
		return errors.New(a.msg("橙云边缘尚未通过严格验证，拒绝释放生产链接。", "The Cloudflare edge has not passed strict validation; the production link remains withheld."))
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/04f-xhttp-cdn-api.sh link "+shQuote(domain)+" 443")
	if !result.OK() {
		return fmt.Errorf("production CDN/XHTTP link generation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	link := parseKV(result.Stdout)["XHTTP_LINK"]
	profile, err := parseCDNXHTTPLink(link)
	if err != nil || profile.Domain != domain || profile.Port != 443 {
		return errors.New(a.msg("生产 XHTTP 链接未通过严格解析，拒绝显示或复制。", "The production XHTTP link failed strict parsing and was not shown or copied."))
	}
	handoff := strings.Join([]string{
		"===== PNA CDN XHTTP PRODUCTION TEST v0.9.5 =====",
		"DEPLOYMENT_MODE=dual-hot-switch",
		"ACTIVE_MODE=SWITCH_TO_CDN_STAGED_8443",
		"CDN_XHTTP_LINK=" + link,
		"CDN_EDGE_443=VALIDATED",
		"CDN_ORIGIN_8443=CLOUDFLARE_ONLY",
		"REALITY_ORIGIN_443=UNCHANGED",
		"REAL_DEVICE_BROWSE=REQUIRED_BEFORE_COMMIT",
		"=================================================",
	}, "\n")
	return a.secretHandoff("CDN XHTTP PRODUCTION TEST", handoff)
}

func (a *App) confirmCDNRealClient(c Connection, domain string) error {
	confirmation := a.prompt(a.msg("把刚才的 443 XHTTP 链接导入客户端并真实浏览后，输入大写 REAL BROWSE OK", "After importing the 443 XHTTP link and actually browsing through it, type uppercase REAL BROWSE OK"))
	if confirmation != "REAL BROWSE OK" {
		a.println(a.msg("未提交生产状态；Reality 直连仍是活动兜底。", "Production state was not committed; Reality direct remains the active fallback."))
		return nil
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/05g-cdn-xhttp-validate.sh "+shQuote(domain)+" "+shQuote(publicIP)+" --confirm-client")
	if !result.OK() || !strings.Contains(result.Stdout, "CDN_REAL_CLIENT_CONFIRMED=1") || !strings.Contains(result.Stdout, "ACTIVE_MODE=DUAL_INSTALLED_ACTIVE_CDN") {
		return fmt.Errorf("real-client confirmation commit failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("[GOOD] CDN/XHTTP 已标记为当前活动客户端路径；原 Reality 443 仍保留，可随时热切回。", "[GOOD] CDN/XHTTP is now marked as the active client path; the original Reality 443 remains available for hot fallback."))
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
		"ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null || { echo PNA_CDN_REMOVE_ERROR=REALITY_443_NOT_VERIFIED >&2; exit 139; }; " +
		"current=$(pna_state_env_value ACTIVE_MODE || true); " +
		"if [ \"$current\" = DUAL_INSTALLED_ACTIVE_DIRECT ]; then pna_state_transition DUAL_INSTALLED_ACTIVE_DIRECT ACTIVE_DIRECT direct-reality xray-reality previously-exposed; " +
		"elif [ \"$current\" != ACTIVE_DIRECT ]; then echo PNA_CDN_REMOVE_ERROR=STATE_$current >&2; exit 139; fi; " +
		"echo PNA_CDN_MANAGED_COMPONENTS_REMOVED"
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "PNA_CDN_MANAGED_COMPONENTS_REMOVED") {
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
	for {
		a.println()
		a.println(a.msg("普通 CDN / XHTTP 双模式控制中心（应用版本永久 v0.9.5）：", "CDN/XHTTP dual-mode control center (application version permanently v0.9.5):"))
		a.println(a.msg("[1] 查看脱敏状态", "[1] Show redacted status"))
		a.println(a.msg("[2] 创建/复用 XHTTP，并仅在 127.0.0.2:8443 做回环验收", "[2] Create/reuse XHTTP and validate only on the 127.0.0.2:8443 shadow"))
		a.println(a.msg("[3] 显示/复制 8443 回环影子链接（不能公网使用）", "[3] Copy the 8443 loopback staged link (not publicly usable)"))
		a.println(a.msg("[4] 获取 Cloudflare 官方 CIDR并显示 8443 锁源计划（只读）", "[4] Fetch official Cloudflare CIDRs and show the read-only 8443 origin-lock plan"))
		a.println(a.msg("[5] 晋升公网 8443 为 Cloudflare-only，并打开人工橙云施工指引", "[5] Promote public 8443 to Cloudflare-only and open the manual orange-cloud guide"))
		a.println(a.msg("[6] 验证橙云、Origin Rule、外部锁源，并复制生产 443 XHTTP 链接", "[6] Validate orange-cloud, Origin Rule, and external origin lock; then copy the production 443 XHTTP link"))
		a.println(a.msg("[7] 真机浏览成功后提交 CDN 为活动路径（Reality 仍保留）", "[7] Commit CDN as active after real browsing succeeds (Reality remains installed)"))
		a.println(a.msg("[8] 撤回公网 8443 与 UFW 锁源，保留回环 XHTTP 影子", "[8] Roll back public 8443 and its UFW lock while retaining the loopback XHTTP shadow"))
		a.println(a.msg("[9] 删除所有本工具 CDN/XHTTP 组件并恢复 ACTIVE_DIRECT", "[9] Remove all managed CDN/XHTTP components and restore ACTIVE_DIRECT"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		switch strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))) {
		case "1", "":
			return a.showCDNXHTTPPrototypeStatus(c)
		case "2":
			domain, inputErr := a.required(a.msg("请亲自输入现有证书覆盖的施工域名", "Type the deployment hostname already covered by the certificate"))
			if inputErr != nil {
				return inputErr
			}
			if !a.yes(a.msg("确认只做回环阶段，不修改 DNS、橙云、防火墙或公网 443/8443？", "Confirm loopback staging only, without changing DNS, orange-cloud state, the firewall, or public 443/8443?"), false) {
				return nil
			}
			return a.stageCDNXHTTPLocal(c, strings.ToLower(strings.TrimSpace(domain)), false)
		case "3":
			domain, inputErr := a.required(a.msg("输入创建影子时使用的施工域名", "Enter the deployment hostname used to create the shadow"))
			if inputErr != nil {
				return inputErr
			}
			return a.copyCDNXHTTPStageLink(c, strings.ToLower(strings.TrimSpace(domain)))
		case "4":
			status := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh status")
			if status.OK() && parseKV(status.Stdout)["CLOUDFLARE_FIREWALL_APPLIED"] == "1" {
				a.println(a.msg("Cloudflare-only 8443 防火墙规则已应用；要刷新 CIDR，先执行 [8] 撤回。", "Cloudflare-only 8443 firewall rules are applied; use [8] to roll them back before refreshing CIDRs."))
				return nil
			}
			fetch := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh fetch")
			if !fetch.OK() {
				return fmt.Errorf("Cloudflare CIDR fetch failed (exit %d): %s", fetch.ExitCode, processFailureDetail(fetch))
			}
			plan := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh plan "+fmt.Sprintf("%d", c.Port))
			if !plan.OK() || !strings.Contains(plan.Stdout, "PLAN_ONLY=1") || !strings.Contains(plan.Stdout, "KEEP_REALITY_PUBLIC_TCP=443") {
				return errors.New(a.msg("Cloudflare 防火墙计划没有通过只读门禁。", "The Cloudflare firewall plan failed the read-only gate."))
			}
			a.println(strings.TrimSpace(plan.Stdout))
			return nil
		case "5":
			domain, inputErr := a.required(a.msg("输入现有证书覆盖的施工域名", "Enter the deployment hostname covered by the current certificate"))
			if inputErr != nil {
				return inputErr
			}
			if !a.yes(a.msg("将自动写入仅限 Cloudflare 官方 CIDR 的 8443 UFW 规则并公开 Nginx 8443；SSH 和 Reality 443 不动。继续？", "This will apply Cloudflare-only UFW rules for 8443 and expose Nginx 8443; SSH and Reality 443 remain unchanged. Continue?"), false) {
				return nil
			}
			return a.promoteCDNPublicOrigin(c, strings.ToLower(strings.TrimSpace(domain)))
		case "6":
			domain, inputErr := a.required(a.msg("输入已经开启橙云并配置 Origin Rule 的施工域名", "Enter the orange-cloud deployment hostname with its Origin Rule configured"))
			if inputErr != nil {
				return inputErr
			}
			if !a.yes(a.msg("我已确认：橙云、Full (strict)、443→8443 Origin Rule、全 hostname 缓存绕过均已设置，且没有 Access/质询/重定向/Worker。开始双端验证？", "I confirm orange-cloud, Full (strict), the 443-to-8443 Origin Rule, hostname-wide cache bypass, and no Access/challenge/redirect/Worker. Start two-sided validation?"), false) {
				return nil
			}
			return a.validateCDNEdge(c, strings.ToLower(strings.TrimSpace(domain)))
		case "7":
			domain, inputErr := a.required(a.msg("输入刚才验证并测试的施工域名", "Enter the deployment hostname just validated and tested"))
			if inputErr != nil {
				return inputErr
			}
			return a.confirmCDNRealClient(c, strings.ToLower(strings.TrimSpace(domain)))
		case "8":
			domain, inputErr := a.required(a.msg("输入要撤回公网 8443 的施工域名", "Enter the deployment hostname whose public 8443 origin will be rolled back"))
			if inputErr != nil {
				return inputErr
			}
			if a.prompt(a.msg("输入大写 ROLLBACK CDN ORIGIN", "Type uppercase ROLLBACK CDN ORIGIN")) != "ROLLBACK CDN ORIGIN" {
				return nil
			}
			publicIP, ipErr := a.remotePublicIP(c)
			if ipErr != nil {
				return ipErr
			}
			if err := a.rollbackCDNPublicOrigin(c, strings.ToLower(strings.TrimSpace(domain)), publicIP); err != nil {
				return err
			}
			a.println(a.msg("公网 8443 和本工具 UFW 规则已撤回；回环 XHTTP 影子与 Reality 443 保留。", "Public 8443 and managed UFW rules were rolled back; the loopback XHTTP shadow and Reality 443 were retained."))
			return nil
		case "9":
			domain, inputErr := a.required(a.msg("输入当前 CDN/XHTTP 施工域名", "Enter the current CDN/XHTTP deployment hostname"))
			if inputErr != nil {
				return inputErr
			}
			return a.removeCDNXHTTPPrototype(c, strings.ToLower(strings.TrimSpace(domain)))
		case "0":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
		}
	}
}
