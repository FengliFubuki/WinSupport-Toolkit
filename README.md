# Windows IT Support Toolkit V1.3

面向 IT Support / Desktop Support 的 Windows 日常运维辅助工具。使用 PowerShell + Windows 自带命令 + winget 实现，无第三方依赖。
当前为 V1.3 开发版本，新增 WPF GUI 初版，同时保留控制台兼容入口。

## 版本定位

- V1.0 = Stable：已完成 Windows 10 / Windows 11 实机测试，视为稳定基线。
- V1.1 = Diagnostic Engine / Network Diagnosis Upgrade：诊断引擎基础、网络诊断升级、一键诊断汇总、重新检测和结构化报告兼容。
- V1.2 = Network Environment：代理、VPN/TUN、公网出口、出口地区及中国大陆/海外网络可达性检测。
- V1.3 = WPF GUI Foundation：使用 PowerShell + WPF + XAML 提供总览、全面诊断、分类详情和报告页面。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `IT-Support-Toolkit.ps1` | 主程序（所有功能） |
| `run.bat` | 双击启动入口，默认启动 WPF GUI；使用 `run.bat --console` 进入兼容控制台 |
| `gui\WinSupport-GUI.ps1` | WPF 启动、事件绑定、后台诊断和报告导出协调 |
| `gui\MainWindow.xaml` | WPF 主窗口布局和浅色卡片式主题 |
| `config\software.json` | 常用软件快捷安装列表（可自行增删改） |
| `tests\Test-DiagnosticRules.ps1` | V1.1/V1.2 诊断规则和报告兼容性测试 |
| `reports\` | 程序运行时自动创建，用于保存导出报告 |
| `logs\` | 程序运行时自动创建，用于保存基础日志 |

## 使用方法

1. 将整个文件夹复制到目标 Windows 电脑（建议放到本地磁盘，例如 `C:\IT-Tools\`）。
2. 双击 `run.bat`。
3. 普通查看功能无需管理员权限；修复类功能会检测权限，并在需要时通过标准 UAC 提示重新以管理员身份运行。

GUI 也可以手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\gui\WinSupport-GUI.ps1
```

如果 GUI 初始化失败，启动脚本会提示原因并回退到控制台菜单。需要直接使用旧控制台时运行 `run.bat --console`，或执行 `IT-Support-Toolkit.ps1 -Console`。直接运行主脚本的原有方式仍然保留。

## V1.3 GUI 当前范围

- 已完成：总览、六类状态卡片、全面诊断、后台执行状态、问题/建议展示、分类详情、网络/系统/磁盘/打印机分类入口、报告摘要、历史报告列表和 TXT / JSON / TXT+JSON 导出。
- 已复用：现有诊断对象、分类缓存、全面诊断、报告快照和报告导出函数；GUI 不复制诊断规则。
- 兼容模式：网络、系统、磁盘、打印机、软件、电脑相关的复杂工具操作通过“在兼容模式打开”进入原控制台菜单，保留原有确认和 UAC 逻辑。
- 限制：第一版不内嵌重写 SFC、DISM、winget、打印队列等复杂交互；后台操作显示“正在执行，请稍候”，不伪造百分比进度。
- 视觉资源：右侧 IT Assistant 当前使用本地 XAML 占位卡片，后续可替换为 `gui\assets\` 下的本地 PNG，不引用网络图片或 CDN。

也可以手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\IT-Support-Toolkit.ps1
```

## 功能一览

- 三区域 UI：总览、工具箱、报告；打开后先显示电脑整体状态，再进入具体工具
- 全面诊断：按设备、Windows、系统、磁盘、网络、打印机顺序执行，并保存本次会话结果
- 分类详情：Dashboard 与详细页共享同一次诊断缓存，分类重新检测前不会重复执行检测
- 一键诊断：系统、CPU/内存、C盘、网络、Windows Update、系统文件签名、关键服务、电池和打印机综合检查
- 网络诊断：网卡连接状态、MAC、IPv4、子网掩码、DHCP、DNS、网关、公网、DNS 解析和 HTTPS/TLS
- 代理感知：识别 Windows 系统代理、WinHTTP 代理和 VPN/TUN；公网直连失败不会单独归因于网卡故障
- 网络环境：检测 WinINET、WinHTTP、环境变量和虚拟网络适配器；显示公网出口 IP/国家/地区/城市/运营商/ASN
- 网络可达性：使用多个大陆与海外 HTTPS 目标，分别判断中国大陆网络、海外网络和 Google；单目标失败不会判定整体断网
- 诊断结论：使用 PASS / WARNING / FAIL / INFO 统一状态，输出问题说明和处理建议
- 修复后复检：网络诊断可按建议执行现有安全修复，并自动重新检测、比较修复结果
- 打印机：查看打印机与队列、清理队列、重启 Print Spooler、一键修复
- 打印机修复：集成两个系统级修复脚本，文件位于 `PrinterRepairScripts\`；分别用于替换打印组件文件，以及替换 `win32spl.dll` 并设置 RPC 打印兼容项
- 系统修复：SFC、DISM 检查/修复、Windows Update 服务检查与基础修复
- 磁盘：磁盘空间、临时文件扫描/清理（只限安全临时目录）、回收站清理、磁盘状态
- 软件：winget 搜索 / 安装 / 卸载 / 更新 / 已安装列表，常用软件快捷安装
- 电脑信息：CIM/WMI 读取硬件与系统信息
- 电脑相关：配置信息页面显示 CPU、显卡、内存条 DDR 类型、硬盘协议、显示器参数，以及 BIOS/SMBIOS 可暴露的主板 M.2、内存和 PCIe 槽位数量
- 导出报告：TXT / JSON，自动保存到 `reports\`；TXT 保留 V1.0 格式并增加结构化诊断段落

## UI 导航

```text
[1] 总览
    ├─ 全面诊断
    ├─ 本次结果
    └─ 分类详细状态

[2] 工具箱
    ├─ 网络
        ├─ 网络环境
    ├─ 打印机
    ├─ 系统
    ├─ 磁盘
    ├─ 软件
    └─ 电脑相关
        ├─ PC 信息
        ├─ 设备状态
        └─ 配置信息

[3] 报告
    ├─ 本次诊断结果
    ├─ 历史报告
    └─ 导出 TXT / JSON
```

诊断结果只保存在当前程序进程中，程序退出后清除，不创建永久状态文件。

## 测试

可以在 Windows PowerShell 5.1 或 PowerShell 7 中运行诊断规则测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-DiagnosticRules.ps1
```

测试使用模拟数据验证正常网络、系统代理、WinHTTP、VPN/TUN、代理不可用、无 IPv4、网关/DNS 异常、公网 Ping 被阻断、磁盘阈值、Windows Update 服务、关键服务和 TXT / JSON 报告兼容性，不会修改系统配置。网络环境公网请求需在 Windows 实机上验证。

GUI 基础检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiFoundation.ps1
```

## 兼容性验证

- V1.0 已完成 Windows 10 / Windows 11 实机验证。
- V1.2 发布前需要分别在 Windows 10 + PowerShell 5.1、Windows 11 + PowerShell 5.1 上执行测试脚本，并检查网络环境、网络诊断、一键诊断、修复后复检及 TXT / JSON 报告。
- M.2 外形和主板槽位数量依赖 BIOS/SMBIOS 暴露；Windows 无法可靠识别时会显示“未由 BIOS 暴露”。

## 常用软件列表维护

编辑 `config\software.json`，按同样格式增加条目即可：

```json
{
  "Name": "软件显示名",
  "PackageId": "winget 软件 ID",
  "Description": "说明",
  "Category": "浏览器",
  "RequiresAdmin": false
}
```

查询 winget ID 的方法：进入工具「软件 -> 搜索软件」，或在命令行执行 `winget search 软件名`。`Category` 为可选字段；未填写时会归入“其他”。常用软件菜单内置“Windows 官方软件”分类，包含照片、画图、记事本、计算器、相机、录音机和 Windows 终端等应用。

## 设计约束

- 只支持 Windows 10 / Windows 11
- 不做驱动替换、不扫描用户 Documents/Downloads/Desktop、不采集任何密码/Cookie/Token
- 清理类操作均先扫描、显示、确认后再执行
- winget 不存在、无打印机、网络断开时程序不会退出，只会给出明确提示
- 所有新增修复操作必须由用户确认；诊断本身不修改系统配置
- 打印机深度修复会修改 `C:\Windows\System32` 文件和注册表，仅应在确认脚本来源可信、且已备份重要数据后使用
- 不使用只有 Windows 11 才存在的命令或 API

## 已知说明

- 报告与日志保存到程序所在目录，程序所在目录需要有写入权限。
- SFC / DISM / 网络修复等操作可能持续数分钟，界面会显示“正在执行，请稍候”，不要误判为卡死。
