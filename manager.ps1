# Node manager - ikona ob uri za upravljanje Node aplikacij (NSSM storitve)
# Aplikacije so podmape nadrejene mape (npr. _nodejs_server\*), vsaka s svojim .env (SERVICE, DISPLAY, PORT, LOG_DIR).
#   manager.ps1             -> ikona ob uri
#   manager.ps1 -List       -> izpise najdene aplikacije in stanje
#   manager.ps1 -Install    -> samodejni zagon ob prijavi (Scheduled Task z admin pravicami)
#   manager.ps1 -Uninstall  -> odstrani samodejni zagon
param([switch]$List, [switch]$Install, [switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName  = 'NodeManager'
$Root      = Split-Path $PSScriptRoot -Parent
$LogFile   = Join-Path $PSScriptRoot 'manager.log'
$RefreshMs = 5000

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$StatusText = @{
    Running      = 'teče'
    Stopped      = 'ustavljena'
    StartPending = 'se zaganja'
    StopPending  = 'se ustavlja'
    Paused       = 'pavza (napaka v aplikaciji?)'
}

function Write-Log($msg) {
    try { Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

function Read-Env($file) {
    $vars = @{}
    foreach ($line in Get-Content -LiteralPath $file -Encoding UTF8) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $vars[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
    $vars
}

function Get-Apps {
    foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory) {
        $envFile = Join-Path $dir.FullName '.env'
        if (-not (Test-Path -LiteralPath $envFile)) { continue }
        $vars = Read-Env $envFile
        $svc = $null
        if ($vars.SERVICE) { $svc = Get-Service -Name $vars.SERVICE -ErrorAction SilentlyContinue }

        if (-not $vars.SERVICE) { $state = 'ni SERVICE v .env' }
        elseif (-not $svc)      { $state = 'ni nameščena' }
        elseif ($StatusText.ContainsKey("$($svc.Status)")) { $state = $StatusText["$($svc.Status)"] }
        else                    { $state = "$($svc.Status)" }

        # LOG_DIR: relativno na mapo aplikacije ali absolutno; privzeto logs
        $logs = $(if ($vars.LOG_DIR) { $vars.LOG_DIR } else { 'logs' })
        if (-not [System.IO.Path]::IsPathRooted($logs)) { $logs = Join-Path $dir.FullName $logs }

        [pscustomobject]@{
            Name      = $(if ($vars.DISPLAY) { $vars.DISPLAY } else { $dir.Name })
            Service   = $vars.SERVICE
            Port      = $vars.PORT
            Dir       = $dir.FullName
            Logs      = $logs
            Status    = $state
            Installed = [bool]$svc
            Running   = [bool]($svc -and $svc.Status -eq 'Running')
        }
    }
}

# --- ukazna vrstica -----------------------------------------------------------

if ($List) {
    Get-Apps | Format-Table Name, Service, Port, Status, Dir -AutoSize
    return
}

if ($Install -or $Uninstall) {
    if (-not $IsAdmin) { Write-Host '[NAPAKA] Zazeni kot administrator.'; exit 1 }
    if ($Uninstall) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Samodejni zagon odstranjen ($TaskName)."
        exit 0
    }
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    # ExecutionTimeLimit 0 = brez omejitve (privzeto bi Windows ikono ugasnil po 72 urah)
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                   -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Samodejni zagon ob prijavi nastavljen za $user ($TaskName). Ikona je ob uri."
    exit 0
}

# --- ikona ob uri ---------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# samo ena instanca na sejo
$mutex = New-Object System.Threading.Mutex($false, 'Local\NodeManager')
if (-not $mutex.WaitOne(0)) { exit }

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 0, 0, 15, 15)
    $font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('N', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 16, 15)), $fmt)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$ColorOk   = [System.Drawing.Color]::FromArgb(26, 127, 55)
$ColorBad  = [System.Drawing.Color]::FromArgb(207, 34, 46)
$ColorNone = [System.Drawing.Color]::FromArgb(110, 119, 129)
$Icons = @{ ok = New-DotIcon $ColorOk; bad = New-DotIcon $ColorBad; none = New-DotIcon $ColorNone }

$script:apps    = @()
$script:exiting = $false

# okno
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Node aplikacije - ' + $Root + $(if (-not $IsAdmin) { '   (brez admin pravic - samo pregled)' })
$form.Size = New-Object System.Drawing.Size(860, 360)
$form.MinimumSize = New-Object System.Drawing.Size(600, 250)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$BoldFont = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
$form.Icon = $Icons.ok
$form.StartPosition = 'Manual'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 12), ($wa.Bottom - $form.Height - 12))

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.BorderStyle = 'None'
$grid.AutoSizeColumnsMode = 'Fill'
foreach ($c in @(@('Aplikacija', 30), @('Storitev', 18), @('Port', 8), @('Stanje', 18), @('Mapa', 30))) {
    $i = $grid.Columns.Add($c[0], $c[0])
    $grid.Columns[$i].FillWeight = $c[1]
}

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'
$panel.AutoSize = $true
$panel.Padding = New-Object System.Windows.Forms.Padding(6)

function New-Button($text, $onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.Add_Click($onClick)
    $panel.Controls.Add($b)
    $b
}

function Get-Selected {
    if ($grid.SelectedRows.Count -gt 0) { $grid.SelectedRows[0].Tag }
}

function Update-Buttons {
    $a = Get-Selected
    $btnStart.Enabled   = [bool]($IsAdmin -and $a -and $a.Installed -and -not $a.Running)
    $btnStop.Enabled    = [bool]($IsAdmin -and $a -and $a.Installed -and $a.Status -ne 'ustavljena')
    $btnRestart.Enabled = [bool]($IsAdmin -and $a -and $a.Installed)
    $btnUninstall.Enabled = [bool]($IsAdmin -and $a -and $a.Installed)
    $btnInstall.Enabled = [bool]($IsAdmin -and $a)
    $btnInstall.Text    = $(if ($a -and $a.Installed) { 'Ponovno namesti' } else { 'Namesti' })
    $btnLogs.Enabled    = [bool]$a
    $btnBrowser.Enabled = [bool]($a -and $a.Port)
    $btnFolder.Enabled  = [bool]$a
}

function Update-Tray {
    $inst = @($script:apps | Where-Object Installed)
    $run  = @($inst | Where-Object Running)
    if ($inst.Count -eq 0)              { $tray.Icon = $Icons.none }
    elseif ($run.Count -eq $inst.Count) { $tray.Icon = $Icons.ok }
    else                                { $tray.Icon = $Icons.bad }
    $tray.Text = "Node aplikacije: $($run.Count)/$($inst.Count) teče"
    $form.Icon = $tray.Icon
}

function Update-View {
    try {
        $script:apps = @(Get-Apps)
    } catch {
        Write-Log "Get-Apps: $($_.Exception.Message)"
        return
    }
    Update-Tray
    if (-not $form.Visible) { return }

    $sel = (Get-Selected).Service
    $first = $grid.FirstDisplayedScrollingRowIndex
    $grid.Rows.Clear()
    foreach ($a in $script:apps) {
        $i = $grid.Rows.Add($a.Name, $a.Service, $a.Port, $a.Status, $a.Dir)
        $row = $grid.Rows[$i]
        $row.Tag = $a
        $cell = $row.Cells[3]
        if ($a.Running)        { $cell.Style.ForeColor = $ColorOk }
        elseif ($a.Installed)  { $cell.Style.ForeColor = $ColorBad }
        else                   { $cell.Style.ForeColor = $ColorNone }
        $cell.Style.Font = $BoldFont
    }
    $grid.ClearSelection()
    foreach ($row in $grid.Rows) {
        if ($sel -and $row.Tag.Service -eq $sel) { $row.Selected = $true; $grid.CurrentCell = $row.Cells[0] }
    }
    if ($first -ge 0 -and $first -lt $grid.Rows.Count) { $grid.FirstDisplayedScrollingRowIndex = $first }
    Update-Buttons
}

function Invoke-ServiceAction($verb) {
    $a = Get-Selected
    if (-not $a) { return }
    $form.Cursor = 'WaitCursor'
    try {
        switch ($verb) {
            'start'   { Start-Service   -Name $a.Service }
            'stop'    { Stop-Service    -Name $a.Service -Force }
            'restart' { Restart-Service -Name $a.Service -Force }
            'uninstall' {
                $q = "Odstranim storitev $($a.Service) ($($a.Name))?`n`nStoritev se ustavi in izbriše skupaj s firewall pravilom. Datoteke aplikacije ostanejo."
                if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Odstrani storitev', 'YesNo', 'Warning') -ne 'Yes') { return }
                Stop-Service -Name $a.Service -Force
                $out = & sc.exe delete $a.Service
                if ($LASTEXITCODE -ne 0) { throw "sc delete: $out" }
                & netsh.exe advfirewall firewall delete rule "name=$($a.Service)" | Out-Null
            }
        }
        Write-Log "$verb $($a.Service)"
    } catch {
        Write-Log "$verb $($a.Service): $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($form, "$($a.Name)`n`n$($_.Exception.Message)", 'Napaka', 'OK', 'Error') | Out-Null
    } finally {
        $form.Cursor = 'Default'
        Update-View
    }
}

function Open-Path($path, $what) {
    if (Test-Path -LiteralPath $path) { Start-Process explorer.exe -ArgumentList "`"$path`"" }
    else { [System.Windows.Forms.MessageBox]::Show($form, "$what ne obstaja:`n$path", 'Node aplikacije') | Out-Null }
}

$btnStart   = New-Button 'Start'   { Invoke-ServiceAction 'start' }
$btnStop    = New-Button 'Stop'    { Invoke-ServiceAction 'stop' }
$btnRestart = New-Button 'Restart' { Invoke-ServiceAction 'restart' }
$btnInstall = New-Button 'Namesti' {
    $a = Get-Selected
    $bat = Join-Path $a.Dir 'install.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        [System.Windows.Forms.MessageBox]::Show($form, "install.bat ne obstaja:`n$bat", 'Node aplikacije') | Out-Null
        return
    }
    Start-Process cmd.exe -ArgumentList "/k `"$bat`"" -WorkingDirectory $a.Dir
}
$btnUninstall = New-Button 'Odstrani' { Invoke-ServiceAction 'uninstall' }
$btnLogs    = New-Button 'Logi'    { $a = Get-Selected; Open-Path $a.Logs 'Mapa z logi' }
$btnBrowser = New-Button 'Odpri v brskalniku' { $a = Get-Selected; Start-Process "http://localhost:$($a.Port)/" }
$btnFolder  = New-Button 'Mapa'    { $a = Get-Selected; Open-Path $a.Dir 'Mapa' }
$btnRefresh = New-Button 'Osveži'  { Update-View }

$grid.Add_SelectionChanged({ Update-Buttons })
$grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { $btnFolder.PerformClick() } })

$form.Controls.Add($panel)
$form.Controls.Add($grid)
$grid.BringToFront()

# zapiranje okna ga samo skrije; izhod je v meniju ikone
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:exiting) { $e.Cancel = $true; $form.Hide() }
})

function Show-Form {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
    Update-View
}

# ikona in meni
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $Icons.none
$tray.Text = 'Node aplikacije'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('Odpri', $null, { Show-Form }) | Out-Null
$menu.Items.Add('Osveži', $null, { Update-View }) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('Izhod', $null, {
    $script:exiting = $true
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
}) | Out-Null
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Form } })
$tray.Visible = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $RefreshMs
$timer.Add_Tick({ Update-View })
$timer.Start()

try {
    Update-View
    Write-Log "start ($Root, admin=$IsAdmin)"
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-Log "NAPAKA: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("Node manager se je ustavil:`n`n$($_.Exception.Message)", 'Node aplikacije', 'OK', 'Error') | Out-Null
} finally {
    $tray.Dispose()
    $mutex.ReleaseMutex()
}
