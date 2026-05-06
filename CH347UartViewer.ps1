param(
    [string]$DefaultPort = "",
    [int]$DefaultBaud = 115200,
    [string]$LogDirectory = "",
    [switch]$DefaultDtr,
    [switch]$DefaultRts,
    [switch]$DefaultHex,
    [switch]$AutoConnect
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Serial = $null
$script:LogStream = $null
$script:LogPath = $null
$script:ByteCount = 0L
$script:DisplayDecoder = New-Object System.Text.UTF8Encoding($false, $false)
$script:MaxDisplayChars = 1048576
$script:PollTimer = $null
$script:DisplayLines = New-Object System.Collections.Generic.List[string]
$script:DisplayCharCount = 0
$script:PendingLine = ""
$script:RenderedLineOffsets = @()
$script:RenderedLineIndexes = @()
$script:CurrentSearchRenderedIndex = -1
$script:LastSearchText = ""

function Get-PortInventory {
    $ports = @{}

    try {
        foreach ($portName in [System.IO.Ports.SerialPort]::GetPortNames()) {
            $ports[$portName] = [ordered]@{
                Port = $portName
                Name = $portName
                IsCh347 = $false
            }
        }
    } catch {
    }

    try {
        $serialMap = Get-ItemProperty -Path "HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM" -ErrorAction Stop
        foreach ($property in $serialMap.PSObject.Properties) {
            if ($property.Value -match "^COM\d+$" -and -not $ports.ContainsKey($property.Value)) {
                $ports[$property.Value] = [ordered]@{
                    Port = [string]$property.Value
                    Name = [string]$property.Value
                    IsCh347 = $false
                }
            }
        }
    } catch {
    }

    try {
        $devices = Get-PnpDevice -Class Ports -PresentOnly -ErrorAction Stop
        foreach ($device in $devices) {
            if ($device.FriendlyName -match "(COM\d+)") {
                $portName = $matches[1]
                if (-not $ports.ContainsKey($portName)) {
                    $ports[$portName] = [ordered]@{
                        Port = $portName
                        Name = $device.FriendlyName
                        IsCh347 = ($device.FriendlyName -match "CH347")
                    }
                } else {
                    $ports[$portName].Name = $device.FriendlyName
                    $ports[$portName].IsCh347 = ($ports[$portName].IsCh347 -or ($device.FriendlyName -match "CH347"))
                }
            }
        }
    } catch {
    }

    if ($ports.Count -eq 0 -and $DefaultPort) {
        $ports[$DefaultPort] = [ordered]@{
            Port = $DefaultPort
            Name = $DefaultPort
            IsCh347 = ($DefaultPort -match "CH347")
        }
    }

    $ports.Values | ForEach-Object {
        $label = $_.Name
        if ($label -notmatch [regex]::Escape($_.Port)) {
            $label = "{0} - {1}" -f $_.Port, $label
        }
        [pscustomobject]@{
            Port = $_.Port
            Label = $label
            IsCh347 = [bool]$_.IsCh347
            SortKey = if ($_.Port -match "^COM(\d+)$") { [int]$matches[1] } else { 9999 }
        }
    } | Sort-Object SortKey, Label
}

function Get-SelectedPortName {
    $value = $portBox.Text.Trim()
    if ($value -match "^(COM\d+)") {
        return $matches[1]
    }
    if ($value -match "(COM\d+)") {
        return $matches[1]
    }
    return $value
}

function Get-DefaultLogPath {
    param(
        [string]$Port,
        [int]$Baud
    )

    $logDir = $LogDirectory
    if (-not $logDir) {
        $logDir = Join-Path $PSScriptRoot "logs"
    }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Join-Path $logDir ("uart_{0}_{1}_{2}.log" -f $stamp, $Port, $Baud)
}

function Format-BytesForDisplay {
    param([byte[]]$Bytes)

    if ($hexCheck.Checked) {
        return ([System.BitConverter]::ToString($Bytes).Replace("-", " ") + " ")
    }

    $text = $script:DisplayDecoder.GetString($Bytes)
    $text -replace "`0", ""
}

function Get-FilterText {
    if ($filterBox) {
        return $filterBox.Text.Trim()
    }
    ""
}

function Test-LineMatchesFilter {
    param([string]$Line)

    $filter = Get-FilterText
    if (-not $filter) {
        return $true
    }

    return ($Line.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-SuppressLine {
    param([string]$Line)

    if (-not ($cleanSpinnerCheck -and $cleanSpinnerCheck.Checked)) {
        return $false
    }

    $trimmed = $Line.Trim()
    if (-not $trimmed) {
        return $true
    }

    if ($trimmed.Length -le 12 -and $trimmed -match '^[\|/\\\-\.\[\]\(\) ]+$') {
        return $true
    }

    return $false
}

function Trim-DisplayLines {
    while ($script:DisplayCharCount -gt $script:MaxDisplayChars -and $script:DisplayLines.Count -gt 0) {
        $script:DisplayCharCount -= ($script:DisplayLines[0].Length + 2)
        $script:DisplayLines.RemoveAt(0)
    }
}

function Write-LogText {
    param([string]$Text)

    if (-not $script:LogStream) {
        return
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $script:LogStream.Write($bytes, 0, $bytes.Length)
}

function Trim-TerminalText {
    if ($terminal.TextLength -le $script:MaxDisplayChars) {
        return
    }

    $remove = $terminal.TextLength - $script:MaxDisplayChars
    $terminal.Select(0, $remove)
    $terminal.SelectedText = ""
}

function Render-Terminal {
    param([switch]$KeepSelection)

    if (-not $terminal) {
        return
    }

    $selectionStart = $terminal.SelectionStart
    $selectionLength = $terminal.SelectionLength
    $wasAtEnd = ($selectionStart -ge [Math]::Max(0, $terminal.TextLength - 1))

    $offsets = New-Object System.Collections.Generic.List[int]
    $indexes = New-Object System.Collections.Generic.List[int]
    $builder = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $script:DisplayLines.Count; $i++) {
        $line = $script:DisplayLines[$i]
        if (Test-LineMatchesFilter -Line $line) {
            [void]$offsets.Add($builder.Length)
            [void]$indexes.Add($i)
            [void]$builder.AppendLine($line)
        }
    }

    $script:RenderedLineOffsets = $offsets.ToArray()
    $script:RenderedLineIndexes = $indexes.ToArray()
    $terminal.Text = $builder.ToString()

    if ($KeepSelection -and $selectionStart -lt $terminal.TextLength) {
        $terminal.SelectionStart = $selectionStart
        $terminal.SelectionLength = [Math]::Min($selectionLength, $terminal.TextLength - $selectionStart)
    } elseif ($autoscrollCheck.Checked -or $wasAtEnd) {
        $terminal.SelectionStart = $terminal.TextLength
        $terminal.ScrollToCaret()
    }

    Update-SearchStatus
}

function Add-DisplayLine {
    param(
        [string]$Line,
        [switch]$SkipLog
    )

    if (Test-SuppressLine -Line $Line) {
        return
    }

    [void]$script:DisplayLines.Add($Line)
    $script:DisplayCharCount += ($Line.Length + 2)
    Trim-DisplayLines

    if (-not $SkipLog) {
        Write-LogText ($Line + "`r`n")
    }
}

function Add-Line {
    param([string]$Message)

    Add-DisplayLine -Line ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -SkipLog
    Render-Terminal
}

function Add-ReceivedText {
    param([string]$Text)

    if (-not $Text) {
        return
    }

    $linesAdded = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]

        if ($char -eq [char]0) {
            continue
        }

        if ($char -eq "`b") {
            if ($script:PendingLine.Length -gt 0) {
                $script:PendingLine = $script:PendingLine.Substring(0, $script:PendingLine.Length - 1)
            }
            continue
        }

        if ($char -eq "`r") {
            if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "`n") {
                Add-DisplayLine -Line $script:PendingLine
                $script:PendingLine = ""
                $linesAdded++
                $i++
            } elseif ($cleanSpinnerCheck.Checked) {
                if (-not (Test-SuppressLine -Line $script:PendingLine)) {
                    Add-DisplayLine -Line $script:PendingLine
                    $linesAdded++
                }
                $script:PendingLine = ""
            } else {
                Add-DisplayLine -Line $script:PendingLine
                $script:PendingLine = ""
                $linesAdded++
            }
            continue
        }

        if ($char -eq "`n") {
            Add-DisplayLine -Line $script:PendingLine
            $script:PendingLine = ""
            $linesAdded++
            continue
        }

        if ([char]::IsControl($char) -and $char -ne "`t") {
            continue
        }

        $script:PendingLine += $char
    }

    if ($linesAdded -gt 0) {
        Render-Terminal
    }
}

function Flush-PendingLine {
    if ($script:PendingLine.Length -gt 0) {
        Add-DisplayLine -Line $script:PendingLine
        $script:PendingLine = ""
        Render-Terminal
    }
}

function Clear-TerminalBuffer {
    $script:DisplayLines.Clear()
    $script:DisplayCharCount = 0
    $script:PendingLine = ""
    $script:RenderedLineOffsets = @()
    $script:RenderedLineIndexes = @()
    $script:CurrentSearchRenderedIndex = -1
    $terminal.Clear()
    Update-SearchStatus
}

function Update-SearchStatus {
    if (-not $searchStatusLabel) {
        return
    }

    $needle = $searchBox.Text
    if (-not $needle) {
        $searchStatusLabel.Text = ""
        return
    }

    $count = 0
    foreach ($index in $script:RenderedLineIndexes) {
        if ($script:DisplayLines[$index].IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $count++
        }
    }

    if ($count -eq 0) {
        $searchStatusLabel.Text = "0 matches"
    } elseif ($script:CurrentSearchRenderedIndex -ge 0) {
        $ordinal = 0
        for ($i = 0; $i -lt $script:CurrentSearchRenderedIndex; $i++) {
            $lineIndex = $script:RenderedLineIndexes[$i]
            if ($script:DisplayLines[$lineIndex].IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $ordinal++
            }
        }
        $searchStatusLabel.Text = "{0} of {1}" -f ($ordinal + 1), $count
    } else {
        $searchStatusLabel.Text = "{0} matches" -f $count
    }
}

function Find-SearchText {
    param([int]$Direction)

    $needle = $searchBox.Text
    if (-not $needle) {
        Update-SearchStatus
        return
    }

    if ($script:LastSearchText -ne $needle) {
        $script:CurrentSearchRenderedIndex = -1
        $script:LastSearchText = $needle
    }

    if ($script:RenderedLineIndexes.Count -eq 0) {
        Render-Terminal -KeepSelection
    }

    $count = $script:RenderedLineIndexes.Count
    if ($count -eq 0) {
        Update-SearchStatus
        return
    }

    if ($script:CurrentSearchRenderedIndex -lt 0) {
        $start = if ($Direction -ge 0) { 0 } else { $count - 1 }
    } else {
        $start = ($script:CurrentSearchRenderedIndex + $Direction + $count) % $count
    }

    for ($attempt = 0; $attempt -lt $count; $attempt++) {
        $renderedIndex = ($start + ($attempt * $Direction) + $count) % $count
        $lineIndex = $script:RenderedLineIndexes[$renderedIndex]
        $line = $script:DisplayLines[$lineIndex]
        $matchOffset = $line.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase)
        if ($matchOffset -ge 0) {
            $script:CurrentSearchRenderedIndex = $renderedIndex
            $selectionStart = $script:RenderedLineOffsets[$renderedIndex] + $matchOffset
            $terminal.Focus()
            $terminal.SelectionStart = $selectionStart
            $terminal.SelectionLength = $needle.Length
            $terminal.ScrollToCaret()
            Update-SearchStatus
            return
        }
    }

    $script:CurrentSearchRenderedIndex = -1
    Update-SearchStatus
}

function Update-Status {
    if ($script:Serial -and $script:Serial.IsOpen) {
        $statusLabel.Text = "Open {0} @ {1}  |  {2:n0} bytes  |  {3}" -f $script:Serial.PortName, $script:Serial.BaudRate, $script:ByteCount, $script:LogPath
    } else {
        $statusLabel.Text = "Closed  |  Select serial settings and connect"
    }
}

function Refresh-Ports {
    $selectedPort = Get-SelectedPortName
    $inventory = @(Get-PortInventory)

    $portBox.Items.Clear()
    foreach ($item in $inventory) {
        [void]$portBox.Items.Add($item.Label)
    }

    $preferred = $DefaultPort
    if (-not $preferred) {
        $ch347 = $inventory | Where-Object { $_.IsCh347 } | Select-Object -First 1
        if ($ch347) {
            $preferred = $ch347.Port
        }
    }
    if (-not $preferred -and $selectedPort) {
        $preferred = $selectedPort
    }

    $chosen = $null
    if ($preferred) {
        $chosen = $inventory | Where-Object { $_.Port -eq $preferred } | Select-Object -First 1
    }

    if ($chosen) {
        $portBox.SelectedItem = $chosen.Label
    } elseif ($portBox.Items.Count -gt 0) {
        $portBox.SelectedIndex = 0
    } elseif ($DefaultPort) {
        $portBox.Text = $DefaultPort
    }
}

function Get-SerialSettings {
    $baud = 0
    if (-not [int]::TryParse($baudBox.Text.Trim(), [ref]$baud)) {
        throw "Baud rate must be a number."
    }

    $dataBits = 8
    if (-not [int]::TryParse($dataBitsBox.Text.Trim(), [ref]$dataBits)) {
        throw "Data bits must be a number."
    }

    [pscustomobject]@{
        PortName = Get-SelectedPortName
        BaudRate = $baud
        DataBits = $dataBits
        Parity = [System.Enum]::Parse([System.IO.Ports.Parity], $parityBox.Text)
        StopBits = [System.Enum]::Parse([System.IO.Ports.StopBits], $stopBitsBox.Text)
        Handshake = [System.Enum]::Parse([System.IO.Ports.Handshake], $handshakeBox.Text)
    }
}

function Connect-Uart {
    if ($script:Serial -and $script:Serial.IsOpen) {
        return
    }

    try {
        $settings = Get-SerialSettings
        if (-not $settings.PortName) {
            throw "Select a COM port first."
        }

        $script:LogPath = Get-DefaultLogPath -Port $settings.PortName -Baud $settings.BaudRate
        $script:LogStream = [System.IO.File]::Open($script:LogPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

        $script:Serial = New-Object System.IO.Ports.SerialPort $settings.PortName, $settings.BaudRate, $settings.Parity, $settings.DataBits, $settings.StopBits
        $script:Serial.Handshake = $settings.Handshake
        $script:Serial.ReadTimeout = 50
        $script:Serial.WriteTimeout = 500
        $script:Serial.ReadBufferSize = 1048576
        $script:Serial.DtrEnable = $dtrCheck.Checked
        $script:Serial.RtsEnable = $rtsCheck.Checked
        $script:Serial.Open()

        $script:ByteCount = 0L
        $connectButton.Text = "Disconnect"
        foreach ($control in @($portBox, $baudBox, $dataBitsBox, $parityBox, $stopBitsBox, $handshakeBox, $dtrCheck, $rtsCheck)) {
            $control.Enabled = $false
        }
        Add-Line ("Connected to {0} at {1}. Log: {2}" -f $settings.PortName, $settings.BaudRate, $script:LogPath)
    } catch {
        if ($script:LogStream) {
            $script:LogStream.Dispose()
            $script:LogStream = $null
        }
        if ($script:Serial) {
            try { $script:Serial.Dispose() } catch { }
            $script:Serial = $null
        }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Could not open UART") | Out-Null
    }

    Update-Status
}

function Disconnect-Uart {
    Flush-PendingLine

    if ($script:Serial) {
        try {
            if ($script:Serial.IsOpen) {
                $script:Serial.Close()
            }
        } catch {
        }
        try { $script:Serial.Dispose() } catch { }
        $script:Serial = $null
    }

    if ($script:LogStream) {
        try { $script:LogStream.Flush() } catch { }
        try { $script:LogStream.Dispose() } catch { }
        $script:LogStream = $null
    }

    $connectButton.Text = "Connect"
    foreach ($control in @($portBox, $baudBox, $dataBitsBox, $parityBox, $stopBitsBox, $handshakeBox, $dtrCheck, $rtsCheck)) {
        $control.Enabled = $true
    }
    Add-Line "Disconnected."
    Update-Status
}

function Poll-Uart {
    if (-not ($script:Serial -and $script:Serial.IsOpen)) {
        return
    }

    try {
        $available = $script:Serial.BytesToRead
        $readThisTick = 0

        while ($available -gt 0 -and $readThisTick -lt 262144) {
            $chunkSize = [Math]::Min($available, 8192)
            $buffer = New-Object byte[] $chunkSize
            $read = $script:Serial.Read($buffer, 0, $buffer.Length)

            if ($read -gt 0) {
                if ($read -ne $buffer.Length) {
                    $actual = New-Object byte[] $read
                    [Array]::Copy($buffer, $actual, $read)
                    $buffer = $actual
                }

                $script:ByteCount += $read
                $readThisTick += $read

                if ($hexCheck.Checked) {
                    $script:LogStream.Write($buffer, 0, $read)
                    $terminal.AppendText((Format-BytesForDisplay -Bytes $buffer))
                    Trim-TerminalText
                } else {
                    Add-ReceivedText -Text (Format-BytesForDisplay -Bytes $buffer)
                }

                $script:LogStream.Flush()
            }

            $available = $script:Serial.BytesToRead
        }

        if ($readThisTick -gt 0 -and $autoscrollCheck.Checked) {
            $terminal.SelectionStart = $terminal.TextLength
            $terminal.ScrollToCaret()
        }
    } catch {
        Add-Line ("UART read error: {0}" -f $_.Exception.Message)
        Disconnect-Uart
    }

    Update-Status
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "CH347 UART Viewer"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1280, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 520)

$topPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$topPanel.Height = 112
$topPanel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)
$topPanel.WrapContents = $true
$topPanel.AutoScroll = $true
$form.Controls.Add($topPanel)

$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = "Port"
$portLabel.AutoSize = $true
$portLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
$topPanel.Controls.Add($portLabel)

$portBox = New-Object System.Windows.Forms.ComboBox
$portBox.Width = 265
$portBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$topPanel.Controls.Add($portBox)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Width = 76
$refreshButton.Add_Click({ Refresh-Ports })
$topPanel.Controls.Add($refreshButton)

$baudLabel = New-Object System.Windows.Forms.Label
$baudLabel.Text = "Baud"
$baudLabel.AutoSize = $true
$baudLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($baudLabel)

$baudBox = New-Object System.Windows.Forms.ComboBox
$baudBox.Width = 108
$baudBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
foreach ($rate in @(1500000, 115200, 921600, 1000000, 2000000, 3000000, 57600, 38400, 19200, 9600)) {
    [void]$baudBox.Items.Add([string]$rate)
}
$baudBox.Text = [string]$DefaultBaud
$topPanel.Controls.Add($baudBox)

$dataBitsLabel = New-Object System.Windows.Forms.Label
$dataBitsLabel.Text = "Data"
$dataBitsLabel.AutoSize = $true
$dataBitsLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($dataBitsLabel)

$dataBitsBox = New-Object System.Windows.Forms.ComboBox
$dataBitsBox.Width = 52
$dataBitsBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($bits in @(8, 7, 6, 5)) {
    [void]$dataBitsBox.Items.Add([string]$bits)
}
$dataBitsBox.SelectedItem = "8"
$topPanel.Controls.Add($dataBitsBox)

$parityLabel = New-Object System.Windows.Forms.Label
$parityLabel.Text = "Parity"
$parityLabel.AutoSize = $true
$parityLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($parityLabel)

$parityBox = New-Object System.Windows.Forms.ComboBox
$parityBox.Width = 74
$parityBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($parity in @("None", "Odd", "Even", "Mark", "Space")) {
    [void]$parityBox.Items.Add($parity)
}
$parityBox.SelectedItem = "None"
$topPanel.Controls.Add($parityBox)

$stopBitsLabel = New-Object System.Windows.Forms.Label
$stopBitsLabel.Text = "Stop"
$stopBitsLabel.AutoSize = $true
$stopBitsLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($stopBitsLabel)

$stopBitsBox = New-Object System.Windows.Forms.ComboBox
$stopBitsBox.Width = 72
$stopBitsBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($stopBits in @("One", "Two", "OnePointFive")) {
    [void]$stopBitsBox.Items.Add($stopBits)
}
$stopBitsBox.SelectedItem = "One"
$topPanel.Controls.Add($stopBitsBox)

$handshakeLabel = New-Object System.Windows.Forms.Label
$handshakeLabel.Text = "Flow"
$handshakeLabel.AutoSize = $true
$handshakeLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($handshakeLabel)

$handshakeBox = New-Object System.Windows.Forms.ComboBox
$handshakeBox.Width = 118
$handshakeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($flow in @("None", "RequestToSend", "XOnXOff", "RequestToSendXOnXOff")) {
    [void]$handshakeBox.Items.Add($flow)
}
$handshakeBox.SelectedItem = "None"
$topPanel.Controls.Add($handshakeBox)

$dtrCheck = New-Object System.Windows.Forms.CheckBox
$dtrCheck.Text = "DTR"
$dtrCheck.AutoSize = $true
$dtrCheck.Checked = [bool]$DefaultDtr
$dtrCheck.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($dtrCheck)

$rtsCheck = New-Object System.Windows.Forms.CheckBox
$rtsCheck.Text = "RTS"
$rtsCheck.AutoSize = $true
$rtsCheck.Checked = [bool]$DefaultRts
$rtsCheck.Margin = New-Object System.Windows.Forms.Padding(4, 6, 4, 0)
$topPanel.Controls.Add($rtsCheck)

$hexCheck = New-Object System.Windows.Forms.CheckBox
$hexCheck.Text = "Hex"
$hexCheck.AutoSize = $true
$hexCheck.Checked = [bool]$DefaultHex
$hexCheck.Margin = New-Object System.Windows.Forms.Padding(12, 6, 4, 0)
$topPanel.Controls.Add($hexCheck)

$autoscrollCheck = New-Object System.Windows.Forms.CheckBox
$autoscrollCheck.Text = "Auto-scroll"
$autoscrollCheck.AutoSize = $true
$autoscrollCheck.Checked = $true
$autoscrollCheck.Margin = New-Object System.Windows.Forms.Padding(4, 6, 4, 0)
$topPanel.Controls.Add($autoscrollCheck)

$cleanSpinnerCheck = New-Object System.Windows.Forms.CheckBox
$cleanSpinnerCheck.Text = "Clean CR/spinner"
$cleanSpinnerCheck.AutoSize = $true
$cleanSpinnerCheck.Checked = $true
$cleanSpinnerCheck.Margin = New-Object System.Windows.Forms.Padding(4, 6, 4, 0)
$topPanel.Controls.Add($cleanSpinnerCheck)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Text = "Connect"
$connectButton.Width = 92
$connectButton.Margin = New-Object System.Windows.Forms.Padding(12, 3, 4, 0)
$connectButton.Add_Click({
    if ($script:Serial -and $script:Serial.IsOpen) {
        Disconnect-Uart
    } else {
        Connect-Uart
    }
})
$topPanel.Controls.Add($connectButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear"
$clearButton.Width = 70
$clearButton.Add_Click({ Clear-TerminalBuffer })
$topPanel.Controls.Add($clearButton)

$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Text = "Log Folder"
$openLogButton.Width = 88
$openLogButton.Add_Click({
    $logDir = $LogDirectory
    if (-not $logDir) {
        $logDir = Join-Path $PSScriptRoot "logs"
    }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }
    Start-Process explorer.exe -ArgumentList "`"$logDir`""
})
$topPanel.Controls.Add($openLogButton)

$filterLabel = New-Object System.Windows.Forms.Label
$filterLabel.Text = "Filter"
$filterLabel.AutoSize = $true
$filterLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 4, 0)
$topPanel.Controls.Add($filterLabel)

$filterBox = New-Object System.Windows.Forms.TextBox
$filterBox.Width = 250
$filterBox.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
$filterBox.Add_TextChanged({
    $script:CurrentSearchRenderedIndex = -1
    Render-Terminal
})
$topPanel.Controls.Add($filterBox)

$clearFilterButton = New-Object System.Windows.Forms.Button
$clearFilterButton.Text = "Clear Filter"
$clearFilterButton.Width = 86
$clearFilterButton.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$clearFilterButton.Add_Click({ $filterBox.Clear() })
$topPanel.Controls.Add($clearFilterButton)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "Search"
$searchLabel.AutoSize = $true
$searchLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 4, 0)
$topPanel.Controls.Add($searchLabel)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Width = 250
$searchBox.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
$searchBox.Add_TextChanged({
    $script:CurrentSearchRenderedIndex = -1
    $script:LastSearchText = $searchBox.Text
    Update-SearchStatus
})
$searchBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        Find-SearchText 1
        $_.SuppressKeyPress = $true
    }
})
$topPanel.Controls.Add($searchBox)

$findPrevButton = New-Object System.Windows.Forms.Button
$findPrevButton.Text = "Prev"
$findPrevButton.Width = 54
$findPrevButton.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 0)
$findPrevButton.Add_Click({ Find-SearchText -1 })
$topPanel.Controls.Add($findPrevButton)

$findNextButton = New-Object System.Windows.Forms.Button
$findNextButton.Text = "Next"
$findNextButton.Width = 54
$findNextButton.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 0)
$findNextButton.Add_Click({ Find-SearchText 1 })
$topPanel.Controls.Add($findNextButton)

$searchStatusLabel = New-Object System.Windows.Forms.Label
$searchStatusLabel.AutoSize = $true
$searchStatusLabel.Margin = New-Object System.Windows.Forms.Padding(4, 10, 0, 0)
$topPanel.Controls.Add($searchStatusLabel)

$terminal = New-Object System.Windows.Forms.TextBox
$terminal.Multiline = $true
$terminal.ReadOnly = $true
$terminal.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$terminal.WordWrap = $false
$terminal.Dock = [System.Windows.Forms.DockStyle]::Fill
$terminal.BackColor = [System.Drawing.Color]::FromArgb(12, 14, 16)
$terminal.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$terminal.Font = New-Object System.Drawing.Font("Consolas", 10)
$form.Controls.Add($terminal)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 50
$script:PollTimer.Add_Tick({ Poll-Uart })

$form.Add_Shown({
    Refresh-Ports
    Add-Line "Ready. Select a COM port and serial settings, then connect."
    Add-Line "CH347 adapters appear as normal Windows COM ports when the WCH VCP driver is installed."
    Update-Status
    $script:PollTimer.Start()
    if ($AutoConnect) {
        Connect-Uart
    }
})

$form.Add_FormClosing({
    if ($script:PollTimer) {
        $script:PollTimer.Stop()
    }
    Disconnect-Uart
})

[void][System.Windows.Forms.Application]::Run($form)
