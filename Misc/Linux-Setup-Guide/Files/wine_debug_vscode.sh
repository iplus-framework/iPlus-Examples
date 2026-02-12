#!/bin/bash
export WINEPREFIX=$HOME/.wine-dotnet48-64
wine "C:\\users\\damir\\.vscode\\extensions\\ms-dotnettools.csharp-1.24.4-win32-x64\\.debugger\\vsdbg.exe" "$@"
