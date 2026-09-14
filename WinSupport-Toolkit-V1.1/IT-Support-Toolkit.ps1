#Requires -Version 5.1
<#
============================================================================
  Windows IT Support Toolkit V1.1
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
    [switch]$SkipBanner
)

$ErrorActionPreference = 'Continue'

$script:ToolName    = 'Windows IT Support Toolkit'
$script:ToolVersion = '1.1'
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

function Initialize-SupportConsoleNative {
    if ('WinSupport.ConsoleNative' -as [type]) {
        return $true
    }
    try {
        $nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace WinSupport {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct Coord {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct ConsoleFontInfoEx {
        public int cbSize;
        public int nFont;
        public Coord dwFontSize;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }

    public static class ConsoleNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleCP(uint codePage);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleOutputCP(uint codePage);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool GetCurrentConsoleFontEx(
            IntPtr consoleOutput,
            bool maximumWindow,
            ref ConsoleFontInfoEx consoleCurrentFontEx);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool SetCurrentConsoleFontEx(
            IntPtr consoleOutput,
            bool maximumWindow,
            ref ConsoleFontInfoEx consoleCurrentFontEx);
    }
}
'@
        Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Set-SupportConsoleFont {
    if (-not (Initialize-SupportConsoleNative)) {
        return $null
    }
    try {
        $outputHandle = [WinSupport.ConsoleNative]::GetStdHandle(-11)
        if ($outputHandle -eq [IntPtr]::Zero -or $outputHandle.ToInt64() -eq -1) {
            return $null
        }
        $fontInfo = New-Object WinSupport.ConsoleFontInfoEx
        $fontInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($fontInfo)
        if (-not [WinSupport.ConsoleNative]::GetCurrentConsoleFontEx($outputHandle, $false, [ref]$fontInfo)) {
            return $null
        }
        foreach ($fontName in @('NSimSun', 'Noto Sans SC', 'Microsoft YaHei')) {
            $fontInfo.FaceName = $fontName
            if ([WinSupport.ConsoleNative]::SetCurrentConsoleFontEx($outputHandle, $false, [ref]$fontInfo)) {
                return $fontName
            }
        }
    }
    catch {}
    return $null
}

function Set-SupportConsoleEncoding {
    # Keep direct .ps1 launches consistent with the UTF-8 code page set by run.bat.
    if (Initialize-SupportConsoleNative) {
        try { [void][WinSupport.ConsoleNative]::SetConsoleCP(65001) } catch {}
        try { [void][WinSupport.ConsoleNative]::SetConsoleOutputCP(65001) } catch {}
    }
    try { & chcp.com 65001 | Out-Null } catch {}

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        $utf8 = [System.Text.Encoding]::UTF8
    }
    try { [Console]::InputEncoding = $utf8 } catch {}
    try { [Console]::OutputEncoding = $utf8 } catch {}
    try { $script:OutputEncoding = $utf8 } catch {}
    try { $script:ConsoleFontName = Set-SupportConsoleFont } catch {}
}

function Write-Banner {
    Clear-Host -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '       Windows IT Support Toolkit' -ForegroundColor Cyan
    Write-Host '       V1.1 - IT Support 日常运维工具' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
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
        $answer = Read-Host '请选择'
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
        if ($ArgumentList.Count -gt 0) {
            & $FilePath @ArgumentList
        }
        else {
            & $FilePath
        }
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

function Get-SupportProxyInfo {
    $proxy = [pscustomobject]@{
        Enabled  = $false
        Server   = ''
        Bypass   = ''
        Summary  = '未启用代理'
    }
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $key = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($key -and $key.ProxyEnable -and ([int]$key.ProxyEnable -eq 1)) {
            $proxy.Enabled = $true
            $proxy.Server = [string]$key.ProxyServer
            $proxy.Bypass = [string]$key.ProxyOverride
            if ($proxy.Server) {
                $proxy.Summary = ('已启用代理：' + $proxy.Server)
            }
            else {
                $proxy.Summary = '已启用代理（未设置服务器）'
            }
        }
    }
    catch {}
    return $proxy
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

function Test-SupportTcpConnect {
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
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
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

function Get-SupportNetworkDiagnosis {
    $results = @()
    Write-Host '正在检测网络，请稍候...' -ForegroundColor Gray

    # 1 网络适配器
    $adapters = @(Get-SupportNetworkAdapterInfo)
    if ($adapters.Count -gt 0) {
        $results += New-SupportReportObject '检测' '网络' '网络适配器' '正常' ('检测到 ' + $adapters.Count + ' 个已启用的网络适配器')
    }
    else {
        $results += New-SupportReportObject '检测' '网络' '网络适配器' '异常' '未检测到已启用并获取 IP 的网卡'
    }

    # 2 IP 地址
    $hasIp = $false
    foreach ($ad in $adapters) {
        foreach ($ip in $ad.IPAddresses) {
            if ($ip -notmatch '^127\.' -and $ip -notmatch '^169\.254\.') {
                $hasIp = $true
                break
            }
        }
        if ($hasIp) { break }
    }
    if ($hasIp) {
        $results += New-SupportReportObject '检测' '网络' 'IP地址' '正常' '本机已获取有效 IP 地址'
    }
    else {
        $results += New-SupportReportObject '检测' '网络' 'IP地址' '异常' '本机没有有效的 IPv4 地址'
    }

    # 3 默认网关
    $gateway = Get-SupportPrimaryGateway
    if ($gateway) {
        $results += New-SupportReportObject '检测' '网络' '默认网关' '正常' ('网关：' + $gateway)
    }
    else {
        $results += New-SupportReportObject '检测' '网络' '默认网关' '异常' '未获取到默认网关'
    }

    # 4 Ping 网关
    if ($gateway) {
        $gwOk = Test-SupportPing -Target $gateway -Count 2
        if ($gwOk) {
            $results += New-SupportReportObject '检测' '网络' '网关连接' '正常' '可以 Ping 通默认网关'
        }
        else {
            $results += New-SupportReportObject '检测' '网络' '网关连接' '警告' 'Ping 网关超时（部分网络会屏蔽 Ping）'
        }
    }

    # 5 Ping 公网 IP
    $internetTargets = @('223.5.5.5', '114.114.114.114', '8.8.8.8')
    $internetOk = $false
    $reachableTarget = ''
    foreach ($target in $internetTargets) {
        if (Test-SupportPing -Target $target -Count 1) {
            $internetOk = $true
            $reachableTarget = $target
            break
        }
    }
    if ($internetOk) {
        $results += New-SupportReportObject '检测' '网络' 'Internet' '正常' ('可以访问公网（' + $reachableTarget + '）')
    }
    else {
        $results += New-SupportReportObject '检测' '网络' 'Internet' '异常' 'Ping 公网 IP 均失败'
    }

    # 6 DNS 解析
    $dnsOk = Test-SupportDnsResolution
    if ($dnsOk) {
        $results += New-SupportReportObject '检测' '网络' 'DNS解析' '正常' '域名解析正常'
    }
    else {
        $results += New-SupportReportObject '检测' '网络' 'DNS解析' '异常' '无法解析域名'
    }

    # 7 TCP 443
    $tcpOk = Test-SupportTcpConnect 'www.microsoft.com' 443
    if ($tcpOk) {
        $results += New-SupportReportObject '检测' '网络' 'TCP 443' '正常' 'HTTPS 连接测试正常'
    }
    else {
        $results += New-SupportReportObject '检测' '网络' 'TCP 443' '异常' 'HTTPS(443) 连接测试失败'
    }

    return $results
}

function Show-SupportNetworkDiagnosis {
    Write-SectionTitle '网络诊断'
    $results = @(Get-SupportNetworkDiagnosis)
    Write-Host ''
    foreach ($r in $results) {
        switch ($r.Status) {
            '正常' { Write-Host ('[正常] ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Green }
            '警告' { Write-Host ('[警告] ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Yellow }
            default { Write-Host ('[异常] ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Red }
        }
    }

    Write-Host ''
    Write-SubTitle '结论'
    $adapterBad = @($results | Where-Object { $_.Check -eq '网络适配器' -and $_.Status -eq '异常' }).Count -gt 0
    $ipBad = @($results | Where-Object { $_.Check -eq 'IP地址' -and $_.Status -eq '异常' }).Count -gt 0
    $gwBad = @($results | Where-Object { $_.Check -eq '默认网关' -and $_.Status -eq '异常' }).Count -gt 0
    $gwWarn = @($results | Where-Object { $_.Check -eq '网关连接' -and $_.Status -eq '警告' }).Count -gt 0
    $netBad = @($results | Where-Object { $_.Check -eq 'Internet' -and $_.Status -eq '异常' }).Count -gt 0
    $dnsBad = @($results | Where-Object { $_.Check -eq 'DNS解析' -and $_.Status -eq '异常' }).Count -gt 0
    $tcpBad = @($results | Where-Object { $_.Check -eq 'TCP 443' -and $_.Status -eq '异常' }).Count -gt 0

    if ($adapterBad -or $ipBad) {
        Write-Host '网络适配器异常或未获取到 IP，请检查网线/Wi-Fi 开关，或尝试重新获取 IP。'
    }
    elseif ($gwBad) {
        Write-Host '网络已连接但没有默认网关，请尝试「重新获取 IP」或联系网络管理员。'
    }
    elseif ($netBad) {
        Write-Host '网络连接存在，但无法访问公网，请检查路由、防火墙或联系网络管理员。'
    }
    elseif ($dnsBad) {
        Write-Host '网络连接正常，但 DNS 解析异常，建议刷新 DNS 或更换 DNS 服务器。'
    }
    elseif ($tcpBad) {
        Write-Host '基本网络正常，但 HTTPS 连接异常，可能是防火墙/代理设置导致。'
    }
    elseif ($gwWarn) {
        Write-Host '基本正常。网关 Ping 不通但公网可访问，通常是网关设备屏蔽了 Ping，不影响使用。'
    }
    else {
        Write-Host '网络连接正常。' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '如需进一步修复，可在「网络 -> 网络修复」中选择对应操作。' -ForegroundColor Gray
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
}

function Invoke-NetworkRenewIp {
    Write-SubTitle '重新获取 IP'
    if (-not (Get-SupportConfirmation '此操作会短暂断开网络并重新获取 IP。是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    Write-Host '正在释放 IP（ipconfig /release）...'
    $null = Invoke-SupportNativeCommand 'ipconfig.exe' @('/release')
    Write-Host '正在重新获取 IP（ipconfig /renew）...'
    $code = Invoke-SupportNativeCommand 'ipconfig.exe' @('/renew')
    if ($code -eq 0) {
        Write-OkText 'IP 已重新获取。'
    }
    else {
        Write-WarnText '重新获取 IP 命令返回异常。如果使用静态 IP 或公司网络策略，这属于正常情况。'
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
    Write-SubTitle '重启网络适配器'
    $ad = Get-SupportDefaultNetworkAdapter
    if (-not $ad) {
        Write-WarnText '无法确定要重启的网络适配器。'
        return
    }
    Write-Host ('将重启网卡：' + $ad.Name + '（' + $ad.InterfaceDescription + '）')
    Write-Host '重启过程中网络会暂时断开。' -ForegroundColor Yellow
    if (-not (Get-SupportConfirmation '是否继续？')) {
        Write-NoticeText '操作已取消。'
        return
    }
    if (-not (Confirm-SupportAdminOperation '重启网卡需要管理员权限。')) {
        return
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
    }
    catch {
        Write-ErrorText ('重启网卡失败：' + $_.Exception.Message)
        Write-Log ('重启网卡失败: ' + $_.Exception.Message) 'ERROR'
        try {
            Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {}
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
    foreach ($r in $results) {
        switch ($r.Status) {
            '正常' { Write-OkText ($r.Check + ' - ' + $r.Message) }
            '警告' { Write-WarnText ($r.Check + ' - ' + $r.Message) }
            default { Write-ErrorText ($r.Check + ' - ' + $r.Message) }
        }
    }
    $stillBad = @($results | Where-Object { $_.Status -eq '异常' }).Count
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
            1 { Invoke-NetworkFlushDns }
            2 { Invoke-NetworkRenewIp }
            3 { Invoke-NetworkResetWinsock }
            4 { Invoke-NetworkResetTcpIp }
            5 { Invoke-NetworkRestartAdapter }
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
        Write-Host '[2] 网络诊断'
        Write-Host '[3] 网络修复'
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection 3
        Write-Host ''
        switch ($choice) {
            1 {
                Show-SupportNetworkInfo
                Write-PressAnyKeyToReturn
            }
            2 {
                Show-SupportNetworkDiagnosis
                Write-PressAnyKeyToReturn
            }
            3 { Show-NetworkRepairMenu }
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

function Show-PrinterMenu {
    while ($true) {
        Write-SectionTitle '打印机'
        Write-Host '[1] 查看打印机'
        Write-Host '[2] 查看打印队列'
        Write-Host '[3] 清理打印队列'
        Write-Host '[4] 重启打印服务'
        Write-Host '[5] 一键修复打印机'
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
                Invoke-SupportPrinterOneKeyFix
                Write-PressAnyKeyToReturn
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
        $idx = 1
        foreach ($item in $software) {
            $desc = ''
            if ($item.Description) { $desc = ' - ' + $item.Description }
            Write-Host ('[{0}] {1}（{2}）{3}' -f $idx, $item.Name, $item.PackageId, $desc)
            $idx++
        }
        Write-Host '[0] 返回'
        Write-Host ''
        $choice = Read-MenuSelection $software.Count
        Write-Host ''
        if ($choice -eq 0) { return }
        $selected = $software[$choice - 1]
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
                Write-OkText ($selected.Name + ' 安装完成。')
            }
            else {
                Write-WarnText ('winget 返回退出码 ' + $code + '，请根据上方输出检查失败原因。')
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
    $code = Invoke-SupportNativeCommand 'winget.exe' @('search', '--query', $keyword, '--accept-source-agreements')
    Write-Host ''
    if ($code -ne 0) {
        Write-WarnText ('winget 搜索返回退出码 ' + $code + '。')
    }
    Write-Host '提示：请记录结果中的完整 ID（例如 Google.Chrome），用于安装/卸载。' -ForegroundColor Gray
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
        Write-OkText '软件安装完成。'
    }
    else {
        Write-WarnText ('winget 返回退出码 ' + $code + '。如果 ID 不正确，请先使用「搜索软件」获取完整 ID。')
    }
}

function Invoke-SoftwareUninstall {
    Write-SubTitle '卸载软件'
    Write-Host '以下为本机 winget 可识别的已安装软件：'
    Write-Host ''
    $null = Invoke-SupportNativeCommand 'winget.exe' @('list', '--accept-source-agreements')
    Write-Host ''
    $package = Read-Host '请输入要卸载的软件 ID（直接回车返回）'
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
        Write-OkText '软件已卸载。'
    }
    else {
        Write-WarnText ('winget 返回退出码 ' + $code + '，部分软件（如 Microsoft 365）可能需要从系统设置中卸载。')
    }
}

function Invoke-SoftwareUpdate {
    Write-SubTitle '更新软件'
    Write-Host '正在检查可更新软件，请稍候...'
    $null = Invoke-SupportNativeCommand 'winget.exe' @('upgrade', '--accept-source-agreements')
    Write-Host ''
    if (Get-SupportConfirmation '是否更新全部可更新的软件？更新过程可能需要较长时间。') {
        if (-not (Confirm-SupportAdminOperation '更新部分软件可能需要管理员权限。')) {
            return
        }
        Write-Host '正在更新全部软件，请稍候（可能需要较长时间）...'
        $code = Invoke-SupportNativeCommand 'winget.exe' @('upgrade', '--all', '--accept-source-agreements', '--accept-package-agreements')
        if ($code -eq 0) {
            Write-OkText '软件更新完成。'
        }
        else {
            Write-WarnText ('winget 返回退出码 ' + $code + '。部分软件可能需要重启电脑或由用户完成交互。')
        }
    }
    else {
        Write-NoticeText '已取消更新。'
    }
}

function Invoke-SoftwareInstalledList {
    Write-SubTitle '已安装软件'
    Write-Host '正在读取列表（winget 首次使用可能需要下载源信息，请耐心等待）...'
    $code = Invoke-SupportNativeCommand 'winget.exe' @('list', '--accept-source-agreements')
    if ($code -ne 0) {
        Write-WarnText ('winget list 返回退出码 ' + $code + '。')
    }
    $filter = Read-Host '输入关键字可再次筛选，直接回车结束'
    if ($filter) {
        Write-Host ''
        $null = Invoke-SupportNativeCommand 'winget.exe' @('list', '--name', $filter, '--accept-source-agreements')
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
        $results += New-SupportReportObject '检测' '电脑' 'Windows' '正常' $f.OsCaption
    }
    else {
        $results += New-SupportReportObject '检测' '电脑' 'Windows' '异常' '无法获取 Windows 版本信息'
    }
    if ($f.Cpu -and $f.Cpu -ne '无法获取') {
        $cpuShort = $f.Cpu
        if ($cpuShort.Length -gt 70) { $cpuShort = $cpuShort.Substring(0, 70) + '...' }
        $results += New-SupportReportObject '检测' '电脑' 'CPU' '正常' $cpuShort
    }
    else {
        $results += New-SupportReportObject '检测' '电脑' 'CPU' '异常' '无法获取 CPU 信息'
    }
    if ($f.MemoryTotal -and $f.MemoryTotal -ne '无法获取') {
        $results += New-SupportReportObject '检测' '电脑' '内存' '正常' ('总内存 ' + $f.MemoryTotal)
    }
    else {
        $results += New-SupportReportObject '检测' '电脑' '内存' '异常' '无法获取内存信息'
    }
    if ($f.Gpu -and $f.Gpu -ne '无法获取') {
        $gpuShort = $f.Gpu
        if ($gpuShort.Length -gt 80) { $gpuShort = $gpuShort.Substring(0, 80) + '...' }
        $results += New-SupportReportObject '检测' '电脑' 'GPU' '正常' $gpuShort
    }
    else {
        $results += New-SupportReportObject '检测' '电脑' 'GPU' '提示' '无法获取 GPU 信息（虚拟机或无显示设备时属正常）'
    }
    return $results
}

function Get-SupportDiskDetectionChecks {
    $results = @()
    $disks = @(Get-SupportDiskInfo)
    $systemDisk = $disks | Where-Object { $_.DriveLetter -eq 'C:' } | Select-Object -First 1
    if (-not $systemDisk) {
        $results += New-SupportReportObject '检测' '磁盘' '系统磁盘' '异常' '未找到 C 盘信息'
        return $results
    }
    $usedPercent = [double]$systemDisk.UsedPercent
    $message = ('C盘：总容量 ' + $systemDisk.TotalText + '，已用 ' + $systemDisk.UsedText + '（' + $systemDisk.UsedPercentText + '），剩余 ' + $systemDisk.FreeText)
    if ($usedPercent -ge 95) {
        $results += New-SupportReportObject '检测' '磁盘' '系统磁盘' '异常' $message
    }
    elseif ($usedPercent -ge 90) {
        $results += New-SupportReportObject '检测' '磁盘' '系统磁盘' '警告' $message
    }
    else {
        $results += New-SupportReportObject '检测' '磁盘' '系统磁盘' '正常' $message
    }
    return $results
}

function Get-SupportBatteryDetectionChecks {
    $results = @()
    $bat = Get-SupportBattery
    if (-not $bat.HasBattery) {
        $results += New-SupportReportObject '检测' '电池' '电池' '提示' '未检测到电池（台式机或虚拟机）'
        return $results
    }
    $batteryText = '电量 ' + $bat.ChargeText
    if ($bat.PowerStatusText) {
        $batteryText += '，' + $bat.PowerStatusText
    }
    if ($bat.ChargePercent -ne $null -and $bat.ChargePercent -lt 20) {
        $results += New-SupportReportObject '检测' '电池' '电池' '警告' ($batteryText + '，电量偏低')
    }
    else {
        $results += New-SupportReportObject '检测' '电池' '电池' '正常' $batteryText
    }
    if ($bat.HealthPercent -ne $null) {
        if ($bat.HealthPercent -lt 80) {
            $results += New-SupportReportObject '检测' '电池' '电池健康' '警告' ('设计容量对比当前充满容量约为 ' + $bat.HealthPercentText)
        }
        else {
            $results += New-SupportReportObject '检测' '电池' '电池健康' '正常' ('电池健康度约 ' + $bat.HealthPercentText)
        }
    }
    else {
        $results += New-SupportReportObject '检测' '电池' '电池健康' '提示' '无法获取电池健康信息（设备或驱动不支持）'
    }
    return $results
}

function Get-SupportPrinterDetectionChecks {
    $results = @()
    $printers = @(Get-SupportPrinters)
    if ($printers.Count -eq 0) {
        $results += New-SupportReportObject '检测' '打印机' '打印机' '正常' '未检测到打印机'
        return $results
    }
    foreach ($p in $printers) {
        $mark = ''
        if ($p.IsDefault) { $mark = '（默认）' }
        if ($p.Status -match '离线|停止') {
            $results += New-SupportReportObject '检测' '打印机' '打印机' '异常' ($p.Name + $mark + '：' + $p.Status)
        }
        else {
            $results += New-SupportReportObject '检测' '打印机' '打印机' '正常' ($p.Name + $mark + '：' + $p.Status)
        }
    }
    return $results
}

function Get-SupportDetectionAll {
    $all = @()
    $all += Get-SupportComputerDetectionChecks
    $all += @(Get-SupportNetworkDiagnosis)
    $all += Get-SupportDiskDetectionChecks
    $all += Get-SupportBatteryDetectionChecks
    $all += Get-SupportPrinterDetectionChecks
    return @($all)
}

function Get-SupportIssueSuggestion {
    param([string]$Check)
    switch -Regex ($Check) {
        'DNS解析' { return 'DNS解析可能存在异常。建议进入「网络 -> 网络修复 -> 刷新 DNS」，或检查 DNS 设置。' }
        'TCP 443' { return 'HTTPS 连接失败，建议进入「网络」进一步诊断（检查代理/防火墙）。' }
        'Internet' { return '无法访问公网，建议进入「网络 -> 网络诊断」进一步检查。' }
        '默认网关' { return '未获取到默认网关，建议进入「网络 -> 网络修复 -> 重新获取 IP」。' }
        'IP地址' { return '本机没有有效 IP，建议检查网线/Wi-Fi 连接后重新获取 IP。' }
        '网络适配器' { return '网络适配器异常，请检查硬件或驱动。' }
        '系统磁盘' { return 'C 盘空间使用率较高，建议进入「磁盘」查看空间并清理临时文件。' }
        '电池' { return '电池电量或健康度需要关注，建议检查电源设置或联系硬件支持。' }
        '打印机' { return '打印机存在异常，建议进入「打印机 -> 一键修复打印机」。' }
        default { return ('"' + $Check + '" 需要进一步检查，可进入对应功能菜单操作。') }
    }
}

function Write-SupportDetectionResults {
    param($Results)
    foreach ($r in $Results) {
        $prefix = '[' + $r.Status + ']'
        switch ($r.Status) {
            '正常' { Write-Host ($prefix + ' ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Green }
            '警告' { Write-Host ($prefix + ' ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Yellow }
            '异常' { Write-Host ($prefix + ' ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Red }
            default { Write-Host ($prefix + ' ' + $r.Check + ' - ' + $r.Message) -ForegroundColor Gray }
        }
    }
}

function Invoke-OneClickCheck {
    Write-SectionTitle '一键检测'
    Write-Host '正在检查电脑、网络、磁盘、电池和打印机，请稍候...' -ForegroundColor Gray
    $all = @(Get-SupportDetectionAll)
    Write-Host ''
    Write-Host '========== 检测结果 ==========' -ForegroundColor Cyan
    Write-Host ''
    Write-SupportDetectionResults $all
    Write-Host ''

    $problemItems = @($all | Where-Object { $_.Status -eq '异常' })
    $warnItems = @($all | Where-Object { $_.Status -eq '警告' })
    $problemCount = $problemItems.Count + $warnItems.Count
    if ($problemCount -eq 0) {
        Write-OkText ('共检测 ' + $all.Count + ' 项，全部正常。')
    }
    else {
        if ($problemItems.Count -gt 0) {
            Write-Host ('发现 ' + $problemItems.Count + ' 个问题：') -ForegroundColor Yellow
            $idx = 1
            foreach ($p in $problemItems) {
                Write-Host ('' + $idx + '. ' + $p.Check + '：' + (Get-SupportIssueSuggestion $p.Check))
                $idx++
            }
        }
        if ($warnItems.Count -gt 0) {
            Write-Host ('另有 ' + $warnItems.Count + ' 项警告：') -ForegroundColor Gray
            $idx = 1
            foreach ($w in $warnItems) {
                Write-Host ('' + $idx + '. ' + $w.Check + '：' + (Get-SupportIssueSuggestion $w.Check))
                $idx++
            }
        }
        Write-Host ''
        Write-Host '可在主菜单选择对应功能进一步处理。' -ForegroundColor Gray
    }
    return $all
}

# ===========================================================================
# 导出报告
# ===========================================================================

function New-SupportReportSnapshot {
    $computer = Get-SupportComputerFacts
    $detection = @(Get-SupportDetectionAll)
    $disks = @(Get-SupportDiskInfo)
    $battery = Get-SupportBattery
    $printers = @(Get-SupportPrinters)
    return [pscustomobject]@{
        ToolName       = $script:ToolName
        ToolVersion    = $script:ToolVersion
        GeneratedAt    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Computer       = $computer
        Detection      = $detection
        Disk           = $disks
        Battery        = $battery
        Printers       = $printers
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
        [void]$sb.AppendLine('[' + $r.Status + '] ' + $r.Check + ' - ' + $r.Message)
    }
    [void]$sb.AppendLine('')

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
        [void]$sb.AppendLine('[' + $r.Status + '] ' + $r.Category + '/' + $r.Check + ' - ' + $r.Message)
    }
    $abnormalCount = @($Snapshot.Detection | Where-Object { $_.Status -eq '异常' }).Count
    $warnCount = @($Snapshot.Detection | Where-Object { $_.Status -eq '警告' }).Count
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('问题统计：异常 ' + $abnormalCount + ' 项，警告 ' + $warnCount + ' 项')
    [void]$sb.AppendLine('')
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

Initialize-Toolkit
Show-MainMenu
