using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("桌面图标开关")]
[assembly: AssemblyDescription("一键隐藏或恢复 Windows 桌面图标。")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace DesktopIconToggle
{
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellServiceProvider
    {
        [PreserveSig] int QueryService(ref Guid service, ref Guid iid, out IntPtr result);
    }

    // The unused methods keep the native vtable slots aligned.
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellBrowser
    {
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enter);
        [PreserveSig] int InsertMenusSB(IntPtr menu, IntPtr widths);
        [PreserveSig] int SetMenuSB(IntPtr menu, IntPtr oleMenu, IntPtr active);
        [PreserveSig] int RemoveMenusSB(IntPtr menu);
        [PreserveSig] int SetStatusTextSB([MarshalAs(UnmanagedType.LPWStr)] string text);
        [PreserveSig] int EnableModelessSB([MarshalAs(UnmanagedType.Bool)] bool enable);
        [PreserveSig] int TranslateAcceleratorSB(IntPtr message, ushort id);
        [PreserveSig] int BrowseObject(IntPtr pidl, uint flags);
        [PreserveSig] int GetViewStateStream(uint mode, out IntPtr stream);
        [PreserveSig] int GetControlWindow(uint id, out IntPtr hwnd);
        [PreserveSig] int SendControlMsg(uint id, uint message, IntPtr wParam, IntPtr lParam, out IntPtr result);
        [PreserveSig] int QueryActiveShellView(out IntPtr view);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativePoint
    {
        public int X;
        public int Y;
    }

    [ComImport, Guid("1AF3A467-214F-4298-908E-06B03E0B39F9")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFolderView2
    {
        [PreserveSig] int GetCurrentViewMode(out uint mode);
        [PreserveSig] int SetCurrentViewMode(uint mode);
        [PreserveSig] int GetFolder(ref Guid iid, out IntPtr folder);
        [PreserveSig] int Item(int index, out IntPtr pidl);
        [PreserveSig] int ItemCount(uint flags, out int count);
        [PreserveSig] int Items(uint flags, ref Guid iid, out IntPtr items);
        [PreserveSig] int GetSelectionMarkedItem(out int index);
        [PreserveSig] int GetFocusedItem(out int index);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out NativePoint point);
        [PreserveSig] int GetSpacing(out NativePoint point);
        [PreserveSig] int GetDefaultSpacing(out NativePoint point);
        [PreserveSig] int GetAutoArrange();
        [PreserveSig] int SelectItem(int index, uint flags);
        [PreserveSig] int SelectAndPositionItems(uint count, IntPtr pidls, IntPtr positions, uint flags);
        [PreserveSig] int SetGroupBy(IntPtr key, [MarshalAs(UnmanagedType.Bool)] bool ascending);
        [PreserveSig] int GetGroupBy(IntPtr key, [MarshalAs(UnmanagedType.Bool)] out bool ascending);
        [PreserveSig] int SetViewProperty(IntPtr pidl, IntPtr key, IntPtr value);
        [PreserveSig] int GetViewProperty(IntPtr pidl, IntPtr key, IntPtr value);
        [PreserveSig] int SetTileViewProperties(IntPtr pidl, [MarshalAs(UnmanagedType.LPWStr)] string list);
        [PreserveSig] int SetExtendedTileViewProperties(IntPtr pidl, [MarshalAs(UnmanagedType.LPWStr)] string list);
        [PreserveSig] int SetText(int type, [MarshalAs(UnmanagedType.LPWStr)] string text);
        [PreserveSig] int SetCurrentFolderFlags(uint mask, uint flags);
        [PreserveSig] int GetCurrentFolderFlags(out uint flags);
    }

    internal sealed class DesktopView : IDisposable
    {
        private const uint NoIcons = 0x1000; // FWF_NOICONS
        private object shellWindows;
        private object desktop;
        private object shellBrowser;
        private object shellView;
        private IFolderView2 view;

        public DesktopView()
        {
            try
            {
                Guid shellWindowsId = new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39");
                shellWindows = Activator.CreateInstance(Type.GetTypeFromCLSID(shellWindowsId, true));
                dynamic windows = shellWindows;
                object location = 0; // CSIDL_DESKTOP
                object root = null;
                int hwnd;
                desktop = windows.FindWindowSW(ref location, ref root, 8, out hwnd, 1);
                if (desktop == null)
                    throw new InvalidOperationException("The desktop view is unavailable.");

                Guid serviceId = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
                Guid browserId = typeof(IShellBrowser).GUID;
                IntPtr browserPointer;
                Check(((IShellServiceProvider)desktop).QueryService(ref serviceId, ref browserId, out browserPointer));
                shellBrowser = TakeComObject(browserPointer);

                IntPtr viewPointer;
                Check(((IShellBrowser)shellBrowser).QueryActiveShellView(out viewPointer));
                shellView = TakeComObject(viewPointer);
                view = (IFolderView2)shellView;
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public bool Hidden
        {
            get
            {
                uint flags;
                Check(view.GetCurrentFolderFlags(out flags));
                return (flags & NoIcons) != 0;
            }
        }

        public void SetHidden(bool hidden)
        {
            Check(view.SetCurrentFolderFlags(NoIcons, hidden ? NoIcons : 0));
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (Hidden == hidden)
                    return;
                Thread.Sleep(50);
            }

            throw new InvalidOperationException("The desktop view did not change.");
        }

        public void Dispose()
        {
            view = null;
            Release(ref shellView);
            Release(ref shellBrowser);
            Release(ref desktop);
            Release(ref shellWindows);
        }

        private static void Check(int result)
        {
            if (result < 0)
                Marshal.ThrowExceptionForHR(result);
        }

        private static object TakeComObject(IntPtr pointer)
        {
            try
            {
                return Marshal.GetObjectForIUnknown(pointer);
            }
            finally
            {
                if (pointer != IntPtr.Zero)
                    Marshal.Release(pointer);
            }
        }

        private static void Release(ref object value)
        {
            if (value != null && Marshal.IsComObject(value))
                Marshal.ReleaseComObject(value);
            value = null;
        }
    }

    internal static class Program
    {
        private const string AppName = "桌面图标开关";

        [STAThread]
        private static int Main(string[] args)
        {
            string command = args.Length == 0 ? "--toggle" : args[0].ToLowerInvariant();
            if (args.Length > 1)
                return ShowHelp(2);

            switch (command)
            {
                case "--help":
                case "/?":
                    return ShowHelp(0);
                case "--toggle":
                case "--show":
                case "--hide":
                    break;
                default:
                    return ShowHelp(2);
            }

            try
            {
                ChangeVisibility(command);
                return 0;
            }
            catch (Exception)
            {
                MessageBox.Show(
                    "暂时无法切换。你也可以右键桌面空白处，选择「查看」→「显示桌面图标」。",
                    AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 1;
            }
        }

        private static void ChangeVisibility(string command)
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            using (Mutex mutex = new Mutex(false, @"Local\DesktopIconToggle-" + identity.User.Value))
            {
                try
                {
                    if (!mutex.WaitOne(TimeSpan.FromSeconds(5)))
                        throw new TimeoutException();
                }
                catch (AbandonedMutexException)
                {
                    // The previous process exited. This thread now owns the mutex.
                }

                try
                {
                    using (DesktopView desktop = new DesktopView())
                    {
                        bool wasHidden = desktop.Hidden;
                        bool hide = command == "--hide" || (command == "--toggle" && !wasHidden);
                        if (hide != wasHidden)
                            desktop.SetHidden(hide);
                    }
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }

        private static int ShowHelp(int exitCode)
        {
            MessageBox.Show(
                "在开始菜单打开「桌面图标开关」即可切换。打开「恢复桌面图标」会直接显示图标。\n\n"
                + "命令行参数：--toggle、--show、--hide、--help",
                AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return exitCode;
        }
    }
}
