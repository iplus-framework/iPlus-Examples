# Seamless RDP Integration

To integrate Windows applications (like Visual Studio or SSMS) naturally into your Linux desktop without running a full desktop window, we use RDP "Seamless Mode" (RAIL).

## 1. Install FreeRDP

Install the latest FreeRDP 3 clients:

```bash
sudo apt install freerdp3-wayland freerdp3-sdl freerdp3-x11
```

## 2. Network Optimization (Fixing "Broken Pipe")

When running RDP over the Incus NAT bridge, strict MTU sizes often cause connections to drop when transmitting large bitmaps.

1.  **Lower Interface MTU:**
    ```bash
    incus network set incusbr0 bridge.mtu 1400
    ```

2.  **Enable MSS Clamping (Critical):**
    This forces TCP packets to fit within the tunnel.
    ```bash
    sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ```

## 3. Windows VM Configuration

Registry changes are required on Windows to allow "Remote Applications" (RAIL) to start.

Create a `.reg` file in Windows and run it, or edit manually:

**Registry Path:** `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList`
*   Value: `fDisabledAllowList` = `1` (DWORD)

**Registry Path:** `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`
*   Value: `fAllowUnlistedRemotePrograms` = `1` (DWORD)

**Restart the Windows VM after applying these changes.**

## 4. Connecting to Applications

You can now launch specific executables from your Linux terminal using `xfreerdp3`.

### Examples

**Visual Studio:**
```bash
xfreerdp3 /u:administrator /p:YOUR_PASSWORD /v:gipDLVmWin11.incus /cert:ignore /app:program:'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe' /kbd:layout:0x00000407
```

**SQL Server Management Studio (SSMS):**
```bash
xfreerdp3 /u:administrator /p:YOUR_PASSWORD /v:gipDLVmWin11.incus /cert:ignore /app:program:'C:\Program Files\Microsoft SQL Server Management Studio 19\Common7\IDE\SSMS.exe' /kbd:layout:0x00000407
```
*(Note: `/kbd:layout:0x00000407` is for German keyboard layout. Use `xfreerdp3 /list:kbd` to find yours.)*

### Creating Linux Desktop Shortcuts

Create a `.desktop` file (e.g., `~/.local/share/applications/vs-seamless.desktop`) to add it to your start menu.

```ini
[Desktop Entry]
Version=1.0
Type=Application
Name=Visual Studio (VM)
Comment=Starts VS2022 via xfreerdp3
Exec=xfreerdp3 /u:administrator /p:PASSWORD /v:gipDLVmWin11.incus /cert:ignore /app:program:'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe' /wm-class:vs-remote
Icon=ms-visual-studio
Terminal=false
StartupWMClass=vs-remote
Categories=Development;IDE;
```
