package main

import (
	"errors"
	"fmt"
	"strings"
)

func (a *App) showCDNXHTTPPrototypeStatus(c Connection) error {
	command := ". " + remoteRoot + "/linux/lib-deployment-state.sh; " +
		"pna_state_init_direct_if_missing; pna_state_show; " +
		"if bash " + remoteRoot + "/linux/04f-xhttp-cdn-api.sh show >/dev/null 2>&1; then echo XHTTP_COMPONENT=READY_LOOPBACK_ONLY; else echo XHTTP_COMPONENT=NOT_READY; fi; " +
		"if grep -qF '# PNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/pna-cdn-xhttp-stage 2>/dev/null && " +
		"ss -H -lntp 2>/dev/null | awk '$4 == \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_LOOPBACK_ONLY; else echo CDN_NGINX_STAGE=NOT_READY; fi; " +
		"echo CLOUDFLARE_MUTATION=NONE; echo PRODUCTION_443_PROMOTION=BLOCKED"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf("CDN/XHTTP redacted status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	for _, key := range []string{"DEPLOYMENT_MODE", "ACTIVE_MODE", "PORT_443_OWNER", "ORIGIN_HISTORY", "XHTTP_COMPONENT", "CDN_NGINX_STAGE", "CLOUDFLARE_MUTATION", "PRODUCTION_443_PROMOTION"} {
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
	if !validate.OK() || !strings.Contains(validate.Stdout, "CDN_LOCAL_VALIDATION=PASS") || !strings.Contains(validate.Stdout, "PRODUCTION_443_PROMOTION=BLOCKED") {
		return fmt.Errorf("local CDN/XHTTP validation failed (exit %d): %s", validate.ExitCode, processFailureDetail(validate))
	}
	a.println(a.msg("XHTTP 与 Nginx 8443 影子已完成本机回环验收；公网 443、DNS、橙云和防火墙均未修改。", "XHTTP and the Nginx 8443 shadow passed loopback validation; public 443, DNS, orange-cloud state, and the firewall were not changed."))
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
		"PRODUCTION_443_PROMOTION=BLOCKED",
		"===============================================",
	}, "\n")
	return a.secretHandoff("CDN XHTTP LOCAL STAGE", handoff)
}

func (a *App) removeCDNXHTTPPrototype(c Connection) error {
	confirmation := a.prompt(a.msg("输入大写 REMOVE XHTTP STAGE，仅删除本工具的 XHTTP 影子和回环 Nginx；Reality 443 保持不动", "Type uppercase REMOVE XHTTP STAGE to remove only the managed XHTTP shadow and loopback Nginx; Reality 443 remains untouched"))
	if confirmation != "REMOVE XHTTP STAGE" {
		a.println(a.msg("已取消。", "Cancelled."))
		return nil
	}
	command := "bash " + remoteRoot + "/linux/05e-cdn-xhttp-nginx.sh disable-stage && " +
		"bash " + remoteRoot + "/linux/04f-xhttp-cdn-api.sh delete && " +
		". " + remoteRoot + "/linux/lib-deployment-state.sh; " +
		"current=$(pna_state_env_value ACTIVE_MODE || true); " +
		"if [ \"$current\" = WAITING_FOR_CLOUDFLARE_MANUAL_ACTION ] || [ \"$current\" = CDN_STAGED_8443 ]; then " +
		"ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null || { echo PNA_CDN_REMOVE_ERROR=REALITY_443_NOT_VERIFIED >&2; exit 139; }; " +
		"pna_state_transition \"$current\" ACTIVE_DIRECT direct-reality xray-reality previously-exposed; fi; " +
		"echo PNA_CDN_LOCAL_PROTOTYPE_REMOVED"
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "PNA_CDN_LOCAL_PROTOTYPE_REMOVED") {
		return fmt.Errorf("CDN/XHTTP prototype removal failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("本地 XHTTP/Nginx 影子已删除；原 Reality 443 已验证并保持。", "The local XHTTP/Nginx shadow was removed; the original Reality 443 was verified and retained."))
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
		a.println(a.msg("普通 CDN / XHTTP 实验控制中心（橙云相关操作全部硬阻断）：", "CDN/XHTTP experimental control center (all orange-cloud mutations are hard-blocked):"))
		a.println(a.msg("[1] 查看脱敏状态", "[1] Show redacted status"))
		a.println(a.msg("[2] 创建/复用 XHTTP，并仅在 127.0.0.2:8443 做本地影子验收", "[2] Create/reuse XHTTP and validate only on the 127.0.0.2:8443 shadow"))
		a.println(a.msg("[3] 严格校验后显示/复制 8443 影子链接（当前不能公网使用）", "[3] Validate and copy the 8443 staged link (not publicly usable yet)"))
		a.println(a.msg("[4] 获取 Cloudflare 官方 CIDR 并生成只读防火墙计划", "[4] Fetch official Cloudflare CIDRs and render a read-only firewall plan"))
		a.println(a.msg("[5] 删除本地 XHTTP/Nginx 影子，恢复 ACTIVE_DIRECT", "[5] Remove the local XHTTP/Nginx shadow and restore ACTIVE_DIRECT"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		switch strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))) {
		case "1", "":
			return a.showCDNXHTTPPrototypeStatus(c)
		case "2":
			domain, inputErr := a.required(a.msg("请亲自输入现有证书覆盖的施工域名", "Type the deployment hostname already covered by the certificate"))
			if inputErr != nil {
				return inputErr
			}
			if !a.yes(a.msg("确认只做回环阶段，不修改 DNS、橙云、防火墙或公网 443？", "Confirm loopback staging only, without changing DNS, orange-cloud state, the firewall, or public 443?"), false) {
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
			fetch := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh fetch")
			if !fetch.OK() {
				return fmt.Errorf("Cloudflare CIDR fetch failed (exit %d): %s", fetch.ExitCode, processFailureDetail(fetch))
			}
			plan := a.rootCapture(c, "bash "+remoteRoot+"/linux/05f-cloudflare-origin-lock.sh plan "+fmt.Sprintf("%d", c.Port))
			if !plan.OK() || !strings.Contains(plan.Stdout, "PLAN_ONLY=1") || !strings.Contains(plan.Stdout, "CLOUDFLARE_FIREWALL_APPLIED=0") {
				return errors.New(a.msg("Cloudflare 防火墙计划没有通过只读门禁。", "The Cloudflare firewall plan failed the read-only gate."))
			}
			a.println(strings.TrimSpace(plan.Stdout))
			return nil
		case "5":
			return a.removeCDNXHTTPPrototype(c)
		case "0":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
		}
	}
}
