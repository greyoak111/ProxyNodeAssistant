package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	trafficWarningNotice   = 70.0
	trafficWarningWarning  = 85.0
	trafficWarningCritical = 95.0
	kiwiVMDefaultEndpoint  = "https://api.64clouds.com/v1/getServiceInfo"
)

type TrafficProfile struct {
	ID               string    `json:"id"`
	Provider         string    `json:"provider"`
	Label            string    `json:"label"`
	Host             string    `json:"host,omitempty"`
	User             string    `json:"user,omitempty"`
	Port             int       `json:"port,omitempty"`
	AccountID        string    `json:"accountId,omitempty"`
	Endpoint         string    `json:"endpoint,omitempty"`
	QuotaBytes       uint64    `json:"quotaBytes,omitempty"`
	ResetDay         int       `json:"resetDay,omitempty"`
	CredentialTarget string    `json:"credentialTarget,omitempty"`
	LastCheckedUTC   time.Time `json:"lastCheckedUtc,omitempty"`
}

type TrafficStore struct {
	Profiles []TrafficProfile `json:"profiles"`
}

type TrafficSnapshot struct {
	Source     string
	UsedBytes  uint64
	QuotaBytes uint64
	RXBytes    uint64
	TXBytes    uint64
	ResetAt    time.Time
	Estimated  bool
	Detail     string
}

func trafficStorePath() (string, error) {
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(base, "ProxyNodeAssistant", "traffic-profiles.json"), nil
}

func loadTrafficStore() (TrafficStore, error) {
	path, err := trafficStorePath()
	if err != nil {
		return TrafficStore{}, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return TrafficStore{}, nil
	}
	if err != nil {
		return TrafficStore{}, err
	}
	var store TrafficStore
	if err := json.Unmarshal(data, &store); err != nil {
		return TrafficStore{}, fmt.Errorf("traffic profile file is invalid: %w", err)
	}
	return store, nil
}

func saveTrafficStore(store TrafficStore) error {
	path, err := trafficStorePath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	sort.SliceStable(store.Profiles, func(i, j int) bool {
		return strings.ToLower(store.Profiles[i].Label) < strings.ToLower(store.Profiles[j].Label)
	})
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

var trafficIDPattern = regexp.MustCompile(`[^a-z0-9._-]+`)

func normalizeTrafficID(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = trafficIDPattern.ReplaceAllString(value, "-")
	value = strings.Trim(value, "-._")
	if len(value) > 64 {
		value = value[:64]
	}
	return value
}

func providerCredentialTarget(provider, id string) string {
	return "ProxyNodeAssistant/traffic/" + normalizeTrafficID(provider) + "/" + normalizeTrafficID(id)
}

func upsertTrafficProfile(store *TrafficStore, profile TrafficProfile) {
	for index := range store.Profiles {
		if store.Profiles[index].ID == profile.ID && store.Profiles[index].Provider == profile.Provider {
			store.Profiles[index] = profile
			return
		}
	}
	store.Profiles = append(store.Profiles, profile)
}

func removeTrafficProfile(store *TrafficStore, provider, id string) bool {
	for index := range store.Profiles {
		if store.Profiles[index].Provider == provider && store.Profiles[index].ID == id {
			store.Profiles = append(store.Profiles[:index], store.Profiles[index+1:]...)
			return true
		}
	}
	return false
}

func validProviderEndpoint(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return "", errors.New("provider API endpoint must be an absolute HTTPS URL")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("provider API endpoint must not contain credentials, query parameters, or fragments")
	}
	return parsed.String(), nil
}

func jsonNumber(value interface{}) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, typed >= 0
	case json.Number:
		parsed, err := typed.Float64()
		return parsed, err == nil && parsed >= 0
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(typed), 64)
		return parsed, err == nil && parsed >= 0
	default:
		return 0, false
	}
}

func findJSONNumber(value interface{}, names ...string) (float64, bool) {
	wanted := make(map[string]bool, len(names))
	for _, name := range names {
		wanted[strings.ToLower(name)] = true
	}
	var walk func(interface{}) (float64, bool)
	walk = func(current interface{}) (float64, bool) {
		switch typed := current.(type) {
		case map[string]interface{}:
			for key, child := range typed {
				if wanted[strings.ToLower(key)] {
					if number, ok := jsonNumber(child); ok {
						return number, true
					}
				}
			}
			for _, child := range typed {
				if number, ok := walk(child); ok {
					return number, true
				}
			}
		case []interface{}:
			for _, child := range typed {
				if number, ok := walk(child); ok {
					return number, true
				}
			}
		}
		return 0, false
	}
	return walk(value)
}

func findJSONString(value interface{}, names ...string) (string, bool) {
	wanted := make(map[string]bool, len(names))
	for _, name := range names {
		wanted[strings.ToLower(name)] = true
	}
	var walk func(interface{}) (string, bool)
	walk = func(current interface{}) (string, bool) {
		switch typed := current.(type) {
		case map[string]interface{}:
			for key, child := range typed {
				if wanted[strings.ToLower(key)] {
					if text, ok := child.(string); ok && strings.TrimSpace(text) != "" {
						return strings.TrimSpace(text), true
					}
				}
			}
			for _, child := range typed {
				if text, ok := walk(child); ok {
					return text, true
				}
			}
		case []interface{}:
			for _, child := range typed {
				if text, ok := walk(child); ok {
					return text, true
				}
			}
		}
		return "", false
	}
	return walk(value)
}

func boundedHTTPJSON(request *http.Request) (interface{}, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nil, errors.New("provider API request failed before a response was received")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("provider API returned HTTP %d", response.StatusCode)
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	decoder.UseNumber()
	var payload interface{}
	if err := decoder.Decode(&payload); err != nil {
		return nil, errors.New("provider API returned invalid JSON")
	}
	return payload, nil
}

func fetchKiwiVMTraffic(profile TrafficProfile, apiKey string) (TrafficSnapshot, error) {
	endpoint, err := validProviderEndpoint(profile.Endpoint)
	if err != nil {
		return TrafficSnapshot{}, err
	}
	parsed, _ := url.Parse(endpoint)
	query := parsed.Query()
	query.Set("veid", profile.AccountID)
	query.Set("api_key", apiKey)
	parsed.RawQuery = query.Encode()
	request, err := http.NewRequest(http.MethodGet, parsed.String(), nil)
	if err != nil {
		return TrafficSnapshot{}, errors.New("could not construct the KiwiVM request")
	}
	request.Header.Set("Accept", "application/json")
	payload, err := boundedHTTPJSON(request)
	parsed.RawQuery = ""
	if err != nil {
		return TrafficSnapshot{}, err
	}
	return parseKiwiVMSnapshot(payload)
}

func parseKiwiVMSnapshot(payload interface{}) (TrafficSnapshot, error) {
	used, usedOK := findJSONNumber(payload, "data_counter")
	limit, limitOK := findJSONNumber(payload, "plan_monthly_data")
	if !usedOK || !limitOK || limit <= 0 {
		return TrafficSnapshot{}, errors.New("KiwiVM response did not contain valid data_counter and plan_monthly_data values")
	}
	multiplier, multiplierOK := findJSONNumber(payload, "monthly_data_multiplier")
	if multiplierOK && multiplier > 0 {
		used *= multiplier
		limit *= multiplier
	} else {
		multiplier = 1
	}
	resetAt := time.Time{}
	if reset, ok := findJSONNumber(payload, "data_next_reset"); ok && reset > 0 {
		resetAt = time.Unix(int64(reset), 0)
	}
	return TrafficSnapshot{
		Source:     "KiwiVM API",
		UsedBytes:  uint64(used),
		QuotaBytes: uint64(limit),
		ResetAt:    resetAt,
		Detail:     fmt.Sprintf("provider counter multiplier %.3g", multiplier),
	}, nil
}

func fetchSolusCompatibleTraffic(profile TrafficProfile, token string) (TrafficSnapshot, error) {
	endpoint, err := validProviderEndpoint(profile.Endpoint)
	if err != nil {
		return TrafficSnapshot{}, err
	}
	request, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return TrafficSnapshot{}, errors.New("could not construct the SolusVM-compatible request")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+token)
	payload, err := boundedHTTPJSON(request)
	if err != nil {
		return TrafficSnapshot{}, err
	}
	used, ok := findJSONNumber(payload,
		"traffic_usage_bytes", "network_traffic_used", "bandwidth_used", "bwusage", "data_counter")
	if !ok {
		return TrafficSnapshot{}, errors.New("the endpoint did not expose a recognized byte-based traffic usage field")
	}
	limit, ok := findJSONNumber(payload,
		"traffic_limit_bytes", "network_traffic_limit", "bandwidth_limit", "bwlimit", "plan_monthly_data")
	if !ok || limit <= 0 {
		limit = float64(profile.QuotaBytes)
	}
	if limit <= 0 {
		return TrafficSnapshot{}, errors.New("the endpoint did not expose a traffic limit and no manual quota was configured")
	}
	resetAt := time.Time{}
	if reset, ok := findJSONNumber(payload, "data_next_reset", "traffic_reset_at", "reset_at"); ok && reset > 0 {
		resetAt = time.Unix(int64(reset), 0)
	} else if resetText, ok := findJSONString(payload, "traffic_reset_at", "reset_at", "next_reset"); ok {
		resetAt, _ = time.Parse(time.RFC3339, resetText)
	}
	return TrafficSnapshot{
		Source:     "SolusVM-compatible HTTPS API",
		UsedBytes:  uint64(used),
		QuotaBytes: uint64(limit),
		ResetAt:    resetAt,
		Detail:     "conditional adapter; provider endpoint must report byte-based fields",
	}, nil
}

type vnStatDocument struct {
	Interfaces []struct {
		Name    string `json:"name"`
		Created struct {
			Date struct {
				Year  int `json:"year"`
				Month int `json:"month"`
				Day   int `json:"day"`
			} `json:"date"`
		} `json:"created"`
		Traffic struct {
			Day []struct {
				Date struct {
					Year  int `json:"year"`
					Month int `json:"month"`
					Day   int `json:"day"`
				} `json:"date"`
				RX uint64 `json:"rx"`
				TX uint64 `json:"tx"`
			} `json:"day"`
		} `json:"traffic"`
	} `json:"interfaces"`
}

func clampedDate(year int, month time.Month, day int, location *time.Location) time.Time {
	if day < 1 {
		day = 1
	}
	last := time.Date(year, month+1, 0, 0, 0, 0, 0, location).Day()
	if day > last {
		day = last
	}
	return time.Date(year, month, day, 0, 0, 0, 0, location)
}

func trafficPeriod(now time.Time, resetDay int) (time.Time, time.Time) {
	if resetDay < 1 || resetDay > 28 {
		resetDay = 1
	}
	start := clampedDate(now.Year(), now.Month(), resetDay, now.Location())
	if now.Before(start) {
		previous := now.AddDate(0, -1, 0)
		start = clampedDate(previous.Year(), previous.Month(), resetDay, now.Location())
	}
	nextMonth := start.AddDate(0, 1, 0)
	next := clampedDate(nextMonth.Year(), nextMonth.Month(), resetDay, now.Location())
	return start, next
}

func parseVnStatTraffic(data []byte, quota uint64, resetDay int, now time.Time) (TrafficSnapshot, error) {
	var document vnStatDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return TrafficSnapshot{}, fmt.Errorf("vnStat returned invalid JSON: %w", err)
	}
	if len(document.Interfaces) == 0 {
		return TrafficSnapshot{}, errors.New("vnStat JSON contains no interface")
	}
	start, next := trafficPeriod(now, resetDay)
	var rx, tx uint64
	for _, item := range document.Interfaces[0].Traffic.Day {
		date := time.Date(item.Date.Year, time.Month(item.Date.Month), item.Date.Day, 0, 0, 0, 0, now.Location())
		if !date.Before(start) && date.Before(next) {
			rx += item.RX
			tx += item.TX
		}
	}
	return TrafficSnapshot{
		Source:     "SSH + vnStat",
		UsedBytes:  rx + tx,
		QuotaBytes: quota,
		RXBytes:    rx,
		TXBytes:    tx,
		ResetAt:    next,
		Estimated:  true,
		Detail:     "guest-interface estimate; provider billing can differ",
	}, nil
}

func trafficPercent(snapshot TrafficSnapshot) float64 {
	if snapshot.QuotaBytes == 0 {
		return 0
	}
	return float64(snapshot.UsedBytes) * 100 / float64(snapshot.QuotaBytes)
}

func trafficWarning(percent float64) string {
	switch {
	case percent >= trafficWarningCritical:
		return "CRITICAL"
	case percent >= trafficWarningWarning:
		return "WARNING"
	case percent >= trafficWarningNotice:
		return "NOTICE"
	default:
		return "GOOD"
	}
}

func formatBytes(value uint64) string {
	const unit = 1024
	if value < unit {
		return fmt.Sprintf("%d B", value)
	}
	divisor := float64(unit)
	units := []string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	index := 0
	for index < len(units)-1 && float64(value)/divisor >= unit {
		divisor *= unit
		index++
	}
	return fmt.Sprintf("%.2f %s", float64(value)/divisor, units[index])
}

func (a *App) printTrafficSnapshot(profile TrafficProfile, snapshot TrafficSnapshot) {
	percent := trafficPercent(snapshot)
	remaining := uint64(0)
	if snapshot.QuotaBytes > snapshot.UsedBytes {
		remaining = snapshot.QuotaBytes - snapshot.UsedBytes
	}
	a.println()
	a.println("================ TRAFFIC STATUS ================")
	a.println(a.msg("节点", "Node") + "=" + profile.Label)
	a.println(a.msg("来源", "Source") + "=" + snapshot.Source)
	a.println(a.msg("已用", "Used") + "=" + formatBytes(snapshot.UsedBytes))
	a.println(a.msg("额度", "Quota") + "=" + formatBytes(snapshot.QuotaBytes))
	a.println(a.msg("剩余", "Remaining") + "=" + formatBytes(remaining))
	a.println(fmt.Sprintf("USAGE_PERCENT=%.2f%%", percent))
	a.println("WARNING_LEVEL=" + trafficWarning(percent))
	if snapshot.RXBytes > 0 || snapshot.TXBytes > 0 {
		a.println("RX=" + formatBytes(snapshot.RXBytes))
		a.println("TX=" + formatBytes(snapshot.TXBytes))
	}
	if !snapshot.ResetAt.IsZero() {
		a.println("RESET_AT=" + snapshot.ResetAt.Local().Format(time.RFC3339))
	}
	if snapshot.Estimated {
		a.println(a.msg("精度=VPS 本机估算，可能与服务商计费不同", "Accuracy=guest estimate; provider billing may differ"))
	} else {
		a.println(a.msg("精度=服务商 API 计费口径", "Accuracy=provider API billing counter"))
	}
	if snapshot.Detail != "" {
		a.println("DETAIL=" + snapshot.Detail)
	}
	a.println("THRESHOLDS=70/85/95")
	a.println("================================================")
}

func parseQuotaGB(value string) (uint64, bool) {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || parsed <= 0 || parsed > 1000000 {
		return 0, false
	}
	return uint64(parsed * 1024 * 1024 * 1024), true
}

func parseResetDay(value string) (int, bool) {
	day, err := strconv.Atoi(strings.TrimSpace(value))
	return day, err == nil && day >= 1 && day <= 28
}

func sshTrafficProfileID(c Connection) string {
	return normalizeTrafficID(fmt.Sprintf("%s-%s-%d", c.Host, c.User, c.Port))
}

func (a *App) configureSSHTrafficProfile(c Connection, existing *TrafficProfile) (TrafficProfile, error) {
	profile := TrafficProfile{
		Provider: "ssh-vnstat",
		ID:       sshTrafficProfileID(c),
		Label:    c.User + "@" + c.Host + ":" + strconv.Itoa(c.Port),
		Host:     c.Host,
		User:     c.User,
		Port:     c.Port,
		ResetDay: 1,
	}
	if existing != nil {
		profile = *existing
	}
	for {
		label := a.prompt(a.msg("流量显示名称 ["+profile.Label+"]", "Traffic display name ["+profile.Label+"]"))
		if a.inputClosed {
			return TrafficProfile{}, errInputClosed
		}
		if strings.TrimSpace(label) != "" {
			profile.Label = strings.TrimSpace(label)
		}
		if profile.Label != "" {
			break
		}
	}
	for {
		defaultText := ""
		if profile.QuotaBytes > 0 {
			defaultText = fmt.Sprintf("%.0f", float64(profile.QuotaBytes)/(1024*1024*1024))
		}
		label := a.msg("月流量额度 GB", "Monthly quota in GB")
		if defaultText != "" {
			label += " [" + defaultText + "]"
		}
		answer := a.prompt(label)
		if a.inputClosed {
			return TrafficProfile{}, errInputClosed
		}
		if answer == "" {
			answer = defaultText
		}
		if quota, ok := parseQuotaGB(answer); ok {
			profile.QuotaBytes = quota
			break
		}
		a.println(a.msg("请输入有效的 GB 数值。", "Enter a valid GB value."))
	}
	for {
		answer := a.prompt(fmt.Sprintf(a.msg("每月重置日 1-28 [%d]", "Monthly reset day 1-28 [%d]"), profile.ResetDay))
		if a.inputClosed {
			return TrafficProfile{}, errInputClosed
		}
		if answer == "" {
			break
		}
		if day, ok := parseResetDay(answer); ok {
			profile.ResetDay = day
			break
		}
		a.println(a.msg("重置日只能是 1 到 28。", "Reset day must be from 1 through 28."))
	}
	return profile, nil
}

func findTrafficProfile(store TrafficStore, provider, id string) *TrafficProfile {
	for index := range store.Profiles {
		if store.Profiles[index].Provider == provider && store.Profiles[index].ID == id {
			copy := store.Profiles[index]
			return &copy
		}
	}
	return nil
}

func (a *App) trafficEstimate() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	status := a.rootCapture(c, "bash "+remoteRoot+"/linux/21-traffic-status.sh --status")
	if !status.OK() {
		return fmt.Errorf("vnStat status failed (exit %d): %s", status.ExitCode, processFailureDetail(status))
	}
	a.println(strings.TrimSpace(status.Stdout))
	if !strings.Contains(status.Stdout, "VNSTAT_INSTALLED=1") || !strings.Contains(status.Stdout, "VNSTAT_DATABASE_READY=1") {
		if !a.yes(a.msg("远端尚未准备好 vnStat。现在安装/初始化这个低占用统计器？", "vnStat is not ready remotely. Install/initialize this low-overhead counter now?"), true) {
			return errors.New(a.msg("没有修改远端；无法生成持久流量估算。", "The remote was unchanged; no persistent traffic estimate is available."))
		}
		install := a.runRootInteractive(c, "bash "+remoteRoot+"/linux/21-traffic-status.sh --install")
		if !install.OK() {
			return fmt.Errorf("vnStat install failed (exit %d): %s", install.ExitCode, processFailureDetail(install))
		}
	}
	store, err := loadTrafficStore()
	if err != nil {
		return err
	}
	id := sshTrafficProfileID(c)
	existing := findTrafficProfile(store, "ssh-vnstat", id)
	profile := TrafficProfile{}
	if existing == nil || !a.yes(a.msg("使用已保存的额度和重置日？", "Use the saved quota and reset day?"), true) {
		profile, err = a.configureSSHTrafficProfile(c, existing)
		if err != nil {
			return err
		}
		upsertTrafficProfile(&store, profile)
		if err := saveTrafficStore(store); err != nil {
			return err
		}
	} else {
		profile = *existing
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/21-traffic-status.sh --json")
	if !result.OK() {
		return fmt.Errorf("vnStat query failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	snapshot, err := parseVnStatTraffic([]byte(result.Stdout), profile.QuotaBytes, profile.ResetDay, time.Now())
	if err != nil {
		return err
	}
	profile.LastCheckedUTC = time.Now().UTC()
	upsertTrafficProfile(&store, profile)
	_ = saveTrafficStore(store)
	a.printTrafficSnapshot(profile, snapshot)
	return nil
}

func (a *App) performanceProfiles() error {
	c, err := a.readyConn()
	if err != nil {
		return err
	}
	if err := a.ensureToolkit(c); err != nil {
		return err
	}
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/20-adaptive-performance.sh --detect")
	if !result.OK() {
		return fmt.Errorf("performance detection failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(strings.TrimSpace(result.Stdout))
	a.println(a.msg("[1] 自动识别并应用（推荐）", "[1] Detect and apply automatically (recommended)"))
	a.println(a.msg("[2] 指定低内存档", "[2] Force low-memory profile"))
	a.println(a.msg("[3] 指定标准档", "[3] Force standard profile"))
	a.println(a.msg("[4] 指定高吞吐档", "[4] Force high-throughput profile"))
	a.println(a.msg("[5] 回滚最近一次性能改动", "[5] Roll back the latest performance change"))
	a.println(a.msg("[0] 只检测，不改动", "[0] Detect only; make no changes"))
	choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
	command := ""
	switch choice {
	case "1":
		command = "--apply auto"
	case "2":
		command = "--apply low"
	case "3":
		command = "--apply standard"
	case "4":
		command = "--apply high"
	case "5":
		if !a.yes(a.msg("确认恢复最近一次性能备份？", "Restore the latest performance backup?"), false) {
			return nil
		}
		command = "--rollback"
	case "0", "":
		return nil
	default:
		return errors.New(a.msg("无效性能档位选择。", "Invalid performance profile selection."))
	}
	apply := a.runRootInteractive(c, "bash "+remoteRoot+"/linux/20-adaptive-performance.sh "+command)
	if !apply.OK() {
		return fmt.Errorf("performance operation failed (exit %d): %s", apply.ExitCode, processFailureDetail(apply))
	}
	return nil
}

func (a *App) listProviderProfiles(store TrafficStore) []TrafficProfile {
	profiles := make([]TrafficProfile, 0)
	for _, profile := range store.Profiles {
		if profile.Provider == "kiwivm" || profile.Provider == "solusvm-compatible" {
			profiles = append(profiles, profile)
		}
	}
	sort.SliceStable(profiles, func(i, j int) bool { return profiles[i].Label < profiles[j].Label })
	for index, profile := range profiles {
		last := "never"
		if !profile.LastCheckedUTC.IsZero() {
			last = profile.LastCheckedUTC.Local().Format("2006-01-02 15:04")
		}
		a.println(fmt.Sprintf("[%d] %s provider=%s last=%s", index+1, profile.Label, profile.Provider, last))
	}
	return profiles
}

func (a *App) chooseProviderProfile(store TrafficStore) (*TrafficProfile, error) {
	profiles := a.listProviderProfiles(store)
	if len(profiles) == 0 {
		return nil, errors.New(a.msg("没有已保存的服务商流量配置。", "No saved provider traffic profiles exist."))
	}
	answer := a.prompt(a.msg("输入编号；0 取消", "Enter a number; 0 cancels"))
	if a.inputClosed {
		return nil, errInputClosed
	}
	index, err := strconv.Atoi(answer)
	if err != nil || index < 1 || index > len(profiles) {
		if answer == "0" {
			return nil, nil
		}
		return nil, errors.New(a.msg("配置编号无效。", "Invalid profile number."))
	}
	return &profiles[index-1], nil
}

func (a *App) configureKiwiVMProvider() error {
	label, err := a.required(a.msg("节点显示名称", "Node display name"))
	if err != nil {
		return err
	}
	id := normalizeTrafficID(label)
	if id == "" {
		return errors.New(a.msg("显示名称无法生成安全配置 ID。", "The label cannot produce a safe profile ID."))
	}
	veid, err := a.required("KiwiVM VEID")
	if err != nil {
		return err
	}
	if _, parseErr := strconv.ParseUint(strings.TrimSpace(veid), 10, 64); parseErr != nil {
		return errors.New("KiwiVM VEID must be numeric")
	}
	endpointAnswer := a.prompt("KiwiVM API endpoint [" + kiwiVMDefaultEndpoint + "]")
	if endpointAnswer == "" {
		endpointAnswer = kiwiVMDefaultEndpoint
	}
	endpoint, err := validProviderEndpoint(endpointAnswer)
	if err != nil {
		return err
	}
	apiKey := a.secretPrompt(a.msg("KiwiVM API Key（遮罩输入，不写日志）", "KiwiVM API Key (masked; never logged)"))
	if apiKey == "" {
		return errors.New(a.msg("API Key 不能为空。", "API Key cannot be empty."))
	}
	profile := TrafficProfile{
		ID:               id,
		Provider:         "kiwivm",
		Label:            strings.TrimSpace(label),
		AccountID:        strings.TrimSpace(veid),
		Endpoint:         endpoint,
		CredentialTarget: providerCredentialTarget("kiwivm", id),
	}
	snapshot, err := fetchKiwiVMTraffic(profile, apiKey)
	if err != nil {
		return err
	}
	profile.QuotaBytes = snapshot.QuotaBytes
	profile.LastCheckedUTC = time.Now().UTC()
	a.printTrafficSnapshot(profile, snapshot)
	if !a.yes(a.msg("把此 API Key 保存到 Windows Credential Manager？", "Save this API Key in Windows Credential Manager?"), true) {
		a.println(a.msg("仅本次使用完毕；API Key 不写入持久存储，也不保存配置。", "One-time use completed; the API Key and profile are not persisted."))
		return nil
	}
	if err := credentialWrite(profile.CredentialTarget, profile.AccountID, apiKey); err != nil {
		return err
	}
	store, err := loadTrafficStore()
	if err != nil {
		_ = credentialDelete(profile.CredentialTarget)
		return err
	}
	upsertTrafficProfile(&store, profile)
	if err := saveTrafficStore(store); err != nil {
		_ = credentialDelete(profile.CredentialTarget)
		return err
	}
	a.println(a.msg("配置已保存；秘密只在 Windows Credential Manager 中。", "Profile saved; the secret exists only in Windows Credential Manager."))
	return nil
}

func (a *App) configureSolusProvider() error {
	a.println(a.msg("仅在服务商明确提供只读流量 HTTPS API/Token 时使用；不要输入 RackNerd 网站密码。", "Use only when the provider supplies a read-only traffic HTTPS API/token; never enter a RackNerd website password."))
	label, err := a.required(a.msg("节点显示名称", "Node display name"))
	if err != nil {
		return err
	}
	id := normalizeTrafficID(label)
	endpointText, err := a.required(a.msg("服务商提供的 HTTPS 流量 JSON 端点（不得含 query/token）", "Provider HTTPS traffic JSON endpoint (no query/token)"))
	if err != nil {
		return err
	}
	endpoint, err := validProviderEndpoint(endpointText)
	if err != nil {
		return err
	}
	token := a.secretPrompt(a.msg("只读 API Token（Bearer，遮罩输入）", "Read-only API Token (Bearer; masked)"))
	if token == "" {
		return errors.New(a.msg("API Token 不能为空。", "API Token cannot be empty."))
	}
	quotaText, err := a.required(a.msg("月流量额度 GB（API不返回额度时使用）", "Monthly quota in GB (used if API omits the limit)"))
	if err != nil {
		return err
	}
	quota, ok := parseQuotaGB(quotaText)
	if !ok {
		return errors.New(a.msg("流量额度无效。", "Invalid traffic quota."))
	}
	profile := TrafficProfile{
		ID:               id,
		Provider:         "solusvm-compatible",
		Label:            strings.TrimSpace(label),
		Endpoint:         endpoint,
		QuotaBytes:       quota,
		CredentialTarget: providerCredentialTarget("solusvm-compatible", id),
	}
	snapshot, err := fetchSolusCompatibleTraffic(profile, token)
	if err != nil {
		return fmt.Errorf(a.msg("条件式 SolusVM 接口未通过验证；请改用 [17] SSH/vnStat：%w", "The conditional SolusVM endpoint did not validate; use [17] SSH/vnStat instead: %w"), err)
	}
	profile.QuotaBytes = snapshot.QuotaBytes
	profile.LastCheckedUTC = time.Now().UTC()
	a.printTrafficSnapshot(profile, snapshot)
	if !a.yes(a.msg("把此 Token 保存到 Windows Credential Manager？", "Save this token in Windows Credential Manager?"), true) {
		return nil
	}
	if err := credentialWrite(profile.CredentialTarget, profile.Label, token); err != nil {
		return err
	}
	store, err := loadTrafficStore()
	if err != nil {
		_ = credentialDelete(profile.CredentialTarget)
		return err
	}
	upsertTrafficProfile(&store, profile)
	if err := saveTrafficStore(store); err != nil {
		_ = credentialDelete(profile.CredentialTarget)
		return err
	}
	return nil
}

func fetchProviderProfile(profile TrafficProfile, secret string) (TrafficSnapshot, error) {
	switch profile.Provider {
	case "kiwivm":
		return fetchKiwiVMTraffic(profile, secret)
	case "solusvm-compatible":
		return fetchSolusCompatibleTraffic(profile, secret)
	default:
		return TrafficSnapshot{}, errors.New("unsupported provider profile")
	}
}

func (a *App) refreshProviderProfile() error {
	store, err := loadTrafficStore()
	if err != nil {
		return err
	}
	profile, err := a.chooseProviderProfile(store)
	if err != nil || profile == nil {
		return err
	}
	secret, err := credentialRead(profile.CredentialTarget)
	if err != nil || secret == "" {
		return errors.New(a.msg("Credential Manager 中没有可用凭据；请重新配置该服务商节点。", "No usable Credential Manager secret exists; reconfigure this provider profile."))
	}
	snapshot, err := fetchProviderProfile(*profile, secret)
	secret = ""
	if err != nil {
		return err
	}
	profile.LastCheckedUTC = time.Now().UTC()
	profile.QuotaBytes = snapshot.QuotaBytes
	upsertTrafficProfile(&store, *profile)
	_ = saveTrafficStore(store)
	a.printTrafficSnapshot(*profile, snapshot)
	return nil
}

func (a *App) deleteProviderProfile() error {
	store, err := loadTrafficStore()
	if err != nil {
		return err
	}
	profile, err := a.chooseProviderProfile(store)
	if err != nil || profile == nil {
		return err
	}
	if !a.yes(a.msg("删除此配置及其 Credential Manager 凭据？", "Delete this profile and its Credential Manager credential?"), false) {
		return nil
	}
	if err := credentialDelete(profile.CredentialTarget); err != nil {
		return err
	}
	removeTrafficProfile(&store, profile.Provider, profile.ID)
	return saveTrafficStore(store)
}

func (a *App) deleteAllProviderProfiles() error {
	store, err := loadTrafficStore()
	if err != nil {
		return err
	}
	confirmation := a.prompt(a.msg("删除全部服务商流量配置和凭据请输入大写 DELETE", "Type uppercase DELETE to remove all provider traffic profiles and credentials"))
	if confirmation != "DELETE" {
		return nil
	}
	retained := make([]TrafficProfile, 0)
	for _, profile := range store.Profiles {
		if profile.Provider == "kiwivm" || profile.Provider == "solusvm-compatible" {
			if err := credentialDelete(profile.CredentialTarget); err != nil {
				return err
			}
			continue
		}
		retained = append(retained, profile)
	}
	store.Profiles = retained
	return saveTrafficStore(store)
}

func (a *App) providerTrafficCenter() error {
	for {
		a.println()
		a.println(a.msg("服务商精确流量中心（本功能不登录 VPS）", "Provider traffic center (no VPS login)"))
		a.println("[1] KiwiVM API: " + a.msg("配置/验证并选择是否安全保存", "configure/validate and optionally save securely"))
		a.println("[2] SolusVM/RackNerd: " + a.msg("仅验证服务商提供的只读 HTTPS API", "validate only a provider-issued read-only HTTPS API"))
		a.println("[3] " + a.msg("刷新一个已保存配置", "refresh a saved profile"))
		a.println("[4] " + a.msg("列出已保存配置（不读取秘密）", "list saved profiles without reading secrets"))
		a.println("[5] " + a.msg("删除一个配置及凭据", "delete one profile and credential"))
		a.println("[6] " + a.msg("删除全部服务商配置及凭据", "delete all provider profiles and credentials"))
		a.println("[0] " + a.msg("返回", "return"))
		choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
		var err error
		switch choice {
		case "1":
			err = a.configureKiwiVMProvider()
		case "2":
			err = a.configureSolusProvider()
		case "3":
			err = a.refreshProviderProfile()
		case "4":
			store, loadErr := loadTrafficStore()
			if loadErr != nil {
				err = loadErr
			} else if len(a.listProviderProfiles(store)) == 0 {
				a.println(a.msg("没有已保存的服务商配置。", "No provider profiles are saved."))
			}
		case "5":
			err = a.deleteProviderProfile()
		case "6":
			err = a.deleteAllProviderProfiles()
		case "0", "":
			return nil
		default:
			err = errors.New(a.msg("无效选择。", "Invalid selection."))
		}
		if err != nil {
			a.println(a.msg("流量中心操作失败：", "Traffic-center action failed: ") + err.Error())
		}
	}
}
