package main

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strings"
)

// DeploymentMode is persisted in local/remote state. Values are protocol
// identifiers: do not translate or silently coerce unknown values.
type DeploymentMode string

const (
	DeploymentDirectReality DeploymentMode = "direct-reality"
	DeploymentCDNXHTTPTLS   DeploymentMode = "cdn-xhttp-tls"
	DeploymentDualHotSwitch DeploymentMode = "dual-hot-switch"
)

type DeploymentState string

const (
	StateActiveDirect                     DeploymentState = "ACTIVE_DIRECT"
	StateActiveCDN                        DeploymentState = "ACTIVE_CDN"
	StateCDNStaged8443                    DeploymentState = "CDN_STAGED_8443"
	StateWaitingForCloudflareManualAction DeploymentState = "WAITING_FOR_CLOUDFLARE_MANUAL_ACTION"
	StateDualInstalledActiveDirect        DeploymentState = "DUAL_INSTALLED_ACTIVE_DIRECT"
	StateDualInstalledActiveCDN           DeploymentState = "DUAL_INSTALLED_ACTIVE_CDN"
	StateSwitchToCDNStaged8443            DeploymentState = "SWITCH_TO_CDN_STAGED_8443"
	StateSwitchToCDNPort443Committing     DeploymentState = "SWITCH_TO_CDN_PORT_443_COMMITTING"
	StateSwitchToDirectStaged24443        DeploymentState = "SWITCH_TO_DIRECT_STAGED_24443"
	StateSwitchToDirectPort443Committing  DeploymentState = "SWITCH_TO_DIRECT_PORT_443_COMMITTING"
)

var handoffAppendixKeyPattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)

func parseDeploymentMode(value string) (DeploymentMode, error) {
	mode := DeploymentMode(strings.TrimSpace(value))
	switch mode {
	case DeploymentDirectReality, DeploymentCDNXHTTPTLS, DeploymentDualHotSwitch:
		return mode, nil
	default:
		return "", fmt.Errorf("unsupported deployment mode %q", value)
	}
}

func deploymentNeedsCloudflareProxy(mode DeploymentMode) bool {
	return mode == DeploymentCDNXHTTPTLS || mode == DeploymentDualHotSwitch
}

func canTransitionDeploymentState(from, to DeploymentState) bool {
	if from == to {
		return true
	}
	allowed := map[DeploymentState]map[DeploymentState]bool{
		StateActiveDirect: {
			StateCDNStaged8443:             true,
			StateDualInstalledActiveDirect: true,
		},
		StateCDNStaged8443: {
			StateWaitingForCloudflareManualAction: true,
			StateActiveDirect:                     true,
		},
		StateWaitingForCloudflareManualAction: {
			StateActiveDirect:              true,
			StateSwitchToCDNStaged8443:     true,
			StateSwitchToDirectStaged24443: true,
			StateDualInstalledActiveDirect: true,
			StateDualInstalledActiveCDN:    true,
		},
		StateDualInstalledActiveDirect: {
			StateSwitchToCDNStaged8443: true,
		},
		StateSwitchToCDNStaged8443: {
			StateWaitingForCloudflareManualAction: true,
			StateDualInstalledActiveDirect:        true,
			StateSwitchToCDNPort443Committing:     true,
		},
		StateSwitchToCDNPort443Committing: {
			StateDualInstalledActiveCDN:    true,
			StateDualInstalledActiveDirect: true,
		},
		StateActiveCDN: {
			StateSwitchToDirectStaged24443: true,
			StateDualInstalledActiveCDN:    true,
		},
		StateDualInstalledActiveCDN: {
			StateSwitchToDirectStaged24443: true,
		},
		StateSwitchToDirectStaged24443: {
			StateWaitingForCloudflareManualAction: true,
			StateDualInstalledActiveCDN:           true,
			StateSwitchToDirectPort443Committing:  true,
		},
		StateSwitchToDirectPort443Committing: {
			StateDualInstalledActiveDirect: true,
			StateDualInstalledActiveCDN:    true,
		},
	}
	return allowed[from][to]
}

// appendCompleteHandoff is deliberately append-only. The legacy bytes are
// already validated by validateHandoff and are copied byte-for-byte before any
// v0.9.5 field is rendered. Unknown legacy fields and repeated client entries
// therefore survive future upgrades.
func appendCompleteHandoff(legacy string, fields map[string]string) (string, error) {
	if legacy == "" {
		return "", errors.New("legacy handoff is empty")
	}
	if strings.ContainsRune(legacy, '\x00') {
		return "", errors.New("legacy handoff contains a NUL byte")
	}
	keys := make([]string, 0, len(fields))
	for key, value := range fields {
		if !handoffAppendixKeyPattern.MatchString(key) {
			return "", fmt.Errorf("invalid handoff appendix key %q", key)
		}
		if strings.ContainsAny(value, "\r\n\x00") {
			return "", fmt.Errorf("handoff appendix value %s contains a line break or NUL", key)
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var output strings.Builder
	output.Grow(len(legacy) + 128 + len(fields)*48)
	output.WriteString(legacy)
	output.WriteString("\n\n===== PNA COMPLETE HANDOFF v0.9.5 =====\n")
	for _, key := range keys {
		output.WriteString(key)
		output.WriteByte('=')
		output.WriteString(fields[key])
		output.WriteByte('\n')
	}
	output.WriteString("===== END PNA COMPLETE HANDOFF v0.9.5 =====")
	return output.String(), nil
}

func (a *App) buildCompleteHandoff(legacy string, c Connection) (string, error) {
	auth := "MANAGED_KEY"
	if c.AuthMode == AuthTemporaryPassword {
		auth = "TEMPORARY_PASSWORD_ONE_RUN"
	}
	fields := map[string]string{
		"PNA_VERSION":         version,
		"SSH_AUTH_MODE":       auth,
		"SSH_KEY_ONLY":        fmt.Sprintf("%t", c.AuthMode == AuthManagedKey),
		"VPS_SSH_USER":        c.User,
		"VPS_SSH_PORT":        fmt.Sprintf("%d", c.Port),
		"VPS_PASSWORD_STATUS": "NOT_RETAINED_BY_APPLICATION",
	}
	if c.AuthMode == AuthManagedKey {
		fields["VPS_PASSWORD_STATUS"] = "SSH_KEY_ONLY"
		fields["SSH_PRIVATE_KEY_FILE"] = c.KeyPath
		if keyID, err := sshAuthenticationKeyID(c.KeyPath); err == nil {
			fields["SSH_AUTH_KEY_ID"] = keyID
		}
	}
	if runtime, err := a.runtimePublicEnv(c); err == nil {
		if ip := strings.TrimSpace(runtime["PUBLIC_IP"]); net.ParseIP(ip) != nil {
			fields["VPS_PUBLIC_IP"] = ip
		}
		if domain := strings.TrimSpace(runtime["COVER_DOMAIN"]); validDomain(domain) {
			fields["CONSTRUCTION_DOMAIN"] = domain
		}
	}
	stateResult := a.rootCapture(c, "cat /etc/proxy-runbook/deployment-state.env 2>/dev/null || true")
	state := parseKV(stateResult.Stdout)
	mode := state["DEPLOYMENT_MODE"]
	active := state["ACTIVE_MODE"]
	if _, err := parseDeploymentMode(mode); err != nil {
		mode = string(DeploymentDirectReality)
	}
	if active == "" {
		active = string(StateActiveDirect)
	}
	fields["DEPLOYMENT_MODE"] = mode
	fields["ACTIVE_MODE"] = active
	fields["CURRENT_ORIGIN_CONCEALED"] = "false"
	fields["ORIGIN_HISTORY"] = state["ORIGIN_HISTORY"]
	if fields["ORIGIN_HISTORY"] == "" {
		fields["ORIGIN_HISTORY"] = "unknown"
	}
	fields["V095_CDN_STATUS"] = "NOT_CONFIGURED"
	fields["V095_PHASE_STATUS"] = "DIRECT_COMPATIBILITY_BASELINE"
	if mode != string(DeploymentDirectReality) {
		fields["V095_CDN_STATUS"] = active
		fields["V095_PHASE_STATUS"] = "EXPERIMENTAL_STAGED_NOT_PUBLICLY_PROMOTED"
	}
	if identity, err := a.fetchNodeIdentity(c); err == nil {
		fields["SERVER_ID"] = identity.ServerID
		fields["NODE_ID"] = identity.NodeID
		fields["MACHINE_ID_SHA256"] = identity.MachineIDHash
		fields["SSH_HOST_KEY_SHA256"] = identity.HostKeySHA256
		fields["FIRST_KNOWN_PUBLIC_IP"] = identity.FirstPublicIP
		fields["CURRENT_PUBLIC_IP"] = identity.CurrentPublicIP
	}
	if panel, err := a.panelMetadata(c); err == nil {
		fields["PANEL_REMOTE_LOOPBACK_PORT"] = fmt.Sprintf("%d", panel.Port)
		fields["PANEL_LOCAL_URL_TEMPLATE"] = fmt.Sprintf("http://127.0.0.1:<LOCAL_TUNNEL_PORT>%s", panel.Path)
		fields["PANEL_SSH_TUNNEL_COMMAND"] = fmt.Sprintf("ssh -N -L 127.0.0.1:<LOCAL_TUNNEL_PORT>:127.0.0.1:%d -p %d %s@%s", panel.Port, c.Port, c.User, c.Host)
	}
	driveResult := a.rootCapture(c, "bash "+remoteRoot+"/linux/29-copyparty-drive.sh status 2>/dev/null || true")
	drive := parseKV(driveResult.Stdout)
	if drive["PRIVATE_DRIVE_MODE"] == "copyparty" {
		fields["PRIVATE_DRIVE_MODE"] = "copyparty"
		fields["PRIVATE_DRIVE_STATUS"] = drive["PRIVATE_DRIVE_STATUS"]
		fields["PRIVATE_DRIVE_PUBLIC_ACCESS"] = "BLOCKED_PENDING_CLOUDFLARE"
		fields["PRIVATE_DRIVE_WEBDAV_LARGE_FILE_LIMIT"] = "OVER_100MB_NOT_SUPPORTED_VIA_CLOUDFLARE"
	} else {
		fields["PRIVATE_DRIVE_MODE"] = "disabled"
	}
	return appendCompleteHandoff(legacy, fields)
}
