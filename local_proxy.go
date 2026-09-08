package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
)

const (
	localProxyURL     = "http://127.0.0.1:10808"
	localProxyBypass  = "localhost,127.0.0.1,::1"
	localProxyHTTP    = "HTTP_PROXY"
	localProxyHTTPS   = "HTTPS_PROXY"
	localProxyNoProxy = "NO_PROXY"
)

var localProxyNames = []string{localProxyHTTP, localProxyHTTPS, localProxyNoProxy}

func expectedLocalProxyValue(name string) string {
	if name == localProxyNoProxy {
		return localProxyBypass
	}
	return localProxyURL
}

func parseEnvironmentLines(output string) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		name, value, ok := strings.Cut(line, "=")
		if ok {
			values[strings.TrimSpace(name)] = strings.TrimSpace(value)
		}
	}
	return values
}

func readUserLocalProxyEnvironment() (map[string]string, error) {
	if runtime.GOOS == "darwin" {
		// The authoritative state on macOS lives in the per-network-service
		// system proxy database. Keep this helper for compatibility with the
		// shared CLI/tests, but never pretend process environment variables are
		// the system-wide setting.
		values := map[string]string{}
		for _, name := range localProxyNames {
			values[name] = os.Getenv(name)
		}
		return values, nil
	}
	if runtime.GOOS != "windows" {
		// A child process cannot mutate its parent shell's environment. Return
		// this process' values so status still reflects what this CLI will pass
		// to commands it starts, without claiming shell-wide persistence.
		values := map[string]string{}
		for _, name := range localProxyNames {
			values[name] = os.Getenv(name)
		}
		return values, nil
	}
	script := `$names = @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY'); foreach ($name in $names) { Write-Output ($name + '=' + [string][Environment]::GetEnvironmentVariable($name, 'User')) }`
	result := runCaptured("powershell.exe", []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script}, nil, true)
	if !result.OK() {
		return nil, fmt.Errorf("cannot read user environment (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	return parseEnvironmentLines(result.Stdout), nil
}

func writeUserLocalProxyEnvironment(remove bool) error {
	if runtime.GOOS == "darwin" {
		if remove {
			restoreLocalProxyEnvironment()
		} else {
			rememberAndSetLocalProxyEnvironment()
		}
		return nil
	}
	if runtime.GOOS != "windows" {
		for _, name := range localProxyNames {
			if remove {
				if err := os.Unsetenv(name); err != nil {
					return fmt.Errorf("cannot clear %s: %w", name, err)
				}
				continue
			}
			if err := os.Setenv(name, expectedLocalProxyValue(name)); err != nil {
				return fmt.Errorf("cannot set %s: %w", name, err)
			}
		}
		return nil
	}
	valueExpression := "'http://127.0.0.1:10808'"
	noProxyExpression := "'localhost,127.0.0.1,::1'"
	if remove {
		valueExpression = "$null"
		noProxyExpression = "$null"
	}
	script := fmt.Sprintf(strings.Join([]string{
		`$ErrorActionPreference = 'Stop'`,
		`[Environment]::SetEnvironmentVariable('HTTP_PROXY', %s, 'User')`,
		`[Environment]::SetEnvironmentVariable('HTTPS_PROXY', %s, 'User')`,
		`[Environment]::SetEnvironmentVariable('NO_PROXY', %s, 'User')`,
		`try { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class PnaEnvironmentBroadcast { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result); }'; $broadcastResult = [IntPtr]::Zero; [void][PnaEnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [IntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$broadcastResult) } catch { }`,
	}, "; "), valueExpression, valueExpression, noProxyExpression)
	result := runCaptured("powershell.exe", []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script}, nil, true)
	if !result.OK() {
		return fmt.Errorf("cannot update user environment (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}

	values, err := readUserLocalProxyEnvironment()
	if err != nil {
		return err
	}
	for _, name := range localProxyNames {
		actual := values[name]
		if remove {
			if actual != "" {
				return fmt.Errorf("%s removal verification failed", name)
			}
			continue
		}
		if actual != expectedLocalProxyValue(name) {
			return fmt.Errorf("%s write verification failed", name)
		}
	}

	for _, name := range localProxyNames {
		if remove {
			_ = os.Unsetenv(name)
		} else {
			_ = os.Setenv(name, expectedLocalProxyValue(name))
		}
	}
	return nil
}

func (a *App) showLocalProxyStatus() error {
	if runtime.GOOS == "darwin" {
		return a.showMacOSProxyStatus()
	}
	values, err := readUserLocalProxyEnvironment()
	if err != nil {
		return err
	}
	a.println(a.msg("当前进程/用户环境变量（"+runtime.GOOS+"）：", "Current process/user environment variables ("+runtime.GOOS+"):"))
	for _, name := range localProxyNames {
		value := values[name]
		if value == "" {
			value = a.msg("（未设置）", "(not set)")
		}
		a.println("  " + name + "=" + value)
	}
	if tcpReachable("127.0.0.1", 10808) {
		a.println(a.msg("[GOOD] 本机 127.0.0.1:10808 当前有程序监听。", "[GOOD] A local program is currently listening on 127.0.0.1:10808."))
	} else {
		a.println(a.msg("[WARN] 127.0.0.1:10808 当前没有程序监听；环境变量可以保存，但使用前必须先启动对应本地代理客户端。", "[WARN] Nothing is currently listening on 127.0.0.1:10808. The variables can be saved, but the matching local proxy client must be started before use."))
	}
	return nil
}

func (a *App) configureLocalProxy() error {
	if runtime.GOOS == "darwin" {
		return a.configureMacOSProxy()
	}
	if err := writeUserLocalProxyEnvironment(false); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		a.println(a.msg("[GOOD] 已为当前 Windows 用户持久配置 HTTP_PROXY、HTTPS_PROXY 和 NO_PROXY，并完成回读验证。", "[GOOD] HTTP_PROXY, HTTPS_PROXY, and NO_PROXY were persistently configured for the current Windows user and read-back verification passed."))
	} else {
		a.println(a.msg("[GOOD] 已为本工具进程配置 HTTP_PROXY、HTTPS_PROXY 和 NO_PROXY，并完成回读验证。父 shell 不会被子进程改写；需要长期生效请手工加入 shell 配置。", "[GOOD] HTTP_PROXY, HTTPS_PROXY, and NO_PROXY were configured for this tool process and read-back verification passed. A child cannot rewrite its parent shell; add the values to your shell profile for persistence."))
	}
	if runtime.GOOS == "windows" {
		a.println(a.msg("本 EXE 后续启动的进程立即继承；已经打开的 PowerShell、终端或应用需要关闭后重新打开。", "Processes started later by this EXE inherit the values immediately. Already-open PowerShell, terminal, or application windows must be closed and reopened."))
	} else {
		a.println(a.msg("本工具后续启动的子进程立即继承。", "Child processes started by this tool inherit the values immediately."))
	}
	return a.showLocalProxyStatus()
}

func (a *App) removeLocalProxy() error {
	if runtime.GOOS == "darwin" {
		return a.removeMacOSProxy()
	}
	if err := writeUserLocalProxyEnvironment(true); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		a.println(a.msg("[GOOD] 已从当前 Windows 用户环境中撤销 HTTP_PROXY、HTTPS_PROXY 和 NO_PROXY，并完成回读验证。", "[GOOD] HTTP_PROXY, HTTPS_PROXY, and NO_PROXY were removed from the current Windows user environment and read-back verification passed."))
	} else {
		a.println(a.msg("[GOOD] 已从本工具进程环境中撤销 HTTP_PROXY、HTTPS_PROXY 和 NO_PROXY，并完成回读验证。", "[GOOD] HTTP_PROXY, HTTPS_PROXY, and NO_PROXY were removed from this tool process and read-back verification passed."))
	}
	if runtime.GOOS == "windows" {
		a.println(a.msg("已经打开的 PowerShell、终端或应用仍保留旧环境副本，需要关闭后重新打开。", "Already-open PowerShell, terminal, or application windows still hold their old environment copy and must be closed and reopened."))
	}
	return a.showLocalProxyStatus()
}

func (a *App) manageLocalProxy() error {
	if runtime.GOOS == "darwin" {
		a.println(a.msg("本功能管理当前 Mac 的系统级 HTTP/HTTPS/SOCKS 代理：不会读取或连接 VPS。配置前自动保存每个可用网络服务的原设置，同时关闭 PAC/WPAD；撤销时完整恢复；修改系统代理时只会出现 macOS 自己的管理员授权框。", "This feature manages the Mac system-wide HTTP/HTTPS/SOCKS proxy and never reads or connects to a VPS. It saves each readable service before configuration, disables PAC/WPAD, and restores everything on removal; macOS may show its own administrator authorization dialog for the system change."))
	} else if runtime.GOOS != "windows" {
		a.println(a.msg("macOS/Linux 只能影响本工具及其子进程；无法替父 shell 持久写入环境。", "On macOS/Linux this affects only this tool and its child processes; it cannot persistently modify the parent shell."))
		a.println(a.msg("本功能只修改本工具进程的代理环境变量，不会询问或连接任何 VPS。", "This feature only changes proxy environment variables for this tool process. It never asks for or connects to any VPS."))
	} else {
		a.println(a.msg("本功能只修改本机当前 Windows 用户的代理环境变量，不会询问或连接任何 VPS。", "This feature only changes proxy environment variables for the current Windows user. It never asks for or connects to any VPS."))
	}
	if runtime.GOOS == "darwin" {
		a.println("[1] " + a.msg("配置并验证：系统 HTTP/HTTPS/SOCKS → 127.0.0.1:10808（关闭 PAC/WPAD，先保存原设置）", "Configure and verify: system HTTP/HTTPS/SOCKS -> 127.0.0.1:10808 (disable PAC/WPAD and save original settings first)"))
		a.println("[2] " + a.msg("恢复并验证：还原配置前的系统代理", "Restore and verify: restore the system proxy saved before configuration"))
	} else {
		a.println("[1] " + a.msg("配置并验证：HTTP/HTTPS → 127.0.0.1:10808", "Configure and verify: HTTP/HTTPS -> 127.0.0.1:10808"))
		a.println("[2] " + a.msg("撤销并验证：删除三个环境变量", "Remove and verify: delete all three environment variables"))
	}
	a.println("[3] " + a.msg("只查看当前状态", "Inspect current status only"))
	a.println("[0] " + a.msg("返回主菜单", "Return to the main menu"))
	for {
		choice := strings.ToLower(strings.TrimSpace(a.prompt(a.msg("请选择本地操作", "Choose local action"))))
		if a.inputClosed {
			return nil
		}
		switch choice {
		case "1":
			return a.configureLocalProxy()
		case "2":
			return a.removeLocalProxy()
		case "3":
			return a.showLocalProxyStatus()
		case "0", "q":
			return nil
		default:
			a.println(a.msg("请输入 1、2、3 或 0。", "Enter 1, 2, 3, or 0."))
		}
	}
}
