package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPanelTunnelLocalFixture(t *testing.T) {
	port, err := strconv.Atoi(strings.TrimSpace(os.Getenv("PNA_FIXTURE_SSH_PORT")))
	if err != nil || port <= 0 {
		t.Skip("PNA_FIXTURE_SSH_PORT is not set; skipping the optional live SSH tunnel fixture")
	}
	user := strings.TrimSpace(os.Getenv("PNA_FIXTURE_SSH_USER"))
	key := strings.TrimSpace(os.Getenv("PNA_FIXTURE_CLIENT_KEY"))
	known := strings.TrimSpace(os.Getenv("PNA_FIXTURE_KNOWN_HOSTS"))
	if user == "" || key == "" || known == "" {
		t.Skip("PNA_FIXTURE_SSH_USER, PNA_FIXTURE_CLIENT_KEY and PNA_FIXTURE_KNOWN_HOSTS are not all set; skipping the optional live SSH tunnel fixture")
	}
	if _, err := os.Stat(key); err != nil {
		t.Fatalf("client key unavailable: %v", err)
	}
	if _, err := os.Stat(known); err != nil {
		t.Fatalf("known_hosts unavailable: %v", err)
	}
	remote, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("remote fixture listener: %v", err)
	}
	defer remote.Close()
	remotePort := remote.Addr().(*net.TCPAddr).Port
	payloadDone := make(chan error, 1)
	go func() {
		deadline := time.Now().Add(8 * time.Second)
		for time.Now().Before(deadline) {
			_ = remote.(*net.TCPListener).SetDeadline(time.Now().Add(500 * time.Millisecond))
			conn, err := remote.Accept()
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					continue
				}
				payloadDone <- err
				return
			}
			_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
			got := make([]byte, 4)
			_, readErr := io.ReadFull(conn, got)
			if readErr == nil && string(got) == "ping" {
				_, writeErr := conn.Write([]byte("PNA_TUNNEL_FIXTURE_OK"))
				conn.Close()
				payloadDone <- writeErr
				return
			}
			conn.Close() // startTunnel's listener probe opens an empty connection.
		}
		payloadDone <- fmt.Errorf("timed out waiting for payload")
	}()

	// The test uses the system OpenSSH explicitly and never reaches the real
	// VPS.  The production resolver normally fills this map during startup.
	openSSHExecutablePaths = map[string]string{
		"ssh.exe": "/usr/bin/ssh",
		"ssh":     "/usr/bin/ssh",
	}
	controlDir, err := os.MkdirTemp("/tmp", "pna-control-fixture-")
	if err != nil {
		t.Fatalf("control dir: %v", err)
	}
	defer os.RemoveAll(controlDir)
	control := filepath.Join(controlDir, "c")
	c := Connection{
		Host:        "127.0.0.1",
		User:        user,
		Port:        port,
		KeyPath:     key,
		ControlPath: control,
		AuthMode:    AuthManagedKey,
		Ready:       true,
	}
	masterArgs := []string{
		"-4", "-M", "-S", control, "-fnNT",
		"-o", "ControlPersist=60",
		"-o", "ConnectTimeout=5",
		"-o", "UserKnownHostsFile=" + known,
		"-o", "StrictHostKeyChecking=yes",
		"-o", "IdentitiesOnly=yes",
		"-i", key,
		"-p", strconv.Itoa(port),
		target(c),
	}
	master := exec.Command("/usr/bin/ssh", masterArgs...)
	if output, err := master.CombinedOutput(); err != nil {
		t.Fatalf("control master start: %v (%s)", err, output)
	}
	masterReady := false
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if _, err := os.Stat(control); err == nil {
			masterReady = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !masterReady {
		t.Fatal("control master socket did not appear")
	}
	app := &App{actionConnection: &c}
	localPort, err := app.startTunnel(c, remotePort)
	if err != nil {
		_ = closeSSHControlMaster(&c)
		t.Fatalf("startTunnel: %v", err)
	}
	if len(app.panelForwards) != 1 || len(app.tunnels) != 0 {
		t.Fatalf("expected one ControlMaster forward and no child process, got forwards=%d child_tunnels=%d", len(app.panelForwards), len(app.tunnels))
	}
	if app.heldPanelConnection != app.actionConnection {
		t.Fatal("startTunnel did not retain the action control master")
	}
	payloadConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", localPort), 2*time.Second)
	if err != nil {
		app.killTunnels()
		_ = app.releaseHeldPanelConnection()
		t.Fatalf("dial forwarded local port: %v", err)
	}
	_ = payloadConn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := payloadConn.Write([]byte("ping")); err != nil {
		payloadConn.Close()
		app.killTunnels()
		_ = app.releaseHeldPanelConnection()
		t.Fatalf("write through tunnel: %v", err)
	}
	response := make([]byte, len("PNA_TUNNEL_FIXTURE_OK"))
	if _, err := io.ReadFull(payloadConn, response); err != nil {
		payloadConn.Close()
		app.killTunnels()
		_ = app.releaseHeldPanelConnection()
		t.Fatalf("read through tunnel: %v", err)
	}
	payloadConn.Close()
	if string(response) != "PNA_TUNNEL_FIXTURE_OK" {
		t.Fatalf("unexpected tunnel response %q", string(response))
	}
	if err := <-payloadDone; err != nil {
		app.killTunnels()
		_ = app.releaseHeldPanelConnection()
		t.Fatalf("remote fixture: %v", err)
	}

	// Closing the UI tunnel first kills only the forwarding child; the
	// authenticated control master remains until explicit release.
	app.killTunnels()
	if len(app.tunnels) != 0 || len(app.panelForwards) != 0 {
		t.Fatalf("killTunnels left child=%d forward=%d entries", len(app.tunnels), len(app.panelForwards))
	}
	closed := false
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		probe, probeErr := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", localPort), 150*time.Millisecond)
		if probeErr != nil {
			closed = true
			break
		}
		probe.Close()
		time.Sleep(50 * time.Millisecond)
	}
	if !closed {
		t.Fatal("forwarding port stayed open after killTunnels")
	}
	if _, err := os.Stat(control); err != nil {
		t.Fatalf("control master vanished before explicit release: %v", err)
	}
	if err := app.releaseHeldPanelConnection(); err != nil {
		t.Fatalf("releaseHeldPanelConnection: %v", err)
	}
	if app.heldPanelConnection != nil {
		t.Fatal("heldPanelConnection still set after release")
	}
	if _, err := os.Stat(control); !os.IsNotExist(err) {
		t.Fatalf("control socket remains after release: %v", err)
	}
}
