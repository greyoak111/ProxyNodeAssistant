param(
    [string]$OutputFile = (Join-Path $PSScriptRoot "dist\ProxyNodeAssistant-v0.9.0-android-universal.apk"),
    [switch]$Provision
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $projectRoot ".android-tools"
$jdkRoot = Join-Path $toolsRoot "jdk-17"
$sdkRoot = Join-Path $toolsRoot "sdk"
$signingRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "ProxyNodeAssistant\android-signing"
$keystore = Join-Path $signingRoot "pna-release-v1.jks"
$protectedPasswordFile = Join-Path $signingRoot "pna-release-v1.password.dpapi"

& (Join-Path $PSScriptRoot "build-android.ps1") -Task Release -Provision:$Provision

New-Item -ItemType Directory -Force -Path $signingRoot | Out-Null
if (-not (Test-Path -LiteralPath $protectedPasswordFile)) {
    $random = [byte[]]::new(36)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $plain = [Convert]::ToBase64String($random).Replace('+','A').Replace('/','B')
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    ConvertFrom-SecureString -SecureString $secure | Set-Content -LiteralPath $protectedPasswordFile -Encoding ascii
    [Array]::Clear($random, 0, $random.Length)
    $plain = $null
}
$encrypted = Get-Content -LiteralPath $protectedPasswordFile -Raw
$securePassword = ConvertTo-SecureString $encrypted.Trim()
$credential = [PSCredential]::new("pna", $securePassword)
$password = $credential.GetNetworkCredential().Password
$env:PNA_ANDROID_SIGN_PASS = $password

try {
    $keytool = Join-Path $jdkRoot "bin\keytool.exe"
    if (-not (Test-Path -LiteralPath $keystore)) {
        & $keytool -genkeypair -keystore $keystore -alias pna-release-v1 -storetype PKCS12 -storepass:env PNA_ANDROID_SIGN_PASS -keypass:env PNA_ANDROID_SIGN_PASS -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=ProxyNodeAssistant, OU=Self-hosted Release, O=ProxyNodeAssistant, C=XX"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $keystore)) { throw "Could not generate the persistent Android release signing key" }
    }

    $unsigned = Join-Path $PSScriptRoot "app\build\outputs\apk\release\app-release-unsigned.apk"
    $buildTools = Join-Path $sdkRoot "build-tools\36.0.0"
    $zipalign = Join-Path $buildTools "zipalign.exe"
    $apksigner = Join-Path $buildTools "apksigner.bat"
    $destination = [IO.Path]::GetFullPath($OutputFile)
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $aligned = Join-Path $destinationDirectory "pna-release-aligned.tmp.apk"
    if (Test-Path -LiteralPath $aligned) { Remove-Item -LiteralPath $aligned -Force }
    & $zipalign -f -p 4 $unsigned $aligned
    if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }
    & $apksigner sign --ks $keystore --ks-key-alias pna-release-v1 --ks-pass env:PNA_ANDROID_SIGN_PASS --key-pass env:PNA_ANDROID_SIGN_PASS --out $destination $aligned
    if ($LASTEXITCODE -ne 0) { throw "APK signing failed" }
    Remove-Item -LiteralPath $aligned -Force
    & $apksigner verify --verbose --print-certs $destination
    if ($LASTEXITCODE -ne 0) { throw "Signed APK verification failed" }
    Get-FileHash -Algorithm SHA256 -LiteralPath $destination | Format-List Hash,Path
    Write-Host "Signing key retained at: $keystore"
    Write-Host "Back up that keystore and its DPAPI password file; Android updates require the same signing identity."
} finally {
    Remove-Item Env:PNA_ANDROID_SIGN_PASS -ErrorAction SilentlyContinue
    $password = $null
    $credential = $null
    $securePassword = $null
}
