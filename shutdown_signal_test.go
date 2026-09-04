package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestShutdownCleanupIsBoundedAndIdempotent(t *testing.T) {
	app := &App{}
	if !app.cleanupAppResourcesBounded(time.Second) {
		t.Fatal("empty app cleanup should complete within the bound")
	}
	// The process defer and a signal can both reach cleanup.  A second call
	// must return immediately rather than repeating SSH/socket cleanup.
	if !app.cleanupAppResourcesBounded(time.Second) {
		t.Fatal("idempotent cleanup should complete within the bound")
	}
}

func TestMainHandlesTerminationSignals(t *testing.T) {
	data, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, required := range []string{
		"syscall.SIGTERM",
		"syscall.SIGHUP",
		"signal.Notify(interrupts, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)",
		"app.cleanupAppResourcesBounded(shutdownCleanupTimeout)",
		"os.Exit(exitCode)",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("main signal handler is missing %q", required)
		}
	}
	if shutdownCleanupTimeout <= 0 || shutdownCleanupTimeout > time.Minute {
		t.Fatalf("shutdown cleanup timeout is not a safe bound: %s", shutdownCleanupTimeout)
	}
}
