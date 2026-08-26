package main

import (
	"archive/tar"
	"compress/gzip"
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
	if probe.Accepted() {
		a.println("DNS_RESOLVER_QUORUM " + probe.Summary())
		a.println(a.msg("DNS 已经指向这台 VPS。", "DNS already points to this VPS."))
		return true
	}
	a.println("DNS_RESOLVER_QUORUM " + probe.Summary())
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

func (a *App) deployOptimize() (returnErr error) {
	c, err := a.readyConn()
	if err != nil {
		return fmt.Errorf(a.msg("SSH 初始化失败：%w", "SSH setup failed: %w"), err)
	}
	probe, err := a.remoteToolkitProbe(c)
	if err != nil {
		return fmt.Errorf(a.msg("远端工具包版本检测失败：%w。没有上传任何东西。", "Remote toolkit version detection failed: %w. Nothing was uploaded."), err)
	}
	relation, err := classifyToolkit(probe, toolkitVersion)
	if err != nil {
		return fmt.Errorf(a.msg("远端工具包版本无法安全识别：%w。没有上传任何东西。", "The remote toolkit version could not be safely classified: %w. Nothing was uploaded."), err)
	}
	updateSameVersionBuild := false
	repairSameVersionToolkit := false
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
		repairSameVersionToolkit = true
		a.println(fmt.Sprintf(a.msg(
			"检测到同版本 v%s 工具包不完整；菜单 [1] 将原位修复工具程序，不会重装节点，也不会改动网盘数据、账号、设备准入或现有配置。",
			"The v%s toolkit is incomplete; menu [1] will repair the program files in place without reinstalling the node or changing drive data, accounts, device admission, or existing configuration.",
		), toolkitVersion))
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
	if relation == ToolkitOlder || relation == ToolkitMissing || updateSameVersionBuild || repairSameVersionToolkit {
		if err := a.uploadToolkit(c); err != nil {
			return fmt.Errorf(a.msg("工具包按需安装/升级失败：%w", "On-demand toolkit install/upgrade failed: %w"), err)
		}
	}
	if err := a.recoverInterruptedInstallTransaction(c); err != nil {
		return err
	}
	if err := a.captureOriginalBaselineBeforeConstruction(c); err != nil {
		return fmt.Errorf(a.msg("施工前原生基线准备失败：%w", "Pre-construction baseline preparation failed: %w"), err)
	}
	if err := a.ensureInstallNodeIdentity(c, relation, probe); err != nil {
		return fmt.Errorf(a.msg("菜单 [1] 的稳定节点身份准备失败：%w", "Menu [1] stable-node identity preparation failed: %w"), err)
	}
	if err := a.syncManagedKeyIdentity(c); err != nil {
		return fmt.Errorf(a.msg("稳定节点身份同步失败：%w", "Stable node identity synchronization failed: %w"), err)
	}
	preservedDrive, err := a.inspectInstallRecoveryState(c)
	if err != nil {
		return err
	}
	topology, inputErr := a.chooseTopologyPlan(c)
	if inputErr != nil {
		return inputErr
	}
	domain, email := topology.baseDomainEmail()
	coverTemplate, templateErr := a.chooseCoverTemplate(c)
	if templateErr != nil {
		return templateErr
	}
	publicIP, err := a.remotePublicIP(c)
	if err != nil {
		return err
	}
	if topology.Mode == topologyOrange {
		if !a.waitForOrangeDNS(domain, publicIP) {
			return errors.New(a.msg("已在橙云证书/代理施工前停止。", "Stopped before orange-cloud certificate/proxy work."))
		}
	} else if !a.waitForDNS(domain, publicIP) {
		return errors.New(a.msg("已在证书/REALITY 施工前停止。", "Stopped before certificate/REALITY work."))
	}
	if topology.Mode == topologyDual && !a.waitForOrangeDNS(topology.OrangeDomain, publicIP) {
		return errors.New(a.msg("已在双路橙云影子施工前停止。", "Stopped before the dual-route orange shadow was staged."))
	}
	if topology.Mode == topologyOrange || topology.Mode == topologyDual {
		if err := a.guideCloudflareOriginCertificatePrerequisites(topology.OrangeDomain); err != nil {
			return err
		}
	}
	if err := a.writeAutoInput(c, domain, email); err != nil {
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
		rollbackErr := a.rollbackInstallTransaction(c, transactionID)
		if rollbackErr == nil {
			return
		}
		if returnErr == nil {
			returnErr = rollbackErr
		} else {
			returnErr = fmt.Errorf("%v; automatic install rollback also failed: %w", returnErr, rollbackErr)
		}
	}()
	driveHandoff, err := a.prepareMandatoryDrive(c)
	if err != nil {
		return err
	}
	a.println(a.msg("开始自适应施工。推荐的安全/幂等项自动采用默认值；24443 真机验货仍会强制确认。", "Starting adaptive convergence. Safe/idempotent recommendations use defaults; real 24443 verification still requires confirmation."))
	remoteGUIMode := "0"
	if guiModeEnabled() {
		remoteGUIMode = "1"
	}
	command := "TNA_LOGIN_USER=" + shQuote(c.User) +
		" TNA_SSH_KEY_INSTALLED=1 TNA_ASSUME_DEFAULTS=1" +
		" TNA_GUI_MODE=" + shQuote(remoteGUIMode) +
		" TNA_LANG=" + shQuote(string(a.lang)) +
		" TNA_TOPOLOGY_MODE=" + shQuote(map[topologyMode]string{topologyGray: "gray", topologyOrange: "orange", topologyDual: "dual"}[topology.Mode]) +
		" TNA_COVER_TEMPLATE=" + shQuote(coverTemplate) +
		" TNA_AUTO_INPUT=/tmp/text-node-assistant-auto-input" +
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
	if topology.Mode == topologyOrange || topology.Mode == topologyDual {
		if err := a.promoteCDNPublicOriginForTopology(c, topology.OrangeDomain, topology.OrangeEmail, topology.Mode); err != nil {
			return err
		}
		if err := a.guideCloudflareOrangeSetup(topology.OrangeDomain); err != nil {
			return err
		}
		if err := a.validateCDNEdgeForTopology(c, topology.OrangeDomain, topology.Mode); err != nil {
			return err
		}
		if err := a.confirmCDNRealClientForTopology(c, topology.OrangeDomain, topology.Mode); err != nil {
			return err
		}
		commit := a.rootCapture(c, "grep -Fqx 'CDN_REAL_CLIENT_CONFIRMED=1' /etc/text-node-assistant/cloudflare/edge-state.env")
		if !commit.OK() {
			return errors.New(a.msg("真机浏览尚未确认；橙云拓扑没有提交，强制网盘普通注册也继续保持关闭。", "Real-device browsing was not confirmed; the orange topology was not committed and ordinary drive registration remains disabled."))
		}
	}
	if err := a.reconcileTopologyPlan(c, topology); err != nil {
		return err
	}
	if err := a.finalizeMandatoryDrive(c, topology.lifecycle()); err != nil {
		return err
	}
	if err := a.verifyPreservedDriveIdentity(c, preservedDrive); err != nil {
		return fmt.Errorf(a.msg("仅拆代理后的保留对象验收失败：%w", "Preserved-object verification after proxy-only removal failed: %w"), err)
	}
	if err := a.ensureCurrentControllerAfterInstall(c); err != nil {
		return fmt.Errorf(a.msg("首个 controller 交付未完成：%w", "First-controller delivery did not complete: %w"), err)
	}
	driveHandoff, err = a.ensureLocalDriveAdminCapability(c, driveHandoff)
	if err != nil {
		return fmt.Errorf(a.msg("本机 admin 空间能力交付未完成：%w", "Local admin-space capability delivery did not complete: %w"), err)
	}

	handoff, handoffErr := a.fetchHandoff(c)
	if handoffErr != nil {
		return fmt.Errorf(a.msg("施工阶段完成，但强制交接单未通过完整性校验；本次不会提交半交付状态：%w", "Construction stages completed, but the mandatory handoff failed integrity validation; a partially delivered state will not be committed: %w"), handoffErr)
	}
	completeHandoff, completeErr := a.buildCompleteHandoff(handoff, c)
	if completeErr != nil {
		return fmt.Errorf(a.msg("完整交接单追加块生成失败：%w", "complete handoff appendix failed: %w"), completeErr)
	}
	if driveHandoff != "" {
		completeHandoff += "\n\n" + driveHandoff
	}
	if err := a.secretHandoff("CREDENTIAL HANDOFF", completeHandoff); err != nil {
		a.println(err.Error())
	}
	if err := a.commitInstallTransaction(c, transactionID); err != nil {
		return err
	}
	transactionActive = false
	if a.yes(a.msg(
		"是否在打开面板前整理远端多余备份，并只保留一份新验证的当前配置备份？",
		"Before opening the panel, prune redundant remote backups and retain one newly verified current-config backup?",
	), false) {
		if err := a.pruneBackupsAndBackupCurrentConfigWithConn(c, false); err != nil {
			return fmt.Errorf(a.msg("远端备份整理失败；为避免继续连锁操作，本次不打开面板：%w", "Remote backup cleanup failed; the panel will not be opened to avoid chained actions: %w"), err)
		}
	} else {
		a.println(a.msg("已跳过远端备份整理；现有备份保持不动。", "Remote backup cleanup was skipped; existing backups were left unchanged."))
	}
	if a.yes(a.msg("现在无感打开 3x-ui 面板？", "Open the 3x-ui panel seamlessly now?"), true) {
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
		"此操作只卸载 TextNodeAssistant 上传的远端工具包程序。",
		"This removes only the remote toolkit program uploaded by TextNodeAssistant.",
	))
	a.println(a.msg(
		"会删除：/opt 下已知 v0.5—v0.9.5 工具包、proxy-runbook-current、proxy-node 命令和 /tmp 上传残留。",
		"It removes: known v0.5-v0.9.5 toolkit directories under /opt, proxy-runbook-current, the proxy-node command, and /tmp upload remnants.",
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
	if !strings.Contains(result.Stdout, "TNA_TOOLKIT_UNINSTALL_BEGIN\n") || !strings.Contains(result.Stdout, "TNA_TOOLKIT_UNINSTALL_END") {
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
	downloadDir := filepath.Join(home, "Downloads", "TextNodeAssistant-Rescue")
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

type dismantleRescueStats struct {
	DriveRootSeen bool
	DriveFiles    int64
	DriveBytes    int64
}

func verifyDismantleRescueContents(localPath string, requireDrive bool, expectedFiles, expectedBytes int64) (dismantleRescueStats, error) {
	input, err := os.Open(localPath)
	if err != nil {
		return dismantleRescueStats{}, err
	}
	defer input.Close()
	gzipReader, err := gzip.NewReader(input)
	if err != nil {
		return dismantleRescueStats{}, fmt.Errorf("rescue gzip validation failed: %w", err)
	}
	defer gzipReader.Close()
	tarReader := tar.NewReader(gzipReader)
	stats := dismantleRescueStats{}
	entries := int64(0)
	const driveSegment = "/files/srv/text-node-assistant/drive-data"
	for {
		header, nextErr := tarReader.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return dismantleRescueStats{}, fmt.Errorf("rescue tar validation failed: %w", nextErr)
		}
		entries++
		name := "/" + strings.TrimPrefix(filepath.ToSlash(header.Name), "/")
		index := strings.Index(name, driveSegment)
		if index < 0 {
			continue
		}
		remainder := strings.TrimPrefix(name[index+len(driveSegment):], "/")
		stats.DriveRootSeen = true
		if remainder != "" && (header.Typeflag == tar.TypeReg || header.Typeflag == tar.TypeRegA) {
			stats.DriveFiles++
			stats.DriveBytes += header.Size
		}
	}
	if entries == 0 {
		return dismantleRescueStats{}, errors.New("rescue archive contains no entries")
	}
	if requireDrive {
		if !stats.DriveRootSeen {
			return dismantleRescueStats{}, errors.New("rescue archive is missing the mandatory drive-data root")
		}
		if stats.DriveFiles != expectedFiles || stats.DriveBytes != expectedBytes {
			return dismantleRescueStats{}, fmt.Errorf("drive-data inventory mismatch: archive files=%d bytes=%d, remote plan files=%d bytes=%d", stats.DriveFiles, stats.DriveBytes, expectedFiles, expectedBytes)
		}
	}
	return stats, nil
}

func (a *App) dismantleManagedNode() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	identity, err := a.fetchNodeIdentity(c)
	if err != nil {
		return fmt.Errorf(a.msg("无法读取稳定 NODE_ID；为避免全拆后失去节点归属证据，本次拒绝拆除：%w", "The stable NODE_ID could not be read. Dismantling is blocked so node-ownership evidence is not lost after a full restore: %w"), err)
	}
	if err := a.requireLocalAdminReauthentication(
		"“拆除施工和恢复基线”属于高风险操作，必须再次验证本机 admin；密码只在本机校验。",
		"Dismantling and baseline restore is high risk and requires local-admin reauthentication; the password is verified only on this device.",
	); err != nil {
		return err
	}
	statusResult := a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --status")
	if !statusResult.OK() || !strings.Contains(statusResult.Stdout, "TNA_DISMANTLE_STATUS_BEGIN") || !strings.Contains(statusResult.Stdout, "TNA_DISMANTLE_STATUS_END") {
		return fmt.Errorf("dismantle status failed (exit %d): %s", statusResult.ExitCode, processFailureDetail(statusResult))
	}
	status := parseKV(statusResult.Stdout)
	legal := status["LEGAL_ACTIONS"]
	var mode, planArg, executeArg, exactConfirmation string
	switch legal {
	case "PROXY_ONLY,FULL_BASELINE":
		a.println(a.msg("当前检测到：代理施工和强制网盘均存在。此状态禁止单独拆网盘。", "Detected: both the managed proxy and mandatory drive are present. Drive-only removal is forbidden in this state."))
		a.println(a.msg("[1] 仅拆除代理施工（保留网盘、文件、账号、设备、SSH 和工具包）", "[1] Remove only the managed proxy (preserve drive, files, accounts, devices, SSH, and toolkit)"))
		a.println(a.msg("[2] 整体拆除全部 TNA 施工并恢复原始基线", "[2] Remove all TNA construction and restore the original baseline"))
		a.println(a.msg("[0] 取消", "[0] Cancel"))
		switch strings.TrimSpace(a.prompt(a.msg("请选择拆除模式", "Choose a removal mode"))) {
		case "1":
			mode, planArg, executeArg, exactConfirmation = "PROXY_ONLY", "proxy-only", "--execute-proxy-only", "REMOVE PROXY KEEP DRIVE"
		case "2":
			mode, planArg, executeArg, exactConfirmation = "FULL_BASELINE", "full", "--execute-full", "RESTORE ORIGINAL"
		default:
			a.println(a.msg("已取消；远端未修改。", "Cancelled; the remote was not changed."))
			return nil
		}
	case "REMAINING_DRIVE":
		a.println(a.msg("当前检测到：代理已完整拆除，仅保留强制网盘。", "Detected: the proxy has been fully removed and only the mandatory drive remains."))
		a.println(a.msg("[1] 拆除剩余网盘和 TNA 管理施工，恢复原始基线", "[1] Remove the remaining drive and TNA management layer, then restore the original baseline"))
		a.println(a.msg("[0] 取消", "[0] Cancel"))
		if strings.TrimSpace(a.prompt(a.msg("请选择", "Choose"))) != "1" {
			a.println(a.msg("已取消；远端未修改。", "Cancelled; the remote was not changed."))
			return nil
		}
		mode, planArg, executeArg, exactConfirmation = "REMAINING_DRIVE", "remaining-drive", "--execute-remaining-drive", "RESTORE ORIGINAL"
	case "NONE":
		a.println(a.msg("没有检测到 TNA 受管施工；没有可执行的拆除动作。", "No TNA-managed construction was detected; there is nothing to dismantle."))
		return nil
	case "RECOVER_IN_MENU_1":
		return errors.New(a.msg("检测到拆除中断或受管组件漂移；请先运行菜单 [1]，由唯一安装入口生成并执行恢复计划。", "An interrupted removal or managed-component drift was detected. Run menu [1] first so the only install entry can build and execute a recovery plan."))
	default:
		return fmt.Errorf("unsupported dismantle state: lifecycle=%s proxy=%s drive=%s legal=%s", status["NODE_LIFECYCLE_STATE"], status["PROXY_PRESENT"], status["DRIVE_PRESENT"], legal)
	}

	plan := a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --plan "+shQuote(planArg))
	if !plan.OK() {
		return fmt.Errorf("dismantle plan failed (exit %d): %s", plan.ExitCode, processFailureDetail(plan))
	}
	if !strings.Contains(plan.Stdout, "TNA_DISMANTLE_PLAN_BEGIN\n") || !strings.Contains(plan.Stdout, "TNA_DISMANTLE_PLAN_END") {
		return errors.New(a.msg("远端没有返回完整拆除计划；拒绝继续。", "The remote did not return a complete dismantle plan; refusing to continue."))
	}
	a.println(strings.TrimSpace(plan.Stdout))
	if mode == "PROXY_ONLY" {
		a.println(a.msg("本操作只撤销代理线路；网盘服务、全部文件、空间 ID、普通账号、加密托管、受信设备、SSH 和工具包必须原样保留。", "This removes only the proxy routes. The drive service, every file, space IDs, ordinary accounts, encrypted escrow, trusted devices, SSH, and toolkit must remain unchanged."))
	} else {
		a.println(fmt.Sprintf(a.msg("整体拆除会永久删除 VPS 上的网盘文件卷：%s（文件 %s 个，合计 %s 字节）。程序会先把完整救援包下载到 Windows 并逐项复核。", "Full removal permanently deletes the VPS drive volume %s (%s files, %s bytes). A full rescue is downloaded to Windows and independently checked first."), planArgValue(plan.Stdout, "DRIVE_DATA_ROOT"), planArgValue(plan.Stdout, "DRIVE_FILE_COUNT"), planArgValue(plan.Stdout, "DRIVE_DATA_BYTES")))
	}
	confirmation := strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("确认继续请输入大写 %s", "Type uppercase %s to continue"), exactConfirmation)))
	if confirmation != exactConfirmation {
		a.println(a.msg("已取消；没有创建备份或修改远端。", "Cancelled; no backup was created and the remote was not changed."))
		return nil
	}
	legacy := strings.Contains(plan.Stdout, "RESTORE_GRADE=LEGACY_UNCERTAIN")
	if legacy {
		legacyPhrase := "LEGACY FULL RESTORE"
		if mode == "PROXY_ONLY" {
			legacyPhrase = "LEGACY PROXY ONLY"
			a.println(a.msg("该旧节点缺少施工前逐文件基线；仅拆代理将只删除有 TNA 归属证据的资源，并保留无法证明归属的共享配置。", "This legacy node lacks a file-level pre-install baseline. Proxy-only removal deletes only resources with TNA ownership evidence and preserves ambiguous shared configuration."))
		} else {
			a.println(a.msg("该节点由旧版施工，缺少施工前基线；只能执行有边界的 legacy 全拆，不能声称逐字节还原。", "This node was built by an older release and has no pre-install baseline. Only bounded legacy full removal is possible; byte-for-byte restoration cannot be claimed."))
		}
		legacyConfirmation := strings.TrimSpace(a.prompt(fmt.Sprintf(a.msg("接受该限制请输入大写 %s", "Type uppercase %s to accept this limitation"), legacyPhrase)))
		if legacyConfirmation != legacyPhrase {
			a.println(a.msg("已取消；远端保持不变。", "Cancelled; the remote was left unchanged."))
			return nil
		}
	}

	backupMode := "--config-only"
	if mode != "PROXY_ONLY" {
		backupMode = "--full"
	}
	a.println(a.msg("正在创建拆除前救援包…", "Creating the pre-dismantle rescue archive..."))
	backup := a.rootCapture(c, "bash "+remoteRoot+"/linux/01-safe-backup.sh "+backupMode)
	if !backup.OK() || !strings.Contains(backup.Stdout, "BACKUP_OK\n") {
		return fmt.Errorf("pre-dismantle backup failed (exit %d): %s", backup.ExitCode, processFailureDetail(backup))
	}
	archivePattern := regexp.MustCompile(`/root/text-node(?:-config)?-backup-[0-9]{8}-[0-9]{6}\.tar\.gz`)
	remoteArchive := archivePattern.FindString(backup.Stdout)
	if remoteArchive == "" {
		return errors.New(a.msg("备份返回成功，但没有识别到安全归档路径；拒绝拆除。", "The backup reported success but no safe archive path was recognized; refusing to dismantle."))
	}
	localArchive, err := a.downloadDismantleRescue(c, remoteArchive)
	if err != nil {
		return fmt.Errorf(a.msg("救援包未能下载并通过 SHA-256 校验；拒绝拆除：%w", "The rescue archive could not be downloaded and SHA-256 verified; refusing to dismantle: %w"), err)
	}
	expectedFiles, filesErr := strconv.ParseInt(planArgValue(plan.Stdout, "DRIVE_FILE_COUNT"), 10, 64)
	expectedBytes, bytesErr := strconv.ParseInt(planArgValue(plan.Stdout, "DRIVE_DATA_BYTES"), 10, 64)
	if filesErr != nil || bytesErr != nil || expectedFiles < 0 || expectedBytes < 0 {
		return fmt.Errorf("dismantle plan returned an invalid drive inventory; rescue=%s", localArchive)
	}
	archiveStats, err := verifyDismantleRescueContents(localArchive, mode != "PROXY_ONLY", expectedFiles, expectedBytes)
	if err != nil {
		return fmt.Errorf(a.msg("救援包内容复核失败；拒绝拆除，文件保留在 %s：%w", "Rescue-content verification failed; dismantling is blocked and the archive remains at %s: %w"), localArchive, err)
	}
	rescueSHA, err := fileSHA256(localArchive)
	if err != nil {
		return fmt.Errorf("local rescue checksum readback failed: %w", err)
	}
	rescueInfo, err := os.Stat(localArchive)
	if err != nil || rescueInfo.Size() < 1 {
		return fmt.Errorf("local rescue file metadata readback failed: %w", err)
	}
	a.println(fmt.Sprintf(a.msg("救援包已通过 SHA-256 和内容清单校验：%s（网盘文件 %d 个、%d 字节）", "The rescue passed SHA-256 and content-inventory checks: %s (drive files=%d, bytes=%d)"), localArchive, archiveStats.DriveFiles, archiveStats.DriveBytes))

	command := "TNA_DISMANTLE_CONFIRM=" + shQuote(strings.ReplaceAll(exactConfirmation, " ", "_"))
	if mode == "PROXY_ONLY" {
		command = "TNA_DISMANTLE_CONFIRM=REMOVE_PROXY_KEEP_DRIVE"
	} else {
		command = "TNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL TNA_DATA_EXPORT_VERIFIED=1"
	}
	if legacy {
		command += " TNA_LEGACY_FULL=1"
	}
	command += " bash " + remoteRoot + "/linux/22-dismantle-managed-node.sh " + executeArg
	result := a.runRootInteractive(c, command)
	if !result.OK() {
		return fmt.Errorf(a.msg("远端拆除失败（状态 %d）；Windows 救援包保留在 %s：%s", "Remote dismantling failed (exit %d); the Windows rescue remains at %s: %s"), result.ExitCode, localArchive, processFailureDetail(result))
	}
	for _, marker := range []string{"TNA_DISMANTLE_BEGIN", "SSH_ACCESS_PRESERVED=1", "PRESERVED_SHARED_BASE_PACKAGES=1", "TNA_DISMANTLE_END"} {
		if !strings.Contains(result.Stdout, marker) {
			return fmt.Errorf("remote dismantle returned success but marker %s is missing; rescue=%s", marker, localArchive)
		}
	}
	verifyCommand := "set -e; test ! -e /opt/text-node-assistant-current; test ! -e /etc/text-node-assistant; test ! -e /root/.config/text-node-assistant; printf 'TNA_POST_DISMANTLE_VERIFY_OK\\n'"
	if mode == "PROXY_ONLY" {
		verifyCommand = "set -e; out=$(bash " + remoteRoot + "/linux/22-dismantle-managed-node.sh --status); printf '%s\\n' \"$out\"; grep -Fqx 'PROXY_PRESENT=0' <<<\"$out\"; grep -Fqx 'DRIVE_PRESENT=1' <<<\"$out\"; grep -Fqx 'NODE_LIFECYCLE_STATE=PROXY_REMOVED_DRIVE_RETAINED' <<<\"$out\"; systemctl is-active --quiet text-node-assistant-copyparty; printf 'TNA_POST_DISMANTLE_VERIFY_OK\\n'"
	}
	verify := a.rootCapture(c, verifyCommand)
	verified := verify.OK() && strings.Contains(verify.Stdout, "TNA_POST_DISMANTLE_VERIFY_OK")
	receipt := newDismantleReceipt(identity, c, mode, plan.Stdout, result.Stdout, localArchive, rescueSHA, rescueInfo.Size(), archiveStats.DriveFiles, archiveStats.DriveBytes, verified)
	receiptPath, receiptErr := writeDismantleReceipt(receipt)
	if !verified {
		if receiptErr != nil {
			return fmt.Errorf(a.msg("拆除脚本已结束，但独立复核和本地失败回执写入均失败；救援包位于 %s；回执错误：%v", "The dismantle script ended, but independent verification and the local failure receipt both failed; rescue archive: %s; receipt error: %v"), localArchive, receiptErr)
		}
		return fmt.Errorf(a.msg("拆除脚本已结束，但独立复核失败；救援包位于 %s；失败回执位于 %s", "The dismantle script ended, but independent verification failed; rescue archive: %s; failure receipt: %s"), localArchive, receiptPath)
	}
	if receiptErr != nil {
		return fmt.Errorf(a.msg("远端拆除及独立复核均已完成，但本机结构化回执写入失败；救援包位于 %s：%w", "Remote dismantling and independent verification completed, but the local structured receipt could not be written; rescue archive: %s: %w"), localArchive, receiptErr)
	}
	if mode == "PROXY_ONLY" {
		a.println(a.msg("仅代理拆除完成并独立复核通过：网盘、文件、账号、设备和 SSH 保留；普通注册已关闭。需要恢复代理时只运行菜单 [1]。", "Proxy-only removal completed and passed independent verification: drive, files, accounts, devices, and SSH were preserved; ordinary registration is disabled. Use menu [1] to restore a proxy."))
	} else {
		a.println(a.msg("整体拆除完成并独立复核通过。SSH 恢复能力和本地救援包保留；重新施工只能运行菜单 [1]。", "Full dismantling completed and passed independent verification. SSH recovery access and the local rescue archive were preserved; use menu [1] as the only reinstall entry."))
	}
	a.println(a.msg("本地救援包：", "Local rescue archive:") + " " + localArchive)
	a.println(a.msg("本地拆除回执（不含秘密）：", "Local dismantle receipt (secret-free):") + " " + receiptPath)
	return nil
}

func planArgValue(output, key string) string {
	return parseKV(output)[key]
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
		kv := parseKV(handoff)
		if kv["PANEL_USERNAME"] != "" {
			a.println("PANEL_USERNAME=" + kv["PANEL_USERNAME"])
		}
		if kv["PANEL_PASSWORD"] != "" {
			if copyClipboard(kv["PANEL_PASSWORD"]) == nil {
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
	complete, err := a.buildCompleteHandoff(handoff, c)
	if err != nil {
		return err
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", complete)
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
	complete, err := a.buildCompleteHandoff(handoff, c)
	if err != nil {
		return err
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", complete)
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
	complete, err := a.buildCompleteHandoff(handoff, c)
	if err != nil {
		return err
	}
	return a.secretHandoff("CREDENTIAL HANDOFF", complete)
}

func (a *App) runtimePublicEnv(c Connection) (map[string]string, error) {
	result := a.rootCapture(c, "cat /etc/text-node-assistant/public.env 2>/dev/null || true")
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
	custom := a.rootCapture(c, "if [ -f /var/www/cover/index.html ] && [ ! -f /var/www/cover/.text-node-assistant-cover ] && ! grep -qE 'This site is online|<h1>Welcome</h1>' /var/www/cover/index.html; then printf YES; else printf NO; fi")
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
	archivePattern := regexp.MustCompile(`/root/text-node-current-config-[0-9]{8}-[0-9]{6}\.tar\.gz`)
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
	tmpPath := "/tmp/text-node-assistant-report-" + stamp + ".txt"
	prepare := "cp " + shQuote(remotePath) + " " + shQuote(tmpPath) + "; chown " + shQuote(c.User) + " " + shQuote(tmpPath) + "; chmod 600 " + shQuote(tmpPath)
	prepared := a.rootCapture(c, prepare)
	if !prepared.OK() {
		return fmt.Errorf("could not prepare a downloadable copy (exit %d): %s", prepared.ExitCode, processFailureDetail(prepared))
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	downloadDir := filepath.Join(home, "Downloads", "TextNodeAssistant-Reports")
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
	if err := generateKey(newPath, "text-node-assistant-rotated"); err != nil {
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
