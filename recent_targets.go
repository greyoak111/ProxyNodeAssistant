package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxRecentTargets = 20

type RecentTarget struct {
	Host     string
	User     string
	Port     int
	LastUsed time.Time
}

func recentTargetsPath() (string, error) {
	if override := strings.TrimSpace(os.Getenv("PNA_HISTORY_PATH")); override != "" {
		return filepath.Clean(override), nil
	}
	base := os.Getenv("APPDATA")
	if base == "" {
		var err error
		base, err = os.UserConfigDir()
		if err != nil {
			return "", err
		}
	}
	current := filepath.Join(base, "ProxyNodeAssistant", "recent-targets.tsv")
	legacy := filepath.Join(base, "TextNodeAssistant", "recent-targets.tsv")
	if _, err := os.Stat(current); os.IsNotExist(err) {
		if _, legacyErr := os.Stat(legacy); legacyErr == nil {
			return legacy, nil
		}
	}
	return current, nil
}

func recentTargetKey(target RecentTarget) string {
	return strings.ToLower(target.Host) + "\x00" + target.User + "\x00" + strconv.Itoa(target.Port)
}

func validRecentTarget(target RecentTarget) bool {
	return hostPartPattern.MatchString(target.Host) && userPartPattern.MatchString(target.User) && target.Port >= 1 && target.Port <= 65535
}

func normalizeRecentTargets(values []RecentTarget) []RecentTarget {
	sort.SliceStable(values, func(i, j int) bool { return values[i].LastUsed.After(values[j].LastUsed) })
	seen := map[string]bool{}
	result := make([]RecentTarget, 0, len(values))
	for _, value := range values {
		value.Host = strings.TrimSpace(value.Host)
		value.User = strings.TrimSpace(value.User)
		if !validRecentTarget(value) || seen[recentTargetKey(value)] {
			continue
		}
		seen[recentTargetKey(value)] = true
		result = append(result, value)
		if len(result) == maxRecentTargets {
			break
		}
	}
	return result
}

func parseRecentTargets(data []byte) []RecentTarget {
	values := []RecentTarget{}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) != 4 {
			continue
		}
		port, err := strconv.Atoi(fields[2])
		if err != nil {
			continue
		}
		used, err := time.Parse(time.RFC3339Nano, fields[3])
		if err != nil {
			continue
		}
		values = append(values, RecentTarget{Host: fields[0], User: fields[1], Port: port, LastUsed: used})
	}
	return normalizeRecentTargets(values)
}

func encodeRecentTargets(values []RecentTarget) []byte {
	values = normalizeRecentTargets(values)
	lines := make([]string, 0, len(values))
	for _, value := range values {
		lines = append(lines, strings.Join([]string{value.Host, value.User, strconv.Itoa(value.Port), value.LastUsed.UTC().Format(time.RFC3339Nano)}, "\t"))
	}
	if len(lines) == 0 {
		return []byte{}
	}
	return []byte(strings.Join(lines, "\n") + "\n")
}

func loadRecentTargets() ([]RecentTarget, error) {
	path, err := recentTargetsPath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return []RecentTarget{}, nil
	}
	if err != nil {
		return nil, err
	}
	return parseRecentTargets(data), nil
}

func saveRecentTargets(values []RecentTarget) error {
	path, err := recentTargetsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temporary := path + ".tmp-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := os.WriteFile(temporary, encodeRecentTargets(values), 0600); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		_ = os.Remove(temporary)
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func rememberRecentTarget(target RecentTarget) error {
	if !validRecentTarget(target) {
		return errors.New("invalid recent target")
	}
	values, err := loadRecentTargets()
	if err != nil {
		return err
	}
	target.LastUsed = time.Now().UTC()
	filtered := []RecentTarget{target}
	key := recentTargetKey(target)
	for _, value := range values {
		if recentTargetKey(value) != key {
			filtered = append(filtered, value)
		}
	}
	return saveRecentTargets(filtered)
}

func deleteRecentTarget(index int) error {
	values, err := loadRecentTargets()
	if err != nil {
		return err
	}
	if index < 0 || index >= len(values) {
		return errors.New("recent target index out of range")
	}
	values = append(values[:index], values[index+1:]...)
	return saveRecentTargets(values)
}

func clearRecentTargets() error {
	path, err := recentTargetsPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (a *App) printRecentTargets(values []RecentTarget) {
	if len(values) == 0 {
		a.println(a.msg("没有保存过 VPS 登录地址。", "No VPS login targets are saved."))
		return
	}
	for index, value := range values {
		used := value.LastUsed.Local().Format("2006-01-02 15:04")
		a.println(fmt.Sprintf("[%d] %s@%s:%d  %s", index+1, value.User, value.Host, value.Port, used))
	}
}

func (a *App) promptManualConnectionDetails() (string, string, int, error) {
	hostValue, err := a.required(a.msg("VPS IP 或主机名", "VPS IP or hostname"))
	if err != nil {
		return "", "", 0, err
	}
	userValue, err := a.required(a.msg("SSH 用户名（如 root / ubuntu）", "SSH username (for example root / ubuntu)"))
	if err != nil {
		return "", "", 0, err
	}
	host := strings.TrimSpace(hostValue)
	user := strings.TrimSpace(userValue)
	portText := strings.TrimSpace(a.prompt(a.msg("SSH 端口 [22]", "SSH port [22]")))
	if a.inputClosed {
		return "", "", 0, errInputClosed
	}
	port := 22
	if portText != "" {
		port, err = strconv.Atoi(portText)
	}
	if err != nil || !validRecentTarget(RecentTarget{Host: host, User: user, Port: port}) {
		return "", "", 0, errors.New(a.msg("连接参数错误。", "Invalid connection input."))
	}
	return host, user, port, nil
}

func (a *App) chooseConnectionDetails() (string, string, int, error) {
	if os.Getenv("PNA_PREFILLED_CONNECTION") == "1" {
		return a.promptManualConnectionDetails()
	}
	for {
		values, err := loadRecentTargets()
		if err != nil {
			a.println(a.msg("读取登录历史失败，将改为手工输入：", "Could not read login history; switching to manual input:") + " " + err.Error())
			return a.promptManualConnectionDetails()
		}
		if len(values) == 0 {
			return a.promptManualConnectionDetails()
		}
		a.println(a.msg("最近使用的 VPS（只保存地址、用户、端口，不保存密码或 key）：", "Recent VPS targets (host, user, and port only; no password or key is stored):"))
		a.printRecentTargets(values)
		a.println(a.msg("[M] 手工输入  [D] 删除单条  [X] 清空全部  [0] 取消", "[M] Manual  [D] Delete one  [X] Clear all  [0] Cancel"))
		choice := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("选择历史编号 [1]", "Choose a recent target [1]"))))
		if a.inputClosed {
			return "", "", 0, errInputClosed
		}
		if choice == "" {
			choice = "1"
		}
		if number, parseErr := strconv.Atoi(choice); parseErr == nil && number >= 1 && number <= len(values) {
			value := values[number-1]
			return value.Host, value.User, value.Port, nil
		}
		switch choice {
		case "m":
			return a.promptManualConnectionDetails()
		case "d":
			indexText := strings.TrimSpace(a.prompt(a.msg("输入要删除的编号", "Enter the number to delete")))
			if a.inputClosed {
				return "", "", 0, errInputClosed
			}
			index, parseErr := strconv.Atoi(indexText)
			if parseErr != nil || index < 1 || index > len(values) {
				a.println(a.msg("编号无效；没有删除。", "Invalid number; nothing was deleted."))
				continue
			}
			if err := deleteRecentTarget(index - 1); err != nil {
				return "", "", 0, err
			}
			a.println(a.msg("该条登录历史已删除。", "That recent target was deleted."))
		case "x":
			if a.yes(a.msg("确认清空全部 VPS 登录历史？已绑定 key 不受影响。", "Clear all VPS login history? Bound keys are not affected."), false) {
				if err := clearRecentTargets(); err != nil {
					return "", "", 0, err
				}
				a.println(a.msg("登录历史已全部清空。", "All login history was cleared."))
			}
		case "0":
			return "", "", 0, errConnectionSelectionCancelled
		default:
			a.println(a.msg("选择无效。", "Invalid choice."))
		}
	}
}

func (a *App) manageRecentTargets() error {
	path, _ := recentTargetsPath()
	for {
		values, err := loadRecentTargets()
		if err != nil {
			return err
		}
		a.println(a.msg("VPS 登录历史（不包含密码、私钥、域名或订阅）：", "VPS login history (no password, private key, domain, or subscription):"))
		a.println(a.msg("保存位置：", "Stored at:") + " " + path)
		a.printRecentTargets(values)
		a.println(a.msg("[1] 删除一条  [2] 清空全部  [0] 返回", "[1] Delete one  [2] Clear all  [0] Back"))
		choice := strings.TrimSpace(a.prompt(a.msg("请选择", "Choose")))
		if a.inputClosed {
			return nil
		}
		switch choice {
		case "1":
			if len(values) == 0 {
				continue
			}
			indexText := strings.TrimSpace(a.prompt(a.msg("输入要删除的编号", "Enter the number to delete")))
			if a.inputClosed {
				return nil
			}
			index, parseErr := strconv.Atoi(indexText)
			if parseErr != nil || index < 1 || index > len(values) {
				a.println(a.msg("编号无效；没有删除。", "Invalid number; nothing was deleted."))
				continue
			}
			if err := deleteRecentTarget(index - 1); err != nil {
				return err
			}
			a.println(a.msg("已删除。", "Deleted."))
		case "2":
			if a.yes(a.msg("确认清空全部登录历史？", "Clear all login history?"), false) {
				if err := clearRecentTargets(); err != nil {
					return err
				}
				a.println(a.msg("登录历史已全部清空。", "All login history was cleared."))
			}
		case "0", "":
			return nil
		default:
			a.println(a.msg("选择无效。", "Invalid choice."))
		}
	}
}
