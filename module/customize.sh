#!/bin/bash
# shellcheck disable=SC2154
# X64 PORT NOTE (rami01e fork):
#  - Upstream hard-aborted everything except ARCH=arm64 and shipped a single
#    arm64-only susfs binary. This port accepts arm64 AND x64 (KernelSU maps
#    x86_64 devices to ARCH=x64, e.g. MuMu 6 Android 15) and picks the susfs
#    CLI that matches $ARCH.
#  - On x86_64 emulators the susfs kernel side is usually a loadable kernel
#    module (susfs_guard_lkm), whose loader module installs its own susfs CLI
#    that speaks the LKM supercall/proc interface. If such a working CLI is
#    already present we keep it instead of overwriting it, and the missing
#    kernel susfs no longer aborts the install: susfs-dependent features
#    simply stay inactive until the kernel/LKM interface is up.
KSU_BIN=/data/adb/ksud
KSU_MODULES_DIR=/data/adb/modules
SUSFS_BIN=/data/adb/ksu/bin/susfs
PERSISTENT_DIR=/data/adb/brene
DEST_BIN_DIR=/data/adb/ksu/bin

# Load utils
[[ -e "${MODPATH}/utils.sh" ]] && source "${MODPATH}/utils.sh"

echo ""
echo "██████╗ ██████╗ ███████╗███╗   ██╗███████╗"
echo "██╔══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝"
echo "██████╔╝██████╔╝█████╗  ██╔██╗ ██║█████╗  "
echo "██╔══██╗██╔══██╗██╔══╝  ██║╚██╗██║██╔══╝  "
echo "██████╔╝██║  ██║███████╗██║ ╚████║███████╗"
echo "╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚══════╝"
echo ""

# Check Compatibility
if [[ -z "${KSU}" ]]; then
	abort '[❌] SuSFS is only for KernelSU or forks!'
fi

# Check arch: arm64 (phones) or x64 (x86_64 emulators like MuMu / AVD)
case "${ARCH}" in
	arm64)
		BUNDLED_SUSFS_BIN="${MODPATH}/tools/susfs"
		echo "[✅] Detected arm64 device"
		;;
	x64)
		BUNDLED_SUSFS_BIN="${MODPATH}/tools/susfs_x64"
		echo "[✅] Detected x64 (x86_64) device"
		;;
	*)
		abort "[❌] Only arm64 and x64 are supported! (ARCH=${ARCH})"
		;;
esac

# if [[ "${KSU_KERNEL_VER_CODE}" -ge 32336 ]]; then
# 	echo "[✅] Detected KernelSU kernel version: ${KSU_KERNEL_VER_CODE}"
# else
# 	abort "[❌] Unsupported KernelSU kernel version: ${KSU_KERNEL_VER_CODE}!"
# fi

if [[ ! -d "${DEST_BIN_DIR}" ]]; then
	abort "[❌] '${DEST_BIN_DIR}' not existed, installation aborted!"
fi

# If a susfs CLI that can already talk to the running kernel is installed
# (e.g. the supercall CLI installed by the susfs_guard_lkm loader module on
# x86_64 emulators), keep it: it matches the susfs implementation that is
# actually present in this kernel. Only fall back to our bundled binary
# (built from susfs4ksu userspace) when no working CLI exists.
susfs_version=$("${SUSFS_BIN}" show version 2>/dev/null)
case "${susfs_version}" in
	v2*)
		echo "[✅] Detected working susfs CLI (${susfs_version}), keeping it"
		;;
	*)
		if [[ ! -f "${BUNDLED_SUSFS_BIN}" ]]; then
			abort "[❌] Bundled susfs binary missing for ARCH=${ARCH}: ${BUNDLED_SUSFS_BIN}!"
		fi
		cp -f "${BUNDLED_SUSFS_BIN}" "${DEST_BIN_DIR}"
		susfs_version=$("${SUSFS_BIN}" show version 2>/dev/null)
		;;
esac

chmod +x "${MODPATH}/inotify.sh"
chmod +x "${MODPATH}/remove_ksu_directory.sh"
chmod 755 "${DEST_BIN_DIR}/susfs"
ln -sf "${DEST_BIN_DIR}/susfs" "${DEST_BIN_DIR}/sus"       # For development
ln -sf "${DEST_BIN_DIR}/susfs" "${DEST_BIN_DIR}/ksu_susfs" # For compatibility

susfs_version=$(${SUSFS_BIN} show version)
if [[ "${susfs_version}" == "v2.4.0" || "${susfs_version}" == "v2.3.0" || "${susfs_version}" == "v2.2.0" ]]; then
	echo "[✅] Detected SuSFS version: ${susfs_version}"
else
	# Do not hard-abort here anymore: on x86_64 emulators the susfs kernel
	# side is a loadable module that may not be loaded at install time (or
	# even refuse to load on this kernel). Install cleanly and let
	# post-fs-data.sh bring the interface up on every boot.
	echo "[⚠️] SuSFS kernel interface not detected (got: '${susfs_version:-nothing}')"
	echo "[⚠️] Continuing anyway - susfs-dependent features stay inactive until the susfs kernel/LKM interface is up"
	susfs_version="unknown"
fi

# Reset module description
susfs_total_features=9
susfs_features_number=$(${SUSFS_BIN} show enabled_features 2>/dev/null | wc -l)
kernel_version=$(cat /proc/version | awk '{print $3}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
description="KernelSU module with SuSFS support and more"
status="Waiting for reboot ⏱️"
${KSU_BIN} module config set override.description "[Status: ${status} | Kernel Version: ${kernel_version} | SuSFS: ${susfs_version} | SuSFS Kernel Features: ${susfs_features_number}/${susfs_total_features} enabled] ${description}"

# Disable other SuSFS modules
[[ -e "${KSU_MODULES_DIR}/susfs4ksu" ]] && {
	touch "${KSU_MODULES_DIR}/susfs4ksu/disable" && echo '[✅] Disabling other SuSFS module'
}
[[ -e "${KSU_MODULES_DIR}/susfs_manager" ]] && {
	touch "${KSU_MODULES_DIR}/susfs_manager/disable" && echo '[✅] Disabling other SuSFS module'
}
[[ -e "${KSU_MODULES_DIR}/ReSuSFS" ]] && {
	touch "${KSU_MODULES_DIR}/ReSuSFS/disable" && echo '[✅] Disabling other SuSFS module'
}

echo "[✅] Preparing brene persistent directory (${PERSISTENT_DIR})"
mkdir -p "${PERSISTENT_DIR}"

# Mount-hide prefixes for the susfs mount marking (LKM: /proc/susfs_hide_mounts).
# Seeded with the mountpoint that Zygisk modules such as zygisk_vector bind
# their resource cache to on x86_64 emulators; its mountinfo root shows as
# "/adb/modules/..." and matches none of the built-in prefixes. One prefix
# per line; '#' starts a comment.
if [[ ! -f "${PERSISTENT_DIR}/custom_mount_hide_prefixes.txt" ]]; then
	printf '%s\n' \
		'# Extra mount-source / mountpoint prefixes susfs should treat as "ours"' \
		'# and hide from non-su processes. One prefix per line.' \
		'/data/resource-cache' \
		> "${PERSISTENT_DIR}/custom_mount_hide_prefixes.txt"
	echo '[✅] Added custom_mount_hide_prefixes.txt'
fi

# Backup SuSFS binary (whichever CLI is live on this device)
cp -pf "${DEST_BIN_DIR}/susfs" "${PERSISTENT_DIR}"

files="
custom_sus_map.txt
custom_kernel_umount.txt
custom_sus_path.txt
custom_sus_path_loop.txt
custom_open_redirect.txt
"
for file in ${files}; do
	if [[ ! -f "${PERSISTENT_DIR}/${file}" ]]; then
		touch "${PERSISTENT_DIR}/${file}" && echo "[✅] Added ${file}"
	fi
done

if [[ ! -f "${PERSISTENT_DIR}/config.sh" ]]; then
	cp "${MODPATH}/config.sh" "${PERSISTENT_DIR}" && echo '[✅] Added config.sh'
else
	while IFS='=' read -r key value || [[ -n "${key}" ]]; do

		# Skip empty lines or comments
		[[ -z "${key// /}" || "${key// /}" == "#"* ]] && continue

		if grep -q "^${key}=" "${PERSISTENT_DIR}/config.sh"; then
			:
		else
			echo "${key}=${value}" >> "${PERSISTENT_DIR}/config.sh"
			echo "[➕] Added missing key=value: ${key}=${value}"
		fi

	done < "${MODPATH}/config.sh"
fi

update_config_date

# Reset fake_files folder
[[ -d "${PERSISTENT_DIR}/fake_files" ]] && rm -rf "${PERSISTENT_DIR}/fake_files"
mkdir -p "${PERSISTENT_DIR}/fake_files"

# Hot install support
if [[ "${KSU_HAS_HOT_INSTALL}" == true ]]; then
	export MODULE_HOT_INSTALL_REQUEST=true
fi
