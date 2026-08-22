//go:build !windows

package main

import "os/exec"

func disableConsoleEcho() func() { return nil }

func hideChildWindow(cmd *exec.Cmd) {}
func setUTF8Console()               {}
func openURL(rawURL string) error   { return nil }
