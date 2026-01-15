# Windows 11 VM Setup

This section covers setting up a Windows 11 Virtual Machine (VM) inside Incus. This VM is essential for running Legacy .NET Framework applications and Visual Studio 2022.

## 1. Preparation: Repacking the Windows ISO

To install Windows 11 automatically or with specific drivers (VirtIO), it is recommended to "repack" the official ISO using `distrobuilder`.

Ref: [Incus Windows 11 Guide](https://discussion.scottibyte.com/t/windows-11-incus-virtual-machine/362)

1.  **Install dependencies:**
    ```bash
    sudo apt install -y golang-go gcc debootstrap rsync gpg squashfs-tools git make build-essential libwin-hivex-perl wimtools genisoimage
    ```

2.  **Build `distrobuilder`:**
    ```bash
    mkdir -p $HOME/install/go/src/github.com/lxc/
    cd $HOME/install/go/src/github.com/lxc/
    git clone https://github.com/lxc/distrobuilder
    cd ./distrobuilder
    make
    ```

3.  **Repack the ISO:**
    *Note: Replace paths with your actual ISO location.*
    ```bash
    sudo apt install -y libguestfs-tools wimtools rsync
    sudo $HOME/go/bin/distrobuilder repack-windows --windows-arch=amd64 /home/damir/Downloads/Win11_25H2_German_x64.iso /home/damir/Downloads/Win11_25H2_German_x64_repacked.iso
    ```

4.  **Install VM Viewer tools:**
    Needed for Secure Boot emulation (OVMF) and viewing the console.
    ```bash
    sudo apt install ovmf virt-viewer
    ```

## 2. Creating the Virtual Machine

Create an empty VM and configure it before installation.

```bash
# Create empty VM
sudo incus init gipDLVmWin11 --empty --vm

# Capabilities config
sudo incus config device override gipDLVmWin11 root size=100GiB
sudo incus config set gipDLVmWin11 limits.cpu=12 limits.memory=24GiB
sudo incus config device add gipDLVmWin11 vtpm tpm path=/dev/tpm0

# Attach Installation Media
sudo incus config device add gipDLVmWin11 install disk source=/home/damir/Downloads/Win11_25H2_German_x64_repacked.iso boot.priority=10

# Audio/Display tweaks (SPICE)
sudo incus config set gipDLVmWin11 raw.qemu -- "-device intel-hda -device hda-duplex -audio spice"

# Start the VM with VGA console
sudo incus start gipDLVmWin11 --console=vga
```

> **Note on Installation:** During the Windows installation, the VM will reboot. You will be disconnected from the console. Reconnect using:
> ```bash
> sudo incus console gipDLVmWin11 --type=vga
> ```

### Product Key & BIOS Passthrough (Optional but Recommended)

If you have a Windows license tied to your hardware BIOS, you need to pass this information through to the VM *before the first boot*.

1.  **Read Host BIOS Info:**
    ```bash
    sudo dmidecode -t 0
    sudo dmidecode -t 1
    ```
2.  **Extract MSDM Table:**
    ```bash
    sudo cat /sys/firmware/acpi/tables/MSDM > /var/lib/incus/msdm.bin
    ```
3.  **Edit VM Configuration:**
    Add `raw.apparmor` and `raw.qemu` parameters to the VM config. The UUIDs in `smbios` must match the `volatile.uuid` of the VM.

    Example `raw.qemu` addition (needs to be customized with your UUIDs/Serials):
    ```yaml
    raw.apparmor: "/var/lib/incus/msdm.bin r,"
    raw.qemu: '-device intel-hda -device hda-duplex -audio spice -acpitable file=/var/lib/incus/msdm.bin -smbios type=0,vendor=HP ... -smbios type=1,uuid=YOUR-UUID ...'
    ```

## 3. Post-Installation Setup

### Cleanup

Remove the installation ISO:
```bash
sudo incus config device remove gipDLVmWin11 install
```

### Install Guest Tools & Drivers

1.  **VirtIO Guest Tools:**
    Download `virtio-win-guest-tools.exe` inside the VM and install it.
    [VirtIO Releases](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md)   

    Alternatively, an installation medium can be mounted instead of the executable:
    ```bash
    sudo incus config device add gipDLVmWin11 install disk source=/home/damir/Downloads/virtio-win-0.1.285.iso
    ```

2.  **WinFsp (File System Proxy):**
    Install [WinFsp 2025](https://github.com/winfsp/winfsp/releases/) or later. This is required for shared folders without Samba.
    *Action:* Set the **VirtIO-FS Service** to "Automatic" and start it in Windows Services.

3.  **Config Adjustments:**
    Add `image.os: Windows` to the VM config manually if not present, to ensure VirtIO services start correctly.

### Shared Folders

This setup allows you to mount a Linux directory into Windows as a native drive letter.

1.  **Add Device in Incus:**
    ```bash
    sudo incus config device add gipDLVmWin11 SHARED disk source=/home/damir/SHARED path=SHARED
    ```
2.  **Mount in Windows:**
    By default, this appears as drive `Z:`.
    To change it (e.g., to `D:`), edit the Registry in the VM:
    *   Key: `HKEY_LOCAL_MACHINE\SOFTWARE\VirtIO-FS`
    *   Value: `MountPoint` (String) -> `D:`
3.  **Reboot VM.**

### Additional data drive for Windows

Software compilation on virtio-fs is often slow because it involves a high volume of small file metadata operations (open, read, close), which create overhead between the host and guest. Especially if you don't want to compile with Visual Studio. To avoid this bottleneck create a separate storage volume for Windows which is much faster. The problem here is that you theoretically can use the same virtual in the host but Using a virtual disk (like a .qcow2 or raw image) for both the host and a running VM at the same time is highly dangerous and can lead to immediate file system corruption. Therefore the better (more performant) approach is that you have redundant folders of the git repositories (host and vm) with the disadvantage of losing HDD space.

1.  **Add a block volume**
    e.g. "gipDLVmWin11_data" from the pool "default (btrfs)"

    ```bash
    sudo incus storage volume create default gipDLVmWin11_data --type=block
    sudo incus storage volume set default gipDLVmWin11_data size=100GiB
    ```
2. **Attach Volume to VM**
     Add the new volume as a disk device to your Windows VM
    
    ```bash
    sudo incus config device add gipDLVmWin11 data disk source=gipDLVmWin11_data pool=default
    ```
3. **Add drive in VM**
    Start the VM and open diskmgmt.msc in Windows to attach as GPT and format this Disk.

### Combine Shared folders and data drive into a common Path
If applications in the VM need access to files that you have shared as a mounted separate drive in Linux using virtio-fs, but require the path located in the additional data drive (separate storage volume), then use symbolic links in Windows: https://learn.microsoft.com/de-de/windows-server/administration/windows-commands/mklink 

### BACKUP
Read [Incus Backup](https://linuxcontainers.org/incus/docs/main/howto/storage_backup_volume/)

## Useful Commands

```bash
# Start/Stop without console
sudo incus start gipDLVmWin11
sudo incus stop gipDLVmWin11
```
