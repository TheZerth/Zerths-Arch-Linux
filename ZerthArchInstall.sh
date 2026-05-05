#!/usr/bin/bash
set -euo pipefail
trap 'echo "ERROR: Script failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: This script must be run as root (./ZerthArchInstall.sh)." >&2
	exit 1
fi

ScriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PacConfig="/etc/pacman.conf"
MkinitcpioConfig="/etc/mkinitcpio.conf"
InstallUser="${SUDO_USER:-$USER}"
InstallHome="$(getent passwd "$InstallUser" | cut -d: -f6)"
InstallGroup="$(id -gn "$InstallUser" 2>/dev/null)"
InstallUid="$(id -u "$InstallUser" 2>/dev/null)"
if [ -z "$InstallHome" ]; then
	InstallHome="$HOME"
fi
if [ -z "$InstallGroup" ]; then
	InstallGroup="$InstallUser"
fi
if [ -z "$InstallUid" ]; then
	InstallUid="$(id -u)"
fi

Title='\e[34m'
Success='\e[32m'
Install='\e[33m'
Fail='\e[31m'
END='\e[0m'

runAsInstallUser() {
	if [ "$(id -u)" -eq 0 ] && [ "$InstallUser" != "root" ]; then
		sudo -u "$InstallUser" env HOME="$InstallHome" XDG_RUNTIME_DIR="/run/user/$InstallUid" "$@"
	else
		"$@"
	fi
}

buildAndInstallParu() {
	if [ "$InstallUser" = "root" ]; then
		echo "ERROR: Cannot build paru as root. Run this script through sudo from the target user." >&2
		exit 1
	fi
	local paruBuildDir="$InstallHome/.cache/paru-build"
	rm -rf "$paruBuildDir"
	mkdir -p "$InstallHome/.cache"
	chown "$InstallUser:$InstallGroup" "$InstallHome/.cache"
	runAsInstallUser git clone "https://aur.archlinux.org/paru.git" "$paruBuildDir"
	runAsInstallUser sh -lc 'cd "'"$paruBuildDir"'" && makepkg -s --noconfirm'
	local paruPackages=("$paruBuildDir"/*.pkg.tar.zst)
	pacman -U --noconfirm "${paruPackages[@]}" || { echo "ERROR: Failed to install paru package. Aborting." >&2; exit 1; }
	rm -rf "$paruBuildDir"
}

ensureParuWorks() {
	if [ ! -x /usr/bin/paru ]; then
		echo -e "Paru ${Fail}not${END} found, ${Install}installing${END}."
		buildAndInstallParu
	else
		echo -e "Paru ${Success}installed${END}."
	fi
}

installRepoPackages() {
	# Install official-repo packages as root via pacman.
	local pkgs=()
	local pkg
	for pkg in "$@"; do
		if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
			pkgs+=("$pkg")
		fi
	done
	if [ "${#pkgs[@]}" -eq 0 ]; then
		echo -e "All packages already ${Success}installed${END}."
		return
	fi
	echo -e "Installing: ${Install}${pkgs[*]}${END}"
	pacman -S --needed --noconfirm "${pkgs[@]}" || { echo "ERROR: Failed to install package group: ${pkgs[*]}" >&2; exit 1; }
}

installAurPackages() {
	# Install AUR packages as the target user via paru.
	ensureParuWorks
	local pkgs=()
	local pkg
	for pkg in "$@"; do
		if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
			pkgs+=("$pkg")
		fi
	done
	if [ "${#pkgs[@]}" -eq 0 ]; then
		echo -e "All packages already ${Success}installed${END}."
		return
	fi
	echo -e "Installing: ${Install}${pkgs[*]}${END}"
	if [ "$InstallUser" = "root" ]; then
		echo "ERROR: Cannot install AUR packages as root through paru. Run through sudo from the target user." >&2
		exit 1
	fi
	runAsInstallUser paru -S --needed --noconfirm --skipreview "${pkgs[@]}" || { echo "ERROR: Failed to install AUR package group: ${pkgs[*]}" >&2; exit 1; }
}

handleRemove() {
	local pkg="$1"
	if pacman -Qq "$pkg" >/dev/null 2>&1; then
		echo -e "$pkg ${Install}installed${END}, ${Fail}removing${END}."
		pacman -Rns --noconfirm "$pkg" || echo "Could not remove $pkg; continuing."
	else
		echo -e "$pkg ${Success}not installed${END}."
	fi
}

waitForHyprlandExit() {
	local pid="$1"
	local attempts=0

	while kill -0 "$pid" >/dev/null 2>&1 && [ "$attempts" -lt 30 ]; do
		sleep 1
		attempts=$((attempts + 1))
	done

	if kill -0 "$pid" >/dev/null 2>&1; then
		echo "Hyprland did not exit after hyprshutdown; stopping first-run session."
		kill "$pid" >/dev/null 2>&1 || true
	fi

	wait "$pid" 2>/dev/null || true
}

configureNvidiaKernel() {
	echo "Configure NVIDIA kernel parameters and suspend services"
	local modprobe_conf="/etc/modprobe.d/nvidia.conf"

	if [ ! -f "$modprobe_conf" ] || ! grep -q 'modeset=1' "$modprobe_conf"; then
		cat > "$modprobe_conf" <<'EOF'
# Hyprland/Wayland requires DRM kernel mode-setting
options nvidia-drm modeset=1
# Preserve VRAM allocations across suspend/resume to prevent freeze on wake
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
		echo "Written $modprobe_conf"
	fi

	echo "Enabling NVIDIA suspend/resume/hibernate services"
	systemctl enable nvidia-suspend.service \
	                nvidia-resume.service \
	                nvidia-hibernate.service || \
		echo "WARNING: One or more NVIDIA power services not found; they may appear after reboot." >&2
}

configureNvidiaInitramfs() {
	local current_modules
	local modules_text
	local module
	local nvidia_modules=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

	echo "Configure NVIDIA modules in mkinitcpio"
	touch "$MkinitcpioConfig"
	current_modules="$(grep -E '^\s*MODULES=' "$MkinitcpioConfig" | head -n 1)"

	if [ -n "$current_modules" ]; then
		modules_text="$(printf '%s\n' "$current_modules" | sed -E 's/^[[:space:]]*MODULES=\(([^)]*)\).*/\1/')"
	else
		modules_text=""
	fi

	for module in "${nvidia_modules[@]}"; do
		if ! printf ' %s ' "$modules_text" | grep -q " $module "; then
			modules_text="$modules_text $module"
		fi
	done

	modules_text="$(printf '%s\n' "$modules_text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
	if grep -qE '^\s*MODULES=' "$MkinitcpioConfig"; then
		sed -i -E "0,/^[[:space:]]*MODULES=/{s|^[[:space:]]*MODULES=.*|MODULES=($modules_text)|}" "$MkinitcpioConfig"
	else
		echo "MODULES=($modules_text)" | tee -a "$MkinitcpioConfig" >/dev/null
	fi

	mkinitcpio -P
}

setNvidiaPersistenceMode() {
	echo "Set NVIDIA persistence mode"
	if ! command -v nvidia-smi >/dev/null 2>&1; then
		echo "nvidia-smi not found; skipping NVIDIA persistence mode."
		return
	fi

	timeout 10s nvidia-smi -pm 1 || echo "Skipping NVIDIA persistence mode; the driver may need a reboot."
}

setNvidiaPowerMizerMode() {
	# NOTE: nvidia-settings requires a running display (X or Wayland).
	# This function is only callable from within an active graphical session.
	# Use setNvidiaPowerMizerModeInHyprland for post-install headless dispatch,
	# or setNvidiaPersistenceMode (nvidia-smi) for headless power state control.
	echo "Set NVIDIA PowerMizer max performance mode"
	if ! command -v nvidia-settings >/dev/null 2>&1; then
		echo "nvidia-settings not found; skipping NVIDIA PowerMizer mode."
		return
	fi
	if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
		echo "No display session detected; skipping NVIDIA PowerMizer mode (needs active display)."
		return
	fi

	timeout 10s nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" || echo "Skipping NVIDIA PowerMizer mode; NVIDIA control display is unavailable."
}

setNvidiaPowerMizerModeInHyprland() {
	echo "Set NVIDIA PowerMizer max performance mode in Hyprland"
	if ! command -v nvidia-settings >/dev/null 2>&1; then
		echo "nvidia-settings not found; skipping NVIDIA PowerMizer mode."
		return
	fi

	if runAsInstallUser hyprctl --instance 0 dispatch exec "sh -lc 'timeout 10s nvidia-settings -a \"[gpu:0]/GpuPowerMizerMode=1\"'" >/dev/null 2>&1; then
		sleep 2
	else
		echo "Hyprland control socket unavailable; skipping NVIDIA PowerMizer mode."
	fi
}

copySshKeysFromUsb() {
	local usb_device
	local mount_point="/tmp/zerth-ssh-usb"
	local source_ssh
	local target_ssh="$InstallHome/.ssh"

	echo -e "${Title}Copying SSH Keys${END}"

	# Auto-detect the first removable partition (USB drive)
	usb_device="$(lsblk -rno NAME,RM,TYPE | awk '$2=="1" && $3=="part" {print "/dev/" $1; exit}')"

	if [ -z "$usb_device" ]; then
		echo "No removable partition auto-detected."
		read -r -p "Enter the USB device partition (e.g. /dev/sdb1), or press Enter to skip: " usb_device
		if [ -z "$usb_device" ]; then
			echo "Skipping SSH key copy."
			return
		fi
	else
		echo "Detected USB device: $usb_device"
		read -r -p "Press Enter to mount $usb_device and copy .ssh, or Ctrl+C to abort."
	fi

	source_ssh="$mount_point/.ssh"

	mkdir -p "$mount_point"
	if ! mount "$usb_device" "$mount_point"; then
		echo "Could not mount $usb_device; skipping SSH key copy."
		rmdir "$mount_point"
		return
	fi

	if [ -d "$source_ssh" ]; then
		mkdir -p "$target_ssh"
		if cp -a "$source_ssh/." "$target_ssh/"; then
			chmod 700 "$target_ssh"
			find "$target_ssh" -type d -exec chmod 700 {} +
			find "$target_ssh" -type f -exec chmod 600 {} +
			if [ "$InstallUser" != "root" ]; then
				chown -R "$InstallUser:$InstallGroup" "$target_ssh"
			fi
			echo "SSH keys copied to $target_ssh."
		else
			echo "Failed to copy SSH keys to $target_ssh."
		fi
	else
		echo "No .ssh folder found at the root of $usb_device; skipping SSH key copy."
	fi

	umount "$mount_point"
	rmdir "$mount_point"
}

ensureHyprLine() {
	local line="$1"
	local config="$2"

	if ! grep -qxF "$line" "$config"; then
		printf '%s\n' "$line" >> "$config"
	fi
}

setHyprBlockOption() {
	local block="$1"
	local option="$2"
	local value="$3"
	local config="$4"
	local block_regex
	local option_regex

	block_regex="$(printf '%s\n' "$block" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"
	option_regex="$(printf '%s\n' "$option" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"

	if grep -qE "^[[:space:]]*${block_regex}[[:space:]]*[{]" "$config"; then
		if sed -n -E "/^[[:space:]]*${block_regex}[[:space:]]*[{]/,/^[[:space:]]*[}]/p" "$config" | grep -qE "^[[:space:]]*${option_regex}[[:space:]]*="; then
			sed -i -E "/^[[:space:]]*${block_regex}[[:space:]]*[{]/,/^[[:space:]]*[}]/ s|^[[:space:]]*${option_regex}[[:space:]]*=.*|    $option = $value|" "$config"
		else
			sed -i -E "/^[[:space:]]*${block_regex}[[:space:]]*[{]/a\\    $option = $value" "$config"
		fi
	else
		printf '\n%s {\n    %s = %s\n}\n' "$block" "$option" "$value" >> "$config"
	fi
}

configureManualMonitorLayout() {
	local config="$1"
	local primary_output="${ZERTH_HYPR_PRIMARY_OUTPUT:-${ZERTH_HYPR_MONITOR_OUTPUT:-DP-3}}"
	local primary_mode="${ZERTH_HYPR_PRIMARY_MODE:-${ZERTH_HYPR_MONITOR_MODE:-3440x1440@120}}"
	local primary_position="${ZERTH_HYPR_PRIMARY_POSITION:-${ZERTH_HYPR_MONITOR_POSITION:-0x0}}"
	local primary_scale="${ZERTH_HYPR_PRIMARY_SCALE:-${ZERTH_HYPR_MONITOR_SCALE:-1}}"
	local portrait_output="${ZERTH_HYPR_PORTRAIT_OUTPUT:-DP-2}"
	local portrait_mode="${ZERTH_HYPR_PORTRAIT_MODE:-2560x1440@144}"
	local portrait_position="${ZERTH_HYPR_PORTRAIT_POSITION:--1440x-560}"
	local portrait_scale="${ZERTH_HYPR_PORTRAIT_SCALE:-1}"
	local portrait_transform="${ZERTH_HYPR_PORTRAIT_TRANSFORM:-1}"

	sed -i -E '/^[[:space:]]*monitor[[:space:]]*=[[:space:]]*,[[:space:]]*preferred[[:space:]]*,[[:space:]]*auto[[:space:]]*,[[:space:]]*(auto|1)[[:space:]]*$/d' "$config"
	sed -i '/^# Zerth manual monitor layout start$/,/^# Zerth manual monitor layout end$/d' "$config"
	sed -i '/^# Zerth Samsung OLED G8 monitor start$/,/^# Zerth Samsung OLED G8 monitor end$/d' "$config"

	{
		printf '\n# Zerth manual monitor layout start\n'
		printf '# Manual monitor configuration is intentional; do not fall back to auto.\n'
		printf '# Primary: Samsung Odyssey G8 ultrawide, HDR, 3440x1440.\n'
		printf '# Portrait: LG 27GL850, SDR/sRGB, 2560x1440 rotated clockwise into 1440x2560, left of primary.\n'
		printf '# Override outputs/modes before running if connector names change:\n'
		printf '# ZERTH_HYPR_PRIMARY_OUTPUT=DP-3 ZERTH_HYPR_PORTRAIT_OUTPUT=DP-2\n'
		printf 'monitorv2 {\n'
		printf '    output = %s\n' "$primary_output"
		printf '    mode = %s\n' "$primary_mode"
		printf '    position = %s\n' "$primary_position"
		printf '    scale = %s\n' "$primary_scale"
		printf '    bitdepth = 10\n'
		printf '    cm = hdr\n'
		printf '    sdrbrightness = 1.2\n'
		printf '    sdrsaturation = 1.0\n'
		printf '    sdr_min_luminance = 0.005\n'
		printf '    sdr_max_luminance = 250\n'
		printf '    sdr_eotf = srgb\n'
		printf '    vrr = 1\n'
		printf '    supports_wide_color = 1\n'
		printf '    supports_hdr = 1\n'
		printf '}\n\n'
		printf 'monitorv2 {\n'
		printf '    output = %s\n' "$portrait_output"
		printf '    mode = %s\n' "$portrait_mode"
		printf '    position = %s\n' "$portrait_position"
		printf '    scale = %s\n' "$portrait_scale"
		printf '    transform = %s\n' "$portrait_transform"
		printf '    cm = srgb\n'
		printf '    sdrbrightness = 1.0\n'
		printf '    sdrsaturation = 1.0\n'
		printf '    vrr = 0\n'
		printf '    supports_wide_color = 0\n'
		printf '    supports_hdr = 0\n'
		printf '}\n'
		printf '# Zerth manual monitor layout end\n'
	} >> "$config"
}

configureHyprpaperConfig() {
	local config="$InstallHome/.config/hypr/hyprpaper.conf"
	local wallpaper_dir="$InstallHome/Pictures/Wallpapers/AncientMegaliths"
	local repo_wallpaper_dir="$ScriptDir/wallpapers/ancient-megaliths"
	local default_wallpaper="$wallpaper_dir/lapis-obscura-ancient-megalith-world-01.png"
	local ultrawide_wallpaper="${ZERTH_HYPRPAPER_ULTRAWIDE_WALLPAPER:-$default_wallpaper}"
	local portrait_wallpaper="${ZERTH_HYPRPAPER_PORTRAIT_WALLPAPER:-$wallpaper_dir/lapis-obscura-ancient-megalith-temple-01.png}"
	local wallpaper="${ZERTH_HYPRPAPER_WALLPAPER:-$default_wallpaper}"
	local ultrawide_output="${ZERTH_HYPRPAPER_ULTRAWIDE_OUTPUT:-${ZERTH_HYPR_PRIMARY_OUTPUT:-DP-3}}"
	local portrait_output="${ZERTH_HYPRPAPER_PORTRAIT_OUTPUT:-${ZERTH_HYPR_PORTRAIT_OUTPUT:-DP-2}}"
	local wp
	local wallpapers=()

	echo "Configure Hyprpaper"
	mkdir -p "$InstallHome/.config/hypr" "$wallpaper_dir"

	if [ -d "$repo_wallpaper_dir" ]; then
		cp -f "$repo_wallpaper_dir"/* "$wallpaper_dir"/ 2>/dev/null || true
	else
		echo "No Ancient Megalith wallpapers found in $repo_wallpaper_dir; Hyprpaper will reference $wallpaper."
	fi

	shopt -s nullglob
	wallpapers=("$wallpaper_dir"/*.png "$wallpaper_dir"/*.jpg "$wallpaper_dir"/*.jpeg "$wallpaper_dir"/*.webp)
	shopt -u nullglob

	if [ "${#wallpapers[@]}" -eq 0 ]; then
		echo "No Ancient Megalith wallpapers found; Hyprpaper will reference $wallpaper."
	fi

	{
		printf '# Zerth Ancient Megaliths wallpaper section\n'
		printf '# Source assets: %s/wallpapers/ancient-megaliths\n' "$ScriptDir"
		printf '# Saved locally: %s\n' "$wallpaper_dir"
		printf '# Fit mode: cover = crop to fill the screen\n'
		printf '# Override default wallpaper before running with:\n'
		printf '# ZERTH_HYPRPAPER_WALLPAPER=/path/to/wallpaper.png\n'
		printf '# Optional dual-monitor outputs default to DP-3 ultrawide and DP-2 portrait:\n'
		printf '# ZERTH_HYPRPAPER_ULTRAWIDE_OUTPUT=DP-3\n'
		printf '# ZERTH_HYPRPAPER_PORTRAIT_OUTPUT=DP-2\n'
		printf 'splash = false\n'
		printf 'ipc = true\n\n'
		for wp in "${wallpapers[@]}"; do
			printf 'preload = %s\n' "$wp"
		done
		if [ "${#wallpapers[@]}" -eq 0 ]; then
			printf 'preload = %s\n' "$wallpaper"
		fi
		printf '\n'
		if [ -n "$ultrawide_output" ]; then
			printf 'wallpaper {\n'
			printf '    monitor = %s\n' "$ultrawide_output"
			printf '    path = %s\n' "$ultrawide_wallpaper"
			printf '    fit_mode = cover\n'
			printf '}\n\n'
		fi
		if [ -n "$portrait_output" ]; then
			printf 'wallpaper {\n'
			printf '    monitor = %s\n' "$portrait_output"
			printf '    path = %s\n' "$portrait_wallpaper"
			printf '    fit_mode = cover\n'
			printf '}\n\n'
		fi
		printf 'wallpaper {\n'
		printf '    monitor = \n'
		printf '    path = %s\n' "$wallpaper"
		printf '    fit_mode = cover\n'
		printf '}\n'
	} > "$config"

	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$config" "$wallpaper_dir" "$InstallHome/Pictures"
	fi
}

configureEwwConfig() {
	local config_dir="$InstallHome/.config/eww"
	local yuck="$config_dir/eww.yuck"
	local scss="$config_dir/eww.scss"
	local status_script="$config_dir/zerth-status.sh"

	echo "Configure Eww overlay"
	mkdir -p "$config_dir"
	cat > "$status_script" <<'EOF'
#! /usr/bin/env bash

case "$1" in
	time)
		date '+%H:%M:%S'
		;;
	date)
		date '+%a %d %b'
		;;
	audio)
		if command -v wpctl >/dev/null 2>&1; then
			status="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)"
			volume="$(printf '%s\n' "$status" | awk '{printf "%d", $2 * 100}')"
			if printf '%s\n' "$status" | grep -q MUTED; then
				printf 'MUTE %s%%\n' "$volume"
			else
				printf 'VOL %s%%\n' "$volume"
			fi
		else
			printf 'VOL --\n'
		fi
		;;
	network)
		if command -v nmcli >/dev/null 2>&1; then
			nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1 == "yes" && $2 != "" {print "NET " $2; found=1; exit} END {if (!found) print "NET --"}'
		else
			printf 'NET --\n'
		fi
		;;
	workspace)
		if command -v hyprctl >/dev/null 2>&1; then
			hyprctl activeworkspace 2>/dev/null | awk -F': ' '/workspace ID/ {print "WS " $2; found=1; exit} END {if (!found) print "WS --"}'
		else
			printf 'WS --\n'
		fi
		;;
	memory)
		free -h 2>/dev/null | awk '/^Mem:/ {print "MEM " $3 "/" $2}'
		;;
	cpu)
		awk '{printf "CPU %.2f %.2f %.2f\n", $1, $2, $3}' /proc/loadavg
		;;
	cpu-pct)
		awk 'NR==1 {idle1=$5; total1=0; for (i=2; i<=NF; i++) total1+=$i} END {printf "%d\n", 0}' /proc/stat >/dev/null
		read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
		total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
		idle1=$((idle + iowait))
		sleep 0.2
		read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
		total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
		idle2=$((idle + iowait))
		dtotal=$((total2 - total1))
		didle=$((idle2 - idle1))
		if [ "$dtotal" -gt 0 ]; then
			printf '%d\n' $(((100 * (dtotal - didle)) / dtotal))
		else
			printf '0\n'
		fi
		;;
	mem-pct)
		free | awk '/^Mem:/ {printf "%d\n", ($3 / $2) * 100}'
		;;
	disk-pct)
		df -P "$HOME" | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
		;;
	gpu-pct)
		if command -v nvidia-smi >/dev/null 2>&1; then
			nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n 1
		else
			printf '0\n'
		fi
		;;
	top-proc)
		ps -eo comm=,%cpu= --sort=-%cpu 2>/dev/null | awk 'NF {printf "%s %s%%\n", $1, $2; exit}'
		;;
	uptime)
		uptime -p 2>/dev/null | sed 's/^up //'
		;;
	disk-free)
		df -hP "$HOME" | awk 'NR==2 {printf "%s free / %s\n", $4, $2}'
		;;
	gpu-temp)
		if command -v nvidia-smi >/dev/null 2>&1; then
			nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1 {print $1 "C"}'
		else
			printf -- '--\n'
		fi
		;;
	vram)
		if command -v nvidia-smi >/dev/null 2>&1; then
			nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | awk -F', ' 'NR==1 {printf "%s/%s MiB\n", $1, $2}'
		else
			printf -- '--\n'
		fi
		;;
	*)
		printf -- '--\n'
		;;
esac
EOF
	chmod 755 "$status_script"

	cat > "$yuck" <<EOF
(defpoll zerth_time :interval "1s" "$status_script time")
(defpoll zerth_date :interval "60s" "$status_script date")
(defpoll zerth_audio :interval "2s" "$status_script audio")
(defpoll zerth_network :interval "5s" "$status_script network")
(defpoll zerth_workspace :interval "1s" "$status_script workspace")
(defpoll zerth_memory :interval "3s" "$status_script memory")
(defpoll zerth_cpu :interval "3s" "$status_script cpu")
(defpoll zerth_cpu_pct :interval "2s" "$status_script cpu-pct")
(defpoll zerth_mem_pct :interval "3s" "$status_script mem-pct")
(defpoll zerth_disk_pct :interval "15s" "$status_script disk-pct")
(defpoll zerth_gpu_pct :interval "3s" "$status_script gpu-pct")
(defpoll zerth_top_proc :interval "3s" "$status_script top-proc")
(defpoll zerth_uptime :interval "60s" "$status_script uptime")
(defpoll zerth_disk_free :interval "30s" "$status_script disk-free")
(defpoll zerth_gpu_temp :interval "5s" "$status_script gpu-temp")
(defpoll zerth_vram :interval "5s" "$status_script vram")

(defwindow zerth_overlay
  :monitor 0
  :geometry (geometry :x "0%" :y "0%" :width "100%" :height "100%" :anchor "top left")
  :stacking "overlay"
  :exclusive false
  :focusable false
  (zerth_screen))

(defwidget zerth_readout [label value]
  (box :class "readout" :orientation "h" :space-evenly false
    (label :class "readout-key" :text label)
    (label :class "readout-value" :text value)))

(defwidget zerth_button [label command]
  (button :class "stone-button" :onclick command label))

(defwidget zerth_metric [name value]
  (box :class "metric" :orientation "v" :space-evenly false
    (box :orientation "h" :space-evenly false
      (label :class "metric-name" :halign "start" :text name)
      (label :class "metric-value" :halign "end" :text "\${value}%"))
    (progress :class "metric-bar" :value value :max 100)))

(defwidget zerth_info_row [label value]
  (box :class "info-row" :orientation "h" :space-evenly false
    (label :class "info-label" :halign "start" :text label)
    (label :class "info-value" :halign "end" :text value)))

(defwidget zerth_system_panel []
  (box :class "console-card system-card" :orientation "v" :space-evenly false
    (label :class "console-title" :halign "start" :text "◇ SYSTEM")
    (label :class "console-subtitle" :halign "start" :text "STONE TELEMETRY")
    (box :class "metric-grid" :orientation "h" :space-evenly false
      (box :class "metric-column" :orientation "v" :space-evenly false
        (zerth_metric :name "CPU" :value zerth_cpu_pct)
        (zerth_metric :name "MEM" :value zerth_mem_pct))
      (box :class "metric-column" :orientation "v" :space-evenly false
        (zerth_metric :name "GPU" :value zerth_gpu_pct)
        (zerth_metric :name "DSK" :value zerth_disk_pct)))
    (box :class "system-info" :orientation "v" :space-evenly false
      (zerth_info_row :label "LOAD" :value zerth_cpu)
      (zerth_info_row :label "UP" :value zerth_uptime)
      (zerth_info_row :label "RAM" :value zerth_memory)
      (zerth_info_row :label "DISK" :value zerth_disk_free)
      (zerth_info_row :label "GPU" :value zerth_gpu_temp)
      (zerth_info_row :label "VRAM" :value zerth_vram)
      (zerth_info_row :label "NET" :value zerth_network)
      (zerth_info_row :label "AUDIO" :value zerth_audio)
      (zerth_info_row :label "TOP" :value zerth_top_proc))))

(defwidget zerth_screen []
  (box :class "screen-dim" :orientation "v" :space-evenly false
    (box :class "stone-panel top-panel" :orientation "h" :space-evenly false :halign "start"
      (label :class "sigil" :text "◇ ZERTH")
      (zerth_readout :label "TIME" :value zerth_time)
      (zerth_readout :label "DATE" :value zerth_date)
      (zerth_readout :label "AUDIO" :value zerth_audio)
      (zerth_readout :label "NET" :value zerth_network)
      (zerth_readout :label "LOAD" :value zerth_cpu)
      (zerth_readout :label "MEM" :value zerth_memory)
      (zerth_readout :label "SPACE" :value zerth_workspace))
    (box :class "desk" :orientation "h" :space-evenly false
      (zerth_system_panel))
    (box :class "spacer")
    (box :class "stone-panel control-panel" :orientation "h" :space-evenly false :halign "start"
      (zerth_button :label "-VOL" :command "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
      (zerth_button :label "MUTE" :command "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
      (zerth_button :label "+VOL" :command "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
      (zerth_button :label "TERM" :command "foot")
      (zerth_button :label "MENU" :command "fuzzel")
      (zerth_button :label "FILES" :command "pcmanfm-qt"))))
EOF

	cat > "$scss" <<'EOF'
/* Lapis Obscura: dark stone first; accents as mineral signal. */
* {
  all: unset;
  font-family: "ProggyClean", "Terminus", monospace;
  font-size: 16px;
}

.screen-dim {
  background-color: rgba(5, 4, 8, 0.82);
  color: #c8c8d0;
}

.stone-panel {
  margin: 21px;
  padding: 8px 13px;
  background-color: rgba(9, 8, 18, 0.96);
  border: 1px solid #24212c;
  box-shadow: inset 0 0 0 1px #111016;
}

.top-panel {
  border-color: #55515d;
}

.desk {
  margin: 0 21px;
}

.console-card {
  min-width: 560px;
  margin-right: 21px;
  padding: 21px;
  background-color: rgba(13, 11, 24, 0.97);
  border: 1px solid #24212c;
  box-shadow: inset 0 0 0 1px #111016;
}

.console-title {
  color: #d8a657;
  font-size: 21px;
  letter-spacing: 2px;
}

.console-subtitle {
  margin-top: 8px;
  color: #918999;
}

.console-launch {
  margin-top: 13px;
  padding: 5px 13px;
  color: #c8c8d0;
  background-color: #111016;
  border: 1px solid #24212c;
}

.console-launch:hover {
  color: #e4e0e8;
  background-color: #171522;
  border-color: #d8a657;
}

.metric {
  margin-top: 13px;
}

.metric-name {
  min-width: 42px;
  color: #918999;
}

.metric-value {
  min-width: 44px;
  color: #c8c8d0;
}

.metric-bar {
  margin-top: 5px;
  min-height: 8px;
}

.metric-bar trough {
  background-color: #050408;
  border: 1px solid #24212c;
}

.metric-bar progress {
  background-color: #d8a657;
  border-right: 1px solid #fabd2f;
}

.metric-grid {
  margin-top: 8px;
}

.metric-column {
  min-width: 245px;
  margin-right: 21px;
}

.system-info {
  margin-top: 13px;
  padding: 13px;
  background-color: #090812;
  border: 1px solid #24212c;
}

.info-row {
  margin-top: 5px;
}

.info-label {
  min-width: 58px;
  color: #918999;
}

.info-value {
  color: #c8c8d0;
}

.control-panel {
  margin-bottom: 34px;
}

.sigil {
  margin-right: 13px;
  padding: 3px 8px;
  color: #e4e0e8;
  background-color: #171522;
  border: 1px solid #d8a657;
}

.readout {
  margin-right: 8px;
  padding: 3px 8px;
  background-color: #0d0b18;
  border: 1px solid #24212c;
}

.readout-key {
  margin-right: 5px;
  color: #918999;
}

.readout-value {
  color: #c8c8d0;
}

.stone-button {
  margin-right: 8px;
  padding: 5px 13px;
  color: #c8c8d0;
  background-color: #0d0b18;
  border: 1px solid #24212c;
}

.stone-button:hover {
  color: #e4e0e8;
  background-color: #171522;
  border-color: #d8a657;
}

.stone-button:active {
  color: #050408;
  background-color: #d8a657;
  border-color: #fabd2f;
}

.spacer {
  min-height: 1px;
}
EOF

	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$config_dir"
	fi
}

configureHypridleConfig() {
	local config="$InstallHome/.config/hypr/hypridle.conf"

	echo "Configure Hypridle"
	mkdir -p "$InstallHome/.config/hypr"
	if [ ! -f "$config" ]; then
		cat > "$config" <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 360
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}

listener {
    timeout = 1800
    on-timeout = systemctl suspend
}
EOF
		echo "Written $config"
	fi
	if [ "$InstallUser" != "root" ]; then
		chown "$InstallUser:$InstallGroup" "$config"
	fi
}

configureHyprlockConfig() {
	local config="$InstallHome/.config/hypr/hyprlock.conf"

	echo "Configure Hyprlock Lapis Obscura sealed-gate theme"
	mkdir -p "$InstallHome/.config/hypr"
	cat > "$config" <<'EOF'
# Zerth Lapis Obscura hyprlock theme.
# Void background, centered sigil/gate, muted stone text, gold focus, rust failure.
general {
    hide_cursor = true
}

animations {
    enabled = false
}

background {
    monitor =
    color = rgba(050408ff)
}

# Quiet seal glyph: a single diamond/gate suspended in the void.
label {
    monitor =
    text = ◇
    color = rgba(d8a657ff)
    font_size = 54
    font_family = ProggyClean, Terminus, monospace
    position = 0, 92
    halign = center
    valign = center
}

label {
    monitor =
    text = SEALED GATE
    color = rgba(918999ff)
    font_size = 13
    font_family = ProggyClean, Terminus, monospace
    position = 0, 36
    halign = center
    valign = center
}

input-field {
    monitor =
    size = 340, 42
    position = 0, -34
    halign = center
    valign = center
    outline_thickness = 1
    outer_color = rgba(d8a657ff)
    inner_color = rgba(111016ee)
    font_color = rgba(e4e0e8ff)
    check_color = rgba(98971aff)
    fail_color = rgba(cc241dff)
    placeholder_text = <span foreground="##918999">passphrase</span>
    hide_input = false
    dots_size = 0.18
    dots_spacing = 0.18
    fade_on_empty = false
}

label {
    monitor =
    text = cmd[update:1000] date +"%H:%M:%S"
    color = rgba(c8c8d0ff)
    font_size = 21
    font_family = ProggyClean, Terminus, monospace
    position = 0, -104
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:60000] date +"%a %d %b"
    color = rgba(918999ff)
    font_size = 13
    font_family = ProggyClean, Terminus, monospace
    position = 0, -134
    halign = center
    valign = center
}
EOF
	echo "Written $config"
	if [ "$InstallUser" != "root" ]; then
		chown "$InstallUser:$InstallGroup" "$config"
	fi
}

configureGithubVault() {
	local github_user="${ZERTH_GITHUB_USER:-TheZerth}"
	local vault_name="${ZERTH_VAULT_REPO:-vault}"
	local vault_dir="${ZERTH_VAULT_DIR:-$InstallHome/vault}"
	local vault_https="https://github.com/$github_user/$vault_name.git"
	local vault_ssh="git@github.com:$github_user/$vault_name.git"
	local bin_dir="$InstallHome/.local/bin"
	local config_dir="$InstallHome/.config"
	local backup_conf="$config_dir/vault-backup.conf"
	local backup_script="$bin_dir/vault-backup"
	local seal_ssh_script="$bin_dir/vault-seal-ssh"
	local service_unit="/etc/systemd/system/vault-backup@.service"
	local timer_unit="/etc/systemd/system/vault-backup@.timer"
	local escaped_timer
	local answer

	echo -e "${Title}Configuring GitHub Vault${END}"
	if [ "$InstallUser" = "root" ]; then
		echo "Skipping GitHub vault setup because no non-root install user was detected."
		return
	fi

	mkdir -p "$bin_dir" "$config_dir"

	cat > "$backup_conf" <<EOF
# GitHub vault backup settings.
# Repo defaults to: $vault_https
VAULT_DIR="$vault_dir"
VAULT_REMOTE_HTTPS="$vault_https"
VAULT_REMOTE_SSH="$vault_ssh"

# Optional: set to an age public recipient for non-interactive encrypted archives.
# Generate one with: age-keygen -o ~/.config/vault-age-identity.txt
# Then copy the public key printed by age-keygen here.
# VAULT_AGE_RECIPIENT="age1..."

# Add small important paths here, one per line. Environment variables are expanded.
VAULT_INCLUDE_FILE="$InstallHome/.config/vault-backup-paths"
EOF

	if [ ! -f "$InstallHome/.config/vault-backup-paths" ]; then
		cat > "$InstallHome/.config/vault-backup-paths" <<'EOF'
# One path per line. Blank lines and # comments are ignored.
# Examples:
# $HOME/Documents/Obsidian
# $HOME/.local/share/Steam/userdata/YOUR_STEAM_ID/APP_ID
EOF
	fi

	cat > "$backup_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

Conf="$HOME/.config/vault-backup.conf"
if [ -f "$Conf" ]; then
	# shellcheck disable=SC1090
	. "$Conf"
fi

VaultDir="${VAULT_DIR:-$HOME/vault}"
IncludeFile="${VAULT_INCLUDE_FILE:-$HOME/.config/vault-backup-paths}"
Timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
Host="$(hostname 2>/dev/null || printf unknown)"

if [ ! -d "$VaultDir/.git" ]; then
	echo "Vault repo not found at $VaultDir" >&2
	exit 1
fi

mkdir -p "$VaultDir/backups/hermes" "$VaultDir/backups/files" "$VaultDir/secrets"

if [ -f "$IncludeFile" ]; then
	while IFS= read -r raw_path || [ -n "$raw_path" ]; do
		case "$raw_path" in
			''|'#'*) continue ;;
		esac
		expanded_path="$(eval "printf '%s' \"$raw_path\"")"
		if [ ! -e "$expanded_path" ]; then
			echo "Skipping missing path: $expanded_path"
			continue
		fi
		name="$(printf '%s' "$expanded_path" | sed "s|^$HOME|HOME|; s|^/||; s|/|__|g")"
		archive="$VaultDir/backups/files/${Host}-${name}-${Timestamp}.tar.gz"
		tar -C "$(dirname "$expanded_path")" -czf "$archive" "$(basename "$expanded_path")"
		if [ -n "${VAULT_AGE_RECIPIENT:-}" ]; then
			age -r "$VAULT_AGE_RECIPIENT" -o "$archive.age" "$archive"
			rm -f "$archive"
		fi
	done < "$IncludeFile"
fi

cd "$VaultDir"
git pull --rebase --autostash || true
git add -A
if git diff --cached --quiet; then
	echo "No vault changes to back up."
	exit 0
fi
git commit -m "vault backup $Timestamp"
git push
EOF
	chmod 755 "$backup_script"

	cat > "$seal_ssh_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VaultDir="${VAULT_DIR:-$HOME/vault}"
SecretOut="$VaultDir/secrets/ssh.tar.age"
mkdir -p "$VaultDir/secrets"
if [ ! -d "$HOME/.ssh" ]; then
	echo "No ~/.ssh directory found." >&2
	exit 1
fi
printf 'This will encrypt selected SSH files into %s\n' "$SecretOut"
printf 'Use a strong passphrase. You will need it on fresh installs.\n'
files=()
for f in id_ed25519 id_ed25519.pub config known_hosts; do
	[ -e "$HOME/.ssh/$f" ] && files+=("$f")
done
if [ "${#files[@]}" -eq 0 ]; then
	echo "No supported SSH files found to seal." >&2
	exit 1
fi
tar -C "$HOME/.ssh" -cf - "${files[@]}" | age -p -o "$SecretOut"
chmod 600 "$SecretOut"
cd "$VaultDir"
git add "$SecretOut"
git commit -m "update encrypted ssh secret" || true
git push
EOF
	chmod 755 "$seal_ssh_script"
	chown -R "$InstallUser:$InstallGroup" "$bin_dir" "$config_dir"

	cat > "$service_unit" <<'EOF'
[Unit]
Description=Push small-file backups to GitHub vault for %i
Documentation=man:systemd.service(5)

[Service]
Type=oneshot
User=%i
ExecStart=%h/.local/bin/vault-backup
EOF

	cat > "$timer_unit" <<'EOF'
[Unit]
Description=Daily GitHub vault backup for %i
Documentation=man:systemd.timer(5)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=45m
Unit=vault-backup@%i.service

[Install]
WantedBy=timers.target
EOF

	if ! runAsInstallUser gh auth status >/dev/null 2>&1; then
		echo "GitHub CLI is not authenticated for $InstallUser."
		read -r -p "Run 'gh auth login' now? This needs your GitHub login and 2FA. [y/N]: " answer
		case "$answer" in
			[Yy]*) runAsInstallUser gh auth login ;;
			*) echo "Skipping GitHub login. Vault scripts were still installed." ;;
		esac
	fi
	if runAsInstallUser gh auth status >/dev/null 2>&1; then
		runAsInstallUser gh auth setup-git || true
	fi

	if [ ! -d "$vault_dir/.git" ] && runAsInstallUser gh auth status >/dev/null 2>&1; then
		if runAsInstallUser gh repo view "$github_user/$vault_name" >/dev/null 2>&1; then
			runAsInstallUser git clone "$vault_https" "$vault_dir" || true
		else
			echo "GitHub repo $github_user/$vault_name does not exist or is not visible."
			read -r -p "Create private repo $github_user/$vault_name now? [y/N]: " answer
			case "$answer" in
				[Yy]*) runAsInstallUser gh repo create "$github_user/$vault_name" --private && runAsInstallUser git clone "$vault_https" "$vault_dir" ;;
				*) echo "Skipping vault repo creation/clone." ;;
			esac
		fi
	fi

	if [ -d "$vault_dir/.git" ]; then
		mkdir -p "$vault_dir/backups/hermes" "$vault_dir/backups/files" "$vault_dir/secrets"
		chown -R "$InstallUser:$InstallGroup" "$vault_dir"
		if [ -f "$vault_dir/secrets/ssh.tar.age" ] && [ ! -f "$InstallHome/.ssh/id_ed25519" ]; then
			read -r -p "Encrypted SSH secret found in vault. Restore it now? [y/N]: " answer
			case "$answer" in
				[Yy]*)
					mkdir -p "$InstallHome/.ssh"
					chown "$InstallUser:$InstallGroup" "$InstallHome/.ssh"
					runAsInstallUser sh -lc "age -d \"\$HOME/vault/secrets/ssh.tar.age\" | tar -C \"\$HOME/.ssh\" -xf -"
					chmod 700 "$InstallHome/.ssh"
					find "$InstallHome/.ssh" -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} +
					find "$InstallHome/.ssh" -type f -name '*.pub' -exec chmod 644 {} +
					[ -f "$InstallHome/.ssh/config" ] && chmod 600 "$InstallHome/.ssh/config"
					chown -R "$InstallUser:$InstallGroup" "$InstallHome/.ssh"
					# Keep the vault remote on HTTPS so gh-managed credentials can push
					# non-interactively. SSH remains available for manual git use after restore.
					;;
				*) echo "Skipping SSH restore." ;;
			esac
		fi
	fi

	systemctl daemon-reload
	escaped_timer="$(systemd-escape --template=vault-backup@.timer "$InstallUser")"
	systemctl enable --now "$escaped_timer" || echo "WARNING: Could not enable vault backup timer; run: systemctl enable --now $escaped_timer" >&2
}

configureHermesAgent() {
	local fish_conf_dir="$InstallHome/.config/fish/conf.d"
	local fish_path_conf="$fish_conf_dir/10-local-bin.fish"
	local profile="$InstallHome/.profile"
	local hermes_bin=""
	local hermes_vault_dir="$InstallHome/vault/backups/hermes"
	local latest_backup
	local restore_answer
	local tmp_restore

	echo -e "${Title}Configuring Hermes Agent${END}"
	if [ "$InstallUser" = "root" ]; then
		echo "Skipping Hermes user setup because no non-root install user was detected."
		return
	fi

	mkdir -p "$InstallHome/.local/bin" "$fish_conf_dir"
	if [ ! -f "$fish_path_conf" ] || ! grep -q 'fish_add_path.*\.local/bin' "$fish_path_conf"; then
		cat > "$fish_path_conf" <<'EOF'
# Keep user-installed CLI tools available.
fish_add_path -m ~/.local/bin
EOF
	fi
	if [ ! -f "$profile" ] || ! grep -q 'HOME/.local/bin' "$profile"; then
		cat >> "$profile" <<'EOF'

# User-installed CLI tools.
case ":$PATH:" in
	*:"$HOME/.local/bin":*) ;;
	*) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
EOF
	fi
	chown -R "$InstallUser:$InstallGroup" "$InstallHome/.local" "$InstallHome/.config/fish" "$profile"

	# Install Hermes Agent directly from git instead of the AUR package. The AUR
	# package can drift from upstream and has produced incomplete venv installs;
	# this keeps /opt/hermes-agent as the source checkout and installs the hermes
	# entry point into /opt/hermes-agent/venv/bin/hermes.
	local hermes_repo="${HERMES_AGENT_REPO_URL:-https://github.com/NousResearch/hermes-agent.git}"
	local hermes_ref="${HERMES_AGENT_REF:-main}"
	local hermes_dir="/opt/hermes-agent"
	# Avoid the [all] extra by default on Arch: it pulls the Matrix encryption
	# stack, whose python-olm/libolm build currently fails with modern CMake.
	# Override with HERMES_AGENT_EXTRAS=all if you explicitly want every extra.
	local hermes_extras="${HERMES_AGENT_EXTRAS:-modal,daytona,vercel,messaging,cron,cli,dev,tts-premium,slack,pty,honcho,mcp,homeassistant,sms,acp,voice,dingtalk,feishu,google,mistral,bedrock,web}"
	local hermes_update_script="/usr/local/sbin/update-hermes-agent"
	local hermes_update_service="/etc/systemd/system/hermes-agent-update.service"
	local hermes_update_timer="/etc/systemd/system/hermes-agent-update.timer"

	installRepoPackages git python python-pip
	if pacman -Qq hermes-agent >/dev/null 2>&1; then
		echo "Removing AUR hermes-agent package before installing from source."
		pacman -Rns --noconfirm hermes-agent || echo "WARNING: Could not remove AUR hermes-agent package; continuing with source install." >&2
	fi

	if [ -d "$hermes_dir/.git" ]; then
		git -C "$hermes_dir" fetch --quiet origin "$hermes_ref" || { echo "WARNING: Hermes git fetch failed; continuing." >&2; return; }
		git -C "$hermes_dir" checkout -q "$hermes_ref" || { echo "WARNING: Hermes checkout failed; continuing." >&2; return; }
		git -C "$hermes_dir" pull --ff-only || { echo "WARNING: Hermes git pull failed; continuing." >&2; return; }
	else
		rm -rf "$hermes_dir"
		git clone --branch "$hermes_ref" --depth 1 "$hermes_repo" "$hermes_dir" || { echo "WARNING: Hermes git clone failed; continuing." >&2; return; }
	fi

	if [ ! -f "$hermes_dir/pyproject.toml" ] && [ ! -f "$hermes_dir/setup.py" ]; then
		echo "WARNING: $hermes_dir is not a Python project; Hermes install skipped." >&2
		return
	fi

	python -m venv "$hermes_dir/venv" || { echo "WARNING: Could not create Hermes venv; continuing." >&2; return; }
	"$hermes_dir/venv/bin/python" -m ensurepip --upgrade || true
	"$hermes_dir/venv/bin/python" -m pip install --upgrade pip setuptools wheel || { echo "WARNING: Could not upgrade Hermes venv packaging tools; continuing." >&2; return; }
	"$hermes_dir/venv/bin/python" -m pip install -e "${hermes_dir}[${hermes_extras}]" || { echo "WARNING: Hermes source install failed; continuing." >&2; return; }
	ln -sf "$hermes_dir/venv/bin/hermes" /usr/local/bin/hermes

	cat > "$hermes_update_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

Repo="$hermes_dir"
Ref="$hermes_ref"
Extras="$hermes_extras"
Py="\$Repo/venv/bin/python"
HermesBin="\$Repo/venv/bin/hermes"

if [ ! -d "\$Repo/.git" ]; then
	echo "Hermes source checkout not found at \$Repo" >&2
	exit 1
fi

cd "\$Repo"
git fetch --quiet origin "\$Ref"
Local="\$(git rev-parse HEAD)"
Remote="\$(git rev-parse "origin/\$Ref")"

if [ "\$Local" = "\$Remote" ]; then
	echo "Hermes Agent already up to date: \$Local"
	exit 0
fi

echo "Updating Hermes Agent: \$Local -> \$Remote"
git checkout -q "\$Ref"
git pull --ff-only

"\$Py" -m ensurepip --upgrade || true
"\$Py" -m pip install --upgrade pip setuptools wheel
"\$Py" -m pip install -e ".[\$Extras]"
ln -sf "\$HermesBin" /usr/local/bin/hermes
"\$HermesBin" doctor || true
EOF
	chmod 755 "$hermes_update_script"

	cat > "$hermes_update_service" <<EOF
[Unit]
Description=Update Hermes Agent from git
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$hermes_update_script
EOF

	cat > "$hermes_update_timer" <<'EOF'
[Unit]
Description=Periodically update Hermes Agent from git

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true
RandomizedDelaySec=15m
Unit=hermes-agent-update.service

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload
	systemctl enable --now hermes-agent-update.timer || echo "WARNING: Could not enable Hermes update timer; run: systemctl enable --now hermes-agent-update.timer" >&2

	hermes_bin="$hermes_dir/venv/bin/hermes"
	if [ -x "$hermes_bin" ]; then
		runAsInstallUser sh -lc "export PATH=\"/usr/local/bin:\$HOME/.local/bin:\$PATH\"; hermes setup --non-interactive || true"
		runAsInstallUser sh -lc "export PATH=\"/usr/local/bin:\$HOME/.local/bin:\$PATH\"; hermes doctor || true"
		if [ -d "$hermes_vault_dir" ]; then
			latest_backup="$(find "$hermes_vault_dir" -maxdepth 1 -type f \( -name 'hermes-*.zip' -o -name 'hermes-*.zip.age' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
			if [ -n "$latest_backup" ]; then
				read -r -p "Hermes backup found in vault ($(basename "$latest_backup")). Import it now? [y/N]: " restore_answer
				case "$restore_answer" in
					[Yy]*)
						if printf '%s\n' "$latest_backup" | grep -q '\.age$'; then
							tmp_restore="$InstallHome/.cache/hermes-restore.zip"
							rm -f "$tmp_restore"
							if [ -f "$InstallHome/.config/vault-age-identity.txt" ]; then
								runAsInstallUser age -d -i "$InstallHome/.config/vault-age-identity.txt" -o "$tmp_restore" "$latest_backup"
							else
								runAsInstallUser age -d -o "$tmp_restore" "$latest_backup"
							fi
							runAsInstallUser sh -lc "export PATH=\"/usr/local/bin:\$HOME/.local/bin:\$PATH\"; hermes import '$tmp_restore' --force"
							rm -f "$tmp_restore"
						else
							runAsInstallUser sh -lc "export PATH=\"/usr/local/bin:\$HOME/.local/bin:\$PATH\"; hermes import '$latest_backup' --force"
						fi
						;;
					*) echo "Skipping Hermes restore." ;;
				esac
			fi
		fi
	else
		echo "WARNING: Hermes executable not found after source install." >&2
	fi
}

configureHermesBackup() {
	local bin_dir="$InstallHome/.local/bin"
	local backup_script="$bin_dir/hermes-backup"
	local env_file="$InstallHome/.config/hermes-backup.env"
	local service_unit="/etc/systemd/system/hermes-backup@.service"
	local timer_unit="/etc/systemd/system/hermes-backup@.timer"
	local escaped_timer

	echo -e "${Title}Configuring Hermes Backup${END}"
	if [ "$InstallUser" = "root" ]; then
		echo "Skipping Hermes backup setup because no non-root install user was detected."
		return
	fi

	mkdir -p "$bin_dir" "$InstallHome/.config" "$InstallHome/.local/share/hermes-backups"
	cat > "$backup_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EnvFile="$HOME/.config/hermes-backup.env"
if [ -f "$HOME/.config/vault-backup.conf" ]; then
	# shellcheck disable=SC1090
	. "$HOME/.config/vault-backup.conf"
fi
if [ -f "$EnvFile" ]; then
	# shellcheck disable=SC1090
	. "$EnvFile"
fi

HermesBin="${HERMES_BIN:-}"
if [ -z "$HermesBin" ]; then
	if command -v hermes >/dev/null 2>&1; then
		HermesBin="$(command -v hermes)"
	elif [ -x "$HOME/.local/bin/hermes" ]; then
		HermesBin="$HOME/.local/bin/hermes"
	else
		echo "hermes not found; cannot create backup." >&2
		exit 1
	fi
fi

BackupDir="${HERMES_BACKUP_DIR:-$HOME/.local/share/hermes-backups}"
ExtraDir="${HERMES_BACKUP_EXTRA_DIR:-}"
Timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BackupFile="$BackupDir/hermes-full-$Timestamp.zip"

mkdir -p "$BackupDir"
"$HermesBin" backup -o "$BackupFile"
find "$BackupDir" -maxdepth 1 -type f -name 'hermes-*.zip' -mtime +30 -delete

if [ -n "$ExtraDir" ]; then
	mkdir -p "$ExtraDir"
	if [ -n "${VAULT_AGE_RECIPIENT:-}" ]; then
		age -r "$VAULT_AGE_RECIPIENT" -o "$ExtraDir/$(basename "$BackupFile").age" "$BackupFile"
	else
		cp -f "$BackupFile" "$ExtraDir/"
	fi
	find "$ExtraDir" -maxdepth 1 -type f \( -name 'hermes-*.zip' -o -name 'hermes-*.zip.age' \) -mtime +90 -delete
fi

printf 'Hermes backup written: %s\n' "$BackupFile"
EOF
	chmod 755 "$backup_script"

	if [ ! -f "$env_file" ]; then
		cat > "$env_file" <<'EOF'
# Hermes backup settings.
# Local snapshots stay on this machine. If ~/vault exists, the installer also
# copies/encrypts Hermes snapshots into ~/vault/backups/hermes for GitHub sync.
HERMES_BACKUP_DIR="$HOME/.local/share/hermes-backups"
HERMES_BACKUP_EXTRA_DIR="${VAULT_DIR:-$HOME/vault}/backups/hermes"
EOF
	fi
	chown -R "$InstallUser:$InstallGroup" "$bin_dir" "$InstallHome/.config" "$InstallHome/.local/share/hermes-backups"

	cat > "$service_unit" <<'EOF'
[Unit]
Description=Back up Hermes Agent state for %i
Documentation=man:systemd.service(5)

[Service]
Type=oneshot
User=%i
ExecStart=%h/.local/bin/hermes-backup
EOF

	cat > "$timer_unit" <<'EOF'
[Unit]
Description=Daily Hermes Agent backup for %i
Documentation=man:systemd.timer(5)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m
Unit=hermes-backup@%i.service

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload
	escaped_timer="$(systemd-escape --template=hermes-backup@.timer "$InstallUser")"
	systemctl enable --now "$escaped_timer" || echo "WARNING: Could not enable Hermes backup timer; run: systemctl enable --now $escaped_timer" >&2

	# Make an initial backup if Hermes is already usable; do not fail the install if credentials/setup are incomplete.
	runAsInstallUser sh -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; \"\$HOME/.local/bin/hermes-backup\" || true"
}

configureHermesLapisObscuraSkin() {
	local hermes_skin_dir="$InstallHome/.hermes/skins"
	local hermes_skin="$hermes_skin_dir/lapis-obscura.yaml"

	echo "Configure Hermes Lapis Obscura skin"
	mkdir -p "$hermes_skin_dir"
	cat > "$hermes_skin" <<'EOF'
name: lapis-obscura
description: Dark basalt Hermes skin with Gruvbox mineral accents, sacred geometry, dithered old-machine ghostlight, and lo-fi wizard TUI restraint.

colors:
  banner_border: "#55515d"
  banner_title: "#d8a657"
  banner_accent: "#8f7dff"
  banner_dim: "#918999"
  banner_text: "#c8c8d0"
  ui_accent: "#d8a657"
  ui_label: "#83a598"
  ui_ok: "#98971a"
  ui_error: "#cc241d"
  ui_warn: "#fabd2f"
  prompt: "#e4e0e8"
  input_rule: "#55515d"
  response_border: "#d8a657"
  session_label: "#d8a657"
  session_border: "#55515d"
  status_bar_bg: "#050408"
  status_bar_text: "#c8c8d0"
  status_bar_strong: "#d8a657"
  status_bar_dim: "#918999"
  status_bar_good: "#98971a"
  status_bar_warn: "#fabd2f"
  status_bar_bad: "#d65d0e"
  status_bar_critical: "#cc241d"
  voice_status_bg: "#0d0b18"
  completion_menu_bg: "#090812"
  completion_menu_current_bg: "#171522"
  completion_menu_meta_bg: "#0d0b18"
  completion_menu_meta_current_bg: "#24212c"

spinner:
  waiting_faces:
    - "(·)"
    - "(◇)"
    - "(△)"
    - "(○)"
    - "(⬡)"
  thinking_faces:
    - "(☉)"
    - "(◌)"
    - "(✦)"
    - "(⌬)"
    - "(☾)"
  thinking_verbs:
    - "carving sigils"
    - "reading the stone"
    - "dithering omens"
    - "tending the moss"
    - "aligning ratios"
    - "opening the gate"
    - "polishing basalt"
    - "tracing old circuits"
    - "summoning a quiet answer"
  wings:
    - ["⟪◇", "◇⟫"]
    - ["⟪△", "△⟫"]
    - ["⟪⬡", "⬡⟫"]
    - ["⟪·", "·⟫"]

branding:
  agent_name: "Hermes Agent"
  welcome: "Lapis Obscura loaded. Type your message or /help for commands."
  goodbye: "Gate sealed. ◇"
  response_label: " ◇ Hermes "
  prompt_symbol: "◇"
  help_header: "◇ Available Commands"

tool_prefix: "╎"

tool_emojis:
  terminal: "△"
  execute_code: "⌬"
  read_file: "◇"
  write_file: "◆"
  patch: "✦"
  search_files: "☉"
  web_search: "◌"
  vision_analyze: "☾"
  image_generate: "✶"
  text_to_speech: "○"

banner_logo: |
  [bold #d8a657]██╗      █████╗ ██████╗ ██╗███████╗[/]
  [#fabd2f]██║     ██╔══██╗██╔══██╗██║██╔════╝[/]
  [#d8a657]██║     ███████║██████╔╝██║███████╗[/]
  [#918999]██║     ██╔══██║██╔═══╝ ██║╚════██║[/]
  [#c8c8d0]███████╗██║  ██║██║     ██║███████║[/]
  [dim #55515d]╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝[/]
  [#8f7dff]        O B S C U R A[/]

banner_hero: |
  [#55515d]             ·     .       ·[/]
  [#918999]        .        ◌        .[/]
  [#d8a657]              △[/]
  [#d8a657]             ╱ ╲[/]
  [#c8c8d0]        ◇───╱___╲───◇[/]
  [#918999]          ╲  ○ ○  ╱[/]
  [#55515d]           ╲__·__╱[/]
  [#24212c]        ░░░▒▒▓ basalt ▓▒▒░░░[/]
  [#98971a]             moss[/] [#8f7dff]wisp[/] [#83a598]signal[/]
EOF
	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$InstallHome/.hermes"
	fi

	if command -v hermes >/dev/null 2>&1; then
		runAsInstallUser sh -lc "export PATH=\"/usr/local/bin:\$HOME/.local/bin:\$PATH\"; hermes config set display.skin lapis-obscura || true"
	else
		echo "Hermes command not found; Lapis Obscura skin file was written but not activated."
	fi
}

configureFootTheme() {
	local config_dir="$InstallHome/.config/foot"
	local config="$config_dir/foot.ini"
	local proggy_font="$InstallHome/proggyfonts/ProggyOriginal/ProggyClean.ttf"
	local foot_font="ProggyClean"
	local foot_font_size=16
	local scanned_font

	echo "Configure Foot Lapis Obscura theme"
	mkdir -p "$config_dir"
	if [ -f "$proggy_font" ]; then
		mkdir -p "$InstallHome/.local/share/fonts/proggyfonts"
		ln -sf "$proggy_font" "$InstallHome/.local/share/fonts/proggyfonts/ProggyClean.ttf"
		fc-cache -f "$InstallHome/.local/share/fonts/proggyfonts" || true
		if command -v fc-scan >/dev/null 2>&1; then
			scanned_font="$(fc-scan --format '%{family[0]}' "$proggy_font" 2>/dev/null || true)"
			if [ -n "$scanned_font" ]; then
				foot_font="$scanned_font"
			fi
		fi
	else
		echo "ProggyClean.ttf not found at $proggy_font; using Foot font fallback name."
	fi

	cat > "$config" <<EOF
# Lapis Obscura foot theme
# Dark basalt terminal with Gruvbox mineral accents.

[main]
font=$foot_font:pixelsize=$foot_font_size
selection-target=both
pad=8x8
term=xterm-256color

[scrollback]
lines=10000
multiplier=3.0

[cursor]
style=block
blink=no

[mouse]
hide-when-typing=yes

[colors-dark]
alpha=1.0
background=050408
foreground=c8c8d0
cursor=050408 d8a657

# Normal colors: stone, rust, moss, gold, spirit, portal, ritual, moon
regular0=090812
regular1=cc241d
regular2=98971a
regular3=d8a657
regular4=83a598
regular5=d3869b
regular6=8ec07c
regular7=c8c8d0

# Bright colors: ash, ember, lichen, lantern, signal, arcane, aqua, bone
bright0=55515d
bright1=fb4934
bright2=b8bb26
bright3=fabd2f
bright4=83a598
bright5=8f7dff
bright6=8ec07c
bright7=e4e0e8

# Stone selection and URL markers
selection-foreground=e4e0e8
selection-background=171522
jump-labels=050408 fabd2f
urls=83a598

[csd]
preferred=none
EOF

	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$config_dir"
		if [ -d "$InstallHome/.local/share/fonts/proggyfonts" ]; then
			chown -R "$InstallUser:$InstallGroup" "$InstallHome/.local/share/fonts/proggyfonts"
		fi
	fi
}

configureFishTheme() {
	local fish_conf_dir="$InstallHome/.config/fish/conf.d"
	local fish_theme="$fish_conf_dir/20-lapis-obscura.fish"

	echo "Configure Fish Lapis Obscura theme"
	mkdir -p "$fish_conf_dir"
	cat > "$fish_theme" <<'EOF'
# Lapis Obscura fish theme
# Dark stone, sparse sacred geometry, Gruvbox mineral accents.

set -g fish_greeting ''

# Syntax colors
set -g fish_color_normal c8c8d0
set -g fish_color_command d8a657
set -g fish_color_keyword 8f7dff
set -g fish_color_quote 98971a
set -g fish_color_redirection 83a598
set -g fish_color_end 918999
set -g fish_color_error cc241d
set -g fish_color_param c8c8d0
set -g fish_color_comment 55515d
set -g fish_color_selection --background=171522
set -g fish_color_search_match --background=24212c --bold
set -g fish_color_operator fabd2f
set -g fish_color_escape 8ec07c
set -g fish_color_autosuggestion 55515d
set -g fish_color_cancel cc241d

# Completion pager colors
set -g fish_pager_color_progress 918999
set -g fish_pager_color_prefix d8a657 --bold
set -g fish_pager_color_completion c8c8d0
set -g fish_pager_color_description 918999
set -g fish_pager_color_selected_background --background=171522
set -g fish_pager_color_selected_prefix fabd2f --bold
set -g fish_pager_color_selected_completion e4e0e8
set -g fish_pager_color_selected_description 83a598

function fish_prompt --description 'Lapis Obscura prompt'
    set -l last_status $status
    set -l cwd (prompt_pwd)

    set_color 55515d
    printf '◇ '
    set_color d8a657
    printf '%s' $USER
    set_color 55515d
    printf '@'
    set_color 83a598
    printf '%s' (prompt_hostname)
    set_color 55515d
    printf ' · '
    set_color c8c8d0
    printf '%s' $cwd

    if command git rev-parse --is-inside-work-tree >/dev/null 2>&1
        set -l branch (command git branch --show-current 2>/dev/null)
        if test -n "$branch"
            set_color 55515d
            printf ' · '
            set_color 8f7dff
            printf '⬡ %s' $branch
        end
    end

    if test $last_status -ne 0
        set_color cc241d
        printf ' △ %s' $last_status
    end

    set_color normal
    printf '\n'
    set_color d8a657
    printf '◆ '
    set_color normal
end

function fish_right_prompt --description 'Lapis Obscura right prompt'
    set_color 55515d
    printf '☾ '
    set_color 918999
    date '+%H:%M'
    set_color normal
end

# Minimal convenience abbreviations. Keep this small: stone first, no shell bloat.
abbr -a -- ll 'ls -lh --group-directories-first'
abbr -a -- la 'ls -lah --group-directories-first'
abbr -a -- gs 'git status --short --branch'
abbr -a -- v nvim
EOF

	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$InstallHome/.config/fish"
	fi
}

configureFuzzelTheme() {
	local config_dir="$InstallHome/.config/fuzzel"
	local config="$config_dir/fuzzel.ini"

	echo "Configure Fuzzel theme"
	mkdir -p "$config_dir"
	cat > "$config" <<'EOF'
# Lapis Obscura fuzzel theme
# Command portal, not app-store card: sharp stone, small footprint, sparse sigils.

[main]
font=ProggyCleanTT:pixelsize=16
terminal=foot -e
prompt="◇ "
placeholder="summon command"
icons-enabled=no
use-bold=no
dpi-aware=no
width=55
lines=13
horizontal-pad=13
vertical-pad=8
inner-pad=5
tabs=4
layer=overlay
match-mode=fzf
filter-desktop=yes

[colors]
background=050408ee
text=c8c8d0ff
prompt=d8a657ff
placeholder=55515dcc
input=e4e0e8ff
match=d8a657ff
selection=171522ff
selection-text=e4e0e8ff
selection-match=fabd2fff
counter=918999cc
border=55515dcc

[border]
width=1
radius=0
selection-radius=0
EOF

	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$config_dir"
	fi

	if command -v fuzzel >/dev/null 2>&1; then
		if ! runAsInstallUser fuzzel --check-config --config "$config"; then
			echo "WARNING: fuzzel config validation failed for $config" >&2
		fi
	fi
}

# shellcheck disable=SC2016
configureHyprlandConfig() {
	local config="$InstallHome/.config/hypr/hyprland.conf"

	echo "Configure Hyprland"
	mkdir -p "$InstallHome/.config/hypr"
	if [ ! -f "$config" ]; then
		cp /usr/share/hypr/hyprland.conf "$config"
	fi

	sed -i -E 's/^([[:space:]]*)autogenerated[[:space:]]*=/\1# autogenerated =/' "$config"
	# Lapis Obscura: sharp basalt slabs, Fibonacci gaps, 1px ritual border,
	# no compositor-costly blur/shadow/glass. Active border is the only flourish.
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*gaps_in[[:space:]]*=.*/    gaps_in = 2/' "$config"
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*gaps_out[[:space:]]*=.*/    gaps_out = 5/' "$config"
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*border_size[[:space:]]*=.*/    border_size = 1/' "$config"
	setHyprBlockOption general col.active_border 'rgba(d8a657ff) rgba(c8c8d0ff) rgba(8f7dffff) 45deg' "$config"
	setHyprBlockOption general col.inactive_border 'rgba(55515dcc) rgba(0d0b18cc) rgba(24212ccc) 45deg' "$config"
	sed -i -E '/^[[:space:]]*decoration[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*rounding[[:space:]]*=.*/    rounding = 0/' "$config"
	sed -i -E '/^[[:space:]]*decoration[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*rounding_power[[:space:]]*=.*/    rounding_power = 2/' "$config"
	setHyprBlockOption decoration active_opacity 1.0 "$config"
	setHyprBlockOption decoration inactive_opacity 1.0 "$config"
	sed -i -E '/^[[:space:]]*shadow[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*enabled[[:space:]]*=.*/        enabled = false/' "$config"
	sed -i -E '/^[[:space:]]*blur[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*enabled[[:space:]]*=.*/        enabled = false/' "$config"
	setHyprBlockOption animations enabled false "$config"
	setHyprBlockOption misc disable_hyprland_logo true "$config"
	setHyprBlockOption misc disable_splash_rendering true "$config"
	setHyprBlockOption misc force_default_wallpaper 0 "$config"
	# Remove render options that are absent from the current Arch Hyprland release
	# or unstable across adjacent Hyprland versions. Keep the known-safe color
	# management options used by Hyprland 0.54.x: cm_enabled, cm_auto_hdr,
	# send_content_type, and non_shader_cm.
	sed -i -E '/^[[:space:]]*render[[:space:]]*\{/,/^[[:space:]]*\}/ {/^[[:space:]]*(cm_fs_passthrough|use_fp16|keep_unmodified_copy|non_shader_cm_interop)[[:space:]]*=/d;}' "$config"
	setHyprBlockOption render cm_enabled true "$config"
	setHyprBlockOption render cm_auto_hdr 1 "$config"
	setHyprBlockOption render send_content_type true "$config"
	setHyprBlockOption render non_shader_cm 2 "$config"
	configureManualMonitorLayout "$config"

	if grep -qE '^\s*\$terminal\s*=' "$config"; then
		sed -i -E 's|^\s*\$terminal\s*=.*|$terminal = foot|' "$config"
	else
		ensureHyprLine '$terminal = foot' "$config"
	fi

	if grep -qE '^\s*\$fileManager\s*=' "$config"; then
		sed -i -E 's|^\s*\$fileManager\s*=.*|$fileManager = pcmanfm-qt|' "$config"
	else
		ensureHyprLine '$fileManager = pcmanfm-qt' "$config"
	fi

	if grep -qE '^\s*\$menu\s*=' "$config"; then
		sed -i -E 's|^\s*\$menu\s*=.*|$menu = fuzzel|' "$config"
	else
		ensureHyprLine '$menu = fuzzel' "$config"
	fi

	ensureHyprLine 'env = LIBVA_DRIVER_NAME,nvidia' "$config"
	ensureHyprLine 'env = GBM_BACKEND,nvidia-drm' "$config"
	ensureHyprLine 'env = __GLX_VENDOR_LIBRARY_NAME,nvidia' "$config"
	ensureHyprLine 'env = XDG_CURRENT_DESKTOP,Hyprland' "$config"
	ensureHyprLine 'env = XDG_SESSION_TYPE,wayland' "$config"
	ensureHyprLine 'env = XDG_SESSION_DESKTOP,Hyprland' "$config"
	ensureHyprLine 'env = GDK_BACKEND,wayland,x11,*' "$config"
	ensureHyprLine 'env = QT_QPA_PLATFORM,wayland;xcb' "$config"
	ensureHyprLine 'env = CLUTTER_BACKEND,wayland' "$config"
	ensureHyprLine 'env = ELECTRON_OZONE_PLATFORM_HINT,auto' "$config"
	ensureHyprLine 'env = NVD_BACKEND,direct' "$config"

	ensureHyprLine 'exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP' "$config"
	ensureHyprLine 'exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP' "$config"
	ensureHyprLine 'exec-once = systemctl --user start hyprpolkitagent' "$config"
	ensureHyprLine 'exec-once = systemctl --user start xdg-desktop-portal xdg-desktop-portal-hyprland' "$config"
	ensureHyprLine 'exec-once = hypridle' "$config"
	ensureHyprLine 'exec-once = dunst' "$config"
	ensureHyprLine 'exec-once = hyprpaper' "$config"
	sed -i -E '/^[[:space:]]*exec-once[[:space:]]*=[[:space:]]*ashell[[:space:]]*$/d' "$config"
	ensureHyprLine 'exec-once = eww daemon' "$config"
	ensureHyprLine 'exec-once = udiskie --tray' "$config"
	ensureHyprLine 'exec-once = wl-paste --type text --watch cliphist store' "$config"
	ensureHyprLine 'exec-once = wl-paste --type image --watch cliphist store' "$config"
	sed -i -E "/^[[:space:]]*exec-once[[:space:]]*=[[:space:]]*sh -c 'command -v monique >\\/dev\\/null 2>&1 && monique'[[:space:]]*$/d" "$config"
	ensureHyprLine "exec-once = sh -c 'command -v monique >/dev/null 2>&1 && monique'" "$config"

	ensureHyprLine 'bind = $mainMod SHIFT, V, exec, cliphist list | fuzzel --dmenu | cliphist decode | wl-copy' "$config"
	# Super+Q should open a terminal. Remove Hyprland's default Super+Q killactive binding first.
	sed -i -E '/^[[:space:]]*bind[[:space:]]*=[[:space:]]*\$mainMod,[[:space:]]*Q,[[:space:]]*killactive[[:space:]]*$/d' "$config"
	ensureHyprLine 'bind = $mainMod, Q, exec, $terminal' "$config"
	ensureHyprLine 'bind = $mainMod, RETURN, exec, $terminal' "$config"
	ensureHyprLine 'bind = $mainMod, M, exec, command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch exit' "$config"
	ensureHyprLine 'bind = $mainMod, E, exec, $fileManager' "$config"
	ensureHyprLine 'bind = $mainMod, R, exec, $menu' "$config"
	ensureHyprLine 'bind = $mainMod, T, exec, eww open zerth_overlay' "$config"
	ensureHyprLine 'bindr = $mainMod, T, exec, eww close zerth_overlay' "$config"
	ensureHyprLine 'bind = $mainMod, L, exec, hyprlock' "$config"
	ensureHyprLine 'bind = , Print, exec, grim - | wl-copy' "$config"
	ensureHyprLine 'bind = SHIFT, Print, exec, grim -g "$(slurp)" - | wl-copy' "$config"

	# Workspace switch (Super+1-9)
	local i
	for i in $(seq 1 9); do
		ensureHyprLine "bind = \$mainMod, $i, workspace, $i" "$config"
		ensureHyprLine "bind = \$mainMod SHIFT, $i, movetoworkspace, $i" "$config"
	done

	# Window management
	ensureHyprLine 'bind = $mainMod, F, fullscreen, 0' "$config"
	ensureHyprLine 'bind = $mainMod SHIFT, F, togglefloating' "$config"
	ensureHyprLine 'bind = $mainMod, left, movefocus, l' "$config"
	ensureHyprLine 'bind = $mainMod, right, movefocus, r' "$config"
	ensureHyprLine 'bind = $mainMod, up, movefocus, u' "$config"
	ensureHyprLine 'bind = $mainMod, down, movefocus, d' "$config"
	ensureHyprLine 'bind = $mainMod SHIFT, left, movewindow, l' "$config"
	ensureHyprLine 'bind = $mainMod SHIFT, right, movewindow, r' "$config"
	ensureHyprLine 'bind = $mainMod SHIFT, up, movewindow, u' "$config"
	ensureHyprLine 'bind = $mainMod SHIFT, down, movewindow, d' "$config"
	ensureHyprLine 'bindm = $mainMod, mouse:272, movewindow' "$config"
	ensureHyprLine 'bindm = $mainMod, mouse:273, resizewindow' "$config"

	if [ "$InstallUser" != "root" ]; then
		chown "$InstallUser:$InstallGroup" "$config"
	fi
}

echo -e "${Title}-----ZERTHS_ARCH_INSTALLER-----${END}"
echo "When prompted, please provide password and/or select Y/y"
echo -e "System ${Install}installation${END} will begin..."

echo "Configuring Pacman."
if ! grep -qE '^\s*Color\b' "$PacConfig"; then
	echo "Enabling Color in Pacman."
	sed -i 's/^\s*#\s*Color\b/Color/' "$PacConfig"
	if ! grep -qE '^\s*Color\b' "$PacConfig"; then
		echo "Color" | tee -a "$PacConfig" >/dev/null
	fi
fi

if ! grep -qE '^\s*ParallelDownloads\s*=' "$PacConfig"; then
	echo "Enabling ParallelDownloads in Pacman."
	sed -i '/^\s*Color\b/a ParallelDownloads = 5' "$PacConfig"
fi

if ! grep -qE '^\s*\[multilib\]' "$PacConfig"; then
	echo "Enabling multilib repo."
	printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PacConfig"
fi


echo -e "${Title}Configuring System Identity${END}"
echo "Setting hostname to themantle."
hostnamectl set-hostname themantle
echo "themantle" > /etc/hostname
if ! grep -q 'themantle' /etc/hosts; then
	printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\tthemantle.localdomain\tthemantle\n' > /etc/hosts
fi

echo "Setting timezone to America/Toronto."
ln -sf /usr/share/zoneinfo/America/Toronto /etc/localtime
hwclock --systohc

echo "Generating en_CA.UTF-8 locale."
if ! grep -qE '^en_CA\.UTF-8 UTF-8' /etc/locale.gen; then
	sed -i 's/^#\s*en_CA\.UTF-8 UTF-8/en_CA.UTF-8 UTF-8/' /etc/locale.gen
	if ! grep -qE '^en_CA\.UTF-8 UTF-8' /etc/locale.gen; then
		echo 'en_CA.UTF-8 UTF-8' >> /etc/locale.gen
	fi
fi
locale-gen
if [ ! -f /etc/locale.conf ] || ! grep -q 'LANG=en_CA.UTF-8' /etc/locale.conf; then
	echo 'LANG=en_CA.UTF-8' > /etc/locale.conf
fi

echo -e "${Title}Updating System.${END}"
echo "Installing reflector and updating mirrorlist for Canada."
pacman -S --needed --noconfirm reflector
reflector --country Canada --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm
if [ -x /usr/bin/paru ]; then
	echo -e "${Title}Rebuilding paru from source against updated libalpm.${END}"
	buildAndInstallParu
fi
echo "Adding development packages."
pacman -S --needed --noconfirm base-devel
echo "Acquiring Git"
if ! command -v git >/dev/null 2>&1; then
	echo -e "Git ${Fail}not${END} found, ${Install}installing${END}."
	pacman -S --noconfirm git
else
	echo -e "Git ${Success}installed${END}."
fi
runAsInstallUser git config --global user.email "drkainaan@icloud.com"
runAsInstallUser git config --global user.name "TheZerth"

echo -e "${Title}Acquiring Paru${END}"
ensureParuWorks
echo -e "${Title}Acquiring Base Packages${END}"
installRepoPackages \
	linux-zen-headers amd-ucode tuned sof-firmware linux-firmware-marvell \
	man-db man-pages texinfo nano neovim fish python openssh uv \
	github-cli age rsync \
	networkmanager bluez bluez-utils cmake ninja clang \
	pacman-contrib zram-generator nftables bat

echo -e "${Title}Configuring Terminal${END}"
cd "$InstallHome"
if [ ! -d "$InstallHome/proggyfonts" ]; then
	git clone "https://github.com/bluescan/proggyfonts.git" "$InstallHome/proggyfonts"
	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$InstallHome/proggyfonts"
	fi
else
	echo -e "ProggyFonts ${Success}installed${END}."
fi
installRepoPackages terminus-font fontconfig
setfont ter-714n
touch /etc/vconsole.conf
if grep -qE '^\s*FONT=' /etc/vconsole.conf; then
	sed -i 's/^\s*FONT=.*/FONT=ter-714n/' /etc/vconsole.conf
else
	echo "FONT=ter-714n" | tee -a /etc/vconsole.conf >/dev/null
fi

echo -e "${Title}Configuring Audio${END}"
installRepoPackages \
	pipewire lib32-pipewire pipewire-docs wireplumber \
	pipewire-audio pipewire-alsa pipewire-pulse \
	pipewire-jack lib32-pipewire-jack alsa-utils
systemctl --global enable pipewire wireplumber pipewire-pulse

echo -e "${Title}Configuring Video${END}"
installRepoPackages \
	dkms nvidia-open-dkms nvidia-utils lib32-nvidia-utils \
	nvidia-settings libva-nvidia-driver \
	gamemode lib32-gamemode vulkan-tools
configureNvidiaInitramfs
configureNvidiaKernel
setNvidiaPersistenceMode

echo -e "${Title}Setup Desktop${END}"
handleRemove ashell
installRepoPackages \
	hyprland aquamarine hyprlang hyprcursor hyprutils \
	hyprgraphics hyprtoolkit hyprland-guiutils hyprwayland-scanner \
	hyprpaper xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
	hyprpolkitagent \
	dunst libnotify qt5-wayland qt6-wayland \
	fuzzel wl-clipboard cliphist udiskie pcmanfm-qt \
	hyprlock hypridle grim slurp
installAurPackages hyprpwcenter hyprshutdown eww monique
echo "Start Hyprland once to generate configs"
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
	echo "Skipping Hyprland first-run because a graphical session is already active."
elif [ "$InstallUser" = "root" ]; then
	echo "Skipping Hyprland first-run because no non-root install user was detected."
elif ! command -v start-hyprland >/dev/null 2>&1; then
	echo "start-hyprland not found; skipping Hyprland first-run."
else
	HyprlandLog="$InstallHome/.cache/zerth-hyprland-first-run.log"
	mkdir -p "$InstallHome/.cache"
	touch "$HyprlandLog"
	chown "$InstallUser:$InstallGroup" "$InstallHome/.cache" "$HyprlandLog"

	runAsInstallUser start-hyprland -- > "$HyprlandLog" 2>&1 &
	HyprlandPid=$!
	sleep 10

	if runAsInstallUser hyprctl --instance 0 dispatch exec hyprshutdown >/dev/null 2>&1; then
		waitForHyprlandExit "$HyprlandPid"
	else
		echo "hyprshutdown did not start; asking Hyprland to exit directly."
		runAsInstallUser hyprctl --instance 0 dispatch exit >/dev/null 2>&1 || true
		waitForHyprlandExit "$HyprlandPid"
	fi
fi
configureHyprlandConfig
configureHyprpaperConfig
configureFuzzelTheme
configureEwwConfig
configureHypridleConfig
configureHyprlockConfig
setNvidiaPowerMizerModeInHyprland

echo -e "${Title}Install Applications${END}"
handleRemove firefox
installRepoPackages \
	foot steam gamescope xorg-xwayland \
	protontricks wine winetricks freecad btop
installAurPackages vesktop zen-browser-bin visual-studio-code-bin jetbrains-toolbox

configureGithubVault
configureHermesAgent
configureHermesLapisObscuraSkin
configureHermesBackup
runAsInstallUser sh -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; if [ -x \"\$HOME/.local/bin/vault-backup\" ]; then \"\$HOME/.local/bin/vault-backup\" || true; fi"

echo -e "${Title}Configuring Arch${END}"
echo "Enable SSD TRIM"
systemctl enable fstrim.timer
echo "Enable paccache weekly prune timer"
systemctl enable paccache.timer
echo "Enable TuneD"
systemctl enable tuned.service
systemctl start tuned.service
tuned-adm profile throughput-performance
echo "Enable NetworkManager"
systemctl enable NetworkManager.service
systemctl start NetworkManager.service
echo "Enable Bluetooth"
systemctl enable bluetooth.service
systemctl start bluetooth.service
echo "Configure zram swap"
if [ ! -f /etc/systemd/zram-generator.conf ]; then
	cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
# Compressed swap in RAM — size capped at half physical RAM
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
fi
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service || \
	echo "WARNING: zram setup failed; swap will be unavailable until reboot." >&2
echo "Configure nftables firewall"
if [ ! -f /etc/nftables.conf ] || ! grep -q 'zerth' /etc/nftables.conf; then
	cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Zerth minimal stateful firewall — deny unsolicited inbound, allow all outbound

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state invalid drop
		ct state { established, related } accept
		iif lo accept
		ip protocol icmp accept
		ip6 nexthdr icmpv6 accept
		# Uncomment to allow SSH inbound:
		# tcp dport 22 accept
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF
fi
systemctl enable nftables.service
systemctl start nftables.service
echo "Set user shell to Fish"
if [ -n "$InstallUser" ] && [ "$InstallUser" != "root" ]; then
	if ! grep -qx "/usr/bin/fish" /etc/shells; then
		echo "/usr/bin/fish" | tee -a /etc/shells >/dev/null
	fi
	chsh -s /usr/bin/fish "$InstallUser"
else
	echo "Skipping shell change because no non-root install user was detected."
fi
configureFootTheme
configureFishTheme
copySshKeysFromUsb

if [ "${ZERTH_NO_REBOOT:-0}" = "1" ]; then
	echo "Installation complete. ZERTH_NO_REBOOT=1 set; skipping reboot."
	exit 0
fi
read -r -p "Installation complete. Press Enter to reboot."
reboot
