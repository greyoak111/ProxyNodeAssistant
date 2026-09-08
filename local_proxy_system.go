package main

// This file contains the platform-neutral part of the macOS system proxy
// implementation.  The entry points are guarded by runtime.GOOS so the same
// source tree continues to build the Windows and Linux CLI.  On macOS all
// changes go through Apple's networksetup utility and the administrator
// authorization dialog; no password is ever accepted by this process.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	macOSNetworkSetupPath = "/usr/sbin/networksetup"
	macOSAppleScriptPath  = "/usr/bin/osascript"
	macOSProxyServer      = "127.0.0.1"
	macOSProxyPort        = 10808
	macOSProxyStateSchema = 1
	macOSProxyStateName   = "local-proxy-state.json"
)

var macOSProxyBypassDomains = []string{"localhost", "127.0.0.1", "::1"}

// macOSProxyEndpoint is deliberately limited to values printed by
// networksetup.  In particular, it has no password field: proxy credentials
// remain in the system keychain and are never copied into our state file.
type macOSProxyEndpoint struct {
	Enabled       bool   `json:"enabled"`
	Server        string `json:"server,omitempty"`
	Port          int    `json:"port,omitempty"`
	Authenticated bool   `json:"authenticated,omitempty"`
	Username      string `json:"username,omitempty"`
}

type macOSProxyServiceState struct {
	Name                 string             `json:"name"`
	Web                  macOSProxyEndpoint `json:"web"`
	SecureWeb            macOSProxyEndpoint `json:"secureWeb"`
	Socks                macOSProxyEndpoint `json:"socks"`
	BypassDomains        []string           `json:"bypassDomains,omitempty"`
	AutoProxyURL         string             `json:"autoProxyURL,omitempty"`
	AutoProxyEnabled     bool               `json:"autoProxyEnabled,omitempty"`
	AutoDiscoveryEnabled bool               `json:"autoDiscoveryEnabled,omitempty"`
}

type macOSProxyState struct {
	Schema   int                      `json:"schema"`
	Endpoint string                   `json:"endpoint"`
	Captured string                   `json:"capturedAt"`
	Services []macOSProxyServiceState `json:"services"`
}

type macOSLocalProxyRuntime struct {
	ListenerPIDs  []string
	HTTPConnect   bool
	SOCKS5        bool
	TUNInterfaces []string
	TUNProcesses  []string
}

func probeLocalHTTPProxy() bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", macOSProxyServer, macOSProxyPort), 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := fmt.Fprintf(conn, "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"); err != nil {
		return false
	}
	buf := make([]byte, 64)
	n, err := conn.Read(buf)
	return err == nil && n >= 5 && bytes.HasPrefix(buf[:n], []byte("HTTP/"))
}

func probeLocalSOCKS5() bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", macOSProxyServer, macOSProxyPort), 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return false
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(conn, response); err != nil {
		return false
	}
	return response[0] == 0x05 && response[1] != 0xff
}

func inspectMacOSLocalProxyRuntime() macOSLocalProxyRuntime {
	status := macOSLocalProxyRuntime{}
	if runtime.GOOS != "darwin" {
		return status
	}
	if result := runCaptured("/usr/sbin/lsof", []string{"-nP", "-iTCP:10808", "-sTCP:LISTEN", "-t"}, nil, true); result.OK() {
		for _, line := range strings.Fields(result.Stdout) {
			if line != "" {
				status.ListenerPIDs = append(status.ListenerPIDs, line)
			}
		}
	}
	if result := runCaptured("/sbin/ifconfig", []string{"-l"}, nil, true); result.OK() {
		for _, name := range strings.Fields(result.Stdout) {
			if strings.HasPrefix(name, "utun") {
				status.TUNInterfaces = append(status.TUNInterfaces, name)
			}
		}
	}
	if len(status.TUNInterfaces) > 0 {
		if result := runCaptured("/bin/ps", []string{"-axo", "comm="}, nil, true); result.OK() {
			seen := map[string]bool{}
			for _, line := range strings.Split(result.Stdout, "\n") {
				line = strings.TrimSpace(line)
				lower := strings.ToLower(line)
				if (strings.Contains(lower, "v2ray") || strings.Contains(lower, "sing-box") || strings.Contains(lower, "mihomo") || strings.Contains(lower, "clash") || strings.Contains(lower, "surge") || strings.Contains(lower, "loon")) && !seen[line] {
					status.TUNProcesses = append(status.TUNProcesses, line)
					seen[line] = true
				}
			}
		}
	}
	status.HTTPConnect = probeLocalHTTPProxy()
	status.SOCKS5 = probeLocalSOCKS5()
	return status
}

// localProxyEnvBefore is process-only bookkeeping.  It is intentionally not
// persisted: proxy environment values can contain credentials, while the
// macOS system snapshot above never does.
var (
	localProxyEnvMu     sync.Mutex
	localProxyEnvBefore = map[string]*string{}
)

func parseMacOSBool(value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "yes", "true", "on", "1":
		return true, nil
	case "no", "false", "off", "0":
		return false, nil
	default:
		return false, fmt.Errorf("invalid boolean value %q", value)
	}
}

func parseNetworksetupKeyValues(output string) map[string]string {
	values := make(map[string]string)
	for _, raw := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if key != "" {
			values[key] = value
		}
	}
	return values
}

func parseMacOSProxyOutput(output string) (macOSProxyEndpoint, error) {
	values := parseNetworksetupKeyValues(output)
	enabledValue, ok := values["Enabled"]
	if !ok {
		return macOSProxyEndpoint{}, errors.New("networksetup proxy output has no Enabled field")
	}
	enabled, err := parseMacOSBool(enabledValue)
	if err != nil {
		return macOSProxyEndpoint{}, err
	}
	state := macOSProxyEndpoint{Enabled: enabled}
	state.Server = strings.TrimSpace(values["Server"])
	if state.Server == "<none>" || strings.EqualFold(state.Server, "none") || strings.EqualFold(state.Server, "empty") {
		state.Server = ""
	}
	if portValue := strings.TrimSpace(values["Port"]); portValue != "" {
		port, parseErr := strconv.Atoi(portValue)
		if parseErr != nil || port < 0 || port > 65535 {
			return macOSProxyEndpoint{}, fmt.Errorf("invalid proxy port %q", portValue)
		}
		state.Port = port
	}
	if authValue := strings.TrimSpace(values["Authenticated Proxy Enabled"]); authValue != "" {
		state.Authenticated, err = parseMacOSBool(authValue)
		if err != nil {
			return macOSProxyEndpoint{}, err
		}
	}
	state.Username = strings.TrimSpace(values["Username"])
	if state.Enabled && (state.Server == "" || state.Port == 0) {
		return macOSProxyEndpoint{}, fmt.Errorf("enabled proxy has incomplete server/port (%q:%d)", state.Server, state.Port)
	}
	return state, nil
}

func parseMacOSAutoProxyOutput(output string) (url string, enabled bool, err error) {
	values := parseNetworksetupKeyValues(output)
	enabledValue, ok := values["Enabled"]
	if !ok {
		return "", false, errors.New("networksetup auto-proxy output has no Enabled field")
	}
	enabled, err = parseMacOSBool(enabledValue)
	if err != nil {
		return "", false, err
	}
	url = strings.TrimSpace(values["URL"])
	if strings.EqualFold(url, "(null)") || strings.EqualFold(url, "none") || strings.EqualFold(url, "empty") {
		url = ""
	}
	if strings.ContainsAny(url, "\x00\r\n") {
		return "", false, errors.New("auto-proxy URL contains a control character")
	}
	return url, enabled, nil
}

func parseMacOSAutoDiscoveryOutput(output string) (bool, error) {
	values := parseNetworksetupKeyValues(output)
	value, ok := values["Auto Proxy Discovery"]
	if !ok {
		return false, errors.New("networksetup auto-discovery output has no state field")
	}
	return parseMacOSBool(value)
}

func parseMacOSBypassOutput(output string) ([]string, error) {
	var domains []string
	for _, raw := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.EqualFold(line, "There aren't any bypass domains set.") || strings.EqualFold(line, "No proxy bypass domains set.") {
			continue
		}
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "** error:") || strings.HasPrefix(lower, "error:") {
			return nil, errors.New(line)
		}
		if strings.HasPrefix(lower, "202") && strings.Contains(lower, "proxies = nil") {
			continue
		}
		if strings.ContainsAny(line, "\x00\r\n") {
			return nil, errors.New("proxy bypass output contains a control character")
		}
		domains = append(domains, line)
	}
	return domains, nil
}

func parseMacOSNetworkServices(output string) []string {
	services := make([]string, 0)
	seen := make(map[string]struct{})
	for _, raw := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "An asterisk (*) denotes") {
			continue
		}
		// Disabled services are not part of the active network path. Keep them
		// untouched so a later restore cannot unexpectedly enable one.
		if strings.HasPrefix(line, "*") {
			continue
		}
		if _, ok := seen[line]; ok {
			continue
		}
		seen[line] = struct{}{}
		services = append(services, line)
	}
	return services
}

func macOSProxyStatePath() (string, error) {
	root, err := productConfigRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, macOSProxyStateName), nil
}

func validateMacOSNetworkServiceName(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("network service name is empty")
	}
	if strings.ContainsAny(name, "\x00\r\n") {
		return errors.New("network service name contains a control character")
	}
	return nil
}

func validateMacOSProxyState(state macOSProxyState) error {
	if state.Schema != macOSProxyStateSchema {
		return fmt.Errorf("unsupported local proxy state schema %d", state.Schema)
	}
	if state.Endpoint != fmt.Sprintf("%s:%d", macOSProxyServer, macOSProxyPort) {
		return fmt.Errorf("local proxy state endpoint is %q, expected %s:%d", state.Endpoint, macOSProxyServer, macOSProxyPort)
	}
	if len(state.Services) == 0 {
		return errors.New("local proxy state has no network services")
	}
	seen := make(map[string]struct{}, len(state.Services))
	for _, service := range state.Services {
		if err := validateMacOSNetworkServiceName(service.Name); err != nil {
			return err
		}
		if _, exists := seen[service.Name]; exists {
			return fmt.Errorf("local proxy state contains duplicate service %q", service.Name)
		}
		seen[service.Name] = struct{}{}
		for _, endpoint := range []macOSProxyEndpoint{service.Web, service.SecureWeb, service.Socks} {
			if err := validateMacOSProxyEndpoint(endpoint); err != nil {
				return fmt.Errorf("invalid proxy state for %q: %w", service.Name, err)
			}
		}
		for _, domain := range service.BypassDomains {
			if strings.ContainsAny(domain, "\x00\r\n") {
				return fmt.Errorf("local proxy state contains an invalid bypass domain for %q", service.Name)
			}
		}
		if strings.ContainsAny(service.AutoProxyURL, "\x00\r\n") {
			return fmt.Errorf("local proxy state contains an invalid automatic proxy URL for %q", service.Name)
		}
	}
	return nil
}

func validateMacOSProxyEndpoint(endpoint macOSProxyEndpoint) error {
	if strings.ContainsAny(endpoint.Server, "\x00\r\n") || strings.ContainsAny(endpoint.Username, "\x00\r\n") {
		return errors.New("proxy endpoint contains a control character")
	}
	if endpoint.Port < 0 || endpoint.Port > 65535 {
		return fmt.Errorf("proxy endpoint port %d is outside 0..65535", endpoint.Port)
	}
	if endpoint.Enabled && (strings.TrimSpace(endpoint.Server) == "" || endpoint.Port == 0) {
		return errors.New("enabled proxy endpoint has no server or port")
	}
	return nil
}

func loadMacOSProxyState() (macOSProxyState, bool, error) {
	path, err := macOSProxyStatePath()
	if err != nil {
		return macOSProxyState{}, false, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return macOSProxyState{}, false, nil
	}
	if err != nil {
		return macOSProxyState{}, true, err
	}
	var state macOSProxyState
	if err := json.Unmarshal(data, &state); err != nil {
		return macOSProxyState{}, true, fmt.Errorf("cannot parse %s: %w", path, err)
	}
	if err := validateMacOSProxyState(state); err != nil {
		return macOSProxyState{}, true, err
	}
	return state, true, nil
}

func writeMacOSProxyState(state macOSProxyState) error {
	if err := validateMacOSProxyState(state); err != nil {
		return err
	}
	path, err := macOSProxyStatePath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".local-proxy-state-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		_ = os.Remove(tmpName)
	}()
	if err := tmp.Chmod(0600); err != nil {
		_ = tmp.Close()
		return err
	}
	encoder := json.NewEncoder(tmp)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(state); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	return nil
}

func runMacOSNetworksetup(args ...string) ProcessResult {
	return runCaptured(macOSNetworkSetupPath, args, nil, true)
}

func readMacOSProxyService(name string) (macOSProxyServiceState, error) {
	if err := validateMacOSNetworkServiceName(name); err != nil {
		return macOSProxyServiceState{}, err
	}
	web := runMacOSNetworksetup("-getwebproxy", name)
	if !web.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read HTTP proxy for %q: %s", name, processFailureDetail(web))
	}
	secure := runMacOSNetworksetup("-getsecurewebproxy", name)
	if !secure.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read HTTPS proxy for %q: %s", name, processFailureDetail(secure))
	}
	socks := runMacOSNetworksetup("-getsocksfirewallproxy", name)
	if !socks.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read SOCKS proxy for %q: %s", name, processFailureDetail(socks))
	}
	bypass := runMacOSNetworksetup("-getproxybypassdomains", name)
	if !bypass.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read proxy bypass domains for %q: %s", name, processFailureDetail(bypass))
	}
	autoProxy := runMacOSNetworksetup("-getautoproxyurl", name)
	if !autoProxy.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read automatic proxy URL for %q: %s", name, processFailureDetail(autoProxy))
	}
	autoDiscovery := runMacOSNetworksetup("-getproxyautodiscovery", name)
	if !autoDiscovery.OK() {
		return macOSProxyServiceState{}, fmt.Errorf("cannot read automatic proxy discovery for %q: %s", name, processFailureDetail(autoDiscovery))
	}
	webState, err := parseMacOSProxyOutput(web.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse HTTP proxy for %q: %w", name, err)
	}
	secureState, err := parseMacOSProxyOutput(secure.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse HTTPS proxy for %q: %w", name, err)
	}
	socksState, err := parseMacOSProxyOutput(socks.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse SOCKS proxy for %q: %w", name, err)
	}
	domains, err := parseMacOSBypassOutput(bypass.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse proxy bypass domains for %q: %w", name, err)
	}
	autoURL, autoEnabled, err := parseMacOSAutoProxyOutput(autoProxy.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse automatic proxy URL for %q: %w", name, err)
	}
	autoDiscoveryEnabled, err := parseMacOSAutoDiscoveryOutput(autoDiscovery.Stdout)
	if err != nil {
		return macOSProxyServiceState{}, fmt.Errorf("cannot parse automatic proxy discovery for %q: %w", name, err)
	}
	return macOSProxyServiceState{
		Name:                 name,
		Web:                  webState,
		SecureWeb:            secureState,
		Socks:                socksState,
		BypassDomains:        domains,
		AutoProxyURL:         autoURL,
		AutoProxyEnabled:     autoEnabled,
		AutoDiscoveryEnabled: autoDiscoveryEnabled,
	}, nil
}

func discoverMacOSProxyServices() ([]macOSProxyServiceState, error) {
	if runtime.GOOS != "darwin" {
		return nil, errors.New("macOS system proxy is unavailable on this platform")
	}
	result := runMacOSNetworksetup("-listallnetworkservices")
	if !result.OK() {
		return nil, fmt.Errorf("cannot list macOS network services: %s", processFailureDetail(result))
	}
	names := parseMacOSNetworkServices(result.Stdout)
	services := make([]macOSProxyServiceState, 0, len(names))
	for _, name := range names {
		service, err := readMacOSProxyService(name)
		if err != nil {
			// A listed Thunderbolt/Bridge/VPN service can disappear from the
			// network database while disconnected. Skip only that service; fail
			// if no usable service remains so we never claim a system change.
			continue
		}
		services = append(services, service)
	}
	if len(services) == 0 {
		return nil, errors.New("no active macOS network service could be read")
	}
	return services, nil
}

func shellQuote(value string) (string, error) {
	if strings.ContainsAny(value, "\x00\r\n") {
		return "", errors.New("command argument contains a control character")
	}
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'", nil
}

func macOSNetworksetupCommand(args ...string) (string, error) {
	parts := []string{macOSNetworkSetupPath}
	for _, arg := range args {
		quoted, err := shellQuote(arg)
		if err != nil {
			return "", err
		}
		parts = append(parts, quoted)
	}
	return strings.Join(parts, " "), nil
}

func macOSProxyConfigureCommands(services []macOSProxyServiceState) ([][]string, error) {
	commands := make([][]string, 0, len(services)*9)
	for _, service := range services {
		if err := validateMacOSNetworkServiceName(service.Name); err != nil {
			return nil, err
		}
		if service.Web.Authenticated || service.SecureWeb.Authenticated || service.Socks.Authenticated {
			return nil, fmt.Errorf("network service %q uses an authenticated proxy; refusing to overwrite credentials", service.Name)
		}
		commands = append(commands,
			[]string{"-setwebproxy", service.Name, macOSProxyServer, strconv.Itoa(macOSProxyPort), "off", "", ""},
			[]string{"-setwebproxystate", service.Name, "on"},
			[]string{"-setsecurewebproxy", service.Name, macOSProxyServer, strconv.Itoa(macOSProxyPort), "off", "", ""},
			[]string{"-setsecurewebproxystate", service.Name, "on"},
			[]string{"-setsocksfirewallproxy", service.Name, macOSProxyServer, strconv.Itoa(macOSProxyPort), "off", "", ""},
			[]string{"-setsocksfirewallproxystate", service.Name, "on"},
			append([]string{"-setproxybypassdomains", service.Name}, macOSProxyBypassDomains...),
			[]string{"-setautoproxystate", service.Name, "off"},
			[]string{"-setproxyautodiscovery", service.Name, "off"},
		)
	}
	return commands, nil
}

func macOSProxyRestoreCommands(state macOSProxyState) ([][]string, error) {
	if err := validateMacOSProxyState(state); err != nil {
		return nil, err
	}
	commands := make([][]string, 0, len(state.Services)*10)
	for _, service := range state.Services {
		if service.Web.Authenticated || service.SecureWeb.Authenticated || service.Socks.Authenticated {
			return nil, fmt.Errorf("network service %q used an authenticated proxy; refusing a lossy restore", service.Name)
		}
		webArgs := []string{"-setwebproxy", service.Name}
		if service.Web.Server == "" || service.Web.Port == 0 {
			webArgs = append(webArgs, "Empty", "0", "off", "", "")
		} else {
			webArgs = append(webArgs, service.Web.Server, strconv.Itoa(service.Web.Port), "off", "", "")
		}
		secureArgs := []string{"-setsecurewebproxy", service.Name}
		if service.SecureWeb.Server == "" || service.SecureWeb.Port == 0 {
			secureArgs = append(secureArgs, "Empty", "0", "off", "", "")
		} else {
			secureArgs = append(secureArgs, service.SecureWeb.Server, strconv.Itoa(service.SecureWeb.Port), "off", "", "")
		}
		socksArgs := []string{"-setsocksfirewallproxy", service.Name}
		if service.Socks.Server == "" || service.Socks.Port == 0 {
			socksArgs = append(socksArgs, "Empty", "0", "off", "", "")
		} else {
			socksArgs = append(socksArgs, service.Socks.Server, strconv.Itoa(service.Socks.Port), "off", "", "")
		}
		commands = append(commands,
			webArgs,
			[]string{"-setwebproxystate", service.Name, boolToNetworksetupState(service.Web.Enabled)},
			secureArgs,
			[]string{"-setsecurewebproxystate", service.Name, boolToNetworksetupState(service.SecureWeb.Enabled)},
			socksArgs,
			[]string{"-setsocksfirewallproxystate", service.Name, boolToNetworksetupState(service.Socks.Enabled)},
		)
		bypassArgs := []string{"-setproxybypassdomains", service.Name}
		if len(service.BypassDomains) == 0 {
			bypassArgs = append(bypassArgs, "Empty")
		} else {
			bypassArgs = append(bypassArgs, service.BypassDomains...)
		}
		commands = append(commands, bypassArgs)
		if service.AutoProxyURL != "" {
			commands = append(commands, []string{"-setautoproxyurl", service.Name, service.AutoProxyURL})
		}
		commands = append(commands,
			[]string{"-setautoproxystate", service.Name, boolToNetworksetupState(service.AutoProxyEnabled)},
			[]string{"-setproxyautodiscovery", service.Name, boolToNetworksetupState(service.AutoDiscoveryEnabled)},
		)
	}
	return commands, nil
}

func boolToNetworksetupState(value bool) string {
	if value {
		return "on"
	}
	return "off"
}

func macOSProxyAdminScript(commands [][]string) (string, error) {
	lines := []string{"set -e"}
	for _, args := range commands {
		command, err := macOSNetworksetupCommand(args...)
		if err != nil {
			return "", err
		}
		lines = append(lines, command)
	}
	return strings.Join(lines, "\n"), nil
}

func appleScriptString(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\"", "\\\"")
	return value
}

func runMacOSAdminCommands(commands [][]string) error {
	if runtime.GOOS != "darwin" {
		return errors.New("macOS administrator authorization is unavailable on this platform")
	}
	shellScript, err := macOSProxyAdminScript(commands)
	if err != nil {
		return err
	}
	appleScript := `do shell script "` + appleScriptString(shellScript) + `" with administrator privileges`
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, macOSAppleScriptPath, "-e", appleScript)
	hideChildWindow(cmd)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return errors.New("macOS administrator authorization timed out or was canceled")
	}
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = strings.TrimSpace(stdout.String())
		}
		if detail == "" {
			detail = err.Error()
		}
		return fmt.Errorf("macOS administrator authorization failed: %s", clipFailureText(detail))
	}
	return nil
}

func macOSProxyServiceForced(service macOSProxyServiceState) bool {
	return service.Web.Enabled && service.Web.Server == macOSProxyServer && service.Web.Port == macOSProxyPort &&
		service.SecureWeb.Enabled && service.SecureWeb.Server == macOSProxyServer && service.SecureWeb.Port == macOSProxyPort &&
		service.Socks.Enabled && service.Socks.Server == macOSProxyServer && service.Socks.Port == macOSProxyPort &&
		!service.Web.Authenticated && !service.SecureWeb.Authenticated && !service.Socks.Authenticated &&
		!service.AutoProxyEnabled && !service.AutoDiscoveryEnabled &&
		macOSLoopbackBypassComplete(service.BypassDomains)
}

func macOSLoopbackBypassComplete(domains []string) bool {
	set := make(map[string]struct{}, len(domains))
	for _, value := range domains {
		set[strings.ToLower(strings.TrimSpace(value))] = struct{}{}
	}
	if _, ok := set["localhost"]; !ok {
		return false
	}
	if _, ok := set["::1"]; !ok {
		return false
	}
	_, exact := set["127.0.0.1"]
	_, cidr := set["127.0.0.0/8"]
	return exact || cidr
}

func containsAllStrings(haystack, needles []string) bool {
	set := make(map[string]struct{}, len(haystack))
	for _, value := range haystack {
		set[strings.TrimSpace(value)] = struct{}{}
	}
	for _, value := range needles {
		if _, ok := set[value]; !ok {
			return false
		}
	}
	return true
}

func macOSProxyEndpointEquivalent(actual, expected macOSProxyEndpoint) bool {
	actualServer := actual.Server
	expectedServer := expected.Server
	if strings.EqualFold(actualServer, "empty") {
		actualServer = ""
	}
	if strings.EqualFold(expectedServer, "empty") {
		expectedServer = ""
	}
	if actual.Enabled != expected.Enabled || actualServer != expectedServer || actual.Port != expected.Port || actual.Authenticated != expected.Authenticated {
		return false
	}
	if expected.Authenticated && actual.Username != expected.Username {
		return false
	}
	return true
}

func macOSProxyServiceEquivalent(actual, expected macOSProxyServiceState) bool {
	if actual.Name != expected.Name || !macOSProxyEndpointEquivalent(actual.Web, expected.Web) || !macOSProxyEndpointEquivalent(actual.SecureWeb, expected.SecureWeb) || !macOSProxyEndpointEquivalent(actual.Socks, expected.Socks) {
		return false
	}
	if len(actual.BypassDomains) != len(expected.BypassDomains) {
		return false
	}
	for index := range expected.BypassDomains {
		if actual.BypassDomains[index] != expected.BypassDomains[index] {
			return false
		}
	}
	return actual.AutoProxyURL == expected.AutoProxyURL && actual.AutoProxyEnabled == expected.AutoProxyEnabled && actual.AutoDiscoveryEnabled == expected.AutoDiscoveryEnabled
}

func verifyMacOSProxyServices(expected []macOSProxyServiceState, forced bool) error {
	actual, err := discoverMacOSProxyServices()
	if err != nil {
		return err
	}
	byName := make(map[string]macOSProxyServiceState, len(actual))
	for _, service := range actual {
		byName[service.Name] = service
	}
	for _, expectedService := range expected {
		service, ok := byName[expectedService.Name]
		if !ok {
			return fmt.Errorf("network service %q is no longer available", expectedService.Name)
		}
		if forced {
			if !macOSProxyServiceForced(service) {
				return fmt.Errorf("network service %q is not forced through 127.0.0.1:10808", service.Name)
			}
		} else if !macOSProxyServiceEquivalent(service, expectedService) {
			return fmt.Errorf("network service %q did not restore its saved proxy settings", service.Name)
		}
	}
	return nil
}

func rememberAndSetLocalProxyEnvironment() {
	localProxyEnvMu.Lock()
	defer localProxyEnvMu.Unlock()
	for _, name := range localProxyNames {
		if _, seen := localProxyEnvBefore[name]; !seen {
			if value, ok := os.LookupEnv(name); ok {
				copyValue := value
				localProxyEnvBefore[name] = &copyValue
			} else {
				localProxyEnvBefore[name] = nil
			}
		}
		_ = os.Setenv(name, expectedLocalProxyValue(name))
	}
}

func restoreLocalProxyEnvironment() {
	localProxyEnvMu.Lock()
	defer localProxyEnvMu.Unlock()
	for _, name := range localProxyNames {
		if value, seen := localProxyEnvBefore[name]; seen {
			if value == nil {
				_ = os.Unsetenv(name)
			} else {
				_ = os.Setenv(name, *value)
			}
			delete(localProxyEnvBefore, name)
			continue
		}
		// A later process has no in-memory baseline. Do not erase an unrelated
		// value; clear only the endpoint this tool owns.
		if os.Getenv(name) == expectedLocalProxyValue(name) {
			_ = os.Unsetenv(name)
		}
	}
}

func (a *App) showMacOSProxyStatus() error {
	services, err := discoverMacOSProxyServices()
	if err != nil {
		return err
	}
	state, stateExists, stateErr := loadMacOSProxyState()
	if stateErr != nil {
		return stateErr
	}
	a.println(a.msg("macOS 系统 HTTP/HTTPS/SOCKS 代理状态（不连接 VPS）：", "macOS system HTTP/HTTPS/SOCKS proxy status (no VPS connection):"))
	for _, service := range services {
		status := ""
		if macOSProxyServiceForced(service) {
			status = a.msg("已强制 → 127.0.0.1:10808", "forced -> 127.0.0.1:10808")
		} else {
			status = a.msg("未指向 127.0.0.1:10808", "not pointing to 127.0.0.1:10808")
		}
		a.println("  " + service.Name + ": " + status +
			a.msg(fmt.Sprintf("（HTTP %s:%d；HTTPS %s:%d；SOCKS %s:%d；自动代理 %s；WPAD %s）", service.Web.Server, service.Web.Port, service.SecureWeb.Server, service.SecureWeb.Port, service.Socks.Server, service.Socks.Port, boolToChineseState(service.AutoProxyEnabled), boolToChineseState(service.AutoDiscoveryEnabled)),
				fmt.Sprintf(" (HTTP %s:%d; HTTPS %s:%d; SOCKS %s:%d; PAC %s; WPAD %s)", service.Web.Server, service.Web.Port, service.SecureWeb.Server, service.SecureWeb.Port, service.Socks.Server, service.Socks.Port, boolToEnglishState(service.AutoProxyEnabled), boolToEnglishState(service.AutoDiscoveryEnabled))))
	}
	if stateExists {
		a.println(a.msg("  已保存可恢复快照："+fmt.Sprintf("%d 个网络服务", len(state.Services)), "  Saved restore snapshot: "+fmt.Sprintf("%d network service(s)", len(state.Services))))
	} else {
		a.println(a.msg("  尚未保存恢复快照；首次配置会先保存当前设置。", "  No restore snapshot exists; the first configure action saves the current settings first."))
	}
	runtimeStatus := inspectMacOSLocalProxyRuntime()
	if tcpReachable("127.0.0.1", macOSProxyPort) {
		if runtimeStatus.HTTPConnect || runtimeStatus.SOCKS5 {
			a.println(a.msg("[GOOD] 127.0.0.1:10808 监听正常，协议探针通过：HTTP CONNECT="+boolToChineseState(runtimeStatus.HTTPConnect)+"，SOCKS5="+boolToChineseState(runtimeStatus.SOCKS5)+"。", "[GOOD] 127.0.0.1:10808 is listening and protocol probes passed: HTTP CONNECT="+boolToEnglishState(runtimeStatus.HTTPConnect)+", SOCKS5="+boolToEnglishState(runtimeStatus.SOCKS5)+"."))
		} else {
			a.println(a.msg("[WARN] 127.0.0.1:10808 有监听但 HTTP CONNECT 与 SOCKS5 探针均失败；可能只是占用端口的其他程序。", "[WARN] 127.0.0.1:10808 is listening, but both HTTP CONNECT and SOCKS5 probes failed; another program may own the port."))
		}
		if len(runtimeStatus.ListenerPIDs) > 0 {
			a.println("  " + a.msg("监听 PID：", "Listener PID(s):") + strings.Join(runtimeStatus.ListenerPIDs, ","))
		}
	} else {
		a.println(a.msg("[WARN] 127.0.0.1:10808 当前没有程序监听；系统代理仍会生效，但请求会失败。", "[WARN] Nothing is listening on 127.0.0.1:10808; the system proxy will still be active, but requests will fail."))
	}
	if len(runtimeStatus.TUNInterfaces) > 0 {
		a.println(a.msg("[WARN] 检测到 TUN 接口 "+strings.Join(runtimeStatus.TUNInterfaces, ", ")+"；系统代理设置与 TUN 是两层，DNS/公网出口可能由 TUN 接管。本工具不会关闭或拆除第三方 TUN。", "[WARN] TUN interface(s) detected: "+strings.Join(runtimeStatus.TUNInterfaces, ", ")+". System proxy and TUN are separate layers; DNS/public egress may be owned by TUN. This tool will not stop or remove a third-party TUN."))
	}
	if len(runtimeStatus.TUNProcesses) > 0 {
		a.println("  " + a.msg("发现相关外部 TUN/代理进程：", "Detected related external TUN/proxy process(es):") + strings.Join(runtimeStatus.TUNProcesses, "; "))
	}
	return nil
}

func (a *App) configureMacOSProxy() error {
	services, err := discoverMacOSProxyServices()
	if err != nil {
		return err
	}
	runtimeStatus := inspectMacOSLocalProxyRuntime()
	if len(runtimeStatus.TUNInterfaces) > 0 {
		a.println(a.msg("[WARN] 当前检测到 "+strings.Join(runtimeStatus.TUNInterfaces, ", ")+"；这通常表示第三方 TUN 正在接管路由。本操作只配置 macOS 系统代理，不会安装、停止或拆除 TUN。", "[WARN] Detected "+strings.Join(runtimeStatus.TUNInterfaces, ", ")+". A third-party TUN may own routing. This action changes only macOS system proxy settings and will not install, stop, or remove the TUN."))
	}
	for _, service := range services {
		if service.Web.Authenticated || service.SecureWeb.Authenticated || service.Socks.Authenticated {
			return fmt.Errorf("网络服务 %q 当前使用认证代理；为避免丢失系统凭据，未修改任何服务", service.Name)
		}
	}
	state, exists, err := loadMacOSProxyState()
	if err != nil {
		return err
	}
	if !exists {
		alreadyForced := true
		for _, service := range services {
			if !macOSProxyServiceForced(service) {
				alreadyForced = false
				break
			}
		}
		if alreadyForced {
			// The endpoint may have been configured by an older build or by
			// System Settings. Capturing that state as the "original" would make
			// a later restore silently leave the proxy enabled, so refuse to
			// manufacture a misleading snapshot. The system is already in the
			// requested state; only synchronize this process' child environment.
			rememberAndSetLocalProxyEnvironment()
			a.println(a.msg("当前可用网络服务已经指向 127.0.0.1:10808；由于没有本工具保存的原设置快照，未伪造恢复点。系统代理保持不变。", "Every readable network service already points to 127.0.0.1:10808. Because no snapshot from this tool exists, no fake restore point was created and the system proxy was left unchanged."))
			return a.showMacOSProxyStatus()
		}
		state = macOSProxyState{Schema: macOSProxyStateSchema, Endpoint: fmt.Sprintf("%s:%d", macOSProxyServer, macOSProxyPort), Captured: time.Now().UTC().Format(time.RFC3339Nano), Services: append([]macOSProxyServiceState(nil), services...)}
		if err := writeMacOSProxyState(state); err != nil {
			return fmt.Errorf("保存 macOS 原代理设置失败：%w", err)
		}
		a.println(a.msg("已先保存当前 macOS 系统代理设置；之后可完整恢复。", "The current macOS proxy settings were saved first and can be fully restored later."))
	} else {
		// A new network service may have appeared since the snapshot was made.
		// Capture its current state before taking it over. If it is already
		// forced by an outside tool, its original state is unknowable and we
		// refuse to overwrite it rather than create an incomplete restore.
		saved := make(map[string]struct{}, len(state.Services))
		for _, service := range state.Services {
			saved[service.Name] = struct{}{}
		}
		changed := false
		for _, service := range services {
			if _, ok := saved[service.Name]; ok {
				continue
			}
			if macOSProxyServiceForced(service) {
				return fmt.Errorf("网络服务 %q 已经指向 127.0.0.1:10808，但快照中没有它；为避免无法恢复，未修改任何新服务", service.Name)
			}
			state.Services = append(state.Services, service)
			changed = true
		}
		if changed {
			if err := writeMacOSProxyState(state); err != nil {
				return fmt.Errorf("保存新增网络服务的原代理设置失败：%w", err)
			}
		}
	}
	commands, err := macOSProxyConfigureCommands(services)
	if err != nil {
		return err
	}
	if err := runMacOSAdminCommands(commands); err != nil {
		return err
	}
	if err := verifyMacOSProxyServices(services, true); err != nil {
		return fmt.Errorf("macOS 系统代理回读验证失败：%w", err)
	}
	runtimeStatus = inspectMacOSLocalProxyRuntime()
	if !runtimeStatus.HTTPConnect && !runtimeStatus.SOCKS5 {
		restoreCommands, restoreErr := macOSProxyRestoreCommands(state)
		if restoreErr != nil {
			return fmt.Errorf("127.0.0.1:10808 协议探针失败，无法生成原系统代理恢复命令：%w", restoreErr)
		}
		if restoreErr = runMacOSAdminCommands(restoreCommands); restoreErr != nil {
			return fmt.Errorf("127.0.0.1:10808 协议探针失败，且自动恢复原系统代理失败：%w", restoreErr)
		}
		if verifyErr := verifyMacOSProxyServices(state.Services, false); verifyErr != nil {
			return fmt.Errorf("127.0.0.1:10808 协议探针失败，原系统代理恢复后回读失败：%w", verifyErr)
		}
		return errors.New("127.0.0.1:10808 未通过 HTTP CONNECT 或 SOCKS5 协议探针；已保留快照，请先启动兼容的 mixed/HTTP/SOCKS 代理后重试")
	}
	rememberAndSetLocalProxyEnvironment()
	a.println(a.msg("[GOOD] 已将当前可用 macOS 网络服务的 HTTP/HTTPS/SOCKS 系统代理强制设为 127.0.0.1:10808，并关闭 PAC/WPAD，完成回读验证。", "[GOOD] HTTP/HTTPS/SOCKS system proxy is now forced to 127.0.0.1:10808 for every readable macOS network service; PAC/WPAD were disabled and read-back verification passed."))
	return a.showMacOSProxyStatus()
}

func (a *App) removeMacOSProxy() error {
	state, exists, err := loadMacOSProxyState()
	if err != nil {
		return err
	}
	if !exists {
		return errors.New("没有可恢复的 macOS 代理快照；为避免误删用户原设置，未修改系统代理。请先用本工具完成一次配置，或在系统设置中手动恢复")
	}
	current, currentErr := discoverMacOSProxyServices()
	if currentErr != nil {
		return fmt.Errorf("无法确认当前系统代理仍由本工具接管；快照保留，未执行恢复：%w", currentErr)
	}
	currentByName := make(map[string]macOSProxyServiceState, len(current))
	for _, service := range current {
		currentByName[service.Name] = service
	}
	for _, saved := range state.Services {
		service, ok := currentByName[saved.Name]
		if !ok || !macOSProxyServiceForced(service) {
			return fmt.Errorf("网络服务 %q 已被其他设置改变；为避免覆盖新代理，未执行恢复，快照保留", saved.Name)
		}
	}
	commands, err := macOSProxyRestoreCommands(state)
	if err != nil {
		return err
	}
	if err := runMacOSAdminCommands(commands); err != nil {
		return err
	}
	if err := verifyMacOSProxyServices(state.Services, false); err != nil {
		return fmt.Errorf("macOS 原代理设置回读验证失败；快照已保留，稍后可重试：%w", err)
	}
	path, err := macOSProxyStatePath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("已恢复系统代理，但删除快照失败：%w", err)
	}
	restoreLocalProxyEnvironment()
	a.println(a.msg("[GOOD] 已恢复配置前保存的 macOS HTTP/HTTPS/SOCKS、旁路和 PAC/WPAD 设置，并完成回读验证。", "[GOOD] The saved macOS HTTP/HTTPS/SOCKS, bypass, PAC, and WPAD settings were restored and verified."))
	return a.showMacOSProxyStatus()
}

// restoreMacOSProxyForUninstall is deliberately a no-op when this build has
// no saved snapshot.  That distinction matters for a user who configured
// 127.0.0.1:10808 manually (or with an older build): uninstalling the app
// must not guess at, or overwrite, that unrelated system setting.  When a
// snapshot exists, use the exact same verified restore path as menu [14].
func (a *App) restoreMacOSProxyForUninstall() error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	_, exists, err := loadMacOSProxyState()
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	return a.removeMacOSProxy()
}

func boolToChineseState(value bool) string {
	if value {
		return "开"
	}
	return "关"
}

func boolToEnglishState(value bool) string {
	if value {
		return "on"
	}
	return "off"
}
