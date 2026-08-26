package main

import "testing"

func TestParseSecurityReport(t *testing.T) {
	text := "__TNA_SECURITY_V1_BEGIN__\n" +
		"META\tSINCE=24h\tCURSOR=0\tLIMIT=200\n" +
		"SOURCE\tSSH\tOK\tJOURNAL_PARSED\n" +
		"SOURCE\tFAIL2BAN\tOK\tSSHD_JAIL_ACTIVE\n" +
		"SOURCE\tFIREWALL\tOK\tMETADATA_PARSED\n" +
		"SOURCE\tNGINX\tINFO\tMANAGED_SECURITY_LOG_ABSENT\n" +
		"SOURCE\tCONNECTIONS\tOK\tSNAPSHOT_CAPTURED\n" +
		"EVENT\tSSH_AUTH_FAILURE\t192.0.2.10\t3\t1720000000\trejected\n" +
		"EVENT\tCURRENT_443_CONNECTION\t2001:db8::1\t1\t1720000001\tsnapshot\n" +
		"SUMMARY\tTOTAL=2\tRETURNED=2\tTRUNCATED=0\tNEXT_CURSOR=\n" +
		"__TNA_SECURITY_V1_END__\n"
	report, err := parseSecurityReport(text)
	if err != nil {
		t.Fatal(err)
	}
	if report.Total != 2 || len(report.Events) != 2 || report.Events[0].IP != "192.0.2.10" {
		t.Fatalf("unexpected report: %#v", report)
	}
}

func TestParseSecurityReportRejectsUntrustedText(t *testing.T) {
	text := "__TNA_SECURITY_V1_BEGIN__\n" +
		"META\tSINCE=24h\tCURSOR=0\tLIMIT=200\n" +
		"SOURCE\tSSH\tOK\tJOURNAL_PARSED\n" +
		"SOURCE\tFAIL2BAN\tOK\tSSHD_JAIL_ACTIVE\n" +
		"SOURCE\tFIREWALL\tOK\tMETADATA_PARSED\n" +
		"SOURCE\tNGINX\tINFO\tMANAGED_SECURITY_LOG_ABSENT\n" +
		"SOURCE\tCONNECTIONS\tOK\tSNAPSHOT_CAPTURED\n" +
		"EVENT\tSSH_AUTH_FAILURE\t192.0.2.10;rm -rf /\t1\t1720000000\trejected\n" +
		"SUMMARY\tTOTAL=1\tRETURNED=1\tTRUNCATED=0\tNEXT_CURSOR=\n" +
		"__TNA_SECURITY_V1_END__\n"
	if _, err := parseSecurityReport(text); err == nil {
		t.Fatal("expected untrusted IP text to be rejected")
	}
}

func TestParseSecurityReportRequiresAllSources(t *testing.T) {
	text := "__TNA_SECURITY_V1_BEGIN__\n" +
		"META\tSINCE=24h\tCURSOR=0\tLIMIT=200\n" +
		"SUMMARY\tTOTAL=0\tRETURNED=0\tTRUNCATED=0\tNEXT_CURSOR=\n" +
		"__TNA_SECURITY_V1_END__\n"
	if _, err := parseSecurityReport(text); err == nil {
		t.Fatal("expected incomplete source list to be rejected")
	}
}
