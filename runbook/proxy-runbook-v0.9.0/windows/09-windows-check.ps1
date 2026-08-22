$ErrorActionPreference = "Continue"

$ip = Read-Host 'VPS public IP'
$domain = Read-Host 'Cover domain'
$portRaw = Read-Host 'Reality test/production port [default 443]'
$port = if ([string]::IsNullOrWhiteSpace($portRaw)) { 443 } else { [int]$portRaw }
$localRaw = Read-Host 'Local v2rayN SOCKS/Mixed port [default 10808]'
$localPort = if ([string]::IsNullOrWhiteSpace($localRaw)) { 10808 } else { [int]$localRaw }

Write-Host "`n===== DNS ====="
Resolve-DnsName $domain -ErrorAction Continue

Write-Host "`n===== VPS TCP ====="
Test-NetConnection $ip -Port $port

Write-Host "`n===== LOCAL PROXY LISTENER ====="
Get-NetTCPConnection -State Listen -LocalPort $localPort -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess

Write-Host "`n===== PROXY EXIT ====="
& curl.exe --socks5-hostname "127.0.0.1:$localPort" --max-time 20 https://api.ipify.org
Write-Host ""

Write-Host "`n===== NORMAL TLS / REALITY FALLBACK ====="
if ($port -eq 443) {
    & curl.exe --noproxy "*" --resolve "${domain}:443:${ip}" "https://${domain}/" -I --max-time 20
} else {
    & curl.exe --noproxy "*" --resolve "${domain}:${port}:${ip}" "https://${domain}:${port}/" -I --max-time 20
}

Write-Host "`n===== NOTE ====="
Write-Host "A Cloudflare 403 from chatgpt.com HEAD/curl is not by itself proof that the proxy is broken."
