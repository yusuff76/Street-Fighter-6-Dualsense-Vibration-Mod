$ErrorActionPreference = 'Stop'
$gameFolder = 'C:\Games\Street Fighter 6'
$helper = Join-Path $gameFolder 'Start-Rumble.ps1'
$gameExe = Join-Path $gameFolder 'StreetFighter6.exe'
$lock = [Threading.Mutex]::new($false, 'Local\SF6RumbleLauncher')
if (!$lock.WaitOne(0)) { $lock.Dispose(); return }
try {
    if (!(Test-Path -LiteralPath $helper)) { throw "Missing helper: $helper" }
    $game = Get-Process -Name StreetFighter6 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$game) {
        Start-Process -FilePath $gameExe -WorkingDirectory $gameFolder
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        do {
            Start-Sleep -Seconds 1
            $game = Get-Process -Name StreetFighter6 -ErrorAction SilentlyContinue | Select-Object -First 1
        } until ($game -or [DateTime]::UtcNow -gt $deadline)
        if (!$game) { throw 'Street Fighter 6 did not start within three minutes.' }
    }
    # One isolated helper per XInput slot; each accepts only its addressed events.
    $slots = @(0,1)
    $configPath = Join-Path $gameFolder 'reframework\data\sf6_rumble_2p.json'
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($null -eq $config.p1 -or $null -eq $config.p2 -or $config.p1 -notin 0..3 -or $config.p2 -notin 0..3 -or $config.p1 -eq $config.p2) {
            throw 'P1 and P2 must have different XInput slots (0..3). Adjust the REFramework menu.'
        }
        $slots = @([int]$config.p1,[int]$config.p2)
    }
    $children = @()
    foreach ($slot in $slots) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Index {1} -GameFolder "{2}"' -f $helper,$slot,$gameFolder
        $children += Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WorkingDirectory $gameFolder -WindowStyle Hidden -PassThru
    }
    foreach ($child in $children) { $child.WaitForExit() }
} catch {
    $message = $_.Exception.Message
    if ($message -notlike '*helper already controls*') {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message, 'SF6 Rumble') | Out-Null
    }
} finally {
    $lock.ReleaseMutex()
    $lock.Dispose()
}
