package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
)

type ProcessResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
	Err      error
}

func (r ProcessResult) OK() bool {
	return r.Err == nil && r.ExitCode == 0
}

func clipFailureText(value string) string {
	const maxRunes = 4000
	text := strings.TrimSpace(stripANSI(value))
	runes := []rune(text)
	if len(runes) <= maxRunes {
		return text
	}
	return "…" + string(runes[len(runes)-maxRunes:])
}

func processFailureDetail(result ProcessResult) string {
	stderr := clipFailureText(sanitizeSSHStderr(result.Stderr))
	stdout := clipFailureText(result.Stdout)
	switch {
	case stderr != "" && stdout != "":
		return "stderr:\n" + stderr + "\nstdout:\n" + stdout
	case stderr != "":
		return stderr
	case stdout != "":
		return stdout
	default:
		return "remote command returned no diagnostic output"
	}
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

func runCaptured(name string, args []string, stdin []byte, hidden bool) ProcessResult {
	cmd := exec.Command(managedCommandPath(name), args...)
	if hidden {
		hideChildWindow(cmd)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	err := cmd.Run()
	return ProcessResult{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: exitCode(err),
		Err:      err,
	}
}

func runStreaming(name string, args []string, stdin io.Reader, hidden bool) ProcessResult {
	cmd := exec.Command(managedCommandPath(name), args...)
	if hidden || guiModeEnabled() {
		hideChildWindow(cmd)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = io.MultiWriter(os.Stdout, &stdout)
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderr)
	cmd.Stdin = stdin
	err := cmd.Run()
	return ProcessResult{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: exitCode(err),
		Err:      err,
	}
}

// runInteractiveSSH preserves OpenSSH's interactive authentication behavior.
// In the WPF client SSH_ASKPASS is forced and the child remains hidden, so the
// password crosses only the per-run current-user named pipe. CLI compatibility
// mode continues to inherit its caller's standard streams.
func runInteractiveSSH(name string, args []string) ProcessResult {
	cmd := exec.Command(managedCommandPath(name), args...)
	if guiModeEnabled() {
		hideChildWindow(cmd)
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	return ProcessResult{
		ExitCode: exitCode(err),
		Err:      err,
	}
}
