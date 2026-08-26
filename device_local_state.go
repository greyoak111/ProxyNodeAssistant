package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const deviceAdmissionStateFile = "TNA-DEVICE-ADMISSION.json"

type localDeviceAdmission struct {
	Version   int    `json:"version"`
	NodeID    string `json:"nodeId"`
	DeviceID  string `json:"deviceId"`
	Role      string `json:"role"`
	DrivePort int    `json:"drivePort"`
	Host      string `json:"host"`
	User      string `json:"user"`
	Port      int    `json:"port"`
}

func (a *App) refreshTrafficDeviceAdmission(c Connection, identity DeviceIdentity) (localDeviceAdmission, error) {
	result := a.sshCapture(c, "drive-meta")
	if !result.OK() {
		return localDeviceAdmission{}, errors.New("restricted traffic-device metadata probe was rejected")
	}
	block, err := extractMarkerBlock(result.Stdout, "__TNA_TRAFFIC_META_V1_BEGIN__", "__TNA_TRAFFIC_META_V1_END__")
	if err != nil {
		return localDeviceAdmission{}, err
	}
	values := parseDeviceKV(block)
	drivePort, portErr := strconv.Atoi(values["DRIVE_LOOPBACK_PORT"])
	revision, revisionErr := strconv.Atoi(values["TOOLKIT_BUILD_REVISION"])
	value := localDeviceAdmission{Version: 1, NodeID: values["NODE_ID"], DeviceID: values["DEVICE_ID"], Role: values["DEVICE_ROLE"], DrivePort: drivePort, Host: c.Host, User: c.User, Port: c.Port}
	if portErr != nil || revisionErr != nil || values["DEVICE_ID"] != identity.DeviceID || values["DEVICE_ROLE"] != "traffic-only" || values["TOOLKIT_BUILD_ID"] != toolkitBuildID || revision != toolkitBuildRevision {
		return localDeviceAdmission{}, fmt.Errorf("restricted traffic-device metadata does not match this executable and identity")
	}
	if err := validateLocalDeviceAdmission(value); err != nil {
		return localDeviceAdmission{}, err
	}
	if err := saveLocalDeviceAdmission(c, value); err != nil {
		return localDeviceAdmission{}, err
	}
	return value, nil
}

type trafficDriveChangeContext struct {
	NodeID      string
	AccountID   string
	SpaceID     string
	Username    string
	QuotaGiB    string
	Controllers []controllerEncryptionKey
}

func parseTrafficDriveChangeContext(stdout string) (trafficDriveChangeContext, error) {
	block, err := extractMarkerBlock(stdout, "__TNA_TRAFFIC_CHANGE_CONTEXT_V1_BEGIN__", "__TNA_TRAFFIC_CHANGE_CONTEXT_V1_END__")
	if err != nil {
		return trafficDriveChangeContext{}, err
	}
	values := parseDeviceKV(block)
	context := trafficDriveChangeContext{NodeID: values["NODE_ID"], AccountID: values["ACCOUNT_ID"], SpaceID: values["SPACE_ID"], Username: values["USERNAME"], QuotaGiB: values["QUOTA_GIB"]}
	for _, line := range strings.Split(block, "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) == 3 && parts[0] == "CONTROLLER" {
			context.Controllers = append(context.Controllers, controllerEncryptionKey{DeviceID: parts[1], Public: parts[2]})
		}
	}
	if !nodeIDPattern.MatchString(context.NodeID) || !driveAccountIDPattern.MatchString(context.AccountID) || !driveSpaceIDPattern.MatchString(context.SpaceID) || !driveUsernamePattern.MatchString(context.Username) || len(context.Controllers) == 0 {
		return trafficDriveChangeContext{}, errors.New("restricted drive password-change context is invalid")
	}
	for _, controller := range context.Controllers {
		if !deviceIDPattern.MatchString(controller.DeviceID) || !strings.HasPrefix(controller.Public, "tna-x25519:") {
			return trafficDriveChangeContext{}, errors.New("restricted drive controller encryption key is invalid")
		}
	}
	return context, nil
}

func validateLocalDeviceAdmission(value localDeviceAdmission) error {
	if value.Version != 1 || !nodeIDPattern.MatchString(value.NodeID) || !deviceIDPattern.MatchString(value.DeviceID) ||
		(value.Role != "controller" && value.Role != "traffic-only") || value.DrivePort < 39000 || value.DrivePort > 39999 ||
		!validRecentTarget(RecentTarget{Host: value.Host, User: value.User, Port: value.Port}) {
		return errors.New("local device-admission state is invalid")
	}
	return nil
}

func saveLocalDeviceAdmission(c Connection, value localDeviceAdmission) error {
	value.Version = 1
	value.Host, value.User, value.Port = c.Host, c.User, c.Port
	if err := validateLocalDeviceAdmission(value); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	path := filepath.Join(filepath.Dir(c.KeyPath), deviceAdmissionStateFile)
	temporary := path + ".new"
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func loadLocalDeviceAdmission(c Connection) (localDeviceAdmission, error) {
	data, err := os.ReadFile(filepath.Join(filepath.Dir(c.KeyPath), deviceAdmissionStateFile))
	if err != nil {
		return localDeviceAdmission{}, err
	}
	var value localDeviceAdmission
	if err := json.Unmarshal(data, &value); err != nil {
		return localDeviceAdmission{}, err
	}
	if err := validateLocalDeviceAdmission(value); err != nil {
		return localDeviceAdmission{}, err
	}
	if value.Host != c.Host || value.User != c.User || value.Port != c.Port {
		return localDeviceAdmission{}, errors.New("local device-admission target mismatch")
	}
	return value, nil
}
