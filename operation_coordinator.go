package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	operationLeaseSeconds     = 180
	operationHeartbeatSeconds = 30
)

var operationTypePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
var operationIDPattern = regexp.MustCompile(`^tna-op-[0-9a-f]{32}$`)

type operationSpec struct {
	Type     string
	Mutating bool
}

type nodeOperationLease struct {
	OperationID  string
	NodeID       string
	OwnerDevice  string
	Type         string
	FencingToken uint64
	StartedEpoch int64
	ExpiresEpoch int64
	Stage        string
	Recovery     string

	connection Connection
	stop       chan struct{}
	done       chan struct{}
	stopOnce   sync.Once
	mu         sync.Mutex
	lastError  error
}

type operationAcquireResult struct {
	Status       string
	OperationID  string
	NodeID       string
	OwnerDevice  string
	Type         string
	FencingToken uint64
	StartedEpoch int64
	ExpiresEpoch int64
	Stage        string
	Recovery     string
}

func randomOperationID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return "tna-op-" + hex.EncodeToString(value), nil
}

func parseOperationAcquire(stdout string) (operationAcquireResult, error) {
	block, err := extractMarkerBlock(stdout, "__TNA_NODE_OPERATION_V1_BEGIN__", "__TNA_NODE_OPERATION_V1_END__")
	if err != nil {
		return operationAcquireResult{}, err
	}
	values := parseDeviceKV(block)
	result := operationAcquireResult{
		Status:      values["STATUS"],
		OperationID: values["NODE_OPERATION_ID"],
		NodeID:      values["NODE_ID"],
		OwnerDevice: values["OWNER_DEVICE_ID"],
		Type:        values["OPERATION_TYPE"],
		Stage:       values["CURRENT_STAGE"],
		Recovery:    values["RECOVERY_STATE"],
	}
	result.FencingToken, _ = strconv.ParseUint(values["FENCING_TOKEN"], 10, 64)
	result.StartedEpoch, _ = strconv.ParseInt(values["STARTED_AT"], 10, 64)
	result.ExpiresEpoch, _ = strconv.ParseInt(values["LEASE_EXPIRES_AT"], 10, 64)
	if result.Status != "ACQUIRED" && result.Status != "BUSY" && result.Status != "RECOVERY_REQUIRED" {
		return operationAcquireResult{}, errors.New("operation coordinator returned an invalid status")
	}
	if !operationIDPattern.MatchString(result.OperationID) || result.OwnerDevice == "" || !operationTypePattern.MatchString(result.Type) || result.FencingToken == 0 || result.StartedEpoch <= 0 || result.ExpiresEpoch <= 0 {
		return operationAcquireResult{}, errors.New("operation coordinator response is incomplete")
	}
	if !nodeIDPattern.MatchString(result.NodeID) {
		return operationAcquireResult{}, errors.New("operation coordinator returned an invalid node identity")
	}
	return result, nil
}

func acquireOperationCommand(operationID, nodeID, owner, operationType string, takeover bool) string {
	takeoverFlag := "0"
	if takeover {
		takeoverFlag = "1"
	}
	return "set -eu; umask 077; " +
		"state_dir=/var/lib/text-node-assistant/operations; mkdir -p \"$state_dir\"; chmod 700 \"$state_dir\"; " +
		"command -v flock >/dev/null 2>&1 || { echo TNA_OPERATION_ERROR=FLOCK_UNAVAILABLE >&2; exit 72; }; " +
		"exec 9>\"$state_dir/lock\"; flock -x 9; now=$(date +%s); current=\"$state_dir/current.env\"; " +
		"read_field() { sed -n \"s/^$1=//p\" \"$current\" 2>/dev/null | head -n 1; }; " +
		"print_current() { printf '%s\\n' '__TNA_NODE_OPERATION_V1_BEGIN__'; printf 'STATUS=%s\\n' \"$1\"; " +
		"for key in NODE_OPERATION_ID NODE_ID OWNER_DEVICE_ID OPERATION_TYPE STARTED_AT LEASE_EXPIRES_AT FENCING_TOKEN CURRENT_STAGE RECOVERY_STATE LAST_HEARTBEAT; do printf '%s=%s\\n' \"$key\" \"$(read_field \"$key\")\"; done; printf '%s\\n' '__TNA_NODE_OPERATION_V1_END__'; }; " +
		"if [ -s \"$current\" ]; then existing_id=$(read_field NODE_OPERATION_ID); expires=$(read_field LEASE_EXPIRES_AT); " +
		"case $expires in ''|*[!0-9]*) expires=0;; esac; if [ \"$existing_id\" != " + shQuote(operationID) + " ]; then " +
		"if [ \"$expires\" -gt \"$now\" ]; then print_current BUSY; exit 73; fi; " +
		"if [ " + takeoverFlag + " != 1 ]; then print_current RECOVERY_REQUIRED; exit 74; fi; fi; fi; " +
		"counter=\"$state_dir/fencing-token\"; token=0; if [ -r \"$counter\" ]; then IFS= read -r token < \"$counter\" || true; fi; case $token in ''|*[!0-9]*) token=0;; esac; token=$((token+1)); printf '%s\\n' \"$token\" > \"$counter.tmp\"; mv -f \"$counter.tmp\" \"$counter\"; " +
		"expires=$((now+" + strconv.Itoa(operationLeaseSeconds) + ")); tmp=\"$current.tmp.$$\"; { " +
		"printf 'NODE_OPERATION_ID=%s\\n' " + shQuote(operationID) + "; printf 'NODE_ID=%s\\n' " + shQuote(nodeID) + "; printf 'OWNER_DEVICE_ID=%s\\n' " + shQuote(owner) + "; printf 'OPERATION_TYPE=%s\\n' " + shQuote(operationType) + "; " +
		"printf 'STARTED_AT=%s\\nLEASE_EXPIRES_AT=%s\\nFENCING_TOKEN=%s\\nCURRENT_STAGE=ACQUIRED\\nRECOVERY_STATE=CLEAN\\nLAST_HEARTBEAT=%s\\n' \"$now\" \"$expires\" \"$token\" \"$now\"; } > \"$tmp\"; chmod 600 \"$tmp\"; mv -f \"$tmp\" \"$current\"; print_current ACQUIRED"
}

func heartbeatOperationCommand(lease *nodeOperationLease) string {
	return "set -eu; state_dir=/var/lib/text-node-assistant/operations; current=\"$state_dir/current.env\"; exec 9>\"$state_dir/lock\"; flock -x 9; " +
		"read_field() { sed -n \"s/^$1=//p\" \"$current\" 2>/dev/null | head -n 1; }; " +
		"[ \"$(read_field NODE_OPERATION_ID)\" = " + shQuote(lease.OperationID) + " ] && [ \"$(read_field FENCING_TOKEN)\" = " + shQuote(strconv.FormatUint(lease.FencingToken, 10)) + " ] || exit 75; " +
		"now=$(date +%s); expires=$((now+" + strconv.Itoa(operationLeaseSeconds) + ")); sed -e \"s/^LEASE_EXPIRES_AT=.*/LEASE_EXPIRES_AT=$expires/\" -e \"s/^LAST_HEARTBEAT=.*/LAST_HEARTBEAT=$now/\" \"$current\" > \"$current.tmp.$$\"; chmod 600 \"$current.tmp.$$\"; mv -f \"$current.tmp.$$\" \"$current\""
}

func releaseOperationCommand(lease *nodeOperationLease, outcome string) string {
	return "set -eu; state_dir=/var/lib/text-node-assistant/operations; current=\"$state_dir/current.env\"; [ -e \"$current\" ] || { echo TNA_NODE_OPERATION_RELEASED=ALREADY_ABSENT; exit 0; }; exec 9>\"$state_dir/lock\"; flock -x 9; " +
		"read_field() { sed -n \"s/^$1=//p\" \"$current\" 2>/dev/null | head -n 1; }; " +
		"[ \"$(read_field NODE_OPERATION_ID)\" = " + shQuote(lease.OperationID) + " ] && [ \"$(read_field FENCING_TOKEN)\" = " + shQuote(strconv.FormatUint(lease.FencingToken, 10)) + " ] || exit 75; " +
		"history=\"$state_dir/history\"; mkdir -p \"$history\"; chmod 700 \"$history\"; receipt=\"$history/" + lease.OperationID + ".env\"; [ ! -e \"$receipt\" ] || exit 76; " +
		"{ cat \"$current\"; printf 'FINAL_STATUS=%s\\nFINISHED_AT=%s\\n' " + shQuote(outcome) + " \"$(date +%s)\"; } > \"$receipt.tmp.$$\"; chmod 600 \"$receipt.tmp.$$\"; mv -f \"$receipt.tmp.$$\" \"$receipt\"; " +
		"rm -f \"$current\"; printf 'TNA_NODE_OPERATION_RELEASED\\nTNA_OPERATION_RECEIPT=%s\\n' \"$receipt\""
}

func (a *App) operationNodeID(c Connection) (string, error) {
	if remoteIdentity, err := a.fetchNodeIdentity(c); err == nil && nodeIDPattern.MatchString(remoteIdentity.NodeID) {
		return remoteIdentity.NodeID, nil
	}
	result := a.rootCapture(c, "set -eu; command -v sha256sum >/dev/null 2>&1; machine=$(tr -d ' \\r\\n\\t' < /etc/machine-id); [ -n \"$machine\" ]; digest=$(printf '%s' \"$machine\" | sha256sum | awk '{print $1}'); printf 'TNA_NODE_ID=tna-node-%.32s\\n' \"$digest\"")
	if !result.OK() {
		return "", fmt.Errorf("stable node identity bootstrap failed: %s", processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	nodeID := values["TNA_NODE_ID"]
	if !nodeIDPattern.MatchString(nodeID) {
		return "", errors.New("stable node identity bootstrap returned invalid data")
	}
	return nodeID, nil
}

func (a *App) acquireNodeOperation(c Connection, spec operationSpec, takeover bool) (*nodeOperationLease, operationAcquireResult, error) {
	identity, err := loadOrCreateDeviceIdentity()
	if err != nil {
		return nil, operationAcquireResult{}, fmt.Errorf("local controller identity is unavailable: %w", err)
	}
	nodeID, err := a.operationNodeID(c)
	if err != nil {
		return nil, operationAcquireResult{}, err
	}
	operationID, err := randomOperationID()
	if err != nil {
		return nil, operationAcquireResult{}, err
	}
	result := a.rootCapture(c, acquireOperationCommand(operationID, nodeID, identity.DeviceID, spec.Type, takeover))
	parsed, parseErr := parseOperationAcquire(result.Stdout)
	if parseErr != nil {
		return nil, operationAcquireResult{}, fmt.Errorf("node operation coordinator failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	if parsed.Status != "ACQUIRED" {
		return nil, parsed, nil
	}
	lease := &nodeOperationLease{
		OperationID: parsed.OperationID, NodeID: parsed.NodeID, OwnerDevice: parsed.OwnerDevice, Type: parsed.Type,
		FencingToken: parsed.FencingToken, StartedEpoch: parsed.StartedEpoch, ExpiresEpoch: parsed.ExpiresEpoch,
		Stage: parsed.Stage, Recovery: parsed.Recovery, connection: c, stop: make(chan struct{}), done: make(chan struct{}),
	}
	go a.heartbeatNodeOperation(lease)
	return lease, parsed, nil
}

func (a *App) heartbeatNodeOperation(lease *nodeOperationLease) {
	defer close(lease.done)
	ticker := time.NewTicker(time.Duration(operationHeartbeatSeconds) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-lease.stop:
			return
		case <-ticker.C:
			result := a.rootCapture(lease.connection, heartbeatOperationCommand(lease))
			if !result.OK() {
				lease.mu.Lock()
				lease.lastError = fmt.Errorf("operation lease heartbeat failed: %s", processFailureDetail(result))
				lease.mu.Unlock()
				return
			}
		}
	}
}

func (a *App) releaseNodeOperation(succeeded bool) error {
	lease := a.activeOperation
	a.activeOperation = nil
	if lease == nil {
		return nil
	}
	lease.stopOnce.Do(func() { close(lease.stop) })
	<-lease.done
	lease.mu.Lock()
	heartbeatErr := lease.lastError
	lease.mu.Unlock()
	outcome := "FAILED"
	if succeeded && heartbeatErr == nil {
		outcome = "COMMITTED"
	}
	result := a.rootCapture(lease.connection, releaseOperationCommand(lease, outcome))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_NODE_OPERATION_RELEASED") {
		return fmt.Errorf("node operation lease could not be released: %s", processFailureDetail(result))
	}
	return heartbeatErr
}

func (a *App) ensureNodeOperation(c Connection) error {
	if !a.currentOperation.Mutating || a.activeOperation != nil {
		return nil
	}
	lease, existing, err := a.acquireNodeOperation(c, a.currentOperation, false)
	if err != nil {
		return err
	}
	if lease != nil {
		a.activeOperation = lease
		a.println(fmt.Sprintf("TNA_NODE_OPERATION_ACQUIRED fencing_token=%d", lease.FencingToken))
		return nil
	}
	if existing.Status == "BUSY" {
		return fmt.Errorf(a.msg("节点正由另一项施工占用：类型=%s 设备=%s 阶段=%s；本次不会并发写入", "The node is busy with another operation: type=%s device=%s stage=%s; this action will not write concurrently"), existing.Type, existing.OwnerDevice, existing.Stage)
	}
	a.println(a.msg("检测到过期施工，需要先复核现场再接管：", "An expired operation requires an explicit recovery review before takeover:"))
	a.println(fmt.Sprintf("operation=%s owner=%s type=%s stage=%s recovery=%s fencing_token=%d", existing.OperationID, existing.OwnerDevice, existing.Type, existing.Stage, existing.Recovery, existing.FencingToken))
	if !a.yes(a.msg("确认旧租约已失效，并由本设备以新 fencing token 接管？", "Confirm the old lease is inactive and take over with a new fencing token?"), false) {
		return errors.New(a.msg("已取消过期施工接管", "Expired-operation takeover was cancelled"))
	}
	lease, _, err = a.acquireNodeOperation(c, a.currentOperation, true)
	if err != nil {
		return err
	}
	if lease == nil {
		return errors.New("operation takeover did not acquire a lease")
	}
	a.activeOperation = lease
	return nil
}
