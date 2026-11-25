# Query the running kernel, independently of the boot entry for the next restart.
$ErrorActionPreference = 'Stop'
if (!('Voxt.WindowsCodeIntegrity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Voxt {
    public static class WindowsCodeIntegrity {
        [StructLayout(LayoutKind.Sequential)]
        private struct IntegrityInfo {
            public uint Length;
            public uint Options;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQuerySystemInformation(
            int informationClass, ref IntegrityInfo info, uint size, out uint returned);

        public static bool AllowsTestSigning() {
            var info = new IntegrityInfo { Length = (uint)Marshal.SizeOf(typeof(IntegrityInfo)) };
            uint returned;
            int status = NtQuerySystemInformation(103, ref info, info.Length, out returned);
            if (status != 0 || returned < info.Length)
                throw new InvalidOperationException(String.Format("SystemCodeIntegrityInformation: 0x{0:X8}", status));
            return (info.Options & 0x02) != 0;
        }
    }
}
'@
}
[Voxt.WindowsCodeIntegrity]::AllowsTestSigning()
