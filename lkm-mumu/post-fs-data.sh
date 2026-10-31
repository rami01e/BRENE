#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Load the MuMu-matched x86_64 susfs_guard_lkm .ko at the earliest boot stage.
# Adapted from ymuuuu/susfs4ksu-lkm-x64's loader for the MuMu 6 Android 15
# kernel (osrelease 6.1.90-perf+). Notes:
#  - Do NOT check `uname -m`: MuMu's kernel spoofs uname to aarch64. The ELF
#    e_machine check happens in the kernel anyway.
#  - Load through `ksud insmod`: five-ish imports (init_mm, native_set_fixmap,
#    copy_to_kernel_nofault, task_work_add, saved_boot_config, ...) exist in
#    the kernel but are not exported to modules; ksud resolves them from
#    kallsyms before finit_module. Plain insmod cannot do that.
MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0
[ -f "$MODDIR/remove" ] && exit 0
umask 077
exec >>"$MODDIR/load.log" 2>&1
echo "susfs_lkm_mumu loader: $(date)"
if [ -e /proc/susfs_path ]; then
	echo "susfs already present; nothing to do."
	exit 0
fi
REL=$(cat /proc/sys/kernel/osrelease) || {
	echo "cannot read kernel release"
	exit 1
}
case "$REL" in
6.1.90-perf+) ;;
*)
	echo "kernel release '$REL' is not what this .ko was built for (6.1.90-perf+); refusing"
	exit 1
	;;
esac
KO="$MODDIR/susfs_guard_lkm_mumu.ko"
[ -f "$KO" ] || {
	echo "matched .ko missing from the module dir:"
	ls "$MODDIR"
	exit 1
}
/data/adb/ksud insmod "$KO" expose_proc=1
rc=$?
[ "$rc" = 0 ] && echo "loaded susfs_guard_lkm for $REL." || echo "ksud insmod failed: $rc"
exit "$rc"
