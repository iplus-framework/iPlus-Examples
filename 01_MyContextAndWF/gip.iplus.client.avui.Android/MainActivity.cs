using Android.App;
using Android.Content.PM;
using Android.OS;
using Android.Views;
using Avalonia;
using Avalonia.Android;
using Avalonia.Controls;

namespace gip.iplus.client.avui.Android;

[Activity(
    Label = "gip.iplus.client.avui.Android",
    Theme = "@style/MyTheme.NoActionBar",
    Icon = "@drawable/icon",
    MainLauncher = true,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.UiMode,
    WindowSoftInputMode = SoftInput.AdjustResize)]
public class MainActivity : AvaloniaMainActivity
{
    // NOTE: unlike the older MES Android client, NO connection-string plumbing is
    // needed here. The login flow (gip.iplus.client.avui LoginView) builds the
    // connection strings from the settings grid and applies the SQL Tunnel to every
    // context registered in LoginView.AdditionalConnectionContainerNames (see
    // Application.cs for the "Name|Catalog" registration).

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        BackRequested += MainActivity_BackRequested;
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        BackRequested -= MainActivity_BackRequested;
    }

    private void MainActivity_BackRequested(object? sender, AndroidBackRequestedEventArgs e)
    {
        e.Handled = true;

        if (this.Content != null && this.Content is UserControl)
        {
            UserControl rootControl = (UserControl)this.Content;
            MainSingleView? mainSingleView = rootControl.Content as MainSingleView;

            if (mainSingleView != null)
            {
                if (mainSingleView.CanClose)
                {
                    FinishAffinity();
                    Java.Lang.JavaSystem.Exit(0);
                    return;
                }

                mainSingleView.BackButton_Click(sender, new Avalonia.Interactivity.RoutedEventArgs());
            }
        }
    }
}
