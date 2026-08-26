package main

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type SecuritySource struct {
	Name   string
	State  string
	Detail string
}

type SecurityEvent struct {
	Category  string
	IP        string
	Count     int
	LastEpoch int64
	Detail    string
}

type SecurityReport struct {
	Since      string
	Cursor     int
	Limit      int
	Sources    []SecuritySource
	Events     []SecurityEvent
	Total      int
	Returned   int
	Truncated  bool
	NextCursor int
}

var securityTokenPattern = regexp.MustCompile(`^[A-Z0-9_]{2,64}$`)
var securityDetailPattern = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,64}$`)

var allowedSecuritySources = map[string]bool{
	"SSH": true, "FAIL2BAN": true, "FIREWALL": true, "NGINX": true, "CONNECTIONS": true,
}

var allowedSecuritySourceStates = map[string]bool{
	"OK": true, "INFO": true, "PARTIAL": true,
}

var allowedSecurityCategories = map[string]bool{
	"SSH_AUTH_SUCCESS":       true,
	"SSH_AUTH_FAILURE":       true,
	"FAIL2BAN_BANNED":        true,
	"FIREWALL_REJECT":        true,
	"REALITY_NEW_CONNECTION": true,
	"CDN_XHTTP_REQUEST":      true,
	"PRIVATE_DRIVE_REQUEST":  true,
	"ACME_REQUEST":           true,
	"WEB_REQUEST":            true,
	"CURRENT_SSH_CONNECTION": true,
	"CURRENT_443_CONNECTION": true,
}

func parseSecurityFields(fields []string) (map[string]string, error) {
	result := make(map[string]string, len(fields))
	for _, field := range fields {
		parts := strings.SplitN(field, "=", 2)
		if len(parts) != 2 || !securityTokenPattern.MatchString(parts[0]) || strings.ContainsAny(parts[1], "\r\n\t") {
			return nil, fmt.Errorf("invalid security protocol field %q", field)
		}
		if _, exists := result[parts[0]]; exists {
			return nil, fmt.Errorf("duplicate security protocol field %s", parts[0])
		}
		result[parts[0]] = parts[1]
	}
	return result, nil
}

func parseBoundedInt(value, label string, minValue, maxValue int) (int, error) {
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < minValue || parsed > maxValue {
		return 0, fmt.Errorf("invalid %s", label)
	}
	return parsed, nil
}

func parseSecurityReport(stdout string) (SecurityReport, error) {
	var report SecurityReport
	stdout = strings.ReplaceAll(stdout, "__TNA_SECURITY_V1_BEGIN__", "__PNA_SECURITY_V1_BEGIN__")
	stdout = strings.ReplaceAll(stdout, "__TNA_SECURITY_V1_END__", "__PNA_SECURITY_V1_END__")
	normalized := strings.ReplaceAll(stdout, "\r\n", "\n")
	lines := strings.Split(normalized, "\n")
	begin, end := -1, -1
	for index, line := range lines {
		switch line {
		case "__PNA_SECURITY_V1_BEGIN__":
			if begin >= 0 {
				return report, errors.New("duplicate security report begin marker")
			}
			begin = index
		case "__PNA_SECURITY_V1_END__":
			if end >= 0 {
				return report, errors.New("duplicate security report end marker")
			}
			end = index
		}
	}
	if begin < 0 || end <= begin {
		return report, errors.New("security report markers are missing or out of order")
	}
	metaSeen, summarySeen := false, false
	for _, line := range lines[begin+1 : end] {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		switch fields[0] {
		case "META":
			if metaSeen || len(fields) != 4 {
				return report, errors.New("invalid or duplicate security META record")
			}
			values, err := parseSecurityFields(fields[1:])
			if err != nil {
				return report, err
			}
			if values["SINCE"] != "1h" && values["SINCE"] != "6h" && values["SINCE"] != "24h" && values["SINCE"] != "7d" {
				return report, errors.New("invalid security report time range")
			}
			report.Since = values["SINCE"]
			report.Cursor, err = parseBoundedInt(values["CURSOR"], "security cursor", 0, 100000)
			if err != nil {
				return report, err
			}
			report.Limit, err = parseBoundedInt(values["LIMIT"], "security limit", 1, 1000)
			if err != nil {
				return report, err
			}
			metaSeen = true
		case "SOURCE":
			if len(fields) != 4 || !allowedSecuritySources[fields[1]] || !allowedSecuritySourceStates[fields[2]] || !securityDetailPattern.MatchString(fields[3]) {
				return report, errors.New("invalid security SOURCE record")
			}
			report.Sources = append(report.Sources, SecuritySource{Name: fields[1], State: fields[2], Detail: fields[3]})
		case "EVENT":
			if len(fields) != 6 || !allowedSecurityCategories[fields[1]] || net.ParseIP(fields[2]) == nil || !securityDetailPattern.MatchString(fields[5]) {
				return report, errors.New("invalid security EVENT record")
			}
			count, err := parseBoundedInt(fields[3], "security event count", 1, 1000000000)
			if err != nil {
				return report, err
			}
			epoch, err := strconv.ParseInt(fields[4], 10, 64)
			if err != nil || epoch < 0 || epoch > time.Now().Add(48*time.Hour).Unix() {
				return report, errors.New("invalid security event timestamp")
			}
			report.Events = append(report.Events, SecurityEvent{Category: fields[1], IP: fields[2], Count: count, LastEpoch: epoch, Detail: fields[5]})
		case "SUMMARY":
			if summarySeen || len(fields) != 5 {
				return report, errors.New("invalid or duplicate security SUMMARY record")
			}
			values, err := parseSecurityFields(fields[1:])
			if err != nil {
				return report, err
			}
			report.Total, err = parseBoundedInt(values["TOTAL"], "security total", 0, 100000)
			if err != nil {
				return report, err
			}
			report.Returned, err = parseBoundedInt(values["RETURNED"], "security returned", 0, 1000)
			if err != nil {
				return report, err
			}
			switch values["TRUNCATED"] {
			case "0":
				report.Truncated = false
			case "1":
				report.Truncated = true
			default:
				return report, errors.New("invalid security truncation flag")
			}
			if values["NEXT_CURSOR"] != "" {
				report.NextCursor, err = parseBoundedInt(values["NEXT_CURSOR"], "security next cursor", 1, 100000)
				if err != nil {
					return report, err
				}
			}
			summarySeen = true
		default:
			return report, fmt.Errorf("unknown security protocol record %q", fields[0])
		}
	}
	if !metaSeen || !summarySeen || len(report.Sources) != 5 || report.Returned != len(report.Events) {
		return report, errors.New("security report is incomplete or inconsistent")
	}
	if report.Truncated && report.NextCursor <= report.Cursor {
		return report, errors.New("security report next cursor did not advance")
	}
	if !report.Truncated && report.NextCursor != 0 {
		return report, errors.New("untruncated security report unexpectedly contains a next cursor")
	}
	return report, nil
}

func (a *App) printSecurityReport(report SecurityReport) {
	a.println()
	a.println("================ SECURITY EVENTS ================")
	a.println("RANGE=" + report.Since)
	for _, source := range report.Sources {
		a.println(fmt.Sprintf("SOURCE %-12s %-7s %s", source.Name, source.State, source.Detail))
	}
	a.println(a.msg("说明：连接或失败事件不等同于攻击；仅 Fail2ban 当前封禁有明确封禁语义。", "Note: a connection or failure is not automatically an attack; only current Fail2ban bans have explicit ban semantics."))
	for _, event := range report.Events {
		last := "unknown"
		if event.LastEpoch > 0 {
			last = time.Unix(event.LastEpoch, 0).Local().Format(time.RFC3339)
		}
		a.println(fmt.Sprintf("%-28s ip=%-39s count=%d last=%s detail=%s", event.Category, event.IP, event.Count, last, event.Detail))
	}
	if len(report.Events) == 0 {
		a.println(a.msg("所选时间范围内没有聚合事件。请同时检查上面的数据源状态。", "No aggregated events exist in the selected range. Also inspect the source states above."))
	}
	a.println(fmt.Sprintf("TOTAL=%d RETURNED=%d TRUNCATED=%t", report.Total, report.Returned, report.Truncated))
	a.println("=================================================")
}

func (a *App) fetchSecurityEvents(c Connection, since string, cursor int) (SecurityReport, error) {
	command := fmt.Sprintf("bash %s/linux/25-security-events.sh --protocol-v1 --since %s --cursor %d --limit 200", remoteRoot, shQuote(since), cursor)
	result := a.rootCapture(c, command)
	if !result.OK() {
		return SecurityReport{}, fmt.Errorf("security event query failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	report, err := parseSecurityReport(result.Stdout)
	if err != nil {
		return SecurityReport{}, fmt.Errorf("security event protocol rejected: %w", err)
	}
	return report, nil
}

func (a *App) manageSecurityEvents() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	for {
		a.println()
		a.println(a.msg("访问与封禁日志（只取聚合元数据，不新增公网面板）", "Access and ban events (aggregated metadata only; no public panel)"))
		a.println(a.msg("[1] 查看最近 24 小时", "[1] View the last 24 hours"))
		a.println(a.msg("[2] 选择 1h / 6h / 24h / 7d", "[2] Choose 1h / 6h / 24h / 7d"))
		a.println(a.msg("[3] 安装/修复受管 Fail2ban sshd jail 与限速连接元数据规则", "[3] Install/repair the managed Fail2ban sshd jail and rate-limited connection metadata rule"))
		a.println(a.msg("[4] 查看安全基线状态", "[4] Inspect security-baseline status"))
		a.println(a.msg("[5] 设置安全日志保留天数（1-30）", "[5] Set security-log retention (1-30 days)"))
		a.println(a.msg("[0] 返回", "[0] Back"))
		choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
		if a.inputClosed {
			return errInputClosed
		}
		since := "24h"
		switch choice {
		case "1":
		case "2":
			since = strings.ToLower(strings.TrimSpace(a.prompt(a.msg("时间范围 [1h/6h/24h/7d]（默认 24h）", "Range [1h/6h/24h/7d] (default 24h)"))))
			if since == "" {
				since = "24h"
			}
			if since != "1h" && since != "6h" && since != "24h" && since != "7d" {
				a.println(a.msg("时间范围无效。", "Invalid range."))
				continue
			}
		case "3":
			if !a.yes(a.msg("应用受管 sshd jail（5 次/10 分钟，封禁 1 小时）并启用隐私化连接元数据？", "Apply the managed sshd jail (5 attempts/10 minutes, 1-hour ban) and privacy-preserving connection metadata?"), false) {
				continue
			}
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/24-security-baseline.sh --apply 7")
			if !result.OK() || !strings.Contains(result.Stdout, "TNA_SECURITY_BASELINE_APPLIED") {
				return fmt.Errorf("security baseline apply failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
			continue
		case "4":
			result := a.rootCapture(c, "bash "+remoteRoot+"/linux/24-security-baseline.sh --status")
			if !result.OK() || !strings.Contains(result.Stdout, "TNA_SECURITY_BASELINE_STATUS_END") {
				return fmt.Errorf("security baseline status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
			continue
		case "5":
			value := strings.TrimSpace(a.prompt(a.msg("保留天数 [1-30]", "Retention days [1-30]")))
			days, parseErr := strconv.Atoi(value)
			if parseErr != nil || days < 1 || days > 30 {
				a.println(a.msg("保留天数无效。", "Invalid retention."))
				continue
			}
			result := a.rootCapture(c, fmt.Sprintf("bash %s/linux/24-security-baseline.sh --apply %d", remoteRoot, days))
			if !result.OK() || !strings.Contains(result.Stdout, "RETENTION_DAYS="+strconv.Itoa(days)) {
				return fmt.Errorf("security retention update failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
			}
			a.println(strings.TrimSpace(result.Stdout))
			continue
		case "0", "":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid selection."))
			continue
		}

		cursor := 0
		for {
			report, fetchErr := a.fetchSecurityEvents(c, since, cursor)
			if fetchErr != nil {
				return fetchErr
			}
			a.printSecurityReport(report)
			if !report.Truncated || !a.yes(a.msg("还有更多聚合事件，读取下一页？", "More aggregated events are available. Fetch the next page?"), false) {
				break
			}
			cursor = report.NextCursor
		}
	}
}
