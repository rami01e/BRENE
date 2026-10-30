#!/system/bin/sh
# Best-effort live unload; the .ko disappears on reboot regardless.
rmmod susfs_guard_lkm 2>/dev/null
exit 0
