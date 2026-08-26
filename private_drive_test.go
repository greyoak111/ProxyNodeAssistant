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
	t.Setenv("TNA_GUI_MODE", "1")
	app := &App{reader: bufio.NewReader(strings.NewReader("  keep both sides  \r\n")), lang: LangEN}
	if got := app.secretPromptExact("fixture"); got != "  keep both sides  " {
		t.Fatalf("secret was normalized: %q", got)
	}
}

func TestCopypartyOriginIsPinnedLoopbackOnlyAndHasBoundedStorage(t *testing.T) {
	drivePath := "runbook/text-node-assistant-v0.9.5/linux/29-copyparty-drive.sh"
	libraryPath := "runbook/text-node-assistant-v0.9.5/linux/lib-drive.sh"
	accountPath := "runbook/text-node-assistant-v0.9.5/linux/30-copyparty-account.sh"
	templatePath := "runbook/text-node-assistant-v0.9.5/templates/copyparty/copyparty.conf.in"
	unitPath := "runbook/text-node-assistant-v0.9.5/templates/systemd/text-node-assistant-copyparty.service"
	for path, required := range map[string][]string{
		drivePath: {
			"install-admin", "rotate-admin", "finalize-install", "DRIVE_REGISTRATION_READY",
			"PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED", "uninstall-preserve", "RESTORE-NATIVE-BASELINE",
		},
		libraryPath: {
			"tna_download_copyparty_pinned", "TNA_DRIVE_CREDENTIAL_CRUD_OK", "seq 39000 39999",
			"TNA_DRIVE_ERROR=TRANSACTION_ROLLED_BACK", "tna_drive_txn_rollback",
			"TNA_DRIVE_ACCOUNT_LIMIT=2", "TNA_DRIVE_LEGACY_DATA_ROOT",
			"systemctl disable --now \"$TNA_DRIVE_SERVICE\"", "systemctl reset-failed \"$TNA_DRIVE_SERVICE\"",
			"systemctl start \"$TNA_DRIVE_SERVICE\"", "invalid password: <redacted>",
		},
		accountPath: {
			"register", "change-password", "pause", "resume", "revoke",
			"TNA_DRIVE_ERROR=DRIVE_ACCOUNT_LIMIT_REACHED current=", "tna_drive_verify_crud",
		},
		templatePath: {
			"i: 127.0.0.1", "p: @LOOPBACK_PORT@", "usernames", "ah-alg: scrypt", "e2ds",
			"u2sz: 1,64,64", "vmaxb: @QUOTA_GIB@g", "vmaxn: 100k", "df: @MIN_FREE_BYTES@b",
			"nohtml", "no_logues", "no_readme", "xvol", "xdev",
		},
		unitPath: {
			"TNA_MANAGED_COPYPARTY_SYSTEMD_V095",
			"User=copyparty", "Group=copyparty", "NoNewPrivileges=true", "ProtectSystem=strict",
			"ReadWritePaths=@DATA_ROOT@",
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
	for _, required := range []string{"rootCaptureWithInput", `[]byte(password+"\n")`, "PRIVATE_DRIVE_ACCESS=SSH_TUNNEL_ONLY_NO_DOMAIN_REQUIRED", "validatedDrivePort"} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows private-drive flow is missing %q", required)
		}
	}
	android, err := os.ReadFile("android/app/src/main/java/com/proxynodeassistant/android/remote/WorkflowRunner.kt")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{`"21" ->`, "prepareMandatoryDrive(handle)", `stdinBytes = "$password\n".toByteArray()`, "DRIVE_ADMIN_STORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT"} {
		if !strings.Contains(string(android), required) {
			t.Fatalf("Android private-drive flow is missing %q", required)
		}
	}
}
