package main

import (
	"errors"
	"fmt"
	"strings"
)

type topologyMode int

const (
	topologyKeep topologyMode = iota
	topologyGray
	topologyOrange
	topologyDual
)

type topologyPlan struct {
	Mode         topologyMode
	GrayDomain   string
	GrayEmail    string
	OrangeDomain string
	OrangeEmail  string
}

func (p topologyPlan) baseDomainEmail() (string, string) {
	if p.Mode == topologyOrange {
		return p.OrangeDomain, p.OrangeEmail
	}
	return p.GrayDomain, p.GrayEmail
}

func (p topologyPlan) lifecycle() string {
	switch p.Mode {
	case topologyOrange:
		return "MANAGED_ORANGE_WITH_DRIVE"
	case topologyDual:
		return "MANAGED_DUAL_WITH_DRIVE"
	default:
		return "MANAGED_GRAY_WITH_DRIVE"
	}
}

func (a *App) askLabeledDomainEmail(domainLabelZH, domainLabelEN string) (string, string, error) {
	var domain, email string
	for {
		value, err := a.required(a.msg(domainLabelZH+"（没有默认值）", domainLabelEN+" (no default)"))
		if err != nil {
			return "", "", err
		}
		domain = strings.ToLower(strings.TrimSpace(value))
		if validDomain(domain) {
			break
		}
		a.println(a.msg("域名格式无效，请重输。", "That does not look like a valid domain; try again."))
	}
	for {
		value, err := a.required(a.msg("请输入该线路证书通知邮箱（没有默认值）", "Enter the certificate-notification email for this route (no default)"))
		if err != nil {
			return "", "", err
		}
		email = strings.TrimSpace(value)
		if validEmail(email) {
			break
		}
		a.println(a.msg("邮箱格式无效，请重输。", "That does not look like a valid email address; try again."))
	}
	return domain, email, nil
}

func (a *App) topologyAlreadyInstalled(c Connection) bool {
	result := a.rootCapture(c, "test -x /usr/local/x-ui/x-ui && test -s /etc/text-node-assistant/deployment-state.env")
	return result.OK()
}

func (a *App) loadExistingTopologyPlan(c Connection) (topologyPlan, error) {
	result := a.rootCapture(c, "if [ -r /root/.config/text-node-assistant/topology.env ]; then cat /root/.config/text-node-assistant/topology.env; elif [ -r /etc/text-node-assistant/public.env ]; then sed -n 's/^COVER_DOMAIN=/GRAY_DOMAIN=/p' /etc/text-node-assistant/public.env; echo TOPOLOGY_MODE=gray; fi")
	if !result.OK() {
		return topologyPlan{}, fmt.Errorf("existing topology read failed: %s", processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	var plan topologyPlan
	switch values["TOPOLOGY_MODE"] {
	case "gray":
		plan.Mode = topologyGray
	case "orange":
		plan.Mode = topologyOrange
	case "dual":
		plan.Mode = topologyDual
	default:
		return topologyPlan{}, errors.New(a.msg("既有节点没有可验证的拓扑记录；请明确选择 1—3 完成迁移。", "The existing node has no verifiable topology record; choose 1-3 explicitly to migrate it."))
	}
	plan.GrayDomain, plan.GrayEmail = values["GRAY_DOMAIN"], values["GRAY_EMAIL"]
	plan.OrangeDomain, plan.OrangeEmail = values["ORANGE_DOMAIN"], values["ORANGE_EMAIL"]
	if plan.Mode != topologyOrange && !validDomain(plan.GrayDomain) {
		return topologyPlan{}, errors.New(a.msg("既有灰云域名记录无效；请明确选择 1—3 重建拓扑。", "The stored gray hostname is invalid; choose 1-3 explicitly to rebuild topology."))
	}
	if plan.Mode != topologyGray && !validDomain(plan.OrangeDomain) {
		return topologyPlan{}, errors.New(a.msg("既有橙云域名记录无效；请明确选择 1—3 重建拓扑。", "The stored orange hostname is invalid; choose 1-3 explicitly to rebuild topology."))
	}
	if plan.Mode != topologyOrange && !validEmail(plan.GrayEmail) {
		domain, email, err := a.askLabeledDomainEmail("重新确认当前灰云子域名", "Reconfirm the current gray hostname")
		if err != nil {
			return topologyPlan{}, err
		}
		plan.GrayDomain, plan.GrayEmail = domain, email
	}
	if plan.Mode != topologyGray && !validEmail(plan.OrangeEmail) {
		domain, email, err := a.askLabeledDomainEmail("重新确认当前橙云子域名", "Reconfirm the current orange hostname")
		if err != nil {
			return topologyPlan{}, err
		}
		plan.OrangeDomain, plan.OrangeEmail = domain, email
	}
	return plan, nil
}

func (a *App) persistTopologyPlan(c Connection, plan topologyPlan) error {
	body, err := topologyPlanBody(plan)
	if err != nil {
		return err
	}
	command := "set -eu; install -d -m 700 /root/.config/text-node-assistant; tmp=$(mktemp /root/.config/text-node-assistant/.topology.XXXXXX); cat > \"$tmp\"; chmod 600 \"$tmp\"; mv -f \"$tmp\" /root/.config/text-node-assistant/topology.env"
	result := a.rootCaptureWithInput(c, command, []byte(body))
	if !result.OK() {
		return fmt.Errorf("topology persistence failed: %s", processFailureDetail(result))
	}
	return nil
}

func topologyPlanBody(plan topologyPlan) (string, error) {
	mode := map[topologyMode]string{topologyGray: "gray", topologyOrange: "orange", topologyDual: "dual"}[plan.Mode]
	if mode == "" {
		return "", errors.New("cannot persist an unresolved topology")
	}
	if plan.Mode != topologyOrange && (!validDomain(plan.GrayDomain) || !validEmail(plan.GrayEmail)) {
		return "", errors.New("gray topology identity is incomplete")
	}
	if plan.Mode != topologyGray && (!validDomain(plan.OrangeDomain) || !validEmail(plan.OrangeEmail)) {
		return "", errors.New("orange topology identity is incomplete")
	}
	if plan.Mode == topologyDual && plan.GrayDomain == plan.OrangeDomain {
		return "", errors.New("dual topology hostnames must be different")
	}
	return strings.Join([]string{
		"TOPOLOGY_STATE_VERSION=1",
		"TOPOLOGY_MODE=" + mode,
		"GRAY_DOMAIN=" + plan.GrayDomain,
		"GRAY_EMAIL=" + plan.GrayEmail,
		"ORANGE_DOMAIN=" + plan.OrangeDomain,
		"ORANGE_EMAIL=" + plan.OrangeEmail,
	}, "\n") + "\n", nil
}

func (a *App) reconcileTopologyPlan(c Connection, plan topologyPlan) error {
	body, err := topologyPlanBody(plan)
	if err != nil {
		return err
	}
	mode := map[topologyMode]string{topologyGray: "gray", topologyOrange: "orange", topologyDual: "dual"}[plan.Mode]
	command := "set -e; bash " + remoteRoot + "/linux/28-topology-reconcile.sh " + shQuote(mode) + " --commit-state; " +
		". " + remoteRoot + "/linux/lib-deployment-state.sh; tna_state_show"
	result := a.rootCaptureWithInput(c, command, []byte(body))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_TOPOLOGY_RECONCILED=1") {
		return fmt.Errorf(a.msg("拓扑最终收敛失败（退出码 %d）：%s", "Final topology convergence failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	expected := map[topologyMode][3]string{
		topologyGray:   {string(DeploymentDirectReality), string(StateActiveDirect), "xray-reality"},
		topologyOrange: {string(DeploymentCDNXHTTPTLS), string(StateActiveCDN), "none"},
		topologyDual:   {string(DeploymentDualHotSwitch), string(StateDualInstalledActiveCDN), "xray-reality"},
	}[plan.Mode]
	if values["TOPOLOGY_MODE"] != mode || values["DEPLOYMENT_MODE"] != expected[0] || values["ACTIVE_MODE"] != expected[1] || values["PORT_443_OWNER"] != expected[2] {
		return fmt.Errorf(a.msg("拓扑最终回读不一致，拒绝继续：mode=%s deployment=%s active=%s owner=%s", "Final topology readback mismatch; refusing to continue: mode=%s deployment=%s active=%s owner=%s"), values["TOPOLOGY_MODE"], values["DEPLOYMENT_MODE"], values["ACTIVE_MODE"], values["PORT_443_OWNER"])
	}
	a.println(a.msg("[GOOD] 远端监听、线路组件与持久化状态已收敛到目标拓扑：", "[GOOD] Remote listeners, route components, and persistent state converged to the requested topology: ") + mode)
	return nil
}

func (a *App) chooseTopologyPlan(c Connection) (topologyPlan, error) {
	installed := a.topologyAlreadyInstalled(c)
	a.println()
	a.println(a.msg("选择代理线路拓扑（必须明确选择，不能直接回车）：", "Choose a proxy topology explicitly (blank input is not accepted):"))
	a.println(a.msg("[1] 仅灰云：路径最短、延迟通常最低；源站 IP 对客户端可见，适合稳定直连。", "[1] Gray only: shortest path and usually lowest latency; clients can see the origin IP."))
	a.println(a.msg("[2] 仅橙云：客户端只用 Cloudflare/XHTTP；多一层边缘，需完成 SSL/TLS、8443 边缘端口和缓存绕过。免费计划不需要 Origin Rule。", "[2] Orange only: clients use Cloudflare/XHTTP; adds an edge hop and requires SSL/TLS, the supported :8443 edge port, and cache bypass. The free plan does not need an Origin Rule."))
	a.println(a.msg("[3] 双路：灰云直连 + 橙云 CDN 同时保留，故障切换最稳，但需要两个不同子域名。", "[3] Dual route: keep gray direct and orange CDN together; best fallback, but requires two different hostnames."))
	if installed {
		a.println(a.msg("[0] 保持当前已安装拓扑不变（只在检测到既有施工时提供）", "[0] Keep the installed topology unchanged (available only for an existing deployment)"))
	}
	for {
		choice := strings.TrimSpace(a.prompt(a.msg("请选择 1、2、3", "Choose 1, 2, or 3")))
		if a.inputClosed {
			return topologyPlan{}, errInputClosed
		}
		if choice == "0" && installed {
			return a.loadExistingTopologyPlan(c)
		}
		var plan topologyPlan
		switch choice {
		case "1":
			plan.Mode = topologyGray
			var err error
			plan.GrayDomain, plan.GrayEmail, err = a.askLabeledDomainEmail("Step 1：请输入灰云/DNS-only 子域名", "Step 1: enter the gray/DNS-only hostname")
			return plan, err
		case "2":
			plan.Mode = topologyOrange
			var err error
			plan.OrangeDomain, plan.OrangeEmail, err = a.askLabeledDomainEmail("Step 1：请输入橙云/Proxied 子域名", "Step 1: enter the orange-cloud/Proxied hostname")
			return plan, err
		case "3":
			plan.Mode = topologyDual
			var err error
			plan.GrayDomain, plan.GrayEmail, err = a.askLabeledDomainEmail("Step 1：请输入灰云/DNS-only 子域名", "Step 1: enter the gray/DNS-only hostname")
			if err != nil {
				return topologyPlan{}, err
			}
			plan.OrangeDomain, plan.OrangeEmail, err = a.askLabeledDomainEmail("Step 2：请输入橙云/Proxied 子域名", "Step 2: enter the orange-cloud/Proxied hostname")
			if err != nil {
				return topologyPlan{}, err
			}
			if plan.GrayDomain == plan.OrangeDomain {
				a.println(a.msg("双路必须使用两个不同子域名；同一 DNS 记录无法同时保持灰云和橙云。", "Dual mode requires two different hostnames; one DNS record cannot be gray and orange at the same time."))
				continue
			}
			return plan, nil
		default:
			a.println(a.msg("必须明确选择有效拓扑；本次不会猜默认值。", "Choose a valid topology explicitly; no default is guessed."))
		}
	}
}

func publicDNSHasIPv4(domain string) (bool, string) {
	result := probeOrangeDNS(domain, defaultDNSProbeDependencies())
	return result.Accepted(), result.Summary()
}

func (a *App) waitForOrangeDNS(domain, publicIP string) bool {
	a.println(a.msg("请在 Cloudflare 创建 A 记录并打开橙云：", "Create an orange-cloud A record in Cloudflare:"))
	a.println("  Type: A")
	a.println("  Name: " + domain)
	a.println("  Content: " + publicIP)
	a.println("  Proxy: Proxied (orange cloud)")
	for {
		ok, summary := publicDNSHasIPv4(domain)
		a.println("ORANGE_DNS_QUORUM " + summary)
		if ok {
			return true
		}
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("改好后按 Enter 重检；若 v2rayN 正开 TUN，请先关闭；输入 q 取消", "Press Enter to re-check; if v2rayN TUN is active, disable it first; type q to cancel"))))
		if a.inputClosed || answer == "q" {
			return false
		}
	}
}

func (a *App) guideCloudflareOrangeSetup(domain string) error {
	a.println()
	a.println(a.msg("Cloudflare 人工门禁：每完成一项回到这里按 Enter；输入 q 会安全停止，不会伪造完成状态。", "Cloudflare manual gate: press Enter after each item; type q to stop safely without claiming completion."))
	steps := [][2]string{
		{"确认该子域名 A 记录已开启橙云 Proxied", "Confirm the hostname A record is orange-cloud Proxied"},
		{"SSL/TLS 模式设为 Full (strict)，并确认 Universal SSL 已激活", "Set SSL/TLS to Full (strict) and confirm Universal SSL is active"},
		{"确认客户端将使用 " + domain + ":8443；免费计划不需要 443→8443 Origin Rule", "Confirm clients will use " + domain + ":8443; the free plan does not need a 443-to-8443 Origin Rule"},
		{"为该 hostname 创建 Cache Rule：Bypass cache；不要附加 Access、Turnstile、质询、重定向或 Worker", "Create a Cache Rule for this hostname: Bypass cache; attach no Access, Turnstile, challenge, redirect, or Worker"},
	}
	for i, step := range steps {
		a.println(fmt.Sprintf("[%d/4] %s", i+1, a.msg(step[0], step[1])))
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("确认后按 Enter；输入 q 取消", "Press Enter to confirm; type q to cancel"))))
		if a.inputClosed || answer == "q" {
			return errors.New(a.msg("Cloudflare 设置尚未完成，公网 CDN 未提交。", "Cloudflare setup is incomplete; the public CDN was not committed."))
		}
	}
	return nil
}

func (a *App) guideCloudflareOriginCertificatePrerequisites(domain string) error {
	a.println()
	a.println(a.msg("橙云源站证书前置门禁：Cloudflare Universal SSL 只是浏览器到边缘的证书；Full (strict) 仍要求 VPS 源站有可验证证书。", "Orange-origin certificate gate: Cloudflare Universal SSL covers browser-to-edge only; Full (strict) still requires a verifiable certificate on the VPS origin."))
	a.println(a.msg("每确认一项按 Enter；输入 q 会在证书和代理施工前安全取消。", "Press Enter after each item; type q to cancel safely before certificate or proxy construction."))
	steps := [][2]string{
		{"已确认 " + domain + " 的 A 记录指向当前 VPS 并开启 Proxied 橙云", "Confirm " + domain + " points to this VPS and is Proxied"},
		{"该 hostname 当前没有 Access、Turnstile、质询、Worker 或强制重定向拦截 /.well-known/acme-challenge/", "No Access, Turnstile, challenge, Worker, or forced redirect currently intercepts /.well-known/acme-challenge/ on this hostname"},
		{"已理解程序将使用手填邮箱签发 VPS 源站证书，不会索取 Cloudflare API Token", "Understand that the app will issue the VPS origin certificate using the typed email and will not request a Cloudflare API token"},
	}
	for i, step := range steps {
		a.println(fmt.Sprintf("[%d/%d] %s", i+1, len(steps), a.msg(step[0], step[1])))
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("确认后按 Enter；输入 q 取消", "Press Enter to confirm; type q to cancel"))))
		if a.inputClosed || answer == "q" {
			return errors.New(a.msg("橙云源站证书前置条件未确认，本次尚未开始远端代理施工。", "Orange-origin certificate prerequisites were not confirmed; remote proxy construction has not started."))
		}
	}
	return nil
}
