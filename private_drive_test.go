package main

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

func TestDrivePasswordGeneratorUsesPortableHighEntropyAlphabet(t *testing.T) {
	first, err := randomDrivePassword()
	if err != nil {
		t.Fatal(err)
	}
	second, err := randomDrivePassword()
	if err != nil {
		t.Fatal(err)
	}
	if first == second || len(first) < 32 || !drivePasswordPattern.MatchString(first) {
		t.Fatalf("unexpected generated drive credential shape: length=%d duplicate=%v", len(first), first == second)
	}
}

func TestSecretPromptExactPreservesSpacesAndOnlyDropsLineEnding(t *testing.T) {
	t.Setenv("PNA_GUI_MODE", "1")
	app := &App{reader: bufio.NewReader(strings.NewReader("  keep both sides  \r\n")), lang: LangEN}
	if got := app.secretPromptExact("fixture"); got != "  keep both sides  " {
		t.Fatalf("secret was normalized: %q", got)
	}
}

func TestCopypartyOriginIsPinnedLoopbackOnlyAndHasBoundedStorage(t *testing.T) {
	drivePath := "runbook/proxy-runbook-v0.9.5/linux/29-copyparty-drive.sh"
	templatePath := "runbook/proxy-runbook-v0.9.5/templates/copyparty/copyparty.conf.in"
	unitPath := "runbook/proxy-runbook-v0.9.5/templates/systemd/proxy-node-assistant-copyparty.service"
	for path, required := range map[string][]string{
		drivePath: {
			"pna_download_copyparty_pinned", "PNA_DRIVE_CREDENTIAL_CRUD_OK", "127.0.0.1:3923",
			"PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED", "uninstall-preserve", "purge PURGE-DATA",
			"PNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK", "rollback_config_and_state",
		},
		templatePath: {
			"i: 127.0.0.1", "p: 3923", "usernames", "ah-alg: scrypt", "e2ds",
			"u2sz: 1,64,64", "vmaxb: @QUOTA_GIB@g", "vmaxn: 100k", "df: @MIN_FREE_BYTES@b",
			"nohtml", "no_logues", "no_readme", "xvol", "xdev",
		},
		unitPath: {
			"PNA_MANAGED_COPYPARTY_SYSTEMD_V095",
			"User=copyparty", "Group=copyparty", "NoNewPrivileges=true", "ProtectSystem=strict",
			"ReadWritePaths=/srv/proxy-node-assistant/drive-data",
		},
	} {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		text := string(body)
		for _, marker := range required {
			if !strings.Contains(text, marker) {
				t.Fatalf("%s is missing %q", path, marker)
			}
		}
	}
	config, _ := os.ReadFile(templatePath)
	for _, forbidden := range []string{"i: 0.0.0.0", "r: *", "w: *", "COPYPARTY_PASSWORD", "@ACCOUNT_PASSWORD@"} {
		if strings.Contains(string(config), forbidden) {
			t.Fatalf("copyparty template contains unsafe pattern %q", forbidden)
		}
	}
}

func TestPrivateDriveSecretsUseStdinNotRemoteArguments(t *testing.T) {
	goSource, err := os.ReadFile("private_drive.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(goSource)
	for _, required := range []string{"rootCaptureWithInput", `[]byte(password+"\n")`, "PRIVATE_DRIVE_PUBLIC_URL=PENDING_CLOUDFLARE_ORIGIN_RULE"} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows private-drive flow is missing %q", required)
		}
	}
	android, err := os.ReadFile("android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{`"21" ->`, "stdinBytes = (password + \"\\n\").toByteArray()", "PRIVATE_DRIVE_CREDENTIAL_HANDOFF_READY"} {
		if !strings.Contains(string(android), required) {
			t.Fatalf("Android private-drive flow is missing %q", required)
		}
	}
}
