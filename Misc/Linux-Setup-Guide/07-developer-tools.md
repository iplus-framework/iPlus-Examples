# Developer Tools Setup
## 1. Git Installation
```bash
sudo apt update
sudo apt install git
sudo apt install git-lfs
```

## 2. Git Configuration

Handling Personal vs. Work identities correctly using Git.

### `.gitconfig` Structure
We use conditional includes to separate configuration based on the directory path or remote URL.

**`~/.gitconfig` (Global):**
```ini
[includeIf "hasconfig:remote.*.url:git@github.com:*/**"]
    path = ~/.gitservers/.gitconfig-github
[includeIf "hasconfig:remote.*.url:ssh://user@private-repo.com*/**"]
    path = ~/.gitservers/.gitconfig-work
```

**`~/.gitservers/.gitconfig-github`:**
```ini
[user]
    name = Damir Lisak
    email = public@example.com
```

**`~/.gitservers/.gitconfig-work`:**
```ini
[user]
    name = Damir Lisak
    email = work@example.com
```

### SSH Configuration (`~/.ssh/config`)
Automate key selection for different hosts.

1.  **Generate/Copy Keys:** Ensure permissions are strict (`chmod 600`).
2.  **Add to Agent:** `ssh-add ~/.ssh/id_rsa_work`
3.  **Config File:**

```ssh
# Work Server
Host private-repo.com
    HostName private-repo.com
    User git
    IdentityFile ~/.ssh/id_rsa_work
    AddKeysToAgent yes

# GitHub
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_rsa_github
    AddKeysToAgent yes
```

## 3. VS Code & .NET

### Install .NET SDK
For native Linux development (Avalonia, Console, Web API):

```bash
sudo apt-get update && sudo apt-get install -y dotnet-sdk-8.0
# Or specific version like 6.0 / 9.0
```

### VS Code Extensions
Recommended extensions for .NET development:
*   **C# Dev Kit** (Microsoft)
*   **Avalonia for VSCode** (if doing UI work)
*   **Docker**
*   **Remote - SSH**

### NUGET
If you are experiencing problems with the NuGet V3 API in a Windows VM due to Incus NAT:

References:
*   [Nuget](https://github.com/NuGet/NuGetGallery/issues/10448)
*   [VS Community](https://developercommunity.visualstudio.com/t/Cant-connect-to-nuget-api/11001841?sort=active)

Switch Nuget API in Visual Studio Settings from [V3](https://api.nuget.org/v3/index.json) to [V2](https://nuget.org/api/v2) until this bug is fixed.

Another possible cause is the prioritization of IPv6 over IPv4. This order can be resolved as follows:

```bash
sudo vim /etc/gai.conf
Remove hashtag:
precedence ::ffff:0:0/96 100
systemctl restart systemd-networkd
```
References:
*   [VS Community](https://zomro.com/blog/faq/471-changing-priority-from-ipv6-to-ipv4-in-ubuntu-and-centos-a-complete-guide)

### Building WPF project on Linux with VS Code
Normally, you can't compile WPF projects with VS Code because Microsoft doesn't provide the Microsoft.WindowsDesktop.App package for Linux. However, with a few tricks, it's possible to compile the iPlus WPF version and even develop it in VS Code (using Code IntelliSense...). Read Chapter [Extra Utilities](08-extras.md) first.

1. [Download SDK for Windows x64](https://dotnet.microsoft.com/en-us/download/dotnet/10.0) because it contains the Microsoft.WindowsDesktop.App package.
2. Copy the Microsoft.WindowsDesktop.App to the dotnet packs folder of linux:
   ```bash
   cp -r ~/".wine/drive_c/Program Files/dotnet/packs/Microsoft.WindowsDesktop.App.Ref" ~/.dotnet/packs/
   ```
3. Open Settings in VS Code and search and set this parameter:
   * dotnet.server.useOmnisharp = true
   * omnisharp.useModernNet = true
   * omnisharp.enableMsBuildLoadProjectsOnDemand = true

4. Restart VS Code.
5. Modify your csproj ot Directory.Build.props and add
   ```
   <EnableWindowsTargeting>true</EnableWindowsTargeting>
   ```
7. If you encounter error messages (NU3028 and NU3037) during compilation, you will need to copy the nuget packages yourself into the nuget packages folder.
8. For launching iPlus WPF-App you have to [add a launch.json and tasks.json into you .vscode directory](/Misc/Linux-Setup-Guide/Files). 


## 3. VS Code on Linux & Legacy Projects with NETFRAMEWORK 4.8

1. [Install Mono](https://www.mono-project.com/download/stable/) or [newer versions from Wine](https://gitlab.winehq.org/mono/mono).
    ```bash
    sudo apt install ca-certificates gnupg
    sudo gpg --homedir /tmp --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/mono-official-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF
    sudo chmod +r /usr/share/keyrings/mono-official-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/mono-official-archive-keyring.gpg] https://download.mono-project.com/repo/ubuntu stable-focal main" | sudo tee /etc/apt/sources.list.d/mono-official-stable.list
    sudo apt update
    sudo apt install mono-complete msbuild
    ```
2. In VS Code settings locate "OmniSharp: Mono Path" and set its value to /usr
3. Add a settings.json file to the .vscode folder
    ```json
    {
        "dotnet.server.useOmnisharp": true,
        "omnisharp.useModernNet": false,
        "omnisharp.loggingLevel": "debug"
    }
    ```
4. Open Extensions and deactivate .NET MAUI and C# Dev Kit Extension for this workspace
5. Restart extensions or reopen VS Code

## 4. VS Code with WINE & Legacy Projects with NETFRAMEWORK 4.8
Solution 3 has the disadvantage that you cannot compile WPF projects. Therefore, an alternative solution is to install VS Code in Wine and also the WPF SDK for framework 4.8. Please read how to [install wine and dnspy](08-extras.md) first.

1. Download the [Developer Pack](https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48) and install it in Wine:
    ```bash
    WINEPREFIX="$HOME/.wine-yourprefix" wine NDP48-DevPack-ENU.exe
    ```
2. Download [VS Code for Windows](https://code.visualstudio.com/download) and install it in Wine:
    ```bash
    WINEPREFIX="$HOME/.wine-yourprefix" wine VSCodeSetup-x64-1.108.2.exe
    ```
3. Download [Powershell msi installer for Windows](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows) and install it in Wine:
    ```bash
    WINEPREFIX="$HOME/.wine-yourprefix" wine PowerShell-7.5.4-win-x64.msi
    ```    
4. Start VS Code in Wine and install the C# for Visual Studio Code Extension 
**ms-dotnettools.csharp Version 1.24.4**. Not a newer one, because this is the last version where msbuild.exe is shipped with omnisharp! Don't install the C# Dev Kit (It's only for net core projects) and you will get problems with omnisharp because it sets the setting "Use Modern Sharp".
    ```bash
    WINEPREFIX="$HOME/.wine-yourprefix" wine code
    ```   
    To be on the safe side, you can create a **settings.json** file to turn it off for your project if you also have net core project where you need the C# Dev Kit.
    ```json 
    {
        "dotnet.server.useOmnisharp": true,
        "omnisharp.useModernNet": false,
        "omnisharp.loggingLevel": "debug"
    }
    ```
5. Install mono. 
    ```bash
    WINEPREFIX="$HOME/.wine-dotnet48-64" winetricks mono
    WINEPREFIX="$HOME/.wine-dotnet48-64" wineboot -k    
    ```    
6. To be able to run msbuild with powershell, the path to msbuild.exe must be set and persisted. Open the powershell terminal in VS Code and run:
    ```bash
    Set-Alias -Name msbuild -Value "C:\users\yourusername\.vscode\extensions\ms-dotnettools.csharp-1.24.4-win32-x64\.omnisharp\1.38.2\.msbuild\Current\Bin\MSBuild.exe" -Force
    
    New-Item -ItemType Directory -Force -Path "$Home\Documents\PowerShell"
    
    New-Item -ItemType File -Force -Path "$Home\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    
    Add-Content -Path $PROFILE -Value 'Set-Alias -Name msbuild -Value "C:\users\yourusername\.vscode\extensions\ms-dotnettools.csharp-1.24.4-win32-x64\.omnisharp\1.38.2\.msbuild\Current\Bin\MSBuild.exe" -Force'
    ```   
    Reload powershell terminal.
7. If your build your solution e.g. **"msbuild iPlusNoTools.sln -m"** you may get an version mismatch of the installed assemblies of omnisharp. Therefore check for each error if the version number of the assembly is the same as declared in the MSBuild.exe.config. You find it in the this under this location:   
    /home/yourusername/.wine-yourprefix/drive_c/users/yourusername/.vscode/extensions/ms-dotnettools.csharp-1.24.4-win32-x64/.omnisharp/1.38.2/.msbuild/Current/Bin/MSBuild.exe.config   
    Open the MSBuild.exe.config and search for the Asslembly. In Version 1.24.4 are these assemblies which are wrong. This is the fix:
    ```xml
      <dependentAssembly>
        <assemblyIdentity name="System.Threading.Tasks.Dataflow" publicKeyToken="b03f5f7f11d50a3a" culture="neutral" />
        <bindingRedirect oldVersion="0.0.0.0-6.0.0.0" newVersion="5.0.0.0" />
      </dependentAssembly>
      
      <dependentAssembly>
        <assemblyIdentity name="System.Resources.Extensions" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral" />
        <bindingRedirect oldVersion="0.0.0.0-4.0.0.0" newVersion="4.0.1.0" />
      </dependentAssembly>
    ```   
    To determine which Version ist installed use the exiftool:
    ```bash
    exiftool /home/damir/.wine-yourprefix/drive_c/users/yourusername/.vscode/extensions/ms-dotnettools.csharp-1.24.4-win32-x64/.omnisharp/1.38.2/.msbuild/Current/Bin/System.Resources.Extensions.dll | grep Version
    ```

### Debugging
Unfortunately there is no possibility to debug netframework 4.8 WPF Applications directly with VS Code debugger on Wine. In the launch.json settings you have three debugger options:
1. **"type": "coreclr"**: This is for NET Core projects. If you start a net48 wpf application, the app will start but the debugger won't attach.
2. **"type": "clr"**: This is for net48 projects. This only works on a Windows machine.
3. **"type": "mono"**: This is for debugging net48 projects but not for WPF! For normal net48 projects you can download the installer from the mono site and install it:
    ```bash 
    WINEPREFIX="$HOME/.wine-dotnet48-64" wine mono-6.12.0.206-x64-0.msi
    WINEPREFIX="$HOME/.wine-dotnet48-64" wine regedit
    # Edit HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment\Path and Append C:\Program Files\Mono\bin
    WINEPREFIX="$HOME/.wine-dotnet48-64" wineboot
    ```   
    Then install the **ms-vscode.mono-debug** extension in VS code. Now your debugger is able to debug. IMPORTANT: You can only debug projects that have a portable pdb format. Therefore change in all your *csproj files the Debug-Type:
    ```xml
    <DebugType>portable</DebugType>
    ```   
You only can debug it with dnspy. But you can automate, that you launch the application from VS Code and automatically attach dnspy.  
Create a excecutable shell script with name "wine_debug_dnspy.sh":
```bash 
#!/bin/bash
export WINEPREFIX=$HOME/.wine-dotnet48-64

# $1 might be /home/damir/... or D:\...
INPUT_PATH="$1"

# 1. Normalize paths using winepath to handle mixed slashes (from VS Code)
LINUX_FULL_PATH=$(winepath -u "$INPUT_PATH")
LINUX_EXE_DIR=$(dirname "$LINUX_FULL_PATH")
EXE_PATH=$(winepath -w "$INPUT_PATH")
EXE_NAME=$(basename "$LINUX_FULL_PATH")

# 3. Clear dnSpy session
DNSPY_CONFIG_DIR="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/dnSpy"
if [ -d "$DNSPY_CONFIG_DIR" ]; then
    rm -rf "$DNSPY_CONFIG_DIR"/*
fi

# 4. Find all gip DLLs
DLL_LIST=$(find "$LINUX_EXE_DIR" -maxdepth 1 -name "gip.*.dll" -exec winepath -w {} +)

# 5. Launch
wine "$EXE_PATH" &
sleep 2

DNSPY_BIN="/home/damir/SHARED/Devel/Tools/dnSpy/dnSpy-netframework/dnSpy.exe"
wine "$DNSPY_BIN" -pn "$EXE_NAME" "$EXE_PATH" $DLL_LIST
```
Add to your launch.json file this section:  
```json 
{
    "name": "DNSPY Launch",
    "type": "node-terminal",
    "request": "launch",
    "command": "${workspaceFolder}/../wine_debug_dnspy.sh \"${workspaceFolder}/bin/Debug/gip.iplus.client.exe\"",
    "cwd": "${workspaceFolder}",
}
```
Now you are ready to debug the WPF-Application.