# Linux Development Environment Setup for .NET Developers

## Introduction

This guide describes a robust and flexible development environment setup for .NET developers transitioning from Windows to Linux. 

In the modern .NET ecosystem, while .NET 6+ and Avalonia UI allow for native Linux development, many developers still maintain legacy .NET Framework 4.8 (WPF/WinForms) applications. This creates a dilemma: stick with Windows and lose the benefits of a Linux dev environment, or switch to Linux and struggle with legacy support.

This setup offers the best of both worlds:
- **Native Performance:** Run modern .NET Core/Avalonia projects, VS Code, and tools directly on the Linux host.
- **Legacy Support:** Run a Windows 11 Virtual Machine (VM) for Visual Studio and legacy .NET Framework projects.
- **Integration:** Seamlessly run Windows apps (like SSMS or Visual Studio) via RDP "Seamless Mode" alongside Linux apps.
- **Isolation:** Use lightweight Linux System Containers (LXC) for VPN clients (FortiClient, SonicWall, etc.) to keep the host clean and avoid conflicts.
- **Flexibility:** Run SQL Server instances in Docker containers within a Linux container, facilitating easy version management.

We use **Incus** as the virtualization manager because it unifies the management of Virtual Machines (KVM/QEMU) and System Containers (LXC) under a single, powerful API and CLI.

## Advantages

- **Clean Host:** No more "DLL hell" or conflicting VPN network adapters on your main workstation.
- **Security:** Risky proprietary software and VPN clients run in isolated containers.
- **Resource Efficiency:** Linux containers have near-zero overhead compared to full VMs.
- **File Sharing:** A shared directory mount allows you to edit code on Linux and compile/debug on Windows without duplicating repositories.
- **Open Source Freedom:** Leverage the power of the Linux ecosystem while maintaining productivity.

## Table of Contents

1. [Prerequisites & Basic Tools](01-prerequisites.md) - Setup of Incus, basic utilities, and the Incus Web UI.
2. [Windows 11 VM Setup](02-windows-vm.md) - Installing Windows 11 in Incus, VirtIO drivers, and optimizations.
3. [Network Configuration](03-network-setup.md) - Bridging, NAT configuration, DNS resolution, and Firewall settings.
4. [Seamless RDP Integration](04-seamless-rdp.md) - Running Windows applications (VS, SSMS) as if they were native Linux windows.
5. [SQL Server Setup](05-sql-server.md) - Running SQL Server in Docker containers with persistent storage.
6. [VPN & Security](06-vpn-and-security.md) - Isolating VPN clients (OpenVPN, FortiClient, etc.) in containers.
7. [Developer Tools](07-developer-tools.md) - Git configuration, VS Code, and .NET SDK setup.
8. [Extra Utilities](08-extras.md) - Wine, Teams, Thunderbird.
9. [AI Server Setup](09-AI-Server.md) - Setting up a local AI server with Lemonade, ROCm, and GPU passthrough.

---

*This guide was motivated by the need for a stable, high-performance environment for developing the open-source **iplus-framework**, ensuring that proprietary client requirements (VPNs) do not interfere with the development stability.*
