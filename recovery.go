package main

import (
	"errors"
	"fmt"
	"strings"
)

type preservedDriveIdentity struct {
	RegistrySHA256 string
	EscrowSHA256   string
	DevicesSHA256  string
	DataRoot       string
	DataFiles      string
	DataBytes      string
	LoopbackPort   string
}

func (a *App) captureOriginalBaselineBeforeConstruction(c Connection) error {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --capture-baseline")
	if !result.OK() {
		return fmt.Errorf("pre-construction baseline capture failed: %s", processFailureDetail(result))
	}
	accepted := strings.Contains(result.Stdout, "ORIGINAL_BASELINE_CAPTURED_EXACT") ||
		strings.Contains(result.Stdout, "ORIGINAL_BASELINE_ALREADY_CAPTURED") ||
		strings.Contains(result.Stdout, "ORIGINAL_BASELINE_LEGACY_UNCERTAIN")
	if !accepted {
		return errors.New("pre-construction baseline capture returned no accepted evidence")
	}
	a.println(a.msg("[GOOD] 施工前基线已在 NODE_ID、网盘、代理和证书改动之前捕获或验证。", "[GOOD] The pre-construction baseline was captured or verified before NODE_ID, drive, proxy, or certificate changes."))
	return nil
}

func (a *App) capturePreservedDriveIdentity(c Connection) (preservedDriveIdentity, error) {
	command := "set -eu; " +
		"state=/etc/text-node-assistant/private-drive.env; registry=/etc/text-node-assistant/drive-accounts.tsv; devices=/root/.config/text-node-assistant/device-admission-v1/registry.json; escrow=/etc/text-node-assistant/drive-credential-escrow; " +
		"test -s \"$state\"; test -s \"$registry\"; " +
		"data=$(sed -n 's/^DRIVE_DATA_ROOT=//p' \"$state\" | sed -n '1p'); port=$(sed -n 's/^COPYPARTY_LOOPBACK_PORT=//p' \"$state\" | sed -n '1p'); " +
		"case \"$data\" in /srv/text-node-assistant/drive-data|/srv/proxy-node-assistant/drive-data) ;; *) exit 71;; esac; test -d \"$data\"; " +
		"printf 'DRIVE_REGISTRY_SHA256=%s\\n' \"$(sha256sum \"$registry\" | awk '{print $1}')\"; " +
		"if [ -d \"$escrow\" ]; then printf 'DRIVE_ESCROW_SHA256=%s\\n' \"$(find \"$escrow\" -maxdepth 1 -type f -name 'tna-account-*.json' -print0 | sort -z | xargs -0r sha256sum | sha256sum | awk '{print $1}')\"; else printf 'DRIVE_ESCROW_SHA256=ABSENT\\n'; fi; " +
		"if [ -s \"$devices\" ]; then printf 'DEVICE_REGISTRY_SHA256=%s\\n' \"$(sha256sum \"$devices\" | awk '{print $1}')\"; else printf 'DEVICE_REGISTRY_SHA256=ABSENT\\n'; fi; " +
		"printf 'DRIVE_DATA_ROOT=%s\\nCOPYPARTY_LOOPBACK_PORT=%s\\n' \"$data\" \"$port\"; " +
		"printf 'DRIVE_DATA_FILE_COUNT=%s\\n' \"$(find \"$data\" -type f -printf . | wc -c)\"; " +
		"printf 'DRIVE_DATA_FILE_BYTES=%s\\n' \"$(find \"$data\" -type f -printf '%s\\n' | awk '{sum+=$1} END{printf \"%.0f\",sum+0}')\""
	result := a.rootCapture(c, command)
	if !result.OK() {
		return preservedDriveIdentity{}, fmt.Errorf("preserved drive identity capture failed: %s", processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	identity := preservedDriveIdentity{
		RegistrySHA256: values["DRIVE_REGISTRY_SHA256"], EscrowSHA256: values["DRIVE_ESCROW_SHA256"], DevicesSHA256: values["DEVICE_REGISTRY_SHA256"],
		DataRoot: values["DRIVE_DATA_ROOT"], DataFiles: values["DRIVE_DATA_FILE_COUNT"], DataBytes: values["DRIVE_DATA_FILE_BYTES"], LoopbackPort: values["COPYPARTY_LOOPBACK_PORT"],
	}
	if identity.RegistrySHA256 == "" || identity.EscrowSHA256 == "" || identity.DevicesSHA256 == "" || identity.DataRoot == "" || identity.DataFiles == "" || identity.DataBytes == "" || identity.LoopbackPort == "" {
		return preservedDriveIdentity{}, errors.New("preserved drive identity capture returned incomplete evidence")
	}
	return identity, nil
}

func (a *App) inspectInstallRecoveryState(c Connection) (*preservedDriveIdentity, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --status")
	if !result.OK() {
		return nil, fmt.Errorf("recovery-state inspection failed: %s", processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	legal := values["LEGAL_ACTIONS"]
	if legal == "RECOVER_IN_MENU_1" && values["REMOVAL_MODE"] == "PROXY_ONLY" && (values["REMOVAL_STATUS"] == "IN_PROGRESS" || values["REMOVAL_STATUS"] == "FAILED_RECOVERABLE") {
		a.println(a.msg("检测到上次“仅拆代理”事务中断。必须先完成到一致的“仅剩网盘”状态，之后才能重新施工；不会重建或清空网盘。", "The previous proxy-only removal was interrupted. It must first finish at a consistent drive-only state before reinstallation; the drive is not rebuilt or cleared."))
		if !a.yes(a.msg("现在按原拆除目标完成恢复？", "Finish recovery to the originally selected removal target now?"), false) {
			return nil, errors.New(a.msg("拆除恢复尚未完成，菜单 [1] 已停止。", "Removal recovery is incomplete; menu [1] stopped."))
		}
		recover := a.rootCapture(c, "TNA_DISMANTLE_CONFIRM=REMOVE_PROXY_KEEP_DRIVE bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --execute-proxy-only")
		if !recover.OK() || !strings.Contains(recover.Stdout, "NODE_LIFECYCLE_STATE=PROXY_REMOVED_DRIVE_RETAINED") {
			return nil, fmt.Errorf("interrupted proxy-only recovery failed: %s", processFailureDetail(recover))
		}
		result = a.rootCapture(c, "bash "+remoteRoot+"/linux/22-dismantle-managed-node.sh --status")
		values = parseKV(result.Stdout)
		legal = values["LEGAL_ACTIONS"]
	}
	if legal == "REMAINING_DRIVE" && values["NODE_LIFECYCLE_STATE"] == "PROXY_REMOVED_DRIVE_RETAINED" {
		a.println(a.msg("检测到：仅代理已拆除。", "Detected: only the proxy was removed."))
		a.println(a.msg("将保留：网盘文件、admin 空间、普通账号、凭据托管、设备准入、SSH、回环端口与配额。", "Will preserve: drive files, admin space, ordinary accounts, credential escrow, device admission, SSH, loopback port, and quota."))
		a.println(a.msg("将恢复：本次明确选择的代理拓扑及其依赖；不会重建网盘、轮换账号或覆盖设备 ID。", "Will restore: only the explicitly selected proxy topology and dependencies; the drive is not rebuilt, accounts are not rotated, and device IDs are not overwritten."))
		identity, err := a.capturePreservedDriveIdentity(c)
		if err != nil {
			return nil, err
		}
		return &identity, nil
	}
	if legal == "RECOVER_IN_MENU_1" {
		evidenceResult := a.rootCapture(c, "printf 'HAS_DRIVE_STATE='; test -s /etc/text-node-assistant/private-drive.env && echo 1 || echo 0; printf 'HAS_DRIVE_REGISTRY='; test -s /etc/text-node-assistant/drive-accounts.tsv && echo 1 || echo 0; printf 'HAS_DRIVE_DATA='; test -d /srv/text-node-assistant/drive-data && echo 1 || echo 0; printf 'HAS_DRIVE_UNIT='; test -e /etc/systemd/system/text-node-assistant-copyparty.service && echo 1 || echo 0; printf 'HAS_DRIVE_PROGRAM='; test -s /opt/text-node-assistant/copyparty/copyparty-sfx.py && echo 1 || echo 0")
		evidence := parseKV(evidenceResult.Stdout)
		if evidence["HAS_DRIVE_STATE"] == "0" && evidence["HAS_DRIVE_REGISTRY"] == "0" && evidence["HAS_DRIVE_DATA"] == "0" && evidence["HAS_DRIVE_UNIT"] == "0" && evidence["HAS_DRIVE_PROGRAM"] == "0" && values["REMOVAL_STATUS"] == "NONE" {
			a.println(a.msg("检测到旧节点尚未安装强制网盘；菜单 [1] 将把它作为缺失的受管基础组件首次安装，不会触碰已有代理配置以外的用户文件。", "This legacy node has never had the mandatory drive. Menu [1] will install it as a missing managed base component without touching user files outside the managed proxy scope."))
			return nil, nil
		}
		return nil, fmt.Errorf(a.msg("检测到受管组件漂移或不可自动续做的拆除状态：lifecycle=%s removal=%s/%s。为避免覆盖用户数据，本构建拒绝盲目重装。", "Managed-component drift or a non-resumable removal state was detected: lifecycle=%s removal=%s/%s. Blind reinstallation is blocked to protect user data."), values["NODE_LIFECYCLE_STATE"], values["REMOVAL_MODE"], values["REMOVAL_STATUS"])
	}
	return nil, nil
}

func (a *App) verifyPreservedDriveIdentity(c Connection, before *preservedDriveIdentity) error {
	if before == nil {
		return nil
	}
	after, err := a.capturePreservedDriveIdentity(c)
	if err != nil {
		return err
	}
	if *before != after {
		return fmt.Errorf("preserved drive identity changed unexpectedly: before=%+v after=%+v", *before, after)
	}
	a.println(a.msg("[GOOD] 拆除后重建验收：网盘注册表、加密托管、设备表、数据清单和回环端口均保持原对象。", "[GOOD] Post-removal reconstruction check: drive registry, encrypted escrow, device registry, data inventory, and loopback port all remained the original objects."))
	return nil
}
