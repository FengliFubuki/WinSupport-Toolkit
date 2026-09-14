@echo off
title 修复共享打印机
cd /d "%~dp0"
echo off
:: 检测是否已管理员权限运行
fltmc >nul 2>&1 || (
    echo 正在请求管理员权限...
    :: PowerShell以管理员身份重新运行当前脚本
    powershell -Command "Start-Process '%~f0' -Verb RunAs" >nul 2>&1
    :: 退出原普通权限进程
    exit /b
)
:start
title 修复共享打印机
echo 适用于修复共享打印机无法使用问题
echo 正在停止打印服务…………
net stop spooler
echo 正在获取打印文件权限…………
TAKEOWN /F C:\Windows\System32\localspl.dll /A
Icacls C:\windows\System32\localspl.dll /grant Administrators:F
TAKEOWN /F C:\Windows\System32\win32spl.dll /A
Icacls C:\windows\System32\win32spl.dll /grant Administrators:F
TAKEOWN /F C:\Windows\System32\spoolsv.exe /A
Icacls C:\windows\System32\spoolsv.exe /grant Administrators:F
echo 正在删除打印机文件…………
copy C:\windows\system32\localspl.dll C:\windows\system32\localspl-77bx.dll
copy C:\windows\system32\win32spl.dll C:\windows\system32\win32spl-77bx.dll
copy C:\windows\system32\spoolsv.exe C:\windows\system32\spoolsv-77bx.exe
del /F /Q C:\windows\system32\localspl.dll
del /F /Q C:\windows\system32\win32spl.dll
del /F /Q C:\windows\system32\spoolsv.exe
echo 正在重载打印机文件…………
copy localspl.dll C:\windows\system32\localspl.dll
copy win32spl.dll C:\windows\system32\win32spl.dll
copy spoolsv.exe C:\windows\system32\spoolsv.exe
echo 正在启动打印服务…………
net start spooler
Echo --------------------------------------------------------------------------
Echo 完成操作，请进行打印测试吧！
pause