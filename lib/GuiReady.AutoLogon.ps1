# GuiReady autologon: create a session automatically at boot (needed for headless GUI and phase B)
#
# Two methods:
#   LsaSecret  - password stored as an LSA private data secret (default, recommended).
#                Microsoft Learn: after configuring AutoAdminLogon with such a tool,
#                "the password is stored in the Local Security Authority (LSA) secret
#                instead of the Winlogon key". Do NOT also write DefaultPassword.
#   Registry   - documented KB324737 method; DefaultPassword is PLAIN TEXT in the registry
#                and the key can be read remotely by Authenticated Users. Fallback only.
#
# AutoLogonCount gotcha (by design in Windows): if the value exists and is 0, the next reboot
# deletes DefaultPassword and sets AutoAdminLogon=0. So when the caller does not ask for a
# limited count, any existing AutoLogonCount MUST be removed.

$Global:GuiReadyWinlogonKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$Global:GuiReadyLogonSecret  = 'DefaultPassword'
$Global:GuiReadyAutoLogonNativeOk = $false

function Initialize-GuiReadyAutoLogonNative {
    if ($Global:GuiReadyAutoLogonNativeOk) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class GuiReadyLsa {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public int Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    const uint POLICY_ALL_ACCESS = 0x000F0FFF;

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaStorePrivateData(IntPtr PolicyHandle, IntPtr KeyName, IntPtr PrivateData);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaRetrievePrivateData(IntPtr PolicyHandle, IntPtr KeyName, out IntPtr PrivateData);

    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr ObjectHandle);

    [DllImport("advapi32.dll")]
    static extern IntPtr LsaFreeMemory(IntPtr Buffer);

    static IntPtr MakeUnicodeString(string s, out IntPtr strBuf) {
        strBuf = IntPtr.Zero;
        LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
        if (s != null) {
            strBuf = Marshal.StringToHGlobalUni(s);
            u.Buffer = strBuf;
            u.Length = (ushort)(s.Length * 2);
            u.MaximumLength = (ushort)((s.Length + 1) * 2);
        }
        IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
        Marshal.StructureToPtr(u, p, false);
        return p;
    }

    static IntPtr OpenPolicy(out uint status) {
        IntPtr policy = IntPtr.Zero;
        LSA_OBJECT_ATTRIBUTES oa = new LSA_OBJECT_ATTRIBUTES();
        oa.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        status = LsaOpenPolicy(IntPtr.Zero, ref oa, POLICY_ALL_ACCESS, out policy);
        return policy;
    }

    // value == null deletes the secret
    public static uint Store(string key, string value) {
        uint st;
        IntPtr policy = OpenPolicy(out st);
        if (st != 0) return st;
        IntPtr keyBuf = IntPtr.Zero, valBuf = IntPtr.Zero, pKey = IntPtr.Zero, pVal = IntPtr.Zero;
        try {
            pKey = MakeUnicodeString(key, out keyBuf);
            if (value != null) pVal = MakeUnicodeString(value, out valBuf);
            return LsaStorePrivateData(policy, pKey, pVal);
        } finally {
            if (pKey != IntPtr.Zero) Marshal.FreeHGlobal(pKey);
            if (pVal != IntPtr.Zero) Marshal.FreeHGlobal(pVal);
            if (keyBuf != IntPtr.Zero) Marshal.FreeHGlobal(keyBuf);
            if (valBuf != IntPtr.Zero) Marshal.FreeHGlobal(valBuf);
            LsaClose(policy);
        }
    }

    // returns 0 if the secret exists, otherwise the NTSTATUS.
    // 只判断存在性：不读取内容，且返回的缓冲区必须用 LsaFreeMemory 释放
    // （用 Marshal.FreeHGlobal 释放 LSA 分配的内存会导致堆损坏 0xC0000374）
    public static uint Exists(string key) {
        uint st;
        IntPtr policy = OpenPolicy(out st);
        if (st != 0) return st;
        IntPtr keyBuf = IntPtr.Zero, pKey = IntPtr.Zero, data = IntPtr.Zero;
        try {
            pKey = MakeUnicodeString(key, out keyBuf);
            return LsaRetrievePrivateData(policy, pKey, out data);
        } finally {
            if (data != IntPtr.Zero) { try { LsaFreeMemory(data); } catch { } }
            if (pKey != IntPtr.Zero) Marshal.FreeHGlobal(pKey);
            if (keyBuf != IntPtr.Zero) Marshal.FreeHGlobal(keyBuf);
            LsaClose(policy);
        }
    }

    public static string Explain(uint status) {
        uint win = 0;
        try { win = LsaNtStatusToWinError(status); } catch { }
        return "NTSTATUS=0x" + status.ToString("X8") + " Win32=" + win;
    }

    [DllImport("advapi32.dll")]
    static extern uint LsaNtStatusToWinError(uint status);
}
'@ -ErrorAction Stop
        $Global:GuiReadyAutoLogonNativeOk = $true
        return $true
    } catch {
        Write-Log ('加载 LSA 接口失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-GuiReadyAutoLogon {
    $k = $Global:GuiReadyWinlogonKey
    $o = [ordered]@{
        Enabled            = $false
        AutoAdminLogon     = ''
        DefaultUserName    = ''
        DefaultDomainName  = ''
        HasRegPlaintext    = $false
        HasLsaSecret       = $false
        LsaSecretStatus    = ''
        AutoLogonCount     = $null
        AutoLogonCountState= ''
        ForceAutoLogon     = ''
        Method             = ''
        Verdict            = ''
        MustFix            = ''
    }

    foreach ($name in @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'ForceAutoLogon')) {
        $v = Get-RegValue $k $name
        if ($null -ne $v) { $o[$name] = [string]$v }
    }

    $pw = Get-RegValue $k 'DefaultPassword'
    $o.HasRegPlaintext = (-not [string]::IsNullOrEmpty([string]$pw))

    $alc = Get-RegValue $k 'AutoLogonCount'
    if ($null -ne $alc) {
        $o.AutoLogonCount = [int]$alc
        if ([int]$alc -eq 0) {
            $o.AutoLogonCountState = 'DWORD=0（危险：下次重启 Windows 会删除密码并把 AutoAdminLogon 置 0）'
            $o.MustFix = '注册表里存在 AutoLogonCount=0，会破坏自动登录。请把它删除或设为大于 0 的值。'
        } else {
            $o.AutoLogonCountState = ('DWORD={0}（只自动登录 {0} 次，用完后 Windows 会自己清掉密码）' -f $alc)
        }
    } else {
        $o.AutoLogonCountState = '不存在（等于每次重启都会自动登录，这是想要的状态）'
    }

    if (Initialize-GuiReadyAutoLogonNative) {
        $st = [GuiReadyLsa]::Exists($Global:GuiReadyLogonSecret)
        $o.LsaSecretStatus = [GuiReadyLsa]::Explain($st)
        $o.HasLsaSecret = ($st -eq 0)
    } else {
        $o.LsaSecretStatus = '未加载 LSA 接口'
    }

    $o.Enabled = ($o.AutoAdminLogon -eq '1')
    if ($o.HasLsaSecret) { $o.Method = 'LsaSecret' }
    elseif ($o.HasRegPlaintext) { $o.Method = 'RegistryPlaintext' }

    if (-not $o.Enabled) {
        $o.Verdict = '未启用自动登录：开机后需要人工登录，才会出现用户会话'
    } elseif ($o.HasLsaSecret) {
        $o.Verdict = ('已启用：开机自动登录 {0}\{1}，密码存于 LSA 机密（不在注册表明文）' -f $o.DefaultDomainName, $o.DefaultUserName)
    } elseif ($o.HasRegPlaintext) {
        $o.Verdict = ('已启用：开机自动登录 {0}\{1}，但密码以明文存在注册表 DefaultPassword（Authenticated Users 可远程读取）' -f $o.DefaultDomainName, $o.DefaultUserName)
    } else {
        $o.Verdict = ('AutoAdminLogon=1 但既没有 LSA 机密也没有 DefaultPassword 明文 —— 这样 Windows 会在下次登录时把 AutoAdminLogon 改回 0，等于没配对')
    }
    return [pscustomobject]$o
}

function Set-GuiReadyAutoLogon {
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Domain = '',
        [int]$AutoLogonCount = 0,
        [switch]$UseRegistryPlaintext,
        [switch]$WhatIf
    )

    Write-Head '配置开机自动登录'

    if (-not (Assert-Administrator)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Domain)) { $Domain = $env:COMPUTERNAME }

    $k = $Global:GuiReadyWinlogonKey

    # 账户校验：必须有密码，且不能被禁用
    $acct = $null
    try { $acct = Get-LocalUser -Name $User -ErrorAction Stop } catch { }
    if (-not $acct) {
        Write-Log ('找不到本地账户: ' + $User) 'ERROR'
        Write-Log '可用账户: ' + ((Get-LocalUser | ForEach-Object { $_.Name }) -join ', ') 'INFO'
        return $null
    }
    if (-not $acct.Enabled) {
        Write-Log ('账户 {0} 已被禁用，自动登录不会生效。请先启用它。' -f $User) 'ERROR'
        return $null
    }
    Write-Log ('账户校验: {0} 启用={1} 密码永不过期={2}' -f $acct.Name, $acct.Enabled, $acct.PasswordNeverExpires) 'OK'

    Write-Log ''
    Write-Log '安全提示:' 'WARN'
    Write-Log '  启用自动登录后，任何能开机的人都能直接进入该系统及其连接的所有网络。' 'WARN'
    Write-Log '  仅建议用于虚拟机、实验机、Kiosk 这类物理受控的场景。' 'WARN'
    if ($UseRegistryPlaintext) {
        Write-Log '  当前选择的是【注册表明文】方式：密码会以明文写入 DefaultPassword，' 'WARN'
        Write-Log '  且该键可被 Authenticated Users 组远程读取。能用 LSA 机密就别用这个。' 'WARN'
    } else {
        Write-Log '  当前选择的是【LSA 机密】方式：密码作为 LSA 私有数据存储，不写注册表明文。' 'OK'
    }
    Write-Log ''

    if ($WhatIf) {
        Write-Log ('将设置 AutoAdminLogon=1  DefaultUserName={0}  DefaultDomainName={1}' -f $User, $Domain) 'DRY'
        if ($AutoLogonCount -gt 0) {
            Write-Log ('将设置 AutoLogonCount={0}（只自动登录 {0} 次，之后 Windows 自动清除密码）' -f $AutoLogonCount) 'DRY'
        } else {
            Write-Log '将确保删除 AutoLogonCount（残留 0 会导致下次重启自动关闭自动登录）' 'DRY'
        }
        if ($UseRegistryPlaintext) {
            Write-Log '将把密码明文写入 DefaultPassword' 'DRY'
        } else {
            Write-Log '将把密码写入 LSA 机密 DefaultPassword（失败时自动改用 SYSTEM 重试）' 'DRY'
        }
        return [pscustomobject]@{ Ok = $true; DryRun = $true }
    }

    $method = 'LsaSecret'
    $secretOk = $false
    $secretNote = ''

    if ($UseRegistryPlaintext) {
        $method = 'RegistryPlaintext'
    } else {
        if (-not (Initialize-GuiReadyAutoLogonNative)) { return $null }

        # 先以当前身份写；LSA 私有数据操作有时要求 SYSTEM，失败就自动改走 SYSTEM 计划任务重试
        $st = 0
        try { $st = [GuiReadyLsa]::Store($Global:GuiReadyLogonSecret, $Password) } catch { $st = 0xFFFFFFFF }
        if ($st -eq 0) {
            $secretOk = $true
            $secretNote = '以当前身份写入成功'
        } else {
            Write-Log ('以当前身份写 LSA 机密失败（{0}），改用以 SYSTEM 计划任务重试...' -f ([GuiReadyLsa]::Explain($st))) 'WARN'
            $body  = (Get-GuiReadyPreamble)
            $body += "`$r = [GuiReadyLsa]::Store('$($Global:GuiReadyLogonSecret)', '$($Password -replace "'", "''")')`r`n"
            $body += "if (`$r -eq 0) { 'SECRET_OK' } else { 'SECRET_FAIL ' + [GuiReadyLsa]::Explain(`$r) }`r`n"
            $t = Invoke-GuiReadyElevatedTask -Name 'AutoLogonSecret' -Body $body -TimeoutSeconds 180 -PollSeconds 5

            # 这条兜底路径会把密码写进临时工作脚本，跑完必须立刻销毁
            if ($t.WorkerScript -and (Test-Path -LiteralPath $t.WorkerScript)) {
                Remove-Item -LiteralPath $t.WorkerScript -Force -ErrorAction SilentlyContinue
                Write-Log '已销毁含密码的临时工作脚本' 'OK'
            }

            if ($t.Log -match 'SECRET_OK') {
                $secretOk = $true
                $secretNote = '以 SYSTEM 身份写入成功'
            } else {
                $secretNote = 'LSA 写入失败: ' + ($t.Log -replace "`r?`n", ' ').Trim()
                Write-Log ('  ' + $secretNote) 'ERROR'
                Write-Log '  回退建议：加 -UseRegistryPlaintext 使用注册表明文方式（安全性较低）。' 'WARN'
                return $null
            }
        }
        Write-Log ('LSA 机密写入成功（{0}）' -f $secretNote) 'OK'

        # 用 LSA 机密时不能保留明文条目，否则等于白做
        if (Test-Path -LiteralPath $k) {
            if ($null -ne (Get-RegValue $k 'DefaultPassword')) {
                Remove-ItemProperty -Path $k -Name 'DefaultPassword' -ErrorAction SilentlyContinue
                Write-Log '已移除注册表里的明文 DefaultPassword（避免两条并存）' 'OK'
            }
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $k)) { return $null }
        New-ItemProperty -Path $k -Name 'AutoAdminLogon'    -Value '1'    -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $k -Name 'DefaultUserName'   -Value $User  -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $k -Name 'DefaultDomainName' -Value $Domain -PropertyType String -Force | Out-Null

        if ($method -eq 'RegistryPlaintext') {
            New-ItemProperty -Path $k -Name 'DefaultPassword' -Value $Password -PropertyType String -Force | Out-Null
            Write-Log '已写入注册表明文 DefaultPassword（注意：可被远程读取）' 'WARN'
        }

        if ($AutoLogonCount -gt 0) {
            New-ItemProperty -Path $k -Name 'AutoLogonCount' -Value $AutoLogonCount -PropertyType DWord -Force | Out-Null
            Write-Log ('已设置 AutoLogonCount={0}：自动登录 {0} 次后 Windows 会自行清除密码并关闭自动登录' -f $AutoLogonCount) 'OK'
        } else {
            # 关键：残留 AutoLogonCount=0 会让下次重启删掉密码并关闭自动登录
            $existing = Get-RegValue $k 'AutoLogonCount'
            if ($null -ne $existing) {
                Remove-ItemProperty -Path $k -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
                Write-Log ('已删除残留的 AutoLogonCount={0}（否则下次重启 Windows 会清掉密码、关闭自动登录）' -f $existing) 'WARN'
            }
        }
        Write-Log 'AutoAdminLogon / DefaultUserName / DefaultDomainName 已写入' 'OK'
    } catch {
        Write-Log ('写 Winlogon 注册表失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }

    $after = Get-GuiReadyAutoLogon
    Write-Log ''
    Write-Log ('当前状态: ' + $after.Verdict) $(if ($after.HasLsaSecret -or $after.HasRegPlaintext) { 'OK' } else { 'WARN' })
    Write-Log '重启后会自动登录该账户，从而建立可用的用户会话。' 'OK'
    return $after
}

function Disable-GuiReadyAutoLogon {
    param([switch]$WhatIf)

    Write-Head '关闭自动登录'

    if (-not (Assert-Administrator)) { return $null }
    $k = $Global:GuiReadyWinlogonKey

    $before = Get-GuiReadyAutoLogon
    Write-Log ('关闭前: ' + $before.Verdict) 'INFO'

    if ($WhatIf) {
        Write-Log '将设置 AutoAdminLogon=0，并删除 DefaultPassword / AutoLogonCount（明文）' 'DRY'
        Write-Log '将删除 LSA 机密 DefaultPassword（LsaStorePrivateData 传 NULL 即为删除）' 'DRY'
        Write-Log '将保留 DefaultUserName / DefaultDomainName（无害，仅用于登录界面预填用户名）' 'DRY'
        return [pscustomobject]@{ Ok = $true; DryRun = $true }
    }

    try {
        if (Test-Path -LiteralPath $k) {
            New-ItemProperty -Path $k -Name 'AutoAdminLogon' -Value '0' -PropertyType String -Force | Out-Null
            foreach ($n in @('DefaultPassword', 'AutoLogonCount')) {
                if ($null -ne (Get-RegValue $k $n)) {
                    Remove-ItemProperty -Path $k -Name $n -ErrorAction SilentlyContinue
                    Write-Log ('已删除注册表项: ' + $n) 'OK'
                }
            }
        }
    } catch {
        Write-Log ('写注册表失败: ' + $_.Exception.Message) 'ERROR'
    }

    if (Initialize-GuiReadyAutoLogonNative) {
        $st = 0
        try { $st = [GuiReadyLsa]::Store($Global:GuiReadyLogonSecret, $null) } catch { $st = 0xFFFFFFFF }
        if ($st -eq 0) {
            Write-Log '已删除 LSA 机密 DefaultPassword' 'OK'
        } else {
            Write-Log ('删除 LSA 机密失败（{0}）；若之前是 LSA 方式，请以 SYSTEM 身份重试' -f ([GuiReadyLsa]::Explain($st))) 'WARN'
        }
    }

    $after = Get-GuiReadyAutoLogon
    Write-Log ''
    Write-Log ('当前状态: ' + $after.Verdict) 'OK'
    return $after
}

function Show-GuiReadyAutoLogonStatus {
    $a = Get-GuiReadyAutoLogon
    Write-Head '开机自动登录状态'
    Write-Log ('AutoAdminLogon    : {0}' -f $(if ($a.AutoAdminLogon) { $a.AutoAdminLogon } else { '(不存在)' })) 'INFO'
    Write-Log ('DefaultUserName   : {0}' -f $(if ($a.DefaultUserName) { $a.DefaultUserName } else { '(不存在)' })) 'INFO'
    Write-Log ('DefaultDomainName : {0}' -f $(if ($a.DefaultDomainName) { $a.DefaultDomainName } else { '(不存在)' })) 'INFO'
    Write-Log ('密码存储方式      : {0}' -f $(if ($a.Method) { $a.Method } else { '(未检测到密码)' })) $(if ($a.Method -eq 'RegistryPlaintext') { 'WARN' } else { 'INFO' })
    Write-Log ('  LSA 机密存在    : {0}   {1}' -f (Format-Bool $a.HasLsaSecret), $a.LsaSecretStatus) 'INFO'
    Write-Log ('  注册表明文存在  : {0}   （值不打印）' -f (Format-Bool $a.HasRegPlaintext)) 'INFO'
    Write-Log ('AutoLogonCount    : {0}' -f $a.AutoLogonCountState) 'INFO'
    Write-Log ('ForceAutoLogon    : {0}' -f $(if ($a.ForceAutoLogon) { $a.ForceAutoLogon } else { '(不存在)' })) 'INFO'
    Write-Log ''
    Write-Log $a.Verdict $(if ($a.Enabled) { 'OK' } else { 'WARN' })
    if ($a.MustFix) { Write-Log ('需要处理: ' + $a.MustFix) 'WARN' }

    Write-Log ''
    Write-Log '当前登录会话:' 'INFO'
    $s = Get-GuiReadySessionInfo
    foreach ($r in $s.Rows) {
        Write-Log ('  {0,-18} 用户={1,-14} ID={2,-5} 状态={3}' -f $r.SessionName, $r.User, $r.Id, $r.State) 'INFO'
    }
    if ($s.LoggedOnCount -eq 0) {
        Write-Log '  没有已登录用户 —— 这正是需要自动登录的场景' 'WARN'
    }
    return $a
}
