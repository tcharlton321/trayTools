<#
    TrayMeters - CPU, RAM, GPU and VRAM usage as a taskbar (notification area) icon.
    Bars left to right: CPU, RAM | GPU, VRAM. Hover for exact numbers.

    CPU/RAM come from performance counters. GPU/VRAM come from nvidia-smi run
    once in --loop mode, with its output read on a background thread (see
    TrayMetersGpu below) - spawning nvidia-smi on every timer tick would cost
    ~50ms of the UI thread each time, and PowerShell's Register-ObjectEvent
    queue is not pumped reliably from inside [Application]::Run.

    On a machine with no NVIDIA GPU the script degrades to the original
    two-bar CPU/RAM icon.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

public static class TrayMetersNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}

public static class TrayMetersGpu {
    private static volatile int _util;
    private static volatile int _usedMB;
    private static volatile int _totalMB;
    private static Process _proc;
    private static volatile bool _stopping;

    public static int Util    { get { return _util; } }
    public static int UsedMB  { get { return _usedMB; } }
    public static int TotalMB { get { return _totalMB; } }

    // Only true once a sample has actually been parsed, so the caller can
    // fall back to a CPU/RAM-only icon on non-NVIDIA machines.
    public static bool Available { get { return _totalMB > 0; } }

    public static void Start(string exePath) {
        // explicit ThreadStart cast: an untyped delegate{} is ambiguous
        // between ThreadStart and ParameterizedThreadStart for Add-Type's compiler
        Thread t = new Thread((ThreadStart)delegate { Loop(exePath); });
        t.IsBackground = true;
        t.Start();
    }

    private static void Loop(string exePath) {
        while (!_stopping) {
            try {
                ProcessStartInfo psi = new ProcessStartInfo(exePath,
                    "--query-gpu=utilization.gpu,memory.used,memory.total " +
                    "--format=csv,noheader,nounits --loop=2");
                psi.RedirectStandardOutput = true;
                psi.UseShellExecute        = false;
                psi.CreateNoWindow         = true;

                using (Process p = Process.Start(psi)) {
                    _proc = p;
                    string line;
                    while ((line = p.StandardOutput.ReadLine()) != null) {
                        if (_stopping) break;
                        string[] f = line.Split(',');
                        if (f.Length < 3) continue;
                        int v;
                        if (TryNum(f[0], out v)) _util    = v;
                        if (TryNum(f[1], out v)) _usedMB  = v;
                        if (TryNum(f[2], out v)) _totalMB = v;
                    }
                }
            } catch { }

            // nvidia-smi exited (driver reload, sleep/resume, TDR). Back off
            // and respawn rather than leaving the gauge frozen forever.
            if (!_stopping) Thread.Sleep(5000);
        }
    }

    private static bool TryNum(string s, out int value) {
        return int.TryParse(s.Trim(), NumberStyles.Integer,
                            CultureInfo.InvariantCulture, out value);
    }

    public static void Stop() {
        _stopping = true;
        try {
            Process p = _proc;
            if (p != null && !p.HasExited) p.Kill();
        } catch { }
    }
}
'@

# ---------- counters ----------
try {
    $cpuCounter = New-Object System.Diagnostics.PerformanceCounter 'Processor Information', '% Processor Utility', '_Total'
    [void]$cpuCounter.NextValue()
} catch {
    $cpuCounter = New-Object System.Diagnostics.PerformanceCounter 'Processor Information', '% Processor Time', '_Total'
    [void]$cpuCounter.NextValue()
}
$availCounter = New-Object System.Diagnostics.PerformanceCounter 'Memory', 'Available MBytes'
[void]$availCounter.NextValue()

$totalRamMB = [double](Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1024

# ---------- gpu feed ----------
$nvidiaSmi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
if (-not $nvidiaSmi) {
    $candidate = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $candidate) { $nvidiaSmi = $candidate }
}
if ($nvidiaSmi) { [TrayMetersGpu]::Start($nvidiaSmi) }

# ---------- drawing ----------
$iconSize = [System.Math]::Max(16, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)

function Get-LoadColor([double]$pct) {
    if ($pct -ge 90) { return [System.Drawing.Color]::FromArgb(255, 95,  85) }
    if ($pct -ge 70) { return [System.Drawing.Color]::FromArgb(255, 196, 60) }
    return [System.Drawing.Color]::FromArgb(88, 214, 118)
}

# Bars are grouped in pairs (CPU|RAM, GPU|VRAM) with a wider gap between the
# groups than within them, so four 3px bars stay readable in a 16px icon.
function New-MeterIcon([double[]]$values, [int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)

    $n = $values.Count
    if ($n -le 2) {
        $innerGap = [int][System.Math]::Max(2, [System.Math]::Round($size * 0.14))
        $groupGap = 0
        $barW     = [int][System.Math]::Floor(($size - $innerGap) / 2)
    } else {
        $innerGap = [int][System.Math]::Max(1, [System.Math]::Round($size * 0.06))
        $groupGap = [int][System.Math]::Max(2, [System.Math]::Round($size * 0.14))
        $barW     = [int][System.Math]::Floor(($size - 2 * $innerGap - $groupGap) / 4)
    }
    if ($barW -lt 1) { $barW = 1 }

    # Centre the bar block: at 16px it fills exactly, but at 20/24px (higher
    # DPI) the integer division leaves a few pixels of slack on the right.
    if ($n -le 2) { $used = 2 * $barW + $innerGap }
    else          { $used = 4 * $barW + 2 * $innerGap + $groupGap }
    $x = [int][System.Math]::Floor(($size - $used) / 2)
    if ($x -lt 0) { $x = 0 }

    $track = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 130, 130, 140))

    for ($i = 0; $i -lt $n; $i++) {
        $p = [System.Math]::Min(100, [System.Math]::Max(0, $values[$i]))

        $g.FillRectangle($track, $x, 0, $barW, $size)
        $h = [int][System.Math]::Round($size * $p / 100)
        if ($h -lt 1 -and $p -gt 0) { $h = 1 }
        if ($h -gt 0) {
            $brush = New-Object System.Drawing.SolidBrush (Get-LoadColor $p)
            $g.FillRectangle($brush, $x, $size - $h, $barW, $h)
            $brush.Dispose()
        }

        # wider gap after bar 2 separates the CPU/RAM pair from the GPU/VRAM pair
        $x += $barW + $(if ($i -eq 1) { $groupGap } else { $innerGap })
    }

    $track.Dispose()
    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hIcon).Clone()
    [void][TrayMetersNative]::DestroyIcon($hIcon)
    $bmp.Dispose()
    return $icon
}

# ---------- startup shortcut helpers ----------
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'TrayMeters.lnk'
$launcher    = Join-Path $PSScriptRoot 'TrayMeters.vbs'

function Set-RunAtStartup([bool]$enable) {
    if ($enable) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($startupLink)
        $lnk.TargetPath  = 'wscript.exe'
        $lnk.Arguments   = '"' + $launcher + '"'
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Description = 'TrayMeters - CPU/RAM/GPU/VRAM tray gauge'
        $lnk.Save()
    } elseif (Test-Path $startupLink) {
        Remove-Item $startupLink -Force
    }
}

# ---------- tray icon ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text    = 'TrayMeters starting...'
$notify.Icon    = New-MeterIcon @(0, 0) $iconSize
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miTaskMgr = $menu.Items.Add('Open Task Manager')
$miTaskMgr.add_Click({ Start-Process taskmgr.exe })

$miResMon = $menu.Items.Add('Open Resource Monitor')
$miResMon.add_Click({ Start-Process resmon.exe })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-Path $startupLink
$miStartup.add_Click({ Set-RunAtStartup $miStartup.Checked })
[void]$menu.Items.Add($miStartup)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = $menu.Items.Add('Exit')
$miExit.add_Click({
    [TrayMetersGpu]::Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notify.ContextMenuStrip = $menu
$notify.add_MouseDoubleClick({ Start-Process taskmgr.exe })

# ---------- refresh loop ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.add_Tick({
    $cpu     = [double]$cpuCounter.NextValue()
    $availMB = [double]$availCounter.NextValue()
    $usedMB  = $totalRamMB - $availMB
    $ram     = if ($totalRamMB -gt 0) { 100 * $usedMB / $totalRamMB } else { 0 }

    $gpuOk = [TrayMetersGpu]::Available
    if ($gpuOk) {
        $gpu       = [double][TrayMetersGpu]::Util
        $vramUsed  = [double][TrayMetersGpu]::UsedMB
        $vramTotal = [double][TrayMetersGpu]::TotalMB
        $vram      = 100 * $vramUsed / $vramTotal
        $values    = @($cpu, $ram, $gpu, $vram)
    } else {
        $values = @($cpu, $ram)
    }

    $old = $notify.Icon
    $notify.Icon = New-MeterIcon $values $iconSize
    if ($old) { $old.Dispose() }

    # NotifyIcon.Text on .NET Framework throws above 63 chars, so keep both
    # lines terse and truncate defensively rather than risk killing the timer.
    $tip = 'CPU {0:0}% | RAM {1:0}% {2:0.0}/{3:0.0}G' -f $cpu, $ram, ($usedMB / 1024), ($totalRamMB / 1024)
    if ($gpuOk) {
        $tip += "`nGPU {0:0}% | VRAM {1:0}% {2:0.0}/{3:0.0}G" -f `
            $gpu, $vram, ($vramUsed / 1024), ($vramTotal / 1024)
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip
})
$timer.Start()

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

[TrayMetersGpu]::Stop()
