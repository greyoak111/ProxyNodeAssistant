package main

import (
	"strings"
	"testing"
)

func TestTransactionCommandResolvesCurrentAndLegacyRoots(t *testing.T) {
	command := transactionCommand("status")
	for _, root := range []string{remoteRoot, legacyTextRemoteRoot, legacyRunbookRemoteRoot} {
		if !strings.Contains(command, root+"/linux/28a-install-transaction.sh") {
			t.Fatalf("transaction command does not include compatibility root %q: %s", root, command)
		}
	}
	if !strings.Contains(command, "SCRIPT_MISSING") || strings.Contains(command, "rm -rf") {
		t.Fatalf("transaction status resolver is not fail-closed/read-only: %s", command)
	}
}

func TestParseInstallTransactionStatusAcceptsLegacyMarkers(t *testing.T) {
	output := strings.Join([]string{
		"noise",
		"PNA_INSTALL_TRANSACTION_STATUS_BEGIN",
		"TRANSACTION_STATUS=ACTIVE",
		"TRANSACTION_ID=tna-install-20260901T010203Z-0123456789ab",
		"PNA_INSTALL_TRANSACTION_STATUS_END",
	}, "\n")
	values, err := parseInstallTransactionStatus(output)
	if err != nil {
		t.Fatal(err)
	}
	if values["TRANSACTION_STATUS"] != "ACTIVE" {
		t.Fatalf("unexpected transaction status: %#v", values)
	}
}

func TestParseInstallTransactionStatusRejectsUnmarkedOutput(t *testing.T) {
	if _, err := parseInstallTransactionStatus("TRANSACTION_STATUS=ACTIVE\n"); err == nil {
		t.Fatal("unmarked transaction output was accepted")
	}
}
