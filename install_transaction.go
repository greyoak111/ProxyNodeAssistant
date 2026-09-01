package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var installTransactionIDPattern = regexp.MustCompile(`^tna-install-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$`)

func (a *App) installTransactionStatus(c Connection) (map[string]string, error) {
	result := a.rootCapture(c, transactionCommand("status"))
	// A v0.9.0 node predates the transaction helper.  It is safe to treat a
	// missing helper as "no transaction" during the read-only recovery probe;
	// the installer uploads the current toolkit before it starts a new
	// transaction.  Any other execution/protocol failure remains fatal.
	if !result.OK() && strings.Contains(result.Stderr+result.Stdout, "TNA_INSTALL_TRANSACTION_ERROR=SCRIPT_MISSING") {
		return map[string]string{"TRANSACTION_STATUS": "NONE"}, nil
	}
	if !result.OK() || !hasInstallTransactionStatusMarkers(result.Stdout) {
		return nil, fmt.Errorf("install transaction status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values, err := parseInstallTransactionStatus(result.Stdout)
	if err != nil {
		return nil, err
	}
	if values["TRANSACTION_STATUS"] == "" {
		return nil, errors.New("install transaction status is incomplete")
	}
	return values, nil
}

// transactionCommand resolves the current toolkit root first and then the
// two roots used by v0.9.x.  A node can be upgraded in place while its
// compatibility symlink still points at the legacy package; hard-coding the
// new path would make recovery appear to fail and could allow a second
// install to be layered on an unfinished transaction.
func transactionCommand(arguments string) string {
	// Keep the concrete paths in the command as well as in the selected
	// variable.  Apart from making the fallback easy to audit in a copied
	// handoff, this prevents a shell expansion bug from silently testing the
	// wrong compatibility root.
	return "set -u; " +
		"[ -x " + shQuote(remoteRoot+"/linux/28a-install-transaction.sh") + " ] && root=" + shQuote(remoteRoot) + "; " +
		"[ -n \"${root-}\" ] || { [ -x " + shQuote(legacyTextRemoteRoot+"/linux/28a-install-transaction.sh") + " ] && root=" + shQuote(legacyTextRemoteRoot) + "; }; " +
		"[ -n \"${root-}\" ] || { [ -x " + shQuote(legacyRunbookRemoteRoot+"/linux/28a-install-transaction.sh") + " ] && root=" + shQuote(legacyRunbookRemoteRoot) + "; }; " +
		"[ -n \"${root-}\" ] || { echo TNA_INSTALL_TRANSACTION_ERROR=SCRIPT_MISSING >&2; exit 64; }; " +
		"bash \"$root/linux/28a-install-transaction.sh\" " + arguments
}

func hasInstallTransactionStatusMarkers(output string) bool {
	return (strings.Contains(output, "TNA_INSTALL_TRANSACTION_STATUS_BEGIN") && strings.Contains(output, "TNA_INSTALL_TRANSACTION_STATUS_END")) ||
		(strings.Contains(output, "PNA_INSTALL_TRANSACTION_STATUS_BEGIN") && strings.Contains(output, "PNA_INSTALL_TRANSACTION_STATUS_END"))
}

func parseInstallTransactionStatus(output string) (map[string]string, error) {
	begin, end := "TNA_INSTALL_TRANSACTION_STATUS_BEGIN", "TNA_INSTALL_TRANSACTION_STATUS_END"
	legacyBegin, legacyEnd := "PNA_INSTALL_TRANSACTION_STATUS_BEGIN", "PNA_INSTALL_TRANSACTION_STATUS_END"
	block, err := extractMarkerBlockCurrentOrLegacy(output, begin, end, legacyBegin, legacyEnd)
	if err != nil {
		return nil, fmt.Errorf("install transaction status protocol rejected: %w", err)
	}
	return parseKV(block), nil
}

// captureOriginalBaseline records the pre-construction node state once.  It
// is intentionally a separate, read-only-facing step from the install
// transaction: the baseline survives a failed transaction and is what menu
// [18] later uses for an exact restore.  A legacy toolkit without this helper
// is reported explicitly instead of silently claiming a rollback guarantee.
func (a *App) captureOriginalBaseline(c Connection) error {
	command := "set -u; root=" + shQuote(remoteRoot) + "; " +
		"[ -x \"$root/linux/22-dismantle-managed-node.sh\" ] || root=" + shQuote(legacyTextRemoteRoot) + "; " +
		"[ -x \"$root/linux/22-dismantle-managed-node.sh\" ] || root=" + shQuote(legacyRunbookRemoteRoot) + "; " +
		"[ -x \"$root/linux/22-dismantle-managed-node.sh\" ] || { echo TNA_BASELINE_CAPTURE=UNAVAILABLE >&2; exit 63; }; " +
		"bash \"$root/linux/22-dismantle-managed-node.sh\" --capture-baseline"
	result := a.rootCapture(c, command)
	if !result.OK() {
		return fmt.Errorf("pre-construction baseline capture failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	for _, marker := range []string{"ORIGINAL_BASELINE_CAPTURED_EXACT", "ORIGINAL_BASELINE_ALREADY_CAPTURED", "ORIGINAL_BASELINE_LEGACY_UNCERTAIN"} {
		if strings.Contains(result.Stdout, marker) {
			a.println(a.msg("[GOOD] 已捕获或复核施工前原生基线。", "[GOOD] The pre-construction native baseline was captured or verified."))
			return nil
		}
	}
	return errors.New("pre-construction baseline capture returned no accepted evidence")
}

func (a *App) recoverInterruptedInstallTransaction(c Connection) error {
	status, err := a.installTransactionStatus(c)
	if err != nil {
		return err
	}
	switch status["TRANSACTION_STATUS"] {
	case "NONE":
		return nil
	case "PREPARING":
		a.println(a.msg("检测到上次施工只完成了事务快照准备，尚未修改节点；正在清理未提交快照。", "The previous run only prepared a transaction snapshot and had not modified the node; the uncommitted snapshot is being cleared."))
	case "ACTIVE", "ROLLING_BACK", "ROLLBACK_FAILED":
		a.println(a.msg("检测到上次菜单 [1] 未提交，必须先恢复到施工前快照；不会在半成品上继续叠加安装。", "The previous menu [1] run was not committed and must be restored to its pre-construction snapshot; installation will not continue on a partial state."))
		a.println("TRANSACTION_ID=" + status["TRANSACTION_ID"])
		a.println("TRANSACTION_STATUS=" + status["TRANSACTION_STATUS"])
		if !a.yes(a.msg("现在执行幂等回滚并独立复核？", "Run the idempotent rollback and independent verification now?"), false) {
			return errors.New(a.msg("上次施工事务尚未回滚，菜单 [1] 已停止。", "The previous install transaction remains unrolled back; menu [1] stopped."))
		}
	default:
		return fmt.Errorf("unsupported install transaction state %q", status["TRANSACTION_STATUS"])
	}
	rollback := a.rootCapture(c, transactionCommand("rollback"))
	if !rollback.OK() || (!strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLED_BACK=1") && !strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLBACK=PREPARE_ABORTED") && !strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLBACK=NOT_NEEDED")) {
		return fmt.Errorf("interrupted install rollback failed (exit %d): %s", rollback.ExitCode, processFailureDetail(rollback))
	}
	a.println(a.msg("[GOOD] 上次未提交施工已回到事务前状态。", "[GOOD] The prior uncommitted construction was restored to its pre-transaction state."))
	return nil
}

func (a *App) beginInstallTransaction(c Connection) (string, error) {
	// The transaction helper accepts optional operation/fencing arguments for
	// compatibility with older experimental builds.  The reset line has no
	// local controller or lease gate, so always use its ordinary standalone
	// transaction path.
	command := transactionCommand("begin")
	result := a.rootCapture(c, command)
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_BEGAN=1") {
		return "", fmt.Errorf("install transaction begin failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	transactionID := parseKV(result.Stdout)["TRANSACTION_ID"]
	if !installTransactionIDPattern.MatchString(transactionID) {
		return "", errors.New("install transaction begin returned an invalid transaction ID")
	}
	a.println("TNA_INSTALL_TRANSACTION_BEGAN transaction_id=" + transactionID)
	return transactionID, nil
}

func (a *App) rollbackInstallTransaction(c Connection, transactionID string) error {
	status, err := a.installTransactionStatus(c)
	if err != nil {
		return err
	}
	if status["TRANSACTION_STATUS"] == "NONE" {
		return nil
	}
	if transactionID != "" && status["TRANSACTION_ID"] != transactionID {
		return fmt.Errorf("refusing to roll back another install transaction: expected=%s remote=%s", transactionID, status["TRANSACTION_ID"])
	}
	result := a.rootCapture(c, transactionCommand("rollback"))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_ROLLED_BACK=1") {
		return fmt.Errorf("install transaction rollback failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("[GOOD] 菜单 [1] 未提交改动已恢复到事务前状态。", "[GOOD] Uncommitted menu [1] changes were restored to the pre-transaction state."))
	return nil
}

func (a *App) commitInstallTransaction(c Connection, transactionID string) error {
	status, err := a.installTransactionStatus(c)
	if err != nil {
		return err
	}
	if status["TRANSACTION_STATUS"] != "ACTIVE" || status["TRANSACTION_ID"] != transactionID {
		return fmt.Errorf("install transaction identity/state mismatch before commit: expected=%s remote=%s/%s", transactionID, status["TRANSACTION_ID"], status["TRANSACTION_STATUS"])
	}
	result := a.rootCapture(c, transactionCommand("commit"))
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_COMMITTED=1") {
		return fmt.Errorf("install transaction commit failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("[GOOD] 菜单 [1] 全部远端阶段已原子提交。", "[GOOD] Every remote stage of menu [1] was committed atomically."))
	return nil
}
