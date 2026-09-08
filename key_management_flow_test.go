package main

import (
	"os"
	"strings"
	"testing"
)

func sourceFunctionBlock(t *testing.T, file, function, next string) string {
	t.Helper()
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	start := strings.Index(text, function)
	if start < 0 {
		t.Fatalf("%s is missing from %s", function, file)
	}
	end := len(text)
	if next != "" {
		if offset := strings.Index(text[start+len(function):], next); offset >= 0 {
			end = start + len(function) + offset
		}
	}
	return text[start:end]
}

func TestKeyManagementLocalSubmenuIsLazyAboutOpenSSH(t *testing.T) {
	if actionNeedsOpenSSH("k") {
		t.Fatal("K dispatch must not run the global OpenSSH preflight")
	}
	block := sourceFunctionBlock(t, "remote.go", "func (a *App) manageBoundKeys()", "func (a *App) showKeyHandoff")
	for _, localChoice := range []string{"listBoundKeys", "listRecoverableKeyBackups", "openManagedKeyFolders", "archiveAllManagedKeys"} {
		if !strings.Contains(block, localChoice) {
			t.Fatalf("K submenu lost local choice %s", localChoice)
		}
	}
	for _, localFunction := range []string{"func (a *App) listBoundKeys()", "func (a *App) listRecoverableKeyBackups()", "func (a *App) archiveAllManagedKeys()", "func (a *App) openManagedKeyFolders()"} {
		functionBlock := sourceFunctionBlock(t, "remote.go", localFunction, "func ")
		if strings.Contains(functionBlock, "ensureOpenSSH()") || strings.Contains(functionBlock, "verifyKey(") || strings.Contains(functionBlock, "sshCapture(") {
			t.Fatalf("local K function %s unexpectedly performs SSH work", localFunction)
		}
	}
}

func TestKeyManagementRemoteBranchesLazyOpenSSHAndUseActionSocket(t *testing.T) {
	unbind := sourceFunctionBlock(t, "remote.go", "func (a *App) unbindManagedKey()", "func (a *App) listBoundKeys()")
	if strings.Index(unbind, "promptConnection(AuthManagedKey)") < 0 || strings.Index(unbind, "ensureOpenSSH()") < strings.Index(unbind, "promptConnection(AuthManagedKey)") {
		t.Fatal("unbind must select a local target before its lazy OpenSSH check")
	}
	if !strings.Contains(unbind, "c.ControlPath = newSSHControlPath()") || !strings.Contains(unbind, "a.actionConnection = &c") {
		t.Fatal("unbind must register a per-action control socket with the shared lifecycle")
	}
	if !strings.Contains(unbind, "a.sshCapture(c, authorizedKeyRemovalCommand") {
		t.Fatal("unbind revocation must run through the authenticated action connection")
	}

	restore := sourceFunctionBlock(t, "remote.go", "func (a *App) restoreManagedKeyBackup()", "func (a *App) openManagedKeyFolders()")
	if strings.HasPrefix(strings.TrimSpace(restore), "func (a *App) restoreManagedKeyBackup() (returnErr error) {\n\tif err := a.ensureOpenSSH()") {
		t.Fatal("restore must not run OpenSSH setup before local backup selection")
	}
	for _, required := range []string{
		"controlPath := newSSHControlPath()",
		"ControlPath: controlPath",
		"a.actionConnection = &backupConnection",
		"a.actionConnection = &temporary",
		"a.sshCapture(restored, \"printf SSH_KEY_OK\")",
		"direct.ExitCode != 255 || !isRecoverableManagedKeyDetail(detail)",
	} {
		if !strings.Contains(restore, required) {
			t.Fatalf("restore is missing lifecycle guard %q", required)
		}
	}
	manage := sourceFunctionBlock(t, "remote.go", "func (a *App) manageBoundKeys()", "func (a *App) showKeyHandoff")
	for _, required := range []string{"return a.runRemoteAction(a.unbindManagedKey)", "return a.runRemoteAction(a.restoreManagedKeyBackup)"} {
		if !strings.Contains(manage, required) {
			t.Fatalf("K remote submenu is missing shared lifecycle wrapper %q", required)
		}
	}
}
