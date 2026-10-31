# BRENE x86_64 (MuMu 6 / Android 15) port

Fork target: `rami01e/BRENE` (fork of `rrr333nnn333/BRENE`, a KernelSU module
built around SuSFS). Goal: make it **install and work** on MuMu 6 Android 15
(x86_64), where the official module refuses to install because it is arm64-only.

Everything below was verified against the live device, not guessed. All
compilation happens on GitHub Actions; nothing is built locally.

---

## 1. Why the official module does not support x86_64 (root cause)

BRENE has **no injection component at all** — it is a set of shell scripts plus
one prebuilt native binary (`module/tools/susfs`, the `ksu_susfs` userspace CLI
from simonpunk's susfs4ksu). The scripts only issue ioctl/supercall commands to
a SuSFS kernel implementation; there is nothing for ByteHook (PLT hooking) to
do, so **ByteHook is not applicable here**.

The arm64-only limitation has three layers:

1. **Installer gate** — `module/customize.sh` aborts on anything but
   `ARCH=arm64`:
   ```bash
   if [[ "${ARCH}" != "arm64" ]]; then
       abort '[❌] Only arm64 is supported!'
   fi
   ```
   On the device, KernelSU sets `ARCH=x64` for x86_64 (verified by installing
   a probe module: `ARCH='x64'`, `ABI='x86_64'`, `API=35`).
2. **arm64-only binary** — upstream susfs4ksu's own
   `build_ksu_susfs_tool.sh` only copies `libs/arm64-v8a/ksu_susfs`; no x86_64
   build of the CLI exists anywhere.
3. **Kernel-side SuSFS** — SuSFS is kernel code. The MuMu 6 Android 15 kernel
   (`6.1.90-perf+`, NetEase build, KernelSU 32525-2 built in,
   `CONFIG_KSU=y`) has **no SuSFS** (`/proc/config.gz` contains no
   `CONFIG_KSU_SUSFS*`). The prebuilt community x86_64 SuSFS LKM
   (`ymuuuu/susfs4ksu-lkm-x64`) is built for stock GKI kernels and **cannot
   load on MuMu** (verified by test-loading `android14-6.1_susfs_guard_lkm.ko`:
   the kernel refuses with `Unknown symbol` for `__list_add_valid`,
   `__list_del_entry_valid`, `fortify_panic`, `init_mm`, `native_set_fixmap`,
   `copy_to_kernel_nofault`, `task_work_add`, `saved_boot_config` — the first
   three do not even exist in MuMu's kernel because it has
   `CONFIG_DEBUG_LIST=n` and `CONFIG_FORTIFY_SOURCE=n`).

   Interesting detail: the vermagic release mismatch (`6.1.166` vs
   `6.1.90-perf+`) does NOT block loading — MODVERSIONS kernels compare only
   the flags part (`SMP preempt mod_unload modversions`), which matches. The
   blocker is purely the symbols, which is fixable by building the LKM against
   MuMu's own kernel config.

## 2. Verified device facts (MuMu 6, Android 15)

| Fact | Value | How verified |
|---|---|---|
| Kernel | `6.1.90-perf+ #3 SMP PREEMPT_DYNAMIC` (clang 19.0.1, built 2026-10-09) | `/proc/version` |
| KernelSU | built-in (`CONFIG_KSU=y`), kernel version code **32525**, `ksud 3.2.5` — BRENE's `>= 32336` check passes | `ksud debug version`, module env dump |
| CPU ABI | `x86_64` (arm64 via translation), `ro.product.cpu.abi=x86_64` | `getprop`, ELF headers (`e_machine=62`) |
| `uname -m` | reports `aarch64` — kernel-spoofed; never use uname for arch detection here | `uname -a` vs ELF headers |
| Module env | `ARCH=x64`, `KSU=true`, `MAGISK_VER_CODE=25200` (compat) | probe module env dump |
| SuSFS in kernel | **absent** (no `CONFIG_KSU_SUSFS*`) | `/proc/config.gz` |
| LKM support | `CONFIG_MODULES=y`, `MODULE_UNLOAD=y`, `MODVERSIONS=y`, **no module signature enforcement**, `KALLSYMS_ALL=y`, `MODULE_FORCE_LOAD=y` | `/proc/config.gz` |
| adb | already root (`uid=0`, `u:r:su:s0`), no `su` binary needed | `adb shell id` |
| Extracted kernel config | saved as `kernel-config/mumu_android15_6.1.90.config` (8754 lines) | `adb pull /proc/config.gz` |

## 3. What this port changes

### 3.1 `module/customize.sh` (rewritten arch/binary logic)
- accepts `ARCH=arm64` **and** `ARCH=x64` (32-bit arches still abort);
- picks `tools/susfs` (arm64, upstream's committed binary) or
  `tools/susfs_x64` (built by CI from susfs4ksu userspace) per arch;
- if a susfs CLI that **already answers `show version` with `v2*`** is
  installed (e.g. the supercall CLI installed by the SuSFS LKM loader module),
  it is **kept**, not overwritten — on x86_64 emulators that LKM CLI is the
  only one that can talk to the LKM's supercall/proc interface;
- the missing-kernel-susfs case no longer aborts the install: it warns and
  continues, so BRENE installs cleanly on MuMu today and all susfs features
  activate automatically once the LKM is loaded;
- backs up whichever CLI is live into the persistent dir.

### 3.2 `module/post-fs-data.sh`
- restores the backed-up CLI only if the current one does not already answer
  `v2*` (never clobbers the LKM's supercall CLI);
- **new**: if `/proc/susfs_path` is missing and the CLI is not answering,
  triggers the SuSFS LKM loader module (`susfs_lkm_mumu`, `susfs_guard_lkm`,
  `susfs_lkm_x64`) before issuing any susfs command — module ids sort
  `brene` before `susfs_*`, so without this, BRENE's early susfs calls would
  run before the LKM is loaded;
- silences the `show variant` probe when the interface is down;
- uname spoof: falls back to the non-GKI release format when
  `ksud boot-info current-kmi` answers nothing (MuMu's ksud does not
  implement it).
- everything else is byte-identical to upstream.

### 3.3 `module/boot-completed.sh`
- `show version` / `show enabled_features` probes silenced when down
  (description correctly shows "Not Working ❌" / "Active ✅");
- `set_priority_uid_filter` is best-effort (`2>/dev/null`): it exists in
  in-kernel susfs v2.3+ but the LKM supercall CLI does not implement it.
- everything else is byte-identical to upstream.

### 3.4 `module/utils.sh`
- new `brene_susfs_ready()` probe (`show version` must answer `v2*`);
- `brene_sus_path`, `brene_sus_path_loop`, `brene_sus_map`, `brene_set_uname`,
  `brene_open_redirect` no-op quietly when the kernel interface is down
  (instead of spamming errors); `brene_kernel_umount` (ksud-based) and
  `brene_clone_perm` (busybox-based) are untouched.

### 3.5 New: `.github/workflows/build.yml`
Three build jobs, all on GitHub runners:
1. **susfs-cli** — clones `simonpunk/susfs4ksu` (`gki-android15-6.6`),
   widens `APP_ABI` to `arm64-v8a x86_64`, `ndk-build`s the classic
   `ksu_susfs` CLI, uploads both binaries.
2. **susfs-lkm-mumu** — resolves the `android14-6.1-6.1.90_*` kernel tag
   (history-scan fallback), applies `kernel-config/mumu_android15_6.1.90.config`
   (the exact MuMu kernel config), `modules_prepare`, then builds the vendored
   `susfs4ksu-for-lkm-2.3.0-r18.6` LKM for x86_64; verifies vermagic flags and
   that the module imports no symbols missing from MuMu's kernel
   (`fortify_panic`, `__list_*_valid`); packages `susfs-lkm-mumu.zip`
   (loader scripts + matched `.ko` + x86_64 supercall CLI).
3. **brene-module** — assembles `BRENE-<ver>-x64.zip` (module + built
   `tools/susfs_x64`).

Tag pushes additionally create a GitHub release with both zips.

### 3.6 New support files
- `kernel-config/mumu_android15_6.1.90.config` — the exact kernel config
  pulled from the device; the LKM build uses it so struct layouts (including
  `CONFIG_ANDROID_KABI_RESERVE=y` reserved fields) match the running kernel.
- `lkm-mumu/{module.prop,post-fs-data.sh,service.sh,uninstall.sh}` — flashable
  loader module adapted from `ymuuuu/susfs4ksu-lkm-x64` for the MuMu kernel:
  loads `susfs_guard_lkm_mumu.ko` via `ksud insmod ... expose_proc=1`
  (plain `insmod` cannot resolve the unexported imports; `ksud insmod`
  resolves them from kallsyms), refuses any other kernel release, and
  installs the x86_64 CLI as `/data/adb/ksu/bin/{susfs,sus,ksu_susfs}`.
  Note: it deliberately does **not** trust `uname -m` (MuMu spoofs it to
  `aarch64`).
- `vendor/susfs4ksu-for-lkm-2.3.0-r18.6.zip` — vendored LKM source
  (GPL-2.0, inforcqb/susfs4ksu-for-lkm) so the build is reproducible.
- `vendor/susfs_cli_x64` — the x86_64 supercall CLI binary from
  `ymuuuu/susfs4ksu-lkm-x64` (GPL-2.0), which speaks the exact command
  surface BRENE calls.

## 4. Install order on MuMu 6 (Android 15)

1. Push this tree to your fork → GitHub Actions builds → download
   `susfs-lkm-mumu.zip` and `BRENE-<ver>-x64.zip` from the run artifacts
   (or the release).
2. Flash **`susfs-lkm-mumu.zip`** in the KernelSU manager, reboot.
   Verify (root adb — MuMu's adb is already root, no `su` needed):
   ```sh
   cat /proc/susfs_path                       # control node exists
   /data/adb/ksu/bin/susfs show version       # expect: v2.3.0
   /data/adb/ksu/bin/susfs show variant
   ```
   If the load fails, read `/data/adb/modules/susfs_lkm_mumu/load.log` and
   `dmesg | tail`. (`rmmod susfs_guard_lkm` unloads it live.)
3. Flash **`BRENE-<ver>-x64.zip`**, reboot. Its installer will detect the
   working LKM CLI and keep it; BRENE's scripts then drive the LKM through
   the same command surface as on arm64 phones.
4. Check module status in the manager (description shows SuSFS: v2.3.0 …) or:
   ```sh
   /data/adb/ksu/bin/susfs show enabled_features
   ```

## 5. Known limitations / honest notes

- **`set_priority_uid_filter`** (hide third-party apps from getpriority
  enumeration) is not implemented by the LKM CLI; the call is best-effort and
  silently skipped on MuMu. Everything else in the BRENE surface
  (`add_sus_path`, `add_sus_path_loop`, `add_sus_map`, `add_sus_kstat*`,
  `add_open_redirect`, `set_uname`, `set_cmdline_or_bootconfig`,
  `enable_log`, `enable_avc_log_spoofing`,
  `hide_sus_mnts_for_non_su_procs`, `show version|variant|enabled_features`)
  is answered by the LKM CLI.
- The LKM build assumes NetEase's kernel is android14-6.1 (GKI) at 6.1.90
  plus KernelSU 32525-2 and nothing that changes core struct layouts
  (`CONFIG_ANDROID_KABI_RESERVE=y` is covered by the android-common tree, and
  the config is the device's own). The CI verification plus the on-device
  smoke test are the proof; if the .ko refuses to load or misbehaves, capture
  `dmesg | tail -30` — the CI is parameterized (`KERNEL_BRANCH`/`KERNEL_VERSION`
  env values at the top of the workflow) if a different base turns out to be
  needed.
- The LKM hides itself from `lsmod`; check `/sys/module/susfs_guard_lkm`.
- `update.json` in the fork still points at upstream's updater; you may want
  to drop `updateJson` from `module.prop` so the manager does not offer the
  arm64-only upstream releases over your port. (Left untouched on purpose.)
- The KernelSU WebUI (`module/webroot/`) was left untouched; it does not
  gate on arch.

## 6. Credits & licenses

- BRENE — rrr333nnn333 (AGPL-3.0)
- susfs4ksu userspace tool & kernel susfs — simonpunk (GPL-2.0)
- susfs4ksu-for-lkm (LKM port) — inforcqb (GPL-2.0)
- x86_64 LKM port & supercall CLI — ymuuuu (GPL-2.0)
- SukiSU-Ultra — patch_memory / lsm_hook / symbol_resolver
- MuMu kernel facts — verified live on the device via adb
