package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/mail"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type DiagItem struct {
	Code       string `json:"code"`
	Severity   string `json:"severity"`
	ZH         string `json:"zh"`
	EN         string `json:"en"`
	Action     string `json:"action"`
	AutoRepair bool   `json:"autoRepair"`
}

type DiagResult struct {
	OK     bool       `json:"ok"`
	Passes []DiagItem `json:"passes"`
	Issues []DiagItem `json:"issues"`
}

func validDomain(value string) bool {
	if len(value) > 253 || strings.ContainsAny(value, " /:@\\") {
		return false
	}
	pattern := regexp.MustCompile(`(?i)^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)
	return pattern.MatchString(value)
}

func validEmail(value string) bool {
	address, err := mail.ParseAddress(value)
	return err == nil && address.Address == value && strings.Contains(value, "@")
}

func normalizeCoverTemplateChoice(value string) (string, bool) {
	choice := strings.ToLower(strings.TrimSpace(value))
	switch choice {
	case "", "r", "random":
		return "random", true
	case "a", "auto", "stable":
		return "auto", true
	}
	number, err := strconv.Atoi(choice)
	if err != nil || number < 1 || number > 15 {
		return "", false
	}
	return strconv.Itoa(number), true
}

func (a *App) chooseCoverTemplate(c Connection) (string, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/05b-cover-site-polished.sh --list")
	if !result.OK() || !strings.Contains(result.Stdout, "COVER_TEMPLATE_LIBRARY_V2 count=15") {
		return "", fmt.Errorf(a.msg("无法读取远端 15 套伪装站模板清单（状态 %d）：%s", "Could not read the remote 15-template cover library (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	a.println()
	a.println(a.msg("可用伪装站模板：", "Available cover-site templates:"))
	a.println(strings.TrimSpace(result.Stdout))
	a.println(a.msg("R = 随机并尽量避开当前模板；A = 按域名稳定选择；1—15 = 指定编号。", "R = random and avoid the current template when possible; A = stable per domain; 1-15 = exact template."))
	for {
		answer := a.prompt(a.msg("选择模板 [R/a/1-15]（默认 R）", "Choose a template [R/a/1-15] (default R)"))
		if a.inputClosed {
			return "", errInputClosed
		}
		if choice, ok := normalizeCoverTemplateChoice(answer); ok {
			return choice, nil
		}
		a.println(a.msg("选择无效：请输入 R、A 或 1 到 15。", "Invalid selection: enter R, A, or a number from 1 to 15."))
	}
}

func (a *App) askDomainEmail() (string, string, error) {
	var domain, email string
	for {
		value, err := a.required(a.msg("请亲自输入 Cover 域名（没有默认值）", "Type the cover domain yourself (no default)"))
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
		value, err := a.required(a.msg("请亲自输入 Let's Encrypt 邮箱（没有默认值）", "Type the Let's Encrypt email yourself (no default)"))
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

func (a *App) remotePublicIP(c Connection) (string, error) {
	result := a.rootCapture(c, "ip=$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"$ip\" ] || ip=$(hostname -I | awk '{print $1}'); printf '%s\\n' \"$ip\"")
	if !result.OK() {
		return "", fmt.Errorf("public IPv4 query failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	for _, line := range strings.Split(strings.ReplaceAll(result.Stdout, "\r\n", "\n"), "\n") {
		candidate := strings.TrimSpace(line)
		parsed := net.ParseIP(candidate)
		if parsed != nil && parsed.To4() != nil {
			return parsed.String(), nil
		}
	}
	return "", errors.New(a.msg("无法可靠识别 VPS 公网 IPv4；停止 DNS/证书施工。", "Could not reliably determine the VPS public IPv4; stopping before DNS/certificate work."))
}

func (a *App) waitForDNS(domain, publicIP string) bool {
	probe := domainDNSProbe(domain, publicIP)
	a.println("DNS_RESOLVER_QUORUM " + probe.Summary())
	if probe.Accepted() {
		a.println(a.msg("DNS 已经指向这台 VPS。", "DNS already points to this VPS."))
		return true
	}
	a.println(a.msg("DNS 还没有指向这台 VPS。脚本不会猜域名。", "DNS does not yet point to this VPS. The tool will not guess your domain."))
	a.println(a.msg("请在 DNS 服务商建立/修改：", "Create/update this record at your DNS provider:"))
	a.println("  Type: A")
	a.println("  Name: " + domain)
	a.println("  Content: " + publicIP)
	a.println("  Proxy: DNS only")
	for {
		answer := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("改好后按 Enter 重新检测；输入 q 取消", "After updating DNS press Enter to re-check; type q to cancel"))))
		if a.inputClosed || answer == "q" {
			return false
		}
		a.println(a.msg("正在重新检测 DNS…", "Re-checking DNS..."))
		probe = domainDNSProbe(domain, publicIP)
		a.println("DNS_RESOLVER_QUORUM " + probe.Summary())
		if probe.Accepted() {
			a.println(a.msg("DNS 已经指向这台 VPS。", "DNS already points to this VPS."))
			return true
		}
		a.println(a.msg("还没生效。可以继续等，也可以稍后重跑。", "It is not effective yet. Keep waiting or rerun later."))
	}
}

func (a *App) deployOptimize() error {
	c, err := a.readyConn()
	if err != nil {
		return fmt.Errorf(a.msg("SSH 初始化失败：%w", "SSH setup failed: %w"), err)
	}

	// Everything before confirmInstallPlan is read-only apart from the SSH
	// authentication setup explicitly selected by the user.  In particular,
	// the embedded toolkit is not uploaded before the full plan is reviewed.
	probe, err := a.remoteToolkitProbe(c)
	if err != nil {
		return fmt.Errorf(a.msg("远端工具包版本检测失败：%w。没有上传任何东西。", "Remote toolkit version detection failed: %w. Nothing was uploaded."), err)
	}
	relation, err := classifyToolkit(probe, toolkitVersion)
	if err != nil {
		return fmt.Errorf(a.msg("远端工具包版本无法安全识别：%w。没有上传任何东西。", "The remote toolkit version could not be safely classified: %w. Nothing was uploaded."), err)
	}
	updateSameVersionBuild := false
	legacyV095Audit := probe.Present && probe.Version == toolkitVersion && probe.BuildRevision > 0 && probe.BuildRevision < toolkitBuildRevision
	switch relation {
	case ToolkitSameComplete:
		switch compareToolkitBuild(probe, toolkitBuildID, toolkitBuildRevision) {
		case -1:
			updateSameVersionBuild = true
			a.println(a.msg("检测到同版本旧构建；菜单 [1] 将只更新工具包构建，不会重装现有节点。", "An older build of the same version was detected; menu [1] will update only the toolkit build, not reinstall the existing node."))
		case 0:
			a.println(a.msg("检测到远端版本和构建均与当前 EXE 一致；禁止重复安装，跳过上传和 bootstrap。", "The remote version and build match this EXE; repeat installation is blocked, so upload and bootstrap are skipped."))
		default:
			return fmt.Errorf(a.msg("远端同版本构建比当前 EXE 新；禁止降级，请换用更新的 EXE", "The remote same-version build is newer than this EXE; downgrade is blocked. Use a newer EXE"))
		}
	case ToolkitSameIncomplete:
		if legacyV095Audit {
			updateSameVersionBuild = true
			a.println(a.msg("检测到旧产品线 v1.0.0 的不完整构建；其内部修订低于重置线，将允许一次受控替换并退役设备门限/网盘。", "An incomplete build from the old v1.0.0 product line was detected; its internal revision predates the reset line, so one controlled replacement and feature retirement is allowed."))
		} else {
			return fmt.Errorf(a.msg(
				"远端已有重置线同版本 v%s，但文件不完整；为防止循环重装，本次拒绝覆盖。请先运行 [13]，确认卸载后再回 [1]",
				"The reset-line toolkit v%s matches this EXE but is incomplete; overwrite is refused to prevent reinstall loops. Run [13], confirm uninstall, then return to [1]",
			), toolkitVersion)
		}
	case ToolkitNewer:
		return fmt.Errorf(a.msg(
			"远端工具包 v%s 比当前 EXE v%s 新；本次禁止降级，也不会继续施工。请换用 v%s 或更新版本的 EXE",
			"Remote toolkit v%s is newer than this EXE v%s; downgrade and further convergence are blocked. Use an EXE matching v%s or newer",
		), probe.Version, toolkitVersion, probe.Version)
	case ToolkitOlder:
		a.println(fmt.Sprintf(a.msg("检测到远端旧版本 v%s；菜单 [1] 将升级到 v%s，成功后清理旧版程序。", "Remote toolkit v%s is older; menu [1] will upgrade to v%s and remove old program copies after success."), probe.Version, toolkitVersion))
	case ToolkitMissing:
		a.println(a.msg("远端未安装工具包；菜单 [1] 将安装当前内嵌版本。", "No remote toolkit is installed; menu [1] will install the embedded version."))
	}

	existingNode, err := a.existingNodeInstalled(c)
	if err != nil {
		return fmt.Errorf(a.msg("无法只读识别现有节点状态：%w。没有上传任何东西。", "Could not inspect the existing-node state read-only: %w. Nothing was uploaded."), err)
	}
	if existingNode {
		a.println(a.msg("检测到已有 x-ui 节点：可选择 [0] 保持线路；任何变更都先备份。", "An existing x-ui node was detected: route [0] is available, and every change is backed up first."))
	} else {
		a.println(a.msg("未检测到已安装节点：必须明确选择灰云、橙云或双路之一。", "No installed node was detected: explicitly choose gray, orange, or dual."))
	}
	existingSSPort, err := a.existingSS2022Port(c)
	if err != nil {
		return fmt.Errorf(a.msg("无法只读识别现有 SS2022 端口：%w。没有上传任何东西。", "Could not inspect the existing SS2022 port read-only: %w. Nothing was uploaded."), err)
	}
	if existingSSPort > 0 {
		a.println(fmt.Sprintf(a.msg("检测到现有 SS2022 TCP 端口 %d；预览默认保持它，只有明确输入新端口才迁移。", "Existing SS2022 TCP port %d detected; the preview will preserve it by default and migrate only on an explicit new-port choice."), existingSSPort))
	} else {
		a.println(a.msg("未检测到现有 SS2022 监听；新部署预览默认使用正式端口 32443。", "No existing SS2022 listener was detected; a fresh deployment preview defaults to the formal port 32443."))
	}
	plan, err := a.collectInstallPlan(existingNode, existingSSPort)
	if err != nil {
		return err
	}
	if err := a.confirmInstallPlan(plan); err != nil {
		if errors.Is(err, errInstallCancelled) {
			return nil
		}
		return err
	}
	if err := a.prepareInstallPrerequisites(c, plan); err != nil {
		return err
	}

	// Only non-sensitive preferences are persisted, and only after APPLY.
	a.installPrefs = plan.Preferences
	a.saveLanguage()

	if relation == ToolkitOlder || relation == ToolkitMissing || updateSameVersionBuild {
		if err := a.uploadToolkit(c); err != nil {
			return fmt.Errorf(a.msg("工具包按需安装/升级失败：%w", "On-demand toolkit install/upgrade failed: %w"), err)
		}
	}
	// The transaction helper is part of the v1 toolkit, but may be absent on
	// an older v0.9.x node until the guarded upload above completes.  Recover
	// any unfinished snapshot before taking a new baseline or touching the
	// node; otherwise a second run could layer changes on a half-applied one.
	if err := a.recoverInterruptedInstallTransaction(c); err != nil {
		return fmt.Errorf(a.msg("上次未提交施工无法安全恢复：%w", "The previous uncommitted construction could not be recovered safely: %w"), err)
	}
	if err := a.captureOriginalBaseline(c); err != nil {
		return err
	}
	transactionID, err := a.beginInstallTransaction(c)
	if err != nil {
		return err
	}
	transactionActive := true
	defer func() {
		if !transactionActive {
			return
		}
		if rollbackErr := a.rollbackInstallTransaction(c, transactionID); rollbackErr != nil {
			a.println(a.msg("未提交施工的事务回滚失败，请立即运行菜单 [3] 并保留远端救援信息：", "The uncommitted install transaction could not be rolled back; run menu [3] immediately and preserve the remote recovery details:") + " " + rollbackErr.Error())
		} else {
			a.println(a.msg("本次未提交施工已按事务快照回滚。", "The uncommitted construction was rolled back to its transaction snapshot."))
		}
	}()
	if err := a.retireLegacyDeviceDriveIfPresent(c, legacyV095Audit); err != nil {
		return err
	}
	inputPath, err := a.writeInstallAutoInput(c, plan)
	if err != nil {
		return err
	}
	defer a.removeInstallAutoInput(c, inputPath)
	a.println(a.msg("开始按预览方案施工；24443 真机验货仍会强制停下确认，任何失败都不会连锁。", "Starting the reviewed plan; real 24443 validation still requires explicit confirmation, and failures do not chain."))
	remoteGUIMode := "0"
	if os.Getenv("PNA_GUI_MODE") == "1" {
		remoteGUIMode = "1"
	}
	command := a.installEnvironment(c, plan, inputPath, remoteGUIMode) +
		" bash " + remoteRoot + "/linux/00-auto-install-or-optimize.sh"
	result := a.runRootInteractive(c, command)
	if !shouldContinueAfterWizard(result.ExitCode) {
		status := a.remoteRunStatus(c)
		detail := processFailureDetail(result)
		if status != nil {
			a.println()
			a.println(a.msg("远端施工失败位置：", "Remote failure location:"))
			a.println("  RUN_STATUS=" + status["RUN_STATUS"])
			a.println("  RUN_STAGE=" + status["RUN_STAGE"])
			a.println("  RUN_EXIT_CODE=" + status["RUN_EXIT_CODE"])
			if status["COVER_STAGE"] != "" {
				a.println("  COVER_STAGE=" + status["COVER_STAGE"])
			}
		}
		if detail != "" {
			a.println(a.msg("SSH/远端错误摘要：", "SSH/remote error summary:"))
			a.println(detail)
		}
		a.println(a.msg("本分支已硬停止：不会复制交接单，也不会询问打开面板。下一步运行菜单 [3]。", "This branch stopped fail-closed: no handoff is copied and no panel is opened. Run menu [3] next."))
		return fmt.Errorf(a.msg("远端向导返回非零状态 %d", "remote wizard returned non-zero status %d"), result.ExitCode)
	}

	// Core input is intentionally one-use.  CDN reconciliation gets a fresh
	// random 0600 input instead of relying on a fixed or already-consumed path.
	cdnInputPath, err := a.writeInstallAutoInput(c, plan)
	if err != nil {
		return err
	}
	defer a.removeInstallAutoInput(c, cdnInputPath)
	if err := a.reconcileCDNRoute(c, plan, cdnInputPath); err != nil {
		a.println(a.msg("线路拓扑未通过最终收敛；不会复制交接单、清理备份或打开面板。", "Route topology did not pass final reconciliation; no handoff, backup pruning, or panel opening will follow."))
		return err
	}

	handoff, handoffErr := a.fetchHandoff(c)
	if handoffErr != nil {
		// The handoff is part of the install contract: it carries the VPS and
		// panel credentials plus all three client links.  Do not commit a
		// remotely-mutated node when that evidence cannot be validated/exported.
		return fmt.Errorf(a.msg("施工阶段完成，但强制交接单未通过完整性校验；本次不会提交半交付状态：%w", "Construction stages completed, but the mandatory handoff failed integrity validation; a partially delivered state will not be committed: %w"), handoffErr)
	}
	complete, completeErr := a.buildCompleteHandoff(handoff, c)
	if completeErr != nil {
		return fmt.Errorf(a.msg("完整交接单追加块生成失败；本次不会提交半交付状态：%w", "Complete handoff appendix generation failed; a partially delivered state will not be committed: %w"), completeErr)
	}
	handoff = complete
	if err := a.secretHandoff("CREDENTIAL HANDOFF", handoff); err != nil {
		// Clipboard failure does not invalidate the remote state, but make the
		// error visible and require the operator to save the printed block.
		a.println(err.Error())
	}
	if err := a.commitInstallTransaction(c, transactionID); err != nil {
		return err
	}
	transactionActive = false
	if plan.Preferences.PruneAfterSuccess {
		if err := a.pruneBackupsAndBackupCurrentConfigWithConn(c, false); err != nil {
			return fmt.Errorf(a.msg("远端备份整理失败；为避免继续连锁操作，本次不打开面板：%w", "Remote backup cleanup failed; the panel will not be opened to avoid chained actions: %w"), err)
		}
	} else {
		a.println(a.msg("已跳过远端备份整理；现有备份保持不动。", "Remote backup cleanup was skipped; existing backups were left unchanged."))
	}
	if plan.Preferences.OpenPanelOnSuccess {
		return a.openPanelWithConn(c)
	}
	return nil
}

func (a *App) uninstallRemoteToolkit() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	a.println(a.msg(
		"此操作只卸载 ProxyNodeAssistant 上传的远端工具包程序。",
		"This removes only the remote toolkit program uploaded by ProxyNodeAssistant.",
	))
	a.println(a.msg(
		"会删除：/opt 下已知旧版及重置版 v1.0.0 工具包、兼容链接、text-node/proxy-node 命令和对应 /tmp 上传残留。",
		"It removes known legacy and reset-v1.0.0 toolkit directories under /opt, compatibility links, text-node/proxy-node launchers, and matching /tmp upload remnants.",
	))
	a.println(a.msg(
		"不会删除：x-ui/Xray、Nginx、WARP、节点配置、凭据、证书或灾备。卸载后只有菜单 [1] 可以重新安装内嵌包。",
		"It does not remove x-ui/Xray, Nginx, WARP, node configuration, credentials, certificates, or backups. Afterward, only menu [1] can reinstall the embedded toolkit.",
	))
	confirmation := a.prompt(a.msg("确认卸载请输入大写 UNINSTALL；其他输入取消", "Type uppercase UNINSTALL to confirm; anything else cancels"))
	if confirmation != "UNINSTALL" {
		a.println(a.msg("已取消，没有删除任何远端文件。", "Cancelled; no remote files were deleted."))
		return nil
	}

	result := a.rootCapture(c, toolkitUninstallCommand())
	if !result.OK() {
		return fmt.Errorf(a.msg("远端工具包卸载失败（状态 %d）：%s", "Remote toolkit uninstall failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	if !strings.Contains(result.Stdout, "PROXY_RUNBOOK_UNINSTALL_BEGIN\n") || !strings.Contains(result.Stdout, "PROXY_RUNBOOK_UNINSTALL_END") {
		return errors.New(a.msg("远端返回成功，但缺少完整卸载确认标记；请不要假定已经删除。", "The remote command succeeded without a complete uninstall marker; do not assume removal."))
	}
	a.println(strings.TrimSpace(result.Stdout))
	a.println(a.msg(
		"远端内嵌工具包已卸载；节点服务与数据保持原样。需要恢复管理功能时运行菜单 [1]。",
		"The remote embedded toolkit is uninstalled; node services and data remain intact. Run menu [1] to restore management functionality.",
	))
	return nil
}

func fileSHA256(path string) (string, error) {
	input, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer input.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, input); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

func (a *App) downloadDismantleRescue(c Connection, remotePath string) (string, error) {
	remoteHashResult := a.rootCapture(c, "sha256sum -- "+shQuote(remotePath))
	if !remoteHashResult.OK() {
		return "", fmt.Errorf("remote rescue checksum failed (exit %d): %s", remoteHashResult.ExitCode, processFailureDetail(remoteHashResult))
	}
	hashPattern := regexp.MustCompile(`(?m)^([0-9a-f]{64})[[:space:]]`)
	hashMatch := hashPattern.FindStringSubmatch(strings.ToLower(remoteHashResult.Stdout))
	if len(hashMatch) != 2 {
		return "", errors.New("remote rescue checksum was not recognized")
	}

	stamp := time.Now().Format("20060102-150405")
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	downloadDir := filepath.Join(home, "Downloads", "ProxyNodeAssistant-Rescue")
	if err := os.MkdirAll(downloadDir, 0700); err != nil {
		return "", err
	}
	localPath := filepath.Join(downloadDir, "pre-dismantle-"+stamp+".tar.gz")
	output, err := os.OpenFile(localPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", err
	}
	complete := false
	defer func() {
		_ = output.Close()
		if !complete {
			_ = os.Remove(localPath)
		}
	}()
	args := sshBase(c, true, false, "")
	args = append(args, target(c), wrapRoot(c, "cat -- "+shQuote(remotePath), true))
	download := exec.Command(managedCommandPath("ssh.exe"), args...)
	var stderr strings.Builder
	download.Stdout = output
	download.Stderr = &stderr
	if err := download.Run(); err != nil {
		return "", fmt.Errorf("SSH-stream rescue download failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if err := output.Sync(); err != nil {
		return "", err
	}
	if err := output.Close(); err != nil {
		return "", err
	}
	localHash, err := fileSHA256(localPath)
	if err != nil {
		return "", err
	}
	if localHash != hashMatch[1] {
		return "", fmt.Errorf("downloaded rescue checksum mismatch: local=%s remote=%s", localHash, hashMatch[1])
	}
	complete = true
	return localPath, nil
}

func (a *App) dismantleManagedNode() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	plan := a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --plan")
	if !plan.OK() {
		return fmt.Errorf("dismantle plan failed (exit %d): %s", plan.ExitCode, processFailureDetail(plan))
	}
	if !strings.Contains(plan.Stdout, "PNA_DISMANTLE_PLAN_BEGIN\n") || !strings.Contains(plan.Stdout, "PNA_DISMANTLE_PLAN_END") {
		return errors.New(a.msg("远端没有返回完整拆除计划；拒绝继续。", "The remote did not return a complete dismantle plan; refusing to continue."))
	}
	a.println(strings.TrimSpace(plan.Stdout))
	a.println(a.msg(
		"高风险操作：程序会先在 Windows 下载一份校验过的完整救援包，再拆除本工具管理的节点栈、网站、证书、WARP、性能配置、流量组件、远端工具与备份。SSH 配置、当前登录 key、22 端口和共享系统基础包保留。",
		"HIGH RISK: a verified full rescue archive is downloaded to Windows first. The tool then removes its managed node stack, cover site, certificate, WARP, performance settings, traffic component, remote toolkit, and backups. SSH configuration, the current login key, port 22, and shared system base packages are preserved.",
	))
	confirmation := strings.TrimSpace(a.prompt(a.msg("确认全量拆除请输入大写 RESTORE ORIGINAL", "Type uppercase RESTORE ORIGINAL to confirm full dismantling")))
	if confirmation != "RESTORE ORIGINAL" {
		a.println(a.msg("已取消；没有创建备份或修改远端。", "Cancelled; no backup was created and the remote was not changed."))
		return nil
	}
	legacy := strings.Contains(plan.Stdout, "RESTORE_GRADE=LEGACY_UNCERTAIN")
	if legacy {
		a.println(a.msg("该节点由旧版施工，缺少施工前基线；只能执行有边界的 legacy 全拆，不能声称逐字节还原。", "This node was built by an older release and has no pre-install baseline. Only bounded legacy full removal is possible; byte-for-byte restoration cannot be claimed."))
		legacyConfirmation := strings.TrimSpace(a.prompt(a.msg("接受该限制请输入大写 LEGACY FULL RESTORE", "Type uppercase LEGACY FULL RESTORE to accept this limitation")))
		if legacyConfirmation != "LEGACY FULL RESTORE" {
			a.println(a.msg("已取消；远端保持不变。", "Cancelled; the remote was left unchanged."))
			return nil
		}
	}

	a.println(a.msg("正在创建拆除前完整救援包…", "Creating the full pre-dismantle rescue archive..."))
	backup := a.rootCapture(c, "bash "+remoteRoot+"/linux/01-safe-backup.sh")
	if !backup.OK() || !strings.Contains(backup.Stdout, "BACKUP_OK\n") {
		return fmt.Errorf("pre-dismantle backup failed (exit %d): %s", backup.ExitCode, processFailureDetail(backup))
	}
	archivePattern := regexp.MustCompile(`/root/(?:text-node|proxy-node)-backup-[0-9]{8}-[0-9]{6}\.tar\.gz`)
	remoteArchive := archivePattern.FindString(backup.Stdout)
	if remoteArchive == "" {
		return errors.New(a.msg("备份返回成功，但没有识别到安全归档路径；拒绝拆除。", "The backup reported success but no safe archive path was recognized; refusing to dismantle."))
	}
	localArchive, err := a.downloadDismantleRescue(c, remoteArchive)
	if err != nil {
		return fmt.Errorf(a.msg("救援包未能下载并通过 SHA-256 校验；拒绝拆除：%w", "The rescue archive could not be downloaded and SHA-256 verified; refusing to dismantle: %w"), err)
	}
	a.println(a.msg("救援包已下载并通过 SHA-256 校验：", "The rescue archive was downloaded and SHA-256 verified:") + " " + localArchive)

	command := "PNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL"
	if legacy {
		command += " PNA_LEGACY_FULL=1"
	}
	command += " bash " + remoteRoot + "/linux/22-dismantle-managed-node.sh --execute"
	result := a.runRootInteractive(c, command)
	if !result.OK() {
		return fmt.Errorf(a.msg("远端拆除失败（状态 %d）；Windows 救援包保留在 %s：%s", "Remote dismantling failed (exit %d); the Windows rescue remains at %s: %s"), result.ExitCode, localArchive, processFailureDetail(result))
	}
	for _, marker := range []string{"PNA_DISMANTLE_BEGIN", "SSH_ACCESS_PRESERVED=1", "PRESERVED_SHARED_BASE_PACKAGES=1", "PNA_DISMANTLE_END"} {
		if !strings.Contains(result.Stdout, marker) {
			return fmt.Errorf("remote dismantle returned success but marker %s is missing; rescue=%s", marker, localArchive)
		}
	}
	verify := a.rootCapture(c, "set -e; test ! -e /opt/proxy-node-assistant-current; test ! -e /opt/proxy-runbook-current; test ! -e /etc/proxy-runbook; test ! -e /root/.config/proxy-runbook; printf 'PNA_POST_DISMANTLE_VERIFY_OK\\n'")
	if !verify.OK() || !strings.Contains(verify.Stdout, "PNA_POST_DISMANTLE_VERIFY_OK") {
		return fmt.Errorf(a.msg("拆除脚本已结束，但独立复核失败；救援包位于 %s", "The dismantle script ended, but independent verification failed; rescue archive: %s"), localArchive)
	}
	a.println(a.msg("全量拆除完成并独立复核通过。SSH 登录能力保留；重新部署只能运行菜单 [1]。", "Full dismantling completed and passed independent verification. SSH access was preserved; use menu [1] as the only reinstall entry."))
	a.println(a.msg("本地救援包：", "Local rescue archive:") + " " + localArchive)
	return nil
}

func (a *App) openPanel() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	return a.openPanelWithConn(c)
}

func (a *App) openPanelWithConn(c Connection) error {
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	meta, err := a.panelMetadata(c)
	if err != nil {
		return fmt.Errorf(a.msg("无法读取 panel 运行态元数据：%w。运行 [3]，不要手猜端口。", "Could not read panel runtime metadata: %w. Run [3]; do not guess the port."), err)
	}
	localPort, err := a.startTunnel(c, meta.Port)
	if err != nil {
		return fmt.Errorf(a.msg("SSH 隧道启动失败：%w", "Failed to start SSH tunnel: %w"), err)
	}
	panelURL := fmt.Sprintf("http://127.0.0.1:%d%s", localPort, meta.Path)
	if err := openURL(panelURL); err != nil {
		return fmt.Errorf("tunnel is ready but the browser could not be opened: %w", err)
	}
	a.println(a.msg("面板已通过 127.0.0.1 本地隧道打开：", "Panel opened through a local 127.0.0.1 tunnel:") + " " + panelURL)
	a.println(a.msg("元数据来源：", "Metadata source:") + " " + meta.Source)
	a.println(a.msg("EXE 退出时会终止自己创建的隧道。", "The tunnel is terminated automatically when this EXE exits."))
	if handoff, err := a.fetchHandoff(c); err == nil {
		// This shortcut used to parse the raw concatenated handoff directly,
		// bypassing the canonical formatter.  On an upgraded node that exposed
		// the legacy PANEL_USERNAME/PASSWORD rows (and occasionally an older
		// archived password) even though menu [7] showed the new form.  Resolve
		// the same last-usable values used by the form and expose only the
		// canonical account spelling here.
		account := handoffCredentialValue(handoff, "PANEL_ACCOUNT", "PANEL_USERNAME")
		password := handoffCredentialValue(handoff, "PANEL_PASSWORD")
		if account != "" {
			a.println("PANEL_ACCOUNT=" + account)
		}
		if password != "" {
			if copyClipboard(password) == nil {
				a.println(a.msg("PANEL_PASSWORD 已单独复制到剪贴板；粘贴后请用菜单 [12] 清空。", "PANEL_PASSWORD was copied alone; use menu [12] to clear it after pasting."))
			}
		}
	}
	return nil
}

func (a *App) printDiagnosis(result DiagResult) {
	a.println("—— GOOD ——")
	for _, item := range result.Passes {
		text := item.ZH
		if a.lang == LangEN || text == "" {
			text = item.EN
		}
		a.println("[GOOD] " + item.Code + ": " + text)
	}
	a.println()
	a.println(a.msg("—— 需要注意 / 问题 ——", "—— ISSUES ——"))
	if len(result.Issues) == 0 {
		a.println(a.msg("没有发现已知异常。此时最合理的动作通常是“不动它”。", "No known issue was found. The best action is usually to leave it unchanged."))
	}
	for _, item := range result.Issues {
		text := item.ZH
		if a.lang == LangEN || text == "" {
			text = item.EN
		}
		a.println("[" + item.Severity + "] " + item.Code + ": " + text)
		a.println("  NEXT=" + item.Action + " AUTO_REPAIR=" + strconv.FormatBool(item.AutoRepair))
	}
}

func (a *App) diagnoseWithConn(c Connection, offerRepair bool) error {
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/16-auto-diagnose.sh --protocol-v1")
	if !result.OK() {
		return fmt.Errorf(a.msg("结构化诊断命令失败（退出码 %d）：%s", "Structured diagnosis command failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	diagnosis, err := parseDiagnosticProtocol(result.Stdout)
	if err != nil {
		return fmt.Errorf("structured diagnosis failed: %w", err)
	}
	a.printDiagnosis(diagnosis)
	if offerRepair {
		for _, issue := range diagnosis.Issues {
			if issue.AutoRepair {
				if a.yes(a.msg("检测到可确定性自动修复项。现在先备份再修复？", "Deterministic auto-repairable issues were found. Back up and repair now?"), false) {
					return a.safeRepairWithConn(c)
				}
				break
			}
		}
	}
	return nil
}

func (a *App) diagnose() error {
	if err := a.ensureOpenSSH(); err != nil {
		return err
	}
	candidate, err := a.getActionConnection()
	if err != nil {
		return err
	}
	if !tcpReachable(candidate.Host, candidate.Port) {
		a.println(a.msg("【本地诊断】SSH TCP 根本连不到。此时不要重装 Xray。", "[Local diagnosis] SSH TCP is unreachable. Do not reinstall Xray at this stage."))
		a.println(a.msg("可能层级：VPS 关机 / IP 或线路不可达 / SSH 端口写错 / 防火墙 / 上游封锁。", "Possible layers: VPS down / path or IP unreachable / wrong SSH port / firewall / upstream filtering."))
		a.println(a.msg("下一步：先到 VPS 厂商 Console/VNC 看机器是否活着；再换宽带/热点对照测试。", "Next: check the provider Console/VNC, then compare another network/hotspot."))
		return nil
	}
	c, err := a.readyConn()
	if err != nil {
		return fmt.Errorf(a.msg("SSH 登录层仍失败：%w", "SSH authentication layer still fails: %w"), err)
	}
	a.println(a.msg("【GOOD】SSH TCP 可达，问题至少不是“完全到不了 VPS”。", "[GOOD] SSH TCP is reachable; the VPS is not completely unreachable."))
	if observed, detectErr := localPublicIPv4(); detectErr == nil {
		a.println(fmt.Sprintf("LOCAL_PUBLIC_IPV4=%s (%d/%d direct sources agree)", observed.IP, len(observed.Sources), observed.Total))
	} else {
		a.println(a.msg("[WARN] 本机公网 IPv4 多源直查失败：", "[WARN] Direct multi-source local public-IPv4 detection failed: ") + detectErr.Error())
	}
	a.runThreeRouteReachability(c)
	return a.diagnoseWithConn(c, true)
}

func (a *App) safeRepair() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	return a.safeRepairWithConn(c)
}

func (a *App) safeRepairWithConn(c Connection) error {
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	if !a.yes(a.msg("确认执行？脚本会先备份；不会改生产 Reality 443，也不会删除未知防火墙规则。", "Continue? The script backs up first; it does not rewrite production Reality 443 or delete unknown firewall rules."), false) {
		return nil
	}
	result := a.runRootInteractive(c, "bash "+remoteRoot+"/linux/17-safe-auto-repair.sh")
	if !result.OK() {
		return fmt.Errorf("safe repair failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return a.diagnoseWithConn(c, false)
}

func (a *App) rotateVPSPassword() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	user := strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("要修改密码的 VPS 用户 [%s]", "VPS user whose password should be rotated [%s]"), c.User)))
	if user == "" {
		user = c.User
	}
	if !userPartPattern.MatchString(user) {
		return errors.New(a.msg("用户名格式无效。", "Invalid username."))
	}
	if !a.yes(a.msg("确认生成高强度随机密码并立即写入？SSH key 已存在，不会因此失联。", "Generate a high-entropy random password and apply it now? SSH key authentication is already available."), false) {
		return nil
	}
	command := "source " + remoteRoot + "/linux/lib-handoff.sh; handoff_begin_run; bash " + remoteRoot + "/linux/01a-rotate-vps-password.sh " + shQuote(user)
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf(a.msg("密码轮换失败（退出码 %d）：%s", "Password rotation failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	handoff, err := a.fetchHandoff(c)
	if err != nil {
		return err
	}
	if complete, completeErr := a.buildCompleteHandoff(handoff, c); completeErr == nil {
		handoff = complete
	} else {
		return completeErr
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", handoff)
}

func (a *App) rotatePanelCredentials() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	a.println(a.msg("注意：修改 3x-ui 用户名/密码会注销现有会话，也可能关闭现有 2FA。", "Warning: rotating 3x-ui credentials logs out current sessions and may disable existing 2FA."))
	if !a.yes(a.msg("继续生成新的随机面板用户名和密码？", "Continue with a new random panel username and password?"), false) {
		return nil
	}
	command := "source " + remoteRoot + "/linux/lib-handoff.sh; handoff_begin_run; bash " + remoteRoot + "/linux/03c-rotate-panel-credentials.sh"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf(a.msg("面板凭据轮换失败（退出码 %d）：%s", "Panel credential rotation failed (exit %d): %s"), result.ExitCode, processFailureDetail(result))
	}
	handoff, err := a.fetchHandoff(c)
	if err != nil {
		return err
	}
	if complete, completeErr := a.buildCompleteHandoff(handoff, c); completeErr == nil {
		handoff = complete
	} else {
		return completeErr
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", handoff)
}

func (a *App) showHandoff() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	handoff, err := a.fetchHandoff(c)
	if err != nil {
		return fmt.Errorf(a.msg("当前没有可验证的交接单：%w", "No validated credential handoff is available: %w"), err)
	}
	if complete, completeErr := a.buildCompleteHandoff(handoff, c); completeErr == nil {
		handoff = complete
	} else {
		return completeErr
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", handoff)
}

func (a *App) runtimePublicEnv(c Connection) (map[string]string, error) {
	// v0.9.x wrote this file below /etc/text-node-assistant.  Read legacy
	// first and the reset-line path second so newer values win while old
	// installations remain inspectable during migration.
	result := a.rootCapture(c, "for f in /etc/text-node-assistant/public.env /etc/proxy-runbook/public.env; do [ -r \"$f\" ] && cat \"$f\"; done")
	if !result.OK() {
		return nil, fmt.Errorf("runtime metadata fetch failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parseKV(result.Stdout), nil
}

func (a *App) optimizeCover() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	metadata, err := a.runtimePublicEnv(c)
	if err != nil {
		return err
	}
	domain := metadata["COVER_DOMAIN"]
	if !validDomain(domain) {
		return errors.New(a.msg("当前 VPS 没有有效的 cover domain 运行态；请执行 [1] 并由本人输入域名和邮箱。", "This VPS has no valid runtime cover domain; run [1] and enter the domain/email yourself."))
	}
	custom := a.rootCapture(c, "if [ -f /var/www/cover/index.html ] && [ ! -f /var/www/cover/.proxy-runbook-cover ] && ! grep -qE 'This site is online|<h1>Welcome</h1>' /var/www/cover/index.html; then printf YES; else printf NO; fi")
	replace := false
	if custom.OK() && strings.TrimSpace(custom.Stdout) == "YES" {
		a.println(a.msg("检测到自定义网站；默认不会覆盖。", "A custom website was detected and is preserved by default."))
		replace = a.yes(a.msg("已有备份机制，仍要替换成标准伪装站？", "A backup is created; replace it with the managed cover anyway?"), false)
		if !replace {
			return nil
		}
	}
	templateChoice, err := a.chooseCoverTemplate(c)
	if err != nil {
		return err
	}
	prefix := ""
	if replace {
		prefix = "REPLACE_COVER=1 "
	}
	command := prefix + "bash " + remoteRoot + "/linux/05b-cover-site-polished.sh " + shQuote(domain) + " auto " + shQuote(templateChoice) + "; " +
		"bash " + remoteRoot + "/linux/05c-optimize-cover-backend.sh " + shQuote(domain)
	result := a.runRootInteractive(c, command)
	if !result.OK() {
		return fmt.Errorf("cover optimization failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("前台/后端优化完成。可在普通浏览器打开 Cover 域名检查。", "Cover frontend/backend optimization finished. Open the cover domain normally to inspect it."))
	return nil
}

func (a *App) backupNode() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	result := a.runRootInteractive(c, "bash "+remoteRoot+"/linux/01-safe-backup.sh")
	if !result.OK() {
		return fmt.Errorf("backup failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("备份保留在 VPS root 区；它可能包含面板 DB、证书和 WARP 身份，请勿公开。", "The backup remains in the VPS root area and may contain panel DB, certificates, and WARP identity. Keep it private."))
	return nil
}

func (a *App) pruneBackupsAndBackupCurrentConfig() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	return a.pruneBackupsAndBackupCurrentConfigWithConn(c, true)
}

func (a *App) pruneBackupsAndBackupCurrentConfigWithConn(c Connection, requireTypedConfirmation bool) error {
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	a.println(a.msg(
		"本项会先创建并完整验证一份当前配置压缩包，再删除本工具产生的旧完整备份、伪装站/Nginx 前置副本、WARP/Xray 前置模板和旧当前配置包。不会删除节点配置、证书、凭据或系统快照。",
		"This action first creates and fully verifies one current-config archive, then removes old full backups, managed cover/Nginx pre-change copies, WARP/Xray pre-change templates, and older current-config archives. It does not delete live node configuration, certificates, credentials, or provider snapshots.",
	))
	if requireTypedConfirmation {
		confirmation := strings.TrimSpace(a.prompt(a.msg("确认继续请输入大写 CLEAN", "Type uppercase CLEAN to continue")))
		if confirmation != "CLEAN" {
			return errors.New(a.msg("确认文字不匹配；没有开始备份或清理。", "Confirmation did not match; backup and cleanup were not started."))
		}
	} else {
		a.println(a.msg("你已经在菜单 [1] 的 y/n 提示中确认；现在开始创建新备份并整理旧文件。", "You confirmed at menu [1]'s y/n prompt; creating the new backup and pruning old files now."))
	}
	result := a.runRootInteractive(c, "bash "+remoteRoot+"/linux/19-prune-backups-current-config.sh")
	if !result.OK() {
		return fmt.Errorf("current-config backup cleanup failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	for _, marker := range []string{
		"CURRENT_CONFIG_BACKUP_OK",
		"OLD_REMAINING=0",
		"CURRENT_CONFIG_ARCHIVES=1",
		"MANIFEST_VERIFY_OK=1",
		"HISTORICAL_FILES_IN_ARCHIVE=0",
		"SERVICES_UNCHANGED=1",
	} {
		if !strings.Contains(result.Stdout, marker) {
			return fmt.Errorf("remote cleanup returned success but marker %s is missing", marker)
		}
	}
	archivePattern := regexp.MustCompile(`/root/(?:text-node|proxy-node)-current-config-[0-9]{8}-[0-9]{6}\.tar\.gz`)
	archive := archivePattern.FindString(result.Stdout)
	if archive == "" {
		return errors.New(a.msg("清理完成标记存在，但没有识别到唯一当前配置备份路径。", "Cleanup markers were present, but the current-config archive path was not recognized."))
	}
	a.println(a.msg("远端备份整理完成；当前只保留一份已验证的配置包：", "Remote backup cleanup completed; exactly one verified current-config archive remains:") + " " + archive)
	a.println(a.msg("该压缩包含面板数据库、证书、WARP 身份和凭据状态，只允许 root 读取，不要公开。", "The archive contains the panel database, certificates, WARP identity, and credential state. It is root-only and must not be shared."))
	return nil
}

func (a *App) emergencyReport() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/10-emergency-network-dump.sh")
	if !result.OK() {
		return fmt.Errorf("report generation failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	pathPattern := regexp.MustCompile(`/root/emergency-network-[0-9]{8}-[0-9]{6}\.txt`)
	remotePath := pathPattern.FindString(result.Stdout)
	if remotePath == "" {
		return errors.New(a.msg("没有识别到远端报告路径。", "The remote report path was not recognized."))
	}
	stamp := time.Now().Format("20060102-150405")
	tmpPath := "/tmp/proxy-node-assistant-report-" + stamp + ".txt"
	prepare := "cp " + shQuote(remotePath) + " " + shQuote(tmpPath) + "; chown " + shQuote(c.User) + " " + shQuote(tmpPath) + "; chmod 600 " + shQuote(tmpPath)
	prepared := a.rootCapture(c, prepare)
	if !prepared.OK() {
		return fmt.Errorf("could not prepare a downloadable copy (exit %d): %s", prepared.ExitCode, processFailureDetail(prepared))
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	downloadDir := filepath.Join(home, "Downloads", "ProxyNodeAssistant-Reports")
	if err := os.MkdirAll(downloadDir, 0700); err != nil {
		return err
	}
	localPath := filepath.Join(downloadDir, "emergency-network-"+stamp+".txt")
	args := scpBase(c, c.KeyPath)
	args = append(args, scpTarget(c, tmpPath), localPath)
	download := runCaptured("scp.exe", args, nil, true)
	if !download.OK() {
		return fmt.Errorf("report download failed (exit %d): %s", download.ExitCode, processFailureDetail(download))
	}
	_ = a.rootCapture(c, "rm -f -- "+shQuote(tmpPath))
	a.println(a.msg("紧急报告已下载到：", "Emergency report downloaded to:") + " " + localPath)
	a.println(a.msg("报告含 IP、端口、服务状态和日志；分享前先检查隐私。", "The report contains IPs, ports, service state, and logs; review privacy before sharing."))
	return nil
}

func (a *App) rotateSSHKey() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if c.AuthMode == AuthTemporaryPassword {
		a.println(a.msg("本项仍是临时模式，没有长期 key 可轮换。重新运行 [11]，选择 [2]，并在密码验证后确认绑定。", "This action is still temporary, so there is no managed key to rotate. Run [11] again, choose [2], and confirm binding after password verification."))
		return nil
	}
	if c.NewlyBound {
		a.println(a.msg("长期 key 已在本次密码验证后新建并绑定，无需立刻再轮换。", "A managed key was just created and bound after password verification; no immediate second rotation is needed."))
		return nil
	}
	oldVerified := verifyKey(c, c.KeyPath).OK()
	if !a.yes(a.msg("重新生成这台节点的 SSH 登录密钥？会先验证新密钥，成功后才移除旧公钥。", "Regenerate this node's SSH login key? The new key is verified before the old public key is removed."), false) {
		return nil
	}
	stamp := time.Now().Format("20060102-150405")
	newPath := c.KeyPath + ".new-" + stamp
	if err := generateKey(newPath, "proxy-node-assistant-rotated"); err != nil {
		return err
	}
	authKey := c.KeyPath
	if !oldVerified {
		a.println(a.msg("旧 key 已失效；接下来系统 ssh 会询问当前 VPS 密码来安装新公钥。", "The old key no longer works; OpenSSH will ask for the current VPS password to install the new public key."))
		authKey = ""
	}
	if err := a.installPublicKey(c, newPath, authKey, nil); err != nil {
		return fmt.Errorf(a.msg("新公钥安装/验证失败；旧 key 完全保留：%w", "New public-key installation/verification failed; the old key remains untouched: %w"), err)
	}
	backupPath := c.KeyPath + ".bak-" + stamp
	if err := os.Rename(c.KeyPath, backupPath); err != nil {
		return fmt.Errorf("new key verified, but local old-key backup failed; both server keys remain authorized: %w", err)
	}
	if err := os.Rename(c.KeyPath+".pub", backupPath+".pub"); err != nil {
		return fmt.Errorf("private key was backed up but public-key backup rename failed: %w", err)
	}
	if err := os.Rename(newPath, c.KeyPath); err != nil {
		return fmt.Errorf("could not activate the verified new private key: %w", err)
	}
	if err := os.Rename(newPath+".pub", c.KeyPath+".pub"); err != nil {
		return fmt.Errorf("could not activate the verified new public key: %w", err)
	}
	if verified := verifyKey(c, c.KeyPath); !verified.OK() {
		return errors.New("the canonical new key failed re-verification; the old key remains in the local .bak and on the server")
	}
	if oldVerified {
		oldPubData, readErr := os.ReadFile(backupPath + ".pub")
		if readErr == nil {
			oldEncoded := base64.StdEncoding.EncodeToString([]byte(strings.TrimSpace(string(oldPubData))))
			remove := "old=$(printf %s " + shQuote(oldEncoded) + " | base64 -d); f=\"$HOME/.ssh/authorized_keys\"; " +
				"tmp=$(mktemp); grep -vxF \"$old\" \"$f\" > \"$tmp\" || true; cat \"$tmp\" > \"$f\"; rm -f \"$tmp\"; chmod 600 \"$f\""
			removed := a.sshCapture(c, remove)
			if !removed.OK() {
				a.println(a.msg("新 key 已启用，但旧公钥未自动移除；这是安全的双钥匙状态，可稍后手工清理。", "The new key is active, but the old public key was not removed. Both remain valid until you clean it up."))
			}
		}
	}
	a.println(a.msg("SSH key 轮换完成；旧私钥本机备份：", "SSH key rotation completed; local old-key backup:") + " " + backupPath)
	return a.showKeyHandoff(c.KeyPath, a.msg("新 SSH 登录密钥（必须保存）", "New SSH login key (save this)"))
}
