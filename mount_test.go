package main

import (
	"os"
	"strings"
	"testing"
)

func TestWindowsMountSupplyChainAndSecretBoundary(t *testing.T) {
	lockBytes, err := os.ReadFile("runbook/text-node-assistant-v0.9.5/THIRD_PARTY_LOCK.env")
	if err != nil {
		t.Fatal(err)
	}
	lock := string(lockBytes)
	for _, required := range []string{
		"RCLONE_VERSION=v1.75.0",
		"RCLONE_SHA256_386=dee1882a2a4277e42bd8b572b8e0e6676a491e3ec0e238ea16dc0e0e619cdc84",
		"RCLONE_SHA256_AMD64=203581f0a7baeae873f2347483a798c79e2eaf5c384a4e9d866aa374f1c89ac0",
		"RCLONE_SHA256_ARM64=bcf628fa6bb3b6ae9fdf105d04acafb40ec77841f686dc6dd7d126dde04c5f6a",
		"WINFSP_VERSION=2.1.25156",
		"WINFSP_MSI_SHA256=073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a",
	} {
		if !strings.Contains(lock, required) {
			t.Fatalf("mount supply-chain lock is missing %q", required)
		}
	}

	buildBytes, err := os.ReadFile("build.ps1")
	if err != nil {
		t.Fatal(err)
	}
	build := string(buildBytes)
	for _, required := range []string{
		"Get-VerifiedDownload",
		"TextNodeAssistant.Rclone.zip",
		"TextNodeAssistant.WinFsp.msi",
		"System.IO.Compression.FileSystem.dll",
		"--runtime-extraction-smoke",
	} {
		if !strings.Contains(build, required) {
			t.Fatalf("mount build chain is missing %q", required)
		}
	}

	guiBytes, err := os.ReadFile("gui/TextNodeAssistant.DriveShell.cs")
	if err != nil {
		t.Fatal(err)
	}
	gui := string(guiBytes)
	guiCoreBytes, err := os.ReadFile("gui/TextNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	gui += "\n" + string(guiCoreBytes)
	for _, required := range []string{
		"RcloneObscure",
		"RCLONE_CONFIG_TNA_PASS",
		"VerifyRcloneRemote",
		"--read-only --vfs-cache-mode off",
		"--vfs-cache-mode writes --vfs-cache-max-size 512M",
		"MountUsesTunnel",
		"StopDriveMount",
		"Dictionary<Process, StringBuilder> driveSessionDiagnostics",
		"driveSessionDiagnostics.TryGetValue(process",
		"RunRuntimeExtractionSmoke",
		"NO_PROXY",
	} {
		if !strings.Contains(gui, required) {
			t.Fatalf("mount implementation is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"--webdav-pass \" + session.Password",
		"RCLONE_CONFIG_TNA_PASS=\" + session.Password",
		"rclone.conf",
		"driveSessionErrors",
		"--password " + `" + session.Password`,
	} {
		if strings.Contains(gui, forbidden) {
			t.Fatalf("mount implementation leaks a secret through %q", forbidden)
		}
	}
}

func TestWindowsMountIsFullyGraphical(t *testing.T) {
	xamlBytes, err := os.ReadFile("gui/MainWindow.xaml")
	if err != nil {
		t.Fatal(err)
	}
	xaml := string(xamlBytes)
	for _, required := range []string{
		`x:Name="DriveMountPanel"`,
		`x:Name="DriveMountDependencyStatus"`,
		`x:Name="DriveMountLetter"`,
		`x:Name="DriveMountReadOnly"`,
		`x:Name="DriveMountReadWrite"`,
		`x:Name="DriveMountGrid"`,
		`x:Name="DriveUnmountButton"`,
	} {
		if !strings.Contains(xaml, required) {
			t.Fatalf("graphical mount workspace is missing %q", required)
		}
	}
}
