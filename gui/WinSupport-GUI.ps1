#requires -Version 5.1
<#
    WPF front-end for WinSupport Toolkit V1.3.
    The existing IT-Support-Toolkit.ps1 remains the source of truth for
    diagnostics, repair actions and report export.
#>

param(
    [switch]$ValidateOnly,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$guiRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$corePath = Join-Path (Split-Path -Parent $guiRoot) 'IT-Support-Toolkit.ps1'
$xamlPath = Join-Path $guiRoot 'MainWindow.xaml'

try {
    if (-not (Test-Path -LiteralPath $corePath)) { throw "找不到核心脚本：$corePath" }
    if (-not (Test-Path -LiteralPath $xamlPath)) { throw "找不到 XAML 文件：$xamlPath" }

    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase

    . $corePath

    $xamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $xmlReader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
    if (-not $window) { throw 'XAML 窗口加载结果为空。' }
}
catch {
    $fallbackError = $_
    Write-Host 'WPF GUI 初始化失败，将回退到控制台模式。' -ForegroundColor Yellow
    Write-Host $fallbackError.Exception.Message -ForegroundColor Gray
    if ($ValidateOnly -or $SmokeTest) { throw $fallbackError }
    if (Test-Path -LiteralPath $corePath) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $corePath -Console
    }
    exit 0
}

$script:GuiWindow = $window
$script:CorePath = $corePath
$script:GuiState = @{ Session = $null; CurrentCategory = ''; PendingPowerShell = $null; PendingAsync = $null; PendingKind = ''; PendingCategory = ''; LastError = '' }
$script:GuiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GuiTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Find-GuiControl {
    param([string]$Name)
    return $script:GuiWindow.FindName($Name)
}

function Set-GuiText {
    param([string]$Name, [string]$Text)
    $control = Find-GuiControl $Name
    if ($control) { $control.Text = if ($null -eq $Text) { '' } else { [string]$Text } }
}

function Show-GuiException {
    param($ErrorRecord)
    $message = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    try { Write-Log ('GUI 操作失败：' + $message) 'ERROR' } catch {}
    $script:GuiState.LastError = $message
    if ($SmokeTest) { return }
    [System.Windows.MessageBox]::Show($message, '操作失败', 'OK', 'Error') | Out-Null
}

function Get-GuiStatusBrush {
    param([string]$Status)
    $color = switch ($Status) {
        '正常' { '#2D8A63' }
        '注意' { '#B47716' }
        '问题' { '#C4475A' }
        default { '#77738D' }
    }
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
}

function Get-GuiCategoryIcon {
    param([string]$Category)
    switch ($Category) {
        '设备' { return '🖥️' }
        'Windows' { return '🪟' }
        '系统' { return '🛠️' }
        '磁盘' { return '💾' }
        '网络' { return '🌐' }
        '打印机' { return '🖨️' }
        default { return '•' }
    }
}

function Get-GuiStatusSummary {
    param([string]$Status)
    switch ($Status) {
        '正常' { return '运行正常，暂时不用处理' }
        '注意' { return '有项目需要留意' }
        '问题' { return '发现问题，建议查看详情' }
        default { return '尚未进行检测' }
    }
}

function Set-GuiAssistantStatus {
    param([string]$Status)
    $text = switch ($Status) {
        '正常' { '状态不错，设备运行正常！' }
        '注意' { '发现一些需要留意的项目。' }
        '问题' { '发现问题，我已经整理好排查方向。' }
        default { '准备好了，开始检查这台电脑吧 ✨' }
    }
    Set-GuiText 'AssistantStatusText' $text
}

function Set-GuiBusy {
    param([bool]$Busy, [string]$Message = '')
    $buttons = @('StartDiagnosisButton','ViewResultsButton','ExportOverviewButton','RunDiagnosisAgainButton','RefreshCategoryButton','ExportTxtButton','ExportJsonButton','ExportBothButton','CompatibilityButton','PlaceholderCompatibilityButton')
    foreach ($name in $buttons) {
        $button = Find-GuiControl $name
        if ($button) { $button.IsEnabled = -not $Busy }
    }
    if ($Busy) {
        Set-GuiText 'DiagnosisStatusText' $Message
        Set-GuiText 'PageSubtitle' $Message
    }
}

function Start-GuiAsyncOperation {
    param([string]$ScriptText, [string]$Kind, [string]$Category = '')
    if ($script:GuiState.PendingPowerShell) { return $false }
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($ScriptText)
        $script:GuiState.PendingPowerShell = $ps
        $script:GuiState.PendingAsync = $ps.BeginInvoke()
        $script:GuiState.PendingKind = $Kind
        $script:GuiState.PendingCategory = $Category
        Set-GuiBusy $true '正在执行，请稍候……'
        $script:GuiTimer.Start()
        return $true
    }
    catch {
        if ($ps) { $ps.Dispose() }
        Show-GuiException $_
        return $false
    }
}

function Complete-GuiAsyncOperation {
    if (-not $script:GuiState.PendingPowerShell -or -not $script:GuiState.PendingAsync.IsCompleted) { return }
    $ps = $script:GuiState.PendingPowerShell
    $kind = $script:GuiState.PendingKind
    $category = $script:GuiState.PendingCategory
    $result = $null
    try {
        $result = @($ps.EndInvoke($script:GuiState.PendingAsync))
        $backgroundErrors = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
        if ($kind -eq 'diagnosis') {
            $script:GuiState.Session = $result | Where-Object { $_.PSObject.Properties['OverallStatus'] } | Select-Object -Last 1
            if (-not $script:GuiState.Session) { throw $(if ($backgroundErrors.Count -gt 0) { $backgroundErrors -join [Environment]::NewLine } else { '全面诊断没有返回有效结果。' }) }
            $script:DiagnosticSession = $script:GuiState.Session
            if ($backgroundErrors.Count -gt 0) { try { Write-Log ('GUI 全面诊断警告：' + ($backgroundErrors -join ' | ')) 'WARN' } catch {} }
            Update-GuiOverview
            Show-GuiDiagnosis
        }
        elseif ($kind -eq 'category') {
            $script:GuiState.Session = $result | Where-Object { $_.PSObject.Properties['OverallStatus'] } | Select-Object -Last 1
            if (-not $script:GuiState.Session) { throw $(if ($backgroundErrors.Count -gt 0) { $backgroundErrors -join [Environment]::NewLine } else { '分类诊断没有返回有效结果。' }) }
            $script:DiagnosticSession = $script:GuiState.Session
            if ($backgroundErrors.Count -gt 0) { try { Write-Log ('GUI 分类诊断警告：' + ($backgroundErrors -join ' | ')) 'WARN' } catch {} }
            Show-GuiCategoryDetail $category
            Update-GuiOverview
        }
        elseif ($kind -eq 'export') {
            $paths = @($result | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties['Paths']) { $_.Paths } })
            if ($paths.Count -gt 0) {
                [System.Windows.MessageBox]::Show(('导出成功：' + [Environment]::NewLine + ($paths -join [Environment]::NewLine)), '报告已导出', 'OK', 'Information') | Out-Null
                Show-GuiReports
            }
            else { throw $(if ($backgroundErrors.Count -gt 0) { $backgroundErrors -join [Environment]::NewLine } else { '没有生成报告文件。' }) }
        }
    }
    catch {
        Show-GuiException $_
    }
    finally {
        $ps.Dispose()
        $script:GuiState.PendingPowerShell = $null
        $script:GuiState.PendingAsync = $null
        $script:GuiState.PendingKind = ''
        $script:GuiState.PendingCategory = ''
        $script:GuiTimer.Stop()
        Set-GuiBusy $false
    }
}

function Show-GuiPanel {
    param([string]$Panel, [string]$Title, [string]$Subtitle)
    foreach ($name in @('OverviewPanel','DiagnosisPanel','DetailPanel','ReportsPanel','PlaceholderPanel')) {
        $control = Find-GuiControl $name
        if ($control) { $control.Visibility = if ($name -eq $Panel) { 'Visible' } else { 'Collapsed' } }
    }
    Set-GuiText 'PageTitle' $Title
    Set-GuiText 'PageSubtitle' $Subtitle
}

function Update-GuiOverview {
    $facts = $null
    try { $facts = Get-SupportComputerFacts } catch {}
    if ($facts) {
        Set-GuiText 'ComputerNameText' $facts.ComputerName
        Set-GuiText 'ComputerMetaText' (($facts.OsCaption + '  ·  用户：' + $facts.CurrentUser + '  ·  运行时长：' + $facts.Uptime))
    }
    $session = $script:GuiState.Session
    $overall = if ($session) { [string]$session.OverallStatus } else { '未检测' }
    Set-GuiText 'OverallStatusText' $overall
    $statusControl = Find-GuiControl 'OverallStatusText'
    if ($statusControl) { $statusControl.Foreground = Get-GuiStatusBrush $overall }
    if ($session) { Set-GuiText 'CountsText' ('问题 ' + $session.ProblemCount + ' 项  ·  注意 ' + $session.AttentionCount + ' 项') }
    else { Set-GuiText 'CountsText' '问题 0 项  ·  注意 0 项' }
    Set-GuiAssistantStatus $overall

    $panel = Find-GuiControl 'StatusCardsPanel'
    $panel.Children.Clear()
    foreach ($category in @('设备','Windows','系统','磁盘','网络','打印机')) {
        $status = if ($session) { [string]$session.CategoryStatuses[$category] } else { '未检测' }
        $card = New-Object System.Windows.Controls.Button
        $card.Width = 205; $card.Height = 108; $card.Margin = '0,0,12,12'; $card.Padding = '14,12'; $card.Tag = $category
        $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
        $card.BorderThickness = '0'
        $stack = New-Object System.Windows.Controls.StackPanel
        $line = New-Object System.Windows.Controls.StackPanel; $line.Orientation = 'Horizontal'
        $icon = New-Object System.Windows.Controls.TextBlock; $icon.Text = (Get-GuiCategoryIcon $category); $icon.FontSize = 20; $icon.Margin = '0,0,8,0'
        $name = New-Object System.Windows.Controls.TextBlock; $name.Text = $category; $name.FontSize = 16; $name.FontWeight = 'SemiBold'; $name.VerticalAlignment = 'Center'
        [void]$line.Children.Add($icon); [void]$line.Children.Add($name); [void]$stack.Children.Add($line)
        $state = New-Object System.Windows.Controls.TextBlock; $state.Text = $status; $state.Foreground = Get-GuiStatusBrush $status; $state.FontWeight = 'SemiBold'; $state.Margin = '0,8,0,0'
        $summary = New-Object System.Windows.Controls.TextBlock; $summary.Text = Get-GuiStatusSummary $status; $summary.Foreground = '#77738D'; $summary.FontSize = 12
        [void]$stack.Children.Add($state); [void]$stack.Children.Add($summary); $card.Content = $stack
        $card.Add_Click({ param($sender, $eventArgs); Show-GuiCategoryDetail ([string]$sender.Tag) })
        [void]$panel.Children.Add($card)
    }
}

function Show-GuiOverview {
    Show-GuiPanel 'OverviewPanel' '总览' '欢迎回来，先看看这台电脑的状态吧。'
    Update-GuiOverview
}

function Show-GuiDiagnosis {
    Show-GuiPanel 'DiagnosisPanel' '全面诊断' '按六个分类检查电脑状态，完成后会自动更新总览。'
    $steps = Find-GuiControl 'DiagnosisStepsPanel'; $steps.Children.Clear()
    foreach ($category in @('设备','Windows','系统','磁盘','网络','打印机')) {
        $status = if ($script:GuiState.Session) { [string]$script:GuiState.Session.CategoryStatuses[$category] } else { '未检测' }
        $row = New-Object System.Windows.Controls.TextBlock; $row.FontSize = 14; $row.Margin = '0,4,0,4'; $row.Text = ((Get-GuiCategoryIcon $category) + '  ' + $category + '    ' + $status); $row.Foreground = Get-GuiStatusBrush $status
        [void]$steps.Children.Add($row)
    }
    $problems = Find-GuiControl 'ProblemsItems'; $problems.Items.Clear()
    $items = if ($script:GuiState.Session) { @($script:GuiState.Session.Results | Where-Object { $_.Status -in @('FAIL','WARNING') }) } else { @() }
    $border = Find-GuiControl 'ProblemsBorder'; $border.Visibility = if ($items.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    foreach ($item in $items) {
        $text = '[' + (Get-SupportUiItemStatus $item) + '] ' + $item.Name + '：' + $item.Result
        if ($item.Diagnosis) { $text += '；诊断：' + $item.Diagnosis }
        if ($item.Recommendation) { $text += '；建议：' + $item.Recommendation }
        $block = New-Object System.Windows.Controls.TextBlock; $block.Text = $text; $block.TextWrapping = 'Wrap'; $block.Margin = '0,4,0,4'; $block.Foreground = '#5E5267'
        [void]$problems.Items.Add($block)
    }
}

function Show-GuiCategoryDetail {
    param([string]$Category)
    $script:GuiState.CurrentCategory = $Category
    Show-GuiPanel 'DetailPanel' ($Category + '详情') '查看检测结果、诊断原因和处理建议。'
    Set-GuiText 'DetailHeading' ((Get-GuiCategoryIcon $Category) + ' ' + $Category + '详情')
    $results = if ($script:GuiState.Session) { @(Get-SupportSessionCategoryResults $Category) } else { @() }
    $status = Get-SupportUiCategoryStatus $results
    Set-GuiText 'DetailStatusText' ('状态：' + $status)
    $detailStatus = Find-GuiControl 'DetailStatusText'; if ($detailStatus) { $detailStatus.Foreground = Get-GuiStatusBrush $status }
    $itemsControl = Find-GuiControl 'DetailItems'; $itemsControl.Items.Clear()
    foreach ($item in $results) {
        $border = New-Object System.Windows.Controls.Border; $border.Background = '#F7F5FB'; $border.CornerRadius = '8'; $border.Padding = '12'; $border.Margin = '0,0,0,8'
        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock; $title.Text = ('[' + (Get-SupportUiItemStatus $item) + ']  ' + $item.Name); $title.FontWeight = 'SemiBold'; $title.Foreground = Get-GuiStatusBrush (Get-SupportUiItemStatus $item)
        [void]$stack.Children.Add($title)
        foreach ($pair in @(@('结果', $item.Result), @('诊断', $item.Diagnosis), @('建议', $item.Recommendation))) {
            if ($pair[1]) { $line = New-Object System.Windows.Controls.TextBlock; $line.Text = ($pair[0] + '：' + $pair[1]); $line.TextWrapping = 'Wrap'; $line.Margin = '0,5,0,0'; $line.Foreground = '#5E5267'; [void]$stack.Children.Add($line) }
        }
        $border.Child = $stack; [void]$itemsControl.Items.Add($border)
    }
    $compat = Find-GuiControl 'CompatibilityButton'; $compat.Visibility = if (Test-SupportCategoryHasRepair $Category) { 'Visible' } else { 'Collapsed' }
}

function Show-GuiReports {
    Show-GuiPanel 'ReportsPanel' '报告' '沿用现有 TXT / JSON 报告结构，文件保存在 reports 目录。'
    $session = $script:GuiState.Session
    if ($session) { Set-GuiText 'ReportSummaryText' ('最近诊断：' + $session.GeneratedAt.ToString('yyyy-MM-dd HH:mm') + '；总体状态：' + $session.OverallStatus + '；问题 ' + $session.ProblemCount + ' 项，注意 ' + $session.AttentionCount + ' 项。') }
    else { Set-GuiText 'ReportSummaryText' '尚未完成诊断，可先运行全面诊断。' }
    $list = Find-GuiControl 'HistoryReportsList'; $list.Items.Clear()
    if (Test-Path -LiteralPath $script:ReportDir) {
        foreach ($report in @(Get-ChildItem -LiteralPath $script:ReportDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            [void]$list.Items.Add(($report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $report.Name))
        }
    }
    if ($list.Items.Count -eq 0) { [void]$list.Items.Add('暂无历史报告') }
}

function Show-GuiPlaceholder {
    param([string]$Category)
    Show-GuiPanel 'PlaceholderPanel' $Category '当前页面保留清晰入口，复杂操作可在兼容模式中使用原有功能。'
    Set-GuiText 'PlaceholderTitle' ((Get-GuiCategoryIcon $Category) + ' ' + $Category)
}

function Start-GuiDiagnosis {
    $escaped = $script:CorePath.Replace("'", "''")
    $code = ". '$escaped'; Invoke-SupportFullDiagnosis -Quiet"
    Show-GuiDiagnosis
    Start-GuiAsyncOperation $code 'diagnosis' | Out-Null
}

function Start-GuiCategoryDiagnosis {
    param([string]$Category)
    $escaped = $script:CorePath.Replace("'", "''")
    $existingJson = if ($script:GuiState.Session) { @($script:GuiState.Session.Results) | ConvertTo-Json -Depth 8 -Compress } else { '[]' }
    $escapedResults = $existingJson.Replace("'", "''")
    $escapedCategory = $Category.Replace("'", "''")
    $code = ". '$escaped'; `$existing = @(ConvertFrom-Json '$escapedResults'); if (`$existing.Count -gt 0) { Set-SupportDiagnosticSession `$existing | Out-Null }; Invoke-SupportCategoryDiagnosis '$escapedCategory'"
    Start-GuiAsyncOperation $code 'category' $Category | Out-Null
}

function Invoke-GuiSmokeTest {
    $script:GuiState.LastError = ''
    $startButton = Find-GuiControl 'StartDiagnosisButton'
    $startButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    if (-not $script:GuiState.PendingPowerShell) { throw 'GUI 冒烟测试失败：开始全面诊断按钮没有启动后台任务。' }

    $deadline = (Get-Date).AddSeconds(150)
    while ($script:GuiState.PendingPowerShell -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        Complete-GuiAsyncOperation
    }
    if ($script:GuiState.PendingPowerShell) { throw 'GUI 冒烟测试失败：全面诊断在 150 秒内没有完成。' }
    if ($script:GuiState.LastError) { throw ('GUI 冒烟测试失败：' + $script:GuiState.LastError) }
    if (-not $script:GuiState.Session) { throw 'GUI 冒烟测试失败：全面诊断没有更新 GUI 会话。' }

    $networkButton = Find-GuiControl 'NavNetwork'
    $networkButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    if ((Find-GuiControl 'DetailPanel').Visibility -ne 'Visible') { throw 'GUI 冒烟测试失败：网络导航按钮没有打开详情页。' }
    if (@(Get-SupportSessionCategoryResults '网络').Count -eq 0) { throw 'GUI 冒烟测试失败：GUI 会话没有同步到分类详情。' }

    Write-Host '[PASS] GUI 按钮、后台全面诊断和分类详情链路通过' -ForegroundColor Green
}

function Start-GuiExport {
    param([ValidateSet('txt','json','both')][string]$Format)
    if (-not $script:GuiState.Session) { [System.Windows.MessageBox]::Show('请先完成全面诊断，再导出本次报告。', '提示', 'OK', 'Information') | Out-Null; return }
    $escaped = $script:CorePath.Replace("'", "''")
    $resultsJson = @($script:GuiState.Session.Results) | ConvertTo-Json -Depth 8 -Compress
    $escapedResults = $resultsJson.Replace("'", "''")
    $formatCode = switch ($Format) { 'txt' { '$paths += Export-SupportReportTxt (''ITSupportReport_'' + $stamp + ''.txt'') $snapshot' }; 'json' { '$paths += Export-SupportReportJson (''ITSupportReport_'' + $stamp + ''.json'') $snapshot' }; default { '$paths += Export-SupportReportTxt (''ITSupportReport_'' + $stamp + ''.txt'') $snapshot; $paths += Export-SupportReportJson (''ITSupportReport_'' + $stamp + ''.json'') $snapshot' } }
    $code = ". '$escaped'; if (-not (Test-Path -LiteralPath `$script:ReportDir)) { New-Item -ItemType Directory -Path `$script:ReportDir -Force | Out-Null }; `$results = ConvertFrom-Json '$escapedResults'; `$snapshot = New-SupportReportSnapshot -DetectionResults `$results; `$stamp = Get-SupportTimeStamp; `$paths = @(); $formatCode; [pscustomobject]@{ Paths = @(`$paths) }"
    Start-GuiAsyncOperation $code 'export' | Out-Null
}

function Open-GuiCompatibilityMode {
    param([string]$Category)
    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $exe) { $exe = 'powershell.exe' }
    Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$script:CorePath,'-Console') | Out-Null
}

function Add-GuiClickHandler {
    param(
        [System.Windows.Controls.Button]$Button,
        [scriptblock]$Action
    )
    if (-not $Button) { throw 'GUI 控件未找到，无法绑定按钮事件。' }
    $handlerScript = {
        param($sender, $eventArgs)
        try { & $Action $sender $eventArgs }
        catch { Show-GuiException $_ }
    }.GetNewClosure()
    $handler = [System.Windows.RoutedEventHandler]$handlerScript
    $Button.AddHandler([System.Windows.Controls.Button]::ClickEvent, $handler)
}

function Add-GuiEvents {
    foreach ($name in @('NavOverview','NavDiagnosis','NavReports','NavNetwork','NavPrinter','NavSystem','NavDisk','NavSoftware','NavDevice')) {
        $button = Find-GuiControl $name
        Add-GuiClickHandler $button {
            param($sender, $eventArgs)
            $tag = [string]$sender.Tag
            switch ($tag) {
                'overview' { Show-GuiOverview }
                'diagnosis' { Show-GuiDiagnosis }
                'reports' { Show-GuiReports }
                default { if ($tag -in @('网络','系统','磁盘','打印机','设备','Windows')) { Show-GuiCategoryDetail $tag } else { Show-GuiPlaceholder $tag } }
            }
        }
    }
    Add-GuiClickHandler (Find-GuiControl 'StartDiagnosisButton') { Start-GuiDiagnosis }
    Add-GuiClickHandler (Find-GuiControl 'RunDiagnosisAgainButton') { Start-GuiDiagnosis }
    Add-GuiClickHandler (Find-GuiControl 'ViewResultsButton') { if ($script:GuiState.Session) { Show-GuiDiagnosis } else { Start-GuiDiagnosis } }
    Add-GuiClickHandler (Find-GuiControl 'ExportOverviewButton') { Start-GuiExport 'both' }
    Add-GuiClickHandler (Find-GuiControl 'RefreshCategoryButton') { Start-GuiCategoryDiagnosis $script:GuiState.CurrentCategory }
    Add-GuiClickHandler (Find-GuiControl 'CompatibilityButton') { Open-GuiCompatibilityMode $script:GuiState.CurrentCategory }
    Add-GuiClickHandler (Find-GuiControl 'PlaceholderCompatibilityButton') { Open-GuiCompatibilityMode '' }
    Add-GuiClickHandler (Find-GuiControl 'ExportTxtButton') { Start-GuiExport 'txt' }
    Add-GuiClickHandler (Find-GuiControl 'ExportJsonButton') { Start-GuiExport 'json' }
    Add-GuiClickHandler (Find-GuiControl 'ExportBothButton') { Start-GuiExport 'both' }
    $script:GuiTimer.Add_Tick([System.EventHandler]{ Complete-GuiAsyncOperation })
}

try {
    [void](Test-SupportAdmin)
    $permission = Find-GuiControl 'PermissionText'
    if ($permission) { $permission.Text = if ($script:IsAdminUser) { '管理员' } else { '普通用户' }; $permission.Foreground = if ($script:IsAdminUser) { '#A9E6C7' } else { '#FFFFFF' } }
    Add-GuiEvents
    Show-GuiOverview
    if ($SmokeTest) {
        Invoke-GuiSmokeTest
    }
    elseif ($ValidateOnly) {
        foreach ($name in @('NavOverview','NavDiagnosis','NavReports','StartDiagnosisButton','ExportTxtButton','ExportJsonButton','ExportBothButton')) {
            if (-not (Find-GuiControl $name)) { throw "GUI 验证失败，找不到控件：$name" }
        }
        Write-Host '[PASS] GUI 初始化与事件绑定检查通过' -ForegroundColor Green
    }
    else { [void]$script:GuiWindow.ShowDialog() }
}
catch {
    if ($ValidateOnly -or $SmokeTest) { throw }
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'WinSupport GUI 错误', 'OK', 'Error') | Out-Null
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $corePath -Console
}
