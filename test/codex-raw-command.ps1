param(
    [string] $Command = $env:FORGEWARD_COMMAND,
    [string] $PluginRoot = $env:PLUGIN_ROOT,
    [string] $PathValue,
    [string] $WorkingDirectory = $env:SystemRoot
)

if ([string]::IsNullOrEmpty($Command)) { exit 2 }

$ProgressPreference = 'SilentlyContinue'
$env:PLUGIN_ROOT = $PluginRoot
if ($PathValue) { $env:PATH = $PathValue }

# ProcessStartInfo.Arguments reparses the complete string. Codex does not:
# std::process::Command passes /C normally, then appends the configured hook as
# one raw argument. Build that final CreateProcessW command line directly.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexRawCommand
{
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint CREATE_ALWAYS = 2, OPEN_EXISTING = 3;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80, STARTF_USESTDHANDLES = 0x100;
    const uint CREATE_NO_WINDOW = 0x08000000, INFINITE = 0xffffffff;

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES {
        public int nLength; public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
        public uint dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share,
        ref SECURITY_ATTRIBUTES attributes, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startup,
        out PROCESS_INFORMATION process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);

    static IntPtr OpenHandle(string path, uint access, uint disposition) {
        SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
        attributes.nLength = Marshal.SizeOf(attributes);
        attributes.bInheritHandle = true;
        IntPtr handle = CreateFileW(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE,
            ref attributes, disposition, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    public static int Run(string comspec, string hook, string cwd,
        string inputPath, string outputPath, string errorPath) {
        IntPtr input = IntPtr.Zero, output = IntPtr.Zero, error = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        try {
            input = OpenHandle(inputPath, GENERIC_READ, OPEN_EXISTING);
            output = OpenHandle(outputPath, GENERIC_WRITE, CREATE_ALWAYS);
            error = OpenHandle(errorPath, GENERIC_WRITE, CREATE_ALWAYS);
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(startup);
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdInput = input; startup.hStdOutput = output; startup.hStdError = error;
            StringBuilder line = new StringBuilder("\"" + comspec + "\" /C \"" + hook + "\"");
            if (!CreateProcessW(comspec, line, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_NO_WINDOW, IntPtr.Zero, cwd, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(process.hThread); process.hThread = IntPtr.Zero;
            CloseHandle(input); input = IntPtr.Zero;
            CloseHandle(output); output = IntPtr.Zero;
            CloseHandle(error); error = IntPtr.Zero;
            WaitForSingleObject(process.hProcess, INFINITE);
            uint exitCode;
            if (!GetExitCodeProcess(process.hProcess, out exitCode))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)exitCode);
        } finally {
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (input != IntPtr.Zero) CloseHandle(input);
            if (output != IntPtr.Zero) CloseHandle(output);
            if (error != IntPtr.Zero) CloseHandle(error);
        }
    }
}
'@

$inputPath = [IO.Path]::GetTempFileName()
$outputPath = [IO.Path]::GetTempFileName()
$errorPath = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($inputPath, [Console]::In.ReadToEnd(), [Text.UTF8Encoding]::new($false))
    $exitCode = [CodexRawCommand]::Run(
        $env:COMSPEC, $Command, $WorkingDirectory, $inputPath, $outputPath, $errorPath)
    [Console]::Out.Write([IO.File]::ReadAllText($outputPath))
    [Console]::Error.Write([IO.File]::ReadAllText($errorPath))
    exit $exitCode
}
finally {
    Remove-Item -LiteralPath $inputPath, $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
}
