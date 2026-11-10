using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("TaskbarFollow Launcher")]
[assembly: AssemblyDescription("Starts the local, portable AutoHotkey v2 taskbar follower")]
[assembly: AssemblyVersion("0.3.1.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string runtime = Path.Combine(root, "runtime", "AutoHotkey64.exe");
        string script = Path.Combine(root, "TaskbarFollow.ahk");
        if (!File.Exists(runtime) || !File.Exists(script))
        {
            MessageBox.Show("程序文件不完整。请先解压整个文件夹，不要仅复制 Start.exe。", "随屏 · TaskbarFollow", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        // The test option checks launcher-to-runtime invocation, with no hooks or window movement.
        string argument = args.Length == 1 && args[0] == "--check" ? " --check" : "";
        try
        {
            var info = new ProcessStartInfo(runtime, (argument != "" ? "/ErrorStdOut=UTF-8 " : "") + "\"" + script + "\"" + argument);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = argument != "" ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal;
            info.RedirectStandardOutput = argument != "";
            info.RedirectStandardError = argument != "";
            using (Process child = Process.Start(info))
            {
                if (argument != "")
                {
                    child.StandardOutput.ReadToEnd();
                    child.StandardError.ReadToEnd();
                    child.WaitForExit();
                    return child.ExitCode;
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("无法启动程序：\n" + ex.Message + "\n\n可尝试文件夹中的 Start.cmd。", "随屏 · TaskbarFollow", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}


