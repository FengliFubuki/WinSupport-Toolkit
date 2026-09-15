#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $root 'IT-Support-Toolkit.ps1'
. $corePath

$script:TestCount = 0
function Assert-GuiTest {
    param([bool]$Condition, [string]$Name)
    $script:TestCount++
    if (-not $Condition) { throw "[FAIL] $Name" }
    Write-Host ("[PASS] $Name") -ForegroundColor Green
}

$script:ProgressCallCount = 0
function Show-SupportDiagnosisProgress { param($States); $script:ProgressCallCount++ }
function Get-SupportComputerDetectionChecks {
    return @(
        (New-SupportDiagnosticResult '电脑' 'CPU' 'PASS' 'CPU 正常' '' ''),
        (New-SupportDiagnosticResult '电脑' 'Windows 系统' 'PASS' 'Windows 正常' '' '')
    )
}
function Get-SupportBatteryDetectionChecks { return @(New-SupportDiagnosticResult '电脑' '电池' 'PASS' '电池正常' '' '') }
function Get-SupportWindowsUpdateChecks { return @(New-SupportDiagnosticResult '系统' 'Windows Update' 'PASS' '更新服务正常' '' '') }
function Get-SupportSystemIntegrityChecks { return @(New-SupportDiagnosticResult '系统' '系统完整性' 'PASS' '系统文件正常' '' '') }
function Get-SupportCriticalServiceChecks { return @(New-SupportDiagnosticResult '系统' '关键服务' 'PASS' '关键服务正常' '' '') }
function Get-SupportDiskDetectionChecks { return @(New-SupportDiagnosticResult '磁盘' 'C盘空间' 'PASS' '磁盘空间正常' '' '') }
function Get-SupportNetworkDiagnosis { return @(New-SupportDiagnosticResult '网络' '网络适配器' 'PASS' '网络正常' '' '') }
function Get-SupportPrinterDetectionChecks { return @(New-SupportDiagnosticResult '打印机' '打印机' 'PASS' '打印机正常' '' '') }

$session = Invoke-SupportFullDiagnosis -Quiet
Assert-GuiTest ($script:ProgressCallCount -eq 0) 'GUI 静默诊断不会调用控制台进度输出'
Assert-GuiTest ($null -ne $session) '全面诊断返回会话对象'
Assert-GuiTest ($session.OverallStatus -eq '正常') '全面诊断总体状态正确'
foreach ($category in @('设备','Windows','系统','磁盘','网络','打印机')) {
    Assert-GuiTest ($session.CategoryStatuses[$category] -eq '正常') ("分类状态正确：$category")
}

$toolActions = @(Get-SupportToolActionCatalog)
Assert-GuiTest ($toolActions.Count -ge 30) 'GUI 工具清单包含原有维护功能'
foreach ($actionId in @('NetworkCommonFix','PrinterOneKeyFix','SystemSfc','WindowsUpdateFix','TempCleanup','SoftwareUpdate','ComputerConfiguration')) {
    Assert-GuiTest (($toolActions.Id -contains $actionId)) ("GUI 工具清单保留：$actionId")
}
$script:ToolActionInvoked = $false
function Show-SupportComputerInfo { $script:ToolActionInvoked = $true }
Invoke-SupportToolAction -Id 'ComputerInfo'
Assert-GuiTest $script:ToolActionInvoked '工具动作分发会调用原有后端函数'

function Get-SupportComputerFacts {
    return [pscustomobject]@{
        ComputerName='TEST-PC'; CurrentUser='TEST\User'; IsAdmin=$false; Manufacturer='Test'; Model='VM'; SerialNumber='N/A'
        Cpu='Test CPU'; MemoryTotal='16 GB'; MemoryFree='8 GB'; Gpu='Test GPU'; OsCaption='Windows Test'; OsBuild='26000'
        Bios='Test BIOS'; Uptime='1 天'; IpAddress='192.0.2.1'; MacAddress='00-00-00-00-00-00'; Gateway='192.0.2.254'; DnsServer='192.0.2.53'
    }
}
function Get-SupportDiskInfo { return @([pscustomobject]@{ DriveLetter='C'; TotalText='100 GB'; UsedText='40 GB'; UsedPercentText='40%'; FreeText='60 GB' }) }
function Get-SupportBattery { return [pscustomobject]@{ HasBattery=$false; ChargeText=''; PowerStatusText=''; HealthPercent=$null; HealthPercentText='' } }
function Get-SupportPrinters { return @() }
function Get-SupportNetworkEnvironmentInfo { return $null }

$testReportDir = Join-Path ([IO.Path]::GetTempPath()) ('WinSupport-GuiTest-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testReportDir -Force | Out-Null
    $script:ReportDir = $testReportDir
    $snapshot = New-SupportReportSnapshot -DetectionResults $session.Results
    $txtPath = Export-SupportReportTxt 'gui-integration.txt' $snapshot
    $jsonPath = Export-SupportReportJson 'gui-integration.json' $snapshot
    Assert-GuiTest (Test-Path -LiteralPath $txtPath) 'TXT 报告导出成功'
    Assert-GuiTest (Test-Path -LiteralPath $jsonPath) 'JSON 报告导出成功'
    Assert-GuiTest ((Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8) -match 'V1.1 结构化诊断结果') 'TXT 报告保留结构化结果'
    $json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GuiTest (@($json.Detection).Count -eq @($session.Results).Count) 'JSON 报告包含完整诊断结果'
}
finally {
    if (Test-Path -LiteralPath $testReportDir) { Remove-Item -LiteralPath $testReportDir -Recurse -Force }
}

Write-Host ("GUI 集成测试完成，共 $script:TestCount 项。") -ForegroundColor Cyan

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    & $hostExe -Sta -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'gui\WinSupport-GUI.ps1') -SmokeTest
    if ($LASTEXITCODE -ne 0) { throw 'GUI 实际按钮与后台诊断冒烟测试失败。' }
}
