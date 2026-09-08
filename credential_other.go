//go:build !windows

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

const unixCredentialCommandTimeout = 15 * time.Second

type unixCredentialBackend struct {
	name string
	path string
}

// unixCredentialBackendForCurrentOS resolves the native password-store CLI at
// call time. Resolving lazily lets a user install/enable Secret Service or
// security and retry without restarting ProxyNodeAssistant.
func unixCredentialBackendForCurrentOS() (unixCredentialBackend, error) {
	var (
		command string
		name    string
		help    string
	)
	switch runtime.GOOS {
	case "darwin":
		command = "security"
		name = "macOS Keychain (security)"
		help = "the /usr/bin/security command"
	case "linux":
		command = "secret-tool"
		name = "Linux Secret Service (secret-tool)"
		help = "libsecret's secret-tool and a running Secret Service provider (for example, gnome-keyring or KeePassXC)"
	default:
		return unixCredentialBackend{}, fmt.Errorf("%w: %s has no supported credential backend; use a supported OS or configure credentials another way", errCredentialManagerUnsupported, runtime.GOOS)
	}
	path, err := exec.LookPath(command)
	if err != nil {
		return unixCredentialBackend{}, fmt.Errorf("%w: %s is unavailable; install or enable %s: %v", errCredentialManagerUnsupported, name, help, err)
	}
	return unixCredentialBackend{name: name, path: path}, nil
}

func validateCredentialTarget(target string) error {
	if strings.TrimSpace(target) == "" {
		return errors.New("credential target must not be empty")
	}
	return nil
}

func trimCredentialOutput(output string) string {
	// Both security(1) and secret-tool print one line terminator for a
	// successful lookup. Remove that terminator without stripping meaningful
	// whitespace from the stored value itself.
	if strings.HasSuffix(output, "\n") {
		output = strings.TrimSuffix(output, "\n")
		if strings.HasSuffix(output, "\r") {
			output = strings.TrimSuffix(output, "\r")
		}
	}
	return output
}

func credentialNotFound(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	for _, marker := range []string{
		"not found",
		"could not be found",
		"no such item",
		"no such secret",
		"secitemnotfound",
		"no matching",
	} {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}

// runUnixCredentialCommand keeps secrets off command-line arguments whenever
// the backend supports stdin (secret-tool). The macOS security CLI has no
// documented non-interactive stdin password option, so its store operation is
// handled separately below; reads and deletes never carry secret material.
func runUnixCredentialCommand(backend unixCredentialBackend, args []string, stdin string) (string, error) {
	if len(args) == 0 {
		return "", errors.New("credential command is empty")
	}
	ctx, cancel := context.WithTimeout(context.Background(), unixCredentialCommandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, backend.path, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		return "", fmt.Errorf("%s %s timed out: %w", backend.name, args[0], ctx.Err())
	}
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail != "" {
			return "", fmt.Errorf("%s %s failed: %w: %s", backend.name, args[0], err, detail)
		}
		return "", fmt.Errorf("%s %s failed: %w", backend.name, args[0], err)
	}
	return stdout.String(), nil
}

func credentialWrite(target, userName, secret string) error {
	if err := validateCredentialTarget(target); err != nil {
		return err
	}
	backend, err := unixCredentialBackendForCurrentOS()
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "darwin":
		// `security` documents -w as the password option. It is the only
		// portable way to perform a non-interactive update with this CLI; the
		// value is held only for this short-lived child and never written to a
		// file or log. Reads/deletes below do not expose secret material.
		args := []string{"add-generic-password", "-a", userName, "-s", target, "-U", "-w", secret}
		_, err := runUnixCredentialCommand(backend, args, "")
		return err
	case "linux":
		// secret-tool reads the secret from stdin, avoiding argv/process-list
		// exposure. Keep the target as the sole lookup attribute: credentialRead
		// and credentialDelete receive only that stable target, so adding
		// userName here would create an entry that those operations could not
		// address consistently. The username is metadata for Windows Keychain
		// compatibility; target namespaces already include the logical account
		// where callers need separation.
		args := []string{
			"store", "--label", "ProxyNodeAssistant",
			"proxy-node-assistant-target", target,
		}
		_, err := runUnixCredentialCommand(backend, args, secret+"\n")
		return err
	default:
		return fmt.Errorf("%w: unsupported Unix credential backend %s", errCredentialManagerUnsupported, runtime.GOOS)
	}
}

func credentialRead(target string) (string, error) {
	if err := validateCredentialTarget(target); err != nil {
		return "", err
	}
	backend, err := unixCredentialBackendForCurrentOS()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "darwin":
		output, err := runUnixCredentialCommand(backend, []string{"find-generic-password", "-s", target, "-w"}, "")
		if err != nil {
			return "", err
		}
		return trimCredentialOutput(output), nil
	case "linux":
		output, err := runUnixCredentialCommand(backend, []string{"lookup", "proxy-node-assistant-target", target}, "")
		if err != nil {
			return "", err
		}
		return trimCredentialOutput(output), nil
	default:
		return "", fmt.Errorf("%w: unsupported Unix credential backend %s", errCredentialManagerUnsupported, runtime.GOOS)
	}
}

func credentialDelete(target string) error {
	if err := validateCredentialTarget(target); err != nil {
		return err
	}
	backend, err := unixCredentialBackendForCurrentOS()
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "darwin":
		_, err := runUnixCredentialCommand(backend, []string{"delete-generic-password", "-s", target}, "")
		if credentialNotFound(err) {
			return nil
		}
		return err
	case "linux":
		_, err := runUnixCredentialCommand(backend, []string{"clear", "proxy-node-assistant-target", target}, "")
		if credentialNotFound(err) {
			return nil
		}
		return err
	default:
		return fmt.Errorf("%w: unsupported Unix credential backend %s", errCredentialManagerUnsupported, runtime.GOOS)
	}
}
