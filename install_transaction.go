package main

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var installTransactionIDPattern = regexp.MustCompile(`^tna-install-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$`)

func (a *App) installTransactionStatus(c Connection) (map[string]string, error) {
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/28a-install-transaction.sh status")
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_STATUS_BEGIN") || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_STATUS_END") {
		return nil, fmt.Errorf("install transaction status failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	values := parseKV(result.Stdout)
	if values["TRANSACTION_STATUS"] == "" {
		return nil, errors.New("install transaction status is incomplete")
	}
	return values, nil
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
	rollback := a.rootCapture(c, "bash "+remoteRoot+"/linux/28a-install-transaction.sh rollback")
	if !rollback.OK() || (!strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLED_BACK=1") && !strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLBACK=PREPARE_ABORTED") && !strings.Contains(rollback.Stdout, "TNA_INSTALL_TRANSACTION_ROLLBACK=NOT_NEEDED")) {
		return fmt.Errorf("interrupted install rollback failed (exit %d): %s", rollback.ExitCode, processFailureDetail(rollback))
	}
	a.println(a.msg("[GOOD] 上次未提交施工已回到事务前状态。", "[GOOD] The prior uncommitted construction was restored to its pre-transaction state."))
	return nil
}

func (a *App) beginInstallTransaction(c Connection) (string, error) {
	operationID := "standalone"
	fencingToken := uint64(0)
	if a.activeOperation != nil {
		operationID = a.activeOperation.OperationID
		fencingToken = a.activeOperation.FencingToken
	}
	command := "bash " + remoteRoot + "/linux/28a-install-transaction.sh begin " + shQuote(operationID) + " " + shQuote(strconv.FormatUint(fencingToken, 10))
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
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/28a-install-transaction.sh rollback")
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
	result := a.rootCapture(c, "bash "+remoteRoot+"/linux/28a-install-transaction.sh commit")
	if !result.OK() || !strings.Contains(result.Stdout, "TNA_INSTALL_TRANSACTION_COMMITTED=1") {
		return fmt.Errorf("install transaction commit failed (exit %d): %s", result.ExitCode, processFailureDetail(result))
	}
	a.println(a.msg("[GOOD] 菜单 [1] 全部远端阶段已原子提交。", "[GOOD] Every remote stage of menu [1] was committed atomically."))
	return nil
}
