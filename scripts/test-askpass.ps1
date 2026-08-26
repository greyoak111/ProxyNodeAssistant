param(
    [Parameter(Mandatory = $true)]
    [string]$AskPassExe
)

$ErrorActionPreference = "Stop"
$resolved = (Resolve-Path -LiteralPath $AskPassExe).Path
$pipe = "TNA-ASKPASS-SMOKE-" + [Guid]::NewGuid().ToString("N")
$job = Start-Job -ScriptBlock {
    param($PipeName)
    $server = [IO.Pipes.NamedPipeServerStream]::new($PipeName, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte)
    try {
        $server.WaitForConnection()
        $reader = [IO.BinaryReader]::new($server, [Text.UTF8Encoding]::new($false), $true)
        $writer = [IO.BinaryWriter]::new($server, [Text.UTF8Encoding]::new($false), $true)
        $prompt = $reader.ReadString()
        $writer.Write("askpass-smoke-response")
        $writer.Flush()
        $prompt
    } finally {
        $server.Dispose()
    }
} -ArgumentList $pipe

try {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $resolved
    $start.Arguments = '"smoke password prompt"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.EnvironmentVariables["TNA_ASKPASS_PIPE"] = $pipe
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $output = $process.StandardOutput.ReadToEnd().Trim()
    if (-not $process.WaitForExit(10000)) {
        try { $process.Kill() } catch { }
        throw "AskPass helper timed out"
    }
    $prompt = Receive-Job -Job $job -Wait
    if ($process.ExitCode -ne 0 -or $output -ne "askpass-smoke-response" -or $prompt -notmatch "smoke password prompt") {
        throw "AskPass named-pipe protocol verification failed"
    }
    "ASKPASS_NAMED_PIPE_SMOKE_OK"
} finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
