param(
    [string]$PortName = "COM7",
    [int]$Seconds = 20,
    [int]$BaudRate = 115200
)

$ErrorActionPreference = "Stop"
$port = [System.IO.Ports.SerialPort]::new($PortName, $BaudRate, "None", 8, "One")
$port.ReadTimeout = 500
$port.NewLine = "`n"

try {
    $port.Open()
    $deadline = (Get-Date).AddSeconds($Seconds)
    Write-Host "=== Capturing $PortName at $BaudRate for $Seconds seconds ==="
    while ((Get-Date) -lt $deadline) {
        try {
            $text = $port.ReadExisting()
            if ($text.Length -gt 0) {
                Write-Host -NoNewline $text
            }
        } catch [TimeoutException] {
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "`n=== Capture done: $PortName ==="
} finally {
    if ($port.IsOpen) {
        $port.Close()
    }
}
