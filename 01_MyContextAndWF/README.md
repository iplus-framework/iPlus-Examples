# Example: MyContext and Workflows (01_MyContextAndWF)

This example demonstrates the basic programming concepts of the **iPlus framework**:

- Adding your own database model (database-first) via `mycompany.package.datamodel`
- Creating business objects (BSOs) via `mycompany.bso.erp` and `mycompany.package.demo`
- Creating a process application / service components via `mycompany.package.proc`
- Using them in the iPlus client (WPF: `gip.iplus.client`, Avalonia UI: `gip.iplus.client.avui.Desktop`)

---

## Requirements

1. **.NET SDK** (see `DefaultNetCoreTargetFramework` in the projects; currently .NET 10)
2. **SQL Server** instance with the iPlus database restored (see the `Database/` folder of the iPlus repository)
3. One of the following iPlus framework sources (see *Reference modes* below):
   - Nothing at all — NuGet packages are used (default)
   - The [iPlus](https://github.com/iplus-framework/iPlus) (and optionally [iPlusMES](https://github.com/iplus-framework/iPlusMES)) repositories cloned **next to this repository**, so that relative paths like `..\..\..\iPlus` resolve
   - Precompiled iPlus assemblies copied into a folder

---

## Reference modes

How the iPlus assemblies are resolved is controlled by two MSBuild properties
(defined in `Directory.Build.props`). The three modes are mutually exclusive:

| Mode | Command | For whom |
|------|---------|----------|
| **NuGet packages** (default) | `dotnet build` | Most users — no iPlus clone needed |
| **Source / ProjectReferences** | `dotnet build -p:UseProjectReferences=true` | Users who cloned iPlus (+ iPlusMES) |
| **Compiled binaries** | `dotnet build -p:UseIPlusPackages=false` | Users with manually copied assemblies |

```bash
# 1) Default: NuGet packages (local feed via nuget.config, later nuget.org)
dotnet build gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj

# 2) Compile against the iPlus source repos (must be cloned as sibling folder)
dotnet build gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj -p:UseProjectReferences=true

# 3) Use compiled binaries from iPlus/bin (IPlusIncludeDir)
dotnet build gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj -p:UseIPlusPackages=false
```

Notes:

- **Mode 2** requires the repositories to be in a *common root directory*:

  ```
  <root>/
  ├── iPlus/                  <- github.com/iplus-framework/iPlus
  ├── iPlusMES/               <- optional
  └── iPlus-Examples/
      └── 01_MyContextAndWF/  <- this example
  ```

  When `UseProjectReferences=true`, the Avalonia fork is enabled automatically
  (`UseAvaloniaFork=true`) — do not mix this with package mode.

- **Mode 3** expects the assemblies in `..\..\..\iPlus\bin\$(Configuration)\...`
  (see `IPlusIncludeDir` in the `.csproj` files). If you keep them elsewhere,
  adjust the paths in the `.csproj` files.

- **WPF client on Linux** (`gip.iplus.client`): needs WINE, see the
  [Linux setup guide](../Misc/Linux-Setup-Guide). The Avalonia client
  (`gip.iplus.client.avui.Desktop`) builds and runs natively on Linux.

---

## Database

1. Unzip the database backup from the `Database/` folder and restore it on a SQL Server instance.
2. Adjust the connection string in `ConnectionStrings.config` of the client project you want to start.
3. Log in with `superuser` / `superuser`.

---

## Build & run

```bash
# Avalonia UI client (Windows, Linux, macOS, ...)
dotnet build gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj -c Debug
dotnet run --project gip.iplus.client.avui.Desktop

# WPF client (Windows, or Linux via WINE)
dotnet build gip.iplus.client/gip.iplus.client.csproj -c Debug
```

In VS Code, ready-made build tasks are available
(*Build Avalonia Desktop*, *Build Windows (wine)*, ...).

> **Tip:** After pulling a newer version, hold the **CTRL key** while clicking
> the login button so your local databases get updated.

---

## Project layout

| Project | Purpose |
|---------|---------|
| `mycompany.package.datamodel` | Your own database model (EF Core, database-first) |
| `mycompany.bso.erp` | Business objects using the database model |
| `mycompany.package.demo` | Demo component / BSO |
| `mycompany.package.proc` | Process application (server-side service components, workflows) |
| `gip.iplus.client` | WPF client (Windows / WINE) |
| `gip.iplus.client.avui.Desktop` | Avalonia UI client (cross-platform) |

Further documentation: [iPlus documentation](https://iplus-framework.com/en/documentation/Home/Schema/View/bce1702a-7637-4b98-83db-01a9d7a3a156).
