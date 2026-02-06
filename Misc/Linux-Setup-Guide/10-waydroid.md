# Waydroid Setup for Android Development

## Introduction

Waydroid allows you to run a full Android system on your Linux host using Linux namespaces (similar to LXC/Docker). This provides a highly performant, native-like Android environment for testing and debugging .NET MAUI or Avalonia applications, eliminating the need for slow, resource-heavy Android emulators.

## 1. Installation

Follow the official instructions to install Waydroid. For Debian/Ubuntu-based systems, use the following commands:

```bash
sudo apt install curl ca-certificates -y
curl -s https://repo.waydro.id | sudo bash
sudo apt install waydroid -y
sudo waydroid init
```

Once installed, you can launch Waydroid from your application menu.

### Network Note
Waydroid creates its own bridge network interface named `waydroid0`, typically using the `192.168.240.1/24` subnet. This usually coexists with the `incusbr0` bridge without issues. Both host processes and Incus containers/VMs can reach the Waydroid instance without additional routing configuration.

## 2. File Sharing (Mounting Host Directories)

To access files from your Linux host within Waydroid (e.g., for uploading documents or inspecting logs), you can mount a host directory into the Waydroid file system.

**Syntax:**
```bash
sudo mount --bind <host_path> ~/.local/share/waydroid/data/media/0/<android_path>
```

**Example:**
To mount your shared "Devel" folder to the Android "Documents" folder:
```bash
sudo mount --bind /home/damir/SHARED ~/.local/share/waydroid/data/media/0/Documents
```

## 3. Window Configuration

By default, Waydroid launches in full-screen mode. You can configure it to run in a fixed window size for better desktop integration.

### Setting Custom Resolution
To set a specific resolution (e.g., 720x1600), run the following commands while Waydroid is running:

```bash
waydroid prop set persist.waydroid.width 720
waydroid prop set persist.waydroid.height 1600
```

### Fixing Navigation Bar Visibility
When running in a custom resolution, Waydroid may still attempt to use the full host screen height, which can push the Android navigation bar off-screen. To fix this, you must calculate and apply vertical padding.

**Formula:** `(MonitorHeight - DeviceHeight) / 2`

**Example:**
For a monitor height of 1920 pixels and a configured device height of 1600 pixels:
$(1920 - 1600) / 2 = 160$

Set the padding:
```bash
waydroid prop set persist.waydroid.height_padding 160
```

### Applying Changes
Changes take effect after restarting Waydroid:
1. Right-click the Waydroid icon in the taskbar and select **Stop**.
2. Start Waydroid again.

### Resetting to Full Screen
To remove custom sizing and revert to default behavior:
```bash
waydroid prop set persist.waydroid.width ""
waydroid prop set persist.waydroid.height ""
# Restart Waydroid after running these commands
```

## 4. Enabling Debugging (ADB)

To deploy and debug applications, you must enable Android Debug Bridge (ADB) connectivity.

### A) Configure System ADB
1. Edit the Waydroid configuration file:
   ```bash
   sudo nano /var/lib/waydroid/waydroid.cfg
   ```
2. Find and set the parameter `auto_adb = True`.
3. Restart Waydroid.
4. Install ADB on your Linux host and connect:
   ```bash
   sudo apt install adb
   adb connect <WAYDROID_IP>:5555
   ```
   *(Check your Android settings for the IP address if unknown)*.
5. A confirmation dialog will appear inside Waydroid. Check "Always allow from this computer" and click **Allow**.

### B) Enable Developer Mode in Android
1. Open the **Settings** app inside Waydroid.
2. Navigate to **About phone**.
3. Tap **Build number** 7 times to enable Developer Mode.
4. Go to **System** > **Developer options**.
5. Enable **USB debugging** and **Wireless debugging**.

---

## 5. Visual Studio Integration (Windows VM)

You can debug .NET MAUI or Android applications running in Visual Studio (inside your Windows VM) directly on the Waydroid instance running on the Linux host.

### Prerequisites (Windows)
- Ensure the **.NET Multi-platform App UI development** workload is installed via Visual Studio Installer.
- **Critical:** Open your Android Project Properties and uncheck **"Use Fast Deployment"**. This is often required for stability with Waydroid.

### Connecting via ADB
1. In Visual Studio, go to **Tools** > **Android** > **Android Adb Command Prompt**.
2. Connect to the Waydroid instance (ensure your VM allows routing to the Waydroid IP):
   ```cmd
   adb connect <WAYDROID_IP>:5555
   ```
3. Allow the connection inside the Waydroid UI if prompted.

The Waydroid device should now appear in the standard Visual Studio "Start Debugging" dropdown.

### Disconnecting
When finished, it is good practice to disconnect:
```cmd
adb disconnect <WAYDROID_IP>:5555
```

---

## 6. VS Code Integration (Linux Host)

For developing with **Avalonia UI (.NET 9)** or **.NET MAUI (.NET 10)** natively on Linux, follow these setup steps. Note that different .NET versions may have strict requirements for specific JDK and Android Build Tools versions.

### 1. Install Microsoft .NET SDK (Official)
Do **not** use the Ubuntu repository versions (e.g., `dotnet-sdk-9.0` from apt), as they often lack proper Workload support. Install the official Microsoft .NET SDK.

```bash
# Example for Ubuntu (check microsoft.com for your specific distro instructions)
sudo apt-get update && \
  sudo apt-get install -y dotnet-sdk-9.0
```
*Note: If you are developing with .NET 10 (Preview), install that SDK as well.*

Install the Android workload:
```bash
dotnet workload install android
```

### 2. Install Java Development Kits (JDK)
You will likely need multiple JDK versions:
*   **.NET 9 (Avalonia iPlus):** Requires **OpenJDK 17**.
*   **.NET 10 (MAUI):** May require **OpenJDK 21**.

Install both to be safe:
```bash
sudo apt install openjdk-17-jdk openjdk-21-jdk
```

### 3. Install Android SDK & Tools
You can install the command-line tools via the package manager to avoid a full Android Studio installation.

```bash
sudo apt install sdkmanager
```

**Important:** System-installed SDKs (in `/usr/lib/android-sdk`) are root-owned. You may run into permission issues or version conflicts. It is often recommended to use a user-local SDK (e.g., `~/Android/Sdk`), but if you prefer the system setup, ensure you explicitly install the required versions.

Install the platforms and build tools for **both** frameworks:

```bash
# For .NET 9 (Avalonia iPlus) - STRICT REQUIREMENT:
sudo sdkmanager "platforms;android-35" "build-tools;35.0.0"

# For .NET 10 (MAUI) - Newer versions:
sudo sdkmanager "platforms;android-36" "build-tools;36.1.0"
```
**Important:** If you decide for a full [Android Studio](https://developer.android.com/studio/install?hl=en#linux) installation (e.g. if you need an emulator), you don't have to do these steps above because the installer and the Android Studio Application does these steps via UI.


### 4. Configure Environment Variables
VS Code requires environment variables to locate the Android SDK.

Add the following to your `~/.bashrc`:
```bash
export ANDROID_HOME=~/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
```

Apply the changes:
```bash
source ~/.bashrc
```

### 5. VS Code & Project Configuration (Critical)
VS Code often struggles when multiple SDK paths exist or when projects require different JDKs. Only perform these steps if you receive error messages during compilation:

**Step A: Configure VS Code (`.vscode/settings.json`)**
Create this file in your workspace root to stop VS Code from asking about the Android SDK path. Point it to your chosen SDK location (system or user-local).

```json
{
    // Disable auto-detection to prevent prompts
    "dotnet.autoConfigureAndroidSdk": false,
    
    // Explicitly set the path (USE ONE):
    // Option 1: System-installed (via apt install sdkmanager)
    "maui.android.sdkPaths": [ "/usr/lib/android-sdk" ], 
    
    // Option 2: User-local (if you manually installed command-line tools)
    // "maui.android.sdkPaths": [ "~/Android/Sdk" ]
}
```

**Step B - OPTIONAL: Configure Build Properties (`Directory.Build.props`)**
To ensure the correct JDK is used for the iPlus (Avalonia) project, edit the `Directory.Build.props` in the solution root to force JDK 17, while leaving other projects to use the default.

```xml
<PropertyGroup>
    <!-- Force .NET 9 projects to use JDK 17 -->
    <JavaSdkDirectory Condition="'$(TargetFramework)' == 'net9.0-android'">/usr/lib/jvm/java-17-openjdk-amd64</JavaSdkDirectory>
    
    <!-- Optional: Explicitly point to SDK if auto-detect fails -->
    <!-- <AndroidSdkDirectory>/usr/lib/android-sdk</AndroidSdkDirectory> -->
</PropertyGroup>
```

### 6. VS Code Extensions
1. Install the **Mono Debug** extension (`ms-vscode.mono-debug`) from the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=ms-vscode.mono-debug).
2. **IMPORTANT! Don't forget to install the Linux package.** The VS Code extension requires a basic Linux installation. Otherwise, the Mono debugger won't be able to connect to the process on the Android device via ADB!
3. ```bash
   sudo apt-get install mono-complete
   ```
4. Create or update the `tasks.json` and `launch.json` files in your project's `.vscode` folder.

> **Note:** Sample `launch.json` and `tasks.json` configurations are provided in the `Files/` subdirectory of this guide.

### 7. Connecting via ADB
1. In VS Code open the Terminal Window (bash).
2. Connect to the Waydroid instance (Waydroid IP):
   ```cmd
   adb connect <WAYDROID_IP>:5555
   ```
3. Allow the connection inside the Waydroid UI if prompted.
4. Unfortunately, VS Code doesn't show that the device is now reachable. Open "Run and Debug" (Ctrl+Shift+D) in the left-hand panel. Select the "Debug - Android" option (the name comes from launch.json) and start the build debug process.
