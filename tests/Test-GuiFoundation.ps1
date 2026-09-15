#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$xamlPath = Join-Path $root 'gui\MainWindow.xaml'
$guiPath = Join-Path $root 'gui\WinSupport-GUI.ps1'
$corePath = Join-Path $root 'IT-Support-Toolkit.ps1'

foreach ($path in @($xamlPath, $guiPath, $corePath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "找不到 GUI 基础文件：$path" }
}

foreach ($scriptFile in @($guiPath, $corePath, (Join-Path $root 'tests\Test-GuiIntegration.ps1'))) {
    $bytes = [System.IO.File]::ReadAllBytes($scriptFile)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "PowerShell 脚本不是 UTF-8 BOM 编码：$scriptFile"
    }
}
Write-Host '[PASS] PowerShell 脚本 UTF-8 BOM 编码检查通过' -ForegroundColor Green

$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$null = [xml]$xaml
$gui = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
$parseTokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$parseTokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw ('GUI PowerShell 语法检查失败：' + ((@($parseErrors) | ForEach-Object { $_.Message }) -join '；'))
}
Write-Host '[PASS] GUI PowerShell 语法检查通过' -ForegroundColor Green

foreach ($name in @('OverviewPanel','DiagnosisPanel','DetailPanel','ReportsPanel','StartDiagnosisButton','ExportTxtButton','ExportJsonButton','ExportBothButton','ToolActionsPanel','ToolActionsTitle','ToolActionsHint')) {
    if ($xaml -notmatch ('x:Name="' + [regex]::Escape($name) + '"')) { throw "XAML 缺少控件：$name" }
}
foreach ($symbol in @('Invoke-SupportFullDiagnosis','New-SupportReportSnapshot','Export-SupportReportTxt','Export-SupportReportJson','Get-SupportToolActionCatalog','Start-GuiToolConsoleAction')) {
    if ($gui -notmatch [regex]::Escape($symbol)) { throw "GUI 未复用核心入口：$symbol" }
}
if ($gui -notmatch 'Invoke-SupportFullDiagnosis\s+-Quiet') { throw 'GUI 全面诊断没有启用静默模式' }
if ($gui -match '(?<!\$)\(\s*if\b') { throw 'GUI 包含会在运行时把 if 误当命令的参数表达式' }
if ($xaml -notmatch '发行商：FengliFubuki') { throw 'GUI 未显示 GitHub 发行商名称' }

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if (-not $window) { throw 'WPF XAML 加载失败' }
    Write-Host '[PASS] WPF XAML 可以加载' -ForegroundColor Green
}
else {
    Write-Host '[INFO] 当前非 Windows，跳过 WPF 运行时加载；XML 和静态入口检查已通过。' -ForegroundColor Yellow
}

Write-Host '[PASS] GUI 基础检查通过' -ForegroundColor Green
