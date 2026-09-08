package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type ProcessResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
	Err      error
}

// Keep non-interactive SSH bounded even when the remote host accepts a TCP
// socket but never completes its banner or authentication exchange.  The
// latter happens intermittently on public SSH endpoints under scanner load;
// an unbounded child used to leave the native workspace stuck at “运行中”.
const (
	capturedOpenSSHTimeout = 30 * time.Second
	// Password hand-off must leave enough time for a real human response and
	// for a busy VPS, while still guaranteeing that a dead ssh child cannot
	// strand the GUI forever.
	interactiveOpenSSHTimeout = 5 * time.Minute
	streamingOpenSSHTimeout   = 15 * time.Minute
	openSSHRetryDelay         = 1200 * time.Millisecond
)

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

func runCapturedAttempt(name string, args []string, stdin []byte, hidden bool) ProcessResult {
	commandPath := managedCommandPath(name)
	// A non-interactive SSH/SCP request must never wait forever after TCP has
	// connected.  This is especially important for key verification: an
	// sshd that accepts the socket but stalls during authentication used to
	// leave the GUI's operation in “运行中” indefinitely.  Interactive password
	// installation continues to use runInteractiveSSH and is intentionally not
	// covered by this deadline.
	var ctx context.Context
	var cancel context.CancelFunc
	if isCapturedOpenSSH(name) {
		ctx, cancel = context.WithTimeout(context.Background(), capturedOpenSSHTimeout)
		defer cancel()
	} else {
		ctx = context.Background()
	}
	cmd := exec.CommandContext(ctx, commandPath, args...)
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
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		message := fmt.Sprintf("OpenSSH command timed out after %s", capturedOpenSSHTimeout)
		if stderr.Len() > 0 {
			stderr.WriteString("\n")
		}
		stderr.WriteString(message)
		if err == nil {
			err = context.DeadlineExceeded
		}
	}
	return ProcessResult{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: exitCode(err),
		Err:      err,
	}
}

// retryableOpenSSHFailure identifies transport failures that happen before a
// command has authenticated.  A single delayed retry is enough to ride out a
// transient banner/kex drop without recreating the old burst of speculative
// TCP probes. Authentication failures and remote command failures are returned
// immediately and are never retried.
func retryableOpenSSHFailure(name string, result ProcessResult) bool {
	logical := strings.ToLower(strings.TrimSuffix(filepath.Base(strings.TrimSpace(name)), ".exe"))
	if logical != "ssh" && logical != "scp" {
		return false
	}
	if result.OK() {
		return false
	}
	detail := strings.ToLower(result.Stderr + "\n" + result.Stdout)
	for _, marker := range []string{
		"connection timed out during banner exchange",
		"connection timed out",
		"operation timed out",
		"kex_exchange_identification",
		"connection reset by peer",
		"connection reset by remote host",
		"connection closed by remote host",
		"connection refused",
		"no route to host",
		"network is unreachable",
	} {
		if strings.Contains(detail, marker) {
			return true
		}
	}
	return false
}

func runCaptured(name string, args []string, stdin []byte, hidden bool) ProcessResult {
	result := runCapturedAttempt(name, args, stdin, hidden)
	// A command carrying a ControlPath (or an explicit -S socket) belongs to
	// an already-established per-action SSH lifecycle. Retrying it would ask
	// the master for another session, and if that master has just disappeared
	// OpenSSH can fall back to a fresh TCP login. On a VPS with fail2ban or a
	// tight MaxStartups policy that second speculative login is exactly what
	// turns a transient banner drop into a source-IP ban. The caller can report
	// the bounded first failure and decide whether a new action should be
	// started explicitly.
	// The first command of an action carries a ControlPath before the master
	// exists.  A transient KEX/banner drop at that exact point leaves no socket
	// to reuse, so one delayed retry is safe and materially improves reliability
	// on busy public sshd endpoints.  Once a socket exists (or for -O control
	// requests) never retry: a second invocation could silently create a new
	// TCP login and defeat the action's single-session guarantee.
	if (hasControlSocketArgs(args) && !initialControlSocketRetryAllowed(args)) || !retryableOpenSSHFailure(name, result) {
		return result
	}
	prepareControlSocketRetry(args)
	time.Sleep(openSSHRetryDelay)
	retry := runCapturedAttempt(name, args, stdin, hidden)
	if retry.OK() || result.OK() {
		return retry
	}
	// Preserve the first transport diagnostic when both attempts failed; it is
	// often the only clue that the remote endpoint dropped the initial banner.
	first := clipFailureText(sanitizeSSHStderr(result.Stderr))
	if first != "" {
		if retry.Stderr != "" {
			retry.Stderr = "first attempt: " + first + "\n" + retry.Stderr
		} else {
			retry.Stderr = "first attempt: " + first
		}
	}
	return retry
}

func hasControlSocketArgs(args []string) bool {
	for index, arg := range args {
		trimmed := strings.TrimSpace(arg)
		if trimmed == "-S" || strings.HasPrefix(trimmed, "-oControlPath=") {
			return true
		}
		// Accept the compact `-oControlPath=...` form above and the split
		// `-o`, `ControlPath=...` form used by sshBase. Keep the index check
		// explicit so an unrelated remote command containing the word
		// ControlPath cannot disable retries accidentally.
		if trimmed == "-o" && index+1 < len(args) && strings.HasPrefix(strings.TrimSpace(args[index+1]), "ControlPath=") {
			return true
		}
	}
	return false
}

// initialControlSocketRetryAllowed reports whether args describe the first
// multiplexed command of an action.  It is deliberately conservative:
// control protocol requests (-O), explicit master management (-M), and
// disabled multiplexing are never retried.  A per-action socket that was
// created by the first attempt is deliberately *not* an automatic veto:
// OpenSSH can leave a half-open socket behind while its master is still
// negotiating.  The one retry below first probes that local socket.  A live
// socket is reused; a stale socket is removed only when it belongs to our
// private pna-ssh-* directory, then the same command is allowed to create a
// fresh master.  This fixes the macOS banner-timeout state without opening a
// speculative third connection.
func initialControlSocketRetryAllowed(args []string) bool {
	path, found := controlSocketPath(args)
	if !found || strings.TrimSpace(path) == "" || strings.EqualFold(strings.TrimSpace(path), "none") {
		return false
	}
	for index, arg := range args {
		trimmed := strings.TrimSpace(arg)
		if trimmed == "-O" || trimmed == "-M" || strings.HasPrefix(trimmed, "-O") {
			return false
		}
		if trimmed == "-o" && index+1 < len(args) {
			option := strings.ToLower(strings.TrimSpace(args[index+1]))
			if option == "controlmaster=no" || strings.HasPrefix(option, "controlmaster=no=") {
				return false
			}
		}
		if strings.HasPrefix(strings.ToLower(trimmed), "-ocontrolmaster=no") {
			return false
		}
	}
	return true
}

// prepareControlSocketRetry handles the only local state that can make the
// first multiplexed SSH command unrecoverable: a dead socket file left by a
// timed-out OpenSSH master.  It never sends a network request and never
// removes a path outside the private directory created by newSSHControlPath.
func prepareControlSocketRetry(args []string) {
	if runtime.GOOS == "windows" {
		return
	}
	path, found := controlSocketPath(args)
	if !found || !managedControlSocketPath(path) {
		return
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return
	}
	if info.Mode()&os.ModeSocket != 0 && controlSocketAlive(path) {
		// The master is alive; the retry will attach to it and will not create a
		// second TCP handshake.
		return
	}
	// A regular file or a Unix socket that no longer accepts a local connection
	// is stale. Ignore an unlink race: OpenSSH will report the actual failure if
	// another process owns the path.
	_ = os.Remove(path)
}

func managedControlSocketPath(path string) bool {
	clean := filepath.Clean(strings.TrimSpace(path))
	if clean == "." || filepath.Base(clean) != "c" {
		return false
	}
	parent := filepath.Base(filepath.Dir(clean))
	if !strings.HasPrefix(parent, "pna-ssh-") {
		return false
	}
	for _, base := range []string{"/tmp", os.TempDir()} {
		if base == "" {
			continue
		}
		root := filepath.Clean(base)
		if clean == root || strings.HasPrefix(clean, root+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func controlSocketAlive(path string) bool {
	if runtime.GOOS == "windows" {
		return false
	}
	conn, err := net.DialTimeout("unix", path, 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func controlSocketPath(args []string) (string, bool) {
	for index, arg := range args {
		trimmed := strings.TrimSpace(arg)
		if trimmed == "-S" && index+1 < len(args) {
			return strings.TrimSpace(args[index+1]), true
		}
		if strings.HasPrefix(trimmed, "-oControlPath=") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "-oControlPath=")), true
		}
		if trimmed == "-o" && index+1 < len(args) {
			option := strings.TrimSpace(args[index+1])
			if strings.HasPrefix(option, "ControlPath=") {
				return strings.TrimSpace(strings.TrimPrefix(option, "ControlPath=")), true
			}
		}
	}
	return "", false
}

func isCapturedOpenSSH(name string) bool {
	logical := strings.ToLower(strings.TrimSpace(name))
	if strings.HasSuffix(logical, ".exe") {
		logical = strings.TrimSuffix(logical, ".exe")
	}
	return logical == "ssh" || logical == "scp" || logical == "ssh-keyscan"
}

func runStreaming(name string, args []string, stdin io.Reader, hidden bool) ProcessResult {
	ctx, cancel := context.WithTimeout(context.Background(), streamingOpenSSHTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, managedCommandPath(name), args...)
	if hidden || os.Getenv("PNA_GUI_MODE") == "1" {
		hideChildWindow(cmd)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = io.MultiWriter(os.Stdout, &stdout)
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderr)
	cmd.Stdin = stdin
	err := cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		fmt.Fprintf(os.Stderr, "OpenSSH streaming command timed out after %s\n", streamingOpenSSHTimeout)
		err = ctx.Err()
	}
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
	ctx, cancel := context.WithTimeout(context.Background(), interactiveOpenSSHTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, managedCommandPath(name), args...)
	if os.Getenv("PNA_GUI_MODE") == "1" {
		hideChildWindow(cmd)
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		// stderr is the PTY in GUI mode, so this marker is visible in the same
		// log stream and tells the user why the operation stopped.
		fmt.Fprintf(os.Stderr, "OpenSSH interactive command timed out after %s\n", interactiveOpenSSHTimeout)
		err = ctx.Err()
	}
	return ProcessResult{
		ExitCode: exitCode(err),
		Err:      err,
	}
}
