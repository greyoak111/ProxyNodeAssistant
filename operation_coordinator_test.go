package main

import (
	"strings"
	"testing"
)

func TestParseOperationAcquire(t *testing.T) {
	input := strings.Join([]string{
		"noise",
		"__TNA_NODE_OPERATION_V1_BEGIN__",
		"STATUS=ACQUIRED",
		"NODE_OPERATION_ID=tna-op-0123456789abcdef0123456789abcdef",
		"NODE_ID=tna-node-0123456789abcdef0123456789abcdef",
		"OWNER_DEVICE_ID=tna-device-abcdefghijklmnopqrstuvwxyz",
		"OPERATION_TYPE=install-upgrade",
		"STARTED_AT=1787640000",
		"LEASE_EXPIRES_AT=1787640180",
		"FENCING_TOKEN=42",
		"CURRENT_STAGE=ACQUIRED",
		"RECOVERY_STATE=CLEAN",
		"LAST_HEARTBEAT=1787640000",
		"__TNA_NODE_OPERATION_V1_END__",
	}, "\n")
	result, err := parseOperationAcquire(input)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "ACQUIRED" || result.FencingToken != 42 || result.Type != "install-upgrade" {
		t.Fatalf("unexpected operation response: %#v", result)
	}
}

func TestOperationCommandsFenceEveryMutation(t *testing.T) {
	command := acquireOperationCommand(
		"tna-op-0123456789abcdef0123456789abcdef",
		"tna-node-0123456789abcdef0123456789abcdef",
		"tna-device-abcdefghijklmnopqrstuvwxyz",
		"restore-baseline",
		false,
	)
	for _, required := range []string{"flock -x", "FENCING_TOKEN", "RECOVERY_REQUIRED", "LEASE_EXPIRES_AT", "mv -f"} {
		if !strings.Contains(command, required) {
			t.Fatalf("operation command is missing %s", required)
		}
	}
}

func TestOperationReleasePersistsImmutableReceipt(t *testing.T) {
	lease := &nodeOperationLease{OperationID: "tna-op-0123456789abcdef0123456789abcdef", FencingToken: 42}
	command := releaseOperationCommand(lease, "COMMITTED")
	for _, required := range []string{"history", "FINAL_STATUS", "FINISHED_AT", "COMMITTED", "[ ! -e \"$receipt\" ]", "FENCING_TOKEN"} {
		if !strings.Contains(command, required) {
			t.Fatalf("operation release receipt is missing %s", required)
		}
	}
}
