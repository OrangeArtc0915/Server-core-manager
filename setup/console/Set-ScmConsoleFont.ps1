param(
    [string]$Face = 'MesloLGS NF',
    [int]$Size = 18,
    [switch]$Probe,
    [switch]$Quiet,
    [string]$OutFile = ''
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ScmConsoleFont {
  [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct FI {
    public uint cbSize; public uint nFont; public COORD dwFontSize;
    public uint FontFamily; public uint FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FaceName;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool b, ref FI f);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool b, ref FI f);
  [DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
  public static string Current() {
    IntPtr h = GetStdHandle(-11);
    FI g = new FI(); g.cbSize = (uint)Marshal.SizeOf(typeof(FI)); g.FaceName = "";
    bool ok = GetCurrentConsoleFontEx(h, false, ref g);
    return "cp=" + GetConsoleOutputCP() + " readOk=" + ok + " face=[" + g.FaceName + "] size=" + g.dwFontSize.X + "x" + g.dwFontSize.Y + " family=0x" + g.FontFamily.ToString("X");
  }
  public static string Apply(string face, short sizeY) {
    IntPtr h = GetStdHandle(-11);
    FI f = new FI();
    f.cbSize = (uint)Marshal.SizeOf(typeof(FI)); f.nFont = 0;
    f.dwFontSize.X = 0; f.dwFontSize.Y = sizeY;
    f.FontFamily = 54; f.FontWeight = 400; f.FaceName = face;
    bool ok = SetCurrentConsoleFontEx(h, false, ref f);
    return "set=" + ok + "  after: " + Current();
  }
}
'@ -ErrorAction SilentlyContinue

$text = if ($Probe) { [ScmConsoleFont]::Current() } else { [ScmConsoleFont]::Apply($Face, [int16]$Size) }

if ($OutFile) {
    try {
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
if (-not $Quiet) { Write-Host $text }
