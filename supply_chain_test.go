package main

import (
	"bufio"
	"bytes"
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestWindowsAndAndroidEmbedTheSameToolkitArchive(t *testing.T) {
	windowsArchive, err := os.ReadFile("assets/proxy-runbook-toolkit-v0.9.5.tar.gz")
	if err != nil {
		t.Fatal(err)
	}
	androidArchive, err := os.ReadFile("android/app/src/main/assets/proxy-runbook-toolkit-v0.9.5.tgz")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(windowsArchive, androidArchive) {
		t.Fatal("Windows and Android embed different v0.9.5 toolkit archives")
	}
}

func readPublicEnvFile(t *testing.T, path string) map[string]string {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || key == "" || value == "" {
			t.Fatalf("invalid public lock line %q", line)
		}
		values[key] = value
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return values
}

func TestThirdPartyLockPinsImmutableInputs(t *testing.T) {
	values := readPublicEnvFile(t, "runbook/proxy-runbook-v0.9.5/THIRD_PARTY_LOCK.env")
	if values["THREEXUI_VERSION"] != "v3.6.0" || values["THREEXUI_COMMIT"] != "c377dca27c23549cdf84e0ffd2d287a16bee577c" {
		t.Fatalf("unexpected 3x-ui pin: %#v", values)
	}
	if !strings.Contains(values["THREEXUI_INSTALLER_URL"], values["THREEXUI_COMMIT"]+"/install.sh") {
		t.Fatal("3x-ui installer URL is not pinned to the locked commit")
	}
	if !strings.Contains(values["THREEXUI_SCRIPT_URL"], values["THREEXUI_COMMIT"]+"/x-ui.sh") {
		t.Fatal("3x-ui runtime script URL is not pinned to the locked commit")
	}
	sha := regexp.MustCompile(`^[0-9a-f]{64}$`)
	for key, value := range values {
		if strings.Contains(key, "SHA256") && !sha.MatchString(value) {
			t.Fatalf("%s is not a SHA-256 digest", key)
		}
	}
	if values["COPYPARTY_VERSION"] != "v1.20.21" || !strings.Contains(values["COPYPARTY_SFX_URL"], "/v1.20.21/copyparty-sfx.py") {
		t.Fatal("copyparty SFX is not pinned to its release tag")
	}
}

func TestFreshInstallNeverExecutesMovingThirdPartyURLs(t *testing.T) {
	for _, path := range []string{
		"runbook/proxy-runbook-v0.9.5/linux/00-auto-install-or-optimize.sh",
		"runbook/proxy-runbook-v0.9.5/linux/03-install-3xui.sh",
		"runbook/proxy-runbook-v0.9.5/linux/lib-third-party.sh",
		"runbook/proxy-runbook-v0.9.5/linux/29-copyparty-drive.sh",
	} {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		text := string(body)
		for _, forbidden := range []string{
			"bash <(curl",
			"/master/install.sh",
			"/main/install.sh",
			"releases/latest/download",
		} {
			if strings.Contains(text, forbidden) {
				t.Fatalf("%s still contains moving/unverified install pattern %q", path, forbidden)
			}
		}
	}
}

func TestXHTTPPrototypeIsLoopbackPacketUpAndFailClosed(t *testing.T) {
	body, err := os.ReadFile("runbook/proxy-runbook-v0.9.5/linux/04f-xhttp-cdn-api.sh")
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, required := range []string{
		`listen:"127.0.0.1"`,
		`network:"xhttp"`,
		`security:"none"`,
		`mode:"packet-up"`,
		`fallbacks:[]`,
		"PNA_XHTTP_ERROR=READBACK_MISMATCH",
		"PNA_XHTTP_ERROR=PUBLIC_LISTENER",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("XHTTP prototype is missing %q", required)
		}
	}
}

func TestLocalCDNStageNeverBindsThePublicAddress(t *testing.T) {
	body, err := os.ReadFile("runbook/proxy-runbook-v0.9.5/linux/05e-cdn-xhttp-nginx.sh")
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, required := range []string{
		"stage-local",
		"listen_address='127.0.0.2'",
		"CLOUDFLARE_ORIGIN_LOCK_NOT_APPLIED",
		"^Default: deny (incoming)",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("safe staged Nginx gate is missing %q", required)
		}
	}
}
