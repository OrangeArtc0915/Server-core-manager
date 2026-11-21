# SMB 共享权限与 NTFS ACL。

function Get-GuiReadySmbShares {
    $rows = @()
    try {
        foreach ($s in @(Get-SmbShare -ErrorAction Stop)) {
            $access = @()
            try { $access = @(Get-SmbShareAccess -Name $s.Name -ErrorAction Stop) } catch { }
            if ($access.Count -eq 0) {
                $rows += [pscustomobject]@{ Share = [string]$s.Name; Path = [string]$s.Path; Account = ''; Access = ''; Type = ''; Description = [string]$s.Description }
            } else {
                foreach ($a in $access) {
                    $rows += [pscustomobject]@{
                        Share = [string]$s.Name; Path = [string]$s.Path
                        Account = [string]$a.AccountName; Access = [string]$a.AccessRight
                        Type = [string]$a.AccessControlType; Description = [string]$s.Description
                    }
                }
            }
        }
    } catch { Write-Log ('读取 SMB 共享失败：' + $_.Exception.Message) 'WARN' }
    return @($rows)
}

function Set-GuiReadySmbShareAccess {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Account,
          [ValidateSet('Full', 'Change', 'Read')][string]$Access = 'Read',
          [ValidateSet('Grant', 'Revoke')][string]$Action = 'Grant',
          [switch]$DryRun)
    if ($DryRun) { Write-Log ('[预览] {0} {1} 对共享 {2} 的 {3} 权限' -f $Action, $Account, $Name, $Access) 'DRY'; return }
    if ($Action -eq 'Grant') { Grant-SmbShareAccess -Name $Name -AccountName $Account -AccessRight $Access -Force -ErrorAction Stop | Out-Null }
    else { Revoke-SmbShareAccess -Name $Name -AccountName $Account -Force -ErrorAction Stop | Out-Null }
    Write-Log ('共享 {0}：{1} {2} {3}' -f $Name, $Action, $Account, $Access) 'OK'
}

function Get-GuiReadyNtfsAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('路径不存在：' + $Path) }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rows = @()
    foreach ($r in @($acl.Access)) {
        $rows += [pscustomobject]@{
            Path = $Path
            Account = [string]$r.IdentityReference
            Rights = [string]$r.FileSystemRights
            Type = [string]$r.AccessControlType
            Inherited = [bool]$r.IsInherited
            InheritFlags = [string]$r.InheritanceFlags
            Propagation = [string]$r.PropagationFlags
        }
    }
    return @($rows)
}

function Set-GuiReadyNtfsAcl {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][string]$Account,
          [ValidateSet('FullControl', 'Modify', 'ReadAndExecute', 'Read', 'Write')][string]$Rights = 'Read',
          [ValidateSet('Allow', 'Deny')][string]$Type = 'Allow',
          [ValidateSet('None', 'ContainerInherit', 'ObjectInherit', 'ContainerInherit,ObjectInherit')][string]$Inherit = 'ContainerInherit,ObjectInherit',
          [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('路径不存在：' + $Path) }
    $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::None
    foreach ($x in ($Inherit -split ',')) {
        switch ($x.Trim()) {
            'ContainerInherit' { $inheritFlags = $inheritFlags -bor [System.Security.AccessControl.InheritanceFlags]::ContainerInherit }
            'ObjectInherit'    { $inheritFlags = $inheritFlags -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit }
        }
    }
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Account, $Rights, $inheritFlags, $prop, $Type)
    if ($DryRun) { Write-Log ('[预览] {0} 对 {1} 的 {2} 权限：{3}' -f $Account, $Path, $Type, $Rights) 'DRY'; return }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($Type -eq 'Allow') { $acl.AddAccessRule($rule) } else { $acl.AddAccessRule($rule) }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    Write-Log ('已设置 NTFS 权限：{0} → {1} {2} {3}' -f $Path, $Account, $Type, $Rights) 'OK'
}

function Get-GuiReadyEffectivePermissions {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Account)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('路径不存在：' + $Path) }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $names = @($Account)
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier])
        foreach ($g in @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups)) {
            try { $names += $g.Translate([System.Security.Principal.NTAccount]).Value } catch { }
        }
    } catch { }
    $names += 'Everyone'
    $names += 'BUILTIN\Users'
    $rows = @()
    foreach ($r in @($acl.Access)) {
        $id = [string]$r.IdentityReference
        $match = $false
        foreach ($n in $names) { if ($id -ieq $n -or $id -like ('*\' + $n)) { $match = $true; break } }
        if (-not $match) { continue }
        $rows += [pscustomobject]@{ Account = $id; Rights = [string]$r.FileSystemRights; Type = [string]$r.AccessControlType; Inherited = [bool]$r.IsInherited }
    }
    return @($rows)
}
