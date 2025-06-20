# This PowerShell script is designed to only load a pre-compiled 'cheat.dll'
# into the Counter-Strike 2 (cs2.exe) process.
# It does NOT contain any cheat logic itself; all cheat functionality
# is expected to be within the 'cheat.dll' file.
#
# IMPORTANT: This script requires 'cheat.dll' to be present in your GitHub repository.
# Ensure the DLL is compatible with the current version of CS2.
#
# This code is provided for educational purposes ONLY. Using such tools in online games
# is against most game's terms of service and can lead to permanent account bans.
# Use at your own risk and responsibility.

#region Load External C# DLL from GitHub
# Define the raw URL for cheat.dll in your GitHub repository
$DllGitHubRawUrl = "https://raw.githubusercontent.com/TheZeny-LNTW/tg/main/cheat.dll"
$TempDllPath = Join-Path $env:TEMP "cheat.dll"

Write-Host "[DLL Injector] Próba pobrania cheat.dll z GitHub..." -ForegroundColor Yellow

try {
    # Download the DLL to a temporary path
    Invoke-RestMethod -Uri $DllGitHubRawUrl -OutFile $TempDllPath
    Write-Host "[DLL Injector] cheat.dll pobrano do: $($TempDllPath)" -ForegroundColor Green

    # Load the DLL from the temporary path
    # This makes the public static classes/methods from the DLL available in PowerShell.
    Add-Type -LiteralPath $TempDllPath
    Write-Host "[DLL Injector] cheat.dll załadowano pomyślnie." -ForegroundColor Green

    # You might want to remove the temporary DLL file after loading.
    # Uncomment the line below if you wish to automatically delete the downloaded DLL.
    # Remove-Item $TempDllPath -ErrorAction SilentlyContinue

} catch {
    Write-Host "[DLL Injector] BŁĄD: Nie udało się pobrać lub załadować cheat.dll." -ForegroundColor Red
    Write-Host "[DLL Injector] Upewnij się, że 'cheat.dll' istnieje pod adresem '$DllGitHubRawUrl' i jest poprawny." -ForegroundColor Red
    Write-Host "[DLL Injector] Szczegóły błędu: $($_.Exception.Message)" -ForegroundColor Red
    exit 1 # Exit the script if DLL cannot be loaded
}
#endregion

# Virtual Key Code for the END key (to exit the script)
private const int VK_END = 0x23;

#region WinAPI Imports (Minimal for Exit Key)
# We need GetAsyncKeyState to check for the END key to exit the script.
# This should ideally also be part of your cheat.dll if you compile it with your WinAPI class.
Add-Type -TypeDefinition @"
    using System.Runtime.InteropServices;

    public class MinimalWinAPI
    {
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);
    }
"@ -Language CSharp

function IsKeyPressed($vKey) {
    # Checks if a virtual key is currently pressed.
    return (([int]([MinimalWinAPI]::GetAsyncKeyState($vKey))) -band 0x8000) -ne 0
}
#endregion

#region Main DLL Injection Logic
function Start-DLLInjector {
    Write-Host "[DLL Injector] Szukam procesu CS2..." -ForegroundColor Cyan

    $process = $null
    $processHandle = [IntPtr]::Zero

    # Loop until the game process is found.
    while ($process -eq $null -or $processHandle -eq [IntPtr]::Zero) {
        $process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) {
            # You might need PROCESS_ALL_ACCESS (0x1F0FFF) or similar if your DLL requires more rights
            $processHandle = [WinAPI]::OpenProcess(0x001F0FFF, $false, $process.Id) # Using a broad access right for injection (PROCESS_ALL_ACCESS)
            if ($processHandle -ne [IntPtr]::Zero) {
                Write-Host "[DLL Injector] Znaleziono cs2.exe. ID Procesu: $($process.Id)" -ForegroundColor Green
                Write-Host "[DLL Injector] Uzyskano uchwyt procesu. Teraz 'cheat.dll' powinien działać." -ForegroundColor Green
                break
            } else {
                Write-Host "[DLL Injector] Nie udało się uzyskać uchwytu procesu do cs2.exe. Upewnij się, że PowerShell jest uruchomiony jako Administrator." -ForegroundColor Red
                Start-Sleep -Seconds 5
            }
        } else {
            Write-Host "[DLL Injector] CS2 nie znaleziono. Ponawiam próbę za 5 sekund..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "[DLL Injector] Aktywny. Naciśnij klawisz 'END', aby wyjść." -ForegroundColor Green

    # Keep the script alive. Your cheat.dll should now be active in CS2.
    while (!(IsKeyPressed $VK_END)) {
        Start-Sleep -Milliseconds 100 # Small delay to prevent busy-waiting
    }

    Write-Host "`n[DLL Injector] Klawisz 'END' naciśnięty. Zamykam injector..." -ForegroundColor Cyan

    # Cleanup: Close the process handle when the injector exits
    if ($processHandle -ne [IntPtr]::Zero) {
        [WinAPI]::CloseHandle($processHandle) | Out-Null
        Write-Host "[DLL Injector] Uchwyt procesu zamknięty." -ForegroundColor Cyan
    }
}
#endregion

# Set console title
$Host.UI.RawUI.WindowTitle = "CS2 DLL Injector (PowerShell)"
Write-Host "Uruchamiam CS2 DLL Injector (PowerShell)..." -ForegroundColor White
Write-Host "------------------------------------------" -ForegroundColor White

# Start the DLL injector logic
Start-DLLInjector

Write-Host "`n[DLL Injector] Injector zakończył działanie." -ForegroundColor Cyan
