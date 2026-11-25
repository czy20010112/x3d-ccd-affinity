using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Threading;
using System.Windows.Forms;

namespace X3DTrayLauncher
{
    internal static class Program
    {
        private const string ScriptName = "X3D-Tray.ps1";

        [STAThread]
        private static void Main()
        {
            string toolDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
            string script  = Path.Combine(toolDir, ScriptName);

            if (!File.Exists(script))
            {
                MessageBox.Show(
                    "Cannot find:\r\n" + script,
                    "X3D CCD Affinity Tray",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            KillStaleTrayProcesses();
            EnsureTask(toolDir);
            Thread.Sleep(400);

            string pwsh = @"C:\Program Files\PowerShell\7\pwsh.exe";
            if (!File.Exists(pwsh)) pwsh = "powershell.exe";

            string arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"";

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(pwsh, arguments);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.WorkingDirectory = toolDir;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Failed to start the tray:\r\n" + ex.Message,
                    "X3D CCD Affinity Tray",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        /// <summary>
        /// Points the logon task at this exe, so later restarts go through the launcher
        /// (which cleans stale instances first) and still run elevated without UAC.
        /// </summary>
        private static void EnsureTask(string toolDir)
        {
            try
            {
                string exe = Path.Combine(toolDir, "X3D-Tray-Admin.exe");
                if (!File.Exists(exe)) return;
                string args = "/Create /TN \"X3D CCD Affinity Tray\" /TR \"\\\"" + exe + "\\\"\" /SC ONLOGON /RL HIGHEST /F";
                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit(15000);
                }
            }
            catch
            {
                // task re-pointing is a convenience; never block the tray from starting
            }
        }

        /// <summary>
        /// Terminates leftover tray instances. This launcher already runs elevated,
        /// so it can also kill instances that were started with admin rights.
        /// </summary>
        private static void KillStaleTrayProcesses()
        {
            int self = Process.GetCurrentProcess().Id;
            try
            {
                using (ManagementObjectSearcher searcher =
                       new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='pwsh.exe' OR Name='powershell.exe'"))
                {
                    foreach (ManagementBaseObject mo in searcher.Get())
                    {
                        object cmdObj = mo["CommandLine"];
                        string cmd = cmdObj == null ? null : cmdObj.ToString();
                        if (cmd == null) continue;
                        // Only match real tray launches: must use -File with our script and must
                        // NOT be an inline -Command shell (a -Command host may merely mention the
                        // script name and must never be terminated).
                        if (cmd.IndexOf("-Command", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                        if (cmd.IndexOf("-File", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        if (cmd.IndexOf(ScriptName, StringComparison.OrdinalIgnoreCase) < 0) continue;

                        int pid = Convert.ToInt32(mo["ProcessId"]);
                        if (pid == self) continue;
                        try
                        {
                            Process.GetProcessById(pid).Kill();
                        }
                        catch
                        {
                            // already gone or protected; ignore
                        }
                    }
                }
            }
            catch
            {
                // WMI unavailable: the single-instance mutex in the tray script still protects us
            }
        }
    }
}



