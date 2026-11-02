# Starts the real Windows dial and checks it comes up: it starts dial-core,
# connects, stays alive, and takes the core down with it when it goes. This
# doesn't exercise scrolling or the microphone. It runs in CI, on a machine
# with no one at it.
param([string]$Dir = "dist/windows")
$ErrorActionPreference = "Stop"
$Dir = (Resolve-Path $Dir).Path
$env:DIAL_CONFIG_DIR = Join-Path ([IO.Path]::GetTempPath()) ("dial-smoke-" + [guid]::NewGuid())

function Stop-All {
    Get-Process dial, dial-core -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Fail($why) {
    Write-Host "FAIL: $why"
    Stop-All
    exit 1
}

# What dial-core says to a client: its hello, with what it knows of the dial.
function Ask-Core {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $client.ReceiveTimeout = 2000
        $client.SendTimeout = 2000
        $client.Connect("127.0.0.1", 47831)
        $stream = $client.GetStream()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.NewLine = "`n"
        $writer.WriteLine('{"type":"hello","platform":"smoke","version":"0"}')
        $writer.Flush()
        $line = [IO.StreamReader]::new($stream).ReadLine()
        $client.Close()
        return $line | ConvertFrom-Json
    } catch {
        return $null
    }
}

Write-Host "Starting $Dir\dial.exe"
$dial = Start-Process (Join-Path $Dir "dial.exe") -PassThru

# It starts dial-core next to itself, and connects.
$hello = $null
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    if ($dial.HasExited) { Fail "dial.exe exited with $($dial.ExitCode) before connecting" }
    $hello = Ask-Core
    if ($hello -and $hello.dial.connected) { break }
    Start-Sleep -Milliseconds 500
}
if (-not ($hello -and $hello.dial.connected)) { Fail "the dial never connected to dial-core" }
if ($hello.dial.platform -ne "windows") { Fail "the core says the dial is on '$($hello.dial.platform)'" }
Write-Host "PASS the dial started dial-core and connected"

# It stays up: drawing and the app list run on timers, so a crash takes a moment.
Start-Sleep -Seconds 8
if ($dial.HasExited) { Fail "dial.exe exited with $($dial.ExitCode) after connecting" }
$hello = Ask-Core
if (-not ($hello -and $hello.dial.connected)) { Fail "the dial dropped its connection" }
Write-Host "PASS the dial is still up and connected after 8 seconds"

# A theme in the config reaches the dial, which resizes itself.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DialWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    public static int Width() {
        Rect r;
        var hwnd = FindWindow("DialWindow", null);
        return hwnd != IntPtr.Zero && GetWindowRect(hwnd, out r) ? r.Right - r.Left : -1;
    }
}
'@
$normal = [DialWindow]::Width()
if ($normal -le 0) { Fail "can't find the dial's window" }
$configPath = Join-Path $env:DIAL_CONFIG_DIR "config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$config.theme = [pscustomobject]@{ size = 1.5; transparency = 0.25 }
$config | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding utf8
$deadline = (Get-Date).AddSeconds(10)
$want = [int][math]::Round($normal * 1.5)
while ((Get-Date) -lt $deadline) {
    if ([DialWindow]::Width() -eq $want) { break }
    Start-Sleep -Milliseconds 200
}
if ([DialWindow]::Width() -ne $want) { Fail "the dial is $([DialWindow]::Width()) wide, not $want, after a theme of 1.5" }
if ($dial.HasExited) { Fail "dial.exe exited with $($dial.ExitCode) on a theme change" }
Write-Host "PASS a theme of 1.5 took the dial from $normal to $want wide"

# The core watches its parent: killing the dial must not leave it behind.
Stop-Process -Id $dial.Id -Force
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process dial-core -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}
if (Get-Process dial-core -ErrorAction SilentlyContinue) { Fail "dial-core outlived the dial" }
Write-Host "PASS dial-core exited with the dial"
Stop-All
