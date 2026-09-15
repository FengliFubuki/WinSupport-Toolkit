#Requires -Version 5.1
<#
============================================================================
  Windows IT Support Toolkit V1.2
--------------------------------------------------------------------------
  用途：面向 IT Support / Desktop Support 的日常运维辅助工具
  运行要求：Windows 10 / Windows 11（需 Windows PowerShell 5.1+）
  运行方式：
    1. 双击 run.bat
    2. 或手动执行：
       powershell.exe -NoProfile -ExecutionPolicy Bypass -File IT-Support-Toolkit.ps1

  目录说明：
    reports\   导出的诊断报告
    logs\      基础运行日志
    config\    配置文件（常用软件列表）
============================================================================
#>

param(
    [switch]$SkipBanner,
    [switch]$Console
)

$ErrorActionPreference = 'Continue'

$script:ToolName    = 'Windows IT Support Toolkit'
$script:ToolVersion = '1.3.0'
$script:ScriptRoot  = $PSScriptRoot
if (-not $script:ScriptRoot) {
    try {
        $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    catch {}
}
$script:ReportDir   = Join-Path $script:ScriptRoot 'reports'
$script:LogDir      = Join-Path $script:ScriptRoot 'logs'
$script:LogFile     = Join-Path $script:LogDir 'it-support-toolkit.log'
$script:SoftwareConfigFile = Join-Path $script:ScriptRoot (Join-Path 'config' 'software.json')
$script:IsWindowsOs = $false
$script:IsAdminUser = $false
$script:HasWinget   = $false
$script:CommonSoftwareCache = $null
$script:DiagnosticSession = $null

# ===========================================================================
# 基础工具函数
# ===========================================================================

function Test-SupportWindows {
    try {
        $script:IsWindowsOs = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }
    catch {
        $script:IsWindowsOs = ($env:OS -eq 'Windows_NT')
    }
    return $script:IsWindowsOs
}

function Set-SupportConsoleEncoding {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
    }
    try {
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {}
    try {
        $OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {}
}

function Write-Banner {
    Clear-Host -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '|  WinSupport Toolkit  v1.2                       |' -ForegroundColor Cyan
    Write-Host '|  电脑急救站                                      |' -ForegroundColor DarkCyan
    Write-Host '+--------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-SectionTitle {
    param([string]$Text)
    Write-Host ''
    Write-Host ('========== ' + $Text + ' ==========') -ForegroundColor Cyan
    Write-Host ''
}

function Write-SubTitle {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Yellow
}

function Write-OkText {
    param([string]$Text)
    Write-Host ('[正常] ' + $Text) -ForegroundColor Green
}

function Write-WarnText {
    param([string]$Text)
    Write-Host ('[警告] ' + $Text) -ForegroundColor Yellow
}

function Write-ErrorText {
    param([string]$Text)
    Write-Host ('[异常] ' + $Text) -ForegroundColor Red
}

function Write-NoticeText {
    param([string]$Text)
    Write-Host ('[提示] ' + $Text) -ForegroundColor Gray
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = ('[{0}] [{1}] {2}' -f $stamp, $Level, $Message)
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {}
}

function Get-SupportTimeStamp {
    return (Get-Date -Format 'yyyyMMdd_HHmmss')
}

function Get-SupportCurrentUser {
    $user = $env:USERNAME
    $domain = $env:USERDOMAIN
    if ($user) {
        if ($domain -and $domain -ne '') {
            return ($domain + '\' + $user)
        }
        return $user
    }
    return '无法获取'
}

function Test-SupportAdmin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $script:IsAdminUser = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $script:IsAdminUser = $false
    }
    return $script:IsAdminUser
}

function Get-SupportConfirmation {
    param([string]$Prompt)
    while ($true) {
        $answer = Read-Host ($Prompt + ' [Y/N]')
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Host '请输入 Y 或 N。' -ForegroundColor Yellow
    }
}

function Read-MenuSelection {
    param([int]$MaxChoice)
    while ($true) {
        $answer = Read-Host '请输入选项数字 ✨'
        if ($answer -match '^\d+$') {
            $num = [int]$answer
            if ($num -ge 0 -and $num -le $MaxChoice) {
                return $num
            }
        }
        Write-Host '输入无效，请重新输入。' -ForegroundColor Yellow
    }
}

function Format-SupportByteSize {
    param([long]$Bytes)
    try {
        if ($Bytes -lt 0) { return '未知' }
        if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
        return ('{0} B' -f $Bytes)
    }
    catch {
        return '未知'
    }
}

function Format-SupportPercent {
    param([double]$Value)
    if ($Value -lt 0) { return '无法获取' }
    return ('{0:N1}%' -f $Value)
}

function Test-SupportPathExists {
    param([string]$Path)
    try {
        return (Test-Path -LiteralPath $Path)
    }
    catch {
        return $false
    }
}

function Confirm-SupportAdminOperation {
    param([string]$Description)
    if (Test-SupportAdmin) {
        return $true
    }
    Write-Host ''
    Write-WarnText ('当前操作需要管理员权限：' + $Description)
    Write-Host '当前操作需要管理员权限。' -ForegroundColor Yellow
    $go = Get-SupportConfirmation '是否以管理员身份重新运行？'
    if ($go) {
        try {
            $exe = 'powershell.exe'
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $exe = 'pwsh.exe'
            }
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
            Write-Host '正在请求管理员权限（UAC）...' -ForegroundColor Yellow
            Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -Wait -ErrorAction Stop
            exit 0
        }
        catch {
            Write-ErrorText '无法以管理员身份启动，可能已被取消或系统禁止。'
            Write-Log ('请求管理员权限失败: ' + $_.Exception.Message) 'ERROR'
            return $false
        }
    }
    else {
        Write-Host ''
        Write-NoticeText '操作已取消。'
        return $false
    }
}

function Invoke-SupportNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
    try {
        $output = @()
        if ($ArgumentList.Count -gt 0) {
            $output = @(& $FilePath @ArgumentList 2>&1)
        }
        else {
            $output = @(& $FilePath 2>&1)
        }
        foreach ($line in $output) {
            Write-Host ([string]$line)
        }
        # 原生命令的标准输出不能混入返回值，否则调用方拿到的不是纯退出码。
        return $LASTEXITCODE
    }
    catch {
        Write-Log ('命令执行失败: ' + $FilePath + ' ' + ($ArgumentList -join ' ') + ' | ' + $_.Exception.Message) 'ERROR'
        return -1
    }
}

function Write-PressAnyKeyToReturn {
    Write-Host ''
    Read-Host '按回车键返回...' | Out-Null
}

function New-SupportReportObject {
    param(
        [string]$Kind,
        [string]$Category,
        [string]$Check,
        [string]$Status,
        [string]$Message
    )
    return [pscustomobject]@{
        Kind     = $Kind
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
    }
}

function ConvertTo-SupportDiagnosticStatus {
    param([string]$Status)
    switch -Regex ($Status) {
        '^(?i:PASS|正常)$' { return 'PASS' }
        '^(?i:WARNING|警告)$' { return 'WARNING' }
        '^(?i:FAIL|异常)$' { return 'FAIL' }
        '^(?i:INFO|提示|信息)$' { return 'INFO' }
        default { return 'INFO' }
    }
}

function Get-SupportLegacyStatusText {
    param([string]$Status)
    switch (ConvertTo-SupportDiagnosticStatus $Status) {
        'PASS' { return '正常' }
        'WARNING' { return '警告' }
        'FAIL' { return '异常' }
        default { return '提示' }
    }
}

function Get-SupportStatusColor {
    param([string]$Status)
    switch (ConvertTo-SupportDiagnosticStatus $Status) {
        'PASS' { return 'Green' }
        'WARNING' { return 'Yellow' }
        'FAIL' { return 'Red' }
        default { return 'Gray' }
    }
}

function New-SupportDiagnosticResult {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Status,
        [string]$Result,
        [string]$Diagnosis = '',
        [string]$Recommendation = '',
        [string]$ActionCode = '',
        [string]$AccessMode = ''
    )
    $normalizedStatus = ConvertTo-SupportDiagnosticStatus $Status
    return [pscustomobject]@{
        Kind           = '诊断'
        Category       = $Category
        Check          = $Name
        Name           = $Name
        Status         = $normalizedStatus
        Message        = $Result
        Result         = $Result
        Diagnosis      = $Diagnosis
        Recommendation = $Recommendation
        ActionCode     = $ActionCode
        AccessMode     = $AccessMode
    }
}

function Convert-SupportReportObjectToDiagnostic {
    param($ReportObject)
    $status = ConvertTo-SupportDiagnosticStatus $ReportObject.Status
    $recommendation = ''
    if ($status -eq 'FAIL' -or $status -eq 'WARNING') {
        $recommendation = Get-SupportIssueSuggestion $ReportObject.Check
    }
    return New-SupportDiagnosticResult $ReportObject.Category $ReportObject.Check $status $ReportObject.Message '' $recommendation
}

# ===========================================================================
# 电脑信息
# ===========================================================================

function Get-SupportComputerFacts {
    $computerName = $env:COMPUTERNAME
    if (-not $computerName) {
        try { $computerName = [System.Environment]::MachineName } catch {}
    }
    if (-not $computerName) { $computerName = '无法获取' }
    $facts = [ordered]@{
        ComputerName    = $computerName
        CurrentUser     = Get-SupportCurrentUser
        IsAdmin         = $script:IsAdminUser
        Manufacturer    = '无法获取'
        Model           = '无法获取'
        SerialNumber    = '无法获取'
        Cpu             = '无法获取'
        CpuCoreCount    = '无法获取'
        MemoryTotal     = '无法获取'
        MemoryFree      = '无法获取'
        Gpu             = '无法获取'
        OsCaption       = '无法获取'
        OsVersion       = '无法获取'
        OsBuild         = '无法获取'
        Bios            = '无法获取'
        Uptime          = '无法获取'
        Disk            = '无法获取'
        IpAddress       = '无法获取'
        MacAddress      = '无法获取'
        Gateway         = '无法获取'
        DnsServer       = '无法获取'
        Battery         = '无法获取'
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cs) {
            $facts.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer } else { '无法获取' }
            $facts.Model        = if ($cs.Model) { $cs.Model } else { '无法获取' }
        }
    }
    catch {}

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bios) {
            $serial = $bios.SerialNumber
            if (-not $serial -or $serial -match '(?i)^(None|Default string|To be filled|0)$') {
                $facts.SerialNumber = '无法获取'
            }
            else {
                $facts.SerialNumber = $serial
            }
            if ($bios.SMBIOSBIOSVersion) {
                $facts.Bios = ($bios.Manufacturer + ' ' + $bios.SMBIOSBIOSVersion).Trim()
            }
        }
    }
    catch {}

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($os) {
            $facts.OsCaption = if ($os.Caption) { $os.Caption.Trim() } else { '无法获取' }
            $facts.OsVersion = if ($os.Version) { $os.Version } else { '无法获取' }
            if ($os.BuildNumber) {
                $buildText = $os.BuildNumber
                try {
                    $cur = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                    if ($cur -and $cur.UBR) {
                        $buildText += '.' + $cur.UBR
                    }
                }
                catch {}
                $facts.OsBuild = $buildText
            }
            if ($os.LastBootUpTime) {
                try {
                    $up = (Get-Date) - $os.LastBootUpTime
                    if ($up.TotalSeconds -lt 0) { $up = New-TimeSpan -Seconds 0 }
                    $days = [math]::Floor($up.TotalDays)
                    $hours = $up.Hours
                    $mins = $up.Minutes
                    $facts.Uptime = ('{0} 天 {1} 小时 {2} 分钟' -f $days, $hours, $mins)
                }
                catch {}
            }
        }
    }
    catch {}

    try {
        $displayVer = $null
        $cur = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cur -and $cur.DisplayVersion) {
            $displayVer = $cur.DisplayVersion
        }
        if ($displayVer) {
            $facts.OsCaption = $facts.OsCaption + ' (' + $displayVer + ')'
        }
    }
    catch {}

    $coreTotal = 0
    $threadTotal = 0
    $cpuNames = New-Object System.Collections.ArrayList
    try {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
        if ($cpus.Count -gt 0) {
            foreach ($cpu in $cpus) {
                if ($cpu.Name) {
                    if ($cpuNames -notcontains $cpu.Name) {
                        [void]$cpuNames.Add($cpu.Name)
                    }
                }
                if ($cpu.NumberOfCores) { $coreTotal += [int]$cpu.NumberOfCores }
                if ($cpu.NumberOfLogicalProcessors) { $threadTotal += [int]$cpu.NumberOfLogicalProcessors }
            }
            if ($cpuNames.Count -gt 0) {
                $facts.Cpu = ($cpuNames -join '; ').Trim()
            }
            if ($coreTotal -gt 0) {
                $facts.CpuCoreCount = ('{0} 核 / {1} 线程' -f $coreTotal, $threadTotal)
            }
        }
    }
    catch {}

    try {
        $memTotalBytes = 0
        $memFreeBytes = 0
        $cs2 = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cs2 -and $cs2.TotalPhysicalMemory) {
            $memTotalBytes = [long]$cs2.TotalPhysicalMemory
        }
        $os2 = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($os2 -and $os2.FreePhysicalMemory) {
            $memFreeBytes = [long]$os2.FreePhysicalMemory * 1KB
        }
        if ($memTotalBytes -gt 0) {
            $facts.MemoryTotal = Format-SupportByteSize $memTotalBytes
            if ($memFreeBytes -gt 0) {
                $facts.MemoryFree = Format-SupportByteSize $memFreeBytes
            }
        }
    }
    catch {}

    try {
        $gpuNames = New-Object System.Collections.ArrayList
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
        foreach ($gpu in $gpus) {
            if ($gpu.Name -and ($gpuNames -notcontains $gpu.Name)) {
                [void]$gpuNames.Add($gpu.Name)
            }
        }
        if ($gpuNames.Count -gt 0) {
            $facts.Gpu = ($gpuNames -join '; ').Trim()
        }
    }
    catch {}

    try {
        $netInfo = Get-SupportNetworkAdapterInfo
        if ($netInfo -and $netInfo.Count -gt 0) {
            $ipList = New-Object System.Collections.ArrayList
            $macList = New-Object System.Collections.ArrayList
            $gwList = New-Object System.Collections.ArrayList
            $dnsList = New-Object System.Collections.ArrayList
            foreach ($ad in $netInfo) {
                foreach ($ip in $ad.IPAddresses) {
                    if ($ip -and $ip -notmatch '^127\.' -and $ip -notmatch '^169\.254\.' -and $ip -notmatch '^::1$' -and $ip -notmatch '^fe80::') {
                        if ($ipList -notcontains $ip) { [void]$ipList.Add($ip) }
                    }
                }
                if ($ad.MacAddress -and ($macList -notcontains $ad.MacAddress)) {
                    [void]$macList.Add($ad.MacAddress)
                }
                foreach ($gw in $ad.Gateways) {
                    if ($gw -and ($gwList -notcontains $gw)) { [void]$gwList.Add($gw) }
                }
                foreach ($dns in $ad.DnsServers) {
                    if ($dns -and ($dnsList -notcontains $dns)) { [void]$dnsList.Add($dns) }
                }
            }
            if ($ipList.Count -gt 0) { $facts.IpAddress = ($ipList -join '; ') }
            if ($macList.Count -gt 0) { $facts.MacAddress = ($macList -join '; ') }
            if ($gwList.Count -gt 0) { $facts.Gateway = ($gwList -join '; ') }
            if ($dnsList.Count -gt 0) { $facts.DnsServer = ($dnsList -join '; ') }
        }
    }
    catch {}

    try {
        $disk = @(Get-SupportDiskInfo)
        $diskTexts = New-Object System.Collections.ArrayList
        foreach ($d in $disk) {
            [void]$diskTexts.Add(($d.DriveLetter + ' 剩余 ' + $d.FreeText + ' / ' + $d.TotalText + ' (' + $d.UsedPercentText + ')'))
        }
        if ($diskTexts.Count -gt 0) {
            $facts.Disk = ($diskTexts -join ' | ')
        }
    }
    catch {}

    try {
        $bat = Get-SupportBattery
        if ($bat.HasBattery) {
            $batTexts = New-Object System.Collections.ArrayList
            if ($bat.ChargePercent -ne $null) {
                [void]$batTexts.Add(('电量 ' + $bat.ChargePercent + '%'))
            }
            if ($bat.PowerStatusText) {
                [void]$batTexts.Add($bat.PowerStatusText)
            }
            if ($bat.HealthPercentText -and $bat.HealthPercentText -ne '无法获取') {
                [void]$batTexts.Add(('健康度 ' + $bat.HealthPercentText))
            }
            if ($batTexts.Count -gt 0) {
                $facts.Battery = ($batTexts -join '，')
            }
        }
        else {
            $facts.Battery = '无电池（台式机/虚拟机）'
        }
    }
    catch {}

    return [pscustomobject]$facts
}

function Get-SupportBattery {
    $battery = [pscustomobject]@{
        HasBattery        = $false
        ChargePercent     = $null
        IsCharging        = $false
        OnAcPower         = $false
        HealthPercent     = $null
        PowerStatusText   = ''
        ChargeText        = '无法获取'
        HealthPercentText = '无法获取'
    }

    try {
        $wb = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wb) {
            $battery.HasBattery = $true
            if ($wb.EstimatedChargeRemaining -ne $null) {
                $battery.ChargePercent = [int]$wb.EstimatedChargeRemaining
                $battery.ChargeText = ($battery.ChargePercent.ToString() + '%')
            }
            $status = 0
            if ($wb.BatteryStatus -ne $null) {
                $status = [int]$wb.BatteryStatus
            }
            switch ($status) {
                1 { $battery.PowerStatusText = '放电中' }
                2 { $battery.PowerStatusText = '使用交流电源'; $battery.OnAcPower = $true }
                3 { $battery.PowerStatusText = '已充满'; $battery.OnAcPower = $true }
                4 { $battery.PowerStatusText = '电量低' }
                5 { $battery.PowerStatusText = '电量严重不足' }
                6 { $battery.PowerStatusText = '正在充电'; $battery.IsCharging = $true; $battery.OnAcPower = $true }
                7 { $battery.PowerStatusText = '正在充电（电量高）'; $battery.IsCharging = $true; $battery.OnAcPower = $true }
                8 { $battery.PowerStatusText = '正在充电（电量低）'; $battery.IsCharging = $true; $battery.OnAcPower = $true }
                9 { $battery.PowerStatusText = '正在充电（电量严重不足）'; $battery.IsCharging = $true; $battery.OnAcPower = $true }
                10 { $battery.PowerStatusText = '状态未知' }
                11 { $battery.PowerStatusText = '部分充电'; $battery.OnAcPower = $true }
                default { $battery.PowerStatusText = '状态未知' }
            }
        }
    }
    catch {}

    try {
        $designed = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
        $full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($designed -and $full -and $designed.DesignedCapacity -gt 0) {
            $ratio = ([double]$full.FullChargedCapacity / [double]$designed.DesignedCapacity) * 100.0
            if ($ratio -gt 100) { $ratio = 100 }
            if ($ratio -lt 0) { $ratio = 0 }
            $battery.HealthPercent = [math]::Round($ratio, 1)
            $battery.HealthPercentText = ($battery.HealthPercent.ToString() + '%')
        }
    }
    catch {}

    return $battery
}

function Show-SupportComputerInfo {
    Write-SectionTitle '电脑信息'
    $f = Get-SupportComputerFacts

    Write-Host ('计算机名：' + $f.ComputerName)
    Write-Host ('当前用户：' + $f.CurrentUser)
    if ($f.IsAdmin) {
        Write-Host '管理员权限：是' -ForegroundColor Green
    }
    else {
        Write-Host '管理员权限：否（部分功能需要管理员权限）' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ('厂商：' + $f.Manufacturer)
    Write-Host ('型号：' + $f.Model)
    Write-Host ('序列号：' + $f.SerialNumber)
    Write-Host ''
    Write-Host ('CPU：' + $f.Cpu)
    if ($f.CpuCoreCount) {
        Write-Host ('CPU 核心：' + $f.CpuCoreCount)
    }
    Write-Host ('内存：' + $f.MemoryTotal)
    if ($f.MemoryFree -and $f.MemoryFree -ne '无法获取') {
        Write-Host ('可用内存：' + $f.MemoryFree)
    }
    Write-Host ('GPU：' + $f.Gpu)
    Write-Host ''
    Write-Host ('Windows版本：' + $f.OsCaption)
    Write-Host ('Windows Build：' + $f.OsBuild)
    Write-Host ('系统版本号：' + $f.OsVersion)
    Write-Host ('BIOS：' + $f.Bios)
    Write-Host ('系统运行时间：' + $f.Uptime)
    Write-Host ''
    Write-Host ('系统磁盘：' + $f.Disk)
    Write-Host ('IP：' + $f.IpAddress)
    Write-Host ('MAC：' + $f.MacAddress)
    Write-Host ('网关：' + $f.Gateway)
    Write-Host ('DNS：' + $f.DnsServer)
    Write-Host ''
    Write-Host ('电池：' + $f.Battery)
    Write-Host ''
}

# ===========================================================================
# 电脑配置
# ===========================================================================

function Convert-SupportMemoryTypeText {
    param([int]$MemoryType)
    switch ($MemoryType) {
        20 { return 'DDR' }
        21 { return 'DDR2' }
        22 { return 'DDR2 FB-DIMM' }
        24 { return 'DDR3' }
        26 { return 'DDR4' }
        27 { return 'LPDDR' }
        28 { return 'LPDDR2' }
        29 { return 'LPDDR3' }
        30 { return 'LPDDR4' }
        34 { return 'DDR5' }
        default { return '未知（SMBIOS ' + $MemoryType + '）' }
    }
}

function Get-SupportComputerConfiguration {
    $configuration = [ordered]@{
        Motherboard = [pscustomobject]@{ Manufacturer = '无法获取'; Product = '无法获取'; SerialNumber = '无法获取' }
        Cpu = @(); Gpu = @(); Memory = @(); MemorySlotCount = $null; Disks = @(); Monitors = @(); Slots = @()
        M2SlotCount = $null; PcieSlotCount = $null; SlotNote = '主板槽位信息取决于 BIOS/SMBIOS 是否暴露。'
    }
    try {
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($board) {
            $configuration.Motherboard = [pscustomobject]@{ Manufacturer = [string]$board.Manufacturer; Product = [string]$board.Product; SerialNumber = [string]$board.SerialNumber }
        }
    } catch {}
    try {
        foreach ($cpu in @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)) {
            $configuration.Cpu += [pscustomobject]@{ Name = [string]$cpu.Name; Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors; MaxClockMHz = $cpu.MaxClockSpeed }
        }
    } catch {}
    try {
        foreach ($gpu in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)) {
            $configuration.Gpu += [pscustomobject]@{ Name = [string]$gpu.Name; VideoMemory = if ($gpu.AdapterRAM) { Format-SupportByteSize ([long]$gpu.AdapterRAM) } else { '无法获取' }; Resolution = if ($gpu.CurrentHorizontalResolution -and $gpu.CurrentVerticalResolution) { $gpu.CurrentHorizontalResolution.ToString() + ' x ' + $gpu.CurrentVerticalResolution.ToString() } else { '无法获取' }; RefreshRate = if ($gpu.CurrentRefreshRate) { $gpu.CurrentRefreshRate.ToString() + ' Hz' } else { '无法获取' } }
        }
    } catch {}
    try {
        $memoryItems = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        foreach ($memory in $memoryItems) {
            $memoryType = if ($memory.SMBIOSMemoryType) { Convert-SupportMemoryTypeText ([int]$memory.SMBIOSMemoryType) } else { Convert-SupportMemoryTypeText ([int]$memory.MemoryType) }
            $configuration.Memory += [pscustomobject]@{ Bank = [string]$memory.DeviceLocator; Manufacturer = [string]$memory.Manufacturer; PartNumber = [string]$memory.PartNumber; Capacity = if ($memory.Capacity) { Format-SupportByteSize ([long]$memory.Capacity) } else { '无法获取' }; Type = $memoryType; Speed = if ($memory.ConfiguredClockSpeed) { $memory.ConfiguredClockSpeed.ToString() + ' MHz' } elseif ($memory.Speed) { $memory.Speed.ToString() + ' MHz' } else { '无法获取' } }
        }
        $memoryArray = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($memoryArray -and $memoryArray.MemoryDevices) { $configuration.MemorySlotCount = [int]$memoryArray.MemoryDevices }
    } catch {}
    try {
        foreach ($disk in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $bus = [string]$disk.BusType
            $protocol = switch -Regex ($bus) { '(?i)NVMe' { 'NVMe / PCIe'; break } '(?i)SATA' { 'SATA'; break } '(?i)USB' { 'USB'; break } default { if ($bus) { $bus } else { '无法获取' } } }
            $configuration.Disks += [pscustomobject]@{ Name = if ($disk.FriendlyName) { [string]$disk.FriendlyName } else { '未命名磁盘' }; MediaType = [string]$disk.MediaType; Protocol = $protocol; Size = if ($disk.Size) { Format-SupportByteSize ([long]$disk.Size) } else { '无法获取' }; Health = [string]$disk.HealthStatus; FormFactor = if ([string]$disk.FriendlyName -match '(?i)M\.2|M2|NGFF') { '可能为 M.2（型号推断）' } else { '无法由系统可靠确认' } }
        }
    } catch {}
    if ($configuration.Disks.Count -eq 0) {
        try { foreach ($disk in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)) { $configuration.Disks += [pscustomobject]@{ Name = [string]$disk.Model; MediaType = ''; Protocol = if ($disk.InterfaceType) { [string]$disk.InterfaceType } else { '无法获取' }; Size = if ($disk.Size) { Format-SupportByteSize ([long]$disk.Size) } else { '无法获取' }; Health = ''; FormFactor = '无法由系统可靠确认' } } } catch {}
    }
    try {
        $monitorIds = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
        $monitorParams = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
        foreach ($monitor in $monitorIds) {
            $manufacturer = -join @($monitor.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }); $name = -join @($monitor.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }); $serial = -join @($monitor.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
            $param = $monitorParams | Where-Object { $_.InstanceName -eq $monitor.InstanceName } | Select-Object -First 1
            $configuration.Monitors += [pscustomobject]@{ Manufacturer = $manufacturer; Name = if ($name) { $name } else { '未知显示器' }; SerialNumber = $serial; PhysicalSize = if ($param.MaxHorizontalImageSize -and $param.MaxVerticalImageSize) { $param.MaxHorizontalImageSize.ToString() + ' x ' + $param.MaxVerticalImageSize.ToString() + ' cm' } else { '无法获取' }; MaxRefreshRate = if ($param.MaxRefreshRate) { $param.MaxRefreshRate.ToString() + ' Hz' } else { '无法获取' } }
        }
    } catch {}
    try {
        foreach ($slot in @(Get-CimInstance -ClassName Win32_SystemSlot -ErrorAction SilentlyContinue)) {
            $text = (([string]$slot.SlotDesignation) + ' ' + ([string]$slot.Description)).Trim(); $isM2 = ($text -match '(?i)M\.2|M2|NGFF'); $isPcie = ($text -match '(?i)PCI.?Express|PCIe' -or ([int]$slot.SlotType) -in @(10, 13, 14, 15, 16, 17, 18))
            $configuration.Slots += [pscustomobject]@{ Designation = $text; SlotType = [string]$slot.SlotType; CurrentUsage = [string]$slot.CurrentUsage; IsM2 = $isM2; IsPcie = $isPcie }
        }
        if ($configuration.Slots.Count -gt 0) { $configuration.M2SlotCount = @($configuration.Slots | Where-Object { $_.IsM2 }).Count; $configuration.PcieSlotCount = @($configuration.Slots | Where-Object { $_.IsPcie }).Count }
    } catch {}
    return [pscustomobject]$configuration
}

function Show-SupportComputerConfiguration {
    Write-SupportUiHeader '配置信息'; Write-Host '正在读取硬件配置，请稍候...' -ForegroundColor Gray; $configuration = Get-SupportComputerConfiguration; Write-Host ''
    Write-SubTitle '主板'; Write-Host ('厂商：' + $configuration.Motherboard.Manufacturer); Write-Host ('型号：' + $configuration.Motherboard.Product); Write-Host ('序列号：' + $configuration.Motherboard.SerialNumber)
    Write-SubTitle 'CPU'; foreach ($cpu in @($configuration.Cpu)) { Write-Host ($cpu.Name + '；' + $cpu.Cores + ' 核 / ' + $cpu.Threads + ' 线程；最高 ' + $cpu.MaxClockMHz + ' MHz') }; if ($configuration.Cpu.Count -eq 0) { Write-Host '无法获取' }
    Write-SubTitle '显卡'; foreach ($gpu in @($configuration.Gpu)) { Write-Host ($gpu.Name + '；显存 ' + $gpu.VideoMemory + '；分辨率 ' + $gpu.Resolution + '；刷新率 ' + $gpu.RefreshRate) }; if ($configuration.Gpu.Count -eq 0) { Write-Host '无法获取' }
    Write-SubTitle '内存'; Write-Host ('已识别内存条：' + $configuration.Memory.Count + ' 条；主板内存槽：' + $(if ($configuration.MemorySlotCount) { $configuration.MemorySlotCount } else { '未由 BIOS 暴露' })); foreach ($memory in @($configuration.Memory)) { Write-Host ($memory.Bank + '：' + $memory.Capacity + ' ' + $memory.Type + ' ' + $memory.Speed + '；' + $memory.Manufacturer + ' ' + $memory.PartNumber) }
    Write-SubTitle '硬盘'; foreach ($disk in @($configuration.Disks)) { Write-Host ($disk.Name + '；' + $disk.MediaType + '；协议：' + $disk.Protocol + '；容量：' + $disk.Size + '；形态：' + $disk.FormFactor) }; if ($configuration.Disks.Count -eq 0) { Write-Host '无法获取' }
    Write-SubTitle '显示器'; foreach ($monitor in @($configuration.Monitors)) { Write-Host ($monitor.Manufacturer + ' ' + $monitor.Name + '；尺寸：' + $monitor.PhysicalSize + '；最大刷新率：' + $monitor.MaxRefreshRate + '；序列号：' + $monitor.SerialNumber) }; if ($configuration.Monitors.Count -eq 0) { Write-Host '无法获取或显示器未暴露 EDID 信息' }
    Write-SubTitle '主板扩展槽'; Write-Host ('M.2 槽：' + $(if ($configuration.M2SlotCount -ne $null) { $configuration.M2SlotCount } else { '未由 BIOS 暴露' })); Write-Host ('PCIe 槽：' + $(if ($configuration.PcieSlotCount -ne $null) { $configuration.PcieSlotCount } else { '未由 BIOS 暴露' })); foreach ($slot in @($configuration.Slots)) { Write-Host ('- ' + $slot.Designation + '；类型：' + $slot.SlotType + '；使用状态：' + $slot.CurrentUsage) }; Write-Host ('说明：' + $configuration.SlotNote) -ForegroundColor Gray; Write-PressAnyKeyToReturn
}

# ===========================================================================
# 网络
# ===========================================================================

function Get-SupportNetworkAdapterInfo {
    $result = @()
    try {
        $netAdapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue)
        $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction SilentlyContinue)
        foreach ($cfg in $configs) {
            $friendlyName = $cfg.Description
            foreach ($na in $netAdapters) {
                if ($na.Index -eq $cfg.Index -and $na.NetConnectionID) {
                    $friendlyName = $na.NetConnectionID
                    break
                }
            }
            $ipv4List = @()
            $maskList = @()
            if ($cfg.IPAddress) {
                $ipArray = @($cfg.IPAddress)
                $maskArray = @($cfg.IPSubnet)
                for ($i = 0; $i -lt $ipArray.Count; $i++) {
                    $ip = [string]$ipArray[$i]
                    if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                        $ipv4List += $ip
                        if ($i -lt $maskArray.Count) {
                            $maskList += [string]$maskArray[$i]
                        }
                        else {
                            $maskList += ''
                        }
                    }
                }
            }
            $gwList = @()
            if ($cfg.DefaultIPGateway) {
                foreach ($gw in @($cfg.DefaultIPGateway)) {
                    if ($gw -and ($gw -notmatch ':')) {
                        $gwList += [string]$gw
                    }
                }
            }
            $dnsList = @()
            if ($cfg.DNSServerSearchOrder) {
                foreach ($dns in @($cfg.DNSServerSearchOrder)) {
                    if ($dns) {
                        $dnsList += [string]$dns
                    }
                }
            }
            $result += [pscustomobject]@{
                Index         = $cfg.Index
                Name          = $friendlyName
                Description   = $cfg.Description
                Status        = '已连接'
                MacAddress    = $cfg.MACAddress
                DhcpEnabled   = $cfg.DHCPEnabled
                IPAddresses   = $ipv4List
                SubnetMasks   = $maskList
                Gateways      = $gwList
                DnsServers    = $dnsList
            }
        }
    }
    catch {}
    return $result
}

function Get-SupportNetConnectionStatusText {
    param([int]$Status)
    switch ($Status) {
        0 { return '已断开' }
        1 { return '正在连接' }
        2 { return '已连接' }
        3 { return '正在断开' }
        4 { return '硬件不存在' }
        5 { return '已禁用' }
        6 { return '硬件故障' }
        7 { return '媒体已断开' }
        8 { return '正在验证' }
        9 { return '验证成功' }
        10 { return '验证失败' }
        11 { return '地址无效' }
        12 { return '需要凭据' }
        default { return '状态未知' }
    }
}

function Get-SupportNetworkAdapterState {
    $result = @()
    $configByIndex = @{}
    try {
        $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue)
        foreach ($cfg in $configs) {
            $configByIndex[[int]$cfg.Index] = $cfg
        }
    }
    catch {}

    try {
        $netAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        if ($netAdapters.Count -gt 0) {
            foreach ($na in $netAdapters) {
                if ($na.Name -match '(?i)^loopback') { continue }
                $cfg = $null
                try {
                    if ($configByIndex.ContainsKey([int]$na.InterfaceIndex)) {
                        $cfg = $configByIndex[[int]$na.InterfaceIndex]
                    }
                }
                catch {}

                $ipv4List = @()
                $maskList = @()
                $gwList = @()
                $dnsList = @()
                $dhcpEnabled = $false
                if ($cfg) {
                    if ($cfg.IPAddress) {
                        $ipArray = @($cfg.IPAddress)
                        $maskArray = @($cfg.IPSubnet)
                        for ($i = 0; $i -lt $ipArray.Count; $i++) {
                            $ip = [string]$ipArray[$i]
                            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                                $ipv4List += $ip
                                if ($i -lt $maskArray.Count) { $maskList += [string]$maskArray[$i] }
                                else { $maskList += '' }
                            }
                        }
                    }
                    if ($cfg.DefaultIPGateway) {
                        foreach ($gw in @($cfg.DefaultIPGateway)) {
                            if ($gw -and ($gw -notmatch ':')) { $gwList += [string]$gw }
                        }
                    }
                    if ($cfg.DNSServerSearchOrder) {
                        foreach ($dns in @($cfg.DNSServerSearchOrder)) {
                            if ($dns) { $dnsList += [string]$dns }
                        }
                    }
                    $dhcpEnabled = [bool]$cfg.DHCPEnabled
                }

                # 某些 Windows 10/11 环境中 WMI 配置查询可能暂时无法按接口索引匹配；
                # 仅在 WMI 没有返回关键网络数据时，使用 NetTCPIP 模块读取同一接口。
                if ($ipv4List.Count -eq 0 -or $gwList.Count -eq 0 -or $dnsList.Count -eq 0) {
                    $modernConfig = Get-SupportModernAdapterNetworkConfig -InterfaceIndex ([int]$na.InterfaceIndex)
                    if ($ipv4List.Count -eq 0) { $ipv4List = @($modernConfig.IPAddresses) }
                    if ($maskList.Count -eq 0) { $maskList = @($modernConfig.SubnetMasks) }
                    if ($gwList.Count -eq 0) { $gwList = @($modernConfig.Gateways) }
                    if ($dnsList.Count -eq 0) { $dnsList = @($modernConfig.DnsServers) }
                    if (-not $dhcpEnabled) { $dhcpEnabled = [bool]$modernConfig.DhcpEnabled }
                }

                $enabled = ($na.Status -ne 'Disabled')
                $connected = ($na.Status -eq 'Up')
                $statusText = [string]$na.Status
                if ($statusText -eq 'Up') { $statusText = '已连接' }
                elseif ($statusText -eq 'Disconnected') { $statusText = '已断开' }
                elseif ($statusText -eq 'Disabled') { $statusText = '已禁用' }
                elseif ($statusText -eq 'Not Present') { $statusText = '不存在' }

                $result += [pscustomobject]@{
                    Index         = [int]$na.InterfaceIndex
                    Name          = $na.Name
                    Description   = $na.InterfaceDescription
                    Status        = $statusText
                    Enabled       = $enabled
                    Connected     = $connected
                    MacAddress    = $na.MacAddress
                    DhcpEnabled   = $dhcpEnabled
                    IPAddresses   = @($ipv4List)
                    SubnetMasks   = @($maskList)
                    Gateways      = @($gwList)
                    DnsServers    = @($dnsList)
                    Source        = 'Get-NetAdapter'
                    IsVirtual     = [bool]$na.Virtual
                    MediaType     = [string]$na.MediaType
                    PhysicalMediaType = [string]$na.PhysicalMediaType
                }
            }
            return $result
        }
    }
    catch {}

    try {
        $cimAdapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.PhysicalAdapter -or $_.NetConnectionID
        })
        foreach ($na in $cimAdapters) {
            if ($na.Name -match '(?i)loopback') { continue }
            $cfg = $null
            try {
                if ($configByIndex.ContainsKey([int]$na.Index)) {
                    $cfg = $configByIndex[[int]$na.Index]
                }
            }
            catch {}

            $ipv4List = @()
            $maskList = @()
            $gwList = @()
            $dnsList = @()
            $dhcpEnabled = $false
            if ($cfg) {
                if ($cfg.IPAddress) {
                    $ipArray = @($cfg.IPAddress)
                    $maskArray = @($cfg.IPSubnet)
                    for ($i = 0; $i -lt $ipArray.Count; $i++) {
                        $ip = [string]$ipArray[$i]
                        if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                            $ipv4List += $ip
                            if ($i -lt $maskArray.Count) { $maskList += [string]$maskArray[$i] }
                            else { $maskList += '' }
                        }
                    }
                }
                if ($cfg.DefaultIPGateway) {
                    foreach ($gw in @($cfg.DefaultIPGateway)) {
                        if ($gw -and ($gw -notmatch ':')) { $gwList += [string]$gw }
                    }
                }
                if ($cfg.DNSServerSearchOrder) {
                    foreach ($dns in @($cfg.DNSServerSearchOrder)) {
                        if ($dns) { $dnsList += [string]$dns }
                    }
                }
                $dhcpEnabled = [bool]$cfg.DHCPEnabled
            }

            $connectionStatus = 0
            if ($na.NetConnectionStatus -ne $null) {
                $connectionStatus = [int]$na.NetConnectionStatus
            }
            $enabled = [bool]$na.NetEnabled
            $connected = ($connectionStatus -eq 2)
            $result += [pscustomobject]@{
                Index         = [int]$na.Index
                Name          = if ($na.NetConnectionID) { $na.NetConnectionID } else { $na.Name }
                Description   = $na.Name
                Status        = Get-SupportNetConnectionStatusText $connectionStatus
                Enabled       = $enabled
                Connected     = $connected
                MacAddress    = $na.MACAddress
                DhcpEnabled   = $dhcpEnabled
                IPAddresses   = @($ipv4List)
                SubnetMasks   = @($maskList)
                Gateways      = @($gwList)
                DnsServers    = @($dnsList)
                Source        = 'Win32_NetworkAdapter'
                IsVirtual     = (-not [bool]$na.PhysicalAdapter)
                MediaType     = [string]$na.AdapterType
                PhysicalMediaType = ''
            }
        }
    }
    catch {}

    if ($result.Count -eq 0) {
        foreach ($ad in @(Get-SupportNetworkAdapterInfo)) {
            $result += [pscustomobject]@{
                Index         = [int]$ad.Index
                Name          = $ad.Name
                Description   = $ad.Description
                Status        = '已连接'
                Enabled       = $true
                Connected     = $true
                MacAddress    = $ad.MacAddress
                DhcpEnabled   = [bool]$ad.DhcpEnabled
                IPAddresses   = @($ad.IPAddresses)
                SubnetMasks   = @($ad.SubnetMasks)
                Gateways      = @($ad.Gateways)
                DnsServers    = @($ad.DnsServers)
                Source        = 'Win32_NetworkAdapterConfiguration'
                IsVirtual     = $false
                MediaType     = ''
                PhysicalMediaType = ''
            }
        }
    }
    return $result
}

function Get-SupportPrimaryNetworkAdapterState {
    param($Adapters)
    if (-not $Adapters -or $Adapters.Count -eq 0) {
        return $null
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $matched = $Adapters | Where-Object { $_.Index -eq $route.ifIndex } | Select-Object -First 1
            if ($matched) { return $matched }
        }
    }
    catch {}
    $connected = $Adapters | Where-Object { $_.Connected } | Select-Object -First 1
    if ($connected) { return $connected }
    $withGateway = $Adapters | Where-Object { $_.Enabled -and $_.Gateways.Count -gt 0 } | Select-Object -First 1
    if ($withGateway) { return $withGateway }
    return ($Adapters | Where-Object { $_.Enabled } | Select-Object -First 1)
}

function Get-SupportWifiInfo {
    $wifi = [pscustomobject]@{
        Detected       = $false
        AdapterName    = ''
        Connected      = $false
        Ssid           = ''
        NetworkCategory = ''
    }
    try {
        $wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.PhysicalMediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match '(?i)wireless|wlan|wi-?fi'
        })
        foreach ($wa in $wifiAdapters) {
            $wifi.Detected = $true
            $wifi.AdapterName = $wa.Name
            if ($wa.Status -eq 'Up') {
                $profile = Get-NetConnectionProfile -InterfaceIndex $wa.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($profile) {
                    $wifi.Connected = $true
                    $wifi.Ssid = $profile.Name
                    $wifi.NetworkCategory = $profile.NetworkCategory
                }
            }
            break
        }
    }
    catch {}
    return $wifi
}

function Get-SupportModernAdapterNetworkConfig {
    param([int]$InterfaceIndex)
    $result = [pscustomobject]@{
        IPAddresses = @()
        SubnetMasks = @()
        Gateways    = @()
        DnsServers  = @()
        DhcpEnabled = $false
    }
    try {
        $ipItems = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($ipItem in $ipItems) {
            if ($ipItem.IPAddress -and ([string]$ipItem.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$')) {
                $result.IPAddresses += [string]$ipItem.IPAddress
                if ($ipItem.PrefixLength -ne $null) {
                    $prefix = [int]$ipItem.PrefixLength
                    $mask = [uint32]0
                    if ($prefix -gt 0) { $mask = [uint32]([uint64]0xffffffff -shl (32 - $prefix)) }
                    $bytes = [BitConverter]::GetBytes($mask)
                    [Array]::Reverse($bytes)
                    $result.SubnetMasks += (($bytes | ForEach-Object { [string]$_ }) -join '.')
                }
            }
        }
    }
    catch {}
    try {
        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipConfig) {
            foreach ($gateway in @($ipConfig.IPv4DefaultGateway)) {
                if ($gateway.NextHop) { $result.Gateways += [string]$gateway.NextHop }
            }
            if ($ipConfig.DnsServer -and $ipConfig.DnsServer.ServerAddresses) {
                $result.DnsServers += @($ipConfig.DnsServer.ServerAddresses | ForEach-Object { [string]$_ })
            }
        }
    }
    catch {}
    try {
        $ipInterface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipInterface -and [string]$ipInterface.Dhcp -eq 'Enabled') { $result.DhcpEnabled = $true }
    }
    catch {}
    $result.IPAddresses = @($result.IPAddresses | Select-Object -Unique)
    $result.SubnetMasks = @($result.SubnetMasks | Select-Object -Unique)
    $result.Gateways = @($result.Gateways | Select-Object -Unique)
    $result.DnsServers = @($result.DnsServers | Select-Object -Unique)
    return $result
}

function Get-SupportWinHttpProxyInfo {
    $result = [pscustomobject]@{
        Enabled = $false
        Server  = ''
        Summary = '未检测到 WinHTTP 代理'
    }
    try {
        $output = @(& netsh.exe winhttp show proxy 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
            $text = ($output -join "`n").Trim()
            if ($text -match '(?i)direct access|直接访问|无代理服务器|没有代理服务器') {
                $result.Summary = 'WinHTTP：直接访问，未配置代理'
                return $result
            }
            $proxyServer = ''
            foreach ($line in $output) {
                if ($line -match '(?i)(Proxy Server\(s\)|Proxy Server|代理服务器)\s*[：:]\s*(.+)$') {
                    $proxyServer = $matches[2].Trim()
                    break
                }
            }
            $result.Enabled = $true
            $result.Server = $proxyServer
            if ($proxyServer) {
                $result.Summary = 'WinHTTP 代理：' + $proxyServer
            }
            else {
                $result.Summary = '检测到 WinHTTP 代理配置'
            }
        }
    }
    catch {}
    return $result
}

function Test-SupportVpnOrTunnelAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $mediaType = [string]$Adapter.MediaType
    $physicalMediaType = [string]$Adapter.PhysicalMediaType
    $description = [string]$Adapter.Description
    if ($mediaType -match '(?i)tunnel|vpn') { return $true }
    if ($physicalMediaType -match '(?i)tunnel') { return $true }
    if ($description -match '(?i)\b(vpn|tun|tap|wireguard|wintun)\b') { return $true }
    if ([bool]$Adapter.IsVirtual) { return $true }
    return $false
}

function Get-SupportProxyInfo {
    param($Adapters)
    $proxy = [pscustomobject]@{
        Enabled            = $false
        Server             = ''
        Bypass             = ''
        AutoConfigUrl      = ''
        AutoDetect         = $false
        ProxyEnable        = $false
        Environment        = @()
        EnvironmentEnabled = $false
        Summary            = '未启用代理'
        WinHttpEnabled     = $false
        WinHttpServer      = ''
        WinHttpSummary     = '未检测到 WinHTTP 代理'
        VpnOrTunnelDetected = $false
        VpnAdapterNames    = @()
        AnyProxy           = $false
    }
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $key = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($key) {
            $proxy.AutoConfigUrl = [string]$key.AutoConfigURL
            $proxy.AutoDetect = [bool]$key.AutoDetect
            if ($key.ProxyEnable -and ([int]$key.ProxyEnable -eq 1)) {
                $proxy.Enabled = $true
                $proxy.ProxyEnable = $true
                $proxy.Server = [string]$key.ProxyServer
                $proxy.Bypass = [string]$key.ProxyOverride
            }
            if ($proxy.AutoConfigUrl -or $proxy.AutoDetect) {
                $proxy.Enabled = $true
            }
        }
    }
    catch {}

    $winHttp = Get-SupportWinHttpProxyInfo
    $proxy.WinHttpEnabled = $winHttp.Enabled
    $proxy.WinHttpServer = $winHttp.Server
    $proxy.WinHttpSummary = $winHttp.Summary

    foreach ($envName in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
        try {
            $envValue = [string](Get-Item -Path ('Env:' + $envName) -ErrorAction SilentlyContinue).Value
            if ($envValue) {
                $proxy.Environment += [pscustomobject]@{ Name = $envName; Value = $envValue }
                if ($envName -ne 'NO_PROXY') { $proxy.EnvironmentEnabled = $true }
            }
        }
        catch {}
    }

    if (-not $Adapters) {
        try { $Adapters = @(Get-SupportNetworkAdapterState) } catch { $Adapters = @() }
    }
    $vpnNames = @()
    foreach ($adapter in @($Adapters)) {
        if (Test-SupportVpnOrTunnelAdapter $adapter) {
            if ($adapter.Name) { $vpnNames += [string]$adapter.Name }
        }
    }
    $vpnNames = @($vpnNames | Select-Object -Unique)
    if ($vpnNames.Count -gt 0) {
        $proxy.VpnOrTunnelDetected = $true
        $proxy.VpnAdapterNames = @($vpnNames)
    }

    $proxy.AnyProxy = ($proxy.Enabled -or $proxy.WinHttpEnabled -or $proxy.EnvironmentEnabled -or $proxy.VpnOrTunnelDetected)
    $summaryParts = @()
    if ($proxy.Enabled) {
        if ($proxy.Server) { $summaryParts += ('系统代理：' + $proxy.Server) }
        elseif ($proxy.AutoConfigUrl) { $summaryParts += ('系统代理自动配置：' + $proxy.AutoConfigUrl) }
        else { $summaryParts += '系统代理：已启用（未设置服务器）' }
    }
    if ($proxy.WinHttpEnabled) {
        if ($proxy.WinHttpServer) { $summaryParts += ('WinHTTP：' + $proxy.WinHttpServer) }
        else { $summaryParts += 'WinHTTP：已配置代理' }
    }
    if ($proxy.EnvironmentEnabled) {
        $summaryParts += ('环境变量：' + ((@($proxy.Environment | Where-Object { $_.Name -ne 'NO_PROXY' }) | ForEach-Object { $_.Name + '=' + $_.Value }) -join ', '))
    }
    if ($proxy.VpnOrTunnelDetected) {
        $summaryParts += ('VPN/TUN：' + ($vpnNames -join ', '))
    }
    if ($summaryParts.Count -gt 0) {
        $proxy.Summary = ($summaryParts -join '；')
    }
    return $proxy
}

# ---- V1.2 网络环境检测（独立于基础 IPv4/网关/DNS 诊断） ----

function Invoke-SupportJsonWebRequest {
    param(
        [string]$Uri,
        [int]$TimeoutMs = 6000,
        $ProxyInfo
    )
    $request = $null
    $response = $null
    $reader = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'WinSupport-Toolkit/1.2'
        $request.UseDefaultCredentials = $true
        try {
            $request.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            if ($ProxyInfo -and -not $ProxyInfo.Enabled -and $ProxyInfo.WinHttpServer -and $ProxyInfo.WinHttpServer -notmatch '[=;]') {
                $proxyAddress = [string]$ProxyInfo.WinHttpServer
                if ($proxyAddress -notmatch '^[a-z]+://') { $proxyAddress = 'http://' + $proxyAddress }
                $request.Proxy = New-Object System.Net.WebProxy($proxyAddress, $true)
            }
        } catch {}
        $response = $request.GetResponse()
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($response.GetResponseStream())
        $raw = $reader.ReadToEnd()
        return [pscustomobject]@{ Success = $true; StatusCode = [int]$response.StatusCode; Data = ($raw | ConvertFrom-Json); Raw = $raw; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; StatusCode = 0; Data = $null; Raw = ''; Error = $_.Exception.Message }
    }
    finally {
        if ($reader) { try { $reader.Close() } catch {} }
        if ($response) { try { $response.Close() } catch {} }
    }
}

function Get-SupportPublicNetworkInfo {
    param($ProxyInfo)
    $services = @('https://ipwho.is/', 'https://ipapi.co/json/')
    foreach ($uri in $services) {
        $result = Invoke-SupportJsonWebRequest -Uri $uri -TimeoutMs 6000 -ProxyInfo $ProxyInfo
        if (-not $result.Success -or -not $result.Data) { continue }
        $data = $result.Data
        $ip = [string]$data.ip
        if (-not $ip) { continue }
        $country = [string]$data.country
        $region = [string]$data.region
        $city = [string]$data.city
        $org = [string]$data.connection.org
        $asn = [string]$data.connection.asn
        if (-not $org) { $org = [string]$data.org }
        if (-not $asn) { $asn = [string]$data.asn }
        return [pscustomobject]@{
            Success = $true; PublicIP = $ip; Country = $country; Region = $region; City = $city
            Organization = $org; ISP = $org; ASN = $asn; Service = $uri; Error = ''
        }
    }
    return [pscustomobject]@{
        Success = $false; PublicIP = ''; Country = ''; Region = ''; City = ''
        Organization = ''; ISP = ''; ASN = ''; Service = ''; Error = '公网出口信息服务均不可访问'
    }
}

function Test-SupportEnvironmentTarget {
    param(
        [string]$Name,
        [string]$HostName,
        [string]$Uri,
        [int]$TimeoutMs = 6000,
        [bool]$UseSystemProxy = $true,
        $ProxyInfo
    )
    $started = [DateTime]::UtcNow
    $dns = @()
    $dnsError = ''
    try { $dns = @([System.Net.Dns]::GetHostAddresses($HostName)) } catch { $dnsError = $_.Exception.Message }
    $dnsOk = ($dns.Count -gt 0)
    $statusCode = 0
    $httpsOk = $false
    $httpsError = ''
    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'WinSupport-Toolkit/1.2'
        $request.UseDefaultCredentials = $true
        if ($UseSystemProxy) {
            try {
                $request.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                if ($ProxyInfo -and -not $ProxyInfo.Enabled -and $ProxyInfo.WinHttpServer -and $ProxyInfo.WinHttpServer -notmatch '[=;]') {
                    $proxyAddress = [string]$ProxyInfo.WinHttpServer
                    if ($proxyAddress -notmatch '^[a-z]+://') { $proxyAddress = 'http://' + $proxyAddress }
                    $request.Proxy = New-Object System.Net.WebProxy($proxyAddress, $true)
                }
            } catch {}
        }
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $httpsOk = ($statusCode -ge 200 -and $statusCode -lt 400)
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            try { $statusCode = [int]$response.StatusCode } catch {}
            $httpsOk = ($statusCode -ge 200 -and $statusCode -lt 400)
        }
        $httpsError = $_.Exception.Message
    }
    catch { $httpsError = $_.Exception.Message }
    finally { if ($response) { try { $response.Close() } catch {} } }
    $elapsed = ([DateTime]::UtcNow - $started).TotalMilliseconds
    return [pscustomobject]@{
        Name = $Name; HostName = $HostName; Uri = $Uri; DnsSuccess = $dnsOk; DnsAddresses = @($dns | Select-Object -First 3 | ForEach-Object { [string]$_ })
        DnsError = $dnsError; HttpsSuccess = $httpsOk; StatusCode = $statusCode; LatencyMs = [int]$elapsed; Error = $httpsError
        # 代理可能替客户端完成 DNS，因此可达性以 HTTPS 为准，DNS 仅作为技术详情。
        Success = $httpsOk
    }
}

function Get-SupportNetworkEnvironmentStatus {
    param([object[]]$Results)
    $items = @($Results)
    if ($items.Count -eq 0) { return '异常' }
    $successes = @($items | Where-Object { $_.Success }).Count
    if (($successes * 2) -gt $items.Count) { return '正常' }
    if ($successes -gt 0) { return '部分可用' }
    return '异常'
}

function Get-SupportNetworkEnvironmentConclusion {
    param($Environment)
    $proxy = $Environment.Proxy
    $local = if ($Environment.LocalNetworkHealthy) { '本地网络正常' } else { '本地网络存在基础连接问题' }
    $proxyText = if ($proxy.AnyProxy) { '当前通过代理或 VPN/TUN 访问互联网' } else { '当前未检测到代理' }
    $location = if ($Environment.Public.Success) {
        $place = @($Environment.Public.Country, $Environment.Public.Region, $Environment.Public.City) | Where-Object { $_ }
        '公网出口位于' + ($place -join ' / ')
    } else { '公网出口地区暂时无法获取' }
    return ($local + '，' + $proxyText + '。' + $location + '。中国大陆网络' + $Environment.MainlandStatus + '，海外网络' + $Environment.OverseasStatus + '，Google' + $Environment.GoogleStatus + '。')
}

function Get-SupportNetworkEnvironmentInfo {
    $adapters = @()
    try { $adapters = @(Get-SupportNetworkAdapterState) } catch {}
    $proxy = Get-SupportProxyInfo $adapters
    $public = Get-SupportPublicNetworkInfo -ProxyInfo $proxy
    $mainlandTargets = @(
        @{ Name = '百度'; HostName = 'www.baidu.com'; Uri = 'https://www.baidu.com/' },
        @{ Name = '腾讯'; HostName = 'www.qq.com'; Uri = 'https://www.qq.com/' },
        @{ Name = '阿里云'; HostName = 'www.aliyun.com'; Uri = 'https://www.aliyun.com/' }
    )
    $overseasTargets = @(
        @{ Name = 'Google'; HostName = 'www.google.com'; Uri = 'https://www.google.com/generate_204' },
        @{ Name = 'Cloudflare'; HostName = 'www.cloudflare.com'; Uri = 'https://www.cloudflare.com/' },
        @{ Name = 'GitHub'; HostName = 'github.com'; Uri = 'https://github.com/' }
    )
    $mainland = @($mainlandTargets | ForEach-Object { Test-SupportEnvironmentTarget -Name $_.Name -HostName $_.HostName -Uri $_.Uri -ProxyInfo $proxy })
    $overseas = @($overseasTargets | ForEach-Object { Test-SupportEnvironmentTarget -Name $_.Name -HostName $_.HostName -Uri $_.Uri -ProxyInfo $proxy })
    $google = $overseas | Where-Object { $_.Name -eq 'Google' } | Select-Object -First 1
    $localHealthy = $false
    try {
        $localHealthy = (@($adapters | Where-Object { $_.Enabled -and $_.Connected -and $_.IPAddresses.Count -gt 0 -and $_.Gateways.Count -gt 0 }).Count -gt 0)
    } catch {}
    $environment = [pscustomobject]@{
        GeneratedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; Proxy = $proxy; Public = $public
        Mainland = @($mainland); Overseas = @($overseas); Google = $google
        MainlandStatus = Get-SupportNetworkEnvironmentStatus $mainland
        OverseasStatus = Get-SupportNetworkEnvironmentStatus $overseas
        GoogleStatus = if ($google -and $google.Success) { '正常' } else { '无法访问' }
        LocalNetworkHealthy = $localHealthy
    }
    $environment.Conclusion = Get-SupportNetworkEnvironmentConclusion $environment
    return $environment
}

function Write-SupportNetworkEnvironmentStatus {
    param([string]$Label, [string]$Status)
    $color = if ($Status -eq '正常') { 'Green' } elseif ($Status -eq '部分可用') { 'Yellow' } else { 'Red' }
    Write-Host ('[' + $Status + '] ' + $Label) -ForegroundColor $color
}

function Show-SupportNetworkEnvironment {
    while ($true) {
        Write-SupportUiHeader '网络环境'
        Write-Host '正在检测网络环境，请稍候...' -ForegroundColor Gray
        $environment = Get-SupportNetworkEnvironmentInfo
        Write-Host ''
        Write-SubTitle '代理'
        if ($environment.Proxy.AnyProxy) {
            Write-WarnText '已检测到代理或 VPN/TUN'
        } else { Write-OkText '未检测到代理' }
        $systemProxyText = if ($environment.Proxy.Server) { $environment.Proxy.Server } elseif ($environment.Proxy.AutoConfigUrl) { 'PAC：' + $environment.Proxy.AutoConfigUrl } elseif ($environment.Proxy.AutoDetect) { '自动检测（WPAD）' } elseif ($environment.Proxy.Enabled) { '已启用（未设置服务器）' } else { '未启用' }
        Write-Host ('系统代理：' + $systemProxyText)
        Write-Host ('PAC：' + $(if ($environment.Proxy.AutoConfigUrl) { $environment.Proxy.AutoConfigUrl } elseif ($environment.Proxy.AutoDetect) { '自动检测（WPAD）' } else { '未使用' }))
        Write-Host ('WinHTTP：' + $(if ($environment.Proxy.WinHttpEnabled) { $environment.Proxy.WinHttpServer } else { 'Direct' }))
        Write-Host ('VPN/TUN：' + $(if ($environment.Proxy.VpnOrTunnelDetected) { '检测到（' + ($environment.Proxy.VpnAdapterNames -join ', ') + '）' } else { '未检测到' }))
        if (@($environment.Proxy.Environment).Count -gt 0) { Write-Host ('环境变量：' + ((@($environment.Proxy.Environment) | ForEach-Object { $_.Name + '=' + $_.Value }) -join ', ')) }
        Write-SubTitle '公网出口'
        if ($environment.Public.Success) {
            Write-Host ('IP：' + $environment.Public.PublicIP)
            Write-Host ('公网出口地区：' + ((@($environment.Public.Country, $environment.Public.Region, $environment.Public.City) | Where-Object { $_ }) -join ' / '))
            Write-Host ('运营商：' + $environment.Public.Organization)
            if ($environment.Public.ASN) { Write-Host ('ASN：' + $environment.Public.ASN) }
            Write-Host '提示：公网出口地区 ≠ 电脑物理位置' -ForegroundColor Gray
        } else { Write-WarnText '公网出口信息暂时无法获取，不影响网络故障判断。' }
        Write-SubTitle '网络可达性'
        Write-SupportNetworkEnvironmentStatus '中国大陆网络' $environment.MainlandStatus
        Write-SupportNetworkEnvironmentStatus '海外网络' $environment.OverseasStatus
        Write-SupportNetworkEnvironmentStatus 'Google' $environment.GoogleStatus
        Write-SubTitle '结论'
        Write-Host $environment.Conclusion -ForegroundColor Cyan
        Write-Host ''
        Write-Host '[1] 重新检测'
        Write-Host '[2] 技术详情'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 2
        if ($choice -eq 0) { return }
        if ($choice -eq 2) {
            Write-SupportUiHeader '网络环境技术详情'
            Write-Host ('代理对象：' + ($environment.Proxy | ConvertTo-Json -Depth 5)) -ForegroundColor Gray
            Write-Host ''
            Write-Host '中国大陆测试：' -ForegroundColor Cyan
            @($environment.Mainland) + @($environment.Overseas) | Format-List | Out-String -Width 240 | Write-Host
            Write-Host '公网 API：' -ForegroundColor Cyan
            $environment.Public | Format-List | Out-String -Width 200 | Write-Host
            Write-PressAnyKeyToReturn
        }
    }
}

function Show-SupportNetworkInfo {
    Write-SectionTitle '网络信息'

    $adapters = @(Get-SupportNetworkAdapterInfo)
    if ($adapters.Count -eq 0) {
        Write-NoticeText '未检测到已启用且获得 IP 的网络适配器。'
    }
    else {
        $idx = 0
        foreach ($ad in $adapters) {
            $idx++
            Write-SubTitle ('适配器 ' + $idx + '：' + $ad.Name)
            Write-Host ('网卡：' + $ad.Description)
            Write-Host ('状态：' + $ad.Status)
            if ($ad.IPAddresses.Count -gt 0) {
                for ($i = 0; $i -lt $ad.IPAddresses.Count; $i++) {
                    Write-Host ('IP地址：' + $ad.IPAddresses[$i])
                    if ($i -lt $ad.SubnetMasks.Count -and $ad.SubnetMasks[$i]) {
                        Write-Host ('子网掩码：' + $ad.SubnetMasks[$i])
                    }
                }
            }
            else {
                Write-Host 'IP地址：无 IPv4 地址'
            }
            if ($ad.Gateways.Count -gt 0) {
                Write-Host ('默认网关：' + ($ad.Gateways -join '; '))
            }
            else {
                Write-Host '默认网关：无'
            }
            if ($ad.DnsServers.Count -gt 0) {
                Write-Host ('DNS：' + ($ad.DnsServers -join '; '))
            }
            else {
                Write-Host 'DNS：无'
            }
            if ($ad.DhcpEnabled) {
                Write-Host 'DHCP：启用'
            }
            else {
                Write-Host 'DHCP：未启用（静态 IP）'
            }
            if ($ad.MacAddress) {
                Write-Host ('MAC地址：' + $ad.MacAddress)
            }
            Write-Host ''
        }
    }

    $wifi = Get-SupportWifiInfo
    if ($wifi.Detected) {
        Write-SubTitle 'Wi-Fi'
        if ($wifi.Connected) {
            Write-Host ('状态：已连接（' + $wifi.AdapterName + '）')
            if ($wifi.Ssid) {
                Write-Host ('当前网络：' + $wifi.Ssid)
            }
            if ($wifi.NetworkCategory) {
                Write-Host ('网络位置：' + $wifi.NetworkCategory)
            }
        }
        else {
            Write-Host ('状态：未连接（' + $wifi.AdapterName + '）')
        }
    }

    $proxy = Get-SupportProxyInfo
    Write-SubTitle 'Windows 代理设置'
    Write-Host ($proxy.Summary)
    Write-Host ''
}

function Test-SupportPing {
    param(
        [string]$Target,
        [int]$Count = 1,
        [int]$TimeoutMs = 1500
    )
    try {
        $null = & ping.exe -n $Count -w $TimeoutMs $Target 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Test-SupportTcpConnectDetailed {
    param(
        [string]$HostName = 'www.microsoft.com',
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostName, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) {
            return [pscustomobject]@{
                Success = $true
                Target  = $HostName
                Port    = $Port
                Detail  = ('TCP ' + $Port + ' 连接成功')
            }
        }
        return [pscustomobject]@{
            Success = $false
            Target  = $HostName
            Port    = $Port
            Detail  = ('TCP ' + $Port + ' 连接超时')
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Target  = $HostName
            Port    = $Port
            Detail  = $_.Exception.Message
        }
    }
    finally {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}

function Test-SupportHttpsConnectDetailed {
    param(
        [string]$HostName = 'www.microsoft.com',
        [int]$TimeoutMs = 7000
    )
    $client = $null
    $sslStream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostName, 443)
        if (-not $task.Wait($TimeoutMs) -or -not $client.Connected) {
            return [pscustomobject]@{
                Success = $false
                Target  = $HostName
                Detail  = 'HTTPS 端口连接超时'
            }
        }
        $sslStream = New-Object System.Net.Security.SslStream -ArgumentList @($client.GetStream(), $false)
        $sslStream.AuthenticateAsClient($HostName)
        return [pscustomobject]@{
            Success = $true
            Target  = $HostName
            Detail  = ('TLS 握手成功（' + $sslStream.SslProtocol.ToString() + '）')
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Target  = $HostName
            Detail  = $_.Exception.Message
        }
    }
    finally {
        if ($sslStream) {
            try { $sslStream.Close() } catch {}
        }
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}

function Test-SupportDnsResolution {
    param([string]$HostName = 'www.microsoft.com')
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        return ($addresses.Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-SupportDnsResolutionDetailed {
    param([string[]]$HostNames = @('www.microsoft.com', 'www.baidu.com'))
    $details = @()
    foreach ($hostName in $HostNames) {
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($hostName))
            if ($addresses.Count -gt 0) {
                $addressText = @($addresses | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join ', '
                $details += [pscustomobject]@{
                    HostName = $hostName
                    Success  = $true
                    Address  = $addressText
                    Error    = ''
                }
            }
            else {
                $details += [pscustomobject]@{
                    HostName = $hostName
                    Success  = $false
                    Address  = ''
                    Error    = '未返回地址'
                }
            }
        }
        catch {
            $details += [pscustomobject]@{
                HostName = $hostName
                Success  = $false
                Address  = ''
                Error    = $_.Exception.Message
            }
        }
    }
    $successful = @($details | Where-Object { $_.Success })
    return [pscustomobject]@{
        Success = ($successful.Count -gt 0)
        Details = @($details)
        Summary = if ($successful.Count -gt 0) {
            ($successful[0].HostName + ' -> ' + $successful[0].Address)
        }
        else {
            '所有测试域名均无法解析'
        }
    }
}

function Test-SupportTcpConnect {
    param(
        [string]$HostName = 'www.microsoft.com',
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )
    return ([bool](Test-SupportTcpConnectDetailed -HostName $HostName -Port $Port -TimeoutMs $TimeoutMs).Success)
}

function Get-SupportPrimaryGateway {
    $adapters = @(Get-SupportNetworkAdapterInfo)
    if ($adapters.Count -eq 0) {
        return $null
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            foreach ($ad in $adapters) {
                if ($ad.Index -eq $route.ifIndex -and $ad.Gateways.Count -gt 0) {
                    return [string]$ad.Gateways[0]
                }
            }
        }
    }
    catch {}
    foreach ($ad in $adapters) {
        if ($ad.Gateways.Count -gt 0) {
            return [string]$ad.Gateways[0]
        }
    }
    return $null
}

function Get-SupportPublicConnectivityResult {
    $targets = @('223.5.5.5', '114.114.114.114', '8.8.8.8', '1.1.1.1')
    foreach ($target in $targets) {
        if (Test-SupportPing -Target $target -Count 1 -TimeoutMs 1200) {
            return [pscustomobject]@{
                Success = $true
                Target  = $target
                Method  = 'ICMP'
                Detail  = ('Ping 公网 IP ' + $target + ' 成功')
            }
        }
    }
    foreach ($target in $targets) {
        $tcpResult = Test-SupportTcpConnectDetailed -HostName $target -Port 443 -TimeoutMs 2500
        if ($tcpResult.Success) {
            return [pscustomobject]@{
                Success = $true
                Target  = $target
                Method  = 'TCP'
                Detail  = ('公网 IP ' + $target + ' 的 TCP 443 可达（ICMP 可能被屏蔽）')
            }
        }
    }
    return [pscustomobject]@{
        Success = $false
        Target  = ''
        Method  = ''
        Detail  = '公网 IP 的 ICMP 与 TCP 443 测试均失败'
    }
}

function Test-SupportHttpsViaSystemProxyDetailed {
    param(
        [string]$HostName = 'www.microsoft.com',
        [int]$TimeoutMs = 8000,
        $ProxyInfo
    )
    $oldSecurityProtocol = $null
    try {
        $oldSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
        if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
    }
    catch {}

    try {
        $request = [System.Net.HttpWebRequest]::Create(('https://' + $HostName + '/'))
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'WinSupport-Toolkit/1.1'
        $request.UseDefaultCredentials = $true
        try {
            $request.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            if ($ProxyInfo -and -not $ProxyInfo.Enabled -and $ProxyInfo.WinHttpServer -and $ProxyInfo.WinHttpServer -notmatch '[=;]') {
                $proxyAddress = [string]$ProxyInfo.WinHttpServer
                if ($proxyAddress -notmatch '^[a-z]+://') {
                    $proxyAddress = 'http://' + $proxyAddress
                }
                $request.Proxy = New-Object System.Net.WebProxy($proxyAddress, $true)
            }
            if ($request.Proxy) {
                $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
            }
        }
        catch {}

        try {
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            try { $response.Close() } catch {}
            if ($statusCode -eq 407) {
                return [pscustomobject]@{
                    Success = $false
                    Target  = $HostName
                    Detail  = '代理服务器要求身份验证（HTTP 407）'
                }
            }
            if ($statusCode -lt 500) {
                return [pscustomobject]@{
                    Success = $true
                    Target  = $HostName
                    Detail  = ('通过系统代理完成 HTTPS 请求（HTTP ' + $statusCode + '）')
                }
            }
            return [pscustomobject]@{
                Success = $false
                Target  = $HostName
                Detail  = ('代理 HTTPS 请求返回 HTTP ' + $statusCode)
            }
        }
        catch [System.Net.WebException] {
            $response = $_.Exception.Response
            if ($response) {
                $statusCode = [int]$response.StatusCode
                try { $response.Close() } catch {}
                if ($statusCode -ne 407 -and $statusCode -lt 500) {
                    return [pscustomobject]@{
                        Success = $true
                        Target  = $HostName
                        Detail  = ('通过系统代理完成 HTTPS 请求（HTTP ' + $statusCode + '）')
                    }
                }
                return [pscustomobject]@{
                    Success = $false
                    Target  = $HostName
                    Detail  = ('代理 HTTPS 请求失败（HTTP ' + $statusCode + '）')
                }
            }
            return [pscustomobject]@{
                Success = $false
                Target  = $HostName
                Detail  = $_.Exception.Message
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Target  = $HostName
            Detail  = $_.Exception.Message
        }
    }
    finally {
        if ($oldSecurityProtocol -ne $null) {
            try { [System.Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol } catch {}
        }
    }
}

function Get-SupportHttpsConnectivityResult {
    param($ProxyInfo)
    $targets = @('www.microsoft.com', 'www.baidu.com')
    $lastDirectError = ''
    foreach ($target in $targets) {
        $result = Test-SupportHttpsConnectDetailed -HostName $target
        if ($result.Success) {
            return [pscustomobject]@{
                Success        = $true
                Target         = $result.Target
                Detail         = $result.Detail
                Mode           = 'Direct'
                DirectSuccess  = $true
                ProxyAttempted = $false
                ProxySuccess   = $false
            }
        }
        $lastDirectError = $result.Detail
    }

    $proxyAttempted = $false
    $lastProxyError = ''
    if ($ProxyInfo -and $ProxyInfo.AnyProxy) {
        $proxyAttempted = $true
        foreach ($target in $targets) {
            $proxyResult = Test-SupportHttpsViaSystemProxyDetailed -HostName $target -ProxyInfo $ProxyInfo
            if ($proxyResult.Success) {
                return [pscustomobject]@{
                    Success        = $true
                    Target         = $proxyResult.Target
                    Detail         = $proxyResult.Detail
                    Mode           = 'SystemProxy'
                    DirectSuccess  = $false
                    ProxyAttempted = $true
                    ProxySuccess   = $true
                }
            }
            $lastProxyError = $proxyResult.Detail
        }
    }
    return [pscustomobject]@{
        Success        = $false
        Target         = ''
        Detail         = if ($lastProxyError) { $lastProxyError } else { $lastDirectError }
        Mode           = 'None'
        DirectSuccess  = $false
        ProxyAttempted = $proxyAttempted
        ProxySuccess   = $false
    }
}

function Get-SupportNetworkEvidence {
    $adapters = @(Get-SupportNetworkAdapterState)
    $selectedAdapter = Get-SupportPrimaryNetworkAdapterState $adapters
    $proxy = Get-SupportProxyInfo $adapters
    $gateway = ''
    if ($selectedAdapter -and $selectedAdapter.Gateways.Count -gt 0) {
        $gateway = [string]$selectedAdapter.Gateways[0]
    }
    if (-not $gateway) {
        $gateway = Get-SupportPrimaryGateway
    }

    $gatewayPingOk = $false
    if ($gateway) {
        $gatewayPingOk = Test-SupportPing -Target $gateway -Count 2 -TimeoutMs 1200
    }

    return [pscustomobject]@{
        Adapters           = @($adapters)
        SelectedAdapter    = $selectedAdapter
        TcpIpOk            = Test-SupportPing -Target '127.0.0.1' -Count 2 -TimeoutMs 800
        Gateway            = $gateway
        GatewayPingOk      = $gatewayPingOk
        PublicConnectivity = Get-SupportPublicConnectivityResult
        Dns                = Test-SupportDnsResolutionDetailed
        Https              = Get-SupportHttpsConnectivityResult $proxy
        Proxy              = $proxy
    }
}

function ConvertTo-SupportNetworkDiagnosticResults {
    param($Evidence)
    $results = @()
    $adapters = @($Evidence.Adapters)
    $selected = $Evidence.SelectedAdapter
    $enabledAdapters = @($adapters | Where-Object { $_.Enabled })

    if ($Evidence.TcpIpOk) {
        $results += New-SupportDiagnosticResult '网络' 'TCP/IP 协议栈' 'PASS' '本机回环通信正常' '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '网络' 'TCP/IP 协议栈' 'FAIL' '本机回环通信失败' 'TCP/IP 协议栈可能异常或 Winsock 配置损坏。' '建议重置 Winsock/TCP/IP，并重启电脑后重新检测。' 'ResetTcpIp'
    }

    if ($adapters.Count -eq 0) {
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'FAIL' '未检测到网络适配器' '系统没有识别到可用网卡，或网卡驱动未正常安装。' '检查设备管理器中的网卡状态，确认无线开关和驱动正常。' ''
    }
    elseif ($enabledAdapters.Count -eq 0) {
        $adapterNames = @($adapters | ForEach-Object { $_.Name }) -join '; '
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'FAIL' ('检测到网卡但均已禁用：' + $adapterNames) '所有网络适配器当前均处于禁用状态。' '在“网络连接”或设备管理器中启用需要的网卡。' ''
    }
    elseif (-not $selected) {
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'WARNING' ('检测到 ' + $enabledAdapters.Count + ' 个已启用网卡，但无法确定主网卡') '系统可能处于多网卡切换状态。' '检查网线、Wi-Fi 和网络适配器状态。' ''
    }
    elseif (-not $selected.Enabled) {
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'FAIL' ($selected.Name + '：' + $selected.Status + '；MAC：' + $selected.MacAddress) '主网络适配器已被禁用。' '启用该网络适配器后重新检测。' ''
    }
    elseif (-not $selected.Connected) {
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'FAIL' ($selected.Name + '：' + $selected.Status + '；MAC：' + $selected.MacAddress) '本地网络适配器已启用，但链路状态不是 Up。' '检查网线、Wi-Fi 开关、AP/交换机端口和网卡驱动。' 'RestartAdapter'
    }
    else {
        $results += New-SupportDiagnosticResult '网络' '网络适配器' 'PASS' ($selected.Name + '：' + $selected.Status + '；MAC：' + $selected.MacAddress) '' ''
    }

    $validIps = @()
    $apipaIps = @()
    foreach ($ad in $enabledAdapters) {
        foreach ($ip in $ad.IPAddresses) {
            if ($ip -match '^127\.') { continue }
            if ($ip -match '^169\.254\.') { $apipaIps += $ip }
            else { $validIps += $ip }
        }
    }

    $ipSource = $selected
    if (-not $ipSource -and $enabledAdapters.Count -gt 0) { $ipSource = $enabledAdapters[0] }
    $maskText = ''
    $dnsText = ''
    $dhcpText = ''
    if ($ipSource) {
        if ($ipSource.SubnetMasks.Count -gt 0) { $maskText = ($ipSource.SubnetMasks -join ', ') }
        if ($ipSource.DnsServers.Count -gt 0) { $dnsText = ($ipSource.DnsServers -join ', ') }
        if ($ipSource.DhcpEnabled) { $dhcpText = 'DHCP 已启用' } else { $dhcpText = '静态 IP 或 DHCP 未启用' }
    }

    if ($validIps.Count -gt 0) {
        $ipText = 'IPv4：' + (($validIps | Select-Object -Unique) -join ', ')
        if ($maskText) { $ipText += '；子网掩码：' + $maskText }
        if ($dnsText) { $ipText += '；DNS：' + $dnsText }
        if ($dhcpText) { $ipText += '；' + $dhcpText }
        $results += New-SupportDiagnosticResult '网络' 'IP 配置' 'PASS' $ipText '' ''
    }
    elseif ($apipaIps.Count -gt 0) {
        $results += New-SupportDiagnosticResult '网络' 'IP 配置' 'FAIL' ('仅获得 APIPA 地址：' + (($apipaIps | Select-Object -Unique) -join ', ')) '设备未能从 DHCP 获得有效 IPv4 地址。' '检查网线/Wi-Fi、DHCP 服务或路由器，并尝试重新获取 IP。' 'RenewIp'
    }
    else {
        $results += New-SupportDiagnosticResult '网络' 'IP 配置' 'FAIL' '没有有效的 IPv4 地址' '设备当前没有获得可用 IP 地址。' '检查 DHCP、网线/Wi-Fi 连接，或尝试重新获取 IP。' 'RenewIp'
    }

    if ($Evidence.Gateway) {
        $results += New-SupportDiagnosticResult '网络' '默认网关' 'PASS' ('网关：' + $Evidence.Gateway) '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '网络' '默认网关' 'FAIL' '未获取到默认网关' 'IPv4 配置中没有默认路由，设备无法跨网段访问。' '重新获取 IP；如为静态配置，请检查网关地址。' 'RenewIp'
    }

    if (-not $Evidence.Gateway) {
        $results += New-SupportDiagnosticResult '网络' '网关连通性' 'INFO' '未配置默认网关，未执行网关探测' '' ''
    }
    elseif ($Evidence.GatewayPingOk) {
        $results += New-SupportDiagnosticResult '网络' '网关连通性' 'PASS' ('可以 Ping 通 ' + $Evidence.Gateway) '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '网络' '网关连通性' 'WARNING' ('Ping ' + $Evidence.Gateway + ' 超时') '网关可能不可达，也可能只是屏蔽了 ICMP Ping；需要结合公网检测结果判断。' '若公网也不可访问，请检查局域网、交换机/AP、网关配置。' ''
    }

    if ($Evidence.PublicConnectivity.Success) {
        $results += New-SupportDiagnosticResult '网络' '公网连通性' 'PASS' $Evidence.PublicConnectivity.Detail '' ''
    }
    elseif ($Evidence.Https.Success -and $Evidence.Https.Mode -eq 'SystemProxy') {
        $results += New-SupportDiagnosticResult '网络' '公网连通性' 'INFO' '公网直连探测失败，但 HTTPS 已经通过系统代理访问成功' '代理环境会改变公网路径，直连探测结果不能用于判断网卡故障。' ''
    }
    elseif ($Evidence.Https.Success) {
        $results += New-SupportDiagnosticResult '网络' '公网连通性' 'INFO' '公网直连 Ping/TCP 探测失败，但 HTTPS 应用层访问正常' 'Ping 和裸 TCP 探测可能被网络策略阻断，不足以判定网络故障。' ''
    }
    else {
        $results += New-SupportDiagnosticResult '网络' '公网连通性' 'FAIL' $Evidence.PublicConnectivity.Detail '公网直连和 HTTPS 应用层访问均失败。' '检查路由、防火墙、代理和上游网络，或联系网络管理员。' ''
    }

    if ($Evidence.Dns.Success) {
        $results += New-SupportDiagnosticResult '网络' 'DNS 解析' 'PASS' $Evidence.Dns.Summary '' ''
    }
    elseif ($Evidence.Https.Success -and $Evidence.Https.Mode -eq 'SystemProxy') {
        $results += New-SupportDiagnosticResult '网络' 'DNS 解析' 'INFO' '本机直接 DNS 解析失败，但代理 HTTPS 访问正常' '域名解析可能由代理服务器或代理客户端完成，不能据此判定本地 DNS 或网卡故障。' ''
    }
    elseif ($Evidence.Https.Success) {
        $results += New-SupportDiagnosticResult '网络' 'DNS 解析' 'WARNING' '本机直接 DNS 解析失败，但 HTTPS 应用层访问正常' '可能存在 DNS 缓存、分流或网络策略差异。' '如业务访问正常，可暂不修改 DNS；否则检查 DNS 服务器配置。' ''
    }
    else {
        $results += New-SupportDiagnosticResult '网络' 'DNS 解析' 'FAIL' $Evidence.Dns.Summary '域名无法解析为 IP 地址，且 HTTPS 应用层访问也失败。' '检查 DNS 服务器配置，或执行刷新 DNS 缓存后重新检测。' 'FlushDns'
    }

    if ($Evidence.Https.Success) {
        $httpsDiagnosis = ''
        if ($Evidence.Https.Mode -eq 'SystemProxy') {
            $httpsDiagnosis = 'HTTPS 通过 Windows 系统代理访问成功。'
        }
        $results += New-SupportDiagnosticResult '网络' 'HTTPS 访问' 'PASS' ($Evidence.Https.Target + '：' + $Evidence.Https.Detail) $httpsDiagnosis '' '' $Evidence.Https.Mode
    }
    else {
        $diagnosis = '直连和系统代理路径下的 HTTPS/TLS 访问均失败。'
        if ($Evidence.Proxy.AnyProxy) {
            $diagnosis = '检测到代理或 VPN/TUN 配置，但 HTTPS 应用层访问仍失败。'
        }
        $results += New-SupportDiagnosticResult '网络' 'HTTPS 访问' 'FAIL' $Evidence.Https.Detail $diagnosis '检查系统代理、WinHTTP 代理、VPN/TUN、防火墙、证书和企业网络策略。' ''
    }

    if ($Evidence.Proxy.AnyProxy) {
        $proxyDiagnosis = '检测到可能影响公网直连测试的代理或 VPN/TUN 配置。'
        if ($Evidence.Https.Success -and $Evidence.Https.Mode -eq 'SystemProxy') {
            $proxyDiagnosis = 'HTTPS 已通过代理成功访问，代理配置不会降低本地网络适配器状态。'
        }
        $results += New-SupportDiagnosticResult '网络' '代理设置' 'INFO' $Evidence.Proxy.Summary $proxyDiagnosis '' ''
    }
    return $results
}

function Get-SupportNetworkDiagnosticSummary {
    param($Results)
    $problemItems = @($Results | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'WARNING' })
    $problems = @()
    foreach ($item in $problemItems) {
        $problems += [pscustomobject]@{
            Name           = $item.Name
            Status         = $item.Status
            Result         = $item.Result
            Diagnosis      = $item.Diagnosis
            Recommendation = $item.Recommendation
        }
    }

    $adapterFail = @($Results | Where-Object { $_.Name -eq '网络适配器' -and $_.Status -eq 'FAIL' }).Count -gt 0
    $ipFail = @($Results | Where-Object { $_.Name -eq 'IP 配置' -and $_.Status -eq 'FAIL' }).Count -gt 0
    $gateway = $Results | Where-Object { $_.Name -eq '默认网关' } | Select-Object -First 1
    $gatewayConnectivity = $Results | Where-Object { $_.Name -eq '网关连通性' } | Select-Object -First 1
    $publicConnectivity = $Results | Where-Object { $_.Name -eq '公网连通性' } | Select-Object -First 1
    $dns = $Results | Where-Object { $_.Name -eq 'DNS 解析' } | Select-Object -First 1
    $https = $Results | Where-Object { $_.Name -eq 'HTTPS 访问' } | Select-Object -First 1
    $proxy = $Results | Where-Object { $_.Name -eq '代理设置' } | Select-Object -First 1

    $primaryDiagnosis = '网络连接正常，未发现需要优先处理的问题。'
    $recommendation = ''
    if ($adapterFail) {
        $primaryDiagnosis = '检测到网络适配器可能未正常工作。'
        $recommendation = '检查网卡状态、驱动、无线开关或物理连接。'
    }
    elseif ($ipFail) {
        $primaryDiagnosis = '设备当前没有获得有效 IPv4 地址。'
        $recommendation = '检查 DHCP、网线/Wi-Fi 连接，或尝试重新获取 IP。'
    }
    elseif ($https -and $https.Status -eq 'PASS' -and $https.AccessMode -eq 'SystemProxy') {
        $primaryDiagnosis = '本地网络适配器工作正常，检测到代理配置，公网直连测试可能受到代理影响；当前 HTTPS 网络访问正常。'
        $recommendation = '无需调整网卡；如需排查代理问题，请检查 Windows 系统代理和 WinHTTP 代理配置。'
    }
    elseif ($https -and $https.Status -eq 'PASS' -and $publicConnectivity -and $publicConnectivity.Status -eq 'INFO') {
        $primaryDiagnosis = '本地网络适配器工作正常；公网直连探测失败，但 HTTPS 应用层访问正常，不能据此判定网络故障。'
        $recommendation = '检查网络策略或代理配置是否限制 Ping/裸 TCP；优先以实际 HTTPS 访问结果为准。'
    }
    elseif ($publicConnectivity -and $publicConnectivity.Status -eq 'FAIL' -and $dns -and $dns.Status -eq 'FAIL') {
        $primaryDiagnosis = '本地适配器已获得 IP，但公网连通性和 DNS 解析均失败。'
        if ($gatewayConnectivity -and $gatewayConnectivity.Status -eq 'WARNING') {
            $primaryDiagnosis += ' 默认网关也未响应探测。'
        }
        if ($proxy) {
            $primaryDiagnosis += ' 已检测到代理或 VPN/TUN 配置，需要同时排除代理服务不可用。'
        }
        $recommendation = '检查局域网、路由、网关、代理服务和上游网络。'
    }
    elseif ($publicConnectivity -and $publicConnectivity.Status -eq 'FAIL') {
        $primaryDiagnosis = '本地网络适配器状态正常，但公网访问失败。'
        if ($proxy) {
            $primaryDiagnosis += ' 已检测到代理或 VPN/TUN 配置，不能据此判定网卡故障。'
            $recommendation = '检查代理服务器、WinHTTP 代理、VPN/TUN 状态和上游网络。'
        }
        else {
            $recommendation = '检查路由、防火墙和上游网络，或联系网络管理员。'
        }
    }
    elseif ($dns -and $dns.Status -eq 'FAIL') {
        $primaryDiagnosis = '本地网络和公网访问正常，但 DNS 解析异常。'
        $recommendation = '检查 DNS 服务器配置，或执行刷新 DNS 缓存。'
    }
    elseif ($dns -and $dns.Status -eq 'WARNING' -and $https -and $https.Status -eq 'PASS') {
        $primaryDiagnosis = '本地网络适配器工作正常；直接 DNS 测试异常，但 HTTPS 应用层访问正常。'
        $recommendation = '如业务访问正常，可暂不修改 DNS；持续异常时检查 DNS 分流、缓存和企业网络策略。'
    }
    elseif ($https -and $https.Status -eq 'FAIL') {
        $primaryDiagnosis = '本地网络适配器工作正常，但 HTTPS 应用层访问失败。'
        $recommendation = '检查系统代理、WinHTTP 代理、VPN/TUN、防火墙、证书和企业网络策略。'
    }
    elseif ($gatewayConnectivity -and $gatewayConnectivity.Status -eq 'WARNING') {
        $primaryDiagnosis = '网络可用，但默认网关未响应 Ping。'
        $recommendation = '公网可达时通常说明网关屏蔽了 ICMP，不影响使用；若业务异常再检查网关策略。'
    }
    elseif ($gateway -and $gateway.Status -eq 'FAIL') {
        $primaryDiagnosis = '网络已连接但没有有效的默认网关。'
        $recommendation = '重新获取 IP；如为静态配置，请检查网关地址。'
    }
    elseif ($proxy) {
        $primaryDiagnosis = '本地网络访问正常，检测到代理配置；本地网络适配器工作正常。'
        $recommendation = '如代理业务异常，请检查 Windows 系统代理和 WinHTTP 代理设置。'
    }

    return [pscustomobject]@{
        IsHealthy        = ($problemItems.Count -eq 0)
        PrimaryDiagnosis = $primaryDiagnosis
        Recommendation   = $recommendation
        Problems         = @($problems)
    }
}

function Write-SupportDiagnosticResults {
    param($Results)
    foreach ($r in $Results) {
        $color = Get-SupportStatusColor $r.Status
        $line = '[' + $r.Status + '] ' + $r.Name
        if ($r.Result) { $line += '：' + $r.Result }
        Write-Host $line -ForegroundColor $color
        if ($r.Diagnosis) {
            Write-Host ('  诊断：' + $r.Diagnosis) -ForegroundColor Gray
        }
        if ($r.Recommendation) {
            Write-Host ('  建议：' + $r.Recommendation) -ForegroundColor Gray
        }
    }
}

function Get-SupportNetworkRecommendedAction {
    param($Results)
    $adapter = $Results | Where-Object { $_.Name -eq '网络适配器' -and $_.Status -eq 'FAIL' -and $_.ActionCode -eq 'RestartAdapter' } | Select-Object -First 1
    if ($adapter) {
        return [pscustomobject]@{
            Code      = 'RestartAdapter'
            MenuText  = '执行建议修复：重启主要网络适配器'
            Target    = ''
        }
    }
    $ip = $Results | Where-Object { $_.Name -eq 'IP 配置' -and $_.Status -eq 'FAIL' } | Select-Object -First 1
    if ($ip) {
        return [pscustomobject]@{
            Code      = 'RenewIp'
            MenuText  = '执行建议修复：重新获取 IP'
            Target    = ''
        }
    }
    $dns = $Results | Where-Object { $_.Name -eq 'DNS 解析' -and $_.Status -eq 'FAIL' } | Select-Object -First 1
    if ($dns) {
        return [pscustomobject]@{
            Code      = 'FlushDns'
            MenuText  = '执行建议修复：刷新 DNS 缓存'
            Target    = ''
        }
    }
    return $null
}

function Invoke-SupportNetworkRecommendedAction {
    param(
        $Action,
        [switch]$SkipConfirmation
    )
    switch ($Action.Code) {
        'FlushDns' { return [bool](Invoke-NetworkFlushDns) }
        'RenewIp' { return [bool](Invoke-NetworkRenewIp -SkipConfirmation:$SkipConfirmation) }
        'RestartAdapter' { return [bool](Invoke-NetworkRestartAdapter -SkipConfirmation:$SkipConfirmation) }
        default { return $false }
    }
}

function Get-SupportNetworkDiagnosis {
    $evidence = Get-SupportNetworkEvidence
    return @(ConvertTo-SupportNetworkDiagnosticResults $evidence)
}

function Show-SupportNetworkDiagnosis {
    Write-SectionTitle '网络诊断'
    Write-Host '正在检测网络，请稍候...' -ForegroundColor Gray
    $currentResults = @(Get-SupportNetworkDiagnosis)
    Write-Host ''
    Write-SupportDiagnosticResults $currentResults
    $summary = Get-SupportNetworkDiagnosticSummary $currentResults
    Write-Host ''
    Write-SubTitle '诊断结论'
    Write-Host $summary.PrimaryDiagnosis -ForegroundColor Cyan
    if ($summary.Recommendation) {
        Write-Host ('建议：' + $summary.Recommendation) -ForegroundColor Gray
    }
    elseif ($summary.IsHealthy) {
        Write-Host '当前网络检测通过。' -ForegroundColor Green
    }

    while ($true) {
        $action = Get-SupportNetworkRecommendedAction $currentResults
        Write-Host ''
        if ($action) {
            Write-Host ('[1] ' + $action.MenuText)
            Write-Host '[2] 重新检测'
            Write-Host '[0] 返回'
            Write-Host ''
            $choice = Read-MenuSelection 2
            if ($choice -eq 0) { return }
            if ($choice -eq 1) {
                $beforeResults = @($currentResults)
                Write-Host ''
                $fixOk = Invoke-SupportNetworkRecommendedAction $action
                Write-Host ''
                Write-Host '正在自动重新检测网络...' -ForegroundColor Gray
                $currentResults = @(Get-SupportNetworkDiagnosis)
                Write-Host ''
                Write-SupportDiagnosticResults $currentResults
                $newSummary = Get-SupportNetworkDiagnosticSummary $currentResults
                Write-Host ''
                Write-SubTitle '修复后结论'
                Write-Host $newSummary.PrimaryDiagnosis -ForegroundColor Cyan
                if ($newSummary.Recommendation) {
                    Write-Host ('建议：' + $newSummary.Recommendation) -ForegroundColor Gray
                }

                $beforeFailures = @($beforeResults | Where-Object { $_.Status -eq 'FAIL' }).Count
                $afterFailures = @($currentResults | Where-Object { $_.Status -eq 'FAIL' }).Count
                if ($beforeFailures -gt 0 -and $afterFailures -eq 0) {
                    Write-OkText '问题已解决。'
                }
                elseif ($afterFailures -lt $beforeFailures) {
                    Write-WarnText '部分问题已解决，但仍有需要处理的异常。'
                }
                elseif ($fixOk) {
                    Write-WarnText '修复操作已执行，但问题仍然存在。'
                }
                else {
                    Write-WarnText '修复操作未成功完成，问题仍然存在。'
                }
                continue
            }
            if ($choice -eq 2) {
                Write-Host ''
                Write-Host '正在重新检测网络...' -ForegroundColor Gray
                $currentResults = @(Get-SupportNetworkDiagnosis)
                Write-Host ''
                Write-SupportDiagnosticResults $currentResults
                $summary = Get-SupportNetworkDiagnosticSummary $currentResults
                Write-Host ''
                Write-SubTitle '诊断结论'
                Write-Host $summary.PrimaryDiagnosis -ForegroundColor Cyan
                if ($summary.Recommendation) {
                    Write-Host ('建议：' + $summary.Recommendation) -ForegroundColor Gray
                }
                continue
            }
        }
        else {
            Write-Host '[1] 重新检测'
            Write-Host '[0] 返回'
            Write-Host ''
            $choice = Read-MenuSelection 1
            if ($choice -eq 0) { return }
            Write-Host ''
            Write-Host '正在重新检测网络...' -ForegroundColor Gray
            $currentResults = @(Get-SupportNetworkDiagnosis)
            Write-Host ''
            Write-SupportDiagnosticResults $currentResults
            $summary = Get-SupportNetworkDiagnosticSummary $currentResults
            Write-Host ''
            Write-SubTitle '诊断结论'
            Write-Host $summary.PrimaryDiagnosis -ForegroundColor Cyan
            if ($summary.Recommendation) {
                Write-Host ('建议：' + $summary.Recommendation) -ForegroundColor Gray
            }
            continue
        }
    }
}

# ---- 网络修复 ----

function Invoke-NetworkFlushDns {
    Write-SubTitle '刷新 DNS'
    Write-Host '正在执行 ipconfig /flushdns ...'
    $code = Invoke-SupportNativeCommand 'ipconfig.exe' @('/flushdns')
    if ($code -eq 0) {
        Write-OkText 'DNS 缓存已刷新。'
    }
    else {
        Write-ErrorText ('命令执行失败（退出码 ' + $code + '）。')
    }
    return ($code -eq 0)
}

function Invoke-NetworkRenewIp {
    param([switch]$SkipConfirmation)
    Write-SubTitle '重新获取 IP'
    if (-not $SkipConfirmation -and -not (Get-SupportConfirmation '此操作会短暂断开网络并重新获取 IP。是否继续？')) {
        Write-NoticeText '操作已取消。'
        return $false
    }
    Write-Host '正在释放 IP（ipconfig /release）...'
    $null = Invoke-SupportNativeCommand 'ipconfig.exe' @('/release')
    Write-Host '正在重新获取 IP（ipconfig /renew）...'
    $code = Invoke-SupportNativeCommand 'ipconfig.exe' @('/renew')
    if ($code -eq 0) {
        Write-OkText 'IP 已重新获取。'
        return $true
    }
    else {
        Write-WarnText '重新获取 IP 命令返回异常。如果使用静态 IP 或公司网络策略，这属于正常情况。'
        return $false
    }
}

function Invoke-NetworkResetWinsock {
    Write-SubTitle '重置 Winsock'
    Write-Host '此操作将重置 Winsock，完成后可能需要重启电脑。' -ForegroundColor Yellow
    if (-not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation '重置 Winsock 需要管理员权限。')) {
        return
    }
    Write-Host '正在执行 netsh winsock reset ...'
    $code = Invoke-SupportNativeCommand 'netsh.exe' @('winsock', 'reset')
    if ($code -eq 0) {
        Write-OkText 'Winsock 已重置。建议重启电脑后再次检测网络。'
    }
    else {
        Write-ErrorText ('重置 Winsock 失败（退出码 ' + $code + '）。')
    }
}

function Invoke-NetworkResetTcpIp {
    Write-SubTitle '重置 TCP/IP'
    Write-Host '此操作将重置 TCP/IP 协议栈，完成后可能需要重启电脑。' -ForegroundColor Yellow
    if (-not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation '重置 TCP/IP 需要管理员权限。')) {
        return
    }
    Write-Host '正在执行 netsh int ip reset ...'
    $code = Invoke-SupportNativeCommand 'netsh.exe' @('int', 'ip', 'reset')
    if ($code -eq 0) {
        Write-OkText 'TCP/IP 已重置。建议重启电脑后再次检测网络。'
    }
    else {
        Write-ErrorText ('重置 TCP/IP 失败（退出码 ' + $code + '）。')
    }
}

function Get-SupportDefaultNetworkAdapter {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $ad = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ad) { return $ad }
        }
    }
    catch {}
    try {
        $states = @(Get-SupportNetworkAdapterState)
        $primaryState = Get-SupportPrimaryNetworkAdapterState $states
        if ($primaryState -and $primaryState.Name) {
            $adState = Get-NetAdapter -Name $primaryState.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adState) { return $adState }
        }
    }
    catch {}
    try {
        $adapters = @(Get-SupportNetworkAdapterInfo)
        if ($adapters.Count -gt 0) {
            $primary = $adapters[0]
            $ad2 = Get-NetAdapter -Name $primary.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ad2) { return $ad2 }
        }
    }
    catch {}
    return $null
}

function Invoke-NetworkRestartAdapter {
    param([switch]$SkipConfirmation)
    Write-SubTitle '重启网络适配器'
    $ad = Get-SupportDefaultNetworkAdapter
    if (-not $ad) {
        Write-WarnText '无法确定要重启的网络适配器。'
        return $false
    }
    Write-Host ('将重启网卡：' + $ad.Name + '（' + $ad.InterfaceDescription + '）')
    Write-Host '重启过程中网络会暂时断开。' -ForegroundColor Yellow
    if (-not $SkipConfirmation -and -not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return $false
    }
    if (-not (Confirm-SupportAdminOperation '重启网卡需要管理员权限。')) {
        return $false
    }
    try {
        Write-Host '正在禁用网卡...'
        Disable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 5
        Write-Host '正在启用网卡...'
        Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
        Write-Host '正在等待网络重新获取 IP ...'
        Start-Sleep -Seconds 8
        Write-OkText '网卡已重启。'
        return $true
    }
    catch {
        Write-ErrorText ('重启网卡失败：' + $_.Exception.Message)
        Write-Log ('重启网卡失败: ' + $_.Exception.Message) 'ERROR'
        try {
            Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {}
        return $false
    }
}

function Invoke-NetworkCommonFix {
    Write-SectionTitle '常见网络问题一键修复'
    Write-Host '将依次执行以下步骤：' -ForegroundColor Yellow
    Write-Host '  1. 释放并重新获取 IP（DHCP）'
    Write-Host '  2. 刷新 DNS 缓存'
    Write-Host '  3. 重置 Winsock'
    Write-Host '  4. 重置 TCP/IP'
    Write-Host '  5. 重启主要网络适配器'
    Write-Host ''
    Write-Host '期间网络会暂时中断，全部完成后可能需要重启电脑。' -ForegroundColor Yellow
    if (-not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation '一键网络修复需要管理员权限。')) {
        return
    }

    Write-Host ''
    Write-Host '[1/5] 释放并重新获取 IP ...'
    $null = Invoke-SupportNativeCommand 'ipconfig.exe' @('/release')
    $null = Invoke-SupportNativeCommand 'ipconfig.exe' @('/renew')

    Write-Host '[2/5] 刷新 DNS 缓存 ...'
    $null = Invoke-SupportNativeCommand 'ipconfig.exe' @('/flushdns')

    Write-Host '[3/5] 重置 Winsock ...'
    $null = Invoke-SupportNativeCommand 'netsh.exe' @('winsock', 'reset')

    Write-Host '[4/5] 重置 TCP/IP ...'
    $null = Invoke-SupportNativeCommand 'netsh.exe' @('int', 'ip', 'reset')

    Write-Host '[5/5] 重启主要网络适配器 ...'
    $ad = Get-SupportDefaultNetworkAdapter
    if ($ad) {
        try {
            Disable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 5
            Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop
            Write-Host '等待网络重新连接 ...'
            Start-Sleep -Seconds 10
        }
        catch {
            Write-WarnText ('重启网卡时出现问题：' + $_.Exception.Message)
            try { Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        }
    }
    else {
        Write-WarnText '未找到可重启的主要网卡，跳过此步骤。'
    }

    Write-Host ''
    Write-SubTitle '修复后重新检测网络'
    $results = @(Get-SupportNetworkDiagnosis)
    Write-Host ''
    Write-SupportDiagnosticResults $results
    $summary = Get-SupportNetworkDiagnosticSummary $results
    Write-Host ''
    Write-Host $summary.PrimaryDiagnosis -ForegroundColor Cyan
    if ($summary.Recommendation) {
        Write-Host ('建议：' + $summary.Recommendation) -ForegroundColor Gray
    }
    $stillBad = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    if ($stillBad -gt 0) {
        Write-Host ''
        Write-WarnText ('修复后仍有 ' + $stillBad + ' 项异常。如果重启电脑后仍无法上网，请继续使用「网络诊断」或联系网络管理员。')
    }
    else {
        Write-Host ''
        Write-OkText '网络修复完成，当前网络检测通过。'
    }
}

function Show-NetworkRepairMenu {
    while ($true) {
        Write-SectionTitle '网络修复'
        Write-Host '[1] 刷新 DNS'
        Write-Host '[2] 重新获取 IP'
        Write-Host '[3] 重置 Winsock'
        Write-Host '[4] 重置 TCP/IP'
        Write-Host '[5] 重启网络适配器'
        Write-Host '[6] 常见网络问题一键修复'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 6
        Write-Host ''
        switch ($choice) {
            1 { [void](Invoke-NetworkFlushDns) }
            2 { [void](Invoke-NetworkRenewIp) }
            3 { Invoke-NetworkResetWinsock }
            4 { Invoke-NetworkResetTcpIp }
            5 { [void](Invoke-NetworkRestartAdapter) }
            6 { Invoke-NetworkCommonFix }
            0 { return }
        }
        Write-PressAnyKeyToReturn
    }
}

function Show-NetworkMenu {
    while ($true) {
        Write-SectionTitle '网络'
        Write-Host '[1] 查看网络信息'
        Write-Host '[2] 网络环境'
        Write-Host '[3] 网络诊断'
        Write-Host '[4] 网络修复'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 4
        Write-Host ''
        switch ($choice) {
            1 {
                Show-SupportNetworkInfo
                Write-PressAnyKeyToReturn
            }
            2 {
                Show-SupportNetworkEnvironment
                Write-PressAnyKeyToReturn
            }
            3 {
                Show-SupportNetworkDiagnosis
                Write-PressAnyKeyToReturn
            }
            4 { Show-NetworkRepairMenu }
            0 { return }
        }
    }
}

# ===========================================================================
# 打印机
# ===========================================================================

function Get-SupportPrinterStatusText {
    param([int]$PrinterStatus)
    switch ($PrinterStatus) {
        1 { return '其他' }
        2 { return '未知' }
        3 { return '空闲' }
        4 { return '正在打印' }
        5 { return '预热中' }
        6 { return '已停止' }
        7 { return '离线' }
        default { return ('状态码 ' + $PrinterStatus) }
    }
}

function Get-SupportPrinters {
    $result = @()
    try {
        $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
        foreach ($p in $printers) {
            $statusText = Get-SupportPrinterStatusText ([int]$p.PrinterStatus)
            if ($p.WorkOffline) {
                $statusText = '离线（脱机使用）'
            }
            $result += [pscustomobject]@{
                Name       = $p.Name
                IsDefault  = [bool]$p.Default
                DriverName = $p.DriverName
                PortName   = $p.PortName
                Status     = $statusText
                Location   = $p.Location
                PrinterStatus = [int]$p.PrinterStatus
            }
        }
    }
    catch {}
    return $result
}

function Get-SupportSpoolerStatus {
    try {
        $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
        if ($svc) {
            return [pscustomobject]@{
                Exists = $true
                Status = $svc.Status
                StartType = $svc.StartType
                Text = ('Print Spooler：' + $svc.Status)
            }
        }
    }
    catch {}
    return [pscustomobject]@{
        Exists = $false
        Status = 'NotPresent'
        StartType = ''
        Text = 'Print Spooler 服务不存在'
    }
}

function Get-SupportPrinterJobs {
    $result = @()
    try {
        $jobs = @(Get-CimInstance -ClassName Win32_PrintJob -ErrorAction SilentlyContinue)
        foreach ($job in $jobs) {
            $printerName = ''
            if ($job.Name -match '^([^,]+),') {
                $printerName = $matches[1]
            }
            $result += [pscustomobject]@{
                PrinterName = $printerName
                Document    = $job.Document
                Owner       = $job.Owner
                JobStatus   = $job.JobStatus
                Pages       = $job.PagesPrinted
                TotalPages  = $job.TotalPages
                CimObject   = $job
            }
        }
    }
    catch {}
    return $result
}

function Show-SupportPrinterList {
    Write-SectionTitle '已安装打印机'
    $printers = @(Get-SupportPrinters)
    if ($printers.Count -eq 0) {
        Write-NoticeText '未检测到打印机。'
        return
    }
    $defaultSet = $false
    foreach ($p in $printers) {
        $defaultMark = ''
        if ($p.IsDefault) {
            $defaultMark = '（默认）'
            $defaultSet = $true
        }
        Write-Host ('- ' + $p.Name + $defaultMark)
        Write-Host ('  状态：' + $p.Status)
        if ($p.DriverName) {
            Write-Host ('  驱动：' + $p.DriverName)
        }
        if ($p.PortName) {
            Write-Host ('  端口：' + $p.PortName)
        }
        if ($p.Location) {
            Write-Host ('  位置：' + $p.Location)
        }
    }
    if (-not $defaultSet) {
        Write-Host ''
        Write-WarnText '当前没有设置默认打印机。'
    }
}

function Show-SupportPrinterQueue {
    Write-SectionTitle '打印队列'
    $spooler = Get-SupportSpoolerStatus
    Write-Host ($spooler.Text)
    if (-not $spooler.Exists) {
        Write-WarnText 'Print Spooler 服务不存在，无法查看打印队列。'
        return
    }
    if ($spooler.Status -ne 'Running') {
        Write-WarnText 'Print Spooler 服务未运行，队列中的任务不会打印。'
        return
    }
    $jobs = @(Get-SupportPrinterJobs)
    if ($jobs.Count -eq 0) {
        Write-OkText '打印队列为空，没有待打印任务。'
        return
    }
    Write-Host ''
    Write-Host ('共 ' + $jobs.Count + ' 个打印任务：')
    foreach ($job in $jobs) {
        $printerText = $job.PrinterName
        if (-not $printerText) { $printerText = '未知打印机' }
        $pageText = ''
        if ($job.TotalPages -gt 0) {
            $pageText = ('（已打印 ' + $job.Pages + '/' + $job.TotalPages + ' 页）')
        }
        Write-Host ('- [' + $printerText + '] ' + $job.Document + '，用户：' + $job.Owner + $pageText)
        if ($job.JobStatus) {
            Write-Host ('  状态：' + $job.JobStatus)
        }
    }
}

function Invoke-SupportClearPrintQueue {
    Write-SectionTitle '清理打印队列'
    $spooler = Get-SupportSpoolerStatus
    if (-not $spooler.Exists) {
        Write-WarnText 'Print Spooler 服务不存在。'
        return
    }
    if ($spooler.Status -ne 'Running') {
        Write-Host 'Print Spooler 服务未运行，先尝试启动服务...'
        try {
            Start-Service -Name Spooler -ErrorAction Stop
            Write-OkText 'Print Spooler 服务已启动。'
        }
        catch {
            Write-WarnText ('无法启动服务：' + $_.Exception.Message)
            return
        }
    }

    $jobs = @(Get-SupportPrinterJobs)
    if ($jobs.Count -eq 0) {
        Write-OkText '打印队列为空，无需清理。'
        return
    }
    Write-Host ('当前共有 ' + $jobs.Count + ' 个打印任务。')
    if (-not (Get-SupportConfirmation '删除全部打印任务后，文档需要重新发送打印。是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    $removed = 0
    $failed = 0
    foreach ($job in $jobs) {
        try {
            Remove-CimInstance -InputObject $job.CimObject -ErrorAction Stop
            $removed++
        }
        catch {
            $failed++
        }
    }
    Write-Host ''
    if ($removed -gt 0) {
        Write-OkText ('已删除 ' + $removed + ' 个打印任务。')
    }
    if ($failed -gt 0) {
        Write-WarnText ($failed + ' 个任务删除失败，可能是权限不足或任务正在使用中。')
    }
    if ((@(Get-SupportPrinterJobs)).Count -eq 0) {
        Write-OkText '打印队列已清空。'
    }
}

function Invoke-SupportRestartSpooler {
    Write-SectionTitle '重启打印服务'
    if (-not (Confirm-SupportAdminOperation '重启 Print Spooler 需要管理员权限。')) {
        return
    }
    $spooler = Get-SupportSpoolerStatus
    if (-not $spooler.Exists) {
        Write-WarnText 'Print Spooler 服务不存在，无法重启。'
        return
    }
    Write-Host '正在停止 Print Spooler ...'
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        Write-Host '正在启动 Print Spooler ...'
        Start-Service -Name Spooler -ErrorAction Stop
        Write-OkText 'Print Spooler 已重启。'
    }
    catch {
        Write-ErrorText ('重启打印服务失败：' + $_.Exception.Message)
        Write-Log ('重启 Spooler 失败: ' + $_.Exception.Message) 'ERROR'
        try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-SupportPrinterOneKeyFix {
    Write-SectionTitle '一键修复打印机'
    Write-Host '本功能不会修改打印机驱动，仅检查服务和队列。' -ForegroundColor Gray
    Write-Host ''

    Write-Host '[1/4] 检查 Print Spooler 服务 ...'
    $spooler = Get-SupportSpoolerStatus
    if (-not $spooler.Exists) {
        Write-ErrorText 'Print Spooler 服务不存在，无法继续。'
        return
    }
    if ($spooler.Status -eq 'Running') {
        Write-OkText 'Print Spooler 运行正常。'
    }
    else {
        Write-WarnText ('Print Spooler 状态为 ' + $spooler.Status + '。')
    }

    Write-Host ''
    Write-Host '[2/4] 检查打印队列 ...'
    $jobs = @(Get-SupportPrinterJobs)
    if ($jobs.Count -eq 0) {
        Write-OkText '打印队列为空。'
    }
    else {
        Write-WarnText ('发现 ' + $jobs.Count + ' 个打印任务。')
        if (Get-SupportConfirmation '删除全部打印任务？删除后文档需要重新发送打印。') {
            foreach ($job in $jobs) {
                try {
                    Remove-CimInstance -InputObject $job.CimObject -ErrorAction Stop
                }
                catch {}
            }
            if ((@(Get-SupportPrinterJobs)).Count -eq 0) {
                Write-OkText '打印队列已清空。'
            }
            else {
                Write-WarnText '部分打印任务删除失败（可能权限不足）。'
            }
        }
    }

    Write-Host ''
    Write-Host '[3/4] 重启 Print Spooler ...'
    if (Test-SupportAdmin) {
        try {
            Stop-Service -Name Spooler -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Start-Service -Name Spooler -ErrorAction Stop
            Write-OkText 'Print Spooler 已重启。'
        }
        catch {
            Write-ErrorText ('重启失败：' + $_.Exception.Message)
            try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch {}
        }
    }
    else {
        Write-WarnText '当前不是管理员，无法重启 Print Spooler。'
        if (Confirm-SupportAdminOperation '一键修复打印机需要管理员权限。') {
            return
        }
    }

    Write-Host ''
    Write-Host '[4/4] 重新检查打印机 ...'
    $printers = @(Get-SupportPrinters)
    if ($printers.Count -eq 0) {
        Write-NoticeText '未检测到打印机。'
        return
    }
    $offline = @($printers | Where-Object { $_.Status -match '离线|停止' }).Count
    foreach ($p in $printers) {
        $mark = ''
        if ($p.IsDefault) { $mark = '（默认）' }
        if ($p.Status -match '离线|停止') {
            Write-ErrorText ($p.Name + $mark + ' - ' + $p.Status)
        }
        else {
            Write-OkText ($p.Name + $mark + ' - ' + $p.Status)
        }
    }
    if ($offline -gt 0) {
        Write-Host ''
        Write-WarnText ('仍有 ' + $offline + ' 台打印机离线或停止。请检查打印机电源、连接线和驱动状态。')
    }
}

function Get-SupportPrinterRepairScripts {
    return @(
        [pscustomobject]@{
            Id = 1
            Name = '打印组件深度修复（3 个系统文件）'
            RelativePath = 'PrinterRepairScripts\DeepRepair\repair-printer-components.bat'
            Warning = '将停止 Print Spooler，并替换 localspl.dll、win32spl.dll、spoolsv.exe；脚本会创建备份文件。'
        }
        [pscustomobject]@{
            Id = 2
            Name = 'win32spl.dll 修复 + RPC 打印兼容设置'
            RelativePath = 'PrinterRepairScripts\Win32SplRpcRepair\repair-win32spl-rpc.bat'
            Warning = '将停止 Print Spooler、替换 win32spl.dll，并将 RpcAuthnLevelPrivacyEnabled 设置为 0。'
        }
    )
}

function Invoke-SupportPrinterRepairScript {
    param([int]$ScriptId)
    $scriptInfo = Get-SupportPrinterRepairScripts | Where-Object { $_.Id -eq $ScriptId } | Select-Object -First 1
    if (-not $scriptInfo) {
        Write-ErrorText '未找到指定的打印机修复程序。'
        return $false
    }
    $scriptPath = Join-Path $script:ScriptRoot $scriptInfo.RelativePath
    if (-not (Test-SupportPathExists $scriptPath)) {
        Write-ErrorText ('修复脚本不存在：' + $scriptPath)
        Write-Log ('打印机修复脚本不存在: ' + $scriptPath) 'ERROR'
        return $false
    }
    Write-SectionTitle $scriptInfo.Name
    Write-WarnText $scriptInfo.Warning
    Write-WarnText '这是系统级修复操作，可能影响当前打印任务和 Print Spooler；请确认脚本来源可信。'
    if (-not (Confirm-SupportAdminOperation '运行打印机系统文件修复脚本。')) { return $false }
    if (-not (Get-SupportConfirmation '确认继续执行该修复程序？')) {
        Write-NoticeText '操作已取消。'
        return $false
    }
    try {
        Write-Host '正在启动修复程序，完成后请关闭脚本窗口返回工具...' -ForegroundColor Gray
        $argumentList = @('/d', '/c', 'call', ('"' + $scriptPath + '"'))
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList $argumentList -WorkingDirectory (Split-Path -Parent $scriptPath) -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Write-OkText '打印机修复程序已执行完成。'
            Write-Log ('打印机修复程序执行完成: ' + $scriptInfo.Name) 'INFO'
            return $true
        }
        Write-WarnText ('打印机修复程序返回退出码 ' + $process.ExitCode + '，请查看脚本窗口中的具体信息。')
        Write-Log ('打印机修复程序返回退出码 ' + $process.ExitCode + ': ' + $scriptInfo.Name) 'WARN'
        return $false
    }
    catch {
        Write-ErrorText ('启动打印机修复程序失败：' + $_.Exception.Message)
        Write-Log ('启动打印机修复程序失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Show-SupportPrinterRepairMenu {
    while ($true) {
        Write-SectionTitle '打印机修复'
        Write-Host '[1] 一键修复打印机（服务和队列）'
        Write-Host '[2] 打印组件深度修复（替换 3 个系统文件）'
        Write-Host '[3] win32spl.dll 修复 + RPC 打印兼容设置'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        if ($choice -eq 0) { return }
        Write-Host ''
        switch ($choice) {
            1 { Invoke-SupportPrinterOneKeyFix; Write-PressAnyKeyToReturn }
            2 { Invoke-SupportPrinterRepairScript -ScriptId 1; Write-PressAnyKeyToReturn }
            3 { Invoke-SupportPrinterRepairScript -ScriptId 2; Write-PressAnyKeyToReturn }
        }
    }
}

function Show-PrinterMenu {
    while ($true) {
        Write-SectionTitle '打印机'
        Write-Host '[1] 查看打印机'
        Write-Host '[2] 查看打印队列'
        Write-Host '[3] 清理打印队列'
        Write-Host '[4] 重启打印服务'
        Write-Host '[5] 打印机修复'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 5
        Write-Host ''
        switch ($choice) {
            1 {
                Show-SupportPrinterList
                Write-PressAnyKeyToReturn
            }
            2 {
                Show-SupportPrinterQueue
                Write-PressAnyKeyToReturn
            }
            3 {
                Invoke-SupportClearPrintQueue
                Write-PressAnyKeyToReturn
            }
            4 {
                Invoke-SupportRestartSpooler
                Write-PressAnyKeyToReturn
            }
            5 {
                Show-SupportPrinterRepairMenu
            }
            0 { return }
        }
    }
}

# ===========================================================================
# 磁盘
# ===========================================================================

function Get-SupportDiskInfo {
    $result = @()
    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -eq 3 -or $_.DriveType -eq 2 })
        foreach ($d in $disks) {
            $total = 0L
            $free = 0L
            try { $total = [long]$d.Size } catch {}
            try { $free = [long]$d.FreeSpace } catch {}
            if ($total -le 0) { continue }
            $used = $total - $free
            $usedPercent = ([double]$used / [double]$total) * 100.0
            $result += [pscustomobject]@{
                DriveLetter     = $d.DeviceID
                VolumeName      = $d.VolumeName
                FileSystem      = $d.FileSystem
                TotalBytes      = $total
                FreeBytes       = $free
                UsedBytes       = $used
                UsedPercent     = $usedPercent
                TotalText       = Format-SupportByteSize $total
                FreeText        = Format-SupportByteSize $free
                UsedText        = Format-SupportByteSize $used
                UsedPercentText = Format-SupportPercent $usedPercent
                DriveType       = $d.DriveType
            }
        }
    }
    catch {}
    return @($result | Sort-Object DriveLetter)
}

function Show-SupportDiskSpace {
    Write-SectionTitle '磁盘空间'
    $disks = @(Get-SupportDiskInfo)
    if ($disks.Count -eq 0) {
        Write-WarnText '未获取到磁盘信息。'
        return
    }
    foreach ($d in $disks) {
        $name = $d.DriveLetter
        if ($d.VolumeName) {
            $name += ' (' + $d.VolumeName + ')'
        }
        Write-Host ('- ' + $name)
        Write-Host ('  总容量：' + $d.TotalText)
        Write-Host ('  已使用：' + $d.UsedText + '（' + $d.UsedPercentText + '）')
        Write-Host ('  剩余：' + $d.FreeText)
        $barLength = 20
        $filled = [math]::Floor([double]$d.UsedPercent / 100.0 * $barLength)
        if ($filled -lt 0) { $filled = 0 }
        if ($filled -gt $barLength) { $filled = $barLength }
        $bar = ('#' * $filled) + ('.' * ($barLength - $filled))
        $barColor = 'Green'
        if ($d.UsedPercent -ge 90) { $barColor = 'Red' }
        elseif ($d.UsedPercent -ge 75) { $barColor = 'Yellow' }
        Write-Host ('  使用：[{0}] {1}' -f $bar, $d.UsedPercentText) -ForegroundColor $barColor
        Write-Host ''
    }
}

function Get-SupportDirectorySize {
    param([string]$Path)
    $result = [pscustomobject]@{
        Path      = $Path
        Exists    = $false
        Bytes     = 0L
        FileCount = 0
        ErrorCount = 0
        SizeText  = '不存在'
    }
    if (-not (Test-SupportPathExists $Path)) {
        return $result
    }
    $result.Exists = $true
    $totalBytes = 0L
    $fileCount = 0
    $errorCount = 0
    try {
        $stack = New-Object System.Collections.Stack
        $stack.Push($Path)
        while ($stack.Count -gt 0) {
            $dir = [string]$stack.Pop()
            try {
                foreach ($filePath in [System.IO.Directory]::EnumerateFiles($dir)) {
                    $fileCount++
                    try {
                        $fi = New-Object System.IO.FileInfo $filePath
                        $totalBytes += $fi.Length
                    }
                    catch {
                        $errorCount++
                    }
                }
            }
            catch {
                $errorCount++
            }
            try {
                foreach ($subDir in [System.IO.Directory]::EnumerateDirectories($dir)) {
                    $skip = $false
                    try {
                        $di = New-Object System.IO.DirectoryInfo $subDir
                        if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                            $skip = $true
                        }
                    }
                    catch {
                        $skip = $true
                    }
                    if (-not $skip) {
                        $stack.Push($subDir)
                    }
                }
            }
            catch {
                $errorCount++
            }
        }
    }
    catch {
        $errorCount++
    }
    $result.Bytes = $totalBytes
    $result.FileCount = $fileCount
    $result.ErrorCount = $errorCount
    $result.SizeText = Format-SupportByteSize $totalBytes
    return $result
}

function Get-SupportTempTargets {
    $targets = @()
    $seen = @{}
    $userTemp = $env:TEMP
    if ($userTemp -and -not $seen.ContainsKey($userTemp)) {
        $seen[$userTemp] = $true
        $targets += [pscustomobject]@{
            Path        = $userTemp
            Description = '当前用户临时文件'
            Safe        = $true
        }
    }
    $winTemp = Join-Path $env:WINDIR 'Temp'
    if (-not $seen.ContainsKey($winTemp)) {
        $seen[$winTemp] = $true
        $targets += [pscustomobject]@{
            Path        = $winTemp
            Description = 'Windows 系统临时文件'
            Safe        = $true
        }
    }
    $wuDownload = Join-Path $env:WINDIR (Join-Path 'SoftwareDistribution' 'Download')
    if (-not $seen.ContainsKey($wuDownload)) {
        $seen[$wuDownload] = $true
        $targets += [pscustomobject]@{
            Path        = $wuDownload
            Description = 'Windows Update 下载缓存'
            Safe        = $true
        }
    }
    return $targets
}

function Show-SupportTempScan {
    Write-SectionTitle '查找临时文件'
    Write-Host '正在扫描临时目录（文件较多时可能需要一点时间）...' -ForegroundColor Gray
    $targets = @(Get-SupportTempTargets)
    $totalBytes = 0L
    $scanResults = @()
    foreach ($t in $targets) {
        $size = Get-SupportDirectorySize $t.Path
        $scanResults += [pscustomobject]@{
            Target      = $t
            Size        = $size
        }
        $totalBytes += $size.Bytes
        $state = '不存在'
        if ($size.Exists) {
            $state = $size.SizeText
            if ($size.ErrorCount -gt 0) {
                $state += '（部分文件无法访问）'
            }
        }
        Write-Host ('- ' + $t.Description)
        Write-Host ('  ' + $t.Path)
        Write-Host ('  大小：' + $state)
        Write-Host ''
    }
    Write-Host ('可清理临时文件合计：' + (Format-SupportByteSize $totalBytes)) -ForegroundColor Yellow
    Write-NoticeText '扫描范围仅限系统/用户临时目录与 Windows Update 缓存，不会扫描 Documents、Downloads、Desktop。'
    return $scanResults
}

function Invoke-SupportTempCleanup {
    Write-SectionTitle '清理临时文件'
    $scanResults = @(Show-SupportTempScan)
    if (-not (Get-SupportConfirmation '是否删除以上临时文件？正在使用的文件会被自动跳过。')) {
        Write-NoticeText '操作已取消。'
        return
    }
    $totalDeleted = 0L
    $totalFiles = 0
    foreach ($item in $scanResults) {
        $path = $item.Target.Path
        $sizeObj = $item.Size
        if (-not $sizeObj.Exists) { continue }
        $beforeBytes = $sizeObj.Bytes
        $deletedCount = 0
        try {
            $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                try {
                    Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
                    $deletedCount++
                }
                catch {}
            }
        }
        catch {}
        $after = Get-SupportDirectorySize $path
        $deletedBytes = $beforeBytes - $after.Bytes
        if ($deletedBytes -lt 0) { $deletedBytes = 0 }
        $totalDeleted += $deletedBytes
        $totalFiles += $deletedCount
        Write-Host ('- ' + $item.Target.Description + '：清理 ' + (Format-SupportByteSize $deletedBytes)) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host ('共删除 ' + $totalFiles + ' 个项目，释放空间约 ' + (Format-SupportByteSize $totalDeleted) + '。') -ForegroundColor Green
    Write-NoticeText '锁定的文件不会被删除，可重启电脑后再次清理。'
}

function Invoke-SupportRecycleBinClean {
    Write-SectionTitle '清理回收站'
    if (-not (Get-SupportConfirmation '确定清空回收站？此操作无法撤销。')) {
        Write-NoticeText '操作已取消。'
        return
    }
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-OkText '回收站已清空。'
    }
    catch {
        Write-WarnText ('回收站可能已为空，或清理时出错：' + $_.Exception.Message)
    }
}

function Show-SupportDiskHealth {
    Write-SectionTitle '磁盘状态检查'
    $found = $false
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        if ($physical.Count -gt 0) {
            $found = $true
            foreach ($pd in $physical) {
                $health = $pd.HealthStatus
                $healthColor = 'Green'
                if ($health -notmatch '(?i)healthy') {
                    $healthColor = 'Red'
                }
                Write-Host ('- ' + $pd.FriendlyName) 
                Write-Host ('  类型：' + $pd.MediaType + '，容量：' + (Format-SupportByteSize ([long]$pd.Size)))
                Write-Host ('  健康状态：' + $health) -ForegroundColor $healthColor
                if ($pd.OperationalStatus) {
                    Write-Host ('  运行状态：' + ($pd.OperationalStatus -join ', '))
                }
                Write-Host ''
            }
        }
    }
    catch {}
    try {
        if (-not $found) {
            $diskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)
            if ($diskDrives.Count -gt 0) {
                $found = $true
                foreach ($dd in $diskDrives) {
                    Write-Host ('- ' + $dd.Model)
                    Write-Host ('  状态：' + $dd.Status)
                    if ($dd.Size) {
                        Write-Host ('  容量：' + (Format-SupportByteSize ([long]$dd.Size)))
                    }
                    Write-Host ''
                }
            }
        }
    }
    catch {}
    if (-not $found) {
        Write-WarnText '无法获取磁盘健康信息。'
    }
    Write-NoticeText '本检查仅读取磁盘状态。如需深入检查请使用磁盘厂商工具，或在管理员命令行执行 chkdsk。'
}

function Show-DiskMenu {
    while ($true) {
        Write-SectionTitle '磁盘'
        Write-Host '[1] 查看磁盘空间'
        Write-Host '[2] 查找临时文件'
        Write-Host '[3] 清理临时文件'
        Write-Host '[4] 清理回收站'
        Write-Host '[5] 磁盘状态检查'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 5
        Write-Host ''
        switch ($choice) {
            1 {
                Show-SupportDiskSpace
                Write-PressAnyKeyToReturn
            }
            2 {
                $null = Show-SupportTempScan
                Write-PressAnyKeyToReturn
            }
            3 {
                Invoke-SupportTempCleanup
                Write-PressAnyKeyToReturn
            }
            4 {
                Invoke-SupportRecycleBinClean
                Write-PressAnyKeyToReturn
            }
            5 {
                Show-SupportDiskHealth
                Write-PressAnyKeyToReturn
            }
            0 { return }
        }
    }
}

# ===========================================================================
# 软件（winget）
# ===========================================================================

function Invoke-SupportWingetCapture {
    param([string[]]$ArgumentList)
    $output = @()
    try {
        $output = @(& winget.exe @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = @($output) }
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = @($_.Exception.Message) }
    }
}

function Get-SupportWingetRows {
    param($Capture)
    $lines = @($Capture.Output | ForEach-Object { [string]$_ })
    $separatorIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{3,}') { $separatorIndex = $i; break }
    }
    if ($separatorIndex -lt 1) { return @() }
    $header = $lines[$separatorIndex - 1]
    $headerTokens = @([regex]::Matches($header, '\S+') | ForEach-Object { [pscustomobject]@{ Text = $_.Value; Index = $_.Index } })
    $columnNames = @()
    foreach ($token in $headerTokens) {
        $columnNames += [pscustomobject]@{ Name = if ($token.Text -match '(?i)^(name|名称)$') { 'Name' } elseif ($token.Text -match '(?i)^(id|package.?id|标识)$') { 'Id' } elseif ($token.Text -match '(?i)^(version|版本|installed)$') { 'Version' } elseif ($token.Text -match '(?i)^(available|可用)$') { 'Available' } elseif ($token.Text -match '(?i)^(source|来源)$') { 'Source' } else { '' }; Index = $token.Index }
    }
    $rows = @()
    for ($i = $separatorIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.Trim() -or $line -match '(?i)^(No package|没有找到|Name\s+Id|名称\s+ID|次の)' -or $line -match '(?i)^(The following|以下|This package)') { continue }
        if ($line -match '^\s*-{3,}') { continue }
        $values = @{}
        $splitValues = @($line.Trim() -split '\s{2,}')
        $knownColumnCount = @($columnNames | Where-Object { $_.Name }).Count
        if ($knownColumnCount -gt 0 -and $splitValues.Count -eq $knownColumnCount) {
            $splitIndex = 0
            for ($c = 0; $c -lt $columnNames.Count; $c++) {
                if ($columnNames[$c].Name) {
                    $values[$c] = $splitValues[$splitIndex]
                    $splitIndex++
                }
            }
        }
        elseif ($headerTokens.Count -gt 0) {
            for ($c = 0; $c -lt $headerTokens.Count; $c++) {
                $start = [int]$headerTokens[$c].Index
                if ($start -ge $line.Length) { $value = '' }
                else {
                    $end = if ($c + 1 -lt $headerTokens.Count) { [int]$headerTokens[$c + 1].Index } else { $line.Length }
                    $length = [Math]::Min($end - $start, $line.Length - $start)
                    $value = if ($length -gt 0) { $line.Substring($start, $length).Trim() } else { '' }
                }
                $values[$c] = $value
            }
        }
        $row = [ordered]@{ Name = ''; Id = ''; Version = ''; Available = ''; Source = '' }
        for ($c = 0; $c -lt $columnNames.Count; $c++) {
            $name = $columnNames[$c].Name
            if ($name -and $values.ContainsKey($c)) { $row[$name] = $values[$c] }
        }
        if (-not $row.Name -and $line.Trim()) {
            $parts = @($line.Trim() -split '\s{2,}')
            if ($parts.Count -ge 3) { $row.Name = $parts[0]; $row.Id = $parts[1]; $row.Version = $parts[2]; if ($parts.Count -ge 4) { $row.Available = $parts[3] }; if ($parts.Count -ge 5) { $row.Source = $parts[4] } }
        }
        if ($row.Name -and ($row.Id -or $row.Version)) { $rows += [pscustomobject]$row }
    }
    return @($rows)
}

function Get-SupportSoftwareDisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($char in ([string]$Text).ToCharArray()) { $width += if ([int][char]$char -lt 127) { 1 } else { 2 } }
    return $width
}

function Format-SupportSoftwareCell {
    param([string]$Text, [int]$Width)
    $value = if ($null -eq $Text) { '' } else { [string]$Text }
    $result = ''
    foreach ($char in $value.ToCharArray()) {
        $charWidth = if ([int][char]$char -lt 127) { 1 } else { 2 }
        if ((Get-SupportSoftwareDisplayWidth ($result + $char)) -gt $Width) { break }
        $result += $char
    }
    if ($result.Length -lt $value.Length -and $Width -ge 4) {
        while ((Get-SupportSoftwareDisplayWidth ($result + '...')) -gt $Width -and $result.Length -gt 0) { $result = $result.Substring(0, $result.Length - 1) }
        $result += '...'
    }
    $padding = $Width - (Get-SupportSoftwareDisplayWidth $result)
    if ($padding -gt 0) { $result += (' ' * $padding) }
    return $result
}

function Show-SupportSoftwareTable {
    param(
        [object[]]$Rows,
        [ValidateSet('Search','Installed','Upgrade')][string]$Mode = 'Search'
    )
    $items = @($Rows)
    if ($items.Count -eq 0) { Write-NoticeText '没有找到软件结果。'; return $null }
    $pageSize = 12
    $page = 0
    $windowWidth = 120
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $windowWidth = [int]$Host.UI.RawUI.WindowSize.Width } } catch {}
    $nameWidth = if ($windowWidth -lt 105) { 24 } else { 30 }
    $idWidth = if ($windowWidth -lt 105) { 24 } else { 30 }
    while ($true) {
        $start = $page * $pageSize
        $end = [Math]::Min($start + $pageSize, $items.Count)
        Write-Host ''
        switch ($Mode) {
            'Installed' { $columns = @(@('序号', 4), @('软件名称', $nameWidth), @('当前版本', 18), @('ID', $idWidth)) }
            'Upgrade' { $columns = @(@('序号', 4), @('软件名称', $nameWidth), @('当前版本', 18), @('可用版本', 18), @('ID', $idWidth)) }
            default { $columns = @(@('序号', 4), @('软件名称', $nameWidth), @('ID', $idWidth), @('版本', 18), @('来源', 12)) }
        }
        Write-Host (($columns | ForEach-Object { Format-SupportSoftwareCell $_[0] $_[1] }) -join ' ') -ForegroundColor Cyan
        $tableWidth = 0
        foreach ($column in $columns) { $tableWidth += [int]$column[1] }
        $tableWidth += ($columns.Count - 1)
        Write-Host ('-' * [Math]::Max(1, [Math]::Min($windowWidth - 2, $tableWidth))) -ForegroundColor DarkGray
        for ($i = $start; $i -lt $end; $i++) {
            $item = $items[$i]
            $number = Format-SupportSoftwareCell (($i + 1).ToString()) 4
            if ($Mode -eq 'Installed') { $cells = @($number, $item.Name, $item.Version, $item.Id) }
            elseif ($Mode -eq 'Upgrade') { $cells = @($number, $item.Name, $item.Version, $item.Available, $item.Id) }
            else { $cells = @($number, $item.Name, $item.Id, $item.Version, $item.Source) }
            $line = ''
            for ($c = 0; $c -lt $cells.Count; $c++) { $line += (Format-SupportSoftwareCell $cells[$c] $columns[$c][1]); if ($c -lt $cells.Count - 1) { $line += ' ' } }
            Write-Host $line
        }
        Write-Host ''
        Write-Host ('第 ' + ($page + 1) + ' / ' + [Math]::Ceiling($items.Count / $pageSize) + ' 页，共 ' + $items.Count + ' 条') -ForegroundColor Gray
        Write-Host '[N] 下一页  [P] 上一页  [数字] 查看详情  [0] 返回'
        $choice = Read-Host '请选择'
        if ($choice -match '^(?i)n$' -and $end -lt $items.Count) { $page++; continue }
        if ($choice -match '^(?i)p$' -and $page -gt 0) { $page--; continue }
        if ($choice -match '^\d+$') {
            $selectedNumber = [int]$choice
            if ($selectedNumber -eq 0) { return $null }
            if ($selectedNumber -ge 1 -and $selectedNumber -le $items.Count) { return $items[$selectedNumber - 1] }
        }
        Write-WarnText '输入无效，或当前没有上一页/下一页。'
    }
}

function Write-SupportSoftwareState {
    param([string]$State, [string]$Text)
    $color = if ($State -eq '失败') { 'Red' } elseif ($State -eq '完成') { 'Green' } elseif ($State -eq '可更新') { 'Yellow' } else { 'Gray' }
    Write-Host ('[' + $State + '] ' + $Text) -ForegroundColor $color
}

function Initialize-SupportWinget {
    $script:HasWinget = $false
    try {
        if (Get-Command -Name winget.exe -CommandType Application -ErrorAction SilentlyContinue) {
            $script:HasWinget = $true
        }
    }
    catch {}
    if (-not $script:HasWinget) {
        try {
            $appxWinget = Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft\WindowsApps' 'winget.exe')
            if (Test-SupportPathExists $appxWinget) {
                $script:HasWinget = $true
            }
        }
        catch {}
    }
    return $script:HasWinget
}

function Get-SupportCommonSoftware {
    if ($script:CommonSoftwareCache -ne $null) {
        return $script:CommonSoftwareCache
    }
    $script:CommonSoftwareCache = @()
    try {
        if (Test-SupportPathExists $script:SoftwareConfigFile) {
            $json = Get-Content -LiteralPath $script:SoftwareConfigFile -Raw -Encoding UTF8 -ErrorAction Stop
            $obj = $json | ConvertFrom-Json -ErrorAction Stop
            $list = @($obj.commonSoftware)
            $script:CommonSoftwareCache = $list
        }
        else {
            Write-Log ('配置文件不存在: ' + $script:SoftwareConfigFile) 'WARN'
        }
    }
    catch {
        Write-Log ('读取软件配置文件失败: ' + $_.Exception.Message) 'ERROR'
    }
    return $script:CommonSoftwareCache
}

function Show-CommonSoftwareMenu {
    while ($true) {
        $software = @(Get-SupportCommonSoftware)
        Write-SectionTitle '常用软件'
        if ($software.Count -eq 0) {
            Write-WarnText '未读取到常用软件列表。'
            Write-Host ('请检查配置文件：' + $script:SoftwareConfigFile) -ForegroundColor Gray
            Write-PressAnyKeyToReturn
            return
        }
        $categories = @('浏览器', '办公', '工具', '开发', 'Windows 官方软件', '其他')
        $numbered = @()
        $idx = 1
        foreach ($category in $categories) {
            $categoryItems = @($software | Where-Object { if ($_.Category) { $_.Category -eq $category } else { $category -eq '其他' } })
            if ($categoryItems.Count -eq 0) { continue }
            Write-Host ''
            Write-Host $category -ForegroundColor Yellow
            foreach ($item in $categoryItems) {
                $numbered += [pscustomobject]@{ Number = $idx; Item = $item }
                Write-Host ((Format-SupportSoftwareCell ('[' + $idx + ']') 6) + (Format-SupportSoftwareCell $item.Name 30) + (Format-SupportSoftwareCell $item.PackageId 30))
                if ($item.Description) { Write-Host ('      ' + $item.Description) -ForegroundColor Gray }
                $idx++
            }
        }
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection $numbered.Count
        Write-Host ''
        if ($choice -eq 0) { return }
        $selectedEntry = $numbered | Where-Object { $_.Number -eq $choice } | Select-Object -First 1
        $selected = if ($selectedEntry) { $selectedEntry.Item } else { $null }
        if (-not $selected -or -not $selected.PackageId) {
            Write-WarnText '配置文件中的软件条目无效。'
            continue
        }
        Write-Host ('将安装：' + $selected.Name + '（' + $selected.PackageId + '）')
        if ($selected.Description) {
            Write-Host ('说明：' + $selected.Description) -ForegroundColor Gray
        }
        if (Get-SupportConfirmation '是否开始安装？') {
            if ($selected.RequiresAdmin -and -not (Confirm-SupportAdminOperation '该软件通常需要管理员权限。')) {
                continue
            }
            Write-Host ('正在通过 winget 安装 ' + $selected.Name + '，请稍候...')
            $code = Invoke-SupportNativeCommand 'winget.exe' @('install', '--exact', '--id', $selected.PackageId, '--accept-source-agreements', '--accept-package-agreements')
            if ($code -eq 0) {
                Write-SupportSoftwareState '完成' ($selected.Name + ' 安装完成。')
            }
            else {
                Write-SupportSoftwareState '失败' ('winget 返回退出码 ' + $code + '，请根据上方输出检查失败原因。')
            }
        }
        Write-PressAnyKeyToReturn
    }
}

function Invoke-SoftwareSearch {
    Write-SubTitle '搜索软件'
    $keyword = Read-Host '请输入软件名称或关键字（直接回车返回）'
    if (-not $keyword) { return }
    Write-Host ''
    Write-Host '正在搜索，请稍候...'
    $capture = Invoke-SupportWingetCapture @('search', '--query', $keyword, '--accept-source-agreements')
    $rows = @(Get-SupportWingetRows $capture)
    if ($capture.ExitCode -ne 0 -and $rows.Count -eq 0) { Write-SupportSoftwareState '失败' ('winget 搜索失败，退出码 ' + $capture.ExitCode + '。') }
    elseif ($rows.Count -eq 0) { Write-SupportSoftwareState '完成' '搜索完成，但没有找到匹配软件。' }
    else {
        Write-SupportSoftwareState '完成' ('搜索完成，共找到 ' + $rows.Count + ' 个结果。')
        $selected = Show-SupportSoftwareTable $rows -Mode Search
        if ($selected) { Write-Host ''; Write-Host ('软件名称：' + $selected.Name); Write-Host ('Package ID：' + $selected.Id); Write-Host ('版本：' + $(if ($selected.Version) { $selected.Version } else { '未知' })) }
    }
}

function Invoke-SoftwareInstall {
    Write-SubTitle '安装软件'
    $package = Read-Host '请输入软件 ID 或名称（例如 Google.Chrome，直接回车返回）'
    if (-not $package) { return }
    if (-not (Get-SupportConfirmation ('是否安装：' + $package + '？'))) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Test-SupportAdmin)) {
        Write-NoticeText '当前不是管理员。如软件需要管理员权限，安装过程会提示或失败；可取消后以管理员身份重新运行本工具。'
    }
    Write-Host '正在安装，请稍候（部分软件可能弹出安装向导）...'
    $code = Invoke-SupportNativeCommand 'winget.exe' @('install', '--id', $package, '--accept-source-agreements', '--accept-package-agreements')
    if ($code -eq 0) {
        Write-SupportSoftwareState '完成' '软件安装完成。'
    }
    else {
        Write-SupportSoftwareState '失败' ('winget 返回退出码 ' + $code + '。如果 ID 不正确，请先使用「搜索软件」获取完整 ID。')
    }
}

function Invoke-SoftwareUninstall {
    Write-SubTitle '卸载软件'
    Write-SupportSoftwareState '已安装' '以下为本机 winget 可识别的已安装软件：'
    Write-Host ''
    $capture = Invoke-SupportWingetCapture @('list', '--accept-source-agreements')
    $rows = @(Get-SupportWingetRows $capture)
    $selected = $null
    if ($rows.Count -gt 0) {
        $selected = Show-SupportSoftwareTable $rows -Mode Installed
        if (-not $selected) { return }
    }
    Write-Host ''
    $package = if ($selected) { $selected.Id } else { Read-Host '请输入要卸载的软件 ID（直接回车返回）' }
    if (-not $package) { return }
    if (-not (Get-SupportConfirmation ('确定卸载：' + $package + '？'))) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation '卸载软件可能需要管理员权限。')) {
        return
    }
    Write-Host '正在卸载，请稍候...'
    $code = Invoke-SupportNativeCommand 'winget.exe' @('uninstall', '--id', $package, '--accept-source-agreements')
    if ($code -eq 0) {
        Write-SupportSoftwareState '完成' '软件已卸载。'
    }
    else {
        Write-SupportSoftwareState '失败' ('winget 返回退出码 ' + $code + '，部分软件（如 Microsoft 365）可能需要从系统设置中卸载。')
    }
}

function Invoke-SoftwareUpdate {
    Write-SubTitle '更新软件'
    Write-Host '正在检查可更新软件，请稍候...'
    $capture = Invoke-SupportWingetCapture @('upgrade', '--accept-source-agreements')
    $rows = @(Get-SupportWingetRows $capture)
    if ($rows.Count -gt 0) {
        Write-SupportSoftwareState '可更新' ('发现 ' + $rows.Count + ' 个可更新软件：')
        $updateSelection = Show-SupportSoftwareTable $rows -Mode Upgrade
        if ($null -eq $updateSelection) { return }
    }
    elseif ($capture.ExitCode -eq 0) { Write-SupportSoftwareState '完成' '当前没有可更新的软件。' }
    else { Write-SupportSoftwareState '失败' ('检查可更新软件失败，退出码 ' + $capture.ExitCode + '。') }
    Write-Host ''
    if (Get-SupportConfirmation '是否更新全部可更新的软件？更新过程可能需要较长时间。') {
        if (-not (Confirm-SupportAdminOperation '更新部分软件可能需要管理员权限。')) {
            return
        }
        Write-Host '正在更新全部软件，请稍候（可能需要较长时间）...'
        $code = Invoke-SupportNativeCommand 'winget.exe' @('upgrade', '--all', '--accept-source-agreements', '--accept-package-agreements')
        if ($code -eq 0) {
            Write-SupportSoftwareState '完成' '软件更新完成。'
        }
        else {
            Write-SupportSoftwareState '失败' ('winget 返回退出码 ' + $code + '。部分软件可能需要重启电脑或由用户完成交互。')
        }
    }
    else {
        Write-NoticeText '已取消更新。'
    }
}

function Invoke-SoftwareInstalledList {
    Write-SubTitle '已安装软件'
    Write-Host '正在读取列表（winget 首次使用可能需要下载源信息，请耐心等待）...'
    $capture = Invoke-SupportWingetCapture @('list', '--accept-source-agreements')
    $rows = @(Get-SupportWingetRows $capture)
    if ($rows.Count -gt 0) {
        Write-SupportSoftwareState '已安装' ('共识别 ' + $rows.Count + ' 个软件：')
        $null = Show-SupportSoftwareTable $rows -Mode Installed
    }
    elseif ($capture.ExitCode -ne 0) { Write-SupportSoftwareState '失败' ('winget list 返回退出码 ' + $capture.ExitCode + '。') }
    else { Write-SupportSoftwareState '完成' '没有检测到已安装软件。' }
    $filter = Read-Host '输入关键字可再次筛选，直接回车结束'
    if ($filter) {
        Write-Host ''
        $filteredCapture = Invoke-SupportWingetCapture @('list', '--name', $filter, '--accept-source-agreements')
        $filteredRows = @(Get-SupportWingetRows $filteredCapture)
        if ($filteredRows.Count -gt 0) { $null = Show-SupportSoftwareTable $filteredRows -Mode Installed }
        elseif ($filteredCapture.ExitCode -eq 0) { Write-SupportSoftwareState '完成' '没有找到匹配的已安装软件。' }
        else { Write-SupportSoftwareState '失败' ('筛选失败，退出码 ' + $filteredCapture.ExitCode + '。') }
    }
}

function Show-SoftwareMenu {
    if (-not (Initialize-SupportWinget)) {
        Write-SectionTitle '软件'
        Write-Host ''
        Write-WarnText '未检测到 winget。'
        Write-Host ''
        Write-Host '请确认当前 Windows 版本是否支持 App Installer。' -ForegroundColor Yellow
        Write-Host '如果本机没有 winget，可到微软商店安装「应用安装程序 App Installer」。' -ForegroundColor Gray
        Write-Log '软件菜单被打开，但未检测到 winget' 'WARN'
        Write-PressAnyKeyToReturn
        return
    }
    while ($true) {
        Write-SectionTitle '软件'
        Write-Host '[1] 搜索软件'
        Write-Host '[2] 安装软件'
        Write-Host '[3] 卸载软件'
        Write-Host '[4] 更新软件'
        Write-Host '[5] 查看已安装软件'
        Write-Host '[6] 常用软件'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 6
        Write-Host ''
        switch ($choice) {
            1 {
                Invoke-SoftwareSearch
                Write-PressAnyKeyToReturn
            }
            2 {
                Invoke-SoftwareInstall
                Write-PressAnyKeyToReturn
            }
            3 {
                Invoke-SoftwareUninstall
                Write-PressAnyKeyToReturn
            }
            4 {
                Invoke-SoftwareUpdate
                Write-PressAnyKeyToReturn
            }
            5 {
                Invoke-SoftwareInstalledList
                Write-PressAnyKeyToReturn
            }
            6 { Show-CommonSoftwareMenu }
            0 { return }
        }
    }
}

# ===========================================================================
# 系统修复
# ===========================================================================

function Invoke-SystemSfc {
    Write-SectionTitle 'SFC 系统文件检查'
    if (-not (Confirm-SupportAdminOperation 'SFC 需要管理员权限。')) {
        return
    }
    Write-Host ''
    Write-Host '正在执行 SFC /SCANNOW，请稍候...' -ForegroundColor Yellow
    Write-Host '此命令可能运行几分钟，请勿关闭窗口或误判为卡死。' -ForegroundColor Gray
    Write-Host ''
    $code = Invoke-SupportNativeCommand 'sfc.exe' @('/scannow')
    Write-Host ''
    switch ($code) {
        0 { Write-OkText 'Windows 资源保护未发现任何完整性冲突。' }
        1 { Write-WarnText 'Windows 资源保护发现损坏文件并已修复。建议重启电脑。' }
        2 { Write-WarnText 'Windows 资源保护无法修复部分文件。请查看 CBS.log 或尝试 DISM 修复。' }
        3 { Write-WarnText 'Windows 资源保护无法完成请求的操作，可能需要重启后重试。' }
        default { Write-WarnText ('SFC 返回退出码 ' + $code + '。') }
    }
}

function Invoke-SystemDismScan {
    Write-SectionTitle 'DISM 系统映像检查'
    if (-not (Confirm-SupportAdminOperation 'DISM 需要管理员权限。')) {
        return
    }
    Write-Host ''
    Write-Host '正在执行 DISM /ScanHealth，请稍候...' -ForegroundColor Yellow
    Write-Host '此命令可能运行较长时间，请勿关闭窗口或误判为卡死。' -ForegroundColor Gray
    Write-Host ''
    $code = Invoke-SupportNativeCommand 'DISM.exe' @('/Online', '/Cleanup-Image', '/ScanHealth')
    Write-Host ''
    if ($code -eq 0) {
        Write-OkText '系统映像检查完成，未发现需要修复的损坏。'
    }
    else {
        Write-WarnText ('DISM 检查完成，返回退出码 ' + $code + '。如提示映像损坏，请执行「DISM 系统映像修复」。')
    }
}

function Invoke-SystemDismRepair {
    Write-SectionTitle 'DISM 系统映像修复'
    if (-not (Confirm-SupportAdminOperation 'DISM 修复需要管理员权限。')) {
        return
    }
    Write-Host ''
    Write-Host '正在执行 DISM /RestoreHealth，请稍候...' -ForegroundColor Yellow
    Write-Host '此命令可能运行 10 分钟以上，过程中可能联网下载修复文件，请勿关闭窗口。' -ForegroundColor Gray
    Write-Host ''
    $code = Invoke-SupportNativeCommand 'DISM.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth')
    Write-Host ''
    if ($code -eq 0) {
        Write-OkText '系统映像修复完成。建议重启电脑后再执行一次 SFC。'
    }
    else {
        Write-WarnText ('DISM 修复返回退出码 ' + $code + '。请检查网络连接，或使用官方 ISO 作为修复源。')
    }
}

function Get-SupportWindowsUpdateServiceInfo {
    $serviceNames = @(
        @{ Name = 'BITS'; Display = 'Background Intelligent Transfer (BITS)' },
        @{ Name = 'wuauserv'; Display = 'Windows Update' },
        @{ Name = 'cryptSvc'; Display = 'Cryptographic Services' },
        @{ Name = 'msiserver'; Display = 'Windows Installer' }
    )
    $result = @()
    foreach ($svcDef in $serviceNames) {
        try {
            $svc = Get-Service -Name $svcDef.Name -ErrorAction SilentlyContinue
            if ($svc) {
                $result += [pscustomobject]@{
                    Name      = $svcDef.Name
                    Display   = $svcDef.Display
                    Exists    = $true
                    Status    = $svc.Status
                    StartType = $svc.StartType
                }
            }
            else {
                $result += [pscustomobject]@{
                    Name      = $svcDef.Name
                    Display   = $svcDef.Display
                    Exists    = $false
                    Status    = ''
                    StartType = ''
                }
            }
        }
        catch {
            $result += [pscustomobject]@{
                Name      = $svcDef.Name
                Display   = $svcDef.Display
                Exists    = $false
                Status    = ''
                StartType = ''
            }
        }
    }
    return $result
}

function Show-SupportWindowsUpdateServices {
    Write-SectionTitle 'Windows Update 服务检查'
    $services = @(Get-SupportWindowsUpdateServiceInfo)
    foreach ($svc in $services) {
        if (-not $svc.Exists) {
            Write-WarnText ($svc.Display + '（' + $svc.Name + '）服务不存在')
            continue
        }
        $startTypeText = [string]$svc.StartType
        $line = $svc.Display + '（' + $svc.Name + '）：状态 ' + $svc.Status + '，启动类型 ' + $startTypeText
        if ($svc.Status -eq 'Running') {
            Write-OkText $line
        }
        elseif ($svc.Name -eq 'msiserver' -and $svc.StartType -eq 'Manual') {
            Write-NoticeText ($line + '（手动服务，按需启动，属正常情况）')
        }
        else {
            Write-WarnText $line
        }
    }
    Write-Host ''
    Write-Host 'BITS、Windows Update、Cryptographic Services 应处于“运行中”。' -ForegroundColor Gray
}

function Invoke-SupportWindowsUpdateBasicFix {
    Write-SectionTitle 'Windows Update 基础修复'
    Write-Host '本操作会：' -ForegroundColor Yellow
    Write-Host '  1. 停止 BITS / Windows Update / Cryptographic Services 服务'
    Write-Host '  2. 重命名 Windows\SoftwareDistribution\DataStore 与 Download（不会删除）'
    Write-Host '  3. 重新启动相关服务'
    Write-Host ''
    Write-Host '重命名后 Windows Update 会重新生成缓存，属于常见的基础修复。' -ForegroundColor Gray
    if (-not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation 'Windows Update 基础修复需要管理员权限。')) {
        return
    }

    $servicesToRestart = @('BITS', 'wuauserv', 'cryptSvc')
    foreach ($name in $servicesToRestart) {
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Write-Host ('正在停止 ' + $name + ' ...')
                Stop-Service -Name $name -Force -ErrorAction Stop
                Write-OkText ($name + ' 已停止。')
            }
            elseif ($svc) {
                Write-NoticeText ($name + ' 当前未运行，无需停止。')
            }
            else {
                Write-WarnText ('服务 ' + $name + ' 不存在。')
            }
        }
        catch {
            Write-WarnText ('停止 ' + $name + ' 失败：' + $_.Exception.Message)
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sdPath = Join-Path $env:WINDIR 'SoftwareDistribution'
    foreach ($folderName in @('DataStore', 'Download')) {
        $folder = Join-Path $sdPath $folderName
        if (Test-SupportPathExists $folder) {
            $backup = $folder + '.old.' + $stamp
            try {
                Rename-Item -LiteralPath $folder -NewName (Split-Path $backup -Leaf) -ErrorAction Stop
                Write-OkText ('已重命名 ' + $folderName + ' -> ' + (Split-Path $backup -Leaf))
            }
            catch {
                Write-WarnText ('重命名 ' + $folderName + ' 失败：' + $_.Exception.Message)
            }
        }
        else {
            Write-NoticeText ($folderName + ' 目录不存在，跳过。')
        }
    }

    foreach ($name in $servicesToRestart) {
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc) {
                Write-Host ('正在启动 ' + $name + ' ...')
                Start-Service -Name $name -ErrorAction Stop
                Write-OkText ($name + ' 已启动。')
            }
        }
        catch {
            Write-WarnText ('启动 ' + $name + ' 失败：' + $_.Exception.Message)
        }
    }
    Write-Host ''
    Write-Host '修复完成。请到「设置 -> Windows 更新」重新检查更新。' -ForegroundColor Green
}

function Show-SystemRepairMenu {
    while ($true) {
        Write-SectionTitle '系统修复'
        Write-Host '[1] SFC 系统文件检查'
        Write-Host '[2] DISM 系统映像检查'
        Write-Host '[3] DISM 系统映像修复'
        Write-Host '[4] Windows Update 服务检查'
        Write-Host '[5] Windows Update 基础修复'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 5
        Write-Host ''
        switch ($choice) {
            1 {
                Invoke-SystemSfc
                Write-PressAnyKeyToReturn
            }
            2 {
                Invoke-SystemDismScan
                Write-PressAnyKeyToReturn
            }
            3 {
                Invoke-SystemDismRepair
                Write-PressAnyKeyToReturn
            }
            4 {
                Show-SupportWindowsUpdateServices
                Write-PressAnyKeyToReturn
            }
            5 {
                Invoke-SupportWindowsUpdateBasicFix
                Write-PressAnyKeyToReturn
            }
            0 { return }
        }
    }
}

# ===========================================================================
# 一键检测
# ===========================================================================

function Get-SupportComputerDetectionChecks {
    $results = @()
    $f = Get-SupportComputerFacts
    if ($f.OsCaption -and $f.OsCaption -ne '无法获取') {
        $results += New-SupportDiagnosticResult '电脑' 'Windows 系统' 'PASS' $f.OsCaption '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' 'Windows 系统' 'FAIL' '无法获取 Windows 版本信息' '系统信息查询未返回有效结果。' '检查 WMI/CIM 服务是否正常，并在管理员 PowerShell 中重新检测。' ''
    }
    if ($f.Cpu -and $f.Cpu -ne '无法获取') {
        $cpuShort = $f.Cpu
        if ($cpuShort.Length -gt 70) { $cpuShort = $cpuShort.Substring(0, 70) + '...' }
        $results += New-SupportDiagnosticResult '电脑' 'CPU' 'PASS' $cpuShort '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' 'CPU' 'FAIL' '无法获取 CPU 信息' 'Windows 未能返回 CPU 硬件信息。' '检查 WMI/CIM 服务或设备管理器中的处理器状态。' ''
    }
    if ($f.MemoryTotal -and $f.MemoryTotal -ne '无法获取') {
        $results += New-SupportDiagnosticResult '电脑' '内存' 'PASS' ('总内存 ' + $f.MemoryTotal + '，当前可用 ' + $f.MemoryFree) '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' '内存' 'FAIL' '无法获取内存信息' 'Windows 未能返回物理内存信息。' '检查 WMI/CIM 服务或稍后重新检测。' ''
    }
    if ($f.Gpu -and $f.Gpu -ne '无法获取') {
        $gpuShort = $f.Gpu
        if ($gpuShort.Length -gt 80) { $gpuShort = $gpuShort.Substring(0, 80) + '...' }
        $results += New-SupportDiagnosticResult '电脑' 'GPU' 'PASS' $gpuShort '' ''
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' 'GPU' 'INFO' '无法获取 GPU 信息（虚拟机或无显示设备时属正常）' '' ''
    }
    return $results
}

function Get-SupportDiskDetectionChecks {
    $results = @()
    $disks = @(Get-SupportDiskInfo)
    $systemDisk = $disks | Where-Object { $_.DriveLetter -eq 'C:' } | Select-Object -First 1
    if (-not $systemDisk) {
        $results += New-SupportDiagnosticResult '磁盘' 'C盘空间' 'FAIL' '未找到 C 盘信息' '无法从系统卷中读取 C 盘容量数据。' '检查磁盘管理中的 C 盘状态和 WMI/CIM 服务。' ''
        return $results
    }
    $usedPercent = [double]$systemDisk.UsedPercent
    $message = ('C盘：总容量 ' + $systemDisk.TotalText + '，已用 ' + $systemDisk.UsedText + '（' + $systemDisk.UsedPercentText + '），剩余 ' + $systemDisk.FreeText)
    if ($usedPercent -ge 95) {
        $results += New-SupportDiagnosticResult '磁盘' 'C盘空间' 'FAIL' $message 'C 盘可用空间极低，可能影响更新、系统文件和临时文件写入。' '立即清理临时文件、卸载无用软件或将大型文件移到其他磁盘。' ''
    }
    elseif ($usedPercent -ge 90) {
        $results += New-SupportDiagnosticResult '磁盘' 'C盘空间' 'WARNING' $message 'C 盘空间接近不足，长期使用可能影响 Windows 更新。' '建议清理系统临时文件并检查大文件占用。' ''
    }
    else {
        $results += New-SupportDiagnosticResult '磁盘' 'C盘空间' 'PASS' $message '' ''
    }
    return $results
}

function Get-SupportBatteryDetectionChecks {
    $results = @()
    $bat = Get-SupportBattery
    if (-not $bat.HasBattery) {
        $results += New-SupportDiagnosticResult '电脑' '电池' 'INFO' '未检测到电池（台式机或虚拟机）' '' ''
        return $results
    }
    $batteryText = '电量 ' + $bat.ChargeText
    if ($bat.PowerStatusText) {
        $batteryText += '，' + $bat.PowerStatusText
    }
    if ($bat.ChargePercent -ne $null -and $bat.ChargePercent -lt 20) {
        $results += New-SupportDiagnosticResult '电脑' '电池' 'WARNING' ($batteryText + '，电量偏低') '电池电量低于 20%。' '连接电源并检查充电状态。' ''
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' '电池' 'PASS' $batteryText '' ''
    }
    if ($bat.HealthPercent -ne $null) {
        if ($bat.HealthPercent -lt 80) {
            $results += New-SupportDiagnosticResult '电脑' '电池健康' 'WARNING' ('设计容量对比当前充满容量约为 ' + $bat.HealthPercentText) '电池健康度低于 80%，续航可能明显下降。' '检查电源使用情况；如续航异常，建议联系硬件支持。' ''
        }
        else {
            $results += New-SupportDiagnosticResult '电脑' '电池健康' 'PASS' ('电池健康度约 ' + $bat.HealthPercentText) '' ''
        }
    }
    else {
        $results += New-SupportDiagnosticResult '电脑' '电池健康' 'INFO' '无法获取电池健康信息（设备或驱动不支持）' '' ''
    }
    return $results
}

function Get-SupportPrinterDetectionChecks {
    $results = @()
    $printers = @(Get-SupportPrinters)
    if ($printers.Count -eq 0) {
        $results += New-SupportDiagnosticResult '打印机' '打印机' 'PASS' '未检测到打印机' '' ''
        return $results
    }
    foreach ($p in $printers) {
        $mark = ''
        if ($p.IsDefault) { $mark = '（默认）' }
        if ($p.Status -match '离线|停止') {
            $results += New-SupportDiagnosticResult '打印机' '打印机' 'FAIL' ($p.Name + $mark + '：' + $p.Status) '打印机处于离线或停止状态。' '检查打印机电源、连接、驱动和打印队列，可使用「一键修复打印机」。' ''
        }
        else {
            $results += New-SupportDiagnosticResult '打印机' '打印机' 'PASS' ($p.Name + $mark + '：' + $p.Status) '' ''
        }
    }
    return $results
}

function Get-SupportWindowsUpdateChecks {
    $serviceNames = @('BITS', 'wuauserv', 'cryptSvc', 'msiserver')
    $missing = @()
    $disabled = @()
    $queryErrors = @()
    foreach ($name in $serviceNames) {
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $svc) {
                $missing += $name
            }
            elseif ([string]$svc.StartType -eq 'Disabled') {
                $disabled += $name
            }
        }
        catch {
            $queryErrors += $name
        }
    }
    if ($missing.Count -gt 0 -or $disabled.Count -gt 0) {
        $parts = @()
        if ($disabled.Count -gt 0) { $parts += ('已禁用：' + ($disabled -join ', ')) }
        if ($missing.Count -gt 0) { $parts += ('不存在：' + ($missing -join ', ')) }
        return @(New-SupportDiagnosticResult '系统' 'Windows Update' 'FAIL' ($parts -join '；') 'Windows Update 依赖服务被禁用或缺失。' '在「系统修复 -> Windows Update 服务检查」中确认服务状态，必要时执行基础修复。' '')
    }
    if ($queryErrors.Count -gt 0) {
        return @(New-SupportDiagnosticResult '系统' 'Windows Update' 'WARNING' ('部分服务状态读取失败：' + ($queryErrors -join ', ')) '当前权限或服务查询环境可能受限。' '以管理员身份重新运行并检查 Windows Update 服务。' '')
    }
    return @(New-SupportDiagnosticResult '系统' 'Windows Update' 'PASS' 'BITS、Windows Update、Cryptographic Services、Windows Installer 启动配置正常' '' '')
}

function Get-SupportSystemIntegrityChecks {
    $systemRoot = $env:WINDIR
    if (-not $systemRoot) { $systemRoot = $env:SystemRoot }
    if (-not $systemRoot) {
        return @(New-SupportDiagnosticResult '系统' '系统文件完整性' 'WARNING' '无法确定 Windows 系统目录' '环境变量 WINDIR/SystemRoot 不可用。' '以正常 Windows 用户环境重新运行工具。' '')
    }

    $targets = @(
        (Join-Path $systemRoot 'System32\kernel32.dll'),
        (Join-Path $systemRoot 'System32\ntdll.dll'),
        (Join-Path $systemRoot 'System32\services.exe'),
        (Join-Path $systemRoot 'System32\lsass.exe')
    )
    $verified = 0
    $invalid = @()
    foreach ($path in $targets) {
        if (-not (Test-SupportPathExists $path)) { continue }
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            if ($signature.Status -eq 'Valid') {
                $verified++
            }
            else {
                $invalid += ((Split-Path -Leaf $path) + '（' + $signature.Status + '）')
            }
        }
        catch {
            $invalid += ((Split-Path -Leaf $path) + '（无法验证）')
        }
    }

    if ($invalid.Count -gt 0) {
        return @(New-SupportDiagnosticResult '系统' '系统文件完整性' 'WARNING' ('异常签名：' + ($invalid -join ', ')) '部分关键系统文件的数字签名未能验证，可能是文件损坏、系统版本差异或安全策略影响。' '建议在管理员环境执行「SFC 系统文件检查」或「DISM 系统映像检查」。' '')
    }
    if ($verified -eq 0) {
        return @(New-SupportDiagnosticResult '系统' '系统文件完整性' 'WARNING' '未找到可验证的关键系统文件' '系统目录结构或文件访问权限异常。' '以管理员身份运行 SFC 检查。' '')
    }
    return @(New-SupportDiagnosticResult '系统' '系统文件完整性' 'PASS' ('已验证 ' + $verified + ' 个关键系统文件签名') '' '')
}

function Get-SupportCriticalServiceChecks {
    $serviceDefs = @(
        @{ Name = 'EventLog'; Display = 'Windows Event Log'; Required = $true },
        @{ Name = 'Winmgmt'; Display = 'WMI 服务'; Required = $true },
        @{ Name = 'Dnscache'; Display = 'DNS Client'; Required = $true },
        @{ Name = 'LanmanWorkstation'; Display = 'Workstation'; Required = $true },
        @{ Name = 'Spooler'; Display = 'Print Spooler'; Required = $false }
    )
    $printerCount = @(Get-SupportPrinters).Count
    $failures = @()
    $warnings = @()
    $details = @()
    foreach ($def in $serviceDefs) {
        try {
            $svc = Get-Service -Name $def.Name -ErrorAction SilentlyContinue
            if (-not $svc) {
                $failures += ($def.Display + '：不存在')
                continue
            }
            $stateText = $def.Display + '：' + $svc.Status
            $details += $stateText
            if ($svc.Status -eq 'Running') { continue }
            if ($def.Name -eq 'Spooler' -and $printerCount -eq 0) {
                $details += '（当前无打印机，停止状态可接受）'
                continue
            }
            if ($def.Required) {
                $failures += $stateText
            }
            else {
                $warnings += $stateText
            }
        }
        catch {
            $failures += ($def.Display + '：无法查询')
        }
    }

    if ($failures.Count -gt 0) {
        return @(New-SupportDiagnosticResult '系统' '关键服务' 'FAIL' ($failures -join '；') '一个或多个 Windows 基础服务未运行或不存在。' '检查服务启动类型并尝试启动；必要时重启后重新检测。' '')
    }
    if ($warnings.Count -gt 0) {
        return @(New-SupportDiagnosticResult '系统' '关键服务' 'WARNING' ($warnings -join '；') '部分非核心服务当前未运行。' '结合具体业务和打印机状态进一步检查。' '')
    }
    return @(New-SupportDiagnosticResult '系统' '关键服务' 'PASS' ($details -join '；') '' '')
}

function Get-SupportDetectionAll {
    $all = @()
    $all += Get-SupportComputerDetectionChecks
    $all += Get-SupportDiskDetectionChecks
    $all += @(Get-SupportNetworkDiagnosis)
    $all += Get-SupportWindowsUpdateChecks
    $all += Get-SupportSystemIntegrityChecks
    $all += Get-SupportCriticalServiceChecks
    $all += Get-SupportBatteryDetectionChecks
    $all += Get-SupportPrinterDetectionChecks
    return @($all)
}

function Get-SupportIssueSuggestion {
    param([string]$Check)
    switch -Regex ($Check) {
        'DNS' { return 'DNS 解析可能存在异常。建议进入「网络 -> 网络诊断」执行刷新 DNS，或检查 DNS 设置。' }
        'HTTPS' { return 'HTTPS 连接失败，建议进入「网络 -> 网络诊断」检查代理、防火墙和证书。' }
        'Internet|公网连通性' { return '公网访问存在异常，建议进入「网络 -> 网络诊断」进一步检查。' }
        '默认网关|网关连通性' { return '默认网关存在异常，建议进入「网络 -> 网络诊断」检查局域网和网关配置。' }
        'IP 配置' { return '本机没有有效 IP，建议检查网线/Wi-Fi 连接后重新获取 IP。' }
        '网络适配器' { return '网络适配器异常，请检查硬件或驱动。' }
        'C盘空间' { return 'C 盘空间使用率较高，建议进入「磁盘」查看空间并清理临时文件。' }
        'Windows Update' { return 'Windows Update 依赖服务异常，建议进入「系统修复 -> Windows Update 服务检查」。' }
        '系统文件完整性' { return '系统文件签名检查异常，建议在管理员环境执行 SFC 或 DISM 检查。' }
        '关键服务' { return '关键 Windows 服务异常，建议检查服务启动类型并尝试启动。' }
        '电池' { return '电池电量或健康度需要关注，建议检查电源设置或联系硬件支持。' }
        '打印机' { return '打印机存在异常，建议进入「打印机 -> 一键修复打印机」。' }
        default { return ('"' + $Check + '" 需要进一步检查，可进入对应功能菜单操作。') }
    }
}

function Write-SupportDetectionResults {
    param($Results)
    foreach ($r in $Results) {
        $line = '[' + $r.Status + '] ' + $r.Name
        if ($r.Result) { $line += '：' + $r.Result }
        Write-Host $line -ForegroundColor (Get-SupportStatusColor $r.Status)
    }
}

function Invoke-OneClickCheck {
    Write-SectionTitle 'Windows IT Support 快速诊断'
    Write-Host '正在检查系统、CPU/内存、C盘、网络、Windows Update、关键服务和打印机，请稍候...' -ForegroundColor Gray
    $all = @(Get-SupportDetectionAll)
    Write-Host ''
    Write-Host '========== 诊断结果 ==========' -ForegroundColor Cyan
    Write-Host ''
    Write-SupportDetectionResults $all
    Write-Host ''

    $problemItems = @($all | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'WARNING' })
    $problemCount = $problemItems.Count
    if ($problemCount -eq 0) {
        Write-OkText ('共检测 ' + $all.Count + ' 项，全部正常。')
    }
    else {
        Write-Host '========== 发现的问题 ==========' -ForegroundColor Cyan
        Write-Host ''
        $idx = 1
        foreach ($item in $problemItems) {
            $statusColor = Get-SupportStatusColor $item.Status
            Write-Host ('' + $idx + '. [' + $item.Status + '] ' + $item.Name) -ForegroundColor $statusColor
            if ($item.Result) {
                Write-Host ('   结果：' + $item.Result) -ForegroundColor Gray
            }
            if ($item.Diagnosis) {
                Write-Host ('   诊断：' + $item.Diagnosis) -ForegroundColor Gray
            }
            if ($item.Recommendation) {
                Write-Host ('   建议：' + $item.Recommendation) -ForegroundColor Gray
            }
            $idx++
        }
        Write-Host ''
        $recommendations = @($problemItems | Where-Object { $_.Recommendation } | ForEach-Object { $_.Recommendation } | Select-Object -Unique)
        if ($recommendations.Count -gt 0) {
            Write-Host '========== 建议 ==========' -ForegroundColor Cyan
            Write-Host ''
            $idx = 1
            foreach ($recommendation in $recommendations) {
                Write-Host ('' + $idx + '. ' + $recommendation)
                $idx++
            }
            Write-Host ''
        }
        Write-Host '可进入对应功能菜单进一步处理。' -ForegroundColor Gray
    }
    return $all
}

# ===========================================================================
# 导出报告
# ===========================================================================

function New-SupportReportSnapshot {
    param($DetectionResults)
    $computer = Get-SupportComputerFacts
    if ($null -ne $DetectionResults) {
        $detection = @($DetectionResults)
    }
    else {
        $detection = @(Get-SupportDetectionAll)
    }
    $disks = @(Get-SupportDiskInfo)
    $battery = Get-SupportBattery
    $printers = @(Get-SupportPrinters)
    $networkEnvironment = Get-SupportNetworkEnvironmentInfo
    return [pscustomobject]@{
        ToolName       = $script:ToolName
        ToolVersion    = $script:ToolVersion
        GeneratedAt    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Computer       = $computer
        Detection      = $detection
        Disk           = $disks
        Battery        = $battery
        Printers       = $printers
        NetworkEnvironment = $networkEnvironment
    }
}

function Format-SupportBooleanChinese {
    param($Value)
    if ($Value) { return '是' }
    return '否'
}

function Export-SupportReportTxt {
    param(
        [string]$FileName,
        $Snapshot
    )
    $filePath = Join-Path $script:ReportDir $FileName
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('========================================')
    [void]$sb.AppendLine(' ' + $script:ToolName + ' - 诊断报告')
    [void]$sb.AppendLine(' 版本：' + $script:ToolVersion)
    [void]$sb.AppendLine(' 生成时间：' + $Snapshot.GeneratedAt)
    [void]$sb.AppendLine('========================================')
    [void]$sb.AppendLine('')

    $c = $Snapshot.Computer
    [void]$sb.AppendLine('===== 电脑信息 =====')
    [void]$sb.AppendLine('计算机名：' + $c.ComputerName)
    [void]$sb.AppendLine('当前用户：' + $c.CurrentUser)
    [void]$sb.AppendLine('管理员权限：' + (Format-SupportBooleanChinese $c.IsAdmin))
    [void]$sb.AppendLine('厂商：' + $c.Manufacturer)
    [void]$sb.AppendLine('型号：' + $c.Model)
    [void]$sb.AppendLine('序列号：' + $c.SerialNumber)
    [void]$sb.AppendLine('CPU：' + $c.Cpu)
    [void]$sb.AppendLine('内存：' + $c.MemoryTotal + '（可用 ' + $c.MemoryFree + '）')
    [void]$sb.AppendLine('GPU：' + $c.Gpu)
    [void]$sb.AppendLine('Windows版本：' + $c.OsCaption)
    [void]$sb.AppendLine('Windows Build：' + $c.OsBuild)
    [void]$sb.AppendLine('BIOS：' + $c.Bios)
    [void]$sb.AppendLine('系统运行时间：' + $c.Uptime)
    [void]$sb.AppendLine('IP：' + $c.IpAddress)
    [void]$sb.AppendLine('MAC：' + $c.MacAddress)
    [void]$sb.AppendLine('网关：' + $c.Gateway)
    [void]$sb.AppendLine('DNS：' + $c.DnsServer)
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('===== 网络检测结果 =====')
    $netResults = @($Snapshot.Detection | Where-Object { $_.Category -eq '网络' })
    foreach ($r in $netResults) {
        [void]$sb.AppendLine('[' + (Get-SupportLegacyStatusText $r.Status) + '] ' + $r.Check + ' - ' + $r.Message)
    }
    [void]$sb.AppendLine('')

    if ($Snapshot.NetworkEnvironment) {
        $ne = $Snapshot.NetworkEnvironment
        [void]$sb.AppendLine('===== 网络环境 =====')
        [void]$sb.AppendLine('代理：' + $(if ($ne.Proxy.AnyProxy) { '已检测到' } else { '未检测到' }))
        [void]$sb.AppendLine('系统代理：' + $(if ($ne.Proxy.Enabled) { $ne.Proxy.Server } else { '未启用' }))
        [void]$sb.AppendLine('WinHTTP：' + $(if ($ne.Proxy.WinHttpEnabled) { $ne.Proxy.WinHttpServer } else { 'Direct' }))
        [void]$sb.AppendLine('VPN/TUN：' + $(if ($ne.Proxy.VpnOrTunnelDetected) { ($ne.Proxy.VpnAdapterNames -join ', ') } else { '未检测到' }))
        [void]$sb.AppendLine('公网 IP：' + $(if ($ne.Public.Success) { $ne.Public.PublicIP } else { '无法获取' }))
        [void]$sb.AppendLine('公网出口地区：' + $(if ($ne.Public.Success) { (@($ne.Public.Country, $ne.Public.Region, $ne.Public.City) | Where-Object { $_ }) -join ' / ' } else { '无法获取' }))
        [void]$sb.AppendLine('运营商：' + $(if ($ne.Public.Success) { $ne.Public.Organization } else { '无法获取' }))
        [void]$sb.AppendLine('中国大陆网络：' + $ne.MainlandStatus)
        [void]$sb.AppendLine('海外网络：' + $ne.OverseasStatus)
        [void]$sb.AppendLine('Google：' + $ne.GoogleStatus)
        [void]$sb.AppendLine('结论：' + $ne.Conclusion)
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('===== 磁盘信息 =====')
    foreach ($d in $Snapshot.Disk) {
        [void]$sb.AppendLine($d.DriveLetter + '：总容量 ' + $d.TotalText + '，已用 ' + $d.UsedText + '（' + $d.UsedPercentText + '），剩余 ' + $d.FreeText)
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('===== 电池信息 =====')
    $b = $Snapshot.Battery
    if ($b.HasBattery) {
        [void]$sb.AppendLine('电池：存在')
        [void]$sb.AppendLine('当前电量：' + $b.ChargeText)
        [void]$sb.AppendLine('电源状态：' + $b.PowerStatusText)
        if ($b.HealthPercent -ne $null) {
            [void]$sb.AppendLine('电池健康度：' + $b.HealthPercentText)
        }
        else {
            [void]$sb.AppendLine('电池健康度：无法获取')
        }
    }
    else {
        [void]$sb.AppendLine('电池：未检测到（台式机或虚拟机）')
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('===== 打印机信息 =====')
    if ($Snapshot.Printers.Count -eq 0) {
        [void]$sb.AppendLine('未检测到打印机')
    }
    else {
        foreach ($p in $Snapshot.Printers) {
            $mark = ''
            if ($p.IsDefault) { $mark = '（默认）' }
            [void]$sb.AppendLine($p.Name + $mark + ' - ' + $p.Status)
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('===== 一键检测结果 =====')
    foreach ($r in $Snapshot.Detection) {
        [void]$sb.AppendLine('[' + (Get-SupportLegacyStatusText $r.Status) + '] ' + $r.Category + '/' + $r.Check + ' - ' + $r.Message)
    }
    $abnormalCount = @($Snapshot.Detection | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount = @($Snapshot.Detection | Where-Object { $_.Status -eq 'WARNING' }).Count
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('问题统计：异常 ' + $abnormalCount + ' 项，警告 ' + $warnCount + ' 项')
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('===== V1.1 结构化诊断结果 =====')
    foreach ($r in $Snapshot.Detection) {
        [void]$sb.AppendLine('[' + $r.Status + '] ' + $r.Category + '/' + $r.Name)
        [void]$sb.AppendLine('结果：' + $r.Result)
        if ($r.Diagnosis) {
            [void]$sb.AppendLine('诊断：' + $r.Diagnosis)
        }
        if ($r.Recommendation) {
            [void]$sb.AppendLine('建议：' + $r.Recommendation)
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('（本报告不包含密码、Cookie、Token 等敏感信息）')

    try {
        $sb.ToString() | Out-File -LiteralPath $filePath -Encoding UTF8 -ErrorAction Stop
        return $filePath
    }
    catch {
        Write-Log ('导出 TXT 报告失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Export-SupportReportJson {
    param(
        [string]$FileName,
        $Snapshot
    )
    $filePath = Join-Path $script:ReportDir $FileName
    try {
        $json = $Snapshot | ConvertTo-Json -Depth 8
        $json | Out-File -LiteralPath $filePath -Encoding UTF8 -ErrorAction Stop
        return $filePath
    }
    catch {
        Write-Log ('导出 JSON 报告失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Show-ReportMenu {
    while ($true) {
        Write-SectionTitle '导出报告'
        Write-Host '[1] 导出 TXT 报告'
        Write-Host '[2] 导出 JSON 报告'
        Write-Host '[3] 导出 TXT + JSON'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        Write-Host ''
        if ($choice -eq 0) { return }

        Write-Host '正在收集信息并生成报告（网络检测需要一点时间）...' -ForegroundColor Gray
        $snapshot = New-SupportReportSnapshot
        try {
            if (-not (Test-SupportPathExists $script:ReportDir)) {
                New-Item -ItemType Directory -Path $script:ReportDir -Force -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-ErrorText ('无法创建报告目录：' + $_.Exception.Message)
            Write-Log ('创建报告目录失败: ' + $_.Exception.Message) 'ERROR'
            continue
        }
        $stamp = Get-SupportTimeStamp
        $exported = @()
        if ($choice -eq 1 -or $choice -eq 3) {
            $fileName = 'ITSupportReport_' + $stamp + '.txt'
            $path = Export-SupportReportTxt $fileName $snapshot
            if ($path) { $exported += $path }
        }
        if ($choice -eq 2 -or $choice -eq 3) {
            $fileName = 'ITSupportReport_' + $stamp + '.json'
            $path = Export-SupportReportJson $fileName $snapshot
            if ($path) { $exported += $path }
        }
        Write-Host ''
        if ($exported.Count -gt 0) {
            Write-OkText '报告导出成功：'
            foreach ($p in $exported) {
                Write-Host ('  ' + $p) -ForegroundColor Green
            }
            Write-Host ''
            Write-NoticeText ('报告保存在：' + $script:ReportDir)
        }
        else {
            Write-ErrorText '报告导出失败，请查看 logs 目录中的日志。'
        }
        Write-PressAnyKeyToReturn
    }
}

# ===========================================================================
# V1.2 UI 页面
# ===========================================================================

function Write-SupportUiHeader {
    param([string]$CurrentPage)
    Clear-Host -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '+------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '|  WinSupport Toolkit                                        |' -ForegroundColor Cyan
    Write-Host '|  电脑急救站                                                 |' -ForegroundColor DarkCyan
    Write-Host '+------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host ('当前页面：' + $CurrentPage) -ForegroundColor Gray
    Write-Host ''
}

function Get-SupportUiCategoryIcon {
    param([string]$Category)
    switch ($Category) {
        '设备' { return 'PC ' }
        'Windows' { return 'WIN' }
        '系统' { return 'SYS' }
        '磁盘' { return 'DSK' }
        '网络' { return 'NET' }
        '打印机' { return 'PRN' }
        default { return '---' }
    }
}

function Get-SupportUiStatusIcon {
    param([string]$Status)
    switch ($Status) {
        '正常' { return ' OK ' }
        '注意' { return 'WARN' }
        '问题' { return 'FAIL' }
        default { return ' -- ' }
    }
}

function Write-SupportUiMascot {
    param([string]$Mood = 'happy')
    $face = switch ($Mood) {
        'work' { '^_^' }
        'alert' { 'o_o' }
        default { '^.^' }
    }
    Write-Host ('        .------.   ' + $face) -ForegroundColor Magenta
    Write-Host '        |  []  |' -ForegroundColor Magenta
    Write-Host '        |______|' -ForegroundColor Magenta
}

function Get-SupportUiCategory {
    param($Result)
    switch ([string]$Result.Category) {
        '网络' { return '网络' }
        '磁盘' { return '磁盘' }
        '打印机' { return '打印机' }
        '系统' { return '系统' }
        '电脑' {
            if ($Result.Name -eq 'Windows 系统') { return 'Windows' }
            return '设备'
        }
        default {
            if ($Result.Name -match 'Windows') { return 'Windows' }
            return '设备'
        }
    }
}

function Get-SupportUiItemStatus {
    param($Result)
    switch ([string]$Result.Status) {
        'FAIL' { return '问题' }
        'WARNING' { return '注意' }
        'PASS' { return '正常' }
        'INFO' {
            if ($Result.Name -eq '代理设置') { return '注意' }
            return '正常'
        }
        default { return '未检测' }
    }
}

function Get-SupportUiStatusColor {
    param([string]$Status)
    switch ($Status) {
        '正常' { return 'Green' }
        '注意' { return 'Yellow' }
        '问题' { return 'Red' }
        default { return 'Gray' }
    }
}

function Get-SupportUiCategoryStatus {
    param($Results)
    $items = @($Results)
    if ($items.Count -eq 0) { return '未检测' }
    $itemStatuses = @($items | ForEach-Object { Get-SupportUiItemStatus $_ })
    if ($itemStatuses -contains '问题') { return '问题' }
    if ($itemStatuses -contains '注意') { return '注意' }
    if (@($itemStatuses | Where-Object { $_ -ne '未检测' }).Count -eq 0) { return '未检测' }
    return '正常'
}

function New-SupportDiagnosticSession {
    param($Results)
    $allResults = @($Results)
    $categories = @('设备', 'Windows', '系统', '磁盘', '网络', '打印机')
    $categoryStatuses = [ordered]@{}
    foreach ($category in $categories) {
        $categoryResults = @($allResults | Where-Object { (Get-SupportUiCategory $_) -eq $category })
        $categoryStatuses[$category] = Get-SupportUiCategoryStatus $categoryResults
    }

    $overallStatus = '正常'
    if (@($categoryStatuses.Values | Where-Object { $_ -eq '问题' }).Count -gt 0) {
        $overallStatus = '问题'
    }
    elseif (@($categoryStatuses.Values | Where-Object { $_ -eq '注意' }).Count -gt 0) {
        $overallStatus = '注意'
    }
    elseif (@($categoryStatuses.Values | Where-Object { $_ -eq '未检测' }).Count -gt 0) {
        $overallStatus = '未检测'
    }

    $uiItemStatuses = @($allResults | ForEach-Object { Get-SupportUiItemStatus $_ })
    return [pscustomobject]@{
        Results          = @($allResults)
        GeneratedAt      = Get-Date
        OverallStatus    = $overallStatus
        CategoryStatuses = $categoryStatuses
        ProblemCount     = @($uiItemStatuses | Where-Object { $_ -eq '问题' }).Count
        AttentionCount   = @($uiItemStatuses | Where-Object { $_ -eq '注意' }).Count
    }
}

function Set-SupportDiagnosticSession {
    param($Results)
    $script:DiagnosticSession = New-SupportDiagnosticSession $Results
    return $script:DiagnosticSession
}

function Get-SupportSessionCategoryResults {
    param([string]$Category)
    if (-not $script:DiagnosticSession) { return @() }
    if ($script:DiagnosticSession.CategoryStatuses.Contains($Category)) {
        return @($script:DiagnosticSession.Results | Where-Object { (Get-SupportUiCategory $_) -eq $Category })
    }
    return @()
}

function Write-SupportDashboardStatus {
    param(
        [string]$Label,
        [string]$Status
    )
    $padding = 10 - $Label.Length
    if ($padding -lt 1) { $padding = 1 }
    $icon = Get-SupportUiCategoryIcon $Label
    $statusIcon = Get-SupportUiStatusIcon $Status
    Write-Host ('[' + $icon + '] ' + $Label + (' ' * $padding) + '[' + $statusIcon + '] ' + $Status) -ForegroundColor (Get-SupportUiStatusColor $Status)
}

function Show-SupportDiagnosisProgress {
    param($States)
    Write-SupportUiHeader '全面诊断'
    Write-SupportUiMascot 'work'
    Write-Host '小助手正在检查电脑，请稍等一下……' -ForegroundColor Cyan
    Write-Host ''
    foreach ($step in @('设备', 'Windows', '系统', '磁盘', '网络', '打印机')) {
        $state = [string]$States[$step]
        switch ($state) {
            '完成' { Write-Host ('[' + (Get-SupportUiCategoryIcon $step) + '] ' + $step + '检查完成') -ForegroundColor Green }
            '进行' { Write-Host ('[' + (Get-SupportUiCategoryIcon $step) + '] 正在检查' + $step + '……') -ForegroundColor Yellow }
            '失败' { Write-Host ('[' + (Get-SupportUiCategoryIcon $step) + '] ' + $step + '检查失败') -ForegroundColor Red }
            default { Write-Host ('[' + (Get-SupportUiCategoryIcon $step) + '] 等待检查' + $step) -ForegroundColor Gray }
        }
    }
    Write-Host ''
}

function Get-SupportDiagnosisModuleFailure {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Message
    )
    return @(New-SupportDiagnosticResult $Category $Name 'FAIL' ('检测未完成：' + $Message) '该检测项发生未处理错误，其他检测项仍会继续。' '重新运行全面诊断；如持续失败，请查看日志。' '')
}

function Invoke-SupportFullDiagnosis {
    param([switch]$Quiet)
    $steps = @('设备', 'Windows', '系统', '磁盘', '网络', '打印机')
    $states = [ordered]@{}
    foreach ($step in $steps) { $states[$step] = '等待' }
    $allResults = @()

    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['设备'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    $computerResults = @()
    try {
        $computerResults += @(Get-SupportComputerDetectionChecks)
        $computerResults += @(Get-SupportBatteryDetectionChecks)
    }
    catch {
        $computerResults += Get-SupportDiagnosisModuleFailure '电脑' '设备检测' $_.Exception.Message
    }
    $deviceResults = @($computerResults | Where-Object { (Get-SupportUiCategory $_) -eq '设备' })
    if ($deviceResults.Count -eq 0) {
        $deviceResults = Get-SupportDiagnosisModuleFailure '电脑' '设备检测' '未返回设备检测结果'
    }
    $allResults += $deviceResults
    $states['设备'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['Windows'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    $windowsResults = @($computerResults | Where-Object { (Get-SupportUiCategory $_) -eq 'Windows' })
    if ($windowsResults.Count -eq 0) {
        $windowsResults = Get-SupportDiagnosisModuleFailure '电脑' 'Windows 系统' '未返回 Windows 状态结果'
    }
    $allResults += $windowsResults
    $states['Windows'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['系统'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    try {
        $allResults += @(Get-SupportWindowsUpdateChecks)
        $allResults += @(Get-SupportSystemIntegrityChecks)
        $allResults += @(Get-SupportCriticalServiceChecks)
    }
    catch {
        $allResults += Get-SupportDiagnosisModuleFailure '系统' '系统检测' $_.Exception.Message
    }
    $states['系统'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['磁盘'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    try {
        $allResults += @(Get-SupportDiskDetectionChecks)
    }
    catch {
        $allResults += Get-SupportDiagnosisModuleFailure '磁盘' '磁盘检测' $_.Exception.Message
    }
    $states['磁盘'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['网络'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    try {
        $allResults += @(Get-SupportNetworkDiagnosis)
    }
    catch {
        $allResults += Get-SupportDiagnosisModuleFailure '网络' '网络检测' $_.Exception.Message
    }
    $states['网络'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $states['打印机'] = '进行'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }
    try {
        $allResults += @(Get-SupportPrinterDetectionChecks)
    }
    catch {
        $allResults += Get-SupportDiagnosisModuleFailure '打印机' '打印机检测' $_.Exception.Message
    }
    $states['打印机'] = '完成'
    if (-not $Quiet) { Show-SupportDiagnosisProgress $states }

    $session = Set-SupportDiagnosticSession $allResults
    return $session
}

function Write-SupportUiCategorySummary {
    param($Session)
    foreach ($category in @('设备', 'Windows', '系统', '磁盘', '网络', '打印机')) {
        Write-SupportDashboardStatus $category ([string]$Session.CategoryStatuses[$category])
    }
}

function Get-SupportPrimaryProblem {
    param($Results)
    $problem = @($Results | Where-Object { $_.Status -eq 'FAIL' } | Select-Object -First 1)
    if ($problem.Count -eq 0) {
        $problem = @($Results | Where-Object { (Get-SupportUiItemStatus $_) -eq '注意' } | Select-Object -First 1)
    }
    if ($problem.Count -gt 0) { return $problem[0] }
    return $null
}

function Update-SupportDiagnosticSessionCategory {
    param(
        [string]$Category,
        $Results
    )
    $otherResults = @()
    if ($script:DiagnosticSession) {
        $otherResults = @($script:DiagnosticSession.Results | Where-Object { (Get-SupportUiCategory $_) -ne $Category })
    }
    return Set-SupportDiagnosticSession @($otherResults + @($Results))
}

function Invoke-SupportCategoryDiagnosis {
    param([string]$Category)
    $results = @()
    switch ($Category) {
        '设备' {
            try {
                $computerResults = @()
                $computerResults += @(Get-SupportComputerDetectionChecks)
                $computerResults += @(Get-SupportBatteryDetectionChecks)
                $results = @($computerResults | Where-Object { (Get-SupportUiCategory $_) -eq '设备' })
            }
            catch {
                $results = Get-SupportDiagnosisModuleFailure '电脑' '设备检测' $_.Exception.Message
            }
        }
        'Windows' {
            try {
                $computerResults = @(Get-SupportComputerDetectionChecks)
                $results = @($computerResults | Where-Object { (Get-SupportUiCategory $_) -eq 'Windows' })
            }
            catch {
                $results = Get-SupportDiagnosisModuleFailure '电脑' 'Windows 系统' $_.Exception.Message
            }
        }
        '系统' {
            try {
                $results += @(Get-SupportWindowsUpdateChecks)
                $results += @(Get-SupportSystemIntegrityChecks)
                $results += @(Get-SupportCriticalServiceChecks)
            }
            catch {
                $results = Get-SupportDiagnosisModuleFailure '系统' '系统检测' $_.Exception.Message
            }
        }
        '磁盘' {
            try { $results = @(Get-SupportDiskDetectionChecks) }
            catch { $results = Get-SupportDiagnosisModuleFailure '磁盘' '磁盘检测' $_.Exception.Message }
        }
        '网络' {
            try { $results = @(Get-SupportNetworkDiagnosis) }
            catch { $results = Get-SupportDiagnosisModuleFailure '网络' '网络检测' $_.Exception.Message }
        }
        '打印机' {
            try { $results = @(Get-SupportPrinterDetectionChecks) }
            catch { $results = Get-SupportDiagnosisModuleFailure '打印机' '打印机检测' $_.Exception.Message }
        }
    }
    if ($results.Count -eq 0) {
        $results = Get-SupportDiagnosisModuleFailure $Category ($Category + '检测') '未返回检测结果'
    }
    return @(Update-SupportDiagnosticSessionCategory $Category $results)
}

function Test-SupportCategoryHasRepair {
    param([string]$Category)
    switch ($Category) {
        '网络' { return $true }
        '打印机' { return $true }
        '系统' { return $true }
        'Windows' { return $true }
        '磁盘' { return $true }
        default { return $false }
    }
}

function Show-SupportNetworkTechnicalDetails {
    Write-SupportUiHeader '网络技术详情'
    Write-Host '适配器：' -ForegroundColor Cyan
    try {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceIndex, Status, MacAddress, InterfaceDescription, MediaType)
        if ($adapters.Count -gt 0) {
            $adapters | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        }
        else {
            Write-Host '未获取到适配器信息。' -ForegroundColor Gray
        }
    }
    catch {
        Write-Host ('适配器信息读取失败：' + $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host '默认路由：' -ForegroundColor Cyan
    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object ifIndex, NextHop, RouteMetric, InterfaceMetric)
        if ($routes.Count -gt 0) {
            $routes | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        }
        else {
            Write-Host '未获取到默认路由。' -ForegroundColor Gray
        }
    }
    catch {
        Write-Host ('默认路由读取失败：' + $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-PressAnyKeyToReturn
}

function Show-SupportCategoryDetail {
    param([string]$Category)
    while ($true) {
        $results = @(Get-SupportSessionCategoryResults $Category)
        if ($results.Count -eq 0) {
            Write-SupportUiHeader ($Category + '状态')
            Write-Host '[未检测] 当前分类尚未检测' -ForegroundColor Gray
            Write-Host ''
            Write-Host '[1] 开始检测'
            Write-Host '[0] 返回'
            Write-Host ''
            $choice = Read-MenuSelection 1
            if ($choice -eq 0) { return }
            $null = Invoke-SupportCategoryDiagnosis $Category
            continue
        }

        $status = Get-SupportUiCategoryStatus $results
        Write-SupportUiHeader ($Category + '状态')
        Write-Host ('[' + $status + '] ' + $Category + '总体状态') -ForegroundColor (Get-SupportUiStatusColor $status)
        Write-Host ''
        foreach ($item in $results) {
            $itemStatus = Get-SupportUiItemStatus $item
            Write-Host ('[' + $itemStatus + '] ' + $item.Name) -ForegroundColor (Get-SupportUiStatusColor $itemStatus)
            if ($itemStatus -ne '正常') {
                if ($item.Result) { Write-Host ('  结果：' + $item.Result) -ForegroundColor Gray }
                if ($item.Diagnosis) { Write-Host ('  诊断：' + $item.Diagnosis) -ForegroundColor Gray }
                if ($item.Recommendation) { Write-Host ('  建议：' + $item.Recommendation) -ForegroundColor Gray }
            }
        }
        Write-Host ''
        if ($status -eq '正常') {
            Write-Host '当前分类未发现需要处理的问题。' -ForegroundColor Green
        }

        $hasRepair = Test-SupportCategoryHasRepair $Category
        Write-Host ''
        Write-Host '[1] 重新检测'
        if ($hasRepair) { Write-Host '[2] 打开相关修复工具' }
        Write-Host '[3] 技术详情'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        switch ($choice) {
            1 {
                Write-Host ''
                Write-Host ('正在重新检测' + $Category + '...') -ForegroundColor Gray
                $null = Invoke-SupportCategoryDiagnosis $Category
                continue
            }
            2 {
                if (-not $hasRepair) { continue }
                switch ($Category) {
                    '网络' { Show-NetworkRepairMenu }
                    '打印机' { Show-PrinterMenu }
                    '系统' { Show-SystemRepairMenu }
                    'Windows' { Show-SystemRepairMenu }
                    '磁盘' { Show-DiskMenu }
                }
                $null = Invoke-SupportCategoryDiagnosis $Category
                continue
            }
            3 {
                Write-SupportUiHeader ($Category + '技术详情')
                foreach ($item in $results) {
                    Write-Host ('项目：' + $item.Name)
                    Write-Host ('状态：' + $item.Status)
                    Write-Host ('结果：' + $item.Result)
                    if ($item.AccessMode) { Write-Host ('访问方式：' + $item.AccessMode) }
                    if ($item.ActionCode) { Write-Host ('动作代码：' + $item.ActionCode) }
                    Write-Host ''
                }
                if ($Category -eq '网络') {
                    Show-SupportNetworkTechnicalDetails
                    continue
                }
                Write-PressAnyKeyToReturn
                continue
            }
            0 { return }
        }
    }
}

function Show-SupportCategoryList {
    while ($true) {
        Write-SupportUiHeader '分类状态'
        $categories = @('网络', '系统', '磁盘', 'Windows', '打印机', '设备')
        $idx = 1
        foreach ($category in $categories) {
            $results = @(Get-SupportSessionCategoryResults $category)
            $status = Get-SupportUiCategoryStatus $results
            Write-Host ($idx.ToString() + '. [' + (Get-SupportUiCategoryIcon $category) + '] ' + $category + '  [' + (Get-SupportUiStatusIcon $status) + '] ' + $status) -ForegroundColor (Get-SupportUiStatusColor $status)
            $idx++
        }
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection $categories.Count
        if ($choice -eq 0) { return }
        Show-SupportCategoryDetail $categories[$choice - 1]
    }
}

function Get-SupportNetworkRepairTargetName {
    param([string]$ActionCode)
    switch ($ActionCode) {
        'FlushDns' { return 'DNS 解析' }
        'RenewIp' { return 'IP 配置' }
        'RestartAdapter' { return '网络适配器' }
        default { return '' }
    }
}

function Invoke-SupportGuidedNetworkRepair {
    $results = @(Get-SupportSessionCategoryResults '网络')
    $action = Get-SupportNetworkRecommendedAction $results
    if (-not $action) {
        Write-SupportUiHeader '处理网络问题'
        Write-WarnText '当前没有可自动执行的网络修复建议。'
        Write-PressAnyKeyToReturn
        return
    }

    $targetName = Get-SupportNetworkRepairTargetName $action.Code
    $target = $results | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
    Write-SupportUiHeader '处理网络问题'
    Write-Host ('[问题] ' + $targetName) -ForegroundColor Red
    if ($target -and $target.Result) {
        Write-Host ('结果：' + $target.Result) -ForegroundColor Gray
    }
    if ($target -and $target.Diagnosis) {
        Write-Host ('诊断：' + $target.Diagnosis) -ForegroundColor Gray
    }
    if ($target -and $target.Recommendation) {
        Write-Host ('建议：' + $target.Recommendation) -ForegroundColor Gray
    }
    Write-Host ''
    if (-not (Get-SupportConfirmation '是否执行修复？')) {
        Write-NoticeText '操作已取消。'
        Write-PressAnyKeyToReturn
        return
    }

    Write-Host ''
    Write-Host '正在修复...' -ForegroundColor Cyan
    $fixOk = Invoke-SupportNetworkRecommendedAction -Action $action -SkipConfirmation
    if ($fixOk) {
        Write-Host ('[完成] ' + $action.MenuText.Replace('执行建议修复：', '')) -ForegroundColor Green
    }
    else {
        Write-Host '[注意] 修复命令未成功完成' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '正在重新检测...' -ForegroundColor Cyan
    $newResults = @(Get-SupportNetworkDiagnosis)
    $null = Update-SupportDiagnosticSessionCategory '网络' $newResults
    $newTarget = $newResults | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
    if ($newTarget) {
        $newStatus = Get-SupportUiItemStatus $newTarget
        Write-Host ('[' + $newStatus + '] ' + $newTarget.Name) -ForegroundColor (Get-SupportUiStatusColor $newStatus)
        if ($newTarget.Result) { Write-Host ('结果：' + $newTarget.Result) -ForegroundColor Gray }
    }

    $beforeFailures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $afterFailures = @($newResults | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Host ''
    if ($beforeFailures -gt 0 -and $afterFailures -eq 0) {
        Write-Host '[正常] 问题已解决' -ForegroundColor Green
    }
    elseif ($afterFailures -lt $beforeFailures) {
        Write-Host '[注意] 部分问题已解决，仍有异常项需要处理。' -ForegroundColor Yellow
    }
    elseif ($fixOk) {
        Write-Host '[注意] 修复操作已执行，但问题仍然存在。' -ForegroundColor Yellow
    }
    else {
        Write-Host '[注意] 修复未成功完成，问题仍然存在。' -ForegroundColor Yellow
    }
    Write-PressAnyKeyToReturn
}

function Invoke-SupportGuidedProblemRepair {
    $problem = Get-SupportPrimaryProblem $script:DiagnosticSession.Results
    if (-not $problem) {
        Write-WarnText '当前没有需要处理的诊断问题。'
        Write-PressAnyKeyToReturn
        return
    }
    $category = Get-SupportUiCategory $problem
    if ($category -eq '网络') {
        Invoke-SupportGuidedNetworkRepair
        return
    }

    Write-SupportUiHeader '处理问题'
    Write-Host ('[' + $category + '] ' + $problem.Name) -ForegroundColor Red
    if ($problem.Result) { Write-Host ('结果：' + $problem.Result) -ForegroundColor Gray }
    if ($problem.Diagnosis) { Write-Host ('诊断：' + $problem.Diagnosis) -ForegroundColor Gray }
    if ($problem.Recommendation) { Write-Host ('建议：' + $problem.Recommendation) -ForegroundColor Gray }
    Write-Host ''
    Write-Host '将打开该分类已有的修复工具；修复命令自身会再次确认具体操作。' -ForegroundColor Gray
    Write-PressAnyKeyToReturn

    switch ($category) {
        '打印机' { Invoke-SupportPrinterOneKeyFix }
        '系统' { Show-SystemRepairMenu }
        'Windows' { Show-SystemRepairMenu }
        '磁盘' { Show-DiskMenu }
        default { Show-SupportCategoryDetail $category; return }
    }

    Write-Host ''
    Write-Host '正在重新检测...' -ForegroundColor Cyan
    $null = Invoke-SupportCategoryDiagnosis $category
    $newResults = @(Get-SupportSessionCategoryResults $category)
    $newStatus = Get-SupportUiCategoryStatus $newResults
    Write-Host ''
    Write-Host ('[' + $newStatus + '] ' + $category + '当前状态') -ForegroundColor (Get-SupportUiStatusColor $newStatus)
    if ($newStatus -eq '正常') {
        Write-Host '[正常] 问题已解决' -ForegroundColor Green
    }
    else {
        Write-Host '[注意] 问题仍然存在，请查看详细结果。' -ForegroundColor Yellow
    }
    Write-PressAnyKeyToReturn
}

function Show-SupportFullDiagnosisDetails {
    param($Session)
    Write-SupportUiHeader '诊断详情'
    Show-SupportCategoryList
}

function Show-SupportFullDiagnosisResult {
    param($Session)
    while ($true) {
        Write-SupportUiHeader '全面诊断结果'
        Write-Host ('[' + (Get-SupportUiStatusIcon $Session.OverallStatus) + '] 电脑状态：' + $Session.OverallStatus) -ForegroundColor (Get-SupportUiStatusColor $Session.OverallStatus)
        Write-Host ('最近检查：' + $Session.GeneratedAt.ToString('HH:mm')) -ForegroundColor Gray
        Write-Host ''
        Write-SupportUiCategorySummary $Session
        Write-Host ''

        if ($Session.ProblemCount -eq 0 -and $Session.AttentionCount -eq 0) {
            Write-Host '未发现需要立即处理的问题。' -ForegroundColor Green
            Write-Host ''
            Write-Host '[1] 查看详细结果'
            Write-Host '[0] 返回'
            Write-Host ''
            $choice = Read-MenuSelection 1
            if ($choice -eq 0) { return }
            Show-SupportFullDiagnosisDetails $Session
            continue
        }

        $primaryProblem = Get-SupportPrimaryProblem $Session.Results
        Write-Host ('发现 ' + $Session.ProblemCount + ' 个问题，' + $Session.AttentionCount + ' 项注意。') -ForegroundColor Yellow
        if ($primaryProblem) {
            Write-Host ''
            Write-Host ((Get-SupportUiCategory $primaryProblem))
            Write-Host $primaryProblem.Result
            if ($primaryProblem.Diagnosis) {
                Write-Host ('诊断：' + $primaryProblem.Diagnosis) -ForegroundColor Gray
            }
            if ($primaryProblem.Recommendation) {
                Write-Host ('建议：' + $primaryProblem.Recommendation) -ForegroundColor Gray
            }
        }
        Write-Host ''
        Write-Host '[1] 处理问题'
        Write-Host '[2] 查看详细结果'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 2
        switch ($choice) {
            1 {
                Invoke-SupportGuidedProblemRepair
            }
            2 { Show-SupportFullDiagnosisDetails $Session }
            0 { return }
        }
    }
}

function Show-SupportDashboard {
    while ($true) {
        Write-SupportUiHeader '总览'
        if (-not $script:DiagnosticSession) {
            Write-SupportUiMascot 'work'
            Write-Host '[ -- ] 尚未完成全面诊断' -ForegroundColor Gray
            Write-Host ''
            Write-Host '最近检查：未检测' -ForegroundColor Gray
            Write-Host ''
            Write-SupportDashboardStatus '网络' '未检测'
            Write-SupportDashboardStatus '系统' '未检测'
            Write-SupportDashboardStatus '磁盘' '未检测'
            Write-SupportDashboardStatus 'Windows' '未检测'
            Write-SupportDashboardStatus '打印机' '未检测'
            Write-SupportDashboardStatus '设备' '未检测'
            Write-Host ''
            Write-Host '1. 开始全面诊断'
            Write-Host '0. 返回'
            Write-Host ''
            $choice = Read-MenuSelection 1
            switch ($choice) {
                1 {
                    $session = Invoke-SupportFullDiagnosis
                    Show-SupportFullDiagnosisResult $session
                }
                0 { return }
            }
            continue
        }

        $session = $script:DiagnosticSession
        $overallText = switch ($session.OverallStatus) {
            '正常' { '电脑运行正常' }
            '注意' { '电脑需要关注' }
            '问题' { '电脑发现问题' }
            default { '电脑尚未完成全面诊断' }
        }
        Write-Host ('[' + (Get-SupportUiStatusIcon $session.OverallStatus) + '] ' + $overallText) -ForegroundColor (Get-SupportUiStatusColor $session.OverallStatus)
        Write-Host ('最近检查：' + $session.GeneratedAt.ToString('HH:mm')) -ForegroundColor Gray
        if ($session.ProblemCount -gt 0 -or $session.AttentionCount -gt 0) {
            Write-Host ('问题 ' + $session.ProblemCount + ' 项，注意 ' + $session.AttentionCount + ' 项') -ForegroundColor Gray
        }
        Write-Host ''
        foreach ($category in @('网络', '系统', '磁盘', 'Windows', '打印机', '设备')) {
            Write-SupportDashboardStatus $category ([string]$session.CategoryStatuses[$category])
        }
        Write-Host ''
        Write-Host '1. 查看本次结果'
        Write-Host '2. 重新全面诊断'
        Write-Host '3. 查看分类详情'
        Write-Host '0. 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        switch ($choice) {
            1 {
                Show-SupportFullDiagnosisResult $script:DiagnosticSession
            }
            2 {
                $session = Invoke-SupportFullDiagnosis
                Show-SupportFullDiagnosisResult $session
            }
            3 {
                Show-SupportCategoryList
            }
            0 { return }
        }
    }
}

function Show-SupportDeviceToolbox {
    while ($true) {
        Write-SupportUiHeader '电脑相关'
        Write-Host '1. PC 信息'
        Write-Host '2. 设备状态'
        Write-Host '3. 配置信息'
        Write-Host '0. 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        switch ($choice) {
            1 {
                Show-SupportComputerInfo
                Write-PressAnyKeyToReturn
            }
            2 { Show-SupportCategoryDetail '设备' }
            3 { Show-SupportComputerConfiguration }
            0 { return }
        }
    }
}

function Show-SupportToolbox {
    while ($true) {
        Write-SupportUiHeader '工具箱'
        Write-Host '1. 网络'
        Write-Host '2. 打印机'
        Write-Host '3. 系统'
        Write-Host '4. 磁盘'
        Write-Host '5. 软件'
        Write-Host '6. 电脑相关'
        Write-Host '0. 返回'
        Write-Host ''
        $choice = Read-MenuSelection 6
        Write-Host ''
        switch ($choice) {
            1 { Show-NetworkMenu }
            2 { Show-PrinterMenu }
            3 { Show-SystemRepairMenu }
            4 { Show-DiskMenu }
            5 { Show-SoftwareMenu }
            6 { Show-SupportDeviceToolbox }
            0 { return }
        }
    }
}

function Show-SupportSessionReportExport {
    if (-not $script:DiagnosticSession) {
        Write-WarnText '当前没有本次诊断结果。'
        Write-PressAnyKeyToReturn
        return
    }
    while ($true) {
        Write-SupportUiHeader '导出本次诊断'
        Write-Host '[1] 导出 TXT'
        Write-Host '[2] 导出 JSON'
        Write-Host '[3] 导出 TXT + JSON'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        if ($choice -eq 0) { return }

        Write-Host ''
        Write-Host '正在生成报告...' -ForegroundColor Gray
        $snapshot = New-SupportReportSnapshot -DetectionResults $script:DiagnosticSession.Results
        try {
            if (-not (Test-SupportPathExists $script:ReportDir)) {
                New-Item -ItemType Directory -Path $script:ReportDir -Force -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-ErrorText ('无法创建报告目录：' + $_.Exception.Message)
            Write-PressAnyKeyToReturn
            continue
        }

        $stamp = Get-SupportTimeStamp
        $exported = @()
        if ($choice -eq 1 -or $choice -eq 3) {
            $path = Export-SupportReportTxt ('ITSupportReport_' + $stamp + '.txt') $snapshot
            if ($path) { $exported += $path }
        }
        if ($choice -eq 2 -or $choice -eq 3) {
            $path = Export-SupportReportJson ('ITSupportReport_' + $stamp + '.json') $snapshot
            if ($path) { $exported += $path }
        }
        Write-Host ''
        if ($exported.Count -gt 0) {
            Write-OkText '报告导出成功：'
            foreach ($path in $exported) {
                Write-Host ('  ' + $path) -ForegroundColor Green
            }
        }
        else {
            Write-ErrorText '报告导出失败，请查看日志。'
        }
        Write-PressAnyKeyToReturn
    }
}

function Show-SupportReportCenter {
    while ($true) {
        Write-SupportUiHeader '报告'
        Write-Host '[1] 本次诊断结果'
        Write-Host '[2] 历史报告'
        Write-Host '[3] 导出报告'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        Write-Host ''
        switch ($choice) {
            1 {
                if (-not $script:DiagnosticSession) {
                    Write-WarnText '当前没有本次诊断结果。'
                }
                else {
                    Show-SupportFullDiagnosisResult $script:DiagnosticSession
                    continue
                }
                Write-PressAnyKeyToReturn
            }
            2 {
                Write-SubTitle '历史报告'
                if (-not (Test-SupportPathExists $script:ReportDir)) {
                    Write-NoticeText '报告目录尚不存在。'
                }
                else {
                    $reports = @(Get-ChildItem -LiteralPath $script:ReportDir -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending)
                    if ($reports.Count -eq 0) {
                        Write-NoticeText '暂无历史报告。'
                    }
                    else {
                        foreach ($report in $reports) {
                            Write-Host ('- ' + $report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $report.Name)
                        }
                        Write-Host ''
                        Write-NoticeText ('报告目录：' + $script:ReportDir)
                    }
                }
                Write-PressAnyKeyToReturn
            }
            3 { Show-SupportSessionReportExport }
            0 { return }
        }
    }
}

function Show-SupportMainMenu {
    while ($true) {
        Write-SupportUiHeader '主菜单'
        Write-SupportUiMascot
        Write-Host '1. 总览          查看电脑健康状态'
        Write-Host '2. 工具箱        网络、系统、打印机等工具'
        Write-Host '3. 报告          查看或导出诊断报告'
        Write-Host '0. 退出          安全关闭小助手'
        Write-Host ''
        $choice = Read-MenuSelection 3
        switch ($choice) {
            1 { Show-SupportDashboard }
            2 { Show-SupportToolbox }
            3 { Show-SupportReportCenter }
            0 {
                Write-Host ''
                Write-Host '感谢使用 WinSupport 小助手，祝你的电脑一直健健康康！' -ForegroundColor Green
                Write-Log '工具退出'
                exit 0
            }
        }
    }
}

# ===========================================================================
# 启动与主菜单
# ===========================================================================

function Initialize-Toolkit {
    Set-SupportConsoleEncoding

    if (-not (Test-SupportWindows)) {
        Write-Host '本工具仅支持 Windows，请在 Windows 10 / Windows 11 上运行。' -ForegroundColor Red
        Write-Log '在非 Windows 环境运行' 'WARN'
        exit 1
    }

    [void](Test-SupportAdmin)
    [void](Initialize-SupportWinget)

    try {
        if (-not (Test-Path -LiteralPath $script:ReportDir)) {
            New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
    }
    catch {}

    Write-Log ('工具启动，用户 ' + (Get-SupportCurrentUser))

    if (-not $SkipBanner) {
        Write-Banner
        $bannerComputer = $env:COMPUTERNAME
        if (-not $bannerComputer) {
            try { $bannerComputer = [System.Environment]::MachineName } catch {}
        }
        if (-not $bannerComputer) { $bannerComputer = '无法获取' }
        Write-Host ('计算机名：' + $bannerComputer)
        Write-Host ('当前用户：' + (Get-SupportCurrentUser))
        Write-Host ('PowerShell：' + $PSVersionTable.PSVersion.ToString() + '（' + $PSVersionTable.PSEdition + '）')
        if ($script:IsAdminUser) {
            Write-Host '管理员权限：是' -ForegroundColor Green
        }
        else {
            Write-Host '管理员权限：否（仅可查看信息，修复类功能需以管理员身份运行）' -ForegroundColor Yellow
        }
        if ($script:HasWinget) {
            Write-Host 'winget：可用' -ForegroundColor Green
        }
        else {
            Write-Host 'winget：不可用（软件管理功能将不可用）' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-PressAnyKeyToReturn
    }
}

function Show-MainMenu {
    while ($true) {
        Write-Banner
        Write-Host '[1] 一键检测'
        Write-Host '[2] 网络'
        Write-Host '[3] 打印机'
        Write-Host '[4] 系统修复'
        Write-Host '[5] 磁盘'
        Write-Host '[6] 软件'
        Write-Host '[7] 电脑信息'
        Write-Host '[8] 导出报告'
        Write-Host '[0] 退出'
        Write-Host ''
        $choice = Read-MenuSelection 8
        Write-Host ''
        switch ($choice) {
            1 {
                $null = Invoke-OneClickCheck
                Write-PressAnyKeyToReturn
            }
            2 { Show-NetworkMenu }
            3 { Show-PrinterMenu }
            4 { Show-SystemRepairMenu }
            5 { Show-DiskMenu }
            6 { Show-SoftwareMenu }
            7 {
                Show-SupportComputerInfo
                Write-PressAnyKeyToReturn
            }
            8 { Show-ReportMenu }
            0 {
                Write-Host '感谢使用 Windows IT Support Toolkit，再见。' -ForegroundColor Green
                Write-Log '工具退出'
                exit 0
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Initialize-Toolkit
    if ($Console) { Write-Log '以兼容控制台模式启动' }
    Show-SupportMainMenu
}
