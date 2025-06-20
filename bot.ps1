# This PowerShell script replicates the functionality of the C# TriggerBot.cs
# and the relevant parts of Program.cs for launching the Trigger Bot.
#
# This version embeds the C# functionality directly into the script for self-contained execution.
# The problematic Console.WriteLine in the embedded C# has been removed to prevent compilation errors.
#
# IMPORTANT: Game offsets change frequently with game updates. You MUST update the offsets
# to match the current game version. Using outdated offsets will lead to incorrect behavior or crashes.
#
# This code is provided for educational purposes ONLY. Using such tools in online games
# is against most game's terms of service and can lead to permanent account bans.
# Use at your own risk and responsibility.

#region WinAPI Imports and Helper Functions (Embedded C#)
# We embed C# code to use WinAPI functions directly, as PowerShell doesn't have native
# equivalents for low-level memory operations or direct P/Invoke without this.
Add-Type -TypeDefinition @"
    using System;
    using System.Diagnostics;
    using System.Runtime.InteropServices;

    public class WinAPI
    {
        // Used to send mouse input events.
        [DllImport("user32.dll", CharSet = CharSet.Auto, CallingConvention = CallingConvention.StdCall)]
        public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, uint dwExtraInfo);

        // Used to open a process with specific access rights.
        [DllImport("kernel32.dll")]
        public static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        // Used to read memory from a process.
        [DllImport("kernel32.dll")]
        public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, [Out] byte[] lpBuffer, int dwSize, out int lpNumberOfBytesRead);

        // Used to close an opened process handle.
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);

        // Used to get the asynchronous key state.
        // This allows checking if a key is currently pressed, even if the application is not in focus.
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

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
                // Removed Console.WriteLine from C# block to prevent Add-Type compilation issues.
                // Debugging output will be handled by PowerShell's ReadMemoryPS wrapper.
                return default(T);
            }
        }
    }
"@ -Language CSharp

#endregion

#region Global Constants and Offsets

# Mouse event flags
$MOUSEEVENTF_LEFTDOWN = 0x02 # Left button down
$MOUSEEVENTF_LEFTUP   = 0x04 # Left button up

# Process access rights
$PROCESS_VM_READ = 0x0010 # Required to read memory

# Virtual Key Codes
$VK_XBUTTON1 = 0x05 # Mouse Button 4 (Activation key)
$VK_END       = 0x23 # END key (Exit key)

# Game Offsets (YOU MUST UPDATE THESE FOR THE CURRENT GAME VERSION)
# These are taken directly from your provided C# TriggerBot.cs
$Offsets = @{
    dwLocalPlayerPawn        = 0x18560D0
    dwEntityList             = 0x1A020A8
    dwGameEntitySystem       = 0x1B25BD8
    dwGameEntitySystem_highestEntityIndex = 0x20F0 # Not used in current logic
    m_iTeamNum               = 0x3E3
    m_iHealth                = 0x344
    m_entitySpottedState     = 0x1630
    bSpotted                 = 0x8
    m_iCrosshairTarget       = 0x1458
    m_fFlags                 = 0x3EC # Not used in current logic
    m_hPlayerPawn            = 0x824 # Not used in current logic
}

# Debugging Flag
$DebugMode = $true # Set to $true to enable verbose debugging output

#endregion

#region Helper Functions (PowerShell Wrappers)

function IsKeyPressed($vKey) {
    # Check if a virtual key is pressed using the imported GetAsyncKeyState from WinAPI class.
    return (([int]([WinAPI]::GetAsyncKeyState($vKey))) -band 0x8000) -ne 0
}

function SimulateLeftClick() {
    # Simulate a left mouse click using the imported mouse_event from WinAPI class.
    [WinAPI]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 10
    [WinAPI]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
}

function ReadMemoryPS([IntPtr]$hProcess, [IntPtr]$address, [Type]$type, [string]$debugTag = "") {
    # Wrapper function to call the C# ReadMemory generic method.
    # It converts the type to a generic type parameter suitable for the C# method.
    # We now handle error logging for ReadMemory failures directly in PowerShell.
    $result = [WinAPI]::ReadMemory([System.Object].GetType().GetMethod("ReadMemory").MakeGenericMethod($type)).Invoke($null, @($hProcess, $address, $debugTag))

    # Check if the result is the default value (indicating a read failure in C#)
    if ($result -eq $null -or $result -eq [System.Activator]::CreateInstance($type)) {
        if ($DebugMode -and -not $global:HasLoggedMemoryReadError) {
            # Log this error only once to avoid spamming, unless it's a new type of error.
            Write-Host "[TriggerBot] DEBUG WARNING: ReadMemory failed for '$debugTag' at 0x$($address.ToInt64().ToString('X')). This might indicate outdated offsets or permission issues." -ForegroundColor Yellow
            # To re-enable this warning on subsequent failures, uncomment the line below:
            # $global:HasLoggedMemoryReadError = $false
            $global:HasLoggedMemoryReadError = $true # Set flag to true after logging
        }
        return default($type) # Return default value to propagate the failure
    } else {
        $global:HasLoggedMemoryReadError = $false # Reset flag if a successful read occurs
    }
    return $result
}

#endregion

#region Main Trigger Bot Logic

function Start-TriggerBot {
    Write-Host "[TriggerBot] Searching for CS2 process..." -ForegroundColor Cyan

    $process = $null
    $processHandle = [IntPtr]::Zero
    $clientDllBase = [IntPtr]::Zero

    # Loop until the game process is found and memory is ready.
    while ($process -eq $null -or $processHandle -eq [IntPtr]::Zero -or $clientDllBase -eq [IntPtr]::Zero) {
        $process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) {
            $processHandle = [WinAPI]::OpenProcess($PROCESS_VM_READ, $false, $process.Id)
            if ($processHandle -ne [IntPtr]::Zero) {
                # Find the client.dll module's base address
                foreach ($module in $process.Modules) {
                    if ($module.ModuleName -eq "client.dll") {
                        $clientDllBase = $module.BaseAddress
                        Write-Host "[TriggerBot] Found cs2.exe. Process ID: $($process.Id)" -ForegroundColor Green
                        Write-Host "[TriggerBot] client.dll Base Address: 0x$($clientDllBase.ToInt64().ToString('X'))" -ForegroundColor Green
                        break
                    }
                }
            }
        }

        if ($clientDllBase -eq [IntPtr]::Zero) {
            Write-Host "[TriggerBot] CS2 not found or client.dll not loaded. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "[TriggerBot] Active. Hold MOUSE4 to enable. Press 'END' to exit." -ForegroundColor Green

    # Initialize a flag to prevent spamming warnings about memory read failures
    $global:HasLoggedMemoryReadError = $false

    # Main bot loop
    while (!(IsKeyPressed $VK_END)) { # Check if END key is pressed to exit
        # Only proceed with trigger logic if MOUSE4 is pressed.
        if (!(IsKeyPressed $VK_XBUTTON1)) {
            Start-Sleep -Milliseconds 100 # Longer delay when not active to reduce CPU usage
            continue
        }

        try {
            # Read local player's pawn address
            $localPlayerPawnPtr = ReadMemoryPS $processHandle ($clientDllBase + $Offsets.dwLocalPlayerPawn) ([IntPtr]) "dwLocalPlayerPawn"
            if ($localPlayerPawnPtr -eq [IntPtr]::Zero) {
                # Error message already handled by ReadMemoryPS, just continue loop
                Start-Sleep -Milliseconds 10
                continue
            }
            if ($DebugMode) { Write-Host "[Debug] localPlayerPawnPtr: 0x$($localPlayerPawnPtr.ToInt64().ToString('X'))" }

            # Read local player's team number
            $localPlayerTeam = ReadMemoryPS $processHandle ($localPlayerPawnPtr + $Offsets.m_iTeamNum) ([int]) "localPlayerTeam"
            # No explicit check needed here, ReadMemoryPS handles default if failed
            if ($DebugMode) { Write-Host "[Debug] localPlayerTeam: $($localPlayerTeam)" }

            # Read the ID of the entity currently in the crosshair
            $crosshairEntityId = ReadMemoryPS $processHandle ($localPlayerPawnPtr + $Offsets.m_iCrosshairTarget) ([int]) "m_iCrosshairTarget"
            # No explicit check needed here, ReadMemoryPS handles default if failed
            if ($DebugMode) { Write-Host "[Debug] crosshairEntityId: $($crosshairEntityId)" }

            $shouldFire = $false

            # Validate crosshairEntityId. Using broader range 1 to 1023.
            # If crosshairEntityId is 0 (default if read failed), this condition also handles it.
            if ($crosshairEntityId -gt 0 -and $crosshairEntityId -lt 1024) {
                # IMPROVED ENTITY POINTER RESOLUTION LOGIC (from your C# code)
                $gameEntitySystemPtr = ReadMemoryPS $processHandle ($clientDllBase + $Offsets.dwGameEntitySystem) ([IntPtr]) "dwGameEntitySystem"

                if ($gameEntitySystemPtr -eq [IntPtr]::Zero) {
                    Write-Host "[TriggerBot] DEBUG ERROR: dwGameEntitySystem pointer is invalid. Cannot resolve entity." -ForegroundColor Red
                    Start-Sleep -Milliseconds 10
                    continue
                }
                if ($DebugMode) { Write-Host "[Debug] gameEntitySystemPtr: 0x$($gameEntitySystemPtr.ToInt64().ToString('X'))" }

                # Explicitly cast to Int64 for intermediate calculations to prevent overflow
                $shf_9_mult_8 = ([Int64]$crosshairEntityId -shr 9) * 0x8
                $band_1FF_mult_78 = ([Int64]$crosshairEntityId -band 0x1FF) * 0x78
                if ($DebugMode) {
                    Write-Host "[Debug] shf_9_mult_8: 0x$($shf_9_mult_8.ToString('X'))"
                    Write-Host "[Debug] band_1FF_mult_78: 0x$($band_1FF_mult_78.ToString('X'))"
                }

                # Calculate entity entry pointer
                $entityEntryAddress = [IntPtr]($gameEntitySystemPtr.ToInt64() + $shf_9_mult_8 + 0x10)
                if ($DebugMode) { Write-Host "[Debug] entityEntryAddress (computed): 0x$($entityEntryAddress.ToInt64().ToString('X'))" }

                $entityEntryPtr = ReadMemoryPS $processHandle $entityEntryAddress ([IntPtr]) "entityEntryPtr_base"

                if ($entityEntryPtr -eq [IntPtr]::Zero) {
                    # Error message already handled by ReadMemoryPS, just continue loop
                    Start-Sleep -Milliseconds 10
                    continue
                }
                if ($DebugMode) { Write-Host "[Debug] entityEntryPtr (read): 0x$($entityEntryPtr.ToInt64().ToString('X'))" }

                # Calculate final entity pointer
                $entityAddress = [IntPtr]($entityEntryPtr.ToInt64() + $band_1FF_mult_78)
                if ($DebugMode) { Write-Host "[Debug] entityAddress (computed): 0x$($entityAddress.ToInt64().ToString('X'))" }

                $entityPtr = ReadMemoryPS $processHandle $entityAddress ([IntPtr]) "entityPtr_final"

                if ($entityPtr -ne [IntPtr]::Zero) {
                    if ($DebugMode) { Write-Host "[Debug] entityPtr (read): 0x$($entityPtr.ToInt64().ToString('X'))" }
                    # Read entity's team number
                    $entityTeam = ReadMemoryPS $processHandle ($entityPtr + $Offsets.m_iTeamNum) ([int]) "m_iTeamNum_entity"
                    if ($DebugMode) { Write-Host "[Debug] entityTeam: $($entityTeam)" }

                    # Trigger logic: Only shoot if it's an enemy
                    if ($entityTeam -ne $localPlayerTeam) {
                        $shouldFire = $true
                    }
                } else {
                    if ($DebugMode) { Write-Host "[Debug] entityPtr (read): 0x0. Cannot resolve entity." }
                }
            } else {
                if ($DebugMode) { Write-Host "[Debug] crosshairEntityId ($($crosshairEntityId)) is out of valid range (1-1023)." }
            }

            # Perform attack based on shouldFire flag
            if ($shouldFire) {
                SimulateLeftClick # Corrected: Removed parentheses for PowerShell function call
                Start-Sleep -Milliseconds 50 # Small delay to prevent too many rapid clicks
            }
        }
        catch {
            Write-Host "[TriggerBot] An error occurred: $($_.Exception.Message). Retrying..." -ForegroundColor Red
            Start-Sleep -Milliseconds 100 # Longer delay on error
        }

        Start-Sleep -Milliseconds 1 # Main loop delay for responsiveness
    }

    # Cleanup: Close the process handle when the bot exits
    if ($processHandle -ne [IntPtr]::Zero) {
        [WinAPI]::CloseHandle($processHandle) | Out-Null # Use Out-Null to suppress boolean output
        Write-Host "[TriggerBot] Process handle closed. Exiting." -ForegroundColor Cyan
    }
}

# Set console title
$Host.UI.RawUI.WindowTitle = "CS2 Bots Launcher - Trigger Bot (PowerShell)"
Write-Host "Starting CS2 Trigger Bot Launcher (PowerShell)..." -ForegroundColor White
Write-Host "------------------------------------------" -ForegroundColor White

# Start the trigger bot
Start-TriggerBot

Write-Host "`n'END' key pressed. Exiting Trigger Bot." -ForegroundColor Cyan
