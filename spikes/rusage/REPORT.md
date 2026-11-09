# Spike B Report: Per-Process I/O Throughput (`proc_pid_rusage`)

## 1. Does it work?
**Partly (No for general physical drives without root; Yes only for user-owned disk images via `diskimages-helper`).**

Specifically:
- **`Finder` (`uid=502`)** does **zero** file copy I/O itself (`R=0 B/s, W=0 B/s`, only an occasional 8 KB `.DS_Store` update).
- **`DesktopServicesHelper` and `DesktopServicesScriptingHelper` (`uid=0, root`)** are the processes that actually perform the copy I/O for Finder. Because both are registered as system LaunchDaemons (`/System/Library/LaunchDaemons/com.apple.DesktopServicesHelper.plist` and `com.apple.DesktopServicesScriptingHelper.plist`), `launchd` spawns them on demand as **`root` (`uid=0, ruid=0`)**. Calling `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)` (or `proc_pidinfo(PROC_PIDTASKINFO)`) on them from a non-root user process (`uid=502`) **fails with `errno = 1` (`EPERM: Operation not permitted`)**.
- **`diskimages-helper` (`uid=502`)** performs the underlying backing-store writes when the target volume is a user-mounted disk image (such as `/Volumes/FinderSpeedTest`). Because `diskimages-helper` runs as `uid=502`, `proc_pid_rusage` succeeds without root and its `ri_diskio_byteswritten` matches the 2 GiB transfer within ~2.3%. However, `diskimages-helper` is **not** involved when copying to physical external USB/Thunderbolt drives, SD cards, or network shares.

---

## 2. The Evidence

### A. Process inspection (`ps`) during Finder copy of `testdata/big_2g.bin`
```text
USER          UID  RUID   PID  PPID  %CPU COMMAND
mauriziolol   502   502   764     1   1.2 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
root            0     0 54069     1   6.8 /System/Library/PrivateFrameworks/DesktopServicesPriv.framework/Resources/DesktopServicesScriptingHelper
mauriziolol   502   502 40861     1  12.7 /System/Library/PrivateFrameworks/DiskImages.framework/Resources/diskimages-helper
```
- When triggered via AppleScript (`tell application "Finder" to duplicate ...`), Finder spawns `DesktopServicesScriptingHelper` (PID 54069) as `root` (`uid=0`), which exits shortly after the copy finishes.
- Interactive Finder copies use `DesktopServicesHelper`, which is likewise configured in `/System/Library/LaunchDaemons/com.apple.DesktopServicesHelper.plist` without `UserName` and therefore also runs as `root` (`uid=0`).

### B. 250ms `proc_pid_rusage(RUSAGE_INFO_V4)` log during isolated 2 GiB copy
- **File size:** `2,147,483,648` bytes (2.00 GiB / 2.15 GB)
- **Wall-clock copy time:** `3.114s`
- **Actual average transfer speed:** `689.68 MB/s` (`657.73 MiB/s`)

```text
Starting rusage_monitor (sampling every 250ms)...
Current UID: 502, EUID: 502 (non-root: true)
[ 0.26s] fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
  [!] Target process DesktopServicesScriptingHelper (pid=54069, uid=0, ruid=0, path=/System/Library/PrivateFrameworks/DesktopServicesPriv.framework/Versions/A/Resources/DesktopServicesScriptingHelper): proc_pid_rusage failed with errno=1 (Operation not permitted); PROC_PIDTASKINFO=FAIL
[ 0.55s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=5.81 MB/s W=103.48 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 0.82s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=41.61 MB/s W=911.39 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 1.08s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=41.42 MB/s W=903.08 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 1.35s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=43.48 MB/s W=947.96 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 1.61s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=43.95 MB/s W=962.29 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 1.88s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=36.80 MB/s W=803.43 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 2.14s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=34.80 MB/s W=757.28 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 2.40s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=33.96 MB/s W=744.05 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 2.67s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=35.25 MB/s W=769.57 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 2.93s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=35.52 MB/s W=775.41 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 3.19s] DesktopServicesScriptingHelper[54069,uid=0]: RUSAGE_ERR(1:Operation not permitted) | diskimages-helper[40861,uid=502]: R=28.75 MB/s W=627.54 MB/s | fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s
[ 3.46s] fileproviderd[790,uid=502]: R=0 B/s W=0 B/s | Finder[764,uid=502]: R=0 B/s W=0 B/s

=== Cumulative I/O during monitoring window ===
  diskimages-helper[40861] (uid=502) -> Read: 101.24 MB (101236736 B), Written: 2.20 GB (2198421504 B)
```

---

## 3. Permissions Needed
- **`proc_pid_rusage` on user-owned processes (`Finder`, `diskimages-helper`):** None (works in a standard unprivileged process).
- **`proc_pid_rusage` on `DesktopServicesHelper` / `DesktopServicesScriptingHelper`:** Requires **`root` (`euid == 0`)**. XNU's `proc_pid_rusage` enforces that the caller must either be root or have matching `uid`/`ruid` with the target process (`bsd/kern/proc_info.c`).

---

## 4. Files Created
- `spikes/rusage/rusage_monitor.swift` — Swift CLI tool that discovers `Finder`, `DesktopServicesHelper`, `DesktopServicesScriptingHelper`, and any process with active disk I/O (`>100 KB` per 250ms window) and samples `proc_pid_rusage(RUSAGE_INFO_V4)` every 250ms.
- `spikes/rusage/rusage_monitor` — Compiled Mach-O arm64 binary.
- `spikes/rusage/REPORT.md` — This report.

---

## 5. Open Questions & Recommendation for Zeus
1. Because `DesktopServicesHelper` and `DesktopServicesScriptingHelper` run as `root`, an unprivileged companion app **cannot** use `proc_pid_rusage` to measure their per-process I/O without a privileged helper daemon.
2. **Recommendation:** If Spike A (`NSProgress` subscription, or polling the destination file/folder size or `IOBlockStorageDriver` stats via IOKit) works without root, we should use that as the primary data engine, or use IOKit `IOBlockStorageDriver` device-level byte counters (which are readable without root via `IORegistryEntryCreateCFProperties`) as a fallback.
