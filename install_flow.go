package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var coverTemplateCatalog = []string{
	" 1  atlas-journal      Atlas Journal",
	" 2  northstar-studio   Northstar Studio",
	" 3  cedar-stone        Cedar & Stone",
	" 4  field-lab          Field Lab",
	" 5  harbor-weather     Harbor Weather",
	" 6  local-library      Local Library",
	" 7  ember-cafe         Ember Café",
	" 8  trail-guide        Trail Guide",
	" 9  signal-status      Signal Status",
	"10  mono-docs          Mono Docs",
	"11  analog-radio       Analog Radio",
	"12  city-calendar      City Calendar",
	"13  pixel-gallery      Pixel Gallery",
	"14  quiet-finance      Quiet Finance",
	"15  signal-runner      Signal Runner",
}

var errInstallCancelled = errors.New("install plan cancelled")

func (a *App) existingNodeInstalled(c Connection) (bool, error) {
	command := "existing=0; " +
		"if systemctl is-active --quiet x-ui 2>/dev/null || [ -x /usr/local/x-ui/x-ui ] || [ -s /etc/x-ui/x-ui.db ]; then existing=1; fi; " +
		"printf 'TNA_EXISTING_NODE=%s\\n' \"$existing\""
	result := a.rootCapture(c, command)
	if !result.OK() {
		return false, fmt.Errorf("existing-node inspection failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	for _, line := range strings.Split(strings.ReplaceAll(result.Stdout, "\r\n", "\n"), "\n") {
		switch strings.TrimSpace(line) {
		case "TNA_EXISTING_NODE=1":
			return true, nil
		case "TNA_EXISTING_NODE=0":
			return false, nil
		}
	}
	return false, errors.New("existing-node inspection returned no trusted marker")
}

// parseExistingSS2022Port decodes the single marker emitted by
// existingSS2022Port. A missing marker is treated as an implementation
// failure rather than as "no listener", so an upgrade never silently changes
// an existing SS2022 endpoint because a probe was truncated.
func parseExistingSS2022Port(output string) (int, bool, error) {
	const marker = "TNA_EXISTING_SS2022_PORT="
	found := false
	selected := 0
	for _, raw := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, marker) {
			continue
		}
		if found {
			return 0, false, errors.New("existing SS2022 inspection returned duplicate markers")
		}
		found = true
		value := strings.TrimSpace(strings.TrimPrefix(line, marker))
		if value == "" || value == "0" {
			selected = 0
			continue
		}
		port, err := strconv.Atoi(value)
		if err != nil || port < 1024 || port > 65535 {
			return 0, false, fmt.Errorf("existing SS2022 inspection returned an invalid port %q", value)
		}
		selected = port
	}
	if !found {
		return 0, false, errors.New("existing SS2022 inspection returned no trusted marker")
	}
	return selected, true, nil
}

// existingSS2022Port is deliberately read-only. It checks managed service
// metadata first, then public compatibility metadata and finally the Xray JSON
// used by older installations. The result is fed into the install preview so
// an upgrade preserves a live trial/custom port unless migration is explicit.
func (a *App) existingSS2022Port(c Connection) (int, error) {
	command := `port=""
for f in /etc/proxy-runbook/ss2022/service.env /etc/text-node-assistant/ss2022/service.env /etc/proxy-runbook/public.env /etc/text-node-assistant/public.env; do
  [ -r "$f" ] || continue
  case "$f" in
    */ss2022/service.env)
      value=$(awk -F= '$1=="PORT" || $1=="SS2022_PORT" || $1=="PNA_SS2022_PORT" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$f" 2>/dev/null || true)
      ;;
    *)
      value=$(awk -F= '$1=="SS2022_PORT" || $1=="PNA_SS2022_PORT" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$f" 2>/dev/null || true)
      ;;
  esac
  case "$value" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null; then
        port="$value"
        break
      fi
      ;;
  esac
done
if [ -z "$port" ] && command -v jq >/dev/null 2>&1; then
  for f in /etc/proxy-runbook/ss2022/server.json /etc/text-node-assistant/ss2022/server.json; do
    [ -r "$f" ] || continue
    value=$(jq -r '.inbounds[]? | select(.protocol == "shadowsocks") | select((.settings.method? // "") | startswith("2022-")) | .port // empty' "$f" 2>/dev/null | head -n 1 || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null; then
          port="$value"
          break
        fi
        ;;
    esac
  done
fi
printf 'TNA_EXISTING_SS2022_PORT=%s\n' "${port:-0}"`
	result := a.rootCapture(c, command)
	if !result.OK() {
		return 0, fmt.Errorf("existing SS2022 inspection failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	port, _, err := parseExistingSS2022Port(result.Stdout)
	if err != nil {
		return 0, err
	}
	return port, nil
}

func (a *App) chooseRouteMode(existingNode bool) (RouteMode, error) {
	a.println()
	a.println(a.msg("请选择本次线路拓扑（必须明确选择，直接回车无效）：", "Choose the route topology for this run (an explicit choice is required):"))
	if existingNode {
		a.println(a.msg("[0] 保持现有线路：只更新工具与所选维护项，不拆、不换当前线路", "[0] Keep current routes: update the toolkit/selected maintenance only; do not replace routes"))
	}
	a.println(a.msg("[1] 仅灰云直连：链路短、性能高；域名必须 DNS only 并直指 VPS", "[1] Gray/direct only: shortest path and highest performance; DNS-only hostname must point to the VPS"))
	a.println(a.msg("[2] 仅橙云 CDN：隐藏源站、绕开部分直连故障；依赖 Cloudflare，链路更复杂", "[2] Orange/CDN only: hides the origin and may bypass direct-path failures; depends on Cloudflare and is more complex"))
	a.println(a.msg("[3] 双路：同时保留灰云 Reality 与橙云 XHTTP，便于故障切换；维护项最多", "[3] Dual: keep gray Reality and orange XHTTP for failover; has the most moving parts"))
	for {
		answer := strings.TrimSpace(a.prompt(a.msg("线路方案", "Route mode")))
		if a.inputClosed {
			return "", errInputClosed
		}
		switch answer {
		case "0":
			if existingNode {
				return RouteKeep, nil
			}
		case "1":
			return RouteGray, nil
		case "2":
			return RouteOrange, nil
		case "3":
			return RouteDual, nil
		}
		a.println(a.msg("选择无效；本项不会用默认值代替你决定。", "Invalid selection; this decision has no implicit default."))
	}
}

func (a *App) askRouteIdentity(labelZH, labelEN string) (RouteIdentity, error) {
	var identity RouteIdentity
	for {
		value, err := a.required(a.msg("请亲自输入"+labelZH+"域名（没有默认值）", "Type the "+labelEN+" hostname yourself (no default)"))
		if err != nil {
			return RouteIdentity{}, err
		}
		identity.Domain = strings.ToLower(strings.TrimSpace(value))
		if validDomain(identity.Domain) {
			break
		}
		a.println(a.msg("域名格式无效，请重输。", "That is not a valid hostname; try again."))
	}
	for {
		value, err := a.required(a.msg("请亲自输入"+labelZH+"证书邮箱（没有默认值）", "Type the "+labelEN+" certificate email yourself (no default)"))
		if err != nil {
			return RouteIdentity{}, err
		}
		identity.Email = strings.TrimSpace(value)
		if validEmail(identity.Email) {
			break
		}
		a.println(a.msg("邮箱格式无效，请重输。", "That is not a valid email address; try again."))
	}
	return identity, nil
}

func (a *App) chooseLocalCoverTemplate(existingNode bool) (string, error) {
	a.println()
	a.println(a.msg("伪装站模板（15 套均内嵌在本机包内）：", "Cover-site templates (all 15 are embedded in this package):"))
	for _, line := range coverTemplateCatalog {
		a.println(line)
	}
	if existingNode {
		a.println(a.msg("[0] 保留当前模板", "[0] Preserve the current template"))
	}
	a.println(a.msg("[R] 随机并尽量避开当前模板；[A] 按域名稳定选择；[1-15] 指定编号", "[R] Random, avoiding the current template when possible; [A] stable per hostname; [1-15] exact ID"))
	for {
		answer := strings.TrimSpace(a.prompt(a.msg("模板方案（必须明确选择）", "Template choice (explicit choice required)")))
		if a.inputClosed {
			return "", errInputClosed
		}
		if answer == "0" && existingNode {
			return "preserve", nil
		}
		if answer == "" {
			a.println(a.msg("请明确输入 0、R、A 或 1—15。", "Enter 0, R, A, or 1-15 explicitly."))
			continue
		}
		if choice, ok := normalizeCoverTemplateChoice(answer); ok {
			return choice, nil
		}
		a.println(a.msg("选择无效：请输入 R、A 或 1 到 15。", "Invalid selection: enter R, A, or a number from 1 to 15."))
	}
}

func (a *App) choosePerformanceMode(existingNode bool) (PerformanceMode, error) {
	a.println()
	a.println(a.msg("性能档位：", "Performance profile:"))
	if existingNode {
		a.println(a.msg("[0] 保留当前性能设置（零修改）", "[0] Preserve the current performance configuration (zero changes)"))
	}
	a.println(a.msg("[1] 自动：按 CPU/内存自适应", "[1] Auto: choose from CPU/RAM"))
	a.println(a.msg("[2] 低配：优先节省内存与并发", "[2] Low: prioritize memory savings and modest concurrency"))
	a.println(a.msg("[3] 标准：通用平衡档", "[3] Standard: balanced general-purpose profile"))
	a.println(a.msg("[4] 高配：更积极使用 CPU/内存换吞吐", "[4] High: use more CPU/RAM for throughput"))
	for {
		answer := strings.TrimSpace(a.prompt(a.msg("性能方案（必须明确选择）", "Performance mode (explicit choice required)")))
		if a.inputClosed {
			return "", errInputClosed
		}
		switch answer {
		case "0":
			if existingNode {
				return PerformancePreserve, nil
			}
		case "1":
			return PerformanceAuto, nil
		case "2":
			return PerformanceLow, nil
		case "3":
			return PerformanceStandard, nil
		case "4":
			return PerformanceHigh, nil
		}
		a.println(a.msg("无效选择；性能档位不会静默采用默认值。", "Invalid selection; the performance profile is never silently defaulted."))
	}
}

func (a *App) chooseWarpMode() (WarpMode, error) {
	a.println()
	a.println(a.msg("WARP 策略：", "WARP policy:"))
	a.println(a.msg("[0] 保持当前状态：未安装就不装，已安装也不改路由", "[0] Preserve current state: do not install it when absent and do not change existing routing"))
	a.println(a.msg("[1] 确保开启：幂等安装/修复本地 WARP 代理与托管路由", "[1] Ensure on: idempotently install/repair the local WARP proxy and managed route"))
	for {
		answer := strings.TrimSpace(a.prompt(a.msg("WARP 方案（必须明确选择）", "WARP mode (explicit choice required)")))
		if a.inputClosed {
			return "", errInputClosed
		}
		switch answer {
		case "0":
			return WarpPreserve, nil
		case "1":
			return WarpEnsureOn, nil
		default:
			a.println(a.msg("无效选择；WARP 不会静默开启。", "Invalid selection; WARP is never silently enabled."))
		}
	}
}

func (a *App) chooseCredentialMode(labelZH, labelEN string, existingNode bool) (CredentialMode, error) {
	a.println()
	a.println(a.msg(labelZH+"凭据策略：", labelEN+" credential policy:"))
	// A read-only preflight may have found a complete protected handoff.  In
	// that case an empty answer is a safe, explicit-preserve shortcut: the
	// remote installer still verifies the retained values before applying the
	// plan.  If readiness is unknown/incomplete, keep the old mandatory-choice
	// behavior so a blank input can never guess or rotate a credential.
	readinessComplete := existingNode && a.credentialReadiness.complete()
	if existingNode {
		if readinessComplete {
			a.println(a.msg("[0] 保留并验证当前凭据（已识别；直接回车也表示保留）", "[0] Preserve and verify the current credentials (detected; Enter also preserves)"))
		} else {
			a.println(a.msg("[0] 保留并验证当前凭据（不改密码）", "[0] Preserve and verify the current credentials (no password change)"))
		}
	}
	a.println(a.msg("[1] 生成新的随机凭据", "[1] Generate new random credentials"))
	a.println(a.msg("[2] 自定义凭据（密码仅本次加密输入，绝不写入设置/命令）", "[2] Custom credentials (secret is sent only for this run; never saved in settings/argv)"))
	for {
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg(labelZH+"策略（必须明确选择）", labelEN+" policy (explicit choice required)"))))
		if a.inputClosed {
			return "", errInputClosed
		}
		if answer == "" && readinessComplete {
			return CredentialPreserve, nil
		}
		switch answer {
		case "0":
			if existingNode {
				return CredentialPreserve, nil
			}
		case "1", "r", "random":
			return CredentialRandom, nil
		case "2", "c", "custom":
			return CredentialCustom, nil
		}
		a.println(a.msg("选择无效；凭据策略不会静默采用默认值。", "Invalid selection; credential policy is never silently defaulted."))
	}
}

func (a *App) promptMatchingSecret(labelZH, labelEN string) (string, error) {
	first := a.secretPromptExact(a.msg(labelZH+"（遮罩输入）", labelEN+" (masked input)"))
	if a.inputClosed {
		return "", errInputClosed
	}
	if !validCredentialSecret(first) {
		return "", errors.New(a.msg("密码必须为 8—256 个字符且不能含换行或 NUL。", "Password must be 8-256 characters and must not contain a newline or NUL."))
	}
	second := a.secretPromptExact(a.msg("请再次输入"+labelZH, "Repeat the "+labelEN))
	if a.inputClosed {
		return "", errInputClosed
	}
	if first != second {
		return "", errors.New(a.msg("两次密码不一致，本次未写入远端。", "The two passwords do not match; nothing was written remotely."))
	}
	return first, nil
}

func (a *App) chooseCredentialPlan(existingNode bool) (CredentialPlan, error) {
	plan := CredentialPlan{}
	var err error
	plan.VPSMode, err = a.chooseCredentialMode("VPS 登录", "VPS login", existingNode)
	if err != nil {
		return CredentialPlan{}, err
	}
	if plan.VPSMode == CredentialCustom {
		plan.VPSPassword, err = a.promptMatchingSecret("VPS 登录密码", "VPS login password")
		if err != nil {
			return CredentialPlan{}, err
		}
	}
	plan.PanelMode, err = a.chooseCredentialMode("3x-ui 面板", "3x-ui panel", existingNode)
	if err != nil {
		return CredentialPlan{}, err
	}
	if plan.PanelMode == CredentialCustom {
		plan.PanelAccount, err = a.required(a.msg("自定义 3x-ui 面板账号（字母/数字/._-）", "Custom 3x-ui panel account (letters/digits/._-)"))
		if err != nil {
			return CredentialPlan{}, err
		}
		plan.PanelAccount = strings.TrimSpace(plan.PanelAccount)
		if !validPanelAccount(plan.PanelAccount) {
			return CredentialPlan{}, errors.New(a.msg("面板账号格式无效。", "Invalid panel account format."))
		}
		plan.PanelPassword, err = a.promptMatchingSecret("3x-ui 面板密码", "3x-ui panel password")
		if err != nil {
			return CredentialPlan{}, err
		}
	}
	return plan, nil
}

func (a *App) chooseSS2022Port(existingNode bool, detected ...int) (int, error) {
	defaultPort := defaultSS2022TCPPort
	if existingNode && len(detected) > 0 && detected[0] >= 1024 && detected[0] <= 65535 {
		// An upgrade must not silently move an existing listener.  The caller
		// may explicitly enter 32443 to migrate after the trial has been tested.
		defaultPort = detected[0]
	}
	a.println()
	if existingNode && len(detected) > 0 && defaultPort != defaultSS2022TCPPort {
		a.println(a.msg(fmt.Sprintf("检测到现有 SS2022 TCP 监听 %d；直接回车保持原端口，输入 32443 或其他专用端口才会迁移。", defaultPort),
			fmt.Sprintf("Existing SS2022 TCP listener %d detected; press Enter to preserve it, or enter 32443/another dedicated port to migrate.", defaultPort)))
	} else {
		a.println(a.msg(
			"SS2022 使用 TCP-only；正式默认端口 32443。30443 仅保留给现有临时试验；留空采用 32443，也可以输入 1024—65535 的其他未占用端口。",
			"SS2022 is TCP-only and defaults to formal port 32443. 30443 remains reserved for the existing trial; press Enter for 32443 or enter another unused port from 1024 to 65535.",
		))
	}
	for {
		answer := strings.TrimSpace(a.prompt(a.msg(fmt.Sprintf("SS2022 TCP 端口 [%d]", defaultPort), fmt.Sprintf("SS2022 TCP port [%d]", defaultPort))))
		if a.inputClosed {
			return 0, errInputClosed
		}
		if answer == "" {
			return defaultPort, nil
		}
		port, err := strconv.Atoi(answer)
		if err == nil && port >= 1024 && port <= 65535 {
			conflict := false
			for _, occupied := range []int{443, 24443, 8443, 40000} {
				if port == occupied {
					conflict = true
					break
				}
			}
			if !conflict && (existingNode || port != legacySS2022TrialPort) {
				return port, nil
			}
		}
		a.println(a.msg("端口无效、与固定监听冲突，或 30443 仍是临时试验端口。", "The port is invalid, conflicts with a fixed listener, or is 30443, which remains trial-only."))
	}
}

func (a *App) collectInstallPlan(existingNode bool, detectedSS2022Port ...int) (InstallPlan, error) {
	plan := defaultInstallPlan()
	route, err := a.chooseRouteMode(existingNode)
	if err != nil {
		return InstallPlan{}, err
	}
	plan.Preferences.RouteMode = route
	if route == RouteKeep {
		plan.Preferences.CoverChoice = "preserve"
	} else {
		if route == RouteGray || route == RouteDual {
			plan.Gray, err = a.askRouteIdentity("灰云/直连", "gray/direct")
			if err != nil {
				return InstallPlan{}, err
			}
		}
		if route == RouteOrange || route == RouteDual {
			plan.Orange, err = a.askRouteIdentity("橙云/CDN", "orange/CDN")
			if err != nil {
				return InstallPlan{}, err
			}
		}
		plan.Preferences.CoverChoice, err = a.chooseLocalCoverTemplate(existingNode)
		if err != nil {
			return InstallPlan{}, err
		}
	}
	plan.Preferences.Performance, err = a.choosePerformanceMode(existingNode)
	if err != nil {
		return InstallPlan{}, err
	}
	plan.Preferences.WarpMode, err = a.chooseWarpMode()
	if err != nil {
		return InstallPlan{}, err
	}
	plan.Ports.SS2022TCP, err = a.chooseSS2022Port(existingNode, detectedSS2022Port...)
	if err != nil {
		return InstallPlan{}, err
	}
	plan.Credentials, err = a.chooseCredentialPlan(existingNode)
	if err != nil {
		return InstallPlan{}, err
	}
	plan.Preferences.BackupBeforeChange = true
	plan.Preferences.PruneAfterSuccess = a.yes(a.msg("成功后清理多余远端备份，并只保留一份新验证的当前配置备份？", "After success, prune redundant remote backups and keep one newly verified current-config backup?"), a.installPrefs.PruneAfterSuccess)
	plan.Preferences.OpenPanelOnSuccess = a.yes(a.msg("成功后通过 127.0.0.1 SSH 隧道打开 3x-ui 面板？", "After success, open 3x-ui through a 127.0.0.1 SSH tunnel?"), a.installPrefs.OpenPanelOnSuccess)
	if err := plan.validateFor(existingNode); err != nil {
		return InstallPlan{}, err
	}
	return plan, nil
}

func (a *App) confirmInstallPlan(plan InstallPlan) error {
	a.println()
	a.println(a.msg("========== 本次施工预览（邮箱已遮罩） ==========", "========== INSTALL PREVIEW (EMAIL MASKED) =========="))
	for _, line := range plan.reviewLines() {
		a.println("  " + line)
	}
	a.println(a.msg("固定协调端口：Reality 443 / 验货 24443 / CDN 源站 8443 / WARP 回环 40000；正式 SS2022 TCP 默认 32443，30443 保留为临时试验。", "Coordinated ports are fixed at Reality 443 / validation 24443 / CDN origin 8443 / WARP loopback 40000; formal SS2022 TCP defaults to 32443 while 30443 remains the trial port."))
	a.println(a.msg("已有节点必先备份；任何阶段失败都会停止后续交接、清理和开面板。", "Existing nodes are backed up first; any failure stops handoff, cleanup, and panel opening."))
	confirmation := a.prompt(a.msg("确认无误请输入大写 APPLY；其他输入取消且不会上传工具包", "Type uppercase APPLY to confirm; anything else cancels without uploading the toolkit"))
	if a.inputClosed {
		return errInputClosed
	}
	if confirmation != "APPLY" {
		a.println(a.msg("已取消；没有上传工具包，也没有开始远端施工。", "Cancelled; no toolkit was uploaded and no remote construction started."))
		return errInstallCancelled
	}
	return nil
}

func (a *App) prepareInstallPrerequisites(c Connection, plan InstallPlan) error {
	if plan.Preferences.RouteMode == RouteKeep {
		return nil
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if plan.Preferences.RouteMode == RouteGray || plan.Preferences.RouteMode == RouteDual {
		if !a.waitForDNS(plan.Gray.Domain, publicIP) {
			return errors.New(a.msg("已在灰云证书/REALITY 施工前停止。", "Stopped before gray-route certificate/REALITY construction."))
		}
	}
	if err := a.prepareCDNPrerequisites(c, plan, publicIP); err != nil {
		return err
	}
	return nil
}

func randomOneRunInputPath() (string, error) {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return "/tmp/proxy-node-assistant-auto-input-" + hex.EncodeToString(raw), nil
}

func (a *App) writeInstallAutoInput(c Connection, plan InstallPlan) (string, error) {
	path, err := randomOneRunInputPath()
	if err != nil {
		return "", fmt.Errorf("could not create one-run input name: %w", err)
	}
	encode := func(value string) string { return base64.StdEncoding.EncodeToString([]byte(value)) }
	content := "GRAY_DOMAIN_B64=" + encode(plan.Gray.Domain) + "\n" +
		"GRAY_EMAIL_B64=" + encode(plan.Gray.Email) + "\n" +
		"ORANGE_DOMAIN_B64=" + encode(plan.Orange.Domain) + "\n" +
		"ORANGE_EMAIL_B64=" + encode(plan.Orange.Email) + "\n" +
		"LANG=" + string(a.lang) + "\n" +
		"VPS_PASSWORD_MODE=" + string(plan.Credentials.VPSMode) + "\n" +
		"PANEL_CREDENTIAL_MODE=" + string(plan.Credentials.PanelMode) + "\n"
	if plan.Credentials.VPSMode == CredentialCustom {
		content += "VPS_PASSWORD_B64=" + encode(plan.Credentials.VPSPassword) + "\n"
	}
	if plan.Credentials.PanelMode == CredentialCustom {
		content += "PANEL_USERNAME_B64=" + encode(plan.Credentials.PanelAccount) + "\n" +
			"PANEL_PASSWORD_B64=" + encode(plan.Credentials.PanelPassword) + "\n"
	}
	// Bash noclobber makes the redirection use O_EXCL.  The explicit atomic
	// create closes the /tmp symlink/TOCTOU window that a test-then-cat sequence
	// would leave open while running as root.
	command := "set -Eeuo pipefail; umask 077; set -C; cat > " + shQuote(path) + "; set +C; chmod 600 " + shQuote(path)
	result := a.rootCaptureWithInput(c, command, []byte(content))
	if !result.OK() {
		// The remote redirection may have created a partial file before SSH or
		// chmod failed. Remove only the generated one-run namespace path; never
		// attempt cleanup on a caller-supplied arbitrary path.
		a.removeInstallAutoInput(c, path)
		return "", fmt.Errorf("failed to write one-run input (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return path, nil
}

func (a *App) removeInstallAutoInput(c Connection, path string) {
	if !regexp.MustCompile(`^/tmp/proxy-node-assistant-(auto-input|credential-input)-[0-9a-f]{6,64}$`).MatchString(path) {
		return
	}
	_ = a.rootCapture(c, "rm -f -- "+shQuote(path))
}

func (a *App) retireLegacyDeviceDriveIfPresent(c Connection, forceLegacyV095Audit bool) error {
	// The retirement worker is intentionally still the v0.9.5 worker and owns
	// the legacy /etc/text-node-assistant namespace.  Probe both namespaces so
	// a renamed v1 client does not miss an old device-gate/drive installation.
	probe := a.rootCapture(c, "present=0; for path in /etc/text-node-assistant/device-registry.json /etc/text-node-assistant/private-drive.env /etc/systemd/system/text-node-assistant-copyparty.service /opt/text-node-assistant/copyparty /etc/proxy-node-assistant/device-registry.json /etc/proxy-node-assistant/private-drive.env /etc/systemd/system/proxy-node-assistant-copyparty.service /opt/proxy-node-assistant/copyparty /etc/nginx/sites-available/tna-private-drive; do if [ -e \"$path\" ]; then present=1; fi; done; if grep -RqsE '[[:space:]](text-node-assistant-device|proxy-node-assistant-device):[^[:space:]]+[[:space:]]*$' /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null; then present=1; fi; printf 'TNA_RETIRED_FEATURES_PRESENT=%s\\n' \"$present\"")
	if !probe.OK() {
		return fmt.Errorf("legacy feature inspection failed (exit %d): %s", probe.ExitCode, processFailureDetail(probe))
	}
	if !forceLegacyV095Audit && !strings.Contains(probe.Stdout, "TNA_RETIRED_FEATURES_PRESENT=1") {
		return nil
	}
	a.println(a.msg("检测到旧 v0.9.5 的设备门限/网盘施工；正在按所有权标记安全退役，用户文件目录不删除。", "Legacy v0.9.5 device-gate/private-drive construction was found; retiring only ownership-marked components without deleting user data roots."))
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/00c-retire-v095-device-drive.sh --apply")
	if !result.OK() || (!strings.Contains(result.Stdout, "TNA_V095_FEATURE_RETIREMENT=COMPLETE") && !strings.Contains(result.Stdout, "TNA_V095_FEATURE_RETIREMENT=ALREADY_CLEAN")) {
		return fmt.Errorf("legacy feature retirement failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("旧设备门限和网盘组件已退役；迁移归档保存在 VPS 的 root-only 目录。", "Legacy device-gate and private-drive components were retired; a migration archive remains in a root-only VPS directory."))
	return nil
}

func (a *App) installEnvironment(c Connection, plan InstallPlan, inputPath, remoteGUIMode string) string {
	return "PROXY_RUNBOOK_LOGIN_USER=" + shQuote(c.User) +
		" PROXY_RUNBOOK_SSH_KEY_INSTALLED=1" +
		" PROXY_RUNBOOK_GUI_MODE=" + shQuote(remoteGUIMode) +
		" PROXY_RUNBOOK_LANG=" + shQuote(string(a.lang)) +
		" TNA_ROUTE_MODE=" + shQuote(string(plan.Preferences.RouteMode)) +
		" TNA_PERFORMANCE_MODE=" + shQuote(string(plan.Preferences.Performance)) +
		" TNA_WARP_MODE=" + shQuote(string(plan.Preferences.WarpMode)) +
		" TNA_COVER_TEMPLATE=" + shQuote(plan.Preferences.CoverChoice) +
		" TNA_PLAN_CONFIRMED='1'" +
		" TNA_REALITY_PORT=" + shQuote(fmt.Sprint(plan.Ports.RealityProduction)) +
		" TNA_REALITY_SHADOW_PORT=" + shQuote(fmt.Sprint(plan.Ports.RealityShadow)) +
		" TNA_CDN_ORIGIN_PORT=" + shQuote(fmt.Sprint(plan.Ports.CDNEdgeOrigin)) +
		" TNA_WARP_PORT=" + shQuote(fmt.Sprint(plan.Ports.WarpLoopback)) +
		" PNA_SS2022_PORT=" + shQuote(fmt.Sprint(plan.Ports.SS2022TCP)) +
		" TNA_VPS_PASSWORD_MODE=" + shQuote(string(plan.Credentials.VPSMode)) +
		" TNA_PANEL_CREDENTIAL_MODE=" + shQuote(string(plan.Credentials.PanelMode)) +
		" TNA_AUTO_INPUT=" + shQuote(inputPath)
}
