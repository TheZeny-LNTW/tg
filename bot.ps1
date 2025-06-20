# This PowerShell script is designed to perform a true DLL injection
# of 'cheat.dll' into the Counter-Strike 2 (cs2.exe) process.
# This script does NOT contain any cheat logic itself; all cheat functionality
# is expected to be within the 'cheat.dll' file that gets injected.
#
# IMPORTANT: This script requires 'cheat.dll' to be present in your GitHub repository.
# Ensure the DLL is compatible with the current version of CS2.
# Using DLL injection is against game terms of service and can lead to permanent bans.
# Use at your own risk and responsibility.

#region Global Constants
private const int VK_END = 0x23; # Virtual Key Code for the END key (to exit the script)

# Process Access Rights (for OpenProcess)
private const int PROCESS_CREATE_THREAD = 0x0002;
private const int PROCESS_QUERY_INFORMATION = 0x0400;
private const int PROCESS_VM_OPERATION = 0x0008;
private const int PROCESS_VM_WRITE = 0x0020;
private const int PROCESS_VM_READ = 0x0010;
private const int PROCESS_ALL_ACCESS = 0x1F0FFF; # Broad access for easier injection

# Memory Allocation Types (for VirtualAllocEx)
private const int MEM_COMMIT = 0x1000;
private const int MEM_RESERVE = 0x2000;

# Memory Protection Constants (for VirtualAllocEx)
private const int PAGE_READWRITE = 0x04;

# CreateRemoteThread constants
private const int CREATE_SUSPENDED = 0x00000004;
private const int THREAD_WAIT_FOR_INPUT_IDLE = 0x00000004; # Optional, for WaitForSingleObject
private const int INFINITE = -1; # For WaitForSingleObject timeout

#endregion

#region WinAPI Imports (for DLL Injection)
# These are the crucial functions needed for DLL Injection.
Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    using System.Text;

    public class InjectorWinAPI
    {
        // For opening a process to get a handle with necessary rights
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(
            int dwDesiredAccess,
            bool bInheritHandle,
            int dwProcessId
        );

        // For allocating memory in the target process
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr VirtualAllocEx(
            IntPtr hProcess,
            IntPtr lpAddress,
            uint dwSize,
            uint flAllocationType,
            uint flProtect
        );

        // For writing data to the target process's memory
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteProcessMemory(
            IntPtr hProcess,
            IntPtr lpBaseAddress,
            byte[] lpBuffer,
            uint nSize,
            out UIntPtr lpNumberOfBytesWritten
        );

        // For getting a module handle (e.g., kernel32.dll) in the current process
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        public static extern IntPtr GetModuleHandleA(string lpModuleName);

        // For getting the address of an exported function from a module
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        public static extern IntPtr GetProcAddress(
            IntPtr hModule,
            string lpProcName
        );

        // For creating a new thread in the target process
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateRemoteThread(
            IntPtr hProcess,
            IntPtr lpThreadAttributes,
            uint dwStackSize,
            IntPtr lpStartAddress,
            IntPtr lpParameter,
            uint dwCreationFlags,
            out IntPtr lpThreadId
        );

        // For waiting for a thread to terminate
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(
            IntPtr hHandle,
            uint dwMilliseconds
        );

        // For freeing memory in the target process
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool VirtualFreeEx(
            IntPtr hProcess,
            IntPtr lpAddress,
            uint dwSize,
            uint dwFreeType
        );

        // For closing process/thread handles
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);

        // For checking key states (for the END key exit)
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);
    }
"@ -Language CSharp

function IsKeyPressed($vKey) {
    # Checks if a virtual key is currently pressed.
    return (([int]([InjectorWinAPI]::GetAsyncKeyState($vKey))) -band 0x8000) -ne 0
}

#endregion

#region Main DLL Injection Logic
function Start-DLLInjector {
    Write-Host "[DLL Injector] Szukam procesu CS2..." -ForegroundColor Cyan

    $process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$process) {
        Write-Host "[DLL Injector] BŁĄD: Proces 'cs2.exe' nie znaleziony. Upewnij się, że gra jest uruchomiona." -ForegroundColor Red
        exit 1
    }

    $processId = $process.Id
    $dllPath = $TempDllPath # Path to the downloaded DLL

    # Get a handle to the process with necessary access rights
    $hProcess = [InjectorWinAPI]::OpenProcess($PROCESS_ALL_ACCESS, $false, $processId)
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się uzyskać uchwytu procesu do cs2.exe. Upewnij się, że PowerShell jest uruchomiony jako Administrator i że masz uprawnienia." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        exit 1
    }
    Write-Host "[DLL Injector] Uzyskano uchwyt procesu CS2: 0x$($hProcess.ToInt64().ToString('X'))" -ForegroundColor Green

    # Allocate memory in the target process for the DLL path
    $dllPathBytes = [System.Text.Encoding]::ASCII.GetBytes($dllPath)
    $dllPathSize = $dllPathBytes.Length + 1 # +1 for null terminator
    $remoteMemory = [InjectorWinAPI]::VirtualAllocEx($hProcess, [IntPtr]::Zero, $dllPathSize, ($MEM_COMMIT -bor $MEM_RESERVE), $PAGE_READWRITE)
    if ($remoteMemory -eq [IntPtr]::Zero) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się zaalokować pamięci w procesie CS2." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
        exit 1
    }
    Write-Host "[DLL Injector] Zaalokowano pamięć w procesie CS2 pod adresem: 0x$($remoteMemory.ToInt64().ToString('X'))" -ForegroundColor Green

    # Write the DLL path to the allocated memory
    $bytesWritten = [System.UIntPtr]::Zero
    if (!([InjectorWinAPI]::WriteProcessMemory($hProcess, $remoteMemory, $dllPathBytes, $dllPathSize, [ref]$bytesWritten))) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się zapisać ścieżki DLL do pamięci CS2." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        [InjectorWinAPI]::VirtualFreeEx($hProcess, $remoteMemory, 0, 0x8000) | Out-Null # MEM_RELEASE = 0x8000
        [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
        exit 1
    }
    Write-Host "[DLL Injector] Ścieżka DLL zapisana do pamięci CS2." -ForegroundColor Green

    # Get the address of LoadLibraryA from kernel32.dll (this address is usually the same across processes)
    $kernel32Module = [InjectorWinAPI]::GetModuleHandleA("kernel32.dll")
    if ($kernel32Module -eq [IntPtr]::Zero) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się uzyskać uchwytu do kernel32.dll." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        [InjectorWinAPI]::VirtualFreeEx($hProcess, $remoteMemory, 0, 0x8000) | Out-Null
        [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
        exit 1
    }
    Write-Host "[DLL Injector] Uchwyt kernel32.dll: 0x$($kernel32Module.ToInt64().ToString('X'))" -ForegroundColor Green

    $loadLibraryAddress = [InjectorWinAPI]::GetProcAddress($kernel32Module, "LoadLibraryA")
    if ($loadLibraryAddress -eq [IntPtr]::Zero) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się uzyskać adresu LoadLibraryA." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        [InjectorWinAPI]::VirtualFreeEx($hProcess, $remoteMemory, 0, 0x8000) | Out-Null
        [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
        exit 1
    }
    Write-Host "[DLL Injector] Adres LoadLibraryA: 0x$($loadLibraryAddress.ToInt64().ToString('X'))" -ForegroundColor Green

    # Create a remote thread in the target process to call LoadLibraryA
    $remoteThreadId = [IntPtr]::Zero
    $hRemoteThread = [InjectorWinAPI]::CreateRemoteThread(
        $hProcess,
        [IntPtr]::Zero,
        0, # Default stack size
        $loadLibraryAddress,
        $remoteMemory,
        0, # dwCreationFlags (0 for immediate execution)
        [ref]$remoteThreadId
    )
    if ($hRemoteThread -eq [IntPtr]::Zero) {
        Write-Host "[DLL Injector] BŁĄD: Nie udało się utworzyć zdalnego wątku w procesie CS2." -ForegroundColor Red
        Write-Host "[DLL Injector] Win32 Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
        [InjectorWinAPI]::VirtualFreeEx($hProcess, $remoteMemory, 0, 0x8000) | Out-Null
        [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
        exit 1
    }
    Write-Host "[DLL Injector] Zdalny wątek utworzony. Wstrzykiwanie 'cheat.dll'..." -ForegroundColor Green

    # Wait for the remote thread to finish
    [InjectorWinAPI]::WaitForSingleObject($hRemoteThread, $INFINITE) | Out-Null
    Write-Host "[DLL Injector] Zdalny wątek zakończył działanie." -ForegroundColor Green

    # Cleanup - Free allocated memory and close handles
    [InjectorWinAPI]::VirtualFreeEx($hProcess, $remoteMemory, 0, 0x8000) | Out-Null # MEM_RELEASE = 0x8000
    [InjectorWinAPI]::CloseHandle($hRemoteThread) | Out-Null
    [InjectorWinAPI]::CloseHandle($hProcess) | Out-Null
    Write-Host "[DLL Injector] Wstrzyknięto 'cheat.dll' do CS2 i zakończono czyszczenie uchwytów." -ForegroundColor Green

    Write-Host "[DLL Injector] Aktywny. Naciśnij klawisz 'END', aby wyjść z PowerShell." -ForegroundColor Green

    # Keep the PowerShell script alive until END key is pressed
    while (!(IsKeyPressed $VK_END)) {
        Start-Sleep -Milliseconds 100 # Small delay to prevent busy-waiting
    }

    Write-Host "`n[DLL Injector] Klawisz 'END' naciśnięty. Zamykam injector..." -ForegroundColor Cyan
}
#endregion

# Set console title
$Host.UI.RawUI.WindowTitle = "CS2 DLL Injector (PowerShell)"
Write-Host "Uruchamiam CS2 DLL Injector (PowerShell)..." -ForegroundColor White
Write-Host "------------------------------------------" -ForegroundColor White

# Start the DLL injector logic
Start-DLLInjector

Write-Host "`n[DLL Injector] Injector zakończył działanie." -ForegroundColor Cyan
