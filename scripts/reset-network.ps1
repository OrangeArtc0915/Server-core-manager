# @scm-id reset-network
# @scm-name 重置网络栈
# @scm-desc 刷新 DNS、重置 Winsock 与 TCP/IP，并重新获取 DHCP 地址。执行后通常需要重启。
# @scm-risk high

$ErrorActionPreference = 'Continue'

Write-Output '--- flushdns ---'
& ipconfig.exe /flushdns
Write-Output '--- winsock reset ---'
& netsh.exe winsock reset
Write-Output '--- int ip reset ---'
& netsh.exe int ip reset
Write-Output '--- release / renew ---'
& ipconfig.exe /release
& ipconfig.exe /renew

Write-Output '网络栈已重置。Winsock / TCP/IP 的更改需要重启后生效。'
