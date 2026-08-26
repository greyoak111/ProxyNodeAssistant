package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

const driveAccountResultPrefix = "TNA_DRIVE_ACCOUNT_RESULT_B64="

func requestedDriveTransaction(args []string) string {
	for _, value := range args {
		switch value {
		case "--drive-register":
			return "register"
		case "--drive-change-password":
			return "change-password"
		}
	}
	return ""
}

func (a *App) driveProtocolConnection(host, user, portText string) (Connection, localDeviceAdmission, error) {
	port, err := strconv.Atoi(strings.TrimSpace(portText))
	if !hostPartPattern.MatchString(host) || !userPartPattern.MatchString(user) || err != nil || port < 1 || port > 65535 {
		return Connection{}, localDeviceAdmission{}, fmt.Errorf("connection input is invalid")
	}
	if err := a.ensureOpenSSH(); err != nil {
		return Connection{}, localDeviceAdmission{}, err
	}
	keyPath, err := defaultKeyPath(host, user)
	if err != nil {
		return Connection{}, localDeviceAdmission{}, err
	}
	if !fileExists(keyPath) || !fileExists(keyPath+".pub") {
		return Connection{}, localDeviceAdmission{}, fmt.Errorf("node is not bound on this device")
	}
	c := Connection{Host: host, User: user, Port: port, KeyPath: keyPath, AuthMode: AuthManagedKey, Ready: true}
	if err := a.ensureHostKey(c); err != nil {
		return Connection{}, localDeviceAdmission{}, err
	}
	identity, identityErr := loadOrCreateDeviceIdentity()
	if identityErr != nil {
		return Connection{}, localDeviceAdmission{}, identityErr
	}
	if traffic, trafficErr := a.refreshTrafficDeviceAdmission(c, identity); trafficErr == nil {
		return c, traffic, nil
	}
	verified := verifyKey(c, keyPath)
	if !verified.OK() || strings.TrimSpace(verified.Stdout) != "SSH_KEY_OK" {
		return Connection{}, localDeviceAdmission{}, fmt.Errorf("managed device key was rejected")
	}
	if err := a.requireExactInstalledToolkit(c); err != nil {
		return Connection{}, localDeviceAdmission{}, err
	}
	return c, localDeviceAdmission{Version: 1, DeviceID: identity.DeviceID, Role: "controller", Host: c.Host, User: c.User, Port: c.Port}, nil
}

func emitDriveAccountResult(value driveAccountSecretResult) int {
	data, err := json.Marshal(value)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_ACCOUNT_ERROR=RESULT_ENCODING_FAILED")
		return 9
	}
	fmt.Println(driveAccountResultPrefix + base64.StdEncoding.EncodeToString(data))
	return 0
}

// runDriveTransaction is a narrow, non-interactive protocol for the graphical
// outer drive.  All credentials arrive on stdin and the sole secret result is
// a base64 JSON frame which the GUI intercepts instead of logging.
func (a *App) runDriveTransaction(action string, input io.Reader) int {
	lines, err := readLocalAdminProtocolLines(input, 7)
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_ACCOUNT_ERROR=INPUT_MISSING")
		return 2
	}
	c, admission, err := a.driveProtocolConnection(strings.TrimSpace(lines[0]), strings.TrimSpace(lines[1]), strings.TrimSpace(lines[2]))
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_ACCOUNT_ERROR="+sanitizeProtocolError(err.Error()))
		return 3
	}
	var result driveAccountSecretResult
	switch action {
	case "register":
		if admission.Role != "controller" {
			err = fmt.Errorf("ordinary account registration requires an active controller device")
			break
		}
		result, err = a.registerOrdinaryDriveAccountValues(c, lines[3], lines[4], lines[5], lines[6])
	case "change-password":
		// username, current password, new password, confirmation
		if admission.Role == "traffic-only" {
			result, err = a.changeOrdinaryDrivePasswordTraffic(c, admission, lines[3], lines[4], lines[5], lines[6])
		} else {
			result, err = a.changeOrdinaryDrivePasswordValues(c, lines[3], lines[4], lines[5], lines[6])
		}
	default:
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_ACCOUNT_ERROR=ACTION_INVALID")
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "TNA_DRIVE_ACCOUNT_ERROR="+sanitizeProtocolError(err.Error()))
		return 4
	}
	return emitDriveAccountResult(result)
}

func sanitizeProtocolError(value string) string {
	value = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(value, "\r", " "), "\n", " | "))
	if len(value) > 800 {
		value = value[:800]
	}
	if value == "" {
		return "UNKNOWN"
	}
	return value
}
