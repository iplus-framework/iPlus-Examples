using System.Runtime.Versioning;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Browser;
using gip.iplus.client.avui;

internal sealed partial class Program
{
    static Program()
    {
        // ==================================================================
        // MULTIPLE EF CONTEXTS IN THE BROWSER (no ConnectionStrings.config!)
        //
        // The example app uses TWO databases on the SAME SQL server:
        //   - iPlusV5_Entities   -> iPlusExampleV5  (iPlus framework runtime)
        //   - ExampleV5_Entities -> ExampleV5       (application tables only)
        //
        // The SQL Tunnel relay is a BLIND TCP PROXY to ONE server: the initial
        // catalog travels inside the TDS login packet, so ONE tunnel serves any
        // number of contexts. In the browser there is no ConnectionStrings.config,
        // so the login flow DERIVES each additional context's connection string
        // from the default container — and without an override it would inherit
        // the default's initial catalog (iPlusExampleV5). The "Name|Catalog"
        // syntax fixes that:
        //
        //   "ExampleV5_Entities|ExampleV5"  ->  initial catalog=ExampleV5
        //
        // (On the desktop this registration is unnecessary: the
        // ConnectionStrings.config next to the exe already carries the correct
        // catalog per context and is rewritten in place by the login flow.)
        // ==================================================================
        gip.iplus.client.avui.LoginView.AdditionalConnectionContainerNames.Add(
            "ExampleV5_Entities|ExampleV5");
    }

    private static Task Main(string[] args) => BuildAvaloniaApp()
            .WithInterFont()
            .StartBrowserAppAsync("out");

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>();
}
