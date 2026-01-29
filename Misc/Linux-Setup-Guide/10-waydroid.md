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

For developing with **Avalonia UI** or .NET Android natively on Linux, follow these setup steps.

### 1. Install Java Development Kit (JDK)
```bash
sudo apt install default-jre
sudo apt install openjdk-21-jdk
```
Verify the installation:
```bash
java -version
```

### 2. Install Android Command Line Tools
Install the command-line tools (no need for the full Android Studio):

```bash
sudo apt install sdkmanager
# As of 2026, you may need a specific installer package:
# sudo apt install google-android-cmdline-tools-13.0-installer
```

### 3. Install SDK Platforms and Build Tools
Identify the required Android API levels from your project's `.csproj` file (look for `<SupportedOSPlatformVersion>`).

Search for available packages:
```bash
sdkmanager --list
```

Install the required platforms and build tools (quoting is required to prevent shell expansion):
```bash
sudo sdkmanager "platforms;android-21"
sudo sdkmanager "platforms;android-35"
sudo sdkmanager "build-tools;36.1.0"
```

### 4. Configure Environment Variables
VS Code requires environment variables to locate the Android SDK.

Add the following to your `~/.bashrc`:
```bash
export ANDROID_HOME=/usr/lib/android-sdk/
export PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools
```

Apply the changes:
```bash
source ~/.bashrc
```

### 5. VS Code Configuration
1. Install the **Mono Debug** extension (`ms-vscode.mono-debug`) from the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=ms-vscode.mono-debug).
2. **IMPORTANT! Don't forget to install the Linux package.** The VS Code extension requires a basic Linux installation. Otherwise, the Mono debugger won't be able to connect to the process on the Android device via ADB!
3. ```bash
   sudo apt-get install mono-complete
   ```
4. Create or update the `tasks.json` and `launch.json` files in your project's `.vscode` folder.

> **Note:** Sample `launch.json` and `tasks.json` configurations are provided in the `Files/` subdirectory of this guide.
