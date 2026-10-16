# iPlus NuGet Packaging

All `gip.*` projects from the `iPlus` and `iPlusMES` repositories are available as
NuGet packages (currently **pre-release `5.0.0-preview.1`**).

## Reference modes (Directory.Build.props)

| Mode | How | Default |
|------|-----|---------|
| **NuGet packages** | `-p:UseIPlusPackages=true` (or nothing) | ✅ default |
| Source (ProjectReferences) | `-p:UseProjectReferences=true` | |
| Compiled binaries | `-p:UseIPlusPackages=false` (uses `IPlusIncludeDir`) | |

```bash
# default: NuGet packages from the local feed (nuget.config)
dotnet build gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj

# compile against the iPlus source repos
dotnet build ... -p:UseProjectReferences=true

# use compiled binaries from iPlus/bin (IPlusIncludeDir)
dotnet build ... -p:UseIPlusPackages=false
```

## Local package feed

`nuget.config` in this folder adds two local sources:

- `../../iPlus/local-packages`
- `../../iPlusMES/local-packages`

They are filled by the pack scripts in each repo:

```bash
cd ../../iPlus      && ./build/pack-local.sh Debug          # all projects
cd ../iPlusMES      && ./build/pack-local.sh Debug          # all projects
./build/pack-local.sh Debug gip.core.datamodel              # single project
```

Packages are written to `<repo>/local-packages` as `nupkg` + `snupkg` (symbols).

## How it works

- **iPlus/build/iPlus.Package.props** – suite versions (`IPlusPackageVersion`,
  `IPlusMESPackageVersion`), repo root and the tooling exclude list.
- **iPlus/Directory.Build.targets** – marks every SDK-style library inside an
  iPlus source repo as packable (`PackageId` = project name, forced suite
  version, symbols, fallback license) and packs `DbScripts/` +
  `VBControlScripts/` as package content.
- **iPlus/build/IPlus.Package.Content.targets** – shipped as
  `buildTransitive/<PackageId>.targets` in every package; copies the packaged
  `DbScripts` and `VBControlScripts` into the consumer's output directory
  (same layout as the old `IPlusIncludeDir` copy).
- **iPlusMES** overrides `IPlusSourceRepoRoot` / `IPlusSuitePackageVersion` in
  its `Directory.Build.props` and imports the same targets.

## Important: NuGet cache & Avalonia fork mode

- Packages are built with **`UseAvaloniaFork=false`** so compiled type
  references bind to the split `iPlus.Xaml.Behaviors.*` / `iPlus.Avalonia.*`
  assemblies (a fork-built `gip.core.layoutengine.avui.dll` would bind to the
  fork's merged `Xaml.Behaviors.dll`, which does not exist in a NuGet
  deployment -> `FileNotFoundException` at startup).
- Because pack versions stay `5.0.0-preview.1` until published, **delete the
  cached `gip.*` packages** after repacking, otherwise restore reuses the old
  ones:
  ```bash
  rm -rf ../../packages/gip.*
  ```
- Packing overwrites `iPlus/bin` with package-mode binaries. Rebuild iPlus
  normally (fork mode) afterwards if you want to run the repo's own Avalonia
  client.

## Known gaps

- `MATRIX32.dll`, `MATRIX64.dll` and `matrix.ini` are native/licensed binaries
  that do not exist in the source repos. They are still copied from
  `$(IPlusIncludeDir)` when present. For pure NuGet consumers they need a
  separate native package (e.g. `iPlus.Native.Matrix`).
- Projects that cannot be built/packed on Linux (Windows-only tooling):
  `gip.core.scichart.avui`, `gip.ext.fluent.avui` (XamlCombine.exe),
  `gip.ext.opctoolbox`, `gip.core.tcClient`, `gip.core.tcShared` (WCF),
  `gip.iplus.client.avui.iOS`. Pack them on Windows.
- `gip.bso.tcStudio` is a legacy (non-SDK) project and is not packed.

## Publishing to nuget.org

Once the packages are verified, push with the suite version bumped
(e.g. `5.0.0-preview.2` in `iPlus/build/iPlus.Package.props`):

```bash
dotnet nuget push local-packages/*.nupkg --source https://api.nuget.org/v3/index.json
dotnet nuget push local-packages/*.snupkg --source https://api.nuget.org/v3/index.json
```
