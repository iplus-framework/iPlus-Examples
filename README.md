# iPlus Framework Example Projects

These example projects serve to explain the most important programming concepts of the *iplus framework*. You can find the [corresponding video][9] on our homepage.

---

## Learning Content

1. **Add your own database model or reuse an existing database** using the database-first approach that can be managed by the iplus runtime.  
   *Documentation:* [Database Model Documentation][1]

2. **Create software components (so-called business objects)** that use the database model so that you can deploy transaction-based applications.  
   *Documentation:* [Business Objects Documentation][2]

3. **Create a user interface for business objects** using the engineering environment.  
   *Documentation:* [User Interface Documentation][3]

4. **Exporting packages for distribution** to other users or transport to another iplus installation.  
   *Documentation:* [Exporting Packages Documentation][4], [Importing Packages Documentation][5]

5. **Creating server-side service components** that are either static instances or dynamic instances used as part of workflows.  
   *Documentation:* [Service Components Documentation][6]

6. **Create controls** to interact with these service components.

7. **Use these service components on the client side** without any network programming knowledge.

8. **Creating workflows**  
   *Documentation:* [Workflows Documentation][7]

---

## Download, Compilation, and Use

1. **A common directory** Make sure to clone this repository into the same root path as iplus-framework. So that our repositories are all in a common directory, so that the specified relative paths match.

   ```
   <root>/
   ├── iPlus/                  <- github.com/iplus-framework/iPlus
   ├── iPlusMES/               <- optional
   └── iPlus-Examples/
   ```

2. **Choose a reference mode** How the iPlus assemblies are resolved is controlled per example via `Directory.Build.props`. The three modes are mutually exclusive:

   | Mode | Command | For whom |
   |------|---------|----------|
   | **NuGet packages** (default) | `dotnet build` | No iPlus clone needed |
   | **Source (ProjectReferences)** | `dotnet build -p:UseProjectReferences=true` | iPlus/iPlusMES cloned as sibling folder |
   | **Compiled binaries** | `dotnet build -p:UseIPlusPackages=false` | Assemblies copied manually (paths in the `.csproj` files) |

   ```bash
   # default: NuGet packages
   dotnet build 01_MyContextAndWF/gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj

   # compile against the iPlus source repos
   dotnet build 01_MyContextAndWF/gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj -p:UseProjectReferences=true

   # use compiled binaries from iPlus/bin
   dotnet build 01_MyContextAndWF/gip.iplus.client.avui.Desktop/gip.iplus.client.avui.Desktop.csproj -p:UseIPlusPackages=false
   ```

   Previously, compiling the release version of iplus-framework was mandatory because the examples used the compiled dll's from the `bin` directory. With the NuGet package mode this is no longer necessary — just build the example.

3. **Unzip the database file** from the database folder and restore the database on a SQL Server instance.

4. **Adjust the connection string** in the client project (`ConnectionStrings.config`) and set it as the startup project.

5. **Compile the example and start the application.** Login with "superuser":"superuser".

   > **Tip:** After pulling a newer version, hold down the **CTRL key** while clicking the login button so that your local databases are updated. Otherwise, the application will not be able to start.

---

## VS Code on Linux
[Read this Guide](./Misc/Linux-Setup-Guide)

## Footnotes

[1]: https://iplus-framework.com/en/documentation/Read/Index/View/6a220db6-a767-40bb-bf95-395e4a289881?chapterID=55619434-4ba5-4f48-8692-439b6f5f3343
[2]: https://iplus-framework.com/en/documentation/Read/Index/View/6a220db6-a767-40bb-bf95-395e4a289881?chapterID=3bdf516c-3c64-449d-a62e-74e6ce1fa956
[3]: https://iplus-framework.com/en/documentation/Read/Index/View/6a220db6-a767-40bb-bf95-395e4a289881?chapterID=f209b7e4-8438-4aeb-bb6a-60e6fec0394c
[4]: https://iplus-framework.com/en/documentation/Read/Index/View/641612af-c7d7-433a-b804-e2a55c17c768
[5]: https://iplus-framework.com/en/documentation/Read/Index/View/7355fbf6-19c7-486d-8769-968cbf83d2e2
[6]: https://iplus-framework.com/en/documentation/Read/Index/View/6a220db6-a767-40bb-bf95-395e4a289881?chapterID=bc346f21-e380-4da1-8476-4bc4850fe051
[7]: https://iplus-framework.com/en/documentation/Read/Index/View/19c44981-6318-4430-8a38-59eb37251156?workspaceSchemaID=5a70a086-3f63-4ce9-8e3c-620d5d1e1884
[8]: https://github.com/iplus-framework/iPlus
[9]: https://iplus-framework.com/en/Home/Index/View?section=F%C3%BCr%20Entwickler#b96f0ecd-0f0a-4295-993a-37de35ab59e1
