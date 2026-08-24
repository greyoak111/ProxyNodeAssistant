param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$IdentityFile,
    [Parameter(Mandatory = $true)][string]$KnownHostsFile,
    [string]$UserName = "root",
    [int]$Port = 22
)

$ErrorActionPreference = "Stop"
$ssh = (Get-Command ssh).Source
$opensslCommand = Get-Command openssl -ErrorAction SilentlyContinue
$openssl = if ($opensslCommand) { $opensslCommand.Source } else { "C:\Program Files\Git\mingw64\bin\openssl.exe" }
if (-not (Test-Path -LiteralPath $openssl -PathType Leaf)) { throw "OpenSSL executable not found" }
$target = "$UserName@$HostName"
$sshArgs = @("-p", "$Port", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=$KnownHostsFile", "-i", $IdentityFile)
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("pna-device-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDirectory | Out-Null

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function ConvertTo-Base32([byte[]]$Bytes) {
    $alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    $output = New-Object Text.StringBuilder
    $buffer = 0L
    $bits = 0
    foreach ($value in $Bytes) {
        $buffer = ($buffer -shl 8) -bor $value
        $bits += 8
        while ($bits -ge 5) {
            $bits -= 5
            [void]$output.Append($alphabet[($buffer -shr $bits) -band 31])
        }
    }
    if ($bits -gt 0) { [void]$output.Append($alphabet[($buffer -shl (5 - $bits)) -band 31]) }
    $output.ToString()
}

function New-TestDevice([string]$Name) {
    $privatePath = Join-Path $testDirectory "$Name-private.pem"
    $publicPath = Join-Path $testDirectory "$Name-public.der"
    & $openssl genpkey -algorithm ED25519 -out $privatePath 2>$null
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL Ed25519 generation failed" }
    & $openssl pkey -in $privatePath -pubout -outform DER -out $publicPath 2>$null
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL Ed25519 public-key export failed" }
    $encoded = [IO.File]::ReadAllBytes($publicPath)
    $raw = $encoded[($encoded.Length - 32)..($encoded.Length - 1)]
    $digest = [Security.Cryptography.SHA256]::HashData($raw)
    [pscustomobject]@{
        Private = $privatePath
        Public = "pna-ed25519:" + (ConvertTo-Base64Url $raw)
        Id = "pna-device-" + (ConvertTo-Base32 $digest[0..15])
    }
}

function Invoke-Remote([string]$Command, [string]$InputText = "") {
    if ($InputText) { $output = $InputText | & $ssh @sshArgs $target $Command }
    else { $output = & $ssh @sshArgs $target $Command }
    [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
}

try {
    $controller = New-TestDevice "controller"
    $traffic = New-TestDevice "traffic"
    $status = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh status"
    if ($status.ExitCode -ne 0) { throw "Device status failed" }
    $nodeId = (($status.Output -split "`n" | Where-Object { $_ -like "NODE_ID=*" } | Select-Object -First 1) -split "=", 2)[1]

    $bootstrap = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh bootstrap-controller" "`n$($controller.Public)`nTest Controller`ncontroller`n`n"
    if ($bootstrap.ExitCode -ne 0 -or $bootstrap.Output -notmatch "__PNA_DEVICE_BOOTSTRAP_V1_END__") { throw "First-controller bootstrap failed" }

    $invite = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh create-invite $($controller.Id)"
    if ($invite.ExitCode -ne 0) { throw "Invitation creation failed" }
    $nonce = (($invite.Output -split "`n" | Where-Object { $_ -like "ENROLLMENT_NONCE=*" } | Select-Object -First 1) -split "=", 2)[1]
    $message = "PNA-DEVICE-ENROLL-V1`nNODE_ID=$nodeId`nNONCE=$nonce`nDEVICE_ID=$($traffic.Id)`nPUBLIC_KEY=$($traffic.Public)`nLABEL=Test Traffic`nROLE=traffic-only`n"
    $messagePath = Join-Path $testDirectory "message.bin"
    $signaturePath = Join-Path $testDirectory "signature.bin"
    [IO.File]::WriteAllText($messagePath, $message, [Text.UTF8Encoding]::new($false))
    & $openssl pkeyutl -sign -inkey $traffic.Private -rawin -in $messagePath -out $signaturePath 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Invitation signing failed" }
    $signature = ConvertTo-Base64Url ([IO.File]::ReadAllBytes($signaturePath))
    $enrollmentInput = "$nonce`n$($traffic.Public)`nTest Traffic`ntraffic-only`n$signature`n"
    $enrollment = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh enroll" $enrollmentInput
    if ($enrollment.ExitCode -ne 0 -or $enrollment.Output -notmatch "NONCE_CONSUMED=1") { throw "Signed enrollment failed" }

    $replay = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh enroll" $enrollmentInput
    if ($replay.ExitCode -ne 71) { throw "Replay rejection returned $($replay.ExitCode), expected 71" }
    foreach ($verb in @("pause", "resume", "revoke")) {
        $change = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh $verb $($controller.Id) $($traffic.Id)"
        if ($change.ExitCode -ne 0) { throw "$verb failed" }
    }
    $last = Invoke-Remote "bash /opt/proxy-runbook-v0.9.5/linux/26-device-admission.sh revoke $($controller.Id) $($controller.Id)"
    if ($last.ExitCode -ne 73) { throw "Last-controller protection returned $($last.ExitCode), expected 73" }
    Write-Output "DEVICE_ADMISSION_REMOTE_TRANSACTION_OK"
} finally {
	if ($null -ne $controller -and $null -ne $traffic) {
		$cleanupCommand = @"
set -Eeuo pipefail
. /opt/proxy-runbook-v0.9.5/linux/lib-xui-api.sh
xui_api_context
list="`$(xui_api_get /panel/api/inbounds/list)"
printf '%s' "`$list" | jq -c --arg one '$($controller.Id)' --arg two '$($traffic.Id)' '.obj[]? | select(any(.settings.clients[]?; (.comment // "") == ("pna-device:" + `$one) or (.comment // "") == ("pna-device:" + `$two)))' | while IFS= read -r object; do
  id="`$(jq -r '.id' <<<"`$object")"
  payload="`$(jq -c --arg one '$($controller.Id)' --arg two '$($traffic.Id)' '{enable,remark,listen,port,protocol,expiryTime,total,settings,streamSettings,sniffing,tag,allocate,subSortIndex,trafficReset,trafficResetDay,shareAddrStrategy,shareAddr} | .settings.clients |= map(select((.comment // "") != ("pna-device:" + `$one) and (.comment // "") != ("pna-device:" + `$two)))' <<<"`$object")"
  response="`$(xui_api_post_json "/panel/api/inbounds/update/`$id" "`$payload")"
  jq -e '.success == true' <<<"`$response" >/dev/null
done
if [ -s /etc/proxy-runbook/device-registry.json ] && jq -e --arg one '$($controller.Id)' --arg two '$($traffic.Id)' 'all(.devices[]?; .deviceId==`$one or .deviceId==`$two)' /etc/proxy-runbook/device-registry.json >/dev/null; then
  rm -f /etc/proxy-runbook/device-registry.json
fi
"@
		$cleanup = Invoke-Remote $cleanupCommand
		if ($cleanup.ExitCode -ne 0) { Write-Error "Remote device-test cleanup failed" }
	}
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Get-ChildItem -LiteralPath $resolved -File | Remove-Item -Force
        Remove-Item -LiteralPath $resolved -Force
    }
}
