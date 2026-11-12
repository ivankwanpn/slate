param(
    [string]$Mode = 'gui',
    [string]$Serial = '',
    [string]$AdbPath = 'C:\platform-tools\adb.exe',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Adb = $null
$script:Serial = $Serial
$script:LogBox = $null
$script:Target = 'com.mobiletools.systemhelper'

function Resolve-Adb {
    if (Test-Path $AdbPath) { return $AdbPath }
    $c = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\platform-tools\adb.exe', "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw 'adb not found'
}

function Shell([string]$Cmd) {
    $a = @()
    if ($script:Serial) { $a += @('-s', $script:Serial) }
    $out = & $script:Adb @a shell $Cmd 2>&1
    return ($out -join [char]10)
}

function Get-Devices {
    $raw = & $script:Adb devices -l 2>&1
    $list = @()
    foreach ($line in $raw) {
        if ($line -match '^([0-9A-Za-z\.\:\-_]+)\s+(device|unauthorized|offline)\s*(.*)$') {
            $serial = $matches[1]
            $state = $matches[2]
            $model = ''
            if ($matches[3] -match 'model:(\S+)') { $model = $matches[1] }
            $list += [pscustomobject]@{ Serial = $serial; State = $state; Model = $model }
        }
    }
    return $list
}

function Get-Audit([string]$pkg) {
    $path = (Shell "pm path $pkg").Trim()
    $installedLine = (Shell "pm list packages --user 0 $pkg").Trim()
    if (-not $path -and -not $installedLine) { return $null }

    $dump = ''
    if ($path) { $dump = Shell "dumpsys package $pkg" }

    $version = ''
    if ($dump -match 'versionName=([^\s]+)') { $version = $matches[1] }

    $enabled = 'n/a'
    if ($dump -match 'User 0:[^\n]*enabled=(\d)') { $enabled = $matches[1] }

    $proc = ''
    if ($path) { $proc = (Shell "ps -A | grep -i $pkg").Trim() }

    $alarms = '0'
    if ($path) { $alarms = (Shell "dumpsys alarm | grep -i -c $pkg").Trim() }

    $uid = ''
    $uidLine = (Shell "pm list packages -U $pkg").Trim()
    if ($uidLine -match 'uid:(\d+)') { $uid = $matches[1] }

    return [pscustomobject]@{
        Package   = $pkg
        Version   = $version
        Installed = [bool]$installedLine
        Enabled   = $enabled
        Running   = [bool]$proc
        Alarms    = $alarms
        Uid       = $uid
        Path      = $path
    }
}

$script:Targets = @($script:Target)

function Get-Report {
    $lines = @()
    $lines += '# PhoneFix audit report'
    $lines += ''
    $lines += '- Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += '- Serial: ' + $script:Serial
    $lines += ''
    $lines += '| Package | Version | Installed(user0) | Enabled | Running | Alarms | UID |'
    $lines += '|---|---|---|---|---|---|---|'
    $found = 0
    foreach ($t in $script:Targets) {
        $a = Get-Audit $t
        if ($a) {
            $found++
            $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $a.Package, $a.Version, $a.Installed, $a.Enabled, $a.Running, $a.Alarms, $a.Uid)
        }
    }
    if ($found -eq 0) { $lines += '| (none) | | | | | | |' }
    $lines += ''
    $sw = (Shell 'settings get secure operator_service_improve_plan').Trim()
    $lines += 'operator_service_improve_plan = ' + $sw
    $lines += ''
    $lines += 'Note: uninstall is per-user; the system-partition copy remains until a factory reset or OTA re-adds it.'
    return ($lines -join [Environment]::NewLine)
}

function Do-Action([string]$Action, [string]$Pkg) {
    switch ($Action) {
        'disable'   { return (Shell "pm disable-user --user 0 $Pkg").Trim() }
        'enable'    { return (Shell "pm enable $Pkg").Trim() }
        'clear'     { return (Shell "pm clear $Pkg").Trim() }
        'uninstall' { return (Shell "pm uninstall -k --user 0 $Pkg").Trim() }
        'restore'   { return (Shell "cmd package install-existing $Pkg").Trim() }
        'harden'    {
            $out = @()
            foreach ($p in @('android.permission.ACCESS_FINE_LOCATION','android.permission.ACCESS_COARSE_LOCATION','android.permission.ACCESS_BACKGROUND_LOCATION','android.permission.READ_PHONE_STATE','android.permission.READ_EXTERNAL_STORAGE')) {
                $r = (Shell "pm revoke $Pkg $p").Trim()
                $out += ($p + ' -> ' + ($(if ($r) { $r } else { 'ok' })))
            }
            foreach ($op in @('FINE_LOCATION','COARSE_LOCATION','READ_PHONE_STATE','READ_EXTERNAL_STORAGE','GET_USAGE_STATS')) {
                $r = (Shell "cmd appops set $Pkg $op ignore").Trim()
                $out += ($op + ' -> ' + ($(if ($r) { $r } else { 'ok' })))
            }
            return ($out -join [Environment]::NewLine)
        }
    }
    return 'unknown action'
}

function Log([string]$msg) {
    if ($script:LogBox) {
        $script:LogBox.AppendText('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg + [Environment]::NewLine)
        $script:LogBox.ScrollToCaret()
    }
    Write-Host $msg
}

if ($Mode -ne 'gui') {
    $script:Adb = Resolve-Adb
    if (-not $script:Serial) {
        $d = Get-Devices | Where-Object { $_.State -eq 'device' } | Select-Object -First 1
        if (-not $d) { Write-Error 'no device'; exit 1 }
        $script:Serial = $d.Serial
    }
    switch ($Mode) {
        'audit' {
            foreach ($t in $script:Targets) {
                $a = Get-Audit $t
                if ($a) {
                    Write-Host ("{0}  v{1}  installed={2}  enabled={3}  running={4}  alarms={5}  uid={6}" -f $a.Package, $a.Version, $a.Installed, $a.Enabled, $a.Running, $a.Alarms, $a.Uid)
                } else {
                    Write-Host ("{0}  not present" -f $t)
                }
            }
        }
        'report' {
            $r = Get-Report
            if ($OutFile) { $r | Out-File -Encoding utf8 $OutFile; Write-Host ('written ' + $OutFile) }
            else { Write-Host $r }
        }
        'disable'   { Write-Host (Do-Action 'disable' $script:Target) }
        'enable'    { Write-Host (Do-Action 'enable' $script:Target) }
        'clear'     { Write-Host (Do-Action 'clear' $script:Target) }
        'harden'    { Write-Host (Do-Action 'harden' $script:Target) }
        'uninstall' { Write-Host (Do-Action 'uninstall' $script:Target) }
        'restore'   { Write-Host (Do-Action 'restore' $script:Target) }
    }
    exit 0
}

$script:Adb = Resolve-Adb

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PhoneFix - preinstalled component auditor'
$form.Size = New-Object System.Drawing.Size(1000, 720)
$form.StartPosition = 'CenterScreen'

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'
$top.Height = 110

$lblDev = New-Object System.Windows.Forms.Label
$lblDev.Text = 'Device:'
$lblDev.Location = New-Object System.Drawing.Point(10, 10)
$lblDev.AutoSize = $true

$cmbDev = New-Object System.Windows.Forms.ComboBox
$cmbDev.Location = New-Object System.Drawing.Point(70, 7)
$cmbDev.Width = 330

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(410, 6)
$btnRefresh.Width = 80

$lblWifi = New-Object System.Windows.Forms.Label
$lblWifi.Text = 'Wi-Fi:'
$lblWifi.Location = New-Object System.Drawing.Point(10, 42)
$lblWifi.AutoSize = $true

$txtWifi = New-Object System.Windows.Forms.TextBox
$txtWifi.Location = New-Object System.Drawing.Point(70, 39)
$txtWifi.Width = 220
$txtWifi.Text = ''

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Connect'
$btnConnect.Location = New-Object System.Drawing.Point(300, 38)
$btnConnect.Width = 90

$btnAudit = New-Object System.Windows.Forms.Button
$btnAudit.Text = 'Audit'
$btnAudit.Location = New-Object System.Drawing.Point(500, 6)
$btnAudit.Width = 90

$btnReport = New-Object System.Windows.Forms.Button
$btnReport.Text = 'Export report'
$btnReport.Location = New-Object System.Drawing.Point(600, 6)
$btnReport.Width = 110

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = 'Disable'
$btnDisable.Location = New-Object System.Drawing.Point(500, 38)
$btnDisable.Width = 90

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text = 'Re-enable'
$btnEnable.Location = New-Object System.Drawing.Point(600, 38)
$btnEnable.Width = 90

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear data'
$btnClear.Location = New-Object System.Drawing.Point(700, 38)
$btnClear.Width = 90

$btnHarden = New-Object System.Windows.Forms.Button
$btnHarden.Text = 'Revoke perms'
$btnHarden.Location = New-Object System.Drawing.Point(800, 38)
$btnHarden.Width = 100

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = 'Uninstall for user'
$btnUninstall.Location = New-Object System.Drawing.Point(500, 70)
$btnUninstall.Width = 140

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = 'Restore'
$btnRestore.Location = New-Object System.Drawing.Point(650, 70)
$btnRestore.Width = 90

$top.Controls.AddRange(@($lblDev, $cmbDev, $btnRefresh, $lblWifi, $txtWifi, $btnConnect, $btnAudit, $btnReport, $btnDisable, $btnEnable, $btnClear, $btnHarden, $btnUninstall, $btnRestore))

$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Top'
$list.Height = 240
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true

foreach ($col in @(@('Package', 280), @('Version', 130), @('Installed', 70), @('Enabled', 70), @('Running', 70), @('Alarms', 60), @('UID', 70))) {
    $h = New-Object System.Windows.Forms.ColumnHeader
    $h.Text = $col[0]
    $h.Width = [int]$col[1]
    [void]$list.Columns.Add($h)
}

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Dock = 'Fill'
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:LogBox = $logBox

$form.Controls.Add($list)
$form.Controls.Add($logBox)
$form.Controls.Add($top)

function Refresh-Devices {
    $cmbDev.Items.Clear()
    foreach ($d in Get-Devices) {
        [void]$cmbDev.Items.Add(($d.Serial + '  [' + $d.State + ']  ' + $d.Model))
    }
    if ($cmbDev.Items.Count -gt 0) { $cmbDev.SelectedIndex = 0 }
}

function Pick-Serial {
    if ($cmbDev.SelectedItem) {
        $script:Serial = ($cmbDev.SelectedItem.ToString() -split '\s+')[0]
    }
}

function Run-Audit {
    $list.Items.Clear()
    foreach ($t in $script:Targets) {
        $a = Get-Audit $t
        if ($a) {
            $item = New-Object System.Windows.Forms.ListViewItem($a.Package)
            [void]$item.SubItems.Add($a.Version)
            [void]$item.SubItems.Add([string]$a.Installed)
            [void]$item.SubItems.Add($a.Enabled)
            [void]$item.SubItems.Add([string]$a.Running)
            [void]$item.SubItems.Add($a.Alarms)
            [void]$item.SubItems.Add($a.Uid)
            [void]$list.Items.Add($item)
            Log ('found ' + $a.Package + ' v' + $a.Version + ' installed=' + $a.Installed + ' enabled=' + $a.Enabled)
        } else {
            Log ('not present: ' + $t)
        }
    }
}

$btnRefresh.Add_Click({ Refresh-Devices })
$btnConnect.Add_Click({
    $target = $txtWifi.Text.Trim()
    if (-not $target) { return }
    $r = & $script:Adb connect $target 2>&1
    Log ('connect: ' + ($r -join ' '))
    Refresh-Devices
})
$cmbDev.Add_SelectedIndexChanged({ Pick-Serial })
$btnAudit.Add_Click({ Pick-Serial; Run-Audit })
$btnReport.Add_Click({
    Pick-Serial
    $r = Get-Report
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('phonefix-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
    $r | Out-File -Encoding utf8 $path
    Log ('report saved: ' + $path)
})
$btnDisable.Add_Click({
    Pick-Serial
    $ans = [System.Windows.Forms.MessageBox]::Show('Disable for user 0? Reversible with Re-enable.', 'Confirm', 'YesNo', 'Warning')
    if ($ans -eq 'Yes') { Log (Do-Action 'disable' $script:Target); Run-Audit }
})
$btnEnable.Add_Click({
    Pick-Serial
    Log (Do-Action 'enable' $script:Target)
    Run-Audit
})
$btnClear.Add_Click({
    Pick-Serial
    $ans = [System.Windows.Forms.MessageBox]::Show('Clear app data? This cannot be undone.', 'Confirm', 'YesNo', 'Warning')
    if ($ans -eq 'Yes') { Log (Do-Action 'clear' $script:Target); Run-Audit }
})
$btnHarden.Add_Click({
    Pick-Serial
    Log (Do-Action 'harden' $script:Target)
    Run-Audit
})
$btnUninstall.Add_Click({
    Pick-Serial
    $ans = [System.Windows.Forms.MessageBox]::Show('Uninstall for user 0?' + [Environment]::NewLine + 'The system-partition copy remains; a factory reset or OTA can bring it back. Restore with the Restore button.', 'Confirm', 'YesNo', 'Warning')
    if ($ans -eq 'Yes') { Log (Do-Action 'uninstall' $script:Target); Run-Audit }
})
$btnRestore.Add_Click({
    Pick-Serial
    Log (Do-Action 'restore' $script:Target)
    Run-Audit
})

Refresh-Devices
Log ('adb: ' + $script:Adb)
[void]$form.ShowDialog()


