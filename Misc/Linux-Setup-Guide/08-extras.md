# Extra Utilities

## 1. Wine
For running simple Windows tools without a full VM.

[Wine Installation Guide (Ubuntu Users)](https://wiki.ubuntuusers.de/Wine/)

```bash
sudo apt-get install wine-stable 
sudo apt install winetricks ttf-mscorefonts-installer
```

### Install newest Version of wine:
https://ubuntuhandbook.org/index.php/2026/01/wine-11-0-released-how-to-install/
```bash
sudo mkdir -p /etc/apt/keyrings
wget -O - https://dl.winehq.org/wine-builds/winehq.key | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key
sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
sudo apt update
sudo apt install --install-recommends winehq-stable
```
### NET Framework 4.8 Compatibitlity
Running net 4.8 applications in Wine by creating a separate wine prefix with win32. 
Microsoft Data Access components must also be installed otherwise mono uses a Oracle provider when connecting to an SQL-Server. 

```bash
WINEPREFIX="$HOME/.wine-dotnet48" WINEARCH=win32 winecfg
WINEPREFIX="$HOME/.wine-dotnet48" winetricks -q dotnet48
WINEPREFIX="$HOME/.wine-dotnet48" winetricks mdac28
```

### Important notes for using iPlus-framework applications V4 (net48)
There is an issue when iPlus is started and have to read the metadata files. To get it running the absolute path to the metadata has to be set. And backslashes must be set twice because linux interprets it as an escape character! Here an example:

```
    <add name="iPlusMESV4_Entities" connectionString="metadata=C:\\iPlus\V4\\Dostofarm\\Debug\\iplusmesv4.csdl|C:\\iPlus\V4\\\Dostofarm\\\Debug\\iplusmesv4.ssdl|C:\\iPlus\V4\\Dostofarm\\Debug\\iplusmesv4.msl;provider=System.Data.SqlClient;provider connection string=&quot;data source=gipDLVmSQL1.incus;initial catalog=DostofarmV4;persist security info=True;user id=gip;password=netspirit;MultipleActiveResultSets=True;Asynchronous Processing=True;App=iPlus_dbApp&quot;"
    providerName="System.Data.EntityClient" />
```

### Starting applications
- **Run**
    ```bash
    WINEPREFIX="/home/damir/.wine-dotnet48" wine gip.variobatch.client.exe
    ```
- **Read or log debug output examples**
    ```bash
    WINEPREFIX="/home/damir/.wine-dotnet48" WINEDEBUG=+file wine gip.variobatch.client.exe 2>&1 | grep "csdl|ssl|msl"
    WINEPREFIX="/home/damir/.wine-dotnet48" WINEDEBUG=+file wine gip.variobatch.client.exe > debug_paths.log 2>&1
    ```
#

### Issues with Rendering KDE/Wayland (Black Context Menu)
    ```bash
    WINEPREFIX="/home/damir/.wine-dotnet48" winetricks ddr=gdi
    ```
### Printing
- **PDF and XPS-Utils**
   XPS-Utils are needed, because iPlus prints with XPS:
    ```bash
    sudo apt install printer-driver-cups-pdf
    sudo apt install libcups2:i386
    sudo apt install libgxps-utils
    sudo apt install libcups2:i386 libpaper1:i386 libpango-1.0-0:i386
    ```
- **GENERIC CUPS-PDF Printer**
  Open Printer Settings and select "GENERIC CUPS-PDF Printer (no options)" as driver

### Scaling
Open Wine config and set scaling to 120dpi:
```bash
WINEPREFIX="/home/damir/.wine-dotnet48" winecfg
WINEPREFIX="/home/damir/.wine-dotnet48" winetricks settings fontsmooth=rgb
```
### iPlus in Startmenu
1. Open KDE Menu Editor
2. Add a new entry
3. Set Parameters (example)
   - Environment: WINEPREFIX=/home/damir/.wine-dotnet48/
   - Application: wine
   - Arguments: '/home/damir/SHARED/Devel/iPlusGit/V4/iPlusMES/bin/Debug/gip.mes.client.exe'
  
### Fonts
If you have a Windows Installation just copy the fonts from "C:\Windows\Fonts" to your linux folder "/usr/local/share/fonts/". (According to MS EULA this is not allowed 🙈)

### iPlus Property log
iPlus uses [Manages Esent](https://github.com/microsoft/ManagedEsent) for logging of property values. Therefore the Esent.Interop.dll needs the esent.dll from the System32 Directory. This esent.dll is a complex database engine core to Windows. Wine's version of this DLL is often a "stub," meaning the file exists but the actual code inside JetCreateInstance is empty or just returns an error code that .NET then translates into an exception. 
1. Therefore copy the original esent.dll from a Win 10 or Win 11 installation into the directory of your wine prefix. For instance 
    - in the example prefix from above "/home/damir/.wine-dotnet48/drive_c/windows/system32/" (legacy V4 Version of iplus) 
    - or the standard prefix "/home/damir/.wine/drive_c/windows/system32/" if you run there the net core Version V5 of iPlus.
2. Then run winecfg in your wine prefix. 
3. Go to the Libraries tab.
4. Type esent in the "New override for library" box and click Add.
5. Ensure it is set to (native, builtin). This tells Wine to use the real Windows file you just provided instead of its own stub.

    
## 2. Microsoft Teams
Use the unofficial "Teams for Linux" client which wraps the web version effectively.
[GitHub: Teams for Linux](https://github.com/IsmaelMartinez/teams-for-linux)

## 3. Thunderbird
Standard email client setup.
[Mozilla Support](https://support.mozilla.org/en-US/kb/installing-thunderbird-linux)
