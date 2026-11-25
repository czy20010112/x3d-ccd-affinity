<#
.SYNOPSIS
    X3D CCD Affinity Tray - 右下角托盘，为正在运行的程序/游戏设置 CCD 亲和性。

.DESCRIPTION
    Ryzen 9 9950X3D / 7950X3D / 9900X3D 等双 CCD X3D 处理器：
        CCD0 = 逻辑 CPU 0-15  -> 96 MB 3D V-Cache，游戏首选
        CCD1 = 逻辑 CPU 16-31 -> 32 MB，频率略高

    左键单击托盘图标打开面板。面板列出所有带窗口的进程，
    可点击表头排序，可选中后一键绑定 CCD0 / CCD1 / 恢复全部核心。
    "记住选中程序" 会把 exe 写入 config.json，由后台守护进程长期生效。

.PARAMETER ToolDir
    工具目录，默认是本脚本所在目录。

.PARAMETER Silence
    启动时不弹出面板，只驻留托盘。
#>
[CmdletBinding()]
param(
    [string]$ToolDir = $PSScriptRoot,
    [switch]$Silence
)

$ErrorActionPreference = 'Stop'

# top-level safety net: record any unhandled error so a hidden tray never dies silently
trap {
    try {
        $fatalDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path -LiteralPath $fatalDir)) { New-Item -ItemType Directory -Path $fatalDir -Force | Out-Null }
        $fatal = Join-Path $fatalDir 'fatal.log'
        $msg = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " FATAL`r`n" + ($_ | Out-String -Width 250) + "`r`n" + (Get-PSCallStack | Out-String -Width 250)
        Add-Content -LiteralPath $fatal -Value $msg -Encoding utf8
    } catch { }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------- paths

$ConfigPath = Join-Path $ToolDir 'config.json'
$GuardPath  = Join-Path $ToolDir 'X3D-CCDAffinity.ps1'
$LogDir     = Join-Path $ToolDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ---------------------------------------------------------------- state

$script:IsAdmin  = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:MaskCcd0 = [int64]0xFFFF
$script:MaskCcd1 = [int64]0xFFFF0000
$script:MaskAll  = [int64](([int64]1 -shl [Environment]::ProcessorCount) - 1)
$script:Config   = $null
$script:KnownExe = @{}          # lowercase exe -> group name from config
$script:ConfigStamp = [datetime]::MinValue
$script:SkipNames = @('ApplicationFrameHost','TextInputHost','SystemSettings','ShellExperienceHost','SearchHost','StartMenuExperienceHost','LockApp','PickerHost','WidgetService','Widgets','SecurityHealthSystray','ShellHost','X3D-Tray-Admin')

# daily log files: tray-YYYY-MM-DD.log
$script:LogPrefix     = 'tray'
$script:LogRetainDays = 14
$script:QuietTicks    = 0
$script:LogPath       = $null
$script:LogDate       = $null

# binding provenance: pid -> 'manual' | 'config' | 'inherited'
$script:SourceMap = @{}
$script:SeenPids  = @{}

# view state
$script:Rows        = @()
$script:SortColumn  = 'Name'
$script:SortAsc     = $true
$script:FilterMode  = 'all'
$script:SearchText  = ''
$script:HoverIndex  = -1
$script:Updating    = $false

function Update-TrayLogPath {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:LogDate -ne $today) {
        $script:LogDate = $today
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $script:LogPath = Join-Path $LogDir ('{0}-{1}.log' -f $script:LogPrefix, $today)
        try {
            $days = if ($script:LogRetainDays -gt 0) { $script:LogRetainDays } else { 14 }
            $cutoff = (Get-Date).Date.AddDays(-1 * $days)
            Get-ChildItem -LiteralPath $LogDir -Filter ('{0}-*.log' -f $script:LogPrefix) -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-TrayLog {
    param([string]$Message)
    try {
        Update-TrayLogPath
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    } catch { }
}

function Get-CurrentTrayLogPath {
    Update-TrayLogPath
    if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { return $script:LogPath }
    $latest = Get-ChildItem -LiteralPath $LogDir -Filter ('{0}-*.log' -f $script:LogPrefix) -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

# ---------------------------------------------------------------- config

function Convert-MaskText {
    param([string]$Text)
    if ($Text -match '^0x([0-9a-fA-F]+)$') { return [int64][Convert]::ToInt64($matches[1], 16) }
    if ($Text -match '^\d+$') { return [int64]$Text }
    return [int64]0
}

function Read-ConfigSafe {
    try {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $known = @{}
        foreach ($g in $cfg.groups) {
            if (-not $g.enabled) { continue }
            foreach ($p in $g.processes) {
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                $known[$p.Trim().ToLowerInvariant()] = $g.name
            }
        }
        $script:KnownExe = $known
        $script:ConfigStamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        $script:Config = $cfg
        return $cfg
    } catch {
        Write-TrayLog ("config read failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-GroupMask {
    param([string]$GroupName)
    if (-not $script:Config) { return [int64]0 }
    $g = $script:Config.groups | Where-Object { $_.name -eq $GroupName } | Select-Object -First 1
    if (-not $g) { return [int64]0 }
    return (Convert-MaskText ([string]$g.mask))
}

function Add-ExeToConfig {
    param([string]$ExeName, [string]$GroupName)
    try {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8
        $cfg = $raw | ConvertFrom-Json
        $grp = $cfg.groups | Where-Object { $_.name -eq $GroupName } | Select-Object -First 1
        if (-not $grp) { return $false }
        $list = @($grp.processes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($x in $list) { if ($x.Trim().ToLowerInvariant() -eq $ExeName.ToLowerInvariant()) { return $false } }
        $grp.processes = @($list + $ExeName)
        $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
        Write-TrayLog ("added {0} to group {1}" -f $ExeName, $GroupName)
        [void](Read-ConfigSafe)
        return $true
    } catch {
        Write-TrayLog ("config write failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-AffinityOf {
    param($Process)
    try {
        $a = [int64]$Process.ProcessorAffinity
        if ($a -le 0) { return [int64]-1 }
        return $a
    } catch { return [int64]-1 }
}

function Set-AffinitySafe {
    param($Process, [int64]$Mask)
    try {
        if ($Process.HasExited) { return $false }
        $Process.ProcessorAffinity = [IntPtr]$Mask
        return $true
    } catch {
        return $false
    }
}

# single instance guard - an exclusive file handle; released automatically when this process dies
$lockPath = Join-Path $LogDir 'tray.lock'
try {
    $script:InstanceLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch {
    Write-TrayLog 'another tray instance already running - new instance exits'
    exit 0
}

# ================================================================ THEME

$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(13, 17, 23)
    Panel     = [System.Drawing.Color]::FromArgb(22, 27, 34)
    Panel2    = [System.Drawing.Color]::FromArgb(28, 34, 43)
    Border    = [System.Drawing.Color]::FromArgb(48, 54, 61)
    Text      = [System.Drawing.Color]::FromArgb(230, 237, 243)
    Muted     = [System.Drawing.Color]::FromArgb(139, 148, 158)
    Dim       = [System.Drawing.Color]::FromArgb(110, 118, 129)
    Teal      = [System.Drawing.Color]::FromArgb(45, 212, 191)
    Blue      = [System.Drawing.Color]::FromArgb(96, 165, 250)
    Green     = [System.Drawing.Color]::FromArgb(52, 211, 153)
    Amber     = [System.Drawing.Color]::FromArgb(251, 191, 36)
    Indigo    = [System.Drawing.Color]::FromArgb(129, 140, 248)
    Red       = [System.Drawing.Color]::FromArgb(248, 113, 113)
    Hover     = [System.Drawing.Color]::FromArgb(33, 40, 50)
    Selected  = [System.Drawing.Color]::FromArgb(30, 58, 70)
}

$FontUI     = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$FontUIBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$FontTitle  = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$FontSub    = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$FontMono   = New-Object System.Drawing.Font('Consolas', 9)

function New-RoundedPath {
    param([System.Drawing.RectangleF]$Rect, [float]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -le 0) { $p.AddRectangle($Rect); return $p }
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Pill {
    param($G, [System.Drawing.Rectangle]$Rect, [string]$Text, $Back, $Fore, $Font)
    if (-not $Font) { $Font = $FontUIBold }
    $sz = $G.MeasureString($Text, $Font)
    $w = [int][Math]::Ceiling($sz.Width) + 16
    $h = 20
    if ($w -gt $Rect.Width - 8) { $w = $Rect.Width - 8 }
    $x = $Rect.X + 4
    $y = $Rect.Y + [int](($Rect.Height - $h) / 2)
    $r = New-Object System.Drawing.RectangleF($x, $y, $w, $h)
    $path = New-RoundedPath -Rect $r -Radius 9
    $br = New-Object System.Drawing.SolidBrush $Back
    $G.FillPath($br, $path)
    $tb = New-Object System.Drawing.SolidBrush $Fore
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $G.DrawString($Text, $Font, $tb, $r, $sf)
    $sf.Dispose(); $tb.Dispose(); $br.Dispose(); $path.Dispose()
}

function Get-SourceInfo {
    param([int64]$Current, [string]$ConfigGroup, [int]$ProcId)
    $src = $script:SourceMap[$ProcId]
    if ($src -eq 'manual') {
        if ($ConfigGroup) { return @{ Text = '手动覆盖'; Back = $C.Amber; Fore = [System.Drawing.Color]::FromArgb(40,32,10) ; Key='manual' } }
        return @{ Text = '手动'; Back = $C.Amber; Fore = [System.Drawing.Color]::FromArgb(40,32,10); Key='manual' }
    }
    if ($ConfigGroup) { return @{ Text = '配置'; Back = $C.Green; Fore = [System.Drawing.Color]::FromArgb(8,40,30); Key='config' } }
    if ($Current -gt 0 -and $Current -ne $script:MaskAll) { return @{ Text = '继承'; Back = $C.Indigo; Fore = [System.Drawing.Color]::FromArgb(20,20,50); Key='inherited' } }
    return @{ Text = '未绑定'; Back = $C.Panel2; Fore = $C.Dim; Key='none' }
}

# ================================================================ DATA

function Build-Rows {
    $rows = @()
    $procs = @()
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            if ($script:SkipNames -contains $_.Name) { return $false }
            ($_.MainWindowTitle -ne '') -or ($script:KnownExe.ContainsKey(($_.Name + '.exe').ToLowerInvariant()))
        }
    } catch { }

    foreach ($p in $procs) {
        $exe = ($p.Name + '.exe').ToLowerInvariant()
        $grp = $script:KnownExe[$exe]
        $cur = Get-AffinityOf $p
        $target = if ($grp) { Get-GroupMask $grp } else { [int64]0 }
        $src = Get-SourceInfo -Current $cur -ConfigGroup $grp -ProcId $p.Id

        $title = $p.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '' }

        $rows += [pscustomobject]@{
            Name      = $p.Name
            Pid       = [int]$p.Id
            Title     = $title
            Current   = $cur
            Target    = $target
            Group     = if ($grp) { $grp } else { '' }
            SourceKey = $src.Key
            SourceTxt = $src.Text
            SourceBk  = $src.Back
            SourceFg  = $src.Fore
            BindKey   = if ($cur -eq $script:MaskCcd0) { 'ccd0' } elseif ($cur -eq $script:MaskCcd1) { 'ccd1' } elseif ($cur -eq $script:MaskAll) { 'all' } elseif ($cur -eq -1) { 'noperm' } else { 'custom' }
        }
    }
    return $rows
}

function Sort-Rows {
    param($Rows)
    $col = $script:SortColumn
    $asc = $script:SortAsc
    $sorted = switch ($col) {
        'Name'    { $Rows | Sort-Object { $_.Name.ToLowerInvariant() } }
        'Pid'     { $Rows | Sort-Object Pid }
        'Title'   { $Rows | Sort-Object { $_.Title.ToLowerInvariant() } }
        'Group'   { $Rows | Sort-Object { $_.Group.ToLowerInvariant() } }
        'Current' { $Rows | Sort-Object Current }
        'Source'  { $Rows | Sort-Object SourceTxt }
        default   { $Rows | Sort-Object { $_.Name.ToLowerInvariant() } }
    }
    if (-not $asc) { $sorted = @($sorted)[($sorted.Count - 1)..0] }
    return @($sorted)
}

function Apply-Filter {
    param($Rows)
    $out = $Rows
    if ($script:FilterMode -ne 'all') {
        $out = $out | Where-Object { $_.BindKey -eq $script:FilterMode }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SearchText)) {
        $q = $script:SearchText.ToLowerInvariant()
        $out = $out | Where-Object {
            $_.Name.ToLowerInvariant().Contains($q) -or
            $_.Title.ToLowerInvariant().Contains($q) -or
            ([string]$_.Pid).Contains($q)
        }
    }
    return @($out)
}

# ================================================================ UI

$form = New-Object System.Windows.Forms.Form
$form.Text = 'X3D 三缓调度'
$form.Size = New-Object System.Drawing.Size 1000, 700
$form.MinimumSize = New-Object System.Drawing.Size 840, 560
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = $FontUI
$form.Padding = New-Object System.Windows.Forms.Padding(0)
# (DoubleBuffered is protected on Form; the ListView is owner-drawn and already flicker-free)

# ---- header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 96
$header.BackColor = $C.Panel
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # accent bar
    $bar = New-Object System.Drawing.SolidBrush $C.Teal
    $g.FillRectangle($bar, 0, 0, 4, $header.Height)
    $bar.Dispose()
    # bottom border
    $pen = New-Object System.Drawing.Pen $C.Border, 1
    $g.DrawLine($pen, 0, $header.Height - 1, $header.Width, $header.Height - 1)
    $pen.Dispose()
})

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'X3D 三缓调度'
$lblTitle.ForeColor = $C.Text
$lblTitle.Font = $FontTitle
$lblTitle.AutoSize = $true
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$lblTitle.Location = New-Object System.Drawing.Point(22, 16)
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'CCD0  CPU 0-15  96 MB 3D V-Cache   ·   CCD1  CPU 16-31  32 MB 高频'
$lblSub.ForeColor = $C.Muted
$lblSub.Font = $FontSub
$lblSub.AutoSize = $true
$lblSub.BackColor = [System.Drawing.Color]::Transparent
$lblSub.Location = New-Object System.Drawing.Point(24, 50)
$header.Controls.Add($lblSub)

$lblPriv = New-Object System.Windows.Forms.Label
$lblPriv.AutoSize = $false
$lblPriv.Size = New-Object System.Drawing.Size(240, 26)
$lblPriv.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblPriv.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
$lblPriv.Location = New-Object System.Drawing.Point(($form.Width - 270), 20)
$lblPriv.BackColor = [System.Drawing.Color]::Transparent
$lblPriv.Font = $FontUIBold
$header.Controls.Add($lblPriv)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.AutoSize = $false
$lblCount.Size = New-Object System.Drawing.Size(240, 20)
$lblCount.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblCount.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
$lblCount.Location = New-Object System.Drawing.Point(($form.Width - 270), 46)
$lblCount.ForeColor = $C.Dim
$lblCount.Font = $FontSub
$lblCount.BackColor = [System.Drawing.Color]::Transparent
$header.Controls.Add($lblCount)

# ---- toolbar (search + filter chips)
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = [System.Windows.Forms.DockStyle]::Top
$toolbar.Height = 56
$toolbar.BackColor = $C.Bg

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$searchBox.BackColor = $C.Panel
$searchBox.ForeColor = $C.Text
$searchBox.Font = $FontUI
$searchBox.Location = New-Object System.Drawing.Point(22, 15)
$searchBox.Size = New-Object System.Drawing.Size(280, 26)
$toolbar.Controls.Add($searchBox)

$lblPlaceholder = New-Object System.Windows.Forms.Label
$lblPlaceholder.Text = '搜索程序名 / 窗口标题 / PID'
$lblPlaceholder.ForeColor = $C.Dim
$lblPlaceholder.BackColor = $C.Panel
$lblPlaceholder.Font = $FontUI
$lblPlaceholder.AutoSize = $true
$lblPlaceholder.Location = New-Object System.Drawing.Point(27, 19)
$lblPlaceholder.Cursor = [System.Windows.Forms.Cursors]::IBeam
$toolbar.Controls.Add($lblPlaceholder)
$lblPlaceholder.BringToFront()

$searchBox.Add_TextChanged({
    $script:SearchText = $searchBox.Text
    if ([string]::IsNullOrWhiteSpace($searchBox.Text)) { $lblPlaceholder.Visible = $true } else { $lblPlaceholder.Visible = $false }
    Refresh-List -KeepScroll
})
$lblPlaceholder.Add_Click({ $searchBox.Focus() })

$chips = @{}
$chipDefs = @(
    @{ Key='all';      Text='全部' },
    @{ Key='ccd0';     Text='CCD0' },
    @{ Key='ccd1';     Text='CCD1' },
    @{ Key='all-cpu';  Text='未绑定' },
    @{ Key='noperm';   Text='需管理员' }
)
$x = 320
foreach ($def in $chipDefs) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $def.Text
    $b.Tag = $def.Key
    $b.Size = New-Object System.Drawing.Size(88, 28)
    $b.Location = New-Object System.Drawing.Point($x, 14)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C.Border
    $b.BackColor = $C.Panel
    $b.ForeColor = $C.Muted
    $b.Font = $FontUI
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click({
        param($s, $e)
        $script:FilterMode = $s.Tag
        Update-Chips
        Refresh-List -KeepScroll
    })
    $toolbar.Controls.Add($b)
    $chips[$def.Key] = $b
    $x += 94
}

function Update-Chips {
    foreach ($k in $chips.Keys) {
        $b = $chips[$k]
        $isActive = ($k -eq $script:FilterMode) -or ($k -eq 'all-cpu' -and $script:FilterMode -eq 'all-cpu')
        if ($k -eq $script:FilterMode) {
            $b.BackColor = $C.Teal
            $b.ForeColor = [System.Drawing.Color]::FromArgb(8, 32, 30)
            $b.FlatAppearance.BorderColor = $C.Teal
        } else {
            $b.BackColor = $C.Panel
            $b.ForeColor = $C.Muted
            $b.FlatAppearance.BorderColor = $C.Border
        }
    }
}

# ---- footer
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
$footer.Height = 118
$footer.BackColor = $C.Panel
$footer.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen $C.Border, 1
    $e.Graphics.DrawLine($pen, 0, 0, $footer.Width, 0)
    $pen.Dispose()
})

function New-ActionButton {
    param([string]$Text, [int]$X, [int]$W, $Back, $Fore, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, 16)
    $b.Size = New-Object System.Drawing.Size($W, 38)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = if ($Primary) { $Back } else { $C.Border }
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = $FontUIBold
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $footer.Controls.Add($b)
    return $b
}

$btnCcd0 = New-ActionButton '绑定 CCD0 · 96 MB' 22 170 $C.Teal ([System.Drawing.Color]::FromArgb(6, 28, 26)) $true
$btnCcd1 = New-ActionButton '绑定 CCD1 · 高频' 200 150 $C.Blue ([System.Drawing.Color]::FromArgb(8, 20, 40)) $true
$btnAll  = New-ActionButton '恢复全部核心' 358 130 $C.Panel2 $C.Text $false
$btnRemember = New-ActionButton '记住为长期规则' 496 150 $C.Amber ([System.Drawing.Color]::FromArgb(40, 30, 6)) $true
$btnRefresh  = New-ActionButton '刷新' 654 80 $C.Panel2 $C.Muted $false

$btnRestart = New-ActionButton '以管理员重启' 742 130 $C.Panel2 $C.Red $false
$btnRestart.Visible = -not $script:IsAdmin

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.AutoSize = $false
$lblHint.Size = New-Object System.Drawing.Size(($form.Width - 44), 50)
$lblHint.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom, Left, Right'
$lblHint.Location = New-Object System.Drawing.Point(22, 60)
$lblHint.ForeColor = $C.Muted
$lblHint.Font = $FontSub
$lblHint.BackColor = [System.Drawing.Color]::Transparent
$lblHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$footer.Controls.Add($lblHint)

# ---- list
$list = New-Object System.Windows.Forms.ListView
$list.Dock = [System.Windows.Forms.DockStyle]::Fill
$list.View = [System.Windows.Forms.View]::Details
$list.OwnerDraw = $true
$list.FullRowSelect = $true
$list.MultiSelect = $true
$list.HideSelection = $false
$list.HeaderStyle = 'Clickable'
$list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$list.Padding = New-Object System.Windows.Forms.Padding(0)
$list.BackColor = $C.Bg
$list.ForeColor = $C.Text
$list.Font = $FontUI
[void]$list.Columns.Add('程序', 190)
[void]$list.Columns.Add('PID', 80)
[void]$list.Columns.Add('窗口标题', 300)
[void]$list.Columns.Add('当前 CPU', 140)
[void]$list.Columns.Add('绑定来源', 130)
[void]$list.Columns.Add('目标', 110)

# force a taller row height via a 1x34 image list
$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(1, 36)
$rowImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$list.SmallImageList = $rowImages

# Docking is applied from the highest child index down to 0.
# Add in reverse visual order so the fill control is processed last.
$form.Controls.Add($list)
$form.Controls.Add($footer)
$form.Controls.Add($toolbar)
$form.Controls.Add($header)
$list.BringToFront()

# ---- list painting
$colMap = @{ 0='Name'; 1='Pid'; 2='Title'; 3='Current'; 4='Source'; 5='Group' }

$list.Add_DrawColumnHeader({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = $e.Bounds
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(28, 34, 43))
    $g.FillRectangle($bg, $rect)
    $bg.Dispose()
    $pen = New-Object System.Drawing.Pen $C.Border, 1
    $g.DrawLine($pen, $rect.Left, $rect.Bottom - 1, $rect.Right, $rect.Bottom - 1)
    $pen.Dispose()

    $colKey = $colMap[$e.ColumnIndex]
    $label = $s.Columns[$e.ColumnIndex].Text
    $isSorted = ($colKey -eq $script:SortColumn)
    $font = if ($isSorted) { $FontUIBold } else { $FontUI }
    $fg = New-Object System.Drawing.SolidBrush (if ($isSorted) { $C.Teal } else { $C.Muted })
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.Alignment = [System.Drawing.StringAlignment]::Near
    $pad = New-Object System.Drawing.RectangleF(($rect.X + 10), $rect.Y, ($rect.Width - 28), $rect.Height)
    $g.DrawString($label, $font, $fg, $pad, $sf)
    $sf.Dispose()

    if ($isSorted) {
        $cx = $rect.Right - 16
        $cy = $rect.Y + [int]($rect.Height / 2)
        $arrow = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($script:SortAsc) {
            $arrow.AddPolygon(@(
                (New-Object System.Drawing.PointF($cx, ($cy - 4))),
                (New-Object System.Drawing.PointF(($cx - 5), ($cy + 3))),
                (New-Object System.Drawing.PointF(($cx + 5), ($cy + 3)))
            ))
        } else {
            $arrow.AddPolygon(@(
                (New-Object System.Drawing.PointF($cx, ($cy + 4))),
                (New-Object System.Drawing.PointF(($cx - 5), ($cy - 3))),
                (New-Object System.Drawing.PointF(($cx + 5), ($cy - 3)))
            ))
        }
        $g.FillPath($fg, $arrow)
        $arrow.Dispose()
    }
    $fg.Dispose()
})

$list.Add_DrawItem({
    param($s, $e)
    # background only here; subitems draw the content
    $g = $e.Graphics
    $rect = $e.Bounds
    $isSel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
    $isHot = ($e.ItemIndex -eq $script:HoverIndex)
    $bgColor = if ($isSel) { $C.Selected } elseif ($isHot) { $C.Hover } elseif (($e.ItemIndex % 2) -eq 1) { [System.Drawing.Color]::FromArgb(16, 21, 27) } else { $C.Bg }
    $bg = New-Object System.Drawing.SolidBrush $bgColor
    $g.FillRectangle($bg, $rect)
    $bg.Dispose()
    if ($isSel) {
        $pen = New-Object System.Drawing.Pen $C.Teal, 2
        $g.DrawLine($pen, $rect.Left, $rect.Top, $rect.Left, $rect.Bottom)
        $pen.Dispose()
    }
})

$list.Add_DrawSubItem({
    param($s, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $rect = $e.Bounds
    $row = $script:Rows[$e.ItemIndex]
    if (-not $row) { return }
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.Alignment = [System.Drawing.StringAlignment]::Near

    switch ($e.ColumnIndex) {
        0 {
            $fg = New-Object System.Drawing.SolidBrush $C.Text
            $g.DrawString($row.Name, $FontUIBold, $fg, (New-Object System.Drawing.RectangleF(($rect.X + 10), $rect.Y, ($rect.Width - 12), $rect.Height)), $sf)
            $fg.Dispose()
        }
        1 {
            $fg = New-Object System.Drawing.SolidBrush $C.Dim
            $g.DrawString([string]$row.Pid, $FontMono, $fg, (New-Object System.Drawing.RectangleF(($rect.X + 10), $rect.Y, ($rect.Width - 12), $rect.Height)), $sf)
            $fg.Dispose()
        }
        2 {
            $t = $row.Title
            if ([string]::IsNullOrWhiteSpace($t)) { $t = '—' }
            if ($t.Length -gt 46) { $t = $t.Substring(0, 46) + '…' }
            $fg = New-Object System.Drawing.SolidBrush (if ($row.Title) { $C.Text } else { $C.Dim })
            $g.DrawString($t, $FontUI, $fg, (New-Object System.Drawing.RectangleF(($rect.X + 10), $rect.Y, ($rect.Width - 12), $rect.Height)), $sf)
            $fg.Dispose()
        }
        3 {
            switch ($row.BindKey) {
                'ccd0'   { Draw-Pill $g $rect 'CCD0 · 96 MB' $C.Teal ([System.Drawing.Color]::FromArgb(6,28,26)) }
                'ccd1'   { Draw-Pill $g $rect 'CCD1 · 高频' $C.Blue ([System.Drawing.Color]::FromArgb(8,20,40)) }
                'all'    { Draw-Pill $g $rect '全部 32 核' $C.Panel2 $C.Muted }
                'noperm' { Draw-Pill $g $rect '需管理员' ([System.Drawing.Color]::FromArgb(64,28,28)) $C.Red }
                default  { Draw-Pill $g $rect ('0x{0:X}' -f $row.Current) $C.Panel2 $C.Amber }
            }
        }
        4 {
            Draw-Pill $g $rect $row.SourceTxt $row.SourceBk $row.SourceFg
        }
        5 {
            if ($row.Group) {
                $fg = New-Object System.Drawing.SolidBrush $C.Muted
                $g.DrawString($row.Group, $FontMono, $fg, (New-Object System.Drawing.RectangleF(($rect.X + 10), $rect.Y, ($rect.Width - 12), $rect.Height)), $sf)
                $fg.Dispose()
            }
        }
    }
    $sf.Dispose()
})

$list.Add_ColumnClick({
    param($s, $e)
    $colKey = $colMap[$e.Column]
    if (-not $colKey) { return }
    if ($script:SortColumn -eq $colKey) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortColumn = $colKey; $script:SortAsc = $true }
    Refresh-List -KeepScroll
})

$list.Add_MouseMove({
    param($s, $e)
    $idx = $list.GetItemAt($e.X, 0)
    $newIdx = if ($idx) { $idx.Index } else { -1 }
    if ($newIdx -ne $script:HoverIndex) {
        $script:HoverIndex = $newIdx
        $list.Invalidate()
    }
})
$list.Add_MouseLeave({ $script:HoverIndex = -1; $list.Invalidate() })

$list.Add_DoubleClick({
    Apply-Mask -Mask $script:MaskCcd0 -Label '绑定 CCD0' -IsManual $true
})

# ================================================================ ACTIONS

function Get-SelectedProcesses {
    $out = @()
    foreach ($it in $list.SelectedItems) {
        $procId = [int]$it.Tag
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) { $out += $p }
    }
    return $out
}

function Update-Hint {
    param([string]$Text, $Color)
    if (-not $Color) { $Color = $C.Muted }
    $lblHint.ForeColor = $Color
    $lblHint.Text = $Text
}

function Refresh-List {
    param([switch]$KeepScroll)
    if ($script:Updating) { return }
    $script:Updating = $true
    try {
        $selPids = @()
        foreach ($it in $list.SelectedItems) { $selPids += [int]$it.Tag }
        $topItem = if ($list.Items.Count -gt 0 -and $KeepScroll) { $list.TopItem } else { $null }
        $scrollIdx = if ($topItem) { $topItem.Index } else { -1 }

        $script:Rows = @(Apply-Filter (Sort-Rows (Build-Rows)))

        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($r in $script:Rows) {
            $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
            [void]$it.SubItems.Add([string]$r.Pid)
            [void]$it.SubItems.Add($r.Title)
            [void]$it.SubItems.Add('')
            [void]$it.SubItems.Add('')
            [void]$it.SubItems.Add($r.Group)
            $it.Tag = $r.Pid
            [void]$list.Items.Add($it)
            if ($selPids -contains $r.Pid) { $it.Selected = $true }
        }
        if ($scrollIdx -ge 0 -and $scrollIdx -lt $list.Items.Count) {
            try { $list.EnsureVisible([Math]::Min($scrollIdx + 8, $list.Items.Count - 1)); $list.EnsureVisible($scrollIdx) } catch { }
        }
        $list.EndUpdate()

        $c0 = @($script:Rows | Where-Object { $_.BindKey -eq 'ccd0' }).Count
        $c1 = @($script:Rows | Where-Object { $_.BindKey -eq 'ccd1' }).Count
        $np = @($script:Rows | Where-Object { $_.BindKey -eq 'noperm' }).Count
        $lblCount.Text = ('{0} 个 · CCD0 {1} · CCD1 {2} · 需管理员 {3}' -f $script:Rows.Count, $c0, $c1, $np)
    }
    finally {
        $script:Updating = $false
    }
}

function Apply-Mask {
    param([int64]$Mask, [string]$Label, [bool]$IsManual)
    $sel = Get-SelectedProcesses
    if (-not $sel -or $sel.Count -eq 0) {
        Update-Hint '请先在列表中选中一个或多个程序。' $C.Amber
        return
    }
    $ok = 0; $fail = 0
    foreach ($p in $sel) {
        if (Set-AffinitySafe -Process $p -Mask $Mask) {
            $ok++
            if ($IsManual) { $script:SourceMap[$p.Id] = 'manual' }
            Write-TrayLog ("manual pin {0} (pid {1}) -> 0x{2:X}" -f $p.Name, $p.Id, $Mask)
        } else {
            $fail++
        }
    }
    $msg = '{0}：成功 {1} 个，失败 {2} 个。' -f $Label, $ok, $fail
    if ($fail -gt 0) { $msg += ' 失败的多为管理员/反作弊进程，需以管理员身份运行本程序。' }
    Update-Hint $msg (if ($fail -gt 0) { $C.Amber } else { $C.Green })
    Refresh-List -KeepScroll
}

$btnCcd0.Add_Click({ Apply-Mask -Mask $script:MaskCcd0 -Label '绑定 CCD0' -IsManual $true })
$btnCcd1.Add_Click({ Apply-Mask -Mask $script:MaskCcd1 -Label '绑定 CCD1' -IsManual $true })
$btnAll.Add_Click({  Apply-Mask -Mask $script:MaskAll  -Label '恢复全部核心' -IsManual $false })
$btnRefresh.Add_Click({ Refresh-List -KeepScroll })

$btnRemember.Add_Click({
    $sel = Get-SelectedProcesses
    if (-not $sel -or $sel.Count -eq 0) { Update-Hint '请先选中要记住的程序。' $C.Amber; return }
    $added = @(); $skipped = @()
    foreach ($p in $sel) {
        $exe = $p.Name + '.exe'
        if (Add-ExeToConfig -ExeName $exe -GroupName 'ccd0-cache') {
            $added += $exe
            [void](Set-AffinitySafe -Process $p -Mask $script:MaskCcd0)
            $script:SourceMap.Remove($p.Id)
        } else {
            $skipped += $exe
        }
    }
    $msg = @()
    if ($added.Count)   { $msg += ('已加入长期规则：' + ($added -join ', ')) }
    if ($skipped.Count) { $msg += ('已在规则中：' + ($skipped -join ', ')) }
    Update-Hint ($msg -join '   ') $C.Green
    Refresh-List -KeepScroll
})

$btnRestart.Add_Click({
    try {
        $exe = (Get-Process -Id $PID).Path
        $argList = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', (Join-Path $ToolDir 'X3D-Tray.ps1'))
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs
        $script:Context.ExitThread()
    } catch {
        Update-Hint ('提权失败：' + $_.Exception.Message) $C.Red
    }
})

# ================================================================ ICON

function New-ChipIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $body   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 13, 17, 23))
    $accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 45, 212, 191))
    $pin    = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 45, 212, 191)), 2

    $g.FillRectangle($body, 5, 5, 22, 22)
    $g.DrawRectangle($pin, 5, 5, 22, 22)
    for ($i = 0; $i -lt 4; $i++) {
        $y = 9 + ($i * 5)
        $g.DrawLine($pin, 2, $y, 4, $y)
        $g.DrawLine($pin, 28, $y, 30, $y)
    }
    $font = New-Object System.Drawing.Font('Segoe UI', 8.0, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString('96', $font, $accent, 8, 9)

    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    $clone = $icon.Clone()
    $font.Dispose(); $body.Dispose(); $accent.Dispose(); $pin.Dispose(); $g.Dispose(); $bmp.Dispose()
    return $clone
}

$form.Icon = New-ChipIcon

# ================================================================ TRAY

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $form.Icon
$tray.Text = 'X3D 三缓调度'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
$menu.BackColor = $C.Panel
$menu.ForeColor = $C.Text
$miShow  = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList @('打开面板')
$miQuick = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList @('把前台窗口绑到 CCD0')
$miSep1  = New-Object System.Windows.Forms.ToolStripSeparator
$miCfg   = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList @('打开 config.json')
$miLog   = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList @('打开日志目录')
$miSep2  = New-Object System.Windows.Forms.ToolStripSeparator
$miExit  = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList @('退出')
[void]$menu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($miShow, $miQuick, $miSep1, $miCfg, $miLog, $miSep2, $miExit))
$tray.ContextMenuStrip = $menu

$showPanel = {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    Refresh-List
}
$tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showPanel }
})
$miShow.Add_Click($showPanel)

if (-not ('FgWin' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FgWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@ -ErrorAction SilentlyContinue
}

$miQuick.Add_Click({
    try {
        $h = [FgWin]::GetForegroundWindow()
        $procId = [uint32]0
        [void][FgWin]::GetWindowThreadProcessId($h, [ref]$procId)
        $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
        if ($p) {
            $ok = Set-AffinitySafe -Process $p -Mask $script:MaskCcd0
            if ($ok) { $script:SourceMap[$p.Id] = 'manual' }
            $tray.ShowBalloonTip(2500, 'X3D', ('{0} → CCD0 {1}' -f $p.Name, $(if ($ok) { '成功' } else { '失败(需管理员)' })), [System.Windows.Forms.ToolTipIcon]::Info)
            Write-TrayLog ("quick pin {0} (pid {1}) -> {2}" -f $p.Name, $p.Id, $ok)
        } else {
            $tray.ShowBalloonTip(2000, 'X3D', '没有取到前台进程', [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } catch {
        Write-TrayLog ("quick pin failed: {0}" -f $_.Exception.Message)
    }
})

$miCfg.Add_Click({ Start-Process notepad.exe -ArgumentList $ConfigPath })
$miLog.Add_Click({ Start-Process explorer.exe -ArgumentList $LogDir })
$miExit.Add_Click({
    $tray.Visible = $false
    $tray.Dispose()
    $script:Context.ExitThread()
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(1500, 'X3D', '已最小化到托盘，左键单击图标重新打开', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ================================================================ AUTO-PIN

function Invoke-AutoPin {
    param([switch]$Quiet)
    try {
        try {
            if (Test-Path -LiteralPath $ConfigPath) {
                $stamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
                if ($stamp -ne $script:ConfigStamp) { [void](Read-ConfigSafe) }
            }
        } catch { }
        if (-not $script:Config) { [void](Read-ConfigSafe) }
        if (-not $script:Config) { return }

        $matched = 0; $pinned = 0; $denied = 0
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            $exe = ($p.Name + '.exe').ToLowerInvariant()
            if (-not $script:KnownExe.ContainsKey($exe)) { continue }
            $matched++
            $grp = $script:KnownExe[$exe]
            $mask = Get-GroupMask $grp
            if ($mask -le 0) { continue }
            $cur = Get-AffinityOf $p
            $firstSight = -not $script:SeenPids.ContainsKey($p.Id)
            if ($firstSight) { $script:SeenPids[$p.Id] = $true }

            # manual override wins: do not fight the user
            if ($script:SourceMap[$p.Id] -eq 'manual' -and $cur -ne $mask) { continue }

            if ($cur -eq $mask) {
                if ($firstSight -and -not $Quiet) {
                    Write-TrayLog ("on CCD0 already: {0} (pid {1}) -> {2}" -f $p.Name, $p.Id, $grp)
                }
                continue
            }
            if ($cur -eq -1) {
                $denied++
                if (-not $Quiet) { Write-TrayLog ("no access to {0} (pid {1}) - needs elevation" -f $p.Name, $p.Id) }
                continue
            }
            if (Set-AffinitySafe -Process $p -Mask $mask) {
                $pinned++
                Write-TrayLog ("auto pin {0} (pid {1}) -> {2}" -f $p.Name, $p.Id, $grp)
            } else {
                $denied++
                if (-not $Quiet) { Write-TrayLog ("pin failed {0} (pid {1}) - access denied" -f $p.Name, $p.Id) }
            }
        }
        if (-not $Quiet) {
            if ($pinned -gt 0 -or $denied -gt 0) {
                Write-TrayLog ("scan done: {0} running, {1} newly pinned, {2} denied" -f $matched, $pinned, $denied)
                $script:QuietTicks = 0
            } else {
                $script:QuietTicks++
                if ($script:QuietTicks -ge 40) {
                    $detail = @()
                    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
                        $exe2 = ($p.Name + '.exe').ToLowerInvariant()
                        if (-not $script:KnownExe.ContainsKey($exe2)) { continue }
                        $a = Get-AffinityOf $p
                        $txt = if ($a -eq -1) { 'noperm' } else { '0x' + $a.ToString('X') }
                        $detail += ('{0}({1})={2}' -f $p.Name, $p.Id, $txt)
                    }
                    Write-TrayLog ("heartbeat: {0} -> {1}" -f $matched, ($detail -join ' '))
                    $script:QuietTicks = 0
                }
            }
        }
    } catch {
        Write-TrayLog ("auto-pin error: {0}" -f $_.Exception.Message)
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    Invoke-AutoPin
    if ($form.Visible) { Refresh-List -KeepScroll }
})

# ================================================================ AUTO-START TASK

function Ensure-AutoStartTask {
    if (-not $script:IsAdmin) { return }
    $taskName = 'X3D CCD Affinity Tray'
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and ([string]$existing.Principal.RunLevel) -eq 'Highest') { return }
        $exe = (Get-Process -Id $PID).Path
        $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ToolDir "{1}" -Silence' -f (Join-Path $ToolDir 'X3D-Tray.ps1'), $ToolDir
        $action    = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $ToolDir
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-TrayLog 'auto-start task registered (Highest)'
    } catch {
        Write-TrayLog ("auto-start task registration failed: {0}" -f $_.Exception.Message)
    }
}

# ================================================================ STARTUP

$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Context.add_ThreadExit({
    $timer.Stop()
    $tray.Visible = $false
    try { $tray.Dispose() } catch { }
})

[void](Read-ConfigSafe)
try {
    if ($script:Config -and ($script:Config.PSObject.Properties.Name -contains 'logRetainDays')) {
        $script:LogRetainDays = [int]$script:Config.logRetainDays
    }
} catch { }

if ($script:IsAdmin) {
    $lblPriv.Text = '●  管理员模式'
    $lblPriv.ForeColor = $C.Green
} else {
    $lblPriv.Text = '○  普通权限 · 管理员游戏受限'
    $lblPriv.ForeColor = $C.Amber
}

Update-Chips
Refresh-List

Write-TrayLog ("tray starting (admin={0})" -f $script:IsAdmin)
if ($script:IsAdmin) {
    Ensure-AutoStartTask
} else {
    $tray.ShowBalloonTip(6000, 'X3D 三缓调度', '当前为普通权限：星穹铁道 / 原神 / 绝区零 等管理员进程无法修改。请用 X3D-Tray-Admin.exe 启动。', [System.Windows.Forms.ToolTipIcon]::Warning)
}

$timer.Start()
Invoke-AutoPin
if ($form.Visible) { }  # first refresh already happened above

if (-not $Silence) {
    $form.Show()
    $form.Activate()
    Refresh-List
}

[System.Windows.Forms.Application]::Run($script:Context)









