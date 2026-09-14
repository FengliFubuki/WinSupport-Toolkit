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

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$UnexpectedPart,
        [string]$Name
    )
    $script:TestCount++
    if (-not $Text -or -not $Text.Contains($UnexpectedPart)) {
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
        return
    }
    $script:TestFailures++
    Write-Host ('[FAIL] ' + $Name + '，不应包含：' + $UnexpectedPart) -ForegroundColor Red
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
        [string[]]$DnsServers = @('223.5.5.5'),
        [bool]$IsVirtual = $false,
        [string]$MediaType = '802.3'
    )
    return [pscustomobject]@{
        Name        = $Name
        Description = $Name
        Status      = $Status
        Enabled     = $Enabled
        Connected   = $Connected
        MacAddress  = '00-11-22-33-44-55'
        IPAddresses = @($IPAddresses)
        SubnetMasks = @('255.255.255.0')
        Gateways    = @($Gateways)
        DnsServers  = @($DnsServers)
        DhcpEnabled = $true
        IsVirtual   = $IsVirtual
        MediaType   = $MediaType
        PhysicalMediaType = ''
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
        [bool]$HttpsOk = $true,
        [string]$HttpsMode = 'Direct',
        [bool]$ProxyEnabled = $false,
        [bool]$WinHttpProxyEnabled = $false,
        [bool]$VpnDetected = $false
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
        Success        = $HttpsOk
        Target         = if ($HttpsOk) { 'www.microsoft.com' } else { '' }
        Detail         = if ($HttpsOk) { 'HTTPS 访问成功' } else { 'HTTPS 访问失败' }
        Mode           = if ($HttpsOk) { $HttpsMode } else { 'None' }
        DirectSuccess  = ($HttpsOk -and $HttpsMode -eq 'Direct')
        ProxyAttempted = ($ProxyEnabled -or $WinHttpProxyEnabled -or $VpnDetected)
        ProxySuccess   = ($HttpsOk -and $HttpsMode -eq 'SystemProxy')
    }
    $anyProxy = ($ProxyEnabled -or $WinHttpProxyEnabled -or $VpnDetected)
    $proxySummary = '未启用代理'
    if ($anyProxy) {
        $parts = @()
        if ($ProxyEnabled) { $parts += '系统代理：127.0.0.1:7890' }
        if ($WinHttpProxyEnabled) { $parts += 'WinHTTP：127.0.0.1:7890' }
        if ($VpnDetected) { $parts += 'VPN/TUN：Test Tunnel' }
        $proxySummary = ($parts -join '；')
    }
    $proxy = [pscustomobject]@{
        Enabled = $ProxyEnabled
        Server  = if ($ProxyEnabled) { '127.0.0.1:7890' } else { '' }
        Bypass  = ''
        Summary = $proxySummary
        WinHttpEnabled = $WinHttpProxyEnabled
        WinHttpServer = if ($WinHttpProxyEnabled) { '127.0.0.1:7890' } else { '' }
        WinHttpSummary = if ($WinHttpProxyEnabled) { 'WinHTTP 代理：127.0.0.1:7890' } else { '未检测到 WinHTTP 代理' }
        VpnOrTunnelDetected = $VpnDetected
        VpnAdapterNames = if ($VpnDetected) { @('Test Tunnel') } else { @() }
        AnyProxy = $anyProxy
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
Assert-Equal '网络' (Get-SupportUiCategory $normalResults[0]) 'UI 聚合：网络分类正确'
Assert-Equal '正常' (Get-SupportUiItemStatus $normalResults[0]) 'UI 聚合：PASS 映射为正常'
$normalSession = New-SupportDiagnosticSession $normalResults
Assert-Equal '正常' $normalSession.CategoryStatuses['网络'] 'UI 聚合：网络会话状态正确'
Assert-Equal '未检测' $normalSession.CategoryStatuses['系统'] 'UI 聚合：无结果分类为未检测'
$allCategoryResults = @(
    New-SupportDiagnosticResult '电脑' 'Windows 系统' 'PASS' 'Windows 正常' '' ''
    New-SupportDiagnosticResult '电脑' 'CPU' 'PASS' 'CPU 正常' '' ''
    New-SupportDiagnosticResult '系统' '关键服务' 'PASS' '服务正常' '' ''
    New-SupportDiagnosticResult '磁盘' 'C盘空间' 'PASS' '磁盘正常' '' ''
    New-SupportDiagnosticResult '网络' '网络适配器' 'PASS' '网络正常' '' ''
    New-SupportDiagnosticResult '打印机' '打印机' 'PASS' '未检测到打印机' '' ''
)
$allNormalSession = New-SupportDiagnosticSession $allCategoryResults
Assert-Equal '正常' $allNormalSession.OverallStatus 'UI 聚合：完整正常结果总体为正常'
$noPrinterResult = New-SupportDiagnosticResult '打印机' '打印机' 'PASS' '未检测到打印机' '' ''
$proxyAttentionResult = New-SupportDiagnosticResult '网络' '代理设置' 'INFO' '系统代理：已启用' '' ''
Assert-Equal '正常' (Get-SupportUiItemStatus $noPrinterResult) 'UI 聚合：未接入打印机仍属正常'
Assert-Equal '注意' (Get-SupportUiItemStatus $proxyAttentionResult) 'UI 聚合：代理配置映射为注意'
$tunnelAdapter = New-TestAdapter -Name 'Test Tunnel' -MediaType 'Tunnel' -IsVirtual $true
Assert-Equal $true (Test-SupportVpnOrTunnelAdapter $tunnelAdapter) 'VPN/TUN：按接口类型识别'

$proxyNormalEvidence = New-TestEvidence $normalAdapter -HttpsMode 'SystemProxy' -ProxyEnabled $true
$proxyNormalResults = @(ConvertTo-SupportNetworkDiagnosticResults $proxyNormalEvidence)
$proxyNormalSummary = Get-SupportNetworkDiagnosticSummary $proxyNormalResults
Assert-Equal 'PASS' (Get-TestStatus $proxyNormalResults '网络适配器') '系统代理正常：网卡仍为 PASS'
Assert-Equal 'PASS' (Get-TestStatus $proxyNormalResults 'HTTPS 访问') '系统代理正常：HTTPS 通过'
Assert-Contains $proxyNormalSummary.PrimaryDiagnosis '本地网络适配器工作正常' '系统代理正常：结论不归因网卡'
Assert-Contains $proxyNormalSummary.PrimaryDiagnosis '当前 HTTPS 网络访问正常' '系统代理正常：明确 HTTPS 正常'
Assert-Equal $true $proxyNormalSummary.IsHealthy '系统代理正常：诊断汇总无故障'

$proxyUnavailableEvidence = New-TestEvidence $normalAdapter -PublicOk $false -DnsOk $false -HttpsOk $false -ProxyEnabled $true
$proxyUnavailableResults = @(ConvertTo-SupportNetworkDiagnosticResults $proxyUnavailableEvidence)
$proxyUnavailableSummary = Get-SupportNetworkDiagnosticSummary $proxyUnavailableResults
Assert-Equal 'PASS' (Get-TestStatus $proxyUnavailableResults '网络适配器') '代理不可用：网卡仍为 PASS'
Assert-Contains $proxyUnavailableSummary.PrimaryDiagnosis '代理服务不可用' '代理不可用：结论指向代理路径'
Assert-NotContains $proxyUnavailableSummary.PrimaryDiagnosis '网络适配器可能未正常工作' '代理不可用：不误判网卡故障'

$noAdapterEvidence = New-TestEvidence $null -Gateway '' -GatewayPingOk $false -PublicOk $false -DnsOk $false -HttpsOk $false
$noAdapterResults = @(ConvertTo-SupportNetworkDiagnosticResults $noAdapterEvidence)
$noAdapterSummary = Get-SupportNetworkDiagnosticSummary $noAdapterResults
Assert-Equal 'FAIL' (Get-TestStatus $noAdapterResults '网络适配器') '无网卡：判定失败'
Assert-Contains $noAdapterSummary.PrimaryDiagnosis '网络适配器' '无网卡：结论命中情况 A'

$disabledAdapter = New-TestAdapter -Status '已禁用' -Enabled $false -Connected $false
$disabledEvidence = New-TestEvidence $disabledAdapter -Gateway '' -GatewayPingOk $false -PublicOk $false -DnsOk $false -HttpsOk $false
$disabledResults = @(ConvertTo-SupportNetworkDiagnosticResults $disabledEvidence)
$disabledSummary = Get-SupportNetworkDiagnosticSummary $disabledResults
Assert-Equal 'FAIL' (Get-TestStatus $disabledResults '网络适配器') '禁用网卡：判定失败'
Assert-Contains $disabledSummary.PrimaryDiagnosis '网络适配器' '禁用网卡：结论指向本地适配器'

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
Assert-Equal 'FAIL' (Get-TestStatus $gatewayFailResults '公网连通性') '网关失败：公网判定失败'
Assert-Contains $gatewayFailSummary.PrimaryDiagnosis '公网连通性和 DNS 解析均失败' '网关失败：结论命中情况 C'
Assert-Equal 'PASS' (Get-TestStatus $gatewayFailResults '网络适配器') '网关失败：网卡仍为 PASS'

$dnsFailEvidence = New-TestEvidence $normalAdapter -DnsOk $false -HttpsOk $false
$dnsFailResults = @(ConvertTo-SupportNetworkDiagnosticResults $dnsFailEvidence)
$dnsFailSummary = Get-SupportNetworkDiagnosticSummary $dnsFailResults
Assert-Equal 'FAIL' (Get-TestStatus $dnsFailResults 'DNS 解析') 'DNS 异常：判定失败'
Assert-Contains $dnsFailSummary.PrimaryDiagnosis 'DNS 解析异常' 'DNS 异常：结论命中情况 D'
Assert-Equal 'PASS' (Get-TestStatus $dnsFailResults '网络适配器') 'DNS 异常：网卡仍为 PASS'

$httpsFailEvidence = New-TestEvidence $normalAdapter -HttpsOk $false
$httpsFailResults = @(ConvertTo-SupportNetworkDiagnosticResults $httpsFailEvidence)
$httpsFailSummary = Get-SupportNetworkDiagnosticSummary $httpsFailResults
Assert-Equal 'FAIL' (Get-TestStatus $httpsFailResults 'HTTPS 访问') 'HTTPS 异常：判定失败'
Assert-Contains $httpsFailSummary.PrimaryDiagnosis 'HTTPS 应用层访问失败' 'HTTPS 异常：结论命中情况 E'
Assert-Equal 'PASS' (Get-TestStatus $httpsFailResults '网络适配器') 'HTTPS 异常：网卡仍为 PASS'

$publicBlockedEvidence = New-TestEvidence $normalAdapter -PublicOk $false -DnsOk $true -HttpsOk $true -HttpsMode 'Direct'
$publicBlockedResults = @(ConvertTo-SupportNetworkDiagnosticResults $publicBlockedEvidence)
$publicBlockedSummary = Get-SupportNetworkDiagnosticSummary $publicBlockedResults
Assert-Equal 'PASS' (Get-TestStatus $publicBlockedResults '网络适配器') '公网 Ping 被阻断：网卡为 PASS'
Assert-Equal 'INFO' (Get-TestStatus $publicBlockedResults '公网连通性') '公网 Ping 被阻断：公网直连标记 INFO'
Assert-Contains $publicBlockedSummary.PrimaryDiagnosis '不能据此判定网络故障' '公网 Ping 被阻断：结论不判故障'
Assert-Equal $true $publicBlockedSummary.IsHealthy '公网 Ping 被阻断：HTTPS 正常时整体健康'

$proxyPublicBlockedEvidence = New-TestEvidence $normalAdapter -PublicOk $false -DnsOk $false -HttpsOk $true -HttpsMode 'SystemProxy' -ProxyEnabled $true
$proxyPublicBlockedResults = @(ConvertTo-SupportNetworkDiagnosticResults $proxyPublicBlockedEvidence)
$proxyPublicBlockedSummary = Get-SupportNetworkDiagnosticSummary $proxyPublicBlockedResults
Assert-Equal 'PASS' (Get-TestStatus $proxyPublicBlockedResults '网络适配器') '代理 HTTPS 正常：网卡为 PASS'
Assert-Equal 'INFO' (Get-TestStatus $proxyPublicBlockedResults '公网连通性') '代理 HTTPS 正常：公网直连标记 INFO'
Assert-Equal 'INFO' (Get-TestStatus $proxyPublicBlockedResults 'DNS 解析') '代理 HTTPS 正常：DNS 直连标记 INFO'
Assert-Equal 'PASS' (Get-TestStatus $proxyPublicBlockedResults 'HTTPS 访问') '代理 HTTPS 正常：HTTPS 通过'
Assert-Contains $proxyPublicBlockedSummary.PrimaryDiagnosis '本地网络适配器工作正常' '代理 HTTPS 正常：结论确认网卡正常'
Assert-Contains $proxyPublicBlockedSummary.PrimaryDiagnosis '当前 HTTPS 网络访问正常' '代理 HTTPS 正常：结论确认访问正常'
Assert-Equal $true $proxyPublicBlockedSummary.IsHealthy '代理 HTTPS 正常：整体判定健康'

$winHttpEvidence = New-TestEvidence $normalAdapter -PublicOk $false -DnsOk $false -HttpsOk $true -HttpsMode 'SystemProxy' -WinHttpProxyEnabled $true
$winHttpResults = @(ConvertTo-SupportNetworkDiagnosticResults $winHttpEvidence)
$winHttpSummary = Get-SupportNetworkDiagnosticSummary $winHttpResults
Assert-Equal 'PASS' (Get-TestStatus $winHttpResults '网络适配器') 'WinHTTP 代理：网卡仍为 PASS'
Assert-Contains $winHttpSummary.PrimaryDiagnosis '代理配置' 'WinHTTP 代理：纳入结论判断'

$vpnEvidence = New-TestEvidence $normalAdapter -PublicOk $false -DnsOk $false -HttpsOk $true -HttpsMode 'SystemProxy' -VpnDetected $true
$vpnResults = @(ConvertTo-SupportNetworkDiagnosticResults $vpnEvidence)
$vpnSummary = Get-SupportNetworkDiagnosticSummary $vpnResults
Assert-Equal 'PASS' (Get-TestStatus $vpnResults '网络适配器') 'VPN/TUN：网卡仍为 PASS'
Assert-Contains $vpnSummary.PrimaryDiagnosis '代理配置' 'VPN/TUN：纳入结论判断'

$gatewayIcMpBlockedEvidence = New-TestEvidence $normalAdapter -GatewayPingOk $false
$gatewayIcMpBlockedResults = @(ConvertTo-SupportNetworkDiagnosticResults $gatewayIcMpBlockedEvidence)
$gatewayIcMpBlockedSummary = Get-SupportNetworkDiagnosticSummary $gatewayIcMpBlockedResults
Assert-Contains $gatewayIcMpBlockedSummary.PrimaryDiagnosis '网关未响应 Ping' '网关屏蔽 ICMP：公网可达时单独说明'

$envPass = @(
    [pscustomobject]@{ Name = '百度'; Success = $true }
    [pscustomobject]@{ Name = '腾讯'; Success = $true }
    [pscustomobject]@{ Name = '阿里云'; Success = $false }
)
Assert-Equal '正常' (Get-SupportNetworkEnvironmentStatus $envPass) '网络环境：多数大陆目标成功为正常'
$envPartial = @(
    [pscustomobject]@{ Name = 'Google'; Success = $true }
    [pscustomobject]@{ Name = 'Cloudflare'; Success = $false }
    [pscustomobject]@{ Name = 'GitHub'; Success = $false }
)
Assert-Equal '部分可用' (Get-SupportNetworkEnvironmentStatus $envPartial) '网络环境：少数海外目标成功为部分可用'
Assert-Equal '异常' (Get-SupportNetworkEnvironmentStatus @([pscustomobject]@{ Success = $false })) '网络环境：全部目标失败为异常'
$environmentConclusion = [pscustomobject]@{
    LocalNetworkHealthy = $true
    Proxy = [pscustomobject]@{ AnyProxy = $true }
    Public = [pscustomobject]@{ Success = $true; Country = '日本'; Region = ''; City = '东京' }
    MainlandStatus = '正常'; OverseasStatus = '部分可用'; GoogleStatus = '无法访问'
}
Assert-Contains (Get-SupportNetworkEnvironmentConclusion $environmentConclusion) '公网出口位于日本 / 东京' '网络环境：结论使用公网出口位置'
Assert-Contains (Get-SupportNetworkEnvironmentConclusion $environmentConclusion) '海外网络部分可用' '网络环境：结论保留分组状态'
$printerRepairScripts = @(Get-SupportPrinterRepairScripts)
Assert-Equal 2 $printerRepairScripts.Count '打印机修复：集成两个修复程序'
Assert-Contains ($printerRepairScripts[0].RelativePath) 'repair-printer-components.bat' '打印机修复：深度修复脚本路径'
Assert-Contains ($printerRepairScripts[1].RelativePath) 'repair-win32spl-rpc.bat' '打印机修复：win32spl 修复脚本路径'
Assert-Equal 'DDR4' (Convert-SupportMemoryTypeText 26) '电脑配置：识别 DDR4'
Assert-Equal 'DDR5' (Convert-SupportMemoryTypeText 34) '电脑配置：识别 DDR5'
$wingetFixture = [pscustomobject]@{ ExitCode = 0; Output = @(
    'Name                         Id                           Version      Source'
    '---------------------------  ---------------------------  -----------  --------'
    'Google Chrome               Google.Chrome                140.0        winget'
    'Mozilla Firefox             Mozilla.Firefox              142.0        winget'
) }
$wingetRows = @(Get-SupportWingetRows $wingetFixture)
Assert-Equal 2 $wingetRows.Count '软件 UI：解析 winget 表格为对象'
Assert-Equal 'Google.Chrome' $wingetRows[0].Id '软件 UI：解析 Package ID'
Assert-Equal 'Google Chrome' $wingetRows[0].Name '软件 UI：保留带空格的软件名'
Assert-Contains (Format-SupportSoftwareCell 'Google Chrome' 8) '...' '软件 UI：长文本截断'

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
