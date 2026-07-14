$sig = @'
using System;
using System.Runtime.InteropServices;
public class MK {
  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEKEYS {
    public uint cbSize;
    public uint dwFlags;
    public uint iMaxSpeed;
    public uint iTimeToMaxSpeed;
    public uint iCtrlSpeed;
    public uint dwReserved1;
    public uint dwReserved2;
  }
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SystemParametersInfo(uint a, uint b, ref MOUSEKEYS c, uint d);
  public const uint SPI_SETMOUSEKEYS = 0x0037;
  public const uint SPI_GETMOUSEKEYS = 0x0036;
  public const uint SPIF_UPDATEINIFILE = 0x01;
  public const uint SPIF_SENDCHANGE = 0x02;
  public static string Run() {
    MOUSEKEYS mk = new MOUSEKEYS();
    mk.cbSize = (uint)Marshal.SizeOf(typeof(MOUSEKEYS));
    mk.dwFlags = 0x01 | 0x02; // MKF_MOUSEKEYSON | MKF_AVAILABLE
    mk.iMaxSpeed = 80;
    mk.iTimeToMaxSpeed = 3000;
    mk.iCtrlSpeed = 0;
    bool ok = SystemParametersInfo(SPI_SETMOUSEKEYS, mk.cbSize, ref mk, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
    // read back
    MOUSEKEYS chk = new MOUSEKEYS();
    chk.cbSize = (uint)Marshal.SizeOf(typeof(MOUSEKEYS));
    SystemParametersInfo(SPI_GETMOUSEKEYS, chk.cbSize, ref chk, 0);
    return "set_ok=" + ok + " readback_flags=0x" + chk.dwFlags.ToString("X");
  }
}
'@
Add-Type -TypeDefinition $sig
# Persist the registry Flags first (survives reboots, shows enabled in Settings).
New-Item -Path 'HKCU:\Control Panel\Accessibility\MouseKeys' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Control Panel\Accessibility\MouseKeys' -Name 'Flags' -Value '63' -Type String
# Re-apply MouseKeys repeatedly over the first ~20s. The logon task has NO fixed
# startup delay (start immediately), so the first apply can land before the session's
# cursor subsystem is ready — with no physical mouse the cursor's display count is
# forced to -1 (hidden), and a single early SystemParametersInfo returns success but
# doesn't make the cursor appear. Re-applying as the session settles makes it reliably
# show up without a long up-front wait. Each call broadcasts WM_SETTINGCHANGE.
$r = ''
for ($i = 0; $i -lt 10; $i++) {
  $r = [MK]::Run()
  Start-Sleep -Seconds 2
}
Set-Content -Path C:\Tools\mousekeys-result.txt -Value "$r registry_flags=63 (re-applied 10x over ~20s)"
