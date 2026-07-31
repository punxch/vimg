"""Exact peak Working Set via GetProcessMemoryInfo(PeakWorkingSetSize)."""
import ctypes, ctypes.wintypes as w, sys, time
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)
CREATE_SUSPENDED = 0x4
INFINITE = 0xFFFFFFFF

class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
    _fields_ = [("cb", w.DWORD), ("PageFaultCount", w.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t)]

class PI(ctypes.Structure):
    _fields_ = [("hProcess", w.HANDLE), ("hThread", w.HANDLE), ("dwProcessId", w.DWORD), ("dwThreadId", w.DWORD)]
class SI(ctypes.Structure):
    _fields_ = [("cb", w.DWORD), ("lpReserved", w.LPWSTR), ("lpDesktop", w.LPWSTR), ("lpTitle", w.LPWSTR),
                ("dwX", w.DWORD), ("dwY", w.DWORD), ("dwXSize", w.DWORD), ("dwYSize", w.DWORD),
                ("dwXCountChars", w.DWORD), ("dwYCountChars", w.DWORD), ("dwFillAttribute", w.DWORD),
                ("dwFlags", w.DWORD), ("wShowWindow", w.WORD), ("cbReserved2", w.WORD),
                ("lpReserved2", ctypes.c_void_p), ("hStdInput", w.HANDLE), ("hStdOutput", w.HANDLE), ("hStdError", w.HANDLE)]

k32.CreateProcessW.restype = w.BOOL
psapi.GetProcessMemoryInfo.restype = w.BOOL
psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.POINTER(PROCESS_MEMORY_COUNTERS), w.DWORD]

exe = sys.argv[1]
args = " ".join('"%s"' % a if " " in a else a for a in sys.argv[2:])
cmd = '"%s" %s' % (exe, args)
si = SI(); si.cb = ctypes.sizeof(SI); pi = PI()
ok = k32.CreateProcessW(exe, cmd, None, None, False, CREATE_SUSPENDED, None, None, ctypes.byref(si), ctypes.byref(pi))
if not ok:
    raise OSError("CreateProcess failed: %d" % ctypes.get_last_error())
k32.ResumeThread(pi.hThread)
peak_ws = 0; peak_pf = 0
while True:
    mc = PROCESS_MEMORY_COUNTERS(); mc.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
    if psapi.GetProcessMemoryInfo(pi.hProcess, ctypes.byref(mc), mc.cb):
        if mc.PeakWorkingSetSize > peak_ws: peak_ws = mc.PeakWorkingSetSize
        if mc.PeakPagefileUsage > peak_pf: peak_pf = mc.PeakPagefileUsage
    if k32.WaitForSingleObject(pi.hProcess, 0) == 0:  # WAIT_OBJECT_0 = exited
        break
    time.sleep(0.001)
k32.WaitForSingleObject(pi.hProcess, INFINITE)
print("%s: peak WS %.1f MB, peak commit %.1f MB" % (
    exe.split("\\")[-1], peak_ws/1048576.0, peak_pf/1048576.0))
