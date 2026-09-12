$ErrorActionPreference = 'Stop'

$script:TestFailures = 0
$script:TestCount = 0

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Name
    )
    $script:TestCount++
    if ($Expected -eq $Actual) {
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
        return
    }
    $script:TestFailures++
    Write-Host ('[FAIL] ' + $Name + '，期望：' + $Expected + '，实际：' + $Actual) -ForegroundColor Red
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$ExpectedPart,
        [string]$Name
    )
    $script:TestCount++
    if ($Text -and $Text.Contains($ExpectedPart)) {
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
        return
    }
    $script:TestFailures++
    Write-Host ('[FAIL] ' + $Name + '，未找到：' + $ExpectedPart) -ForegroundColor Red
}

function Get-TestStatus {
    param($Results, [string]$Name)
    $item = $Results | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($item) { return $item.Status }
    return 'MISSING'
}

function New-TestAdapter {
    param(
        [string]$Name = 'Ethernet',
        [string]$Status = '已连接',
        [bool]$Enabled = $true,
        [bool]$Connected = $true,
        [string[]]$IPAddresses = @('192.168.1.10'),
        [string[]]$Gateways = @('192.168.1.1'),
        [string[]]$DnsServers = @('223.5.5.5')
    )
    return [pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Enabled     = $Enabled
        Connected   = $Connected
        MacAddress  = '00-11-22-33-44-55'
        IPAddresses = @($IPAddresses)
        SubnetMasks = @('255.255.255.0')
        Gateways    = @($Gateways)
        DnsServers  = @($DnsServers)
        DhcpEnabled = $true
    }
}

function New-TestEvidence {
    param(
        $Adapter,
        [bool]$TcpIpOk = $true,
        [string]$Gateway = '192.168.1.1',
        [bool]$GatewayPingOk = $true,
        [bool]$PublicOk = $true,
        [bool]$DnsOk = $true,
        [bool]$HttpsOk = $true
    )
    $public = [pscustomobject]@{
        Success = $PublicOk
        Target  = if ($PublicOk) { '223.5.5.5' } else { '' }
        Method  = if ($PublicOk) { 'ICMP' } else { '' }
        Detail  = if ($PublicOk) { '公网可达' } else { '公网不可达' }
    }
    $dns = [pscustomobject]@{
        Success = $DnsOk
        Details = @()
        Summary = if ($DnsOk) { 'www.microsoft.com -> 20.0.0.1' } else { '所有测试域名均无法解析' }
    }
    $https = [pscustomobject]@{
        Success = $HttpsOk
        Target  = if ($HttpsOk) { 'www.microsoft.com' } else { '' }
        Detail  = if ($HttpsOk) { 'TLS 握手成功' } else { 'TLS 握手失败' }
    }
    $proxy = [pscustomobject]@{
        Enabled = $false
        Server  = ''
        Bypass  = ''
        Summary = '未启用代理'
    }
    $adapters = @()
    if ($Adapter) { $adapters = @($Adapter) }
    return [pscustomobject]@{
        Adapters           = $adapters
        SelectedAdapter    = $Adapter
        TcpIpOk            = $TcpIpOk
        Gateway            = $Gateway
        GatewayPingOk      = $GatewayPingOk
        PublicConnectivity = $public
        Dns                = $dns
        Https              = $https
        Proxy              = $proxy
    }
}

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'IT-Support-Toolkit.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw ('找不到主脚本：' + $scriptPath)
}
. $scriptPath

Write-Host '正在验证网络诊断规则...' -ForegroundColor Cyan

$normalAdapter = New-TestAdapter
$normalEvidence = New-TestEvidence $normalAdapter
$normalResults = @(ConvertTo-SupportNetworkDiagnosticResults $normalEvidence)
$normalSummary = Get-SupportNetworkDiagnosticSummary $normalResults
Assert-Equal 'PASS' (Get-TestStatus $normalResults '网络适配器') '正常网络：网卡通过'
Assert-Equal 'PASS' (Get-TestStatus $normalResults 'IP 配置') '正常网络：IP 通过'
Assert-Equal 'PASS' (Get-TestStatus $normalResults 'DNS 解析') '正常网络：DNS 通过'
Assert-Equal 'PASS' (Get-TestStatus $normalResults 'HTTPS 访问') '正常网络：HTTPS 通过'
Assert-Equal $true $normalSummary.IsHealthy '正常网络：诊断汇总无问题'

$noAdapterEvidence = New-TestEvidence $null -Gateway '' -GatewayPingOk $false -PublicOk $false -DnsOk $false -HttpsOk $false
$noAdapterResults = @(ConvertTo-SupportNetworkDiagnosticResults $noAdapterEvidence)
$noAdapterSummary = Get-SupportNetworkDiagnosticSummary $noAdapterResults
Assert-Equal 'FAIL' (Get-TestStatus $noAdapterResults '网络适配器') '无网卡：判定失败'
Assert-Contains $noAdapterSummary.PrimaryDiagnosis '网络适配器' '无网卡：结论命中情况 A'

$apipaAdapter = New-TestAdapter -IPAddresses @('169.254.10.20') -Gateways @() -DnsServers @()
$apipaEvidence = New-TestEvidence $apipaAdapter -Gateway '' -GatewayPingOk $false -PublicOk $false -DnsOk $false -HttpsOk $false
$apipaResults = @(ConvertTo-SupportNetworkDiagnosticResults $apipaEvidence)
$apipaSummary = Get-SupportNetworkDiagnosticSummary $apipaResults
Assert-Equal 'FAIL' (Get-TestStatus $apipaResults 'IP 配置') '无有效 IP：判定失败'
Assert-Contains $apipaSummary.PrimaryDiagnosis '没有获得有效 IPv4' '无 IP：结论命中情况 B'
$apipaAction = Get-SupportNetworkRecommendedAction $apipaResults
Assert-Equal 'RenewIp' $apipaAction.Code '无有效 IP：优先建议重新获取 IP'

$gatewayFailEvidence = New-TestEvidence $normalAdapter -GatewayPingOk $false -PublicOk $false -DnsOk $false -HttpsOk $false
$gatewayFailResults = @(ConvertTo-SupportNetworkDiagnosticResults $gatewayFailEvidence)
$gatewayFailSummary = Get-SupportNetworkDiagnosticSummary $gatewayFailResults
Assert-Equal 'WARNING' (Get-TestStatus $gatewayFailResults '网关连通性') '网关失败：判定警告'
Assert-Equal 'FAIL' (Get-TestStatus $gatewayFailResults 'Internet') '网关失败：公网判定失败'
Assert-Contains $gatewayFailSummary.PrimaryDiagnosis '无法访问公网' '网关失败：结论命中情况 C'

$dnsFailEvidence = New-TestEvidence $normalAdapter -DnsOk $false -HttpsOk $false
$dnsFailResults = @(ConvertTo-SupportNetworkDiagnosticResults $dnsFailEvidence)
$dnsFailSummary = Get-SupportNetworkDiagnosticSummary $dnsFailResults
Assert-Equal 'FAIL' (Get-TestStatus $dnsFailResults 'DNS 解析') 'DNS 异常：判定失败'
Assert-Contains $dnsFailSummary.PrimaryDiagnosis 'DNS 解析异常' 'DNS 异常：结论命中情况 D'

$httpsFailEvidence = New-TestEvidence $normalAdapter -HttpsOk $false
$httpsFailResults = @(ConvertTo-SupportNetworkDiagnosticResults $httpsFailEvidence)
$httpsFailSummary = Get-SupportNetworkDiagnosticSummary $httpsFailResults
Assert-Equal 'FAIL' (Get-TestStatus $httpsFailResults 'HTTPS 访问') 'HTTPS 异常：判定失败'
Assert-Contains $httpsFailSummary.PrimaryDiagnosis 'HTTPS 访问异常' 'HTTPS 异常：结论命中情况 E'

$gatewayIcMpBlockedEvidence = New-TestEvidence $normalAdapter -GatewayPingOk $false
$gatewayIcMpBlockedResults = @(ConvertTo-SupportNetworkDiagnosticResults $gatewayIcMpBlockedEvidence)
$gatewayIcMpBlockedSummary = Get-SupportNetworkDiagnosticSummary $gatewayIcMpBlockedResults
Assert-Contains $gatewayIcMpBlockedSummary.PrimaryDiagnosis '网关未响应 Ping' '网关屏蔽 ICMP：公网可达时单独说明'

Write-Host '正在验证磁盘和系统服务规则...' -ForegroundColor Cyan

function Get-SupportDiskInfo {
    return @([pscustomobject]@{
        DriveLetter     = 'C:'
        TotalText       = '100 GB'
        UsedText        = '96 GB'
        UsedPercentText = '96.0%'
        FreeText        = '4 GB'
        UsedPercent     = $script:MockDiskUsedPercent
    })
}

$script:MockDiskUsedPercent = 50.0
$diskPass = @(Get-SupportDiskDetectionChecks)
Assert-Equal 'PASS' $diskPass[0].Status 'C盘正常：通过'
$script:MockDiskUsedPercent = 91.0
$diskWarning = @(Get-SupportDiskDetectionChecks)
Assert-Equal 'WARNING' $diskWarning[0].Status 'C盘不足：警告'
$script:MockDiskUsedPercent = 96.0
$diskFail = @(Get-SupportDiskDetectionChecks)
Assert-Equal 'FAIL' $diskFail[0].Status 'C盘严重不足：失败'

$script:MockServices = @{}
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    if ($script:MockServices.ContainsKey($Name)) {
        return $script:MockServices[$Name]
    }
    return $null
}

$script:MockServices = @{
    BITS       = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
    wuauserv   = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
    cryptSvc   = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    msiserver  = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
}
$updatePass = @(Get-SupportWindowsUpdateChecks)
Assert-Equal 'PASS' $updatePass[0].Status 'Windows Update 正常启动配置：通过'
$script:MockServices.wuauserv.StartType = 'Disabled'
$updateFail = @(Get-SupportWindowsUpdateChecks)
Assert-Equal 'FAIL' $updateFail[0].Status 'Windows Update 服务禁用：失败'

function Get-SupportPrinters {
    return @()
}

$script:MockServices = @{
    EventLog          = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    Winmgmt           = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    Dnscache          = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    LanmanWorkstation = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    Spooler           = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
}
$servicePass = @(Get-SupportCriticalServiceChecks)
Assert-Equal 'PASS' $servicePass[0].Status '关键服务正常：通过'
$script:MockServices.Dnscache.Status = 'Stopped'
$serviceFail = @(Get-SupportCriticalServiceChecks)
Assert-Equal 'FAIL' $serviceFail[0].Status 'DNS Client 服务停止：失败'

Write-Host '正在验证 TXT / JSON 报告兼容性...' -ForegroundColor Cyan

$testReportDir = Join-Path ([System.IO.Path]::GetTempPath()) ('WinSupportToolkitTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testReportDir -Force | Out-Null
$originalReportDir = $script:ReportDir
$script:ReportDir = $testReportDir

$reportDetection = @(
    New-SupportDiagnosticResult '网络' 'DNS 解析' 'FAIL' '无法解析 www.microsoft.com' 'DNS 服务异常。' '刷新 DNS 后重新检测。' 'FlushDns'
)
$reportSnapshot = [pscustomobject]@{
    GeneratedAt = '2026-09-12 16:00:00'
    Computer = [pscustomobject]@{
        ComputerName = 'TEST-PC'
        CurrentUser = 'TEST\User'
        IsAdmin = $false
        Manufacturer = 'Test'
        Model = 'Test'
        SerialNumber = 'Test'
        Cpu = 'Test CPU'
        MemoryTotal = '16 GB'
        MemoryFree = '8 GB'
        Gpu = 'Test GPU'
        OsCaption = 'Windows 10 Pro'
        OsBuild = '19045.1'
        Bios = 'Test BIOS'
        Uptime = '1 天'
        IpAddress = '192.168.1.10'
        MacAddress = '00-11-22-33-44-55'
        Gateway = '192.168.1.1'
        DnsServer = '223.5.5.5'
    }
    Detection = $reportDetection
    Disk = @()
    Battery = [pscustomobject]@{
        HasBattery = $false
        ChargeText = ''
        PowerStatusText = ''
        HealthPercent = $null
        HealthPercentText = ''
    }
    Printers = @()
}

$txtPath = Export-SupportReportTxt 'diagnostic-test.txt' $reportSnapshot
$jsonPath = Export-SupportReportJson 'diagnostic-test.json' $reportSnapshot
$txtContent = Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8
$json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Contains $txtContent '[异常] DNS 解析' 'TXT：保留 V1.0 中文状态格式'
Assert-Contains $txtContent '===== V1.1 结构化诊断结果 =====' 'TXT：包含 V1.1 结构化诊断'
Assert-Equal 'FAIL' $json.Detection[0].Status 'JSON：保存结构化状态'
Assert-Equal '刷新 DNS 后重新检测。' $json.Detection[0].Recommendation 'JSON：保存处理建议'

$script:ReportDir = $originalReportDir
Remove-Item -LiteralPath $testReportDir -Recurse -Force

Write-Host ''
if ($script:TestFailures -eq 0) {
    Write-Host ('全部测试通过：' + $script:TestCount + ' 项') -ForegroundColor Green
    exit 0
}
Write-Host ('测试失败：' + $script:TestFailures + ' / ' + $script:TestCount) -ForegroundColor Red
exit 1
