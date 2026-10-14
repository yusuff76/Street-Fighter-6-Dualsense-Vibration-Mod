param(
    [ValidateRange(0,3)][int]$Index = 0,
    [string]$GameFolder = $PSScriptRoot,
    [switch]$Test,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
function Test-RumbleDestination($Event, [int]$Slot) {
    return ($null -ne $Event.index -and $Event.index -in 0..3 -and $Event.index -eq $Slot)
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class SF6Rumble {
    [StructLayout(LayoutKind.Sequential)] public struct Vibration { public ushort Left, Right; }
    [DllImport("xinput1_4.dll", EntryPoint="XInputSetState")]
    static extern uint SetState(uint index, ref Vibration vibration);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    sealed class Pulse { public double End; public ushort Left, Right; }
    static readonly object Gate = new object();
    static readonly List<Pulse> Pulses = new List<Pulse>();
    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static Timer timer;
    static uint slot, gamePid;
    static bool testMode;
    static double heartbeat;
    public static uint LastResult = 0;
    public static bool DryRun = false;
    public static ushort LastLeft, LastRight;
    static void Write(Vibration v) {
        LastLeft=v.Left; LastRight=v.Right;
        LastResult=DryRun ? 0 : SetState(slot, ref v);
    }
    public static int ActiveCount { get { lock(Gate) { return Pulses.Count; } } }
    public static double Now { get { return Clock.Elapsed.TotalMilliseconds; } }
    public static void Start(uint index, uint pid, bool test) {
        slot=index; gamePid=pid; testMode=test; heartbeat=Now;
        timer = new Timer(Tick, null, 0, 10);
    }
    public static void Beat() { lock(Gate) { heartbeat=Now; } }
    public static void Add(double left, double right, int ms) {
        if (Double.IsNaN(left) || Double.IsNaN(right) || left<0 || left>1 || right<0 || right>1 || ms<1 || ms>450)
            throw new ArgumentOutOfRangeException("pulse");
        lock(Gate) {
            if (Pulses.Count >= 64) Pulses.RemoveAt(0);
            Pulses.Add(new Pulse {End=Now+ms, Left=(ushort)(left*65535), Right=(ushort)(right*65535)});
        }
    }
    public static void Stop() {
        lock(Gate) { Pulses.Clear(); Write(new Vibration()); }
    }
    static void Tick(object unused) {
        lock(Gate) {
            uint foreground=gamePid;
            if (!testMode) GetWindowThreadProcessId(GetForegroundWindow(), out foreground);
            if ((!testMode && foreground!=gamePid) || Now-heartbeat>500) Pulses.Clear();
            var v = new Vibration();
            for(int i=Pulses.Count-1;i>=0;i--) {
                var p=Pulses[i];
                if (Now>=p.End) {Pulses.RemoveAt(i); continue;}
                v.Left=Math.Max(v.Left,p.Left); v.Right=Math.Max(v.Right,p.Right);
            }
            Write(v);
        }
    }
    public static void Close() { if(timer!=null) timer.Dispose(); Stop(); }
}
'@
if ($SelfTest) {
    foreach ($slot in 0..3) {
        foreach ($target in 0..3) {
            if ((Test-RumbleDestination ([pscustomobject]@{index=$target}) $slot) -ne ($slot -eq $target)) { throw 'Slot routing failed' }
        }
        if (Test-RumbleDestination ([pscustomobject]@{}) $slot) { throw 'Missing destination accepted' }
    }
    if ([Runtime.InteropServices.Marshal]::SizeOf([type][SF6Rumble+Vibration]) -ne 4) { throw 'Wrong vibration ABI' }
    [SF6Rumble]::Add(0.2,0.3,75)
    if ([SF6Rumble]::ActiveCount -ne 1) { throw 'Pulse queue failed' }
    $caught = $false
    try { [SF6Rumble]::Add(2,0,75) } catch { $caught = $true }
    if (!$caught) { throw 'Pulse range validation failed' }
    [SF6Rumble]::DryRun=$true
    [SF6Rumble]::Start(0,0,$true)
    try {
        [SF6Rumble]::Stop()
        [SF6Rumble]::Add(0.8,0.9,80)
        [SF6Rumble]::Add(0.2,0.3,220)
        Start-Sleep -Milliseconds 35
        if ([SF6Rumble]::LastLeft -lt 50000) { throw 'Overlapping strong pulse lost' }
        Start-Sleep -Milliseconds 100
        if ([SF6Rumble]::LastLeft -gt 15000 -or [SF6Rumble]::LastLeft -eq 0) { throw 'Independent pulse expiry failed' }
        Start-Sleep -Milliseconds 120
        if ([SF6Rumble]::LastLeft -ne 0) { throw 'Pulse stop failed' }
        [SF6Rumble]::Beat()
        Start-Sleep -Milliseconds 350
        [SF6Rumble]::Add(0.8,0.8,450)
        Start-Sleep -Milliseconds 220
        if ([SF6Rumble]::LastLeft -ne 0) { throw 'Heartbeat watchdog failed' }
    } finally { [SF6Rumble]::Close() }
    Write-Host 'PASS: compilation, XInput ABI, range validation, pulse overlap, expiry and watchdog. No motor calls.'
    return
}
$mutex = [Threading.Mutex]::new($false, "Local\SF6RumbleSlot$Index")
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); throw "A helper already controls XInput slot $Index." }
try {
    if ($Test) {
        [SF6Rumble]::Start($Index,0,$true)
        foreach ($p in @(@('normal',0.22,0.35,75),@('heavy',0.55,0.65,130),@('di',0.85,1.0,220),@('super',1.0,0.85,400))) {
            [SF6Rumble]::Beat()
            [SF6Rumble]::Add($p[1],$p[2],$p[3])
            Start-Sleep -Milliseconds 450
            Write-Host "$($p[0]): XInput result $([SF6Rumble]::LastResult) (0=success, 1167=not connected)"
            Start-Sleep -Milliseconds 550
        }
        return
    }
    $game = Get-Process -Name StreetFighter6 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$game) { throw 'Start Street Fighter 6 first, then run this helper.' }
    $bus = Join-Path $GameFolder 'reframework\data\sf6_rumble_bus.json'
    [SF6Rumble]::Start($Index,[uint32]$game.Id,$false)
    Write-Host "Watching $bus | XInput slot $Index. Keep this window open; Ctrl+C stops."
    $session = ''; $beat = -1; $seen = 0; $lastChange = [SF6Rumble]::Now
    $lastCode = -1
    while (!$game.HasExited) {
        try {
            $packet = [IO.File]::ReadAllText($bus) | ConvertFrom-Json
            if ($packet.version -ne 2 -or !$packet.session) { throw 'Invalid packet' }
            if ($packet.session -ne $session) {
                [SF6Rumble]::Stop()
                $session = $packet.session; $beat = $packet.heartbeat
                $seen = 0
                foreach ($event in $packet.events) { $seen = [Math]::Max($seen,[long]$event.id) }
                $lastChange = [SF6Rumble]::Now
                # Baseline only: never replay an old file at startup or script reload.
            } elseif ($packet.heartbeat -ne $beat) {
                $gap = [SF6Rumble]::Now - $lastChange
                $lastChange = [SF6Rumble]::Now; $beat = $packet.heartbeat
                [SF6Rumble]::Beat()
                if (!$packet.enabled -or $gap -gt 500) { [SF6Rumble]::Stop() }
                foreach ($event in $packet.events) {
                    if ([long]$event.id -gt $seen) {
                        $seen = [long]$event.id
                        if ($packet.enabled -and $gap -le 500 -and (Test-RumbleDestination $event $Index)) {
                            [SF6Rumble]::Add([double]$event.left,[double]$event.right,[int]$event.ms)
                            Write-Host "P$($event.player) $($event.role) $($event.kind): $($event.ms) ms"
                        }
                    }
                }
            }
        } catch {
            # A writer can temporarily truncate/lock the file. Retry, never refresh
            # the watchdog on a bad read. Native timer stops even if this loop stalls.
        }
        $code = [SF6Rumble]::LastResult
        if ($code -ne $lastCode) { Write-Host "XInput=$code (0=success; 1167=slot disconnected)"; $lastCode=$code }
        Start-Sleep -Milliseconds 10
    }
} finally {
    [SF6Rumble]::Close()
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
