# CH347 UART Viewer

A small Windows UART viewer/logger for WCH CH347 adapters and other serial COM ports.

It is intentionally simple: pick a port, choose serial settings, connect, watch incoming UART text, and keep a cleaned text log on disk.

## Features

- Detects Windows COM ports, including CH347 virtual COM ports.
- Defaults to a detected CH347 port when one is present.
- Supports common high-speed UART rates such as `1500000`, `2000000`, and `3000000`.
- Configurable baud, data bits, parity, stop bits, flow control, DTR, and RTS.
- Text and hex display modes.
- Cleaned text log capture to `logs\uart_YYYYMMDD_HHMMSS_COMx_baud.log`.
- Optional CR/backspace spinner cleanup for bootloader progress animations.
- Filter visible lines by substring.
- Search visible lines by substring with previous/next navigation.
- Single PowerShell/WinForms script; no build step required.

## Requirements

- Windows PowerShell 5.1 or newer.
- Windows Forms support, included with normal desktop Windows installs.
- For CH347 adapters, install the WCH virtual COM port driver if Windows does not expose the adapter as a COM port.

## Usage

Run:

```cmd
Launch-CH347UartViewer.cmd
```

Or run the script directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CH347UartViewer.ps1
```

Optional parameters:

```powershell
.\CH347UartViewer.ps1 -DefaultPort COM3 -DefaultBaud 1500000 -AutoConnect
.\CH347UartViewer.ps1 -LogDirectory C:\uart_logs
.\CH347UartViewer.ps1 -DefaultDtr -DefaultRts -DefaultHex
```

Only one application can normally open a COM port at a time. Close other terminals or loggers before connecting.
