#! /usr/bin/bash

PacConfig="/etc/pacman.conf"

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
handleInstall power-profiles-daemon
handleInstall sof-firmware
handleInstall linux-firmware-marvell
handleInstall man-db
handleInstall man-pages
handleInstall texinfo
handleInstall nano
handleInstall neovim
handleInstall fish

echo -e "${Title}Configuring Terminal${END}"
cd
if [ ! -d ~/proggyfonts ]; then
	git clone "https://www.github.com/bluescan/proggyfonts.git"
else
	echo -e "ProggyFonts ${Success}installed${END}."
fi
handleInstall terminus-font
setfont ter-714n
#ADD PERMANENT FONT CHANGE

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
handleInstall gamemode

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
handleInstall xdg-desktop-portal-hyprland
handleInstall hyprpolkitagent
handleInstall hyprpwcenter
handleInstall hyprshutdown
handleInstall mako
handleInstall libnotify
handleInstall qt5-wayland
handleInstall qt6-wayland
handleInstall ashell
handleInstall fuzzel
handleInstall wl-clipboard
handleInstall cliphist

echo -e "${Title}Install Applications${END}"
handleInstall foot
handleInstall vesktop
handleInstall steam
handleInstall gamescope
handleInstall freecad
handleInstall firefox
handleInstall visual-studio-code-bin
handleInstall jetbrains-toolbox

chsh /usr/bin/fish
sudo reboot
