#!/usr/bin/bash
set -euo pipefail
trap 'echo "ERROR: Script failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: This script must be run as root (./ZerthArchInstall.sh)." >&2
	exit 1
fi

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

ensureParuWorks() {
	if [ ! -x /usr/bin/paru ]; then
		echo -e "Paru ${Fail}not${END} found, ${Install}installing${END}."
		if [ "$InstallUser" = "root" ]; then
			echo "ERROR: Cannot build paru as root. Run this script through sudo from the target user." >&2
			exit 1
		fi
		local ParuBuildDir="$InstallHome/.cache/paru-bin-build"
		rm -rf "$ParuBuildDir"
		mkdir -p "$InstallHome/.cache"
		chown "$InstallUser:$InstallGroup" "$InstallHome/.cache"
		runAsInstallUser git clone "https://aur.archlinux.org/paru-bin.git" "$ParuBuildDir"
		runAsInstallUser sh -lc 'cd "$HOME/.cache/paru-bin-build" && makepkg --noconfirm'
		local ParuPackages=("$ParuBuildDir"/*.pkg.tar.zst)
		pacman -U --noconfirm "${ParuPackages[@]}" || { echo "ERROR: Failed to install paru package. Aborting." >&2; exit 1; }
		rm -rf "$ParuBuildDir"
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

	if grep -qE "^[[:space:]]*$block_regex[[:space:]]*\{" "$config"; then
		if sed -n -E "/^[[:space:]]*$block_regex[[:space:]]*\{/,/^[[:space:]]*\}/p" "$config" | grep -qE "^[[:space:]]*$option_regex[[:space:]]*="; then
			sed -i -E "/^[[:space:]]*$block_regex[[:space:]]*\{/,/^[[:space:]]*\}/ s|^[[:space:]]*$option_regex[[:space:]]*=.*|    $option = $value|" "$config"
		else
			sed -i -E "/^[[:space:]]*$block_regex[[:space:]]*\{/a\\    $option = $value" "$config"
		fi
	else
		printf '\n%s {\n    %s = %s\n}\n' "$block" "$option" "$value" >> "$config"
	fi
}

configureSamsungOledG8Monitor() {
	local config="$1"
	local output="${ZERTH_HYPR_MONITOR_OUTPUT:-}"

	sed -i -E '/^[[:space:]]*monitor[[:space:]]*=[[:space:]]*,[[:space:]]*preferred[[:space:]]*,[[:space:]]*auto[[:space:]]*,[[:space:]]*(auto|1)[[:space:]]*$/d' "$config"
	sed -i '/^# Zerth Samsung OLED G8 monitor start$/,/^# Zerth Samsung OLED G8 monitor end$/d' "$config"

	{
		printf '\n# Zerth Samsung OLED G8 monitor start\n'
		printf '# Set ZERTH_HYPR_MONITOR_OUTPUT before running to pin a specific output, e.g. DP-1 or HDMI-A-1.\n'
		printf 'monitorv2 {\n'
		printf '    output = %s\n' "$output"
		printf '    mode = 3440x1440@120\n'
		printf '    position = 0x0\n'
		printf '    scale = 1\n'
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
		printf '}\n'
		printf '# Zerth Samsung OLED G8 monitor end\n'
	} >> "$config"
}

configureHyprpaperConfig() {
	local config="$InstallHome/.config/hypr/hyprpaper.conf"
	local wallpaper="${ZERTH_HYPRPAPER_WALLPAPER:-$InstallHome/Pictures/wallpaper.png}"
	local escaped_wallpaper

	escaped_wallpaper="$(printf '%s\n' "$wallpaper" | sed 's/[&|\\]/\\&/g')"

	echo "Configure Hyprpaper"
	mkdir -p "$InstallHome/.config/hypr" "$InstallHome/Pictures"
	if [ ! -f "$config" ]; then
		{
			printf '# Zerth wallpaper section\n'
			printf '# Hyprpaper needs a local image path. Override before running with:\n'
			printf '# ZERTH_HYPRPAPER_WALLPAPER=/path/to/wallpaper.png\n'
			printf 'preload = %s\n' "$wallpaper"
			printf 'wallpaper = ,%s\n' "$wallpaper"
			printf 'splash = false\n'
		} > "$config"
	else
		if grep -qE '^[[:space:]]*preload[[:space:]]*=' "$config"; then
			sed -i -E "0,/^[[:space:]]*preload[[:space:]]*=/{s|^[[:space:]]*preload[[:space:]]*=.*|preload = $escaped_wallpaper|}" "$config"
		else
			printf '\n# Zerth wallpaper section\npreload = %s\n' "$wallpaper" >> "$config"
		fi

		if grep -qE '^[[:space:]]*wallpaper[[:space:]]*=' "$config"; then
			sed -i -E "0,/^[[:space:]]*wallpaper[[:space:]]*=/{s|^[[:space:]]*wallpaper[[:space:]]*=.*|wallpaper = ,$escaped_wallpaper|}" "$config"
		else
			printf 'wallpaper = ,%s\n' "$wallpaper" >> "$config"
		fi

		if grep -qE '^[[:space:]]*splash[[:space:]]*=' "$config"; then
			sed -i -E '0,/^[[:space:]]*splash[[:space:]]*=/{s|^[[:space:]]*splash[[:space:]]*=.*|splash = false|}' "$config"
		else
			printf 'splash = false\n' >> "$config"
		fi
	fi

	if ! grep -qF 'ZERTH_HYPRPAPER_WALLPAPER=/path/to/wallpaper.png' "$config"; then
		{
			printf '\n'
			printf '# Zerth wallpaper section\n'
			printf '# Hyprpaper needs a local image path. Override before running with:\n'
			printf '# ZERTH_HYPRPAPER_WALLPAPER=/path/to/wallpaper.png\n'
		} >> "$config"
	fi

	if [ "$InstallUser" != "root" ]; then
		chown "$InstallUser:$InstallGroup" "$config" "$InstallHome/Pictures"
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
    (label :class "console-title" :halign "start" :text "SYSTEM")
    (label :class "console-subtitle" :halign "start" :text "native overlay telemetry")
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
      (label :class "sigil" :text "ZERTH")
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
* {
  all: unset;
  font-family: "ProggyClean", "Terminus", monospace;
  font-size: 16px;
}

.screen-dim {
  background-color: rgba(2, 2, 6, 0.84);
  color: #d8d5e6;
}

.stone-panel {
  margin: 18px;
  padding: 10px 12px;
  background-color: #090812;
  border: 1px solid #6f5cff;
  box-shadow: inset 0 0 0 1px #1b1730, 0 0 5px rgba(126, 102, 255, 0.34);
}

.top-panel {
  border-color: #8f7dff;
}

.desk {
  margin: 0 18px;
}

.console-card {
  min-width: 560px;
  margin-right: 18px;
  padding: 18px;
  background-color: #07060d;
  border: 1px solid #4a3fb0;
  box-shadow: inset 0 0 0 1px #151224, 0 0 6px rgba(126, 102, 255, 0.32);
}

.console-title {
  color: #f1efff;
  font-size: 22px;
  letter-spacing: 2px;
}

.console-subtitle {
  margin-top: 8px;
  color: #8f8aa8;
}

.console-launch {
  margin-top: 14px;
  padding: 6px 12px;
  color: #d8d5ff;
  background-color: #121026;
  border: 1px solid #6f5cff;
}

.console-launch:hover {
  color: #ffffff;
  background-color: #241b4a;
  border-color: #c4bbff;
}

.metric {
  margin-top: 10px;
}

.metric-name {
  min-width: 42px;
  color: #8f8aa8;
}

.metric-value {
  min-width: 44px;
  color: #e8e4ff;
}

.metric-bar {
  margin-top: 4px;
  min-height: 8px;
}

.metric-bar trough {
  background-color: #05040a;
  border: 1px solid #34304d;
}

.metric-bar progress {
  background-color: #8f7dff;
  box-shadow: 0 0 3px rgba(196, 187, 255, 0.55);
}

.metric-grid {
  margin-top: 8px;
}

.metric-column {
  min-width: 245px;
  margin-right: 18px;
}

.system-info {
  margin-top: 14px;
  padding: 10px;
  background-color: #030207;
  border: 1px solid #34304d;
}

.info-row {
  margin-top: 5px;
}

.info-label {
  min-width: 58px;
  color: #8f8aa8;
}

.info-value {
  color: #e8e4ff;
}

.control-panel {
  margin-bottom: 26px;
}

.sigil {
  margin-right: 18px;
  padding: 4px 10px;
  color: #ffffff;
  background-color: #17122c;
  border: 1px solid #8f7dff;
}

.readout {
  margin-right: 12px;
  padding: 4px 8px;
  background-color: #05040a;
  border: 1px solid #34304d;
}

.readout-key {
  margin-right: 6px;
  color: #8f8aa8;
}

.readout-value {
  color: #e8e4ff;
}

.stone-button {
  margin-right: 10px;
  padding: 5px 10px;
  color: #e8e4ff;
  background-color: #0d0b18;
  border: 1px solid #5c528a;
}

.stone-button:hover {
  color: #ffffff;
  background-color: #241b4a;
  border-color: #c4bbff;
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

	echo "Configure Hyprlock"
	mkdir -p "$InstallHome/.config/hypr"
	if [ ! -f "$config" ]; then
		cat > "$config" <<'EOF'
general {
    hide_cursor = true
    no_fade_in = true
    no_fade_out = true
}

background {
    monitor =
    color = rgba(050408ff)
}

input-field {
    monitor =
    size = 300, 40
    position = 0, -80
    halign = center
    valign = center
    outline_thickness = 1
    outer_color = rgba(7b7684ff)
    inner_color = rgba(111016ff)
    font_color = rgba(e4e0e8ff)
    check_color = rgba(c8c8d0ff)
    fail_color = rgba(cc3333ff)
    placeholder_text = <span foreground="##918999">passphrase</span>
    hide_input = false
}

label {
    monitor =
    text = cmd[update:1000] echo "$TIME"
    color = rgba(d5d0d8ff)
    font_size = 16
    font_family = ProggyClean, Terminus, monospace
    position = 0, 80
    halign = center
    valign = center
}
EOF
		echo "Written $config"
	fi
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
					runAsInstallUser sh -lc 'age -d "$HOME/vault/secrets/ssh.tar.age" | tar -C "$HOME/.ssh" -xf -'
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
	local hermes_bin="$InstallHome/.local/bin/hermes"
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
# Keep user-installed CLI tools available, including Hermes installed by uv.
fish_add_path -m ~/.local/bin
EOF
	fi
	if [ ! -f "$profile" ] || ! grep -q 'HOME/.local/bin' "$profile"; then
		cat >> "$profile" <<'EOF'

# User-installed CLI tools, including Hermes installed by uv.
case ":$PATH:" in
	*:"$HOME/.local/bin":*) ;;
	*) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
EOF
	fi
	chown -R "$InstallUser:$InstallGroup" "$InstallHome/.local" "$InstallHome/.config/fish" "$profile"

	if ! command -v uv >/dev/null 2>&1; then
		echo "uv not found; skipping Hermes install."
		return
	fi

	if runAsInstallUser sh -lc 'uv tool install --upgrade hermes-agent'; then
		echo "Hermes Agent installed for $InstallUser."
	else
		echo "WARNING: Hermes Agent install failed; continuing." >&2
		return
	fi

	if [ -x "$hermes_bin" ]; then
		runAsInstallUser sh -lc 'export PATH="$HOME/.local/bin:$PATH"; hermes setup --non-interactive || true'
		runAsInstallUser sh -lc 'export PATH="$HOME/.local/bin:$PATH"; hermes doctor || true'
		if [ -d "$hermes_vault_dir" ]; then
			latest_backup="$(ls -t "$hermes_vault_dir"/hermes-*.zip "$hermes_vault_dir"/hermes-*.zip.age 2>/dev/null | head -n 1 || true)"
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
							runAsInstallUser sh -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; hermes import '$tmp_restore' --force"
							rm -f "$tmp_restore"
						else
							runAsInstallUser sh -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; hermes import '$latest_backup' --force"
						fi
						;;
					*) echo "Skipping Hermes restore." ;;
				esac
			fi
		fi
	else
		echo "WARNING: Hermes executable not found at $hermes_bin after install." >&2
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
	runAsInstallUser sh -lc 'export PATH="$HOME/.local/bin:$PATH"; "$HOME/.local/bin/hermes-backup" || true'
}

configureHyprlandConfig() {
	local config="$InstallHome/.config/hypr/hyprland.conf"

	echo "Configure Hyprland"
	mkdir -p "$InstallHome/.config/hypr"
	if [ ! -f "$config" ]; then
		cp /usr/share/hypr/hyprland.conf "$config"
	fi

	sed -i -E 's/^([[:space:]]*)autogenerated[[:space:]]*=/\1# autogenerated =/' "$config"
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*gaps_in[[:space:]]*=.*/    gaps_in = 2/' "$config"
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*gaps_out[[:space:]]*=.*/    gaps_out = 5/' "$config"
	sed -i -E '/^[[:space:]]*general[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*border_size[[:space:]]*=.*/    border_size = 1/' "$config"
	setHyprBlockOption general col.active_border 'rgba(c8c8d0ff) rgba(0b0612ff) rgba(e6e6ecff) rgba(170026ff) rgba(c8c8d0ff) 45deg' "$config"
	setHyprBlockOption general col.inactive_border 'rgba(55515dcc) rgba(0b0612cc) rgba(2a2633cc) 45deg' "$config"
	sed -i -E '/^[[:space:]]*decoration[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*rounding[[:space:]]*=.*/    rounding = 0/' "$config"
	sed -i -E '/^[[:space:]]*decoration[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*rounding_power[[:space:]]*=.*/    rounding_power = 0/' "$config"
	sed -i -E '/^[[:space:]]*shadow[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*enabled[[:space:]]*=.*/        enabled = false/' "$config"
	sed -i -E '/^[[:space:]]*blur[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*enabled[[:space:]]*=.*/        enabled = false/' "$config"
	sed -i -E '/^[[:space:]]*animations[[:space:]]*\{/,/^[[:space:]]*\}/ s/^[[:space:]]*enabled[[:space:]]*=.*/    enabled = false/' "$config"
	setHyprBlockOption misc disable_hyprland_logo true "$config"
	setHyprBlockOption misc disable_splash_rendering true "$config"
	setHyprBlockOption misc force_default_wallpaper 0 "$config"
	setHyprBlockOption render cm_enabled true "$config"
	setHyprBlockOption render cm_fs_passthrough 2 "$config"
	setHyprBlockOption render cm_auto_hdr 1 "$config"
	setHyprBlockOption render send_content_type true "$config"
	setHyprBlockOption render use_fp16 2 "$config"
	setHyprBlockOption render keep_unmodified_copy 2 "$config"
	configureSamsungOledG8Monitor "$config"

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
	ensureHyprLine 'bind = $mainMod, Q, killactive' "$config"
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
if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$DISPLAY" ]; then
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
configureHermesBackup
runAsInstallUser sh -lc 'export PATH="$HOME/.local/bin:$PATH"; if [ -x "$HOME/.local/bin/vault-backup" ]; then "$HOME/.local/bin/vault-backup" || true; fi'

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
echo "Configure Foot font"
ProggyFont="$InstallHome/proggyfonts/ProggyOriginal/ProggyClean.ttf"
FootConfig="$InstallHome/.config/foot/foot.ini"
FootFont="ProggyClean"
FootFontSize=16
if [ -f "$ProggyFont" ]; then
	mkdir -p "$InstallHome/.local/share/fonts/proggyfonts" "$InstallHome/.config/foot"
	ln -sf "$ProggyFont" "$InstallHome/.local/share/fonts/proggyfonts/ProggyClean.ttf"
	fc-cache -f "$InstallHome/.local/share/fonts/proggyfonts"
	if command -v fc-scan >/dev/null 2>&1; then
		ScannedFootFont="$(fc-scan --format '%{family[0]}' "$ProggyFont" 2>/dev/null)"
		if [ -n "$ScannedFootFont" ]; then
			FootFont="$ScannedFootFont"
		fi
	fi
	if [ -f "$FootConfig" ]; then
		if grep -qE '^\s*font=' "$FootConfig"; then
			sed -i "s|^\s*font=.*|font=$FootFont:pixelsize=$FootFontSize|" "$FootConfig"
		elif grep -qE '^\s*\[main\]' "$FootConfig"; then
			sed -i "/^\s*\[main\]/a font=$FootFont:pixelsize=$FootFontSize" "$FootConfig"
		else
			printf "\n[main]\nfont=%s:pixelsize=%s\n" "$FootFont" "$FootFontSize" >> "$FootConfig"
		fi
	else
		printf "[main]\nfont=%s:pixelsize=%s\n" "$FootFont" "$FootFontSize" > "$FootConfig"
	fi
	# Foot defaults selected text to the PRIMARY selection only. That works
	# terminal-to-terminal, but Chromium/Helium Ctrl+V reads CLIPBOARD.
	# Copy selections to both so terminal -> browser paste works normally.
	if grep -qE '^\s*selection-target=' "$FootConfig"; then
		sed -i 's|^\s*selection-target=.*|selection-target=both|' "$FootConfig"
	else
		printf "selection-target=both\n" >> "$FootConfig"
	fi
	if [ "$InstallUser" != "root" ]; then
		chown -R "$InstallUser:$InstallGroup" "$InstallHome/.config/foot" "$InstallHome/.local/share/fonts/proggyfonts"
	fi
else
	echo "ProggyClean.ttf not found at $ProggyFont; skipping Foot font configuration."
fi
copySshKeysFromUsb

if [ "${ZERTH_NO_REBOOT:-0}" = "1" ]; then
	echo "Installation complete. ZERTH_NO_REBOOT=1 set; skipping reboot."
	exit 0
fi
read -r -p "Installation complete. Press Enter to reboot."
reboot
