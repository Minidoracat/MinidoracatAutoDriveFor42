# Minidoracat PZ MOD 家族 — 測試啟動器圖形介面（正本：D:/github/pz-family-docs/scripts/）
# 只定義 Show-PZTestLauncher；由 PZ_Test.ps1 在無 -Action 時 dot-source 後呼叫。
# 實際工作一律交給獨立 powershell.exe -File <PZ_Test.ps1> -Action ...，本檔不重複任何同步/啟動邏輯。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# PowerShell 5.1 的舊宿主預設使用 legacy accessibility；只在本程序啟用 .NET 原生 UIA 改善。
foreach ($suffix in @('', '.2', '.3', '.4', '.5')) {
    $switchName = 'Switch.UseLegacyAccessibilityFeatures' + $suffix
    [AppContext]::SetSwitch($switchName, $false)
}
[AppContext]::SetSwitch('Switch.System.Windows.Forms.UseLegacyToolTipDisplay', $false)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('PZLauncherWindowTheme' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PZLauncherWindowTheme {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    public static int DarkTitlebar(IntPtr window) {
        int value = 1;
        return DwmSetWindowAttribute(window, 20, ref value, 4);
    }
}
'@
}

function Get-PZLauncherSettingsPath {
    param([string]$ProjectRoot, [string]$ZomboidDir)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(
        [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\').ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    return (Join-Path $ZomboidDir ("MinidoracatDevSync\launcher\" + $key + '.json'))
}

function Read-PZLauncherSettings {
    param([string]$Path)
    Assert-PZSyncPhysicalPath $Path
    if (-not [IO.File]::Exists($Path)) { return $null }
    $s = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if (($s.version -isnot [int] -and $s.version -isnot [long]) -or $s.version -ne 1 -or
        $s.noSteam -isnot [bool] -or $s.debugClient -isnot [bool] -or
        $s.target -isnot [string] -or $s.target -notin @('client', 'server', 'combo') -or
        ($s.clients -isnot [int] -and $s.clients -isnot [long]) -or $s.clients -notin @(1, 2) -or
        $s.server -isnot [string] -or [string]::IsNullOrWhiteSpace($s.server)) {
        throw '啟動選項格式不符'
    }
    return $s
}

function Write-PZLauncherSettings {
    param([string]$Path, [hashtable]$Choices)
    Assert-PZSyncPhysicalPath $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    # 只保存安全選項；完整驗證與強制停止不進設定檔。
    $doc = [ordered]@{
        version = 1; noSteam = [bool]$Choices.noSteam; target = [string]$Choices.target
        clients = [int]$Choices.clients; debugClient = [bool]$Choices.debugClient; server = [string]$Choices.server
    }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Move-PZSyncFileAtomic -Temp $temp -Target $Path
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function ConvertTo-PZArgToken {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Show-PZTestLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$ZomboidDir,
        [Parameter(Mandatory = $true)][string]$ModLabel,
        [switch]$SupportsCNTrans
    )

    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "找不到啟動器腳本：`n$LauncherPath`n`n請重新執行家族腳本散布（sync_family_scripts.ps1）後再試。",
            'PZ 測試啟動器', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    . (Join-Path $ProjectRoot 'scripts\sync_mod.ps1')
    $preferencesPath = Get-PZLauncherSettingsPath -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir
    $savedChoices = $null
    $choicesNotice = ''
    try { $savedChoices = Read-PZLauncherSettings $preferencesPath }
    catch { $choicesNotice = '無法讀取上次選項，已使用預設。請重新選擇需要的啟動方式。' }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    # 暗色桌面工具：原生控制項保留鍵盤與勾選狀態，不加裝飾動畫。
    $installed = New-Object System.Drawing.Text.InstalledFontCollection
    $families = @($installed.Families | ForEach-Object { $_.Name })
    $uiFamily = if ($families -contains 'Microsoft JhengHei UI') { 'Microsoft JhengHei UI' }
                elseif ($families -contains 'Microsoft JhengHei') { 'Microsoft JhengHei' }
                else { 'Segoe UI' }
    $monoFamily = if ($families -contains 'Consolas') { 'Consolas' } else { 'Courier New' }

    $fontBody = New-Object System.Drawing.Font($uiFamily, 10.5)
    $fontBodyBold = New-Object System.Drawing.Font($uiFamily, 10.5, [System.Drawing.FontStyle]::Bold)
    $fontTitle = New-Object System.Drawing.Font($uiFamily, 18, [System.Drawing.FontStyle]::Bold)
    $fontSmall = New-Object System.Drawing.Font($uiFamily, 10)
    $fontPrimary = New-Object System.Drawing.Font($uiFamily, 12, [System.Drawing.FontStyle]::Bold)
    $fontMono = New-Object System.Drawing.Font($monoFamily, 9.5)

    $colBack = [System.Drawing.ColorTranslator]::FromHtml('#181B22')
    $colPanel = [System.Drawing.ColorTranslator]::FromHtml('#212632')
    $colField = [System.Drawing.ColorTranslator]::FromHtml('#2B3343')
    $colText = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F8')
    $colSub = [System.Drawing.ColorTranslator]::FromHtml('#B8C2D2')
    $colLine = [System.Drawing.ColorTranslator]::FromHtml('#718097')
    $colPrimary = [System.Drawing.ColorTranslator]::FromHtml('#2D62AD')
    $colFocus = [System.Drawing.ColorTranslator]::FromHtml('#B7D4FF')
    $colPrimaryHover = [System.Drawing.ColorTranslator]::FromHtml('#356FC2')
    $colPrimaryPressed = [System.Drawing.ColorTranslator]::FromHtml('#24528F')
    $colControlHover = [System.Drawing.ColorTranslator]::FromHtml('#394457')
    $colDanger = [System.Drawing.ColorTranslator]::FromHtml('#FFB4B9')
    $colOk = [System.Drawing.ColorTranslator]::FromHtml('#98D3AF')
    if ([Windows.Forms.SystemInformation]::HighContrast) {
        $colBack = $colPanel = $colField = [Drawing.SystemColors]::Window
        $colText = $colSub = $colDanger = $colOk = [Drawing.SystemColors]::WindowText
        $colLine = $colFocus = $colPrimary = [Drawing.SystemColors]::Highlight
        $colPrimaryHover = $colPrimaryPressed = [Drawing.SystemColors]::Highlight
        $colControlHover = [Drawing.SystemColors]::Control
    }

    $serverIniDir = Join-Path $ZomboidDir 'Server'
    $state = @{
        Process   = $null
        OutTask   = $null
        ErrTask   = $null
        Watch     = $null
        Label     = ''
        Verified  = $false   # 本次工作是否帶了 -ForceVerify
        LayoutBusy = $false
        LayoutWidth = -1
        PreferencesSaved = $true
    }

    # ---------- 版面 ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Name = 'PZTestLauncherForm'
    $form.Text = "PZ 測試啟動器 — $ModLabel"
    $form.AccessibleName = 'Project Zomboid MOD 測試啟動器'
    $form.BackColor = $colBack
    $form.ForeColor = $colText
    $form.Font = $fontBody
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Padding = New-Object System.Windows.Forms.Padding(16)
    $form.AutoScroll = $true

    $gfx = $form.CreateGraphics()
    $scale = $gfx.DpiX / 96.0
    $gfx.Dispose()
    $form.MinimumSize = New-Object System.Drawing.Size([int](320 * $scale), [int](400 * $scale))
    $form.ClientSize = New-Object System.Drawing.Size([int](860 * $scale), [int](600 * $scale))
    if (-not [Windows.Forms.SystemInformation]::HighContrast) { [void][PZLauncherWindowTheme]::DarkTitlebar($form.Handle) }

    $tip = New-Object System.Windows.Forms.ToolTip

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Name = 'RootLayout'
    $root.Dock = [System.Windows.Forms.DockStyle]::Top
    $root.AutoSize = $true
    $root.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $root.ColumnCount = 1
    $root.RowCount = 5
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($i in 0..4) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    $form.Controls.Add($root)

    # --- 標題 ---
    $header = New-Object System.Windows.Forms.Panel
    $header.Name = 'HeaderPanel'
    $header.BackColor = $colBack
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 12)
    $header.AutoSize = $true
    $header.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink

    $headerStack = New-Object System.Windows.Forms.TableLayoutPanel
    $headerStack.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerStack.ColumnCount = 1
    $headerStack.RowCount = 2
    [void]$headerStack.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    [void]$headerStack.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $headerStack.AutoSize = $true
    $headerStack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Name = 'TitleLabel'
    $lblTitle.Text = 'PZ 測試啟動器'
    $lblTitle.Font = $fontTitle
    $lblTitle.ForeColor = $colText
    $lblTitle.AutoSize = $true

    $lblMod = New-Object System.Windows.Forms.Label
    $lblMod.Name = 'ModLabel'
    $lblMod.Text = $ModLabel
    $lblMod.Font = $fontSmall
    $lblMod.ForeColor = $colSub
    $lblMod.AutoSize = $true
    $lblMod.Dock = [Windows.Forms.DockStyle]::Top
    $lblMod.AutoEllipsis = $true
    $lblMod.MaximumSize = New-Object System.Drawing.Size([int](760 * $scale), 0)
    $tip.SetToolTip($lblMod, "來源專案：$ProjectRoot`n啟動器：$LauncherPath`n遊戲資料夾：$ZomboidDir")

    $headerStack.Controls.Add($lblTitle, 0, 0)
    $headerStack.Controls.Add($lblMod, 0, 1)
    $header.Controls.Add($headerStack)
    $root.Controls.Add($header, 0, 0)

    # --- 啟動設定 ---
    $grpSettings = New-Object System.Windows.Forms.Panel
    $grpSettings.Name = 'SettingsGroup'
    $grpSettings.AccessibleName = '啟動設定'
    $grpSettings.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Grouping
    $grpSettings.Font = $fontBody
    $grpSettings.ForeColor = $colText
    $grpSettings.BackColor = $colPanel
    $grpSettings.Dock = [System.Windows.Forms.DockStyle]::Top
    $grpSettings.AutoSize = $true
    $grpSettings.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $grpSettings.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    $grpSettings.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Name = 'SettingsLayout'
    $grid.Dock = [System.Windows.Forms.DockStyle]::Top
    $grid.Font = $fontBody
    $grid.ColumnCount = 2
    $grid.RowCount = 6
    foreach ($i in 0..5) { [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) }
    $grid.AutoSize = $true
    $grid.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $grpSettings.Controls.Add($grid)
    $root.Controls.Add($grpSettings, 0, 1)

    $newRowLabel = {
        param([string]$Text, [int]$Row)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.Font = $fontBody
        $l.ForeColor = $colSub
        $l.AutoSize = $true
        $l.Margin = New-Object System.Windows.Forms.Padding(0, 8, 12, 4)
        $grid.Controls.Add($l, 0, $Row)
    }
    $newFlow = {
        param([string]$Name, [int]$Row)
        $f = New-Object System.Windows.Forms.FlowLayoutPanel
        $f.Name = $Name
        $f.AutoSize = $true
        $f.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $f.WrapContents = $true
        $f.Dock = [System.Windows.Forms.DockStyle]::Top
        $f.Font = $fontBody
        $f.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
        $grid.Controls.Add($f, 1, $Row)
        return $f
    }

    # 伺服器設定
    & $newRowLabel '伺服器設定' 0
    $cmbServer = New-Object System.Windows.Forms.ComboBox
    $cmbServer.Name = 'ServerCombo'
    $cmbServer.AccessibleName = '伺服器設定檔'
    $cmbServer.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbServer.Font = $fontBody
    $cmbServer.BackColor = $colField
    $cmbServer.ForeColor = $colText
    $cmbServer.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $cmbServer.Width = [int](260 * $scale)
    $cmbServer.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $grid.Controls.Add($cmbServer, 1, 0)
    $tip.SetToolTip($cmbServer, "來自 $serverIniDir 的 *.ini；沒有檔案時使用 servertest（首次啟動會自動建立）。本介面不會修改 ini。")

    $refreshServers = {
        $current = if ($cmbServer.SelectedItem) { [string]$cmbServer.SelectedItem } else { 'servertest' }
        $names = @(Get-ChildItem -LiteralPath $serverIniDir -Filter '*.ini' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName } | Sort-Object)
        if ($names.Count -eq 0) { $names = @('servertest') }
        $cmbServer.BeginUpdate()
        $cmbServer.Items.Clear()
        foreach ($n in $names) { [void]$cmbServer.Items.Add($n) }
        $idx = $cmbServer.Items.IndexOf($current)
        $cmbServer.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
        $cmbServer.EndUpdate()
    }
    & $refreshServers
    $cmbServer.add_DropDown({ & $refreshServers })

    # 連線模式（no-Steam 置前且預設）
    & $newRowLabel '連線模式' 1
    $flowMode = & $newFlow 'ModeFlow' 1
    $rdoNoSteam = New-Object System.Windows.Forms.RadioButton
    $rdoNoSteam.Name = 'NoSteamRadio'
    $rdoNoSteam.AccessibleName = 'no-Steam 模式（本機多開）'
    $rdoNoSteam.Text = 'no-Steam'
    $rdoNoSteam.Checked = $true
    $rdoNoSteam.AutoSize = $true
    $rdoNoSteam.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 6)
    $rdoSteam = New-Object System.Windows.Forms.RadioButton
    $rdoSteam.Name = 'SteamRadio'
    $rdoSteam.AccessibleName = 'Steam 模式（需登入 Steam，僅 1 個客戶端）'
    $rdoSteam.Text = 'Steam'
    $rdoSteam.AutoSize = $true
    $rdoSteam.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $flowMode.Controls.Add($rdoNoSteam)
    $flowMode.Controls.Add($rdoSteam)

    # 啟動內容
    & $newRowLabel '啟動內容' 2
    $flowTarget = & $newFlow 'TargetFlow' 2
    $rdoClient = New-Object System.Windows.Forms.RadioButton
    $rdoClient.Name = 'ClientRadio'
    $rdoClient.AccessibleName = '只啟動客戶端'
    $rdoClient.Text = '客戶端'
    $rdoClient.Checked = $true
    $rdoClient.AutoSize = $true
    $rdoClient.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 6)
    $rdoServer = New-Object System.Windows.Forms.RadioButton
    $rdoServer.Name = 'ServerRadio'
    $rdoServer.AccessibleName = '只啟動專用伺服器'
    $rdoServer.Text = '伺服器'
    $rdoServer.AutoSize = $true
    $rdoServer.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 6)
    $rdoCombo = New-Object System.Windows.Forms.RadioButton
    $rdoCombo.Name = 'ComboRadio'
    $rdoCombo.AccessibleName = '伺服器 + 客戶端'
    $rdoCombo.Text = '伺服器 + 客戶端'
    $rdoCombo.AutoSize = $true
    $rdoCombo.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $flowTarget.Controls.Add($rdoClient)
    $flowTarget.Controls.Add($rdoServer)
    $flowTarget.Controls.Add($rdoCombo)

    # 客戶端數量
    & $newRowLabel '客戶端數量' 3
    $flowClients = & $newFlow 'ClientsFlow' 3
    $rdoClients1 = New-Object System.Windows.Forms.RadioButton
    $rdoClients1.Name = 'Clients1Radio'
    $rdoClients1.AccessibleName = '1 個客戶端'
    $rdoClients1.Text = '1 個'
    $rdoClients1.Checked = $true
    $rdoClients1.AutoSize = $true
    $rdoClients1.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 6)
    $rdoClients2 = New-Object System.Windows.Forms.RadioButton
    $rdoClients2.Name = 'Clients2Radio'
    $rdoClients2.AccessibleName = '2 個客戶端（no-Steam 多開）'
    $rdoClients2.Text = '2 個'
    $rdoClients2.AutoSize = $true
    $rdoClients2.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $flowClients.Controls.Add($rdoClients1)
    $flowClients.Controls.Add($rdoClients2)

    # 其他選項
    & $newRowLabel '其他選項' 4
    $flowOptions = & $newFlow 'OptionsFlow' 4
    $chkDebug = New-Object System.Windows.Forms.CheckBox
    $chkDebug.Name = 'DebugCheck'
    $chkDebug.AccessibleName = '客戶端使用 Debug 模式'
    $chkDebug.Text = '啟用 Debug'
    $chkDebug.AccessibleName = $chkDebug.Text
    $chkDebug.AutoSize = $true
    $chkDebug.Margin = New-Object System.Windows.Forms.Padding(0, 6, 20, 6)
    $chkVerify = New-Object System.Windows.Forms.CheckBox
    $chkVerify.Name = 'ForceVerifyCheck'
    $chkVerify.AccessibleName = '本次執行完整驗證'
    $chkVerify.Text = '完整驗證一次'
    $chkVerify.AccessibleName = $chkVerify.Text
    $chkVerify.AutoSize = $true
    $chkVerify.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $tip.SetToolTip($chkVerify, '忽略增量快取、重新雜湊並比對整份 MOD。成功後會自動取消勾選，下一次回到快取模式。')
    $flowOptions.Controls.Add($chkDebug)
    $flowOptions.Controls.Add($chkVerify)
    $rowLabels = @(0..4 | ForEach-Object { $grid.GetControlFromPosition(0, $_) })
    $rowFields = @($cmbServer, $flowMode, $flowTarget, $flowClients, $flowOptions)
    $lblSummary = New-Object Windows.Forms.Label
    $lblSummary.AutoSize = $true
    $lblSummary.ForeColor = $colSub
    $lblSummary.Font = $fontSmall
    $lblSummary.Margin = [Windows.Forms.Padding]::new(0, 12, 0, 4)
    $grid.Controls.Add($lblSummary, 0, 5)
    $grid.SetColumnSpan($lblSummary, 2)
    foreach ($choice in @($rdoNoSteam, $rdoSteam, $rdoClient, $rdoServer, $rdoCombo, $rdoClients1, $rdoClients2, $chkDebug, $chkVerify)) {
        $choice.UseVisualStyleBackColor = $false
        $choice.MinimumSize = [Drawing.Size]::new(0, [int](28 * $scale))
    }

    # --- 動作 ---
    $flowActions = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowActions.Name = 'ActionFlow'
    $flowActions.Dock = [System.Windows.Forms.DockStyle]::Top
    $flowActions.AutoSize = $true
    $flowActions.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flowActions.WrapContents = $true
    $flowActions.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $root.Controls.Add($flowActions, 0, 2)

    $btnLaunch = New-Object System.Windows.Forms.Button
    $btnLaunch.Name = 'LaunchButton'
    $btnLaunch.AccessibleName = '同步並啟動'
    $btnLaunch.Font = $fontPrimary
    $btnLaunch.BackColor = $colPrimary
    $btnLaunch.ForeColor = [System.Drawing.Color]::White
    $btnLaunch.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnLaunch.FlatAppearance.BorderSize = 0
    $btnLaunch.FlatAppearance.MouseOverBackColor = $colPrimaryHover
    $btnLaunch.FlatAppearance.MouseDownBackColor = $colPrimaryPressed
    if ([Windows.Forms.SystemInformation]::HighContrast) { $btnLaunch.ForeColor = [Drawing.SystemColors]::HighlightText }
    $btnLaunch.AutoSize = $true
    $btnLaunch.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $btnLaunch.Padding = New-Object System.Windows.Forms.Padding(18, 10, 18, 10)
    $btnLaunch.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 8)

    $mkSecondary = {
        param([string]$Name, [string]$Text, [string]$Access, [System.Drawing.Color]$Fore)
        $b = New-Object System.Windows.Forms.Button
        $b.Name = $Name
        $b.Text = $Text
        $b.AccessibleName = $Text
        $b.AccessibleDescription = $Access
        $b.Font = $fontBody
        $b.BackColor = $colField
        $b.ForeColor = $Fore
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderColor = $colLine
        $b.FlatAppearance.MouseOverBackColor = $colControlHover
        $b.FlatAppearance.MouseDownBackColor = $colPanel
        $b.FlatAppearance.BorderSize = 2
        $b.Tag = @{ FocusColor = $colFocus; BorderColor = $colLine }
        $b.add_Enter({ param($sender, $eventArgs) $sender.FlatAppearance.BorderColor = $sender.Tag.FocusColor })
        $b.add_Leave({ param($sender, $eventArgs) $sender.FlatAppearance.BorderColor = $sender.Tag.BorderColor })
        $b.AutoSize = $true
        $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $b.Padding = New-Object System.Windows.Forms.Padding(14, 8, 14, 8)
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
        return $b
    }
    $btnSync = & $mkSecondary 'SyncOnlyButton' '只同步' '只同步 MOD，不啟動遊戲' $colText
    $btnLogs = & $mkSecondary 'OpenLogsButton' '開啟紀錄資料夾' '開啟 Zomboid log 目錄' $colText
    $btnCNTrans = $null
    if ($SupportsCNTrans) {
        $btnCNTrans = & $mkSecondary 'CNTransButton' '漢化對照啟動' '以漢化對照設定啟動' $colText
        $tip.SetToolTip($btnCNTrans, '啟動漢化對照伺服器與 1 個 Debug 客戶端；連線模式沿用目前選擇。')
    }
    $btnStop = & $mkSecondary 'StopAllButton' '強制停止 PZ' '強制停止所有 Project Zomboid 程序，未存檔進度可能遺失' $colDanger
    $btnStop.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $tip.SetToolTip($btnStop, '直接砍掉遊戲與伺服器進程，未存檔的進度會遺失。僅在卡住時使用。')

    $flowActions.Controls.Add($btnLaunch)
    $flowActions.Controls.Add($btnSync)
    $flowActions.Controls.Add($btnLogs)
    if ($btnCNTrans) { $flowActions.Controls.Add($btnCNTrans) }
    $flowActions.Controls.Add($btnStop)

    # --- 狀態列 ---
    $statusBar = New-Object System.Windows.Forms.TableLayoutPanel
    $statusBar.Name = 'StatusBar'
    $statusBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $statusBar.ColumnCount = 1
    $statusBar.RowCount = 2
    [void]$statusBar.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    [void]$statusBar.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $statusBar.AutoSize = $true
    $statusBar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $statusBar.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    [void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $root.Controls.Add($statusBar, 0, 3)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Name = 'StatusLabel'
    $lblStatus.LiveSetting = [Windows.Forms.Automation.AutomationLiveSetting]::Polite
    $lblStatus.Text = '就緒。平常使用快速檢查；懷疑檔案異常時再勾完整驗證。'
    $lblStatus.Font = $fontBody
    $lblStatus.ForeColor = $colSub
    $lblStatus.AutoSize = $true
    $lblStatus.MaximumSize = New-Object System.Drawing.Size([int](620 * $scale), 0)
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(2, 6, 12, 6)

    $lblElapsed = New-Object System.Windows.Forms.Label
    $lblElapsed.Name = 'ElapsedLabel'
    $lblElapsed.Text = ''
    $lblElapsed.Visible = $false
    $lblElapsed.Font = $fontMono
    $lblElapsed.MinimumSize = [Drawing.Size]::new([int](110 * $scale), 0)
    $lblElapsed.ForeColor = $colSub
    $lblElapsed.AutoSize = $true
    $lblElapsed.Margin = New-Object System.Windows.Forms.Padding(0, 8, 12, 6)

    $btnDetails = & $mkSecondary 'ToggleLogButton' '詳細紀錄' '展開完整操作與錯誤紀錄' $colText
    $btnDetails.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)

    $statusBar.Controls.Add($lblStatus, 0, 0)
    $statusActions = New-Object Windows.Forms.FlowLayoutPanel
    $statusActions.AutoSize = $true
    $statusActions.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $statusActions.WrapContents = $true
    $statusActions.Dock = [Windows.Forms.DockStyle]::Top
    $statusActions.Controls.Add($lblElapsed)
    $statusActions.Controls.Add($btnDetails)
    $statusBar.Controls.Add($statusActions, 0, 1)

    # --- 詳細紀錄 ---
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Name = 'LogTextBox'
    $txtLog.AccessibleName = '詳細紀錄'
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.WordWrap = $true
    $txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtLog.Font = $fontMono
    $txtLog.BackColor = $colPanel
    $txtLog.ForeColor = $colText
    $txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtLog.Dock = [System.Windows.Forms.DockStyle]::Top
    $txtLog.Height = [int](180 * $scale)
    $txtLog.MinimumSize = [Drawing.Size]::new(0, [int](180 * $scale))
    $txtLog.Visible = $false
    $root.Controls.Add($txtLog, 0, 4)

    # ---------- 行為 ----------
    $appendLog = {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return }
        # 先算好字串再單一引數呼叫：方法括號內直接寫 -replace 的逗號會被當成引數分隔。
        $normalized = $Text -replace "`r`n", "`n"
        $normalized = $normalized -replace "`n", "`r`n"
        if (-not $normalized.EndsWith("`r`n")) { $normalized += "`r`n" }
        $txtLog.AppendText($normalized)
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }

    $setStatus = {
        param([string]$Text, [System.Drawing.Color]$Color)
        $lblStatus.Text = $Text
        $lblStatus.ForeColor = $Color
        [void]$lblStatus.AccessibilityObject.RaiseLiveRegionChanged()
    }

    $getClients = { if ($rdoClients2.Enabled -and $rdoClients2.Checked) { 2 } else { 1 } }

    $describe = {
        $mode = if ($rdoSteam.Checked) { 'Steam' } else { 'no-Steam' }
        $n = & $getClients
        if ($rdoServer.Checked) { return "專用伺服器（$mode）" }
        $dbg = if ($chkDebug.Checked) { ' / Debug' } else { '' }
        if ($rdoCombo.Checked) { return "伺服器 + $n 個客戶端（$mode$dbg）" }
        if ($n -eq 2) { return "2 個客戶端多開（$mode$dbg）" }
        return "客戶端（$mode$dbg）"
    }

    $syncUi = {
        # Steam 無法多開：強制 1 個客戶端
        $rdoClients2.Enabled = (-not $rdoSteam.Checked) -and (-not $rdoServer.Checked)
        if (-not $rdoClients2.Enabled -and $rdoClients2.Checked) { $rdoClients1.Checked = $true }
        $rdoClients2.Visible = $rdoClients2.Enabled
        # 只啟動伺服器：客戶端相關設定無意義
        $rdoClients1.Enabled = -not $rdoServer.Checked
        $chkDebug.Enabled = -not $rdoServer.Checked
        $rowLabels[3].Visible = -not $rdoServer.Checked
        $flowClients.Visible = -not $rdoServer.Checked
        $chkDebug.Visible = -not $rdoServer.Checked
        $btnLaunch.Text = '同步並啟動'
        $btnLaunch.AccessibleName = $btnLaunch.Text + ' ' + (& $describe)
        $limit = if ($rdoServer.Checked) { '' } elseif ($rdoSteam.Checked) { 'Steam 需登入，最多 1 個客戶端。' } else { 'no-Steam 支援本機多開。' }
        $lblSummary.Text = "將啟動：$(& $describe)。$limit"
    }
    if ($savedChoices) {
        $rdoSteam.Checked = -not $savedChoices.noSteam
        $rdoNoSteam.Checked = $savedChoices.noSteam
        $rdoClient.Checked = $savedChoices.target -eq 'client'
        $rdoServer.Checked = $savedChoices.target -eq 'server'
        $rdoCombo.Checked = $savedChoices.target -eq 'combo'
        $rdoClients2.Checked = $savedChoices.clients -eq 2
        $rdoClients1.Checked = $savedChoices.clients -eq 1
        $chkDebug.Checked = $savedChoices.debugClient
        $at = $cmbServer.Items.IndexOf([string]$savedChoices.server)
        if ($at -ge 0) { $cmbServer.SelectedIndex = $at }
        else { $choicesNotice = '上次的伺服器設定已不在清單，請確認本次選擇。' }
    }
    if ($choicesNotice) { $lblStatus.Text = $choicesNotice }
    foreach ($c in @($rdoNoSteam, $rdoSteam, $rdoClient, $rdoServer, $rdoCombo, $rdoClients1, $rdoClients2)) {
        $c.add_CheckedChanged({ & $syncUi })
    }
    $chkDebug.add_CheckedChanged({ & $syncUi })
    & $syncUi

    $saveChoices = {
        try {
            $target = if ($rdoServer.Checked) { 'server' } elseif ($rdoCombo.Checked) { 'combo' } else { 'client' }
            Write-PZLauncherSettings -Path $preferencesPath -Choices @{
                noSteam = $rdoNoSteam.Checked; target = $target; clients = (& $getClients)
                debugClient = $chkDebug.Checked; server = [string]$cmbServer.SelectedItem
            }
            $state.PreferencesSaved = $true
            return $true
        } catch {
            $state.PreferencesSaved = $false
            & $appendLog ("[選項未保存] {0}。請檢查設定資料夾是否可寫入。" -f $_.Exception.Message)
            return $false
        }
    }

    # 寬視窗採標籤／欄位兩欄；窄視窗改為單欄，內容由原生捲軸保持可達。
    $applyLayout = {
        if ($state.LayoutBusy) { return }
        $width = [Math]::Max(220, $form.ClientSize.Width - $form.Padding.Horizontal - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
        if ($state.LayoutWidth -eq $width) { return }
        $state.LayoutBusy = $true
        $state.LayoutWidth = $width
        $root.SuspendLayout()
        $grid.SuspendLayout()
        try {
            $narrow = $width -lt (600 * $scale)
            $inner = [Math]::Max(180, $width - $grpSettings.Padding.Horizontal - 12)
            $labelWidth = [int](112 * $scale)
            $fieldWidth = if ($narrow) { $inner } else { $inner - $labelWidth }
            $root.MaximumSize = [Drawing.Size]::new($width, 0)
            $root.Width = $width
            $header.MaximumSize = [Drawing.Size]::new($width, 0)
            $headerStack.Width = $width
            $lblTitle.MaximumSize = [Drawing.Size]::new($width - 8, 0)
            $lblMod.MaximumSize = [Drawing.Size]::new($width - 8, 0)
            $lblMod.Width = $width - 8
            $grpSettings.MaximumSize = [Drawing.Size]::new($width, 0)
            $grid.MaximumSize = [Drawing.Size]::new($inner, 0)
            $grid.Width = $inner
            $grid.ColumnCount = 2
            $grid.RowCount = 11
            $grid.SetColumnSpan($lblSummary, 1)
            for ($i = 0; $i -lt 5; $i++) {
                $labelRow = if ($narrow) { $i * 2 } else { $i }
                $fieldRow = if ($narrow) { $i * 2 + 1 } else { $i }
                $fieldColumn = if ($narrow) { 0 } else { 1 }
                $grid.SetCellPosition($rowLabels[$i], [Windows.Forms.TableLayoutPanelCellPosition]::new(0, $labelRow))
                $grid.SetCellPosition($rowFields[$i], [Windows.Forms.TableLayoutPanelCellPosition]::new($fieldColumn, $fieldRow))
                $rowFields[$i].MaximumSize = [Drawing.Size]::new($fieldWidth, 0)
                $rowFields[$i].Width = $fieldWidth
            }
            $summaryRow = if ($narrow) { 10 } else { 5 }
            $grid.SetCellPosition($lblSummary, [Windows.Forms.TableLayoutPanelCellPosition]::new(0, $summaryRow))
            $grid.ColumnCount = if ($narrow) { 1 } else { 2 }
            $grid.RowCount = $summaryRow + 1
            $grid.ColumnStyles.Clear()
            if (-not $narrow) { [void]$grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, $labelWidth)) }
            [void]$grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
            $grid.RowStyles.Clear()
            for ($i = 0; $i -le $summaryRow; $i++) { [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) }
            $grid.RowStyles[$grid.GetRow($cmbServer)].SizeType = [Windows.Forms.SizeType]::Absolute
            $grid.RowStyles[$grid.GetRow($cmbServer)].Height = $cmbServer.PreferredHeight + $cmbServer.Margin.Vertical
            $grid.SetColumnSpan($lblSummary, $grid.ColumnCount)
            $lblSummary.MaximumSize = [Drawing.Size]::new($inner, 0)
            $cmbServer.DropDownWidth = [Math]::Max($fieldWidth, [int](260 * $scale))
            foreach ($panel in @($flowActions, $statusBar, $statusActions)) {
                $panel.MaximumSize = [Drawing.Size]::new($width, 0)
                $panel.Width = $width
            }
            $lblStatus.MaximumSize = [Drawing.Size]::new($width - 20, 0)
            $txtLog.Width = $width - 8
        } finally {
            $grid.ResumeLayout($true)
            $root.ResumeLayout($true)
            $state.LayoutBusy = $false
        }
    }
    $form.add_ClientSizeChanged({ & $applyLayout })
    & $applyLayout
    & $appendLog ("專案：{0}`r`n來源：{1}`r`n設定會在啟動或關閉視窗時保存。" -f $ModLabel, $ProjectRoot)

    $btnLaunch.FlatAppearance.BorderSize = 2
    $btnLaunch.FlatAppearance.BorderColor = $colLine
    $btnLaunch.Tag = @{ FocusColor = $colFocus; BorderColor = $colLine }
    $btnLaunch.add_Enter({ param($sender, $eventArgs) $sender.FlatAppearance.BorderColor = $sender.Tag.FocusColor })
    $btnLaunch.add_Leave({ param($sender, $eventArgs) $sender.FlatAppearance.BorderColor = $sender.Tag.BorderColor })

    $busyControls = @($cmbServer, $rdoNoSteam, $rdoSteam, $rdoClient, $rdoServer, $rdoCombo,
        $rdoClients1, $rdoClients2, $chkDebug, $chkVerify, $btnLaunch, $btnSync, $btnStop)
    if ($btnCNTrans) { $busyControls += $btnCNTrans }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250

    $setBusy = {
        param([bool]$Busy)
        foreach ($c in $busyControls) { $c.Enabled = -not $Busy }
        if (-not $Busy) { & $syncUi }
        $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default }
    }

    $showLog = {
        $txtLog.Visible = $true
        $btnDetails.Text = $btnDetails.AccessibleName = '收合紀錄'
        $form.PerformLayout()
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
        $form.ScrollControlIntoView($txtLog)
    }

    $finishJob = {
        $p = $state.Process
        $code = $p.ExitCode
        $out = $state.OutTask.Result
        $err = $state.ErrTask.Result
        $elapsed = $state.Watch.Elapsed
        $timer.Stop()
        $state.Watch.Stop()
        & $appendLog $out
        if ($err.Trim()) { & $appendLog "----- 錯誤輸出 -----`r`n$err" }
        & $appendLog ("----- 結束（代碼 $code，耗時 " + $elapsed.ToString('mm\:ss') + "） -----`r`n")
        $lblElapsed.Text = '耗時 {0:N1} 秒' -f $elapsed.TotalSeconds
        if ($code -eq 0) {
            & $setStatus ("完成：$($state.Label)。") $colOk
            if ($state.Verified) { $chkVerify.Checked = $false }
        } else {
            & $setStatus ("未完成：$($state.Label)。請依下方紀錄修正後重試（代碼 $code）。") $colDanger
        }
        $p.Dispose()
        $state.Process = $null
        $state.OutTask = $null
        $state.ErrTask = $null
        & $setBusy $false
        if ($code -ne 0) { & $showLog }
    }

    # 介面自身出錯時：停掉計時器並把錯誤完整顯示出來，避免每 250ms 再彈一次未處理例外視窗。
    $timer.add_Tick({
        try {
            if (-not $state.Process) { $timer.Stop(); return }
            $lblElapsed.Text = '執行中 {0:N1} 秒' -f $state.Watch.Elapsed.TotalSeconds
            if (-not $state.Process.HasExited) { return }
            if (-not ($state.OutTask.IsCompleted -and $state.ErrTask.IsCompleted)) { return }
            & $finishJob
        } catch {
            $timer.Stop()
            $message = $_.Exception.Message
            $where = $_.InvocationInfo.PositionMessage
            if ($state.Process) {
                try { $state.Process.Dispose() } catch { }
                $state.Process = $null
                $state.OutTask = $null
                $state.ErrTask = $null
            }
            & $setBusy $false
            & $appendLog "[介面錯誤] $message`r`n$where"
            & $setStatus "介面更新失敗，已停止自動更新。請查看詳細紀錄，確認工作結果後再操作。" $colDanger
            & $showLog
        }
    })

    $startJob = {
        param([string]$Action, [string]$Label, [bool]$WithClient)
        if ($state.Process) { return }
        [void](& $saveChoices)
        $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-PZArgToken $LauncherPath), '-Action', $Action)
        if ($Action -ne 'stop') {
            $tokens += @('-ServerName', (ConvertTo-PZArgToken ([string]$cmbServer.SelectedItem)))
            if ($Action -eq 'cntrans') {
                $tokens += @('-Clients', '1', '-DebugClient')
            } elseif ($WithClient) {
                $tokens += @('-Clients', ([string](& $getClients)))
                if ($chkDebug.Checked) { $tokens += '-DebugClient' }
            }
            if (-not $rdoSteam.Checked) { $tokens += '-NoSteam' }
            if ($chkVerify.Checked) { $tokens += '-ForceVerify' }
        }
        $argLine = $tokens -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = $argLine
        $psi.WorkingDirectory = $ProjectRoot
        $psi.EnvironmentVariables['PROJECT_ROOT'] = $ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        & $appendLog "===== $Label =====`r`npowershell.exe $argLine"
        try {
            [void]$p.Start()
        } catch {
            $p.Dispose()
            & $setStatus "無法啟動工作程序：$($_.Exception.Message)。請確認 powershell.exe 可執行，或改用命令列直接執行 PZ_Test.ps1。" $colDanger
            & $appendLog "[介面] 啟動工作程序失敗：$($_.Exception.Message)"
            return
        }
        # 後端為非互動模式；關閉 stdin，避免任何意外的 Read-Host 永遠卡住。
        try { $p.StandardInput.Close() } catch { }
        $state.Process = $p
        $state.OutTask = $p.StandardOutput.ReadToEndAsync()
        $state.ErrTask = $p.StandardError.ReadToEndAsync()
        $state.Watch = [System.Diagnostics.Stopwatch]::StartNew()
        $state.Label = $Label
        $state.Verified = [bool]$chkVerify.Checked
        $lblElapsed.Text = '執行中 0.0 秒'
        $lblElapsed.Visible = $true
        & $setStatus "執行中：$Label。完成後會顯示結果，無需重複按啟動。" $colText
        & $setBusy $true
        $timer.Start()
    }

    $btnLaunch.add_Click({
        $action = if ($rdoServer.Checked) { 'server' } elseif ($rdoCombo.Checked) { 'combo' } else { 'client' }
        & $startJob $action ('同步並啟動 ' + (& $describe)) (-not $rdoServer.Checked)
    })

    $btnSync.add_Click({
        & $startJob 'sync' '只同步 MOD（不啟動遊戲）' $false
    })

    if ($btnCNTrans) {
        $btnCNTrans.add_Click({
            $network = if ($rdoSteam.Checked) { 'Steam' } else { 'no-Steam' }
            & $startJob 'cntrans' "漢化對照（$network，伺服器 + 1 個 Debug 客戶端）" $true
        })
    }

    $btnStop.add_Click({
        $confirm = New-Object Windows.Forms.Form
        $confirm.Text = '確認強制停止'
        $confirm.BackColor = $colBack
        $confirm.ForeColor = $colText
        $confirm.Font = $fontBody
        $confirm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
        $confirm.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
        $confirm.ShowInTaskbar = $false
        $confirm.MinimizeBox = $confirm.MaximizeBox = $false
        $confirm.AutoSize = $true
        $confirm.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
        $confirm.Padding = [Windows.Forms.Padding]::new(20)
        $stack = New-Object Windows.Forms.FlowLayoutPanel
        $stack.FlowDirection = [Windows.Forms.FlowDirection]::TopDown
        $stack.AutoSize = $true
        $stack.WrapContents = $false
        $stack.Dock = [Windows.Forms.DockStyle]::Fill
        $body = New-Object Windows.Forms.Label
        $body.Text = '這會強制結束本機所有 PZ 客戶端與伺服器，未存檔進度可能遺失。建議先在伺服器輸入 quit 正常關閉。'
        $body.AutoSize = $true
        $body.MaximumSize = [Drawing.Size]::new([Math]::Min([int](360 * $scale), [Math]::Max(240, $form.ClientSize.Width - 64)), 0)
        $body.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 16)
        $buttons = New-Object Windows.Forms.FlowLayoutPanel
        $buttons.AutoSize = $true
        $cancel = & $mkSecondary 'CancelStop' '取消' '取消強制停止' $colText
        $stop = & $mkSecondary 'ConfirmStop' '強制停止 PZ' '強制停止所有本機 PZ 程序' $colDanger
        $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $stop.DialogResult = [Windows.Forms.DialogResult]::Yes
        $buttons.Controls.Add($cancel)
        $buttons.Controls.Add($stop)
        $stack.Controls.Add($body)
        $stack.Controls.Add($buttons)
        $confirm.Controls.Add($stack)
        $confirm.AcceptButton = $confirm.CancelButton = $cancel
        if (-not [Windows.Forms.SystemInformation]::HighContrast) { [void][PZLauncherWindowTheme]::DarkTitlebar($confirm.Handle) }
        try { $answer = $confirm.ShowDialog($form) }
        finally { $confirm.Dispose() }
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { & $startJob 'stop' '強制停止所有 PZ 進程' $false }
    })

    $btnLogs.add_Click({
        if (-not (Test-Path -LiteralPath $ZomboidDir)) {
            & $setStatus "log 目錄還不存在：$ZomboidDir（跑過一次遊戲後才會建立）。" $colDanger
            return
        }
        foreach ($f in @('console.txt', 'server-console.txt')) {
            $p = Join-Path $ZomboidDir $f
            if (Test-Path -LiteralPath $p) {
                & $appendLog ("[log] $p  ($([math]::Round((Get-Item -LiteralPath $p).Length / 1KB)) KB)")
            } else {
                & $appendLog "[log] $p  (不存在)"
            }
        }
        try { [void][System.Diagnostics.Process]::Start('explorer.exe', (ConvertTo-PZArgToken $ZomboidDir)) }
        catch { & $setStatus "無法開啟檔案總管：$($_.Exception.Message)。請手動開啟 $ZomboidDir。" $colDanger }
    })

    $btnDetails.add_Click({
        if ($txtLog.Visible) {
            $txtLog.Visible = $false
            $btnDetails.Text = $btnDetails.AccessibleName = '詳細紀錄'
        } else { & $showLog }
    })

    $form.add_FormClosing({
        param($sender, $e)
        if ($state.Process) {
            $e.Cancel = $true
            & $setStatus '工作仍在執行，請等待結果後再關閉視窗。' $colSub
        } elseif (-not (& $saveChoices)) {
            [void][Windows.Forms.MessageBox]::Show('上次選項未能保存。請確認設定資料夾可寫入後重試；本視窗仍會關閉。', '選項未保存')
        }
    })

    # 真正顯示後才輸出；供外部（hub readiness / 自動化驗收）等待視窗就緒。
    $form.add_Shown({
        & $applyLayout
        Write-Host 'PZ_LAUNCHER_UI_READY'
        [Console]::Out.Flush()
    })

    $form.AcceptButton = $btnLaunch
    $tabOrder = @($cmbServer, $flowMode, $flowTarget, $flowClients, $flowOptions, $btnLaunch, $btnSync, $btnLogs)
    if ($btnCNTrans) { $tabOrder += $btnCNTrans }
    $tabOrder += @($btnStop, $btnDetails, $txtLog)
    for ($i = 0; $i -lt $tabOrder.Count; $i++) { $tabOrder[$i].TabIndex = $i }

    try {
        [void]$form.ShowDialog()
    } finally {
        $timer.Stop()
        $timer.Dispose()
        if ($state.Process) { $state.Process.Dispose(); $state.Process = $null }
        $tip.Dispose()
        $form.Dispose()
        foreach ($f in @($fontBody, $fontBodyBold, $fontTitle, $fontSmall, $fontPrimary, $fontMono)) { $f.Dispose() }
        $installed.Dispose()
    }
}
