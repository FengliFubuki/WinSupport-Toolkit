# Windows IT Support Toolkit V1.1

面向 IT Support / Desktop Support 的 Windows 日常运维辅助工具。使用 PowerShell + Windows 自带命令 + winget 实现，无第三方依赖。
目前为自用测试版本

## V1.1

- 修复 Windows PowerShell 5.1 在 en-US、OEM 437 等非中文控制台环境下的中文显示问题。
- `run.bat` 与主脚本启动入口均自动初始化 UTF-8 控制台编码，并在经典控制台中临时选用已安装的中文字体，无需用户修改系统区域或手动执行 `chcp`。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `IT-Support-Toolkit.ps1` | 主程序（所有功能） |
| `run.bat` | 双击启动入口（自动选择 pwsh / Windows PowerShell，绕过执行策略） |
| `config\software.json` | 常用软件快捷安装列表（可自行增删改） |
| `reports\` | 程序运行时自动创建，用于保存导出报告 |
| `logs\` | 程序运行时自动创建，用于保存基础日志 |

## 使用方法

1. 将整个文件夹复制到目标 Windows 电脑（建议放到本地磁盘，例如 `C:\IT-Tools\`）。
2. 双击 `run.bat`。
3. 普通查看功能无需管理员权限；修复类功能会检测权限，并在需要时通过标准 UAC 提示重新以管理员身份运行。

也可以手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\IT-Support-Toolkit.ps1
```

## 功能一览

- 一键检测：电脑 / 网络 / 磁盘 / 电池 / 打印机综合检查
- 网络：查看信息、分步诊断（适配器、IP、网关、公网、DNS、443）、网络修复
- 打印机：查看打印机与队列、清理队列、重启 Print Spooler、一键修复
- 系统修复：SFC、DISM 检查/修复、Windows Update 服务检查与基础修复
- 磁盘：磁盘空间、临时文件扫描/清理（只限安全临时目录）、回收站清理、磁盘状态
- 软件：winget 搜索 / 安装 / 卸载 / 更新 / 已安装列表，常用软件快捷安装
- 电脑信息：CIM/WMI 读取硬件与系统信息
- 导出报告：TXT / JSON，自动保存到 `reports\`

## 常用软件列表维护

编辑 `config\software.json`，按同样格式增加条目即可：

```json
{
  "Name": "软件显示名",
  "PackageId": "winget 软件 ID",
  "Description": "说明",
  "RequiresAdmin": false
}
```

查询 winget ID 的方法：进入工具「软件 -> 搜索软件」，或在命令行执行 `winget search 软件名`。

## 设计约束（V1.1）

- 只支持 Windows 10 / Windows 11
- 不做驱动替换、不扫描用户 Documents/Downloads/Desktop、不采集任何密码/Cookie/Token
- 清理类操作均先扫描、显示、确认后再执行
- winget 不存在、无打印机、网络断开时程序不会退出，只会给出明确提示

## 已知说明

- 报告与日志保存到程序所在目录，程序所在目录需要有写入权限。
- SFC / DISM / 网络修复等操作可能持续数分钟，界面会显示“正在执行，请稍候”，不要误判为卡死。
