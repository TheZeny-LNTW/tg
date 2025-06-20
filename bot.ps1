# This PowerShell script integrates the functionality of TriggerBot and Bhop
# directly using embedded C# code via Add-Type.
# It does NOT use external DLLs like cheat.dll.
#
# IMPORTANT: Game offsets change frequently with game updates. You MUST update the offsets
# to match the current game version. Using outdated offsets will lead to incorrect behavior or crashes.
#
# This code is provided for educational purposes ONLY. Using such tools in online games
# is against most game's terms of service and can lead to permanent account bans.
# Use at your own risk and responsibility.

#region Global Constants
private const int VK_END = 0x23;      # Virtual Key Code for the END key (to exit all bots)
private const int VK_XBUTTON1 = 0x05; # Virtual Key Code for Mouse Button 4 (TriggerBot activation)
private const int VK_SPACE = 0x20;    # Virtual Key Code for Spacebar (Bhop activation)

# Process Access Rights
private const int PROCESS_VM_READ = 0x0010;  # Required to read memory
private const int PROCESS_VM_WRITE = 0x0020; # Required to write memory (for Bhop)
private const int PROCESS_VM_OPERATION = 0x0008; # Required for general operations (for Bhop)
private const int PROCESS_ALL_ACCESS = 0x1F0FFF; # Broad access for OpenProcess (if needed)

# Bhop specific constants
private const int ON_GROUND_FLAG = 1; # (1 << 0) indicates being on ground for player flags
private const int JUMP_ON = 65537;    # Value to write to dwForceJump to initiate jump
private const int JUMP_OFF = 256;     # Value to write to dwForceJump to stop jump (or revert)

#endregion

#region Embedded C# (WinAPI Imports and Helper Methods, Game Offsets)
Add-Type -TypeDefinition @"
    using System;
    using System.Diagnostics;
    using System.Runtime.InteropServices;
    using System.Text; // For Encoding if needed, though not directly used in this C# block for string conversion for injection

    // Public class for all WinAPI imports and common helper memory functions
    public class WinAPIAndHelpers
    {
        // --- WinAPI Imports (from Program.cs, Triggerbot.cs, Bhop.cs) ---
        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, uint dwExtraInfo);

        [DllImport("kernel32.dll")]
        public static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll")]
        public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, [Out] byte[] lpBuffer, int dwSize, out int lpNumberOfBytesRead);

        [DllImport("kernel32.dll")]
        public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, [In] byte[] lpBuffer, int dwSize, out int lpNumberOfBytesWritten);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        // --- Helper Methods ---
        // Generic ReadMemory function using Marshal
        public static T ReadMemory<T>(IntPtr hProcess, IntPtr address, string debugTag = "") where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            byte[] buffer = new byte[size];
            int bytesRead;

            if (ReadProcessMemory(hProcess, address, buffer, size, out bytesRead) && bytesRead == size)
            {
                GCHandle handle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                T data = (T)Marshal.PtrToStructure(handle.AddrOfPinnedObject(), typeof(T));
                handle.Free();
                return data;
            }
            else
            {
                // Return default(T) on failure; PowerShell wrapper will handle logging
                return default(T);
            }
        }

        // Generic WriteMemory function using Marshal
        public static bool WriteMemory<T>(IntPtr hProcess, IntPtr address, T value, string debugTag = "") where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            byte[] buffer = new byte[size];

            GCHandle handle = GCHandle.Alloc(value, GCHandleType.Pinned);
            Marshal.Copy(handle.AddrOfPinnedObject(), buffer, 0, size);
            handle.Free();

            int bytesWritten;
            bool success = WriteProcessMemory(hProcess, address, buffer, size, out bytesWritten);

            return success && bytesWritten == size; // Return success status
        }

        // Simulates a left mouse click (down and up) using mouse_event
        public static void SimulateLeftClick()
        {
            mouse_event(0x02, 0, 0, 0, 0); // MOUSEEVENTF_LEFTDOWN
            System.Threading.Thread.Sleep(10);
            mouse_event(0x04, 0, 0, 0, 0);   // MOUSEEVENTF_LEFTUP
        }
    }

    // --- Game Offsets (Defined as a static class for easy access and type safety) ---
    public static class GameOffsets
    {
        // User-provided offsets (YOU MUST UPDATE THESE FOR THE CURRENT GAME VERSION)
        public static int dwLocalPlayerPawn = 0x18560D0;
        public static int dwEntityList = 0x1A020A8;
        public static int dwGameEntitySystem = 0x1B25BD8;

        public static int m_iTeamNum = 0x3E3;
        public static int m_iHealth = 0x344;
        public static int m_entitySpottedState = 0x1630;
        public static int bSpotted = 0x8; // Offset within m_entitySpottedState structure

        public static int m_iCrosshairTarget = 0x1458;

        public static int m_fFlags = 0x3EC; // Player Flags (for Bhop)
        public static int dwForceJump = 0x184EE00; // Force Jump offset (for Bhop)
    }
"@ -Language CSharp

#endregion

#region PowerShell Helper Functions

# Initialize a flag to prevent spamming warnings about memory read failures
$global:HasLoggedMemoryReadError = $false

function IsKeyPressedPS($vKey) {
    # Checks if a virtual key is currently pressed using the C# helper.
    return (([int]([WinAPIAndHelpers]::GetAsyncKeyState($vKey))) -band 0x8000) -ne 0
}

function SimulateLeftClickPS() {
    # Simulates a left mouse click using the C# helper.
    [WinAPIAndHelpers]::SimulateLeftClick()
}

function ReadMemoryPS([IntPtr]$hProcess, [IntPtr]$address, [Type]$type, [string]$debugTag = "") {
    # Wrapper function to call the C# ReadMemory generic method.
    $result = [WinAPIAndHelpers]::ReadMemory([System.Object].GetType().GetMethod("ReadMemory").MakeGenericMethod($type)).Invoke($null, @($hProcess, $address, $debugTag))

    # Check if the result is the default value (indicating a read failure in C#)
    if ($result -eq $null -or $result -eq [System.Activator]::CreateInstance($type)) {
        if ($DebugMode -and -not $global:HasLoggedMemoryReadError) {
            Write-Host "[Bots] DEBUG WARNING: ReadMemory failed for '$debugTag' at 0x$($address.ToInt64().ToString('X')). This might indicate outdated offsets or permission issues." -ForegroundColor Yellow
            $global:HasLoggedMemoryReadError = $true # Set flag to true after logging
        }
        return $result # Return default value to propagate the failure
    } else {
        $global:HasLoggedMemoryReadError = $false # Reset flag if a successful read occurs
    }
    return $result
}

function WriteMemoryPS([IntPtr]$hProcess, [IntPtr]$address, [object]$value, [string]$debugTag = "") {
    # Wrapper function to call the C# WriteMemory generic method.
    # Dynamically determine the type for the generic method
    $type = $value.GetType()
    $success = [WinAPIAndHelpers]::WriteMemory([System.Object].GetType().GetMethod("WriteMemory").MakeGenericMethod($type)).Invoke($null, @($hProcess, $address, $value, $debugTag))

    if (!$success -and $DebugMode) {
        Write-Host "[Bots] DEBUG WARNING: WriteMemory failed for '$debugTag' at 0x$($address.ToInt64().ToString('X')). Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Yellow
    }
    return $success
}

#endregion

#region Main Bots Logic

function Start-CS2Bots {
    Write-Host "[Bots] Szukam procesu CS2..." -ForegroundColor Cyan

    $process = $null
    $processHandle = [IntPtr]::Zero
    $clientDllBase = [IntPtr]::Zero

    # Loop until the game process is found and memory is ready.
    while ($process -eq $null -or $processHandle -eq [IntPtr]::Zero -or $clientDllBase -eq [IntPtr]::Zero) {
        $process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) {
            # Use PROCESS_ALL_ACCESS for both read/write operations (needed by Bhop)
            $processHandle = [WinAPIAndHelpers]::OpenProcess($PROCESS_VM_READ -bor $PROCESS_VM_WRITE -bor $PROCESS_VM_OPERATION, $false, $process.Id)
            if ($processHandle -ne [IntPtr]::Zero) {
                # Find the client.dll module's base address. This module contains most game data.
                foreach ($module in $process.Modules) {
                    if ($module.ModuleName -eq "client.dll") {
                        $clientDllBase = $module.BaseAddress
                        Write-Host "[Bots] Znaleziono cs2.exe. ID Procesu: $($process.Id)" -ForegroundColor Green
                        Write-Host "[Bots] client.dll Base Adres: 0x$($clientDllBase.ToInt64().ToString('X'))" -ForegroundColor Green
                        break
                    }
                }
            }
        }

        if ($clientDllBase -eq [IntPtr]::Zero) {
            Write-Host "[Bots] CS2 nie znaleziono lub client.dll nie załadowano. Ponawiam próbę za 5 sekund..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "[Bots] Aktywny. Przytrzymaj MOUSE4 dla Trigger Bot, SPACJĘ dla Bhop Bot. Naciśnij 'END', aby wyjść." -ForegroundColor Green

    # Main bot loop
    while (!(IsKeyPressedPS $VK_END)) { # Check if END key is pressed to exit
        # Check Trigger Bot activation
        if (IsKeyPressedPS $VK_XBUTTON1) {
            # --- Trigger Bot Logic ---
            try {
                $localPlayerPawnPtr = ReadMemoryPS $processHandle ($clientDllBase + [GameOffsets]::dwLocalPlayerPawn) ([IntPtr]) "dwLocalPlayerPawn"
                if ($localPlayerPawnPtr -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 10; continue }

                $localPlayerTeam = ReadMemoryPS $processHandle ($localPlayerPawnPtr + [GameOffsets]::m_iTeamNum) ([int]) "localPlayerTeam"
                $crosshairEntityId = ReadMemoryPS $processHandle ($localPlayerPawnPtr + [GameOffsets]::m_iCrosshairTarget) ([int]) "m_iCrosshairTarget"

                $shouldFire = $false
                if ($crosshairEntityId -gt 0 -and $crosshairEntityId -lt 1024) {
                    $gameEntitySystemPtr = ReadMemoryPS $processHandle ($clientDllBase + [GameOffsets]::dwGameEntitySystem) ([IntPtr]) "dwGameEntitySystem"
                    if ($gameEntitySystemPtr -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 10; continue }

                    $shf_9_mult_8 = ([Int64]$crosshairEntityId -shr 9) * 0x8
                    $band_1FF_mult_78 = ([Int64]$crosshairEntityId -band 0x1FF) * 0x78

                    $entityEntryAddress = [IntPtr]($gameEntitySystemPtr.ToInt64() + $shf_9_mult_8 + 0x10)
                    $entityEntryPtr = ReadMemoryPS $processHandle $entityEntryAddress ([IntPtr]) "entityEntryPtr_base"
                    if ($entityEntryPtr -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 10; continue }

                    $entityAddress = [IntPtr]($entityEntryPtr.ToInt64() + $band_1FF_mult_78)
                    $entityPtr = ReadMemoryPS $processHandle $entityAddress ([IntPtr]) "entityPtr_final"

                    if ($entityPtr -ne [IntPtr]::Zero) {
                        $entityTeam = ReadMemoryPS $processHandle ($entityPtr + [GameOffsets]::m_iTeamNum) ([int]) "m_iTeamNum_entity"
                        if ($entityTeam -ne $localPlayerTeam) {
                            $shouldFire = $true
                        }
                    }
                }
                if ($shouldFire) {
                    SimulateLeftClickPS
                    Start-Sleep -Milliseconds 50 # Delay to prevent too many rapid clicks
                }
            }
            catch {
                Write-Host "[Bots] An error occurred during Trigger Bot: $($_.Exception.Message). Retrying..." -ForegroundColor Red
            }
        }

        # Check Bhop activation
        if (IsKeyPressedPS $VK_SPACE) {
            # --- Bhop Logic ---
            try {
                $localPlayerPawnPtr = ReadMemoryPS $processHandle ($clientDllBase + [GameOffsets]::dwLocalPlayerPawn) ([IntPtr]) "dwLocalPlayerPawn"
                if ($localPlayerPawnPtr -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 10; continue }

                $playerFlags = ReadMemoryPS $processHandle ($localPlayerPawnPtr + [GameOffsets]::m_fFlags) ([int]) "m_fFlags"

                if (($playerFlags -band $ON_GROUND_FLAG) -gt 0) {
                    # Write jump values
                    WriteMemoryPS $processHandle ($clientDllBase + [GameOffsets]::dwForceJump) $JUMP_ON "dwForceJump_ON"
                    Start-Sleep -Milliseconds 5
                    WriteMemoryPS $processHandle ($clientDllBase + [GameOffsets]::dwForceJump) $JUMP_OFF "dwForceJump_OFF"
                }
            }
            catch {
                Write-Host "[Bots] An error occurred during Bhop Bot: $($_.Exception.Message). Retrying..." -ForegroundColor Red
            }
        }

        Start-Sleep -Milliseconds 1 # Main loop delay for responsiveness
    }

    # Cleanup: Close the process handle when the bot exits
    if ($processHandle -ne [IntPtr]::Zero) {
        [WinAPIAndHelpers]::CloseHandle($processHandle) | Out-Null
        Write-Host "[Bots] Process handle closed. Exiting." -ForegroundColor Cyan
    }
}
#endregion

# Set console title
$Host.UI.RawUI.WindowTitle = "CS2 Bots Launcher (PowerShell)"
Write-Host "Uruchamiam CS2 Bots Launcher (PowerShell)..." -ForegroundColor White
Write-Host "------------------------------------------" -ForegroundColor White

# Start the main bot logic
Start-CS2Bots

Write-Host "`nKlawisz 'END' naciśnięty. Zamykam wszystkie boty." -ForegroundColor Cyan
