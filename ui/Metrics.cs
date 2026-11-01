using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace ScmUi
{
    // ============================================================
    // 实时指标采样（进程内）。
    // 以前总览页每 5 秒起一个 powershell.exe 跑 Run-GuiReadyMonitor.ps1 -Mode metrics：
    // 单次约 150-250ms CPU + 80MB 峰值内存，只是拿 CPU / 内存 / 系统盘三个数。
    // 换成 GetSystemTimes + GlobalMemoryStatusEx + DriveInfo 之后单次 < 0.05ms，
    // 且不产生子进程。取不到时（极端精简的系统）调用方仍可回退到 runner。
    // ============================================================
    internal sealed class MetricSample
    {
        public double Cpu = -1;        // 百分比；-1 = 本次取不到
        public double MemPct = -1;
        public double MemUsedGB;
        public double MemTotalGB;
        public double DiskPct = -1;
        public string DiskName = "";
        public double DiskFreeGB;
        public string CpuSrc = "本机采样";
    }

    internal static class Metrics
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
            public ulong ToU64() { return ((ulong)High << 32) | Low; }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatusEx
        {
            public uint Length;
            public uint MemoryLoad;
            public ulong TotalPhys;
            public ulong AvailPhys;
            public ulong TotalPageFile;
            public ulong AvailPageFile;
            public ulong TotalVirtual;
            public ulong AvailVirtual;
            public ulong AvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buf);

        private static readonly object Gate = new object();
        private static ulong _lastIdle, _lastBusy;
        private static bool _primed;
        private static bool _broken;

        // 异步采样：首次调用先「打点」，第二次开始才有准确 CPU 值
        public static void SampleAsync(Action<MetricSample> done, Action<string> fail)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    MetricSample s;
                    if (!TrySample(out s)) throw new Exception("本机采样不可用");
                    if (done != null) done(s);
                }
                catch (Exception ex)
                {
                    if (fail != null) fail(ex.Message);
                }
            });
        }

        public static bool TrySample(out MetricSample sample)
        {
            sample = new MetricSample();
            if (_broken) return false;

            try
            {
                double cpu = ReadCpu();
                if (cpu < 0)
                {
                    // 第一次调用只是打点（GetSystemTimes 要两次差值才有意义）。
                    // 这里等 300ms 再取一次，让首屏就能显示真实 CPU，而不是空 5 秒。
                    try { Thread.Sleep(300); } catch { }
                    cpu = ReadCpu();
                }
                if (cpu >= 0) sample.Cpu = cpu;
                sample.CpuSrc = "本机采样 · 5s";
            }
            catch
            {
                _broken = true;
                return false;
            }

            try
            {
                var m = new MemoryStatusEx();
                m.Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
                if (GlobalMemoryStatusEx(ref m))
                {
                    sample.MemPct = m.MemoryLoad;
                    sample.MemTotalGB = Math.Round(m.TotalPhys / 1073741824.0, 1);
                    sample.MemUsedGB = Math.Round((m.TotalPhys - m.AvailPhys) / 1073741824.0, 1);
                }
            }
            catch { }

            try
            {
                string sys = Environment.GetEnvironmentVariable("SystemDrive");
                if (string.IsNullOrEmpty(sys)) sys = "C:";
                var d = new DriveInfo(sys);
                long total = d.TotalSize;
                long free = d.AvailableFreeSpace;
                if (total > 0)
                {
                    sample.DiskName = sys;
                    sample.DiskFreeGB = Math.Round(free / 1073741824.0, 1);
                    sample.DiskPct = Math.Round((total - free) * 100.0 / total, 1);
                }
            }
            catch { }

            return sample.Cpu >= 0 || sample.MemPct >= 0 || sample.DiskPct >= 0;
        }

        // 相邻两次采样的差值：kernel 时间已包含 idle，所以分母是 kernel+user
        private static double ReadCpu()
        {
            FileTime idle, kernel, user;
            if (!GetSystemTimes(out idle, out kernel, out user)) return -1;

            ulong i = idle.ToU64();
            ulong b = kernel.ToU64() + user.ToU64();

            lock (Gate)
            {
                if (!_primed)
                {
                    _primed = true;
                    _lastIdle = i;
                    _lastBusy = b;
                    return -1;      // 打点，本次没有可信值
                }

                ulong di = i - _lastIdle;
                ulong db = b - _lastBusy;
                _lastIdle = i;
                _lastBusy = b;
                if (db == 0) return -1;

                double pct = (1.0 - (double)di / db) * 100.0;
                if (pct < 0) pct = 0;
                if (pct > 100) pct = 100;
                return Math.Round(pct, 1);
            }
        }
    }
}
