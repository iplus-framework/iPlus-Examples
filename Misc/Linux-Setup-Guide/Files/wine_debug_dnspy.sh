#!/bin/bash
export WINEPREFIX=$HOME/.wine-dotnet48-64

# $1 might be /home/damir/... or D:\...
INPUT_PATH="$1"

# 1. Normalize paths using winepath to handle mixed slashes (from VS Code)
LINUX_FULL_PATH=$(winepath -u "$INPUT_PATH")
LINUX_EXE_DIR=$(dirname "$LINUX_FULL_PATH")
EXE_PATH=$(winepath -w "$INPUT_PATH")
EXE_NAME=$(basename "$LINUX_FULL_PATH")

# 3. Clear dnSpy session
DNSPY_CONFIG_DIR="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/dnSpy"
if [ -d "$DNSPY_CONFIG_DIR" ]; then
    rm -rf "$DNSPY_CONFIG_DIR"/*
fi

# 4. Find all gip DLLs
DLL_LIST=$(find "$LINUX_EXE_DIR" -maxdepth 1 -name "gip.*.dll" -exec winepath -w {} +)

# 5. Launch
wine "$EXE_PATH" &
sleep 2

DNSPY_BIN="/home/damir/SHARED/Devel/Tools/dnSpy/dnSpy-netframework/dnSpy.exe"
wine "$DNSPY_BIN" -pn "$EXE_NAME" "$EXE_PATH" $DLL_LIST
