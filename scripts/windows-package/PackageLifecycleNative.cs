// Native helpers for test-windows-package-lifecycle.ps1, compiled by Add-Type.
// C# 5 only: Windows PowerShell 5.1 compiles this with the .NET Framework
// CodeDOM compiler. Everything here observes the app from outside; nothing
// sends input to other applications or reads their memory beyond window text.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Jsti.PackageLifecycle
{
    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
        [PreserveSig]
        int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, IntPtr itemArray,
            [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig]
        int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, IntPtr itemArray,
            out uint processId);
    }

    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager
    {
    }

    public sealed class Activation
    {
        public int HResult;
        public uint ProcessId;
    }

    public static class Native
    {
        const int ActivateNoErrorUI = 0x2;
        const uint WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E, WM_CLOSE = 0x0010;
        const uint LB_GETTEXT = 0x0189, LB_GETTEXTLEN = 0x018A, LB_GETCOUNT = 0x018B;
        const uint SMTO_ABORTIFHUNG = 0x0002, MessageTimeout = 5000;
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, TOKEN_QUERY = 0x0008;
        const int TokenIntegrityLevel = 25, AppModelErrorNoPackage = 15700, ErrorInsufficientBuffer = 122;

        delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll")]
        static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr GetDlgItem(IntPtr window, int identifier);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, StringBuilder lParam,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
        static extern IntPtr SendMessageTimeoutValue(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder name);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);
        [DllImport("advapi32.dll")]
        static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("advapi32.dll")]
        static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

        // The same activation the Start menu performs for an app user model ID.
        public static Activation Activate(string appUserModelId, string arguments)
        {
            IApplicationActivationManager manager = (IApplicationActivationManager)new ApplicationActivationManager();
            try
            {
                uint processId;
                int result = manager.ActivateApplication(appUserModelId, arguments, ActivateNoErrorUI, out processId);
                Activation activation = new Activation();
                activation.HResult = result;
                activation.ProcessId = processId;
                return activation;
            }
            finally
            {
                Marshal.ReleaseComObject(manager);
            }
        }

        public static IntPtr FindWindow(uint processId, string className)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindowsProc callback = delegate(IntPtr window, IntPtr parameter)
            {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner != processId) return true;
                StringBuilder name = new StringBuilder(256);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() != className) return true;
                found = window;
                return false;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found;
        }

        static IntPtr Control(IntPtr window, int identifier)
        {
            IntPtr control = GetDlgItem(window, identifier);
            if (control == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Missing control " + identifier);
            return control;
        }

        static int SendValue(IntPtr window, uint message, int wParam)
        {
            IntPtr result;
            if (SendMessageTimeoutValue(window, message, new IntPtr(wParam), IntPtr.Zero, SMTO_ABORTIFHUNG,
                MessageTimeout, out result) == IntPtr.Zero)
            {
                throw new TimeoutException("The app window did not answer message 0x" + message.ToString("X"));
            }
            return result.ToInt32();
        }

        static string SendText(IntPtr window, uint message, int wParam, int length)
        {
            StringBuilder buffer = new StringBuilder(Math.Max(length, 0) + 2);
            IntPtr result;
            if (SendMessageTimeout(window, message, new IntPtr(wParam), buffer, SMTO_ABORTIFHUNG, MessageTimeout,
                out result) == IntPtr.Zero)
            {
                throw new TimeoutException("The app window did not answer message 0x" + message.ToString("X"));
            }
            return buffer.ToString();
        }

        public static string GetControlText(IntPtr window, int identifier)
        {
            IntPtr control = Control(window, identifier);
            int length = SendValue(control, WM_GETTEXTLENGTH, 0);
            return SendText(control, WM_GETTEXT, length + 1, length);
        }

        public static int GetListBoxCount(IntPtr window, int identifier)
        {
            return SendValue(Control(window, identifier), LB_GETCOUNT, 0);
        }

        public static string[] GetListBoxItems(IntPtr window, int identifier)
        {
            IntPtr control = Control(window, identifier);
            int count = SendValue(control, LB_GETCOUNT, 0);
            List<string> items = new List<string>();
            for (int index = 0; index < count; index++)
            {
                int length = SendValue(control, LB_GETTEXTLEN, index);
                items.Add(length < 0 ? "" : SendText(control, LB_GETTEXT, index, length));
            }
            return items.ToArray();
        }

        public static bool RequestClose(IntPtr window)
        {
            return PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }

        static IntPtr OpenForQuery(uint processId)
        {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            return process;
        }

        // Null means the process runs without package identity.
        public static string GetPackageFullName(uint processId)
        {
            IntPtr process = OpenForQuery(processId);
            try
            {
                uint length = 0;
                int result = GetPackageFullName(process, ref length, null);
                if (result == AppModelErrorNoPackage) return null;
                if (result != ErrorInsufficientBuffer) throw new Win32Exception(result);
                StringBuilder name = new StringBuilder((int)length);
                result = GetPackageFullName(process, ref length, name);
                if (result != 0) throw new Win32Exception(result);
                return name.ToString();
            }
            finally
            {
                CloseHandle(process);
            }
        }

        public static string GetIntegrityLevel(uint processId)
        {
            IntPtr process = OpenForQuery(processId);
            IntPtr token = IntPtr.Zero;
            IntPtr buffer = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(process, TOKEN_QUERY, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                int length;
                GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out length);
                buffer = Marshal.AllocHGlobal(length);
                if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, length, out length))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                int rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                if (rid >= 0x4000) return "system";
                if (rid >= 0x3000) return "high";
                if (rid >= 0x2000) return "medium";
                if (rid >= 0x1000) return "low";
                return "untrusted";
            }
            finally
            {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (token != IntPtr.Zero) CloseHandle(token);
                CloseHandle(process);
            }
        }
    }
}
