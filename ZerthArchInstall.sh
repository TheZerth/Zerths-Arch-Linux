#! /usr/bin/bash

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

handleInstall() {
	local pkg="$1"
	if ! paru -Qq | grep -qx "$pkg"; then
		echo -e "$pkg ${Fail}not${END} found, ${Install}installing${END}."
		paru -S --noconfirm "$pkg"
	else	
		echo -e "$pkg" ${Success}installed${END}.
	fi
}

handleRemove() {
	local pkg="$1"
	if paru -Qq | grep -qx "$pkg"; then
		echo -e "$pkg ${Install}installed${END}, ${Fail}removing${END}."
		paru -Rns --noconfirm "$pkg" || echo "Could not remove $pkg; continuing."
	else
		echo -e "$pkg ${Success}not installed${END}."
	fi
}

runAsInstallUser() {
	if [ "$(id -u)" -eq 0 ] && [ "$InstallUser" != "root" ]; then
		sudo -u "$InstallUser" env HOME="$InstallHome" XDG_RUNTIME_DIR="/run/user/$InstallUid" "$@"
	else
		"$@"
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

configureNvidiaInitramfs() {
	local current_modules
	local modules_text
	local module
	local nvidia_modules=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

	echo "Configure NVIDIA modules in mkinitcpio"
	sudo touch "$MkinitcpioConfig"
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
		sudo sed -i -E "0,/^[[:space:]]*MODULES=/{s|^[[:space:]]*MODULES=.*|MODULES=($modules_text)|}" "$MkinitcpioConfig"
	else
		echo "MODULES=($modules_text)" | sudo tee -a "$MkinitcpioConfig" >/dev/null
	fi

	sudo mkinitcpio -P
}

setNvidiaPersistenceMode() {
	echo "Set NVIDIA persistence mode"
	if ! command -v nvidia-smi >/dev/null 2>&1; then
		echo "nvidia-smi not found; skipping NVIDIA persistence mode."
		return
	fi

	timeout 10s sudo nvidia-smi -pm 1 || echo "Skipping NVIDIA persistence mode; the driver may need a reboot."
}

setNvidiaPowerMizerMode() {
	echo "Set NVIDIA PowerMizer max performance mode"
	if ! command -v nvidia-settings >/dev/null 2>&1; then
		echo "nvidia-settings not found; skipping NVIDIA PowerMizer mode."
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
	local usb_device="/dev/sda1"
	local mount_point="/tmp/zerth-ssh-usb"
	local source_ssh="$mount_point/.ssh"
	local target_ssh="$InstallHome/.ssh"

	echo -e "${Title}Copying SSH Keys${END}"
	read -r -p "Please plug in the USB device containing .ssh on /dev/sda1, then press Enter to continue."

	sudo mkdir -p "$mount_point"
	if ! sudo mount "$usb_device" "$mount_point"; then
		echo "Could not mount $usb_device; skipping SSH key copy."
		sudo rmdir "$mount_point"
		return
	fi

	if [ -d "$source_ssh" ]; then
		sudo mkdir -p "$target_ssh"
		if sudo cp -a "$source_ssh/." "$target_ssh/"; then
			sudo chmod 700 "$target_ssh"
			sudo find "$target_ssh" -type d -exec chmod 700 {} +
			sudo find "$target_ssh" -type f -exec chmod 600 {} +
			if [ "$InstallUser" != "root" ]; then
				sudo chown -R "$InstallUser:$InstallGroup" "$target_ssh"
			fi
			echo "SSH keys copied to $target_ssh."
		else
			echo "Failed to copy SSH keys to $target_ssh."
		fi
	else
		echo "No .ssh folder found at the root of $usb_device; skipping SSH key copy."
	fi

	sudo umount "$mount_point"
	sudo rmdir "$mount_point"
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
		sudo chown "$InstallUser:$InstallGroup" "$config" "$InstallHome/Pictures"
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

(defwidget zerth_screen []
  (box :class "screen-dim" :orientation "v" :space-evenly false
    (box :class "stone-panel top-panel" :orientation "h" :space-evenly false
      (label :class "sigil" :text "ZERTH")
      (zerth_readout :label "TIME" :value zerth_time)
      (zerth_readout :label "DATE" :value zerth_date)
      (zerth_readout :label "AUDIO" :value zerth_audio)
      (zerth_readout :label "NET" :value zerth_network)
      (zerth_readout :label "LOAD" :value zerth_cpu)
      (zerth_readout :label "MEM" :value zerth_memory)
      (zerth_readout :label "SPACE" :value zerth_workspace))
    (box :class "spacer")
    (box :class "stone-panel control-panel" :orientation "h" :space-evenly false
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
  background-color: rgba(5, 4, 8, 0.78);
  color: #d5d0d8;
}

.stone-panel {
  margin: 18px;
  padding: 10px 12px;
  background-color: #111016;
  border: 2px solid #7b7684;
  box-shadow: inset 0 0 0 2px #24202d, 0 0 0 2px #050408;
}

.top-panel {
  border-color: #a7a1ad;
}

.control-panel {
  margin-bottom: 26px;
}

.sigil {
  margin-right: 18px;
  padding: 4px 10px;
  color: #f0edf2;
  background-color: #22172f;
  border: 1px solid #a7a1ad;
}

.readout {
  margin-right: 12px;
  padding: 4px 8px;
  background-color: #0b0a0f;
  border: 1px solid #4d4855;
}

.readout-key {
  margin-right: 6px;
  color: #918999;
}

.readout-value {
  color: #e4e0e8;
}

.stone-button {
  margin-right: 10px;
  padding: 5px 10px;
  color: #e4e0e8;
  background-color: #17131d;
  border: 1px solid #817988;
}

.stone-button:hover {
  color: #ffffff;
  background-color: #2a2036;
  border-color: #c8c3cf;
}

.spacer {
  min-height: 1px;
}
EOF

	if [ "$InstallUser" != "root" ]; then
		sudo chown -R "$InstallUser:$InstallGroup" "$config_dir"
	fi
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
	ensureHyprLine 'exec-once = dunst' "$config"
	ensureHyprLine 'exec-once = hyprpaper' "$config"
	sed -i -E '/^[[:space:]]*exec-once[[:space:]]*=[[:space:]]*ashell[[:space:]]*$/d' "$config"
	ensureHyprLine 'exec-once = eww daemon' "$config"
	ensureHyprLine 'exec-once = udiskie --tray' "$config"
	ensureHyprLine 'exec-once = wl-paste --type text --watch cliphist store' "$config"
	ensureHyprLine 'exec-once = wl-paste --type image --watch cliphist store' "$config"
	sed -i -E "/^[[:space:]]*exec-once[[:space:]]*=[[:space:]]*sh -c 'command -v monique >\/dev\/null 2>&1 && monique'[[:space:]]*$/d" "$config"

	ensureHyprLine 'bind = $mainMod SHIFT, V, exec, cliphist list | fuzzel --dmenu | cliphist decode | wl-copy' "$config"
	ensureHyprLine 'bind = $mainMod, M, exec, command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch exit' "$config"
	ensureHyprLine 'bind = $mainMod, E, exec, $fileManager' "$config"
	ensureHyprLine 'bind = $mainMod, R, exec, $menu' "$config"
	ensureHyprLine 'bind = $mainMod, T, exec, eww open zerth_overlay' "$config"
	ensureHyprLine 'bindr = $mainMod, T, exec, eww close zerth_overlay' "$config"

	if [ "$InstallUser" != "root" ]; then
		sudo chown "$InstallUser:$InstallGroup" "$config"
	fi
}

echo -e "${Title}-----ZERTHS_ARCH_INSTALLER-----${END}"
echo "When prompted, please provide password and/or select Y/y"
echo -e "System ${Install}installation${END} will begin..."

echo "Configuring Pacman."
if ! grep -qE '^\s*Color\b' "$PacConfig"; then
echo "Enabling Color in Pacman."
	sudo sed -i 's/^\s*#\s*Color\b/Color/' "$PacConfig"
	if ! grep -qE '^\s*Color\b' "$PacConfig"; then
		echo "Color" | sudo tee -a "$PacConfig" >/dev/null
	fi
fi


echo -e "${Title}Updating System.${END}"
sudo pacman -Syu
echo "Adding development packages."
sudo pacman -S --needed base-devel
echo "Acquiring Git"
if ! command -v git >/dev/null 2>&1; then
	echo -e "Git ${Fail}not${END} found, ${Install}installing${END}."
	sudo pacman -S git
else
	echo -e "Git ${Success}installed${END}."
fi
git config --global user.email "drkainaan@icloud.com"
git config --global user.name "TheZerth"

echo -e "#${Title}Acquiring Paru${END}"
if [ ! -x /usr/bin/paru ]; then
	echo -e "Paru ${Fail}not${END} found, ${Install}installing${END}."
	cd
	git clone "https://aur.archlinux.org/paru.git"
	cd paru
	makepkg -si
else
	echo -e "Paru ${Success}installed${END}."
fi
handleInstall bat


echo -e "${Title}Acquiring Base Packages${END}"
handleInstall linux-zen-headers
handleInstall amd-ucode
handleInstall tuned
handleInstall sof-firmware
handleInstall linux-firmware-marvell
handleInstall man-db
handleInstall man-pages
handleInstall texinfo
handleInstall nano
handleInstall neovim
handleInstall fish
handleInstall python
handleInstall networkmanager
handleInstall bluez
handleInstall bluez-utils
handleInstall cmake
handleInstall ninja
handleInstall clang

echo -e "${Title}Configuring Terminal${END}"
cd "$InstallHome"
if [ ! -d "$InstallHome/proggyfonts" ]; then
	git clone "https://www.github.com/bluescan/proggyfonts.git" "$InstallHome/proggyfonts"
else
	echo -e "ProggyFonts ${Success}installed${END}."
fi
handleInstall terminus-font
handleInstall fontconfig
sudo setfont ter-714n
sudo touch /etc/vconsole.conf
if sudo grep -qE '^\s*FONT=' /etc/vconsole.conf; then
	sudo sed -i 's/^\s*FONT=.*/FONT=ter-714n/' /etc/vconsole.conf
else
	echo "FONT=ter-714n" | sudo tee -a /etc/vconsole.conf >/dev/null
fi

echo -e "${Title}Configuring Audio${END}"
handleInstall pipewire 
handleInstall lib32-pipewire
handleInstall pipewire-docs
handleInstall wireplumber
handleInstall pipewire-audio
handleInstall pipewire-alsa
handleInstall pipewire-pulse
handleInstall pipewire-jack 
handleInstall lib32-pipewire-jack
handleInstall alsa-utils
systemctl --user enable pipewire wireplumber pipewire-pulse

echo -e "${Title}Configuring Video${END}"
handleInstall dkms
handleInstall nvidia-open-dkms 
handleInstall nvidia-utils 
handleInstall lib32-nvidia-utils 
handleInstall nvidia-settings
handleInstall libva-nvidia-driver
handleInstall gamemode
handleInstall lib32-gamemode
handleInstall vulkan-tools
configureNvidiaInitramfs

echo -e "${Title}Setup Desktop${END}"
handleInstall hyprland 
handleInstall aquamarine 
handleInstall hyprlang 
handleInstall hyprcursor 
handleInstall hyprutils 
handleInstall hyprgraphics
handleInstall hyprtoolkit
handleInstall hyprland-guiutils 
handleInstall hyprwayland-scanner
handleInstall hyprpaper
handleInstall xdg-desktop-portal
handleInstall xdg-desktop-portal-hyprland
handleInstall hyprpolkitagent
handleInstall hyprpwcenter
handleInstall hyprshutdown
handleInstall mako
handleInstall dunst
handleInstall libnotify
handleInstall qt5-wayland
handleInstall qt6-wayland
handleRemove ashell
handleInstall eww
handleInstall fuzzel
handleInstall wl-clipboard
handleInstall cliphist
handleInstall udiskie
handleInstall pcmanfm-qt
handleInstall monique
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
	sudo chown "$InstallUser:$InstallGroup" "$InstallHome/.cache" "$HyprlandLog"

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

echo -e "${Title}Install Applications${END}"
handleInstall foot
handleInstall vesktop
handleInstall steam
handleInstall gamescope
handleInstall xorg-xwayland
handleInstall protontricks
handleInstall wine
handleInstall winetricks
handleInstall freecad
handleRemove firefox
handleInstall helium-browser-bin
handleInstall visual-studio-code-bin
handleInstall jetbrains-toolbox
handleInstall btop

echo -e "${Title}Configuring Arch${END}"
echo "Enable SSD TRIM"
sudo systemctl enable fstrim.timer
echo "Enable TuneD"
sudo systemctl enable tuned.service
sudo systemctl start tuned.service
sudo tuned-adm profile throughput-performance
echo "Enable NetworkManager"
sudo systemctl enable NetworkManager.service
sudo systemctl start NetworkManager.service
echo "Enable Bluetooth"
sudo systemctl enable bluetooth.service
sudo systemctl start bluetooth.service
echo "Set user shell to Fish"
if [ -n "$InstallUser" ] && [ "$InstallUser" != "root" ]; then
	if ! grep -qx "/usr/bin/fish" /etc/shells; then
		echo "/usr/bin/fish" | sudo tee -a /etc/shells >/dev/null
	fi
	sudo chsh -s /usr/bin/fish "$InstallUser"
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
	if [ "$InstallUser" != "root" ]; then
		sudo chown -R "$InstallUser:$InstallGroup" "$InstallHome/.config/foot" "$InstallHome/.local/share/fonts/proggyfonts"
	fi
else
	echo "ProggyClean.ttf not found at $ProggyFont; skipping Foot font configuration."
fi
copySshKeysFromUsb

read -r -p "Installation complete. Press Enter to reboot."
sudo reboot
