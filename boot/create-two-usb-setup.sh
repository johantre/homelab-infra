#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Constants
WORK_DIR="/tmp/ubuntu-two-usb"

# Functions
check_dependencies() {
    local deps=(curl jq)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Installing missing dependencies: ${missing[*]}${NC}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi
}

get_latest_desktop_iso() {
    local arch=$1  # "amd64" or "arm64"
    
    # ALL debug output goes to stderr (&2)
    echo -e "${BLUE}Fetching latest Ubuntu Desktop version for $arch...${NC}" >&2
    
    if [[ "$arch" == "amd64" ]]; then
        # x86_64
        echo -e "${YELLOW}[DEBUG] Fetching from: https://releases.ubuntu.com/${NC}" >&2
        
        local releases_page=$(curl -s "https://releases.ubuntu.com/" 2>&1)
        local curl_exit=$?
        
        if [[ $curl_exit -ne 0 ]]; then
            echo -e "${RED}[ERROR] curl failed with exit code: $curl_exit${NC}" >&2
            return 1
        fi
        
        echo -e "${YELLOW}[DEBUG] Page fetched, length: ${#releases_page} chars${NC}" >&2
        
        local latest_version=$(echo "$releases_page" | \
            grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' | \
            grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | \
            sort -Vr | head -1)
        
        echo -e "${YELLOW}[DEBUG] Extracted version: '$latest_version'${NC}" >&2
        
        if [[ -z "$latest_version" ]]; then
            echo -e "${YELLOW}[WARNING] Could not extract version, using fallback: 24.04.2${NC}" >&2
            latest_version="24.04.2"
        fi
        
        local iso_url="https://releases.ubuntu.com/${latest_version}/ubuntu-${latest_version}-desktop-amd64.iso"
        local iso_name="ubuntu-${latest_version}-desktop-amd64.iso"
        
        echo -e "${YELLOW}[DEBUG] Constructed URL: $iso_url${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Verifying URL exists...${NC}" >&2
        
        if curl -sf -I "$iso_url" > /dev/null 2>&1; then
            echo -e "${GREEN}[OK] URL verified${NC}" >&2
        else
            echo -e "${RED}[ERROR] URL verification failed${NC}" >&2
            return 1
        fi
        
    else
        # ARM64
        echo -e "${YELLOW}[DEBUG] Fetching from: https://cdimage.ubuntu.com/releases/24.04.2/release/${NC}" >&2
        
        local cdimage_page=$(curl -s "https://cdimage.ubuntu.com/releases/24.04.2/release/" 2>&1)
        local curl_exit=$?
        
        if [[ $curl_exit -ne 0 ]]; then
            echo -e "${RED}[ERROR] curl failed with exit code: $curl_exit${NC}" >&2
            return 1
        fi
        
        echo -e "${YELLOW}[DEBUG] Page fetched, length: ${#cdimage_page} chars${NC}" >&2
        
        local latest_iso=$(echo "$cdimage_page" | \
            grep -oE 'ubuntu-[0-9]+\.[0-9]+\.[0-9]+-desktop-arm64\.iso' | \
            sort -V | tail -1)
        
        echo -e "${YELLOW}[DEBUG] Extracted ISO: '$latest_iso'${NC}" >&2
        
        if [[ -z "$latest_iso" ]]; then
            echo -e "${YELLOW}[WARNING] Could not extract ISO, using fallback: ubuntu-24.04.3-desktop-arm64.iso${NC}" >&2
            latest_iso="ubuntu-24.04.3-desktop-arm64.iso"
        fi
        
        local iso_url="https://cdimage.ubuntu.com/releases/24.04.2/release/${latest_iso}"
        local iso_name="$latest_iso"
        
        echo -e "${YELLOW}[DEBUG] Constructed URL: $iso_url${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Verifying URL exists...${NC}" >&2
        
        if curl -sf -I "$iso_url" > /dev/null 2>&1; then
            echo -e "${GREEN}[OK] URL verified${NC}" >&2
        else
            echo -e "${RED}[ERROR] URL verification failed${NC}" >&2
            return 1
        fi
    fi
    
    echo -e "${GREEN}✓ Found: $iso_name${NC}" >&2
    
    # ONLY the result goes to stdout for capture
    echo "${iso_url}|${iso_name}"
}

is_safe_usb() {
    local device=$1
    if [ "$(cat /sys/block/$device/removable 2>/dev/null)" != "1" ]; then
        return 1
    fi
    if mount | grep -q "^/dev/${device}[0-9]* on / "; then
        return 1
    fi
    if lsblk -no MOUNTPOINT "/dev/$device" 2>/dev/null | grep -qE "^/$|^/boot$|^/home$"; then
        return 1
    fi
    return 0
}

#==============================================================================
# MAIN SCRIPT START
#==============================================================================

# Banner
echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║   Two-USB Ubuntu Setup Creator                            ║
║   USB1: Bootable ISO | USB2: Post-Install Script          ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}" 
   exit 1
fi

# Check dependencies
check_dependencies

echo -e "${GREEN}Step 1: Select Architecture${NC}"
echo
echo "1) x86_64 (Intel/AMD - Lenovo laptop, desktop PC)"
echo "2) ARM64 (Raspberry Pi 4/5, ARM servers)"
echo
echo -ne "${YELLOW}Select architecture (1-2) [1]: ${NC}"
read ARCH_CHOICE
ARCH_CHOICE=${ARCH_CHOICE:-1}

case $ARCH_CHOICE in
    1)
        ARCH="x86_64"
        ARCH_API="amd64"
        ;;
    2)
        ARCH="arm64"
        ARCH_API="arm64"
        ;;
    *)
        echo -e "${RED}Invalid choice!${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Selected: $ARCH${NC}"
echo

# Fetch latest ISO info
ISO_INFO=$(get_latest_desktop_iso "$ARCH_API")
ISO_RESULT=$?

if [[ $ISO_RESULT -ne 0 ]]; then
    echo -e "${RED}Failed to fetch ISO information${NC}"
    exit 1
fi

# Parse result
IFS='|' read -r ISO_URL ISO_NAME <<< "$ISO_INFO"

if [[ -z "$ISO_URL" || -z "$ISO_NAME" ]]; then
    echo -e "${RED}Failed to parse ISO information${NC}"
    exit 1
fi

echo -e "${BLUE}Will download: $ISO_NAME${NC}"
echo

echo -e "${GREEN}Step 2: Configuration for post-install script${NC}"
echo

# Config
echo -ne "${YELLOW}Hostname [homeassistance]: ${NC}"
read HOSTNAME
HOSTNAME=${HOSTNAME:-homeassistance}

echo
echo -e "${BLUE}Note: Script will configure the user created during installation${NC}"
echo

echo -e "${YELLOW}SSH Public Key (paste and press Enter, or leave empty to skip):${NC}"
read SSH_KEY

echo
echo -e "${GREEN}Step 3: Detecting USB devices...${NC}"
echo

# Find USB devices
echo -e "${BLUE}Available USB devices:${NC}"
printf "%-4s %-10s %-10s %-30s\n" "NUM" "DEVICE" "SIZE" "MODEL"
echo "--------------------------------------------------------"

SAFE_DEVICES=()
counter=1

for device in $(lsblk -d -n -o NAME | grep -E "^sd[a-z]+$"); do
    if is_safe_usb "$device"; then
        SIZE=$(lsblk -d -n -o SIZE "/dev/$device")
        MODEL=$(lsblk -d -n -o MODEL "/dev/$device" | xargs)
        printf "%-4s %-10s %-10s %-30s\n" "$counter" "$device" "$SIZE" "$MODEL"
        SAFE_DEVICES+=("$device")
        counter=$((counter + 1))
    fi
done

echo

if [ ${#SAFE_DEVICES[@]} -lt 2 ]; then
    echo -e "${RED}Need at least 2 USB devices! Found: ${#SAFE_DEVICES[@]}${NC}"
    echo -e "${YELLOW}Please insert both USB sticks${NC}"
    exit 1
fi

# Select USB 1 (for ISO)
echo -e "${YELLOW}USB 1 will be the BOOT USB (4GB+ recommended)${NC}"
echo -ne "${YELLOW}Select USB 1 number for ISO [1]: ${NC}"
read USB1_NUM
USB1_NUM=${USB1_NUM:-1}
idx=$((USB1_NUM - 1))
USB1_DEVICE="${SAFE_DEVICES[$idx]}"

# Select USB 2 (for setup script)
echo -e "${YELLOW}USB 2 will be the SETUP USB (any size is fine)${NC}"
echo -ne "${YELLOW}Select USB 2 number for setup script [2]: ${NC}"
read USB2_NUM
USB2_NUM=${USB2_NUM:-2}
idx=$((USB2_NUM - 1))
USB2_DEVICE="${SAFE_DEVICES[$idx]}"

if [ "$USB1_DEVICE" = "$USB2_DEVICE" ]; then
    echo -e "${RED}Cannot use same device for both!${NC}"
    exit 1
fi

echo
echo -e "${BLUE}Selected:${NC}"
echo "  USB1 (Boot ISO): /dev/$USB1_DEVICE"
echo "  USB2 (Setup):    /dev/$USB2_DEVICE"
echo

# Confirmation
echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  WARNING: BOTH USB DEVICES WILL BE ERASED!   ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
echo -ne "${YELLOW}Continue? (yes/no) [no]: ${NC}"
read CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 0
fi

echo
echo -e "${GREEN}Step 4: Preparing workspace...${NC}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo -e "${GREEN}Step 5: Downloading Ubuntu Desktop ISO...${NC}"
if [ ! -f "$ISO_NAME" ]; then
    echo -e "${YELLOW}Downloading $ISO_NAME...${NC}"
    wget -q --show-progress "$ISO_URL" || {
        echo -e "${RED}Download failed!${NC}"
        exit 1
    }
else
    echo -e "${YELLOW}ISO already exists, reusing...${NC}"
fi

echo -e "${GREEN}Step 6: Generating post-install script...${NC}"

cat > setup-machine.sh << 'SETUP_EOF'
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Post-Install Configuration Script        ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
echo

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}" 
   exit 1
fi

# Auto-detect the user who invoked sudo
ACTUAL_USER="${SUDO_USER}"

if [ -z "$ACTUAL_USER" ]; then
    echo -e "${RED}Could not detect user! Please run with sudo.${NC}"
    exit 1
fi

echo -e "${BLUE}Detected user: ${ACTUAL_USER}${NC}"
echo -e "${BLUE}Hostname: HOSTNAME_PLACEHOLDER${NC}"
echo

# Set hostname
echo -e "${GREEN}[1/4] Setting hostname...${NC}"
hostnamectl set-hostname HOSTNAME_PLACEHOLDER
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname

# Update hosts file
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1    HOSTNAME_PLACEHOLDER" >> /etc/hosts
echo -e "   ${GREEN}✓${NC} Hostname set to HOSTNAME_PLACEHOLDER"

# SSH key setup
SSH_KEY_PROVIDED="SSH_KEY_PLACEHOLDER"
if [ -n "$SSH_KEY_PROVIDED" ] && [ "$SSH_KEY_PROVIDED" != "SKIP" ]; then
    echo -e "${GREEN}[2/4] Adding SSH key...${NC}"
    
    USER_HOME=$(eval echo ~${ACTUAL_USER})
    mkdir -p "$USER_HOME/.ssh"
    
    # Add key if not already present
    if ! grep -q "$SSH_KEY_PROVIDED" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$SSH_KEY_PROVIDED" >> "$USER_HOME/.ssh/authorized_keys"
    fi
    
    chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    
    echo -e "   ${GREEN}✓${NC} SSH key added"
else
    echo -e "${YELLOW}[2/4] No SSH key configured (skipped)${NC}"
fi

# Sudo passwordless
echo -e "${GREEN}[3/4] Configuring sudo...${NC}"
if ! grep -q "^${ACTUAL_USER}.*NOPASSWD" /etc/sudoers.d/${ACTUAL_USER} 2>/dev/null; then
    echo "${ACTUAL_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${ACTUAL_USER}
    chmod 440 /etc/sudoers.d/${ACTUAL_USER}
    echo -e "   ${GREEN}✓${NC} Passwordless sudo enabled"
else
    echo -e "   ${YELLOW}Already configured${NC}"
fi

# Ensure openssh-server
echo -e "${GREEN}[4/4] Checking SSH server...${NC}"
if ! systemctl is-active --quiet ssh; then
    echo -e "   ${YELLOW}Installing openssh-server...${NC}"
    apt-get update -qq
    apt-get install -y -qq openssh-server
    systemctl enable ssh
    systemctl start ssh
    echo -e "   ${GREEN}✓${NC} SSH server installed and enabled"
else
    echo -e "   ${GREEN}✓${NC} SSH server already running"
fi

# Optional configurations (commented out)
echo
echo -e "${BLUE}Optional configurations (edit script to enable):${NC}"
echo -e "${YELLOW}# Uncomment in script to enable:${NC}"
echo -e "${YELLOW}# - Cloud-init (for CIDATA USB usage later)${NC}"
echo -e "${YELLOW}# - Basic packages (vim, curl, wget, git, htop)${NC}"
echo -e "${YELLOW}# - Disable desktop environment (for headless server)${NC}"

# Optional: Cloud-init
# echo -e "${BLUE}Installing cloud-init...${NC}"
# apt-get install -y cloud-init
# systemctl enable cloud-init
# echo -e "   ${GREEN}✓${NC} Cloud-init enabled"

# Optional: Basic packages
# echo -e "${BLUE}Installing basic packages...${NC}"
# apt-get install -y vim curl wget git htop
# echo -e "   ${GREEN}✓${NC} Basic packages installed"

# Optional: Disable desktop for headless server
# echo -e "${BLUE}Disabling desktop environment...${NC}"
# systemctl set-default multi-user.target
# echo -e "   ${GREEN}✓${NC} Desktop disabled (headless mode)"

echo
echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Configuration Complete!              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Reboot the machine"
echo "  2. SSH in: ${BLUE}ssh ${ACTUAL_USER}@HOSTNAME_PLACEHOLDER.local${NC}"
echo "  3. Run your Ansible playbook"
echo
echo -e "${GREEN}Machine is ready for Ansible! 🚀${NC}"

SETUP_EOF

# Replace placeholders
sed -i "s|HOSTNAME_PLACEHOLDER|$HOSTNAME|g" setup-machine.sh

if [ -z "$SSH_KEY" ]; then
    sed -i "s|SSH_KEY_PLACEHOLDER|SKIP|" setup-machine.sh
else
    # Escape special characters for sed
    SSH_KEY_ESCAPED=$(echo "$SSH_KEY" | sed 's/[\/&]/\\&/g')
    sed -i "s|SSH_KEY_PLACEHOLDER|$SSH_KEY_ESCAPED|" setup-machine.sh
fi

chmod +x setup-machine.sh

echo -e "${GREEN}Step 7: Creating USB 1 (Boot ISO)...${NC}"

# Unmount USB1
umount "/dev/${USB1_DEVICE}"* 2>/dev/null || true
sleep 2

echo -e "${BLUE}Flashing ISO to USB1...${NC}"
dd if="$ISO_NAME" of="/dev/$USB1_DEVICE" bs=4M status=progress conv=fsync
sync
sleep 2

echo -e "${GREEN}Step 8: Creating USB 2 (Setup Script)...${NC}"

# Unmount USB2
umount "/dev/${USB2_DEVICE}"* 2>/dev/null || true
sleep 2

# Format USB2 as FAT32
echo -e "${BLUE}Formatting USB2...${NC}"
parted -s "/dev/$USB2_DEVICE" mklabel msdos
parted -s "/dev/$USB2_DEVICE" mkpart primary fat32 1MiB 100%
sleep 2
partprobe "/dev/$USB2_DEVICE"
sleep 2

mkfs.vfat -F 32 -n SETUP "/dev/${USB2_DEVICE}1"

# Mount and copy files
mkdir -p /mnt/setup
mount "/dev/${USB2_DEVICE}1" /mnt/setup

cp setup-machine.sh /mnt/setup/

# Create README
cat > /mnt/setup/README.txt << 'README_EOF'
╔═══════════════════════════════════════════════════════════╗
║            Ubuntu Post-Install Setup Script               ║
╚═══════════════════════════════════════════════════════════╝

After manual Ubuntu installation:

1. Boot into your new Ubuntu system

2. Insert this SETUP USB stick

3. Mount it (it should auto-mount to /media/username/SETUP)
   Or manually: sudo mount /dev/sdX1 /mnt

4. Run the setup script:
   sudo bash /media/username/SETUP/setup-machine.sh
   (Or: sudo bash /mnt/setup-machine.sh)

5. Reboot

6. SSH in and run your Ansible playbook!

The script configures:
✓ Hostname
✓ SSH key
✓ Passwordless sudo
✓ SSH server

Then use Ansible for the rest (Docker, Home Assistant, Pi-hole, etc)!
README_EOF

sync
umount /mnt/setup
rmdir /mnt/setup

echo
echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          SUCCESS! Both USB drives ready!      ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
echo
echo -e "${YELLOW}USB Setup:${NC}"
echo -e "  ${GREEN}USB 1 (/dev/$USB1_DEVICE):${NC} Ubuntu Desktop ISO (bootable, GUI installer!)"
echo -e "  ${GREEN}USB 2 (/dev/$USB2_DEVICE):${NC} Post-install script (labeled SETUP)"
echo
echo -e "${YELLOW}Installation Process:${NC}"
echo -e "  ${BLUE}1.${NC} Boot from USB 1 (GUI installer with mouse support!)"
echo -e "  ${BLUE}2.${NC} Manual install (~10 min):"
echo -e "     - Select language"
echo -e "     - Select disk (choose T7 - device names are visible!)"
echo -e "     - Create user (any username you want)"
echo -e "     - Configure WiFi"
echo -e "  ${BLUE}3.${NC} After first boot, insert USB 2"
echo -e "  ${BLUE}4.${NC} Run: ${GREEN}sudo bash /media/USERNAME/SETUP/setup-machine.sh${NC}"
echo -e "  ${BLUE}5.${NC} Reboot"
echo -e "  ${BLUE}6.${NC} SSH: ${GREEN}ssh USERNAME@$HOSTNAME.local${NC}"
echo -e "  ${BLUE}7.${NC} Run Ansible playbook"
echo
echo -e "${BLUE}Note: Setup script auto-detects the user created during installation${NC}"
echo -e "${BLUE}Desktop environment can be disabled after install if not needed${NC}"
echo
echo -e "${GREEN}Architecture: $ARCH${NC}"
echo -e "${GREEN}ISO: $ISO_NAME${NC}"
echo -e "${GREEN}Ready to install! 🚀${NC}"

cd /
rm -rf "$WORK_DIR"
