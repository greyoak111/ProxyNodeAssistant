package main

import (
	"fmt"
	"sort"
	"strings"
)

// RouteMode is deliberately small and explicit. Unknown values are rejected;
// they are never silently treated as the recommended route.
type RouteMode string

const (
	RouteKeep   RouteMode = "keep"
	RouteGray   RouteMode = "gray"
	RouteOrange RouteMode = "orange"
	RouteDual   RouteMode = "dual"
)

type PerformanceMode string

const (
	PerformancePreserve PerformanceMode = "preserve"
	PerformanceAuto     PerformanceMode = "auto"
	PerformanceLow      PerformanceMode = "low"
	PerformanceStandard PerformanceMode = "standard"
	PerformanceHigh     PerformanceMode = "high"
)

type WarpMode string

const (
	WarpPreserve WarpMode = "preserve"
	WarpEnsureOn WarpMode = "ensure-on"
)

// PortPlan is a coordinated preset. Until every remote component consumes
// these values centrally, v0.9.5 accepts only this proven combination.
type PortPlan struct {
	RealityProduction int `json:"realityProduction"`
	RealityShadow     int `json:"realityShadow"`
	CDNEdgeOrigin     int `json:"cdnEdgeOrigin"`
	WarpLoopback      int `json:"warpLoopback"`
}

type RouteIdentity struct {
	Domain string `json:"-"`
	Email  string `json:"-"`
}

// InstallPreferences are safe to persist locally. They intentionally contain
// no host, domain, email, account, password, token, or private-key material.
type InstallPreferences struct {
	RouteMode          RouteMode       `json:"routeMode"`
	CoverChoice        string          `json:"coverChoice"`
	Performance        PerformanceMode `json:"performance"`
	WarpMode           WarpMode        `json:"warpMode"`
	BackupBeforeChange bool            `json:"backupBeforeChange"`
	PruneAfterSuccess  bool            `json:"pruneAfterSuccess"`
	OpenPanelOnSuccess bool            `json:"openPanelOnSuccess"`
}

// InstallPlan exists only for the current run. Route identities are excluded
// from JSON so an accidental settings serialization cannot retain them.
type InstallPlan struct {
	Preferences InstallPreferences `json:"preferences"`
	Ports       PortPlan           `json:"ports"`
	Gray        RouteIdentity      `json:"-"`
	Orange      RouteIdentity      `json:"-"`
}

func defaultInstallPreferences() InstallPreferences {
	return InstallPreferences{
		RouteMode:          RouteGray,
		CoverChoice:        "random",
		Performance:        PerformanceAuto,
		WarpMode:           WarpEnsureOn,
		BackupBeforeChange: true,
		PruneAfterSuccess:  false,
		OpenPanelOnSuccess: true,
	}
}

func defaultPortPlan() PortPlan {
	return PortPlan{
		RealityProduction: 443,
		RealityShadow:     24443,
		CDNEdgeOrigin:     8443,
		WarpLoopback:      40000,
	}
}

func defaultInstallPlan() InstallPlan {
	return InstallPlan{Preferences: defaultInstallPreferences(), Ports: defaultPortPlan()}
}

func validRouteMode(value RouteMode) bool {
	switch value {
	case RouteKeep, RouteGray, RouteOrange, RouteDual:
		return true
	default:
		return false
	}
}

func validPerformanceMode(value PerformanceMode) bool {
	switch value {
	case PerformancePreserve, PerformanceAuto, PerformanceLow, PerformanceStandard, PerformanceHigh:
		return true
	default:
		return false
	}
}

func validWarpMode(value WarpMode) bool {
	switch value {
	case WarpPreserve, WarpEnsureOn:
		return true
	default:
		return false
	}
}

func (p PortPlan) validate() error {
	recommended := defaultPortPlan()
	if p != recommended {
		return fmt.Errorf("unsupported coordinated port plan: got reality=%d shadow=%d cdn=%d warp=%d; supported preset is 443/24443/8443/40000",
			p.RealityProduction, p.RealityShadow, p.CDNEdgeOrigin, p.WarpLoopback)
	}
	return nil
}

func (p InstallPlan) validateFor(existingNode bool) error {
	if !validRouteMode(p.Preferences.RouteMode) {
		return fmt.Errorf("unsupported route mode %q", p.Preferences.RouteMode)
	}
	if _, ok := normalizeCoverTemplateChoice(p.Preferences.CoverChoice); !ok && strings.ToLower(strings.TrimSpace(p.Preferences.CoverChoice)) != "preserve" {
		return fmt.Errorf("unsupported cover choice %q", p.Preferences.CoverChoice)
	}
	if !validPerformanceMode(p.Preferences.Performance) {
		return fmt.Errorf("unsupported performance mode %q", p.Preferences.Performance)
	}
	if !validWarpMode(p.Preferences.WarpMode) {
		return fmt.Errorf("unsupported WARP mode %q", p.Preferences.WarpMode)
	}
	if p.Preferences.RouteMode == RouteKeep && !existingNode {
		return fmt.Errorf("keep route mode is available only for an existing managed node")
	}
	if !p.Preferences.BackupBeforeChange {
		return fmt.Errorf("backup-before-change cannot be disabled in v0.9.5")
	}
	if err := p.Ports.validate(); err != nil {
		return err
	}
	if p.Preferences.RouteMode == RouteKeep {
		return nil
	}
	if p.Preferences.RouteMode != RouteOrange {
		if !validDomain(p.Gray.Domain) || !validEmail(p.Gray.Email) {
			return fmt.Errorf("gray route requires a valid human-entered domain and email")
		}
	}
	if p.Preferences.RouteMode != RouteGray {
		if !validDomain(p.Orange.Domain) || !validEmail(p.Orange.Email) {
			return fmt.Errorf("orange route requires a valid human-entered domain and email")
		}
	}
	if p.Preferences.RouteMode == RouteDual && strings.EqualFold(p.Gray.Domain, p.Orange.Domain) {
		return fmt.Errorf("dual route requires two different hostnames")
	}
	return nil
}

func (p InstallPlan) validate() error {
	return p.validateFor(false)
}

func maskEmail(value string) string {
	value = strings.TrimSpace(value)
	parts := strings.SplitN(value, "@", 2)
	if len(parts) != 2 || parts[0] == "" {
		return "***"
	}
	visible := string([]rune(parts[0])[:1])
	return visible + "***@" + parts[1]
}

// reviewLines is an ephemeral, user-facing confirmation view. It may show
// route hostnames because the user must verify them, but it masks ACME email
// local-parts and must never be written to settings or logs automatically.
func (p InstallPlan) reviewLines() []string {
	values := []string{
		"ROUTE_MODE=" + string(p.Preferences.RouteMode),
		"COVER_CHOICE=" + p.Preferences.CoverChoice,
		"PERFORMANCE=" + string(p.Preferences.Performance),
		"WARP_MODE=" + string(p.Preferences.WarpMode),
		fmt.Sprintf("BACKUP_BEFORE_CHANGE=%t", p.Preferences.BackupBeforeChange),
		fmt.Sprintf("PRUNE_AFTER_SUCCESS=%t", p.Preferences.PruneAfterSuccess),
		fmt.Sprintf("OPEN_PANEL_ON_SUCCESS=%t", p.Preferences.OpenPanelOnSuccess),
		fmt.Sprintf("PORT_PRESET=reality:%d shadow:%d cdn:%d warp:%d", p.Ports.RealityProduction, p.Ports.RealityShadow, p.Ports.CDNEdgeOrigin, p.Ports.WarpLoopback),
	}
	if p.Preferences.RouteMode != RouteKeep && p.Preferences.RouteMode != RouteOrange {
		values = append(values, "GRAY_DOMAIN="+p.Gray.Domain, "GRAY_EMAIL="+maskEmail(p.Gray.Email))
	}
	if p.Preferences.RouteMode != RouteKeep && p.Preferences.RouteMode != RouteGray {
		values = append(values, "ORANGE_DOMAIN="+p.Orange.Domain, "ORANGE_EMAIL="+maskEmail(p.Orange.Email))
	}
	sort.Strings(values)
	return values
}

// preferenceSummaryLines is safe for diagnostics because it deliberately
// excludes domains, email addresses, hosts, users, and all secret material.
func (p InstallPlan) preferenceSummaryLines() []string {
	values := []string{
		"PLAN_ROUTE=" + string(p.Preferences.RouteMode),
		"PLAN_COVER=" + p.Preferences.CoverChoice,
		"PLAN_PERFORMANCE=" + string(p.Preferences.Performance),
		"PLAN_WARP=" + string(p.Preferences.WarpMode),
		fmt.Sprintf("PLAN_PRUNE=%t", p.Preferences.PruneAfterSuccess),
		fmt.Sprintf("PLAN_OPEN_PANEL=%t", p.Preferences.OpenPanelOnSuccess),
		fmt.Sprintf("PORT_PRESET=%d/%d/%d/%d", p.Ports.RealityProduction, p.Ports.RealityShadow, p.Ports.CDNEdgeOrigin, p.Ports.WarpLoopback),
	}
	sort.Strings(values)
	return values
}
