//go:build windows

package main

import (
	"os/exec"
	"sync"
	"syscall"
	"unsafe"
)

var consoleEchoMu sync.Mutex

func hideChildWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

func setUTF8Console() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	setOutputCP := kernel32.NewProc("SetConsoleOutputCP")
	setInputCP := kernel32.NewProc("SetConsoleCP")
	_, _, _ = setOutputCP.Call(65001)
	_, _, _ = setInputCP.Call(65001)
}

func disableConsoleEcho() func() {
	consoleEchoMu.Lock()
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	getStdHandle := kernel32.NewProc("GetStdHandle")
	getConsoleMode := kernel32.NewProc("GetConsoleMode")
	setConsoleMode := kernel32.NewProc("SetConsoleMode")
	handle, _, _ := getStdHandle.Call(^uintptr(9)) // STD_INPUT_HANDLE = -10
	var original uint32
	result, _, _ := getConsoleMode.Call(handle, uintptr(unsafe.Pointer(&original)))
	if result == 0 {
		consoleEchoMu.Unlock()
		return nil
	}
	const enableEchoInput = 0x0004
	_, _, _ = setConsoleMode.Call(handle, uintptr(original&^enableEchoInput))
	return func() {
		_, _, _ = setConsoleMode.Call(handle, uintptr(original))
		consoleEchoMu.Unlock()
	}
}

func openURL(rawURL string) error {
	cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", rawURL)
	hideChildWindow(cmd)
	return cmd.Start()
}
