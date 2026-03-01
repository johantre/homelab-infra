#!/bin/bash
set -e

#==============================================================================
# Ubuntu Install USB Creator
# Single USB approach for both x86 and Raspberry Pi 4
#
# UNIFIED APPROACH:
# - Both use systemd firstboot service for auto-run
# - Both inject: setup-machine.sh + firstboot-setup.service
# - Desktop: Also adds autostart .desktop to show terminal with output
#
# x86:  Live ISO + SETUP partition (user runs inject script after install)
# Pi4:  Preinstalled image (inject during USB creation)
#==============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Constants
WORK_DIR="/tmp/ubuntu-install-usb"
CACHE_DIR="$HOME/.cache/ubuntu-install-usb"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create cache directory for persistent downloads
mkdir -p "$CACHE_DIR"

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

check_dependencies() {
    local deps=(curl jq wget parted mkfs.vfat xz mkfs.exfat)
    local pkg_map=(
        "curl:curl"
        "jq:jq"
        "wget:wget"
        "parted:parted"
        "mkfs.vfat:dosfstools"
        "xz:xz-utils"
        "mkfs.exfat:exfatprogs"
        "wipefs:util-linux"
        "resize2fs:e2fsprogs"
    )
    local missing_packages=()

    echo -e "${BLUE}Checking dependencies...${NC}"

    for mapping in "${pkg_map[@]}"; do
        local cmd="${mapping%%:*}"
        local pkg="${mapping##*:}"

        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${YELLOW}  Missing: $cmd (package: $pkg)${NC}"
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Installing missing packages: ${missing_packages[*]}${NC}"
        apt-get update -qq
        apt-get install -y "${missing_packages[@]}"
    else
        echo -e "${GREEN}  All dependencies OK${NC}"
    fi

    # Load exfat kernel module (needed for Ventoy)
    modprobe exfat 2>/dev/null || true
}

get_latest_ubuntu_version() {
    local lts_only=$1  # "yes" or "no"

    echo -e "${BLUE}Fetching latest Ubuntu version...${NC}" >&2

    local releases_page=$(curl -s "https://releases.ubuntu.com/" 2>&1)

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR] Failed to fetch releases page${NC}" >&2
        return 1
    fi

    local all_versions=$(echo "$releases_page" | \
        grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' | \
        grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | \
        sort -Vr)

    local latest_version
    if [[ "$lts_only" == "yes" ]]; then
        # LTS = even year + .04 (e.g., 24.04, 26.04)
        latest_version=$(echo "$all_versions" | grep -E '^[0-9]*[02468]\.04' | head -1)
    else
        latest_version=$(echo "$all_versions" | head -1)
    fi

    if [[ -z "$latest_version" ]]; then
        echo "24.04"  # Fallback
    else
        echo "$latest_version"
    fi
}

get_latest_x86_iso() {
    local version=$1

    echo -e "${BLUE}Finding latest x86 Desktop ISO for Ubuntu ${version}...${NC}" >&2

    # Check releases.ubuntu.com for the ISO
    local releases_url="https://releases.ubuntu.com/${version}/"
    local page=$(curl -s "$releases_url")

    # Find the desktop ISO (could be 24.04 or 24.04.1, etc.)
    local iso_name=$(echo "$page" | \
        grep -oE "ubuntu-${version}[^\"]*-desktop-amd64\.iso" | \
        sort -V | tail -1)

    if [[ -z "$iso_name" ]]; then
        # Try with point release
        iso_name="ubuntu-${version}-desktop-amd64.iso"
    fi

    local iso_url="${releases_url}${iso_name}"

    # Verify URL exists
    if curl -sf -I "$iso_url" > /dev/null 2>&1; then
        echo -e "${GREEN}Found: $iso_name${NC}" >&2
        echo "${iso_url}|${iso_name}"
    else
        echo -e "${RED}[ERROR] ISO not found at $iso_url${NC}" >&2
        return 1
    fi
}

get_latest_pi4_image() {
    local version=$1
    local type=$2  # "desktop" or "server"

    echo -e "${BLUE}Finding latest Raspberry Pi ${type} image for Ubuntu ${version}...${NC}" >&2

    local cdimage_url="https://cdimage.ubuntu.com/releases/${version}/release/"
    local page=$(curl -s "$cdimage_url")

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR] Failed to fetch cdimage page${NC}" >&2
        return 1
    fi

    # Find the preinstalled image (version can be X.Y or X.Y.Z)
    local image_name=$(echo "$page" | \
        grep -oE "ubuntu-[0-9]+\.[0-9]+(\.[0-9]+)?-preinstalled-${type}-arm64\+raspi\.img\.xz" | \
        sort -V | tail -1)

    if [[ -z "$image_name" ]]; then
        echo -e "${RED}[ERROR] No ${type} image found for Pi4${NC}" >&2
        return 1
    fi

    local image_url="${cdimage_url}${image_name}"

    # Verify URL exists
    if curl -sf -I "$image_url" > /dev/null 2>&1; then
        echo -e "${GREEN}Found: $image_name${NC}" >&2
        echo "${image_url}|${image_name}"
    else
        echo -e "${RED}[ERROR] Image not found at $image_url${NC}" >&2
        return 1
    fi
}

is_safe_usb() {
    local device=$1

    # Verify device exists in /sys/block
    if [ ! -d "/sys/block/$device" ]; then
        return 1
    fi

    # Verify device is a block device
    if [ ! -b "/dev/$device" ]; then
        return 1
    fi

    # Function to check if device has system mounts
    check_system_mounts() {
        local dev=$1
        # Check if mounted as root, boot, or home
        if mount | grep -q "^/dev/${dev}[0-9p]* on / "; then
            return 0  # Is system disk
        fi
        if mount | grep -q "^/dev/${dev}[0-9p]* on /boot"; then
            return 0  # Is system disk
        fi
        if mount | grep -q "^/dev/${dev}[0-9p]* on /home"; then
            return 0  # Is system disk
        fi
        return 1  # Not system disk
    }

    # Check 1: Use lsblk TRAN column (most reliable for USB detection)
    local transport=$(lsblk -d -n -o TRAN "/dev/$device" 2>/dev/null | tr -d '[:space:]')
    if [ "$transport" = "usb" ]; then
        if check_system_mounts "$device"; then
            return 1
        fi
        return 0
    fi

    # Check 2: Is it marked as removable? (fallback for older systems)
    if [ "$(cat /sys/block/$device/removable 2>/dev/null)" = "1" ]; then
        if check_system_mounts "$device"; then
            return 1
        fi
        return 0
    fi

    # Check 3: Is it on USB bus via sysfs path? (fallback)
    local device_path=$(readlink -f /sys/block/$device 2>/dev/null)
    if [ -n "$device_path" ] && echo "$device_path" | grep -q "/usb"; then
        if check_system_mounts "$device"; then
            return 1
        fi
        return 0
    fi

    return 1
}

select_usb_device() {
    echo -e "${BLUE}Available USB devices:${NC}"
    printf "%-4s %-10s %-10s %-6s %-30s\n" "NUM" "DEVICE" "SIZE" "TRAN" "MODEL"
    echo "-------------------------------------------------------------------"

    SAFE_DEVICES=()
    local counter=1

    # List devices from /sys/block to avoid lsblk issues
    for device in $(ls /sys/block/ | grep -E "^sd[a-z]+$|^nvme[0-9]+n[0-9]+$"); do
        # Verify device exists as block device
        if [ ! -b "/dev/$device" ]; then
            continue
        fi

        if is_safe_usb "$device"; then
            # Get size, model and transport safely
            local size=$(lsblk -d -n -o SIZE "/dev/$device" 2>/dev/null | tr -d '[:space:]')
            local model=$(lsblk -d -n -o MODEL "/dev/$device" 2>/dev/null | xargs || echo "")
            local tran=$(lsblk -d -n -o TRAN "/dev/$device" 2>/dev/null | tr -d '[:space:]')

            # Skip devices with 0 size (not ready)
            if [ "$size" = "0B" ] || [ -z "$size" ]; then
                continue
            fi

            printf "%-4s %-10s %-10s %-6s %-30s\n" "$counter" "$device" "$size" "$tran" "$model"
            SAFE_DEVICES+=("$device")
            counter=$((counter + 1))
        fi
    done

    echo

    if [ ${#SAFE_DEVICES[@]} -lt 1 ]; then
        echo -e "${RED}No USB devices found!${NC}"
        echo
        echo -e "${YELLOW}Debug info - All block devices:${NC}"
        lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null || true
        echo
        exit 1
    fi

    echo -ne "${YELLOW}Select USB device number [1]: ${NC}"
    read USB_NUM
    USB_NUM=${USB_NUM:-1}
    local idx=$((USB_NUM - 1))
    USB_DEVICE="${SAFE_DEVICES[$idx]}"

    echo -e "${GREEN}Selected: /dev/$USB_DEVICE${NC}"
}

gather_config() {
    echo -e "${GREEN}Configuration for post-install setup${NC}"
    echo

    echo -ne "${YELLOW}Hostname [homeassistant]: ${NC}"
    read HOSTNAME
    HOSTNAME=${HOSTNAME:-homeassistant}

    echo
    echo -e "${YELLOW}SSH Public Key (paste and press Enter, or leave empty):${NC}"
    echo -ne "${YELLOW}SSH Key: ${NC}"
    read SSH_KEY
    if [ -n "$SSH_KEY" ]; then
        tput cuu1
        echo -ne "\r${YELLOW}SSH Key: ${NC}"
        printf '*%.0s' $(seq 1 ${#SSH_KEY})
        tput el
        echo
        echo -e "${GREEN}SSH key received (${#SSH_KEY} chars)${NC}"
    else
        echo -e "${YELLOW}SSH key skipped${NC}"
    fi

    echo
    echo -e "${BLUE}GitHub Runner Configuration:${NC}"
    echo

    echo -ne "${YELLOW}GitHub Username [johantre]: ${NC}"
    read GH_USER
    GH_USER=${GH_USER:-johantre}

    echo -ne "${YELLOW}GitHub Repository [homelab-infra]: ${NC}"
    read GH_REPO
    GH_REPO=${GH_REPO:-homelab-infra}

    echo
    echo -e "${YELLOW}GitHub Personal Access Token (PAT):${NC}"
    echo -e "${BLUE}  Needs: repo, workflow, admin:org (manage_runners)${NC}"
    echo -ne "${YELLOW}PAT: ${NC}"
    IFS= read -r GH_PAT
    if [ -z "$GH_PAT" ]; then
        echo -e "${RED}ERROR: GitHub PAT is required${NC}"
        exit 1
    fi
    tput cuu1
    echo -ne "\r${YELLOW}PAT: ${NC}"
    printf '*%.0s' $(seq 1 ${#GH_PAT})
    tput el
    echo
    echo -e "${GREEN}PAT received (${#GH_PAT} chars)${NC}"

    GH_REPO_URL="https://github.com/${GH_USER}/${GH_REPO}"
}

gather_wifi_config() {
    # WiFi configuration - used by both x86 and Pi4
    echo
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  WiFi Configuration                    ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo

    echo -ne "${YELLOW}WiFi SSID: ${NC}"
    read WIFI_SSID
    if [ -z "$WIFI_SSID" ]; then
        echo -e "${YELLOW}No WiFi configured (will use ethernet)${NC}"
        WIFI_PASSWORD=""
    else
        echo -ne "${YELLOW}WiFi Password: ${NC}"
        read -s WIFI_PASSWORD
        echo
        echo -e "${GREEN}WiFi configured: $WIFI_SSID${NC}"
    fi
}

gather_user_account() {
    # User account configuration - used by both x86 and Pi4
    echo
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Ubuntu User Account                   ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo

    echo -ne "${YELLOW}Username [ubuntu]: ${NC}"
    read UBUNTU_USER
    UBUNTU_USER=${UBUNTU_USER:-ubuntu}

    echo -ne "${YELLOW}Password: ${NC}"
    read -s UBUNTU_PASSWORD
    echo
    if [ -z "$UBUNTU_PASSWORD" ]; then
        UBUNTU_PASSWORD="ubuntu"
        echo -e "${YELLOW}Using default password: ubuntu${NC}"
    else
        echo -e "${GREEN}Password set${NC}"
    fi

    echo -ne "${YELLOW}Full name [$UBUNTU_USER]: ${NC}"
    read UBUNTU_FULLNAME
    UBUNTU_FULLNAME=${UBUNTU_FULLNAME:-$UBUNTU_USER}
}

gather_config_x86_disk_selection() {
    # Disk selection - x86 only
    echo
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  Target Disk Selection                 ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}How should Ubuntu identify the target disk during install?${NC}"
    echo
    echo "1) By model name (e.g., 'Samsung T7' - recommended)"
    echo "2) Interactive (you choose during install)"
    echo
    echo -ne "${YELLOW}Select (1-2) [1]: ${NC}"
    read DISK_SELECT_METHOD
    DISK_SELECT_METHOD=${DISK_SELECT_METHOD:-1}

    if [ "$DISK_SELECT_METHOD" = "1" ]; then
        echo
        echo -e "${YELLOW}Enter part of the disk model name:${NC}"
        echo -e "${BLUE}(e.g., 'Samsung T7' or 'T7' or 'Samsung')${NC}"
        echo -ne "${YELLOW}Model pattern: ${NC}"
        read TARGET_DISK_MODEL
        if [ -z "$TARGET_DISK_MODEL" ]; then
            echo -e "${RED}No model specified, falling back to interactive${NC}"
            DISK_SELECT_METHOD="2"
        else
            echo -e "${GREEN}Will install to disk matching: *${TARGET_DISK_MODEL}*${NC}"
        fi
    fi

    if [ "$DISK_SELECT_METHOD" = "2" ]; then
        TARGET_DISK_MODEL=""
        echo -e "${YELLOW}You will select the disk during Ubuntu install${NC}"
    fi
}

generate_pi4_cloud_init() {
    local output_file=$1

    # Generate password hash
    local password_hash=$(echo "$UBUNTU_PASSWORD" | openssl passwd -6 -stdin)

    cat > "$output_file" << CLOUDINIT_EOF
#cloud-config

# Keyboard configuration
keyboard:
  layout: be

# Disable password expiry (no forced change on first login)
chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: "${password_hash}"
      type: hash

# Ensure ubuntu user exists with correct settings
users:
  - name: ubuntu
    gecos: "${UBUNTU_FULLNAME}"
    groups: [adm, sudo, users, plugdev]
    shell: /bin/bash
    lock_passwd: false
CLOUDINIT_EOF

    echo -e "${GREEN}Generated cloud-init user-data${NC}"
}

generate_autoinstall_yaml() {
    local output_file=$1
    local setup_script_content=$2  # Pre-generated setup script content

    # Generate password hash
    local password_hash=$(echo "$UBUNTU_PASSWORD" | openssl passwd -6 -stdin)

    # Determine storage config
    local storage_config=""
    if [ -n "$TARGET_DISK_MODEL" ]; then
        # Automatic disk selection by model
        storage_config="
  storage:
    layout:
      name: custom
    config:
      - id: disk0
        type: disk
        match:
          model: \"*${TARGET_DISK_MODEL}*\"
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: true
      - id: efi-part
        type: partition
        device: disk0
        size: 512M
        flag: boot
        grub_device: true
      - id: efi-format
        type: format
        volume: efi-part
        fstype: fat32
      - id: root-part
        type: partition
        device: disk0
        size: 80G
      - id: root-format
        type: format
        volume: root-part
        fstype: ext4
      - id: backup-part
        type: partition
        device: disk0
        size: -1
      - id: backup-format
        type: format
        volume: backup-part
        fstype: ext4
      - id: efi-mount
        type: mount
        device: efi-format
        path: /boot/efi
      - id: root-mount
        type: mount
        device: root-format
        path: /
      - id: backup-mount
        type: mount
        device: backup-format
        path: /backup"
    else
        # Interactive storage selection
        storage_config="
  interactive-sections:
    - storage"
    fi

    # NOTE: WiFi is configured in post-install setup script (setup-machine.sh)
    # This avoids netplan errors during live installer boot

    # Write the YAML header
    cat > "$output_file" << AUTOINSTALL_EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: be
  identity:
    hostname: ${HOSTNAME}
    username: ${UBUNTU_USER}
    password: "${password_hash}"
    realname: "${UBUNTU_FULLNAME}"
${storage_config}
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    # Embed setup script directly (Ventoy partition can't be mounted during install)
    - |
      cat > /target/opt/setup-machine.sh << 'SETUPSCRIPTEOF'
AUTOINSTALL_EOF

    # Append the setup script content (indented for YAML)
    echo "$setup_script_content" | sed 's/^/      /' >> "$output_file"

    # Close the heredoc and add remaining commands
    cat >> "$output_file" << 'AUTOINSTALL_EOF2'
      SETUPSCRIPTEOF
      chmod +x /target/opt/setup-machine.sh
    # Create firstboot service
    - |
      cat > /target/etc/systemd/system/firstboot-setup.service << 'SERVICEEOF'
      [Unit]
      Description=First Boot Setup
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStartPre=/bin/sleep 15
      ExecStart=/opt/setup-machine.sh
      RemainAfterExit=yes
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target
      SERVICEEOF
    - curtin in-target -- systemctl enable firstboot-setup.service
AUTOINSTALL_EOF2

    echo -e "${GREEN}Generated autoinstall.yaml with embedded setup script${NC}"
}

generate_setup_script() {
    local output_file=$1
    local arch=$2  # "x86_64" or "arm64"

    cat > "$output_file" << 'SETUP_SCRIPT_EOF'
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Post-Install Configuration Script  ${NC}"
echo -e "${GREEN}======================================${NC}"
echo

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Run with sudo!${NC}"
   exit 1
fi

# Detect user
# Detect user (fallback to ubuntu if running via systemd where logname fails)
ACTUAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[ -z "$ACTUAL_USER" ] && ACTUAL_USER="ubuntu"
echo -e "${BLUE}User: ${ACTUAL_USER}${NC}"
echo -e "${BLUE}Hostname: __HOSTNAME__${NC}"
echo

# 1. Set hostname
echo -e "${GREEN}[1/7] Setting hostname...${NC}"
hostnamectl set-hostname __HOSTNAME__
echo "__HOSTNAME__" > /etc/hostname
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1    __HOSTNAME__" >> /etc/hosts
echo -e "   ${GREEN}Done${NC}"

# 2. SSH key
SSH_KEY="__SSH_KEY__"
if [ -n "$SSH_KEY" ] && [ "$SSH_KEY" != "SKIP" ]; then
    echo -e "${GREEN}[2/7] Adding SSH key...${NC}"
    USER_HOME=$(eval echo ~${ACTUAL_USER})
    mkdir -p "$USER_HOME/.ssh"
    if ! grep -q "$SSH_KEY" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$SSH_KEY" >> "$USER_HOME/.ssh/authorized_keys"
    fi
    chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    echo -e "   ${GREEN}Done${NC}"
else
    echo -e "${YELLOW}[2/7] SSH key skipped${NC}"
fi

# 3. Passwordless sudo
echo -e "${GREEN}[3/7] Configuring sudo...${NC}"
echo "${ACTUAL_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${ACTUAL_USER}
chmod 440 /etc/sudoers.d/${ACTUAL_USER}
echo -e "   ${GREEN}Done${NC}"

# 4. SSH server
echo -e "${GREEN}[4/7] Checking SSH server...${NC}"
if ! systemctl is-active --quiet ssh; then
    apt-get update -qq
    apt-get install -y -qq openssh-server
    systemctl enable ssh
    systemctl start ssh
fi
echo -e "   ${GREEN}Done${NC}"

# 5. WiFi configuration
WIFI_SSID="__WIFI_SSID__"
WIFI_PASSWORD="__WIFI_PASSWORD__"
if [ -n "$WIFI_SSID" ] && [ "$WIFI_SSID" != "SKIP" ]; then
    echo -e "${GREEN}[5/7] Configuring WiFi...${NC}"
    # Use nmcli (NetworkManager) - works on both Desktop and Server
    if command -v nmcli &> /dev/null; then
        # Delete existing connection with same name if exists
        nmcli connection delete "$WIFI_SSID" 2>/dev/null || true
        # Create new WiFi connection
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" || {
            echo -e "${YELLOW}   WiFi connection failed (adapter may not be ready)${NC}"
            echo -e "${YELLOW}   Creating connection profile for later...${NC}"
            nmcli connection add type wifi con-name "$WIFI_SSID" ssid "$WIFI_SSID" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASSWORD"
        }
        echo -e "   ${GREEN}Done${NC}"
    else
        echo -e "${YELLOW}   NetworkManager not found, creating netplan config...${NC}"
        cat > /etc/netplan/99-wifi.yaml << WIFIEOF
network:
  version: 2
  renderer: NetworkManager
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "$WIFI_SSID":
          password: "$WIFI_PASSWORD"
WIFIEOF
        chmod 600 /etc/netplan/99-wifi.yaml
        netplan apply 2>/dev/null || echo -e "${YELLOW}   Netplan apply deferred to next boot${NC}"
        echo -e "   ${GREEN}Done${NC}"
    fi
else
    echo -e "${YELLOW}[5/7] WiFi skipped${NC}"
fi

# 6. GitHub Runner
echo -e "${GREEN}[6/7] Installing GitHub Runner...${NC}"
GH_USER="__GH_USER__"
GH_REPO="__GH_REPO__"
GH_PAT="__GH_PAT__"
GH_REPO_URL="__GH_REPO_URL__"

if [ -n "$GH_PAT" ] && [ "$GH_PAT" != "SKIP" ]; then
    # Install dependencies
    apt-get update -qq
    apt-get install -y -qq curl jq wget

    # Install GitHub CLI
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y -qq gh

    # Authenticate
    sudo -u ${ACTUAL_USER} gh auth logout 2>/dev/null || true
    echo "$GH_PAT" | sudo -u ${ACTUAL_USER} gh auth login --with-token

    # Get runner token
    RUNNER_TOKEN=$(sudo -u ${ACTUAL_USER} gh api --method POST \
        -H "Accept: application/vnd.github+json" \
        /repos/${GH_USER}/${GH_REPO}/actions/runners/registration-token \
        | jq -r .token)

    if [ -n "$RUNNER_TOKEN" ] && [ "$RUNNER_TOKEN" != "null" ]; then
        USER_HOME=$(eval echo ~${ACTUAL_USER})
        RUNNER_DIR="$USER_HOME/actions-runner"
        mkdir -p "$RUNNER_DIR"
        chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$RUNNER_DIR"
        cd "$RUNNER_DIR"

        # Download runner
        RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/v//')
        RUNNER_ARCH="__RUNNER_ARCH__"
        RUNNER_FILE="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

        sudo -u ${ACTUAL_USER} wget -q --show-progress \
            "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_FILE}"
        sudo -u ${ACTUAL_USER} tar xzf "$RUNNER_FILE"
        rm "$RUNNER_FILE"

        # Remove existing runner with same name
        RUNNER_NAME="$(hostname)"
        EXISTING_IDS=$(sudo -u ${ACTUAL_USER} gh api \
            /repos/${GH_USER}/${GH_REPO}/actions/runners \
            --paginate -q '.runners[] | select(.name=="'"${RUNNER_NAME}"'") | .id' || true)

        for id in $EXISTING_IDS; do
            sudo -u ${ACTUAL_USER} gh api --method DELETE \
                "/repos/${GH_USER}/${GH_REPO}/actions/runners/${id}" >/dev/null 2>&1 || true
        done

        # Configure and start
        sudo -u ${ACTUAL_USER} ./config.sh \
            --url "$GH_REPO_URL" \
            --token "$RUNNER_TOKEN" \
            --name "${RUNNER_NAME}" \
            --labels "self-hosted,linux,$(uname -m)" \
            --unattended

        ./svc.sh install ${ACTUAL_USER}
        ./svc.sh start
        echo -e "   ${GREEN}Runner installed${NC}"
    else
        echo -e "   ${RED}Failed to get runner token${NC}"
    fi
else
    echo -e "${YELLOW}   Skipped (no PAT)${NC}"
fi

# 7. Cleanup firstboot service and all related files
echo -e "${GREEN}[7/7] Cleanup...${NC}"
if [ -f /etc/systemd/system/firstboot-setup.service ]; then
    systemctl disable firstboot-setup.service 2>/dev/null || true
    rm -f /etc/systemd/system/firstboot-setup.service
fi
# Remove entire firstboot directory (includes setup-machine.sh, run-setup-in-terminal.sh, etc)
rm -rf /opt/firstboot 2>/dev/null || true
echo -e "   ${GREEN}Done${NC}"

echo
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Configuration Complete!             ${NC}"
echo -e "${GREEN}======================================${NC}"
echo
echo -e "${YELLOW}Summary:${NC}"
echo "  Hostname: __HOSTNAME__"
echo "  SSH: configured"
echo "  Sudo: passwordless"
echo "  Runner: installed"
echo
echo -e "${YELLOW}Next:${NC}"
echo "  1. Reboot"
echo "  2. SSH: ssh ${ACTUAL_USER}@__HOSTNAME__.local"
echo

# Self-destruct
echo -e "${RED}========================================${NC}"
echo -e "${RED}  SELF-DESTRUCT SEQUENCE INITIATED     ${NC}"
echo -e "${RED}========================================${NC}"
echo

# Try to delete autoinstall.yaml from USB if still mounted
echo -e "${YELLOW}Searching for autoinstall.yaml...${NC}"
for mount_point in /cdrom /media/*/* /run/media/*/*; do
    if [ -f "${mount_point}/SETUP/autoinstall.yaml" ]; then
        echo -e "${YELLOW}Found: ${mount_point}/SETUP/autoinstall.yaml${NC}"
        rm -f "${mount_point}/SETUP/autoinstall.yaml" 2>/dev/null && \
            echo -e "${GREEN}Deleted autoinstall.yaml${NC}" || \
            echo -e "${YELLOW}Could not delete (USB may be read-only or removed)${NC}"
    fi
    if [ -f "${mount_point}/ventoy/ventoy.json" ]; then
        rm -f "${mount_point}/ventoy/ventoy.json" 2>/dev/null && \
            echo -e "${GREEN}Deleted ventoy.json${NC}" || true
    fi
done

echo
echo -e "${RED}Self-destructing in 3...${NC}"
sleep 1
echo -e "${RED}2...${NC}"
sleep 1
echo -e "${RED}1...${NC}"
sleep 1

# Delete this script
SCRIPT_PATH="${BASH_SOURCE[0]}"
rm -f "$SCRIPT_PATH"
echo -e "${GREEN}Setup script removed.${NC}"

# Also clean up /opt/setup-machine.sh if different location
rm -f /opt/setup-machine.sh 2>/dev/null || true

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ALL SENSITIVE DATA DESTROYED         ${NC}"
echo -e "${GREEN}========================================${NC}"
SETUP_SCRIPT_EOF

    # Replace placeholders
    sed -i "s|__HOSTNAME__|$HOSTNAME|g" "$output_file"

    if [ -z "$SSH_KEY" ]; then
        sed -i "s|__SSH_KEY__|SKIP|" "$output_file"
    else
        local ssh_escaped=$(echo "$SSH_KEY" | sed 's/[\/&]/\\&/g')
        sed -i "s|__SSH_KEY__|$ssh_escaped|" "$output_file"
    fi

    sed -i "s|__GH_USER__|$GH_USER|g" "$output_file"
    sed -i "s|__GH_REPO__|$GH_REPO|g" "$output_file"
    sed -i "s|__GH_REPO_URL__|$GH_REPO_URL|g" "$output_file"

    # WiFi credentials
    if [ -z "$WIFI_SSID" ]; then
        sed -i "s|__WIFI_SSID__|SKIP|" "$output_file"
        sed -i "s|__WIFI_PASSWORD__||" "$output_file"
    else
        sed -i "s|__WIFI_SSID__|$WIFI_SSID|g" "$output_file"
        local wifi_pass_escaped=$(echo "$WIFI_PASSWORD" | sed 's/[\/&]/\\&/g')
        sed -i "s|__WIFI_PASSWORD__|$wifi_pass_escaped|" "$output_file"
    fi

    if [ -z "$GH_PAT" ]; then
        sed -i "s|__GH_PAT__|SKIP|" "$output_file"
    else
        local pat_escaped=$(echo "$GH_PAT" | sed 's/[\/&]/\\&/g')
        sed -i "s|__GH_PAT__|$pat_escaped|" "$output_file"
    fi

    # Set runner architecture
    if [ "$arch" = "arm64" ]; then
        sed -i "s|__RUNNER_ARCH__|arm64|g" "$output_file"
    else
        sed -i "s|__RUNNER_ARCH__|x64|g" "$output_file"
    fi

    chmod +x "$output_file"
}

generate_firstboot_service() {
    local output_file=$1
    local is_desktop=$2  # "yes" or "no" - kept for compatibility but both use same service now

    # NOTE: Previously desktop mode used run-setup-in-terminal.sh to open a GUI terminal,
    # but this failed when accessed via SSH (no X11 display). Now both desktop and server
    # use the same reliable approach: run directly after network is ready.
    # The terminal launcher script is still generated but not used by the service.

    cat > "$output_file" << 'SERVICE_EOF'
[Unit]
Description=First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/opt/firstboot/setup-machine.sh

[Service]
Type=oneshot
# Wait for network to be fully ready
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash /opt/firstboot/setup-machine.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE_EOF
}

generate_terminal_launcher() {
    local output_file=$1

    cat > "$output_file" << 'LAUNCHER_EOF'
#!/bin/bash
# Launch setup script in a visible terminal window

# Find the logged-in user
DESKTOP_USER=$(who | grep -E '\(:0\)|\(:[0-9]+\)' | head -1 | awk '{print $1}')
if [ -z "$DESKTOP_USER" ]; then
    DESKTOP_USER=$(ls -1 /home | head -1)
fi

# Get user's display
export DISPLAY=:0
export XAUTHORITY="/home/${DESKTOP_USER}/.Xauthority"

# Try different terminal emulators
if command -v gnome-terminal &> /dev/null; then
    sudo -u "$DESKTOP_USER" gnome-terminal --wait -- bash -c "sudo /opt/firstboot/setup-machine.sh; echo; echo 'Press Enter to close...'; read"
elif command -v xfce4-terminal &> /dev/null; then
    sudo -u "$DESKTOP_USER" xfce4-terminal --hold -e "sudo /opt/firstboot/setup-machine.sh"
elif command -v konsole &> /dev/null; then
    sudo -u "$DESKTOP_USER" konsole --hold -e "sudo /opt/firstboot/setup-machine.sh"
elif command -v xterm &> /dev/null; then
    sudo -u "$DESKTOP_USER" xterm -hold -e "sudo /opt/firstboot/setup-machine.sh"
else
    # Fallback: just run it
    /opt/firstboot/setup-machine.sh
fi

# Disable the service after running
systemctl disable firstboot-setup.service 2>/dev/null || true
LAUNCHER_EOF
    chmod +x "$output_file"
}

generate_flash_to_m2_script() {
    local output_file=$1
    local target_image_name=$2
    local is_desktop=$3

    # Generate password hash for embedding in cloud-init
    local password_hash=$(echo "$UBUNTU_PASSWORD" | openssl passwd -6 -stdin)

    cat > "$output_file" << 'FLASH_EOF'
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
cat << "BANNER"
 _____ _           _       _          __  __ ____
|  ___| | __ _ ___| |__   | |_ ___   |  \/  |___ \
| |_  | |/ _` / __| '_ \  | __/ _ \  | |\/| | __) |
|  _| | | (_| \__ \ | | | | || (_) | | |  | |/ __/
|_|   |_|\__,_|___/_| |_|  \__\___/  |_|  |_|_____|

  Flash Ubuntu to Argon One M.2 SSD
BANNER
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Run with sudo!${NC}"
   exit 1
fi

# Resolve symlinks to get actual script location (important for /usr/local/bin symlink)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TARGET_IMAGE="__TARGET_IMAGE__"
IS_DESKTOP="__IS_DESKTOP__"

# Find the boot device (USB SSD we're running from)
BOOT_DEVICE=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p$//')
echo -e "${BLUE}Boot device: ${BOOT_DEVICE}${NC}"

# Find the M.2 SSD (should be a different device)
echo -e "${GREEN}Scanning for M.2 SSD...${NC}"
echo

M2_DEVICE=""
for dev in /dev/sd? /dev/nvme?n?; do
    if [ -b "$dev" ] && [ "$dev" != "$BOOT_DEVICE" ]; then
        SIZE=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null)
        MODEL=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null | xargs)
        echo -e "  Found: ${GREEN}$dev${NC} - $SIZE - $MODEL"
        if [ -z "$M2_DEVICE" ]; then
            M2_DEVICE="$dev"
        fi
    fi
done

echo
if [ -z "$M2_DEVICE" ]; then
    echo -e "${RED}No M.2 SSD found!${NC}"
    echo -e "${YELLOW}Make sure the Argon One case is properly connected.${NC}"
    exit 1
fi

echo -e "${YELLOW}Target M.2 SSD: ${M2_DEVICE}${NC}"
echo
echo -e "${RED}WARNING: All data on ${M2_DEVICE} will be erased!${NC}"
echo -ne "${YELLOW}Continue? (yes/no): ${NC}"
read CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Check if target image exists
if [ ! -f "${SCRIPT_DIR}/${TARGET_IMAGE}" ]; then
    echo -e "${RED}Target image not found: ${SCRIPT_DIR}/${TARGET_IMAGE}${NC}"
    exit 1
fi

echo
echo -e "${GREEN}Flashing Ubuntu to M.2 SSD...${NC}"
echo -e "${BLUE}This will take several minutes...${NC}"
echo

# Unmount any partitions on target
for part in ${M2_DEVICE}*; do
    umount "$part" 2>/dev/null || true
done

# Flash the image
xz -dc "${SCRIPT_DIR}/${TARGET_IMAGE}" | dd of="${M2_DEVICE}" bs=4M status=progress conv=fsync
sync
sleep 2

# Re-read partition table
partprobe "${M2_DEVICE}"
sleep 3

echo
echo -e "${GREEN}Flash complete!${NC}"

# Find rootfs partition on M.2
M2_ROOTFS=""
if [ -b "${M2_DEVICE}2" ]; then
    M2_ROOTFS="${M2_DEVICE}2"
elif [ -b "${M2_DEVICE}p2" ]; then
    M2_ROOTFS="${M2_DEVICE}p2"
else
    echo -e "${RED}Could not find rootfs partition on M.2${NC}"
    exit 1
fi

# ============================================
# AUTOMATIC PARTITIONING: 80GB root + backup
# ============================================
echo
echo -e "${GREEN}Partitioning M.2 SSD (80GB root + backup)...${NC}"

# Get disk size in bytes
DISK_SIZE_BYTES=$(blockdev --getsize64 "${M2_DEVICE}")
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1000000000))
echo -e "${BLUE}Disk size: ${DISK_SIZE_GB}GB${NC}"

# Only partition if disk is large enough (> 100GB)
if [ "$DISK_SIZE_GB" -gt 100 ]; then
    # NOTE: Fresh Ubuntu image has small partition (~4GB). We need to:
    # 1. FIRST expand partition to 88GB
    # 2. THEN resize filesystem to 80GiB
    # The old order (resize2fs before parted) failed because filesystem
    # can't grow larger than partition!

    echo -e "${BLUE}[1/5] Expanding partition to 88GB...${NC}"
    # parted uses GB (1000-based), 88GB gives room for 80GiB filesystem
    parted -s "${M2_DEVICE}" resizepart 2 88GB

    # Re-read partition table after resize
    partprobe "${M2_DEVICE}"
    sleep 2

    echo -e "${BLUE}[2/5] Checking filesystem...${NC}"
    e2fsck -f -y "${M2_ROOTFS}" 2>/dev/null || true

    echo -e "${BLUE}[3/5] Resizing filesystem to 80GiB...${NC}"
    # resize2fs uses GiB (1024-based), so 80G = 80 GiB
    # This now works because partition is already 88GB
    resize2fs "${M2_ROOTFS}" 80G

    echo -e "${BLUE}[4/5] Creating backup partition...${NC}"
    parted -s "${M2_DEVICE}" mkpart primary ext4 88GB 100%

    # Re-read partition table so kernel can detect existing filesystem
    partprobe "${M2_DEVICE}"
    sleep 2

    # Find and format the new backup partition
    M2_BACKUP=""
    if [ -b "${M2_DEVICE}3" ]; then
        M2_BACKUP="${M2_DEVICE}3"
    elif [ -b "${M2_DEVICE}p3" ]; then
        M2_BACKUP="${M2_DEVICE}p3"
    fi

    if [ -n "$M2_BACKUP" ]; then
        BACKUP_SIZE=$(lsblk -n -o SIZE "$M2_BACKUP" 2>/dev/null)
        EXISTING_LABEL=$(lsblk -n -o LABEL "$M2_BACKUP" 2>/dev/null | xargs)
        EXISTING_FSTYPE=$(lsblk -n -o FSTYPE "$M2_BACKUP" 2>/dev/null | xargs)

        if [ "$EXISTING_LABEL" = "backup" ] && [ "$EXISTING_FSTYPE" = "ext4" ]; then
            # Existing backup partition found - ask user what to do
            echo
            echo -e "${CYAN}========================================${NC}"
            echo -e "${CYAN}  Existing backup partition detected!  ${NC}"
            echo -e "${CYAN}========================================${NC}"
            echo -e "${YELLOW}Size: ${BACKUP_SIZE}${NC}"
            echo
            echo -e "${YELLOW}This partition may contain Home Assistant backups.${NC}"
            echo -ne "${YELLOW}Preserve existing data? (yes/no): ${NC}"
            read PRESERVE_BACKUP

            if [ "$PRESERVE_BACKUP" = "yes" ]; then
                echo -e "${GREEN}[5/5] Preserving existing backup partition${NC}"
                echo -e "${GREEN}Backup data preserved!${NC}"
            else
                echo -e "${BLUE}[5/5] Formatting backup partition...${NC}"
                mkfs.ext4 -F -L backup "$M2_BACKUP"
                echo -e "${GREEN}Backup partition formatted: ${BACKUP_SIZE}${NC}"
            fi
        else
            # No existing backup - format it
            echo -e "${BLUE}[5/5] Formatting backup partition...${NC}"
            mkfs.ext4 -L backup "$M2_BACKUP"
            echo -e "${GREEN}Backup partition created: ${BACKUP_SIZE}${NC}"
        fi
    fi

    # Re-read partition table
    partprobe "${M2_DEVICE}"
    sleep 2

    echo -e "${GREEN}Partitioning complete!${NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "${M2_DEVICE}"

    # Mount rootfs to add fstab entry for backup partition
    mkdir -p /mnt/m2root
    mount "${M2_ROOTFS}" /mnt/m2root

    # Create backup mount point
    mkdir -p /mnt/m2root/mnt/backup

    # Add backup partition to fstab (use partition 3, which is standard for Pi4)
    # Using /dev/sda3 as Pi4 sees its M.2 as /dev/sda when booting from it
    if ! grep -q "/mnt/backup" /mnt/m2root/etc/fstab; then
        echo "/dev/sda3 /mnt/backup ext4 defaults 0 2" >> /mnt/m2root/etc/fstab
        echo -e "${GREEN}Added /mnt/backup to fstab${NC}"
    fi

    sync
    umount /mnt/m2root
    rmdir /mnt/m2root
else
    echo -e "${YELLOW}Disk too small for partitioning (${DISK_SIZE_GB}GB < 100GB), skipping${NC}"
fi

echo
echo -e "${GREEN}Injecting post-install setup...${NC}"

# Mount and inject
mkdir -p /mnt/m2root
mount "${M2_ROOTFS}" /mnt/m2root

# Create firstboot directory
mkdir -p /mnt/m2root/opt/firstboot

# Copy setup script
cp "${SCRIPT_DIR}/setup-machine.sh" /mnt/m2root/opt/firstboot/
chmod +x /mnt/m2root/opt/firstboot/setup-machine.sh

# Copy systemd service
cp "${SCRIPT_DIR}/firstboot-setup.service" /mnt/m2root/etc/systemd/system/

# Copy terminal launcher (kept for manual use, but service runs directly now)
if [ "$IS_DESKTOP" = "yes" ] && [ -f "${SCRIPT_DIR}/run-setup-in-terminal.sh" ]; then
    cp "${SCRIPT_DIR}/run-setup-in-terminal.sh" /mnt/m2root/opt/firstboot/
    chmod +x /mnt/m2root/opt/firstboot/run-setup-in-terminal.sh
fi

# Always enable via multi-user.target (works for both desktop and server)
mkdir -p /mnt/m2root/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/firstboot-setup.service \
    /mnt/m2root/etc/systemd/system/multi-user.target.wants/firstboot-setup.service

sync
umount /mnt/m2root
rmdir /mnt/m2root

# Find and mount M.2 boot partition for cloud-init injection
echo -e "${GREEN}Injecting cloud-init config (keyboard BE + password)...${NC}"
M2_BOOT=""
if [ -b "${M2_DEVICE}1" ]; then
    M2_BOOT="${M2_DEVICE}1"
elif [ -b "${M2_DEVICE}p1" ]; then
    M2_BOOT="${M2_DEVICE}p1"
else
    echo -e "${YELLOW}Could not find boot partition, skipping cloud-init${NC}"
fi

if [ -n "$M2_BOOT" ]; then
    mkdir -p /mnt/m2boot
    mount "${M2_BOOT}" /mnt/m2boot

    # Write cloud-init user-data
    cat > /mnt/m2boot/user-data << 'CLOUDINIT_M2_EOF'
#cloud-config

# Keyboard configuration
keyboard:
  layout: be

# Disable password expiry (no forced change on first login)
chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: "__PASSWORD_HASH__"
      type: hash

# Ensure ubuntu user exists with correct settings
users:
  - name: ubuntu
    gecos: "__FULLNAME__"
    groups: [adm, sudo, users, plugdev]
    shell: /bin/bash
    lock_passwd: false
CLOUDINIT_M2_EOF

    # Create empty meta-data
    echo "instance-id: pi4-m2-installed" > /mnt/m2boot/meta-data

    sync
    umount /mnt/m2boot
    rmdir /mnt/m2boot
    echo -e "${GREEN}Cloud-init injected${NC}"
fi

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  M.2 SSD Ready!                       ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Power off the Pi4"
echo "  2. Remove this USB SSD"
echo "  3. Power on - Pi4 will boot from M.2 SSD"
echo "  4. Post-install setup runs automatically"
if [ "$IS_DESKTOP" = "yes" ]; then
    echo "  5. A terminal window shows progress + self-destruct!"
fi
echo
echo -e "${BLUE}Login: ubuntu / (your configured password)${NC}"
echo
echo -ne "${YELLOW}Power off now? (yes/no): ${NC}"
read POWEROFF
if [ "$POWEROFF" = "yes" ]; then
    poweroff
fi
FLASH_EOF

    # Replace placeholders
    sed -i "s|__TARGET_IMAGE__|$target_image_name|g" "$output_file"
    sed -i "s|__IS_DESKTOP__|$is_desktop|g" "$output_file"
    sed -i "s|__PASSWORD_HASH__|$password_hash|g" "$output_file"
    sed -i "s|__FULLNAME__|$UBUNTU_FULLNAME|g" "$output_file"
    chmod +x "$output_file"
}

generate_inject_script() {
    local output_file=$1
    local is_desktop=$2

    cat > "$output_file" << 'INJECT_EOF'
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Inject Firstboot Setup into Target   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Run with sudo!${NC}"
   exit 1
fi

# Find the SETUP partition (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Find target system - try common mount points
TARGET=""
for mount_point in /target /mnt /media/*/; do
    if [ -d "${mount_point}/etc/systemd/system" ] && [ -f "${mount_point}/etc/os-release" ]; then
        TARGET="$mount_point"
        break
    fi
done

if [ -z "$TARGET" ]; then
    echo -e "${YELLOW}Target system not found at common locations.${NC}"
    echo -e "${YELLOW}Please enter the mount point of your new Ubuntu installation:${NC}"
    echo -e "${BLUE}(e.g., /mnt or /target)${NC}"
    echo -ne "${YELLOW}Mount point: ${NC}"
    read TARGET

    if [ ! -d "${TARGET}/etc/systemd/system" ]; then
        echo -e "${RED}Invalid target: ${TARGET}/etc/systemd/system not found${NC}"
        echo
        echo -e "${YELLOW}You may need to mount your new installation first:${NC}"
        echo "  1. Find the partition: lsblk"
        echo "  2. Mount it: sudo mount /dev/sdXY /mnt"
        echo "  3. Run this script again"
        exit 1
    fi
fi

echo -e "${GREEN}Target system found: ${TARGET}${NC}"
echo

# Create firstboot directory
echo -e "${BLUE}Creating firstboot directory...${NC}"
mkdir -p "${TARGET}/opt/firstboot"

# Copy setup script
echo -e "${BLUE}Copying setup script...${NC}"
cp "${SCRIPT_DIR}/setup-machine.sh" "${TARGET}/opt/firstboot/"
chmod +x "${TARGET}/opt/firstboot/setup-machine.sh"

# Copy systemd service
echo -e "${BLUE}Installing systemd service...${NC}"
cp "${SCRIPT_DIR}/firstboot-setup.service" "${TARGET}/etc/systemd/system/"

# For desktop: also copy the terminal launcher
if [ -f "${SCRIPT_DIR}/run-setup-in-terminal.sh" ]; then
    echo -e "${BLUE}Installing terminal launcher (desktop mode)...${NC}"
    cp "${SCRIPT_DIR}/run-setup-in-terminal.sh" "${TARGET}/opt/firstboot/"
    chmod +x "${TARGET}/opt/firstboot/run-setup-in-terminal.sh"
fi

# Enable the service
echo -e "${BLUE}Enabling firstboot service...${NC}"
# Create symlink to enable the service (multi-user.target works for both desktop and server)
mkdir -p "${TARGET}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/firstboot-setup.service \
    "${TARGET}/etc/systemd/system/multi-user.target.wants/firstboot-setup.service" 2>/dev/null || true

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Injection Complete!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Unmount target if needed: sudo umount ${TARGET}"
echo "  2. Remove USB"
echo "  3. Reboot into your new system"
echo "  4. Setup will run automatically!"
echo
echo -e "${BLUE}On first boot, a terminal window will open${NC}"
echo -e "${BLUE}showing the setup progress and self-destruct sequence.${NC}"
echo
INJECT_EOF
    chmod +x "$output_file"
}

#==============================================================================
# x86 INSTALLATION (using Ventoy)
#==============================================================================

get_latest_ventoy() {
    echo -e "${BLUE}Finding latest Ventoy version...${NC}" >&2

    local api_url="https://api.github.com/repos/ventoy/Ventoy/releases/latest"
    local release_info=$(curl -s "$api_url")

    local version=$(echo "$release_info" | jq -r '.tag_name' | sed 's/^v//')
    local download_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | contains("linux.tar.gz")) | .browser_download_url')

    if [[ -z "$version" || -z "$download_url" ]]; then
        echo -e "${RED}Failed to get Ventoy info${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Found Ventoy $version${NC}" >&2
    echo "${download_url}|ventoy-${version}-linux.tar.gz|${version}"
}

create_x86_usb() {
    local version=$1

    echo -e "${GREEN}Creating x86 Install USB (Ventoy)...${NC}"
    echo
    echo -e "${BLUE}Ventoy creates a multi-boot USB where you can just copy ISO files${NC}"
    echo

    # Get ISO info
    local iso_info=$(get_latest_x86_iso "$version")
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to get ISO info${NC}"
        exit 1
    fi
    IFS='|' read -r ISO_URL ISO_NAME <<< "$iso_info"
    echo -e "${BLUE}Ubuntu ISO: $ISO_NAME${NC}"

    # Get Ventoy info
    local ventoy_info=$(get_latest_ventoy)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to get Ventoy info${NC}"
        exit 1
    fi
    IFS='|' read -r VENTOY_URL VENTOY_NAME VENTOY_VERSION <<< "$ventoy_info"
    echo -e "${BLUE}Ventoy: $VENTOY_VERSION${NC}"

    echo
    # Confirm
    echo -e "${RED}WARNING: /dev/$USB_DEVICE will be erased!${NC}"
    echo -ne "${YELLOW}Continue? (yes/no) [no]: ${NC}"
    read CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    # Prepare workspace
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    # Download Ventoy (with caching)
    echo
    echo -e "${GREEN}Checking Ventoy...${NC}"
    if [ -f "$CACHE_DIR/$VENTOY_NAME" ]; then
        echo -e "${BLUE}Using cached Ventoy: $CACHE_DIR/$VENTOY_NAME${NC}"
        cp "$CACHE_DIR/$VENTOY_NAME" "$WORK_DIR/"
    else
        echo -e "${YELLOW}Downloading Ventoy (will be cached for next time)...${NC}"
        wget -q --show-progress -O "$CACHE_DIR/$VENTOY_NAME" "$VENTOY_URL"
        cp "$CACHE_DIR/$VENTOY_NAME" "$WORK_DIR/"
    fi

    # Extract Ventoy
    cd "$WORK_DIR"
    echo -e "${GREEN}Extracting Ventoy...${NC}"
    tar xzf "$VENTOY_NAME"
    VENTOY_DIR="ventoy-${VENTOY_VERSION}"

    # Download ISO (with caching)
    echo
    echo -e "${GREEN}Checking Ubuntu ISO...${NC}"
    if [ -f "$CACHE_DIR/$ISO_NAME" ]; then
        echo -e "${BLUE}Using cached ISO: $CACHE_DIR/$ISO_NAME${NC}"
        echo -e "${BLUE}($(du -h "$CACHE_DIR/$ISO_NAME" | cut -f1))${NC}"
        # Don't copy - we'll copy directly to USB later
    else
        echo -e "${YELLOW}Downloading Ubuntu ISO (will be cached for next time)...${NC}"
        wget -q --show-progress -O "$CACHE_DIR/$ISO_NAME" "$ISO_URL"
    fi

    # Unmount device
    echo
    echo -e "${GREEN}Preparing USB device...${NC}"

    # Kill any processes using the device
    echo -e "${BLUE}Stopping processes using the device...${NC}"
    fuser -km "/dev/${USB_DEVICE}" 2>/dev/null || true
    sleep 1

    # Unmount all partitions (try multiple times)
    echo -e "${BLUE}Unmounting all partitions...${NC}"
    for attempt in 1 2 3; do
        for part in /dev/${USB_DEVICE}*; do
            [ -b "$part" ] && umount -f "$part" 2>/dev/null || true
        done
        # Also try by mount point
        umount -f /media/*/Ventoy 2>/dev/null || true
        umount -f /run/media/*/Ventoy 2>/dev/null || true
        sleep 1
    done

    # Check if still mounted, use lazy unmount as last resort
    if mount | grep -q "/dev/${USB_DEVICE}"; then
        echo -e "${YELLOW}Device still mounted. Trying lazy unmount...${NC}"
        for part in /dev/${USB_DEVICE}*; do
            [ -b "$part" ] && umount -l "$part" 2>/dev/null || true
        done
        sleep 2
    fi

    # Verify device still exists - if not, wait for reconnection
    if [ ! -b "/dev/$USB_DEVICE" ]; then
        echo -e "${RED}Device /dev/$USB_DEVICE no longer exists!${NC}"
        echo
        echo -e "${YELLOW}Please physically disconnect and reconnect the USB device.${NC}"
        echo -e "${YELLOW}Waiting for USB device...${NC}"
        echo

        # Wait for any USB disk to appear
        local wait_count=0
        local max_wait=60
        while [ $wait_count -lt $max_wait ]; do
            # Check if any USB disk appeared
            for dev in /dev/sd?; do
                if [ -b "$dev" ] && readlink -f /sys/block/$(basename $dev) 2>/dev/null | grep -q "/usb"; then
                    local size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null)
                    if [ -n "$size" ] && [ "$size" != "0B" ]; then
                        echo -e "${GREEN}Detected USB device: $dev ($size)${NC}"
                        sleep 2  # Give it time to stabilize
                        break 2
                    fi
                fi
            done
            echo -n "."
            sleep 1
            wait_count=$((wait_count + 1))
        done
        echo

        if [ $wait_count -ge $max_wait ]; then
            echo -e "${RED}Timeout waiting for USB device.${NC}"
            exit 1
        fi

        # Re-select USB device
        echo -e "${GREEN}USB detected! Please select the device:${NC}"
        echo
        select_usb_device
    fi

    # Completely wipe the disk to avoid GPT/partition table issues
    echo -e "${BLUE}Wiping disk to ensure clean install...${NC}"
    wipefs -af "/dev/$USB_DEVICE" 2>/dev/null || true
    dd if=/dev/zero of="/dev/$USB_DEVICE" bs=1M count=10 status=none 2>/dev/null || true
    partprobe "/dev/$USB_DEVICE" 2>/dev/null || true
    sleep 2

    # Verify device is ready
    if [ ! -b "/dev/$USB_DEVICE" ]; then
        echo -e "${RED}Device /dev/$USB_DEVICE still not available.${NC}"
        echo -e "${YELLOW}Please reboot your computer and try again.${NC}"
        exit 1
    fi

    # Install Ventoy to USB
    echo -e "${GREEN}Installing Ventoy to USB...${NC}"
    echo -e "${YELLOW}This will create a bootable multi-ISO USB${NC}"

    cd "$VENTOY_DIR"

    # Use yes to answer all prompts (including any GPT warnings)
    yes | ./Ventoy2Disk.sh -I -g "/dev/$USB_DEVICE"
    local ventoy_exit=$?

    # Ventoy returns 0 on success
    if [[ $ventoy_exit -ne 0 ]]; then
        echo -e "${YELLOW}Ventoy returned exit code $ventoy_exit (checking if install succeeded anyway)${NC}"
    fi

    # Verify Ventoy was installed by checking for partition
    sleep 3
    partprobe "/dev/$USB_DEVICE" 2>/dev/null || true
    sleep 2

    if ! lsblk "/dev/${USB_DEVICE}" | grep -q "part"; then
        echo -e "${RED}Ventoy installation failed - no partitions created${NC}"
        exit 1
    fi

    # Show partition info
    echo -e "${GREEN}Ventoy installed. Partition layout:${NC}"
    lsblk "/dev/${USB_DEVICE}" -o NAME,SIZE,TYPE,FSTYPE

    sleep 3
    partprobe "/dev/$USB_DEVICE"
    sleep 2

    # Find the data partition (partition 1, exFAT)
    local data_part=""
    if [ -b "/dev/${USB_DEVICE}1" ]; then
        data_part="/dev/${USB_DEVICE}1"
    elif [ -b "/dev/${USB_DEVICE}p1" ]; then
        data_part="/dev/${USB_DEVICE}p1"
    else
        echo -e "${RED}Could not find Ventoy data partition${NC}"
        exit 1
    fi

    # Unmount if auto-mounted (common on desktop systems)
    echo -e "${BLUE}Checking for auto-mount...${NC}"
    umount "$data_part" 2>/dev/null || true
    umount "/dev/${USB_DEVICE}2" 2>/dev/null || true
    # Also try common auto-mount locations
    umount /media/*/Ventoy 2>/dev/null || true
    umount /run/media/*/Ventoy 2>/dev/null || true
    sleep 2

    # Ensure exfat kernel module is loaded
    modprobe exfat 2>/dev/null || true

    # Check filesystem type
    local fs_type=$(blkid -s TYPE -o value "$data_part" 2>/dev/null)
    echo -e "${BLUE}Filesystem type: ${fs_type:-unknown}${NC}"

    echo -e "${GREEN}Mounting Ventoy partition (read-write)...${NC}"
    mkdir -p /mnt/ventoy

    # Try mounting with detected filesystem type
    local mount_success=false

    # Attempt 1: Auto-detect
    if mount -o rw "$data_part" /mnt/ventoy 2>/dev/null; then
        if touch /mnt/ventoy/.write_test 2>/dev/null; then
            rm -f /mnt/ventoy/.write_test
            mount_success=true
            echo -e "${GREEN}Mounted successfully (auto-detect)${NC}"
        else
            umount /mnt/ventoy 2>/dev/null || true
        fi
    fi

    # Attempt 2: Explicit exfat
    if [ "$mount_success" = false ]; then
        echo -e "${YELLOW}Trying explicit exfat mount...${NC}"
        if mount -t exfat -o rw "$data_part" /mnt/ventoy 2>/dev/null; then
            if touch /mnt/ventoy/.write_test 2>/dev/null; then
                rm -f /mnt/ventoy/.write_test
                mount_success=true
                echo -e "${GREEN}Mounted successfully (exfat)${NC}"
            else
                umount /mnt/ventoy 2>/dev/null || true
            fi
        fi
    fi

    # Attempt 3: Try reformatting as exfat (Ventoy supports this)
    if [ "$mount_success" = false ]; then
        echo -e "${YELLOW}Mount failed. Reformatting partition as exFAT...${NC}"
        mkfs.exfat -n Ventoy "$data_part"
        sleep 1
        if mount -t exfat -o rw "$data_part" /mnt/ventoy 2>/dev/null; then
            if touch /mnt/ventoy/.write_test 2>/dev/null; then
                rm -f /mnt/ventoy/.write_test
                mount_success=true
                echo -e "${GREEN}Mounted successfully after reformat${NC}"
            else
                umount /mnt/ventoy 2>/dev/null || true
            fi
        fi
    fi

    if [ "$mount_success" = false ]; then
        echo -e "${RED}ERROR: Could not mount Ventoy partition as writable${NC}"
        echo -e "${YELLOW}Please check:${NC}"
        echo "  1. USB device has no physical write-protect switch"
        echo "  2. exfatprogs is installed: sudo apt install exfatprogs"
        echo "  3. exfat kernel module: sudo modprobe exfat"
        exit 1
    fi

    # Copy ISO to Ventoy (from cache)
    echo -e "${GREEN}Copying Ubuntu ISO to USB...${NC}"
    cp "$CACHE_DIR/$ISO_NAME" /mnt/ventoy/
    echo -e "${GREEN}ISO copied${NC}"

    # Create SETUP folder
    echo -e "${GREEN}Creating SETUP folder with scripts...${NC}"
    mkdir -p /mnt/ventoy/SETUP

    # Generate setup script to temp file first
    cd "$WORK_DIR"
    generate_setup_script "${WORK_DIR}/setup-machine.sh" "x86_64"

    # Read the setup script content for embedding in autoinstall.yaml
    local setup_script_content
    setup_script_content=$(cat "${WORK_DIR}/setup-machine.sh")

    # Also copy to SETUP folder for reference/manual use
    cp "${WORK_DIR}/setup-machine.sh" /mnt/ventoy/SETUP/setup-machine.sh

    # Generate autoinstall config with embedded setup script
    echo -e "${GREEN}Creating autoinstall configuration...${NC}"
    generate_autoinstall_yaml /mnt/ventoy/SETUP/autoinstall.yaml "$setup_script_content"

    # Create cloud-init structure (required for Ubuntu Desktop autoinstall)
    echo "instance-id: ubuntu-autoinstall" > /mnt/ventoy/SETUP/meta-data
    cp /mnt/ventoy/SETUP/autoinstall.yaml /mnt/ventoy/SETUP/user-data

    # Create Ventoy autoinstall directory structure
    mkdir -p /mnt/ventoy/ventoy

    # Create Ventoy JSON config for autoinstall
    # NOTE: Do NOT set VTOY_DEFAULT_SEARCH_ROOT - it hides ISOs in root!
    cat > /mnt/ventoy/ventoy/ventoy.json << VENTOY_JSON_EOF
{
    "auto_install": [
        {
            "image": "/${ISO_NAME}",
            "template": [
                "/SETUP/autoinstall.yaml"
            ]
        }
    ]
}
VENTOY_JSON_EOF

    # Add autoinstall kernel parameter for Ubuntu Desktop
    # Without this, Ubuntu Desktop shows "Try or Install" menu
    cat > /mnt/ventoy/ventoy/ventoy_grub.cfg << 'GRUB_CFG_EOF'
# Add autoinstall parameter for Ubuntu Desktop
set ventoy_linux_extra_args="autoinstall"
GRUB_CFG_EOF

    # Create README
    cat > /mnt/ventoy/SETUP/README.txt << 'README_EOF'
========================================
  Ubuntu Install USB - x86 (Autoinstall)
========================================

FULLY AUTOMATED INSTALLATION:
=============================

1. Boot from this USB
   - Ventoy menu appears
   - Select the Ubuntu ISO

2. Ubuntu installer starts with autoinstall
   - Keyboard, WiFi, user account: automatic
   - Disk selection: automatic (if configured) or manual

3. Installation completes automatically

4. On first boot:
   - Post-install setup runs automatically
   - GitHub runner gets configured
   - Sensitive files self-destruct

WHAT GETS CONFIGURED:
====================
- Keyboard: Belgian (be)
- WiFi: pre-configured
- User account: as specified
- Disk layout: EFI + 80GB root + backup
- Hostname, SSH, passwordless sudo
- GitHub self-hosted runner

SECURITY:
=========
Both autoinstall.yaml and setup-machine.sh contain
sensitive data and will be deleted after use.
README_EOF

    sync
    umount /mnt/ventoy
    rmdir /mnt/ventoy

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  x86 Install USB Created Successfully  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}USB Contents:${NC}"
    echo "  - Ventoy bootloader"
    echo "  - $ISO_NAME"
    echo "  - Autoinstall configuration"
    echo "  - Post-install setup script"
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "  - Hostname: $HOSTNAME"
    echo "  - User: $UBUNTU_USER"
    echo "  - Keyboard: Belgian (be)"
    if [ -n "$WIFI_SSID" ]; then
        echo "  - WiFi: $WIFI_SSID"
    else
        echo "  - WiFi: not configured (ethernet only)"
    fi
    if [ -n "$TARGET_DISK_MODEL" ]; then
        echo "  - Target disk: *${TARGET_DISK_MODEL}*"
        echo "  - Partitions: EFI (512MB) + Root (80GB) + Backup (rest)"
    else
        echo "  - Target disk: interactive selection"
    fi
    echo
    echo -e "${YELLOW}Installation Steps:${NC}"
    echo
    echo -e "  ${BLUE}1.${NC} Boot from this USB"
    echo -e "  ${BLUE}2.${NC} Select Ubuntu ISO from Ventoy menu"
    echo -e "  ${BLUE}3.${NC} Autoinstall runs automatically"
    if [ -z "$TARGET_DISK_MODEL" ]; then
        echo -e "  ${BLUE}4.${NC} Select target disk when prompted"
        echo -e "  ${BLUE}5.${NC} Installation completes, system reboots"
    else
        echo -e "  ${BLUE}4.${NC} Installation completes, system reboots"
    fi
    echo -e "  ${BLUE}5.${NC} Post-install setup runs on first boot"
    echo -e "  ${BLUE}6.${NC} Self-destruct removes sensitive files"
    echo
    echo -e "${YELLOW}NETWORK NOTE:${NC}"
    echo "  Ensure ethernet cable is connected during installation."
    echo "  The installer may fail if no network is available."
    echo
    echo -e "${RED}SECURITY NOTE:${NC}"
    echo "  autoinstall.yaml contains WiFi password!"
    echo "  setup-machine.sh contains SSH key and GitHub PAT!"
    echo "  Both files on the target will self-destruct after first boot."
    echo "  Both files will STAY on the Install USB."
    echo
    echo -e "${BLUE}Tip: You can add more ISOs to this USB by copying them to the root${NC}"
    echo

    cd /
    rm -rf "$WORK_DIR"
}

#==============================================================================
# RASPBERRY PI 4 INSTALLATION
#==============================================================================

create_pi4_usb() {
    local version=$1
    local target_image_type=$2  # "desktop" or "server" - what to install on M.2

    echo -e "${GREEN}Creating Raspberry Pi 4 Install USB...${NC}"
    echo
    echo -e "${BLUE}This USB will boot the Pi4 and flash Ubuntu to the M.2 SSD${NC}"
    echo

    # We need TWO images:
    # 1. Boot image (Ubuntu Server - smaller, just for booting USB)
    # 2. Target image (Ubuntu Desktop/Server - to flash to M.2)

    echo -e "${GREEN}Step 1: Getting boot image (Ubuntu Server for USB boot)...${NC}"
    local boot_info=$(get_latest_pi4_image "$version" "server")
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to get boot image info${NC}"
        exit 1
    fi
    IFS='|' read -r BOOT_URL BOOT_NAME <<< "$boot_info"
    echo -e "${BLUE}Boot image: $BOOT_NAME${NC}"

    echo
    echo -e "${GREEN}Step 2: Getting target image (Ubuntu ${target_image_type} for M.2)...${NC}"
    local target_info=$(get_latest_pi4_image "$version" "$target_image_type")
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to get target image info${NC}"
        exit 1
    fi
    IFS='|' read -r TARGET_URL TARGET_NAME <<< "$target_info"
    echo -e "${BLUE}Target image: $TARGET_NAME${NC}"

    local is_desktop="no"
    if [ "$target_image_type" = "desktop" ]; then
        is_desktop="yes"
    fi

    echo
    # Confirm
    echo -e "${RED}WARNING: /dev/$USB_DEVICE will be erased!${NC}"
    echo -ne "${YELLOW}Continue? (yes/no) [no]: ${NC}"
    read CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    # Prepare workspace
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Download both images (with caching)
    echo
    echo -e "${GREEN}Checking boot image...${NC}"
    if [ -f "$CACHE_DIR/$BOOT_NAME" ]; then
        echo -e "${BLUE}Using cached boot image: $CACHE_DIR/$BOOT_NAME${NC}"
        echo -e "${BLUE}($(du -h "$CACHE_DIR/$BOOT_NAME" | cut -f1))${NC}"
    else
        echo -e "${YELLOW}Downloading boot image (will be cached for next time)...${NC}"
        wget -q --show-progress -O "$CACHE_DIR/$BOOT_NAME" "$BOOT_URL"
    fi

    echo
    echo -e "${GREEN}Checking target image...${NC}"
    if [ -f "$CACHE_DIR/$TARGET_NAME" ]; then
        echo -e "${BLUE}Using cached target image: $CACHE_DIR/$TARGET_NAME${NC}"
        echo -e "${BLUE}($(du -h "$CACHE_DIR/$TARGET_NAME" | cut -f1))${NC}"
    else
        echo -e "${YELLOW}Downloading target image (will be cached for next time)...${NC}"
        wget -q --show-progress -O "$CACHE_DIR/$TARGET_NAME" "$TARGET_URL"
    fi

    # Unmount device
    echo
    echo -e "${GREEN}Preparing USB device...${NC}"
    for part in /dev/${USB_DEVICE}*; do
        umount "$part" 2>/dev/null || true
    done

    # Flash BOOT image to USB (from cache)
    echo -e "${GREEN}Flashing boot image to USB SSD...${NC}"
    xz -dc "$CACHE_DIR/$BOOT_NAME" | dd of="/dev/$USB_DEVICE" bs=4M status=progress conv=fsync
    sync
    sleep 2

    # Re-read partition table
    partprobe "/dev/$USB_DEVICE"
    sleep 3

    # Find rootfs partition (usually partition 2)
    local rootfs_part=""
    if [ -b "/dev/${USB_DEVICE}2" ]; then
        rootfs_part="/dev/${USB_DEVICE}2"
    elif [ -b "/dev/${USB_DEVICE}p2" ]; then
        rootfs_part="/dev/${USB_DEVICE}p2"
    else
        echo -e "${RED}Could not find rootfs partition${NC}"
        exit 1
    fi

    # Expand rootfs partition to use all available space
    # (preinstalled images have small rootfs that can't fit the target image)
    echo -e "${GREEN}Expanding rootfs partition to use full USB capacity...${NC}"

    # Get the partition number (2 for rootfs)
    local part_num="2"

    # Use parted to expand partition to 100%
    parted -s "/dev/${USB_DEVICE}" resizepart ${part_num} 100%
    sleep 1

    # Re-read partition table
    partprobe "/dev/${USB_DEVICE}"
    sleep 2

    # Check and resize the filesystem
    echo -e "${BLUE}Checking filesystem...${NC}"
    e2fsck -f -y "$rootfs_part" 2>/dev/null || true

    echo -e "${BLUE}Resizing filesystem...${NC}"
    resize2fs "$rootfs_part"

    # Show new size
    local new_size=$(lsblk -n -o SIZE "$rootfs_part" 2>/dev/null)
    echo -e "${GREEN}Rootfs partition expanded to: ${new_size}${NC}"

    # Find boot partition (partition 1, FAT32)
    local boot_part=""
    if [ -b "/dev/${USB_DEVICE}1" ]; then
        boot_part="/dev/${USB_DEVICE}1"
    elif [ -b "/dev/${USB_DEVICE}p1" ]; then
        boot_part="/dev/${USB_DEVICE}p1"
    else
        echo -e "${RED}Could not find boot partition${NC}"
        exit 1
    fi

    # Inject cloud-init config into boot partition
    echo -e "${GREEN}Injecting cloud-init config (keyboard BE + password + auto-flash)...${NC}"
    mkdir -p /mnt/pi4boot
    mount "$boot_part" /mnt/pi4boot

    # Generate cloud-init user-data with auto-run flash
    generate_pi4_cloud_init /mnt/pi4boot/user-data

    # Create empty meta-data (required by cloud-init)
    echo "instance-id: pi4-flash-usb" > /mnt/pi4boot/meta-data

    sync
    umount /mnt/pi4boot
    rmdir /mnt/pi4boot

    echo -e "${GREEN}Adding flash tools and target image to USB...${NC}"

    # Mount rootfs
    mkdir -p /mnt/rootfs
    mount "$rootfs_part" /mnt/rootfs

    # Create flash directory
    mkdir -p /mnt/rootfs/opt/pi4-flash

    # Copy target image to USB from cache (will be used by flash script)
    echo -e "${BLUE}Copying target image to USB (this may take a while)...${NC}"
    cp "$CACHE_DIR/$TARGET_NAME" /mnt/rootfs/opt/pi4-flash/

    # Generate all scripts
    echo -e "${BLUE}Generating scripts...${NC}"
    generate_flash_to_m2_script /mnt/rootfs/opt/pi4-flash/flash-to-m2.sh "$TARGET_NAME" "$is_desktop"
    generate_setup_script /mnt/rootfs/opt/pi4-flash/setup-machine.sh "arm64"
    generate_firstboot_service /mnt/rootfs/opt/pi4-flash/firstboot-setup.service "$is_desktop"

    if [ "$is_desktop" = "yes" ]; then
        generate_terminal_launcher /mnt/rootfs/opt/pi4-flash/run-setup-in-terminal.sh
    fi

    # Create a convenient symlink and desktop shortcut
    ln -sf /opt/pi4-flash/flash-to-m2.sh /mnt/rootfs/usr/local/bin/flash-to-m2

    # Create README
    cat > /mnt/rootfs/opt/pi4-flash/README.txt << 'README_EOF'
========================================
  Raspberry Pi 4 - Flash to M.2 SSD
========================================

This USB boots your Pi4 and flashes Ubuntu to
your Argon One M.2 SSD.

STEPS:
======
1. Boot Pi4 from this USB SSD
2. Login: ubuntu / (your configured password)
3. Run: sudo flash-to-m2
4. Type "yes" to confirm flash
5. Wait for flash to complete
6. Power off, remove USB
7. Power on - Pi4 boots from M.2
8. Post-install runs automatically!

WHAT GETS CONFIGURED:
=====================
- Keyboard: Belgian (BE)
- Hostname, SSH key, passwordless sudo
- WiFi (if configured)
- GitHub Actions runner

FILES:
======
- flash-to-m2.sh          : Main flash script
- setup-machine.sh        : Post-install configuration
- firstboot-setup.service : Auto-run service
- *.img.xz                : Ubuntu image for M.2
README_EOF

    # Create MOTD to remind user what to do
    cat > /mnt/rootfs/etc/update-motd.d/99-flash-instructions << 'MOTD_EOF'
#!/bin/bash
echo ""
echo "========================================"
echo "  Pi4 Flash USB - Ready to flash M.2"
echo "========================================"
echo ""
echo "  Run: sudo flash-to-m2"
echo ""
echo "========================================"
echo ""
MOTD_EOF
    chmod +x /mnt/rootfs/etc/update-motd.d/99-flash-instructions

    sync
    umount /mnt/rootfs
    rmdir /mnt/rootfs

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Pi4 Install USB Created Successfully  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}USB Contents:${NC}"
    echo "  - Bootable Ubuntu Server (for booting Pi4)"
    echo "  - Ubuntu ${target_image_type^} image (to flash to M.2)"
    echo "  - Cloud-init config (keyboard BE + password)"
    echo "  - Flash script + post-install setup"
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "  - Hostname: $HOSTNAME"
    echo "  - User: $UBUNTU_USER"
    echo "  - Keyboard: Belgian (be)"
    if [ -n "$WIFI_SSID" ]; then
        echo "  - WiFi: $WIFI_SSID"
    else
        echo "  - WiFi: not configured (ethernet only)"
    fi
    echo
    echo -e "${YELLOW}Installation Steps:${NC}"
    echo -e "  ${RED}NOTE: Argon One M.2 appears as USB device - must manage boot order!${NC}"
    echo
    echo -e "  ${BLUE}1.${NC} ${RED}Disconnect M.2 USB bridge${NC} inside Argon case"
    echo -e "  ${BLUE}2.${NC} Connect USB SSD to Pi4"
    echo -e "  ${BLUE}3.${NC} Power on Pi4 (boots from USB)"
    echo -e "  ${BLUE}4.${NC} Login: ubuntu / (your password)"
    echo -e "  ${BLUE}5.${NC} ${RED}Reconnect M.2 USB bridge${NC} (M.2 appears as /dev/sdb)"
    echo -e "  ${BLUE}6.${NC} Run: ${GREEN}sudo flash-to-m2${NC}"
    echo -e "  ${BLUE}7.${NC} Type ${GREEN}yes${NC} to confirm flash"
    echo -e "  ${BLUE}8.${NC} Wait for flash + partitioning to complete"
    echo -e "  ${BLUE}9.${NC} Power off, ${RED}remove USB SSD${NC}"
    echo -e "  ${BLUE}10.${NC} Power on - Pi4 boots from M.2"
    if [ "$is_desktop" = "yes" ]; then
        echo -e "  ${BLUE}11.${NC} Setup runs automatically (terminal shows progress)"
    else
        echo -e "  ${BLUE}11.${NC} Setup runs automatically (check: journalctl -f)"
    fi
    echo -e "  ${BLUE}12.${NC} SSH: ssh ${UBUNTU_USER}@${HOSTNAME}.local"
    echo
    echo -e "${YELLOW}NETWORK NOTE:${NC}"
    echo "  Ensure ethernet cable is connected during firstboot setup."
    echo "  GitHub runner registration requires network access."
    echo

    cd /
    rm -rf "$WORK_DIR"
}

#==============================================================================
# UPDATE MODE - Update hostname/labels on existing USB without re-flashing
#==============================================================================

update_usb() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  USB Update Mode                      ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${BLUE}Update hostname/runner labels on existing USB${NC}"
    echo -e "${BLUE}No re-flash required!${NC}"
    echo

    # Select USB device
    echo -e "${GREEN}Step 1: Select USB Device${NC}"
    echo
    select_usb_device

    echo
    echo -e "${GREEN}Step 2: Detecting USB type...${NC}"

    local setup_script=""
    local usb_type=""
    local mount_point=""

    # Try x86 Ventoy first (partition 1, exFAT)
    local data_part=""
    if [ -b "/dev/${USB_DEVICE}1" ]; then
        data_part="/dev/${USB_DEVICE}1"
    elif [ -b "/dev/${USB_DEVICE}p1" ]; then
        data_part="/dev/${USB_DEVICE}p1"
    fi

    if [ -n "$data_part" ]; then
        local fs_type
        fs_type=$(blkid -s TYPE -o value "$data_part" 2>/dev/null)
        if [ "$fs_type" = "exfat" ] || [ "$fs_type" = "vfat" ]; then
            mkdir -p /mnt/ventoy
            umount "$data_part" 2>/dev/null || true
            umount /media/*/Ventoy 2>/dev/null || true
            umount /run/media/*/Ventoy 2>/dev/null || true
            modprobe exfat 2>/dev/null || true
            sleep 1
            if mount -t exfat -o rw "$data_part" /mnt/ventoy 2>/dev/null \
               || mount -o rw "$data_part" /mnt/ventoy 2>/dev/null; then
                if [ -f "/mnt/ventoy/SETUP/setup-machine.sh" ]; then
                    setup_script="/mnt/ventoy/SETUP/setup-machine.sh"
                    usb_type="x86"
                    mount_point="/mnt/ventoy"
                    echo -e "${GREEN}Detected: x86 Ventoy USB${NC}"
                else
                    umount /mnt/ventoy 2>/dev/null || true
                fi
            fi
        fi
    fi

    # Try Pi4 (partition 2, ext4 rootfs)
    if [ -z "$usb_type" ]; then
        local rootfs_part=""
        if [ -b "/dev/${USB_DEVICE}2" ]; then
            rootfs_part="/dev/${USB_DEVICE}2"
        elif [ -b "/dev/${USB_DEVICE}p2" ]; then
            rootfs_part="/dev/${USB_DEVICE}p2"
        fi

        if [ -n "$rootfs_part" ]; then
            local fs_type
            fs_type=$(blkid -s TYPE -o value "$rootfs_part" 2>/dev/null)
            if [ "$fs_type" = "ext4" ]; then
                mkdir -p /mnt/rootfs
                if mount -o rw "$rootfs_part" /mnt/rootfs 2>/dev/null; then
                    if [ -f "/mnt/rootfs/opt/pi4-flash/setup-machine.sh" ]; then
                        setup_script="/mnt/rootfs/opt/pi4-flash/setup-machine.sh"
                        usb_type="pi4"
                        mount_point="/mnt/rootfs"
                        echo -e "${GREEN}Detected: Pi4 USB${NC}"
                    else
                        umount /mnt/rootfs 2>/dev/null || true
                    fi
                fi
            fi
        fi
    fi

    if [ -z "$usb_type" ]; then
        echo -e "${RED}ERROR: Could not find setup-machine.sh on USB.${NC}"
        echo -e "${RED}Ensure this is a USB created by this script and is properly inserted.${NC}"
        exit 1
    fi

    # Resolve arch suffix and runtime arch value based on USB type:
    #   x86 USB → hostname suffix "-x86",  runner label arch "x86_64"
    #   Pi4 USB → hostname suffix "-pi4",  runner label arch "aarch64"
    local arch_suffix arch_value
    if [ "$usb_type" = "x86" ]; then
        arch_suffix="x86"
        arch_value="x86_64"
    else
        arch_suffix="pi4"
        arch_value="aarch64"
    fi

    # Extract current hostname from setup-machine.sh
    local old_hostname
    old_hostname=$(grep "hostnamectl set-hostname" "$setup_script" | awk '{print $NF}')

    if [ -z "$old_hostname" ]; then
        echo -e "${RED}ERROR: Could not read current hostname from setup script.${NC}"
        umount "$mount_point" 2>/dev/null || true
        exit 1
    fi

    # Split hostname into device name + arch suffix.
    # Convention: <device>-<arch>  e.g. "pihole-x86", "homeassistant-pi4"
    # Strip the known suffix so the user only needs to enter the device name.
    local old_device_name="${old_hostname%-${arch_suffix}}"

    echo
    echo -e "${GREEN}Step 3: What to update?${NC}"
    echo -e "${BLUE}Current hostname: ${YELLOW}$old_hostname${NC}"
    echo -e "${BLUE}  (device: ${YELLOW}$old_device_name${BLUE}, arch suffix: ${YELLOW}-${arch_suffix}${BLUE} from USB type)${NC}"
    echo

    # Ask for device name only — arch suffix is fixed by USB type
    echo -ne "${YELLOW}Device name [$old_device_name]: ${NC}"
    read -r new_device_name
    new_device_name=${new_device_name:-$old_device_name}
    local NEW_HOSTNAME="${new_device_name}-${arch_suffix}"
    echo -e "${BLUE}  → Hostname will be: ${GREEN}${NEW_HOSTNAME}${NC}"

    # Ask for role label
    # Check if a role label is already present
    local existing_role_label
    existing_role_label=$(grep -- '--labels' "$setup_script" | \
        grep -oP '"self-hosted,linux,\$\(uname -m\),\K[^"]+' 2>/dev/null || true)

    local current_labels="self-hosted,linux,$arch_value"
    if [ -n "$existing_role_label" ]; then
        current_labels="self-hosted,linux,$arch_value,$existing_role_label"
    fi

    echo
    echo -e "${BLUE}Runner labels:${NC}"
    echo -e "  Current: ${YELLOW}$current_labels${NC}"
    echo -e "  Role label examples: homeassistant, pihole"
    echo -ne "${YELLOW}Role label (leave empty to keep as-is): ${NC}"
    read -r ROLE_LABEL

    # Confirm changes
    echo
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Planned changes:${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$NEW_HOSTNAME" != "$old_hostname" ]; then
        echo -e "  Hostname:  ${RED}$old_hostname${NC} → ${GREEN}$NEW_HOSTNAME${NC}"
    else
        echo -e "  Hostname:  ${BLUE}$old_hostname${NC} (unchanged)"
    fi
    if [ -n "$ROLE_LABEL" ]; then
        echo -e "  Labels:    $current_labels → ${GREEN}self-hosted,linux,$arch_value,$ROLE_LABEL${NC}"
    else
        echo -e "  Labels:    ${BLUE}$current_labels${NC} (unchanged)"
    fi
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -ne "${YELLOW}Proceed? (y/N): ${NC}"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        umount "$mount_point" 2>/dev/null || true
        exit 0
    fi

    echo
    echo -e "${GREEN}Step 4: Applying changes...${NC}"

    # Update hostname in setup-machine.sh
    if [ "$NEW_HOSTNAME" != "$old_hostname" ]; then
        sed -i "s|${old_hostname}|${NEW_HOSTNAME}|g" "$setup_script"
        echo -e "  ${GREEN}✓ Hostname updated in setup-machine.sh${NC}"

        # For x86: also update autoinstall.yaml and user-data
        if [ "$usb_type" = "x86" ]; then
            for f in "$mount_point/SETUP/autoinstall.yaml" "$mount_point/SETUP/user-data"; do
                [ -f "$f" ] && sed -i "s|${old_hostname}|${NEW_HOSTNAME}|g" "$f" \
                    && echo -e "  ${GREEN}✓ Hostname updated in $(basename $f)${NC}"
            done
        fi
    fi

    # Update runner labels in setup-machine.sh
    if [ -n "$ROLE_LABEL" ]; then
        local old_label_line='--labels "self-hosted,linux,$(uname -m)"'
        local new_label_line="--labels \"self-hosted,linux,\$(uname -m),$ROLE_LABEL\""
        # Also handle case where a role label already exists (replace it)
        if [ -n "$existing_role_label" ]; then
            old_label_line="--labels \"self-hosted,linux,\$(uname -m),$existing_role_label\""
        fi
        sed -i "s|${old_label_line}|${new_label_line}|g" "$setup_script"
        echo -e "  ${GREEN}✓ Runner labels updated in setup-machine.sh${NC}"

        # For x86: also update autoinstall.yaml and user-data
        if [ "$usb_type" = "x86" ]; then
            for f in "$mount_point/SETUP/autoinstall.yaml" "$mount_point/SETUP/user-data"; do
                [ -f "$f" ] && sed -i "s|${old_label_line}|${new_label_line}|g" "$f" \
                    && echo -e "  ${GREEN}✓ Labels updated in $(basename $f)${NC}"
            done
        fi
    fi

    # Sync and unmount
    sync
    umount "$mount_point"
    rmdir "$mount_point" 2>/dev/null || true

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  USB Updated Successfully!             ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}Summary:${NC}"
    echo "  USB type:  $usb_type"
    echo "  Hostname:  $NEW_HOSTNAME"
    [ -n "$ROLE_LABEL" ] && echo "  Role:      $ROLE_LABEL"
    echo
    echo -e "${BLUE}No re-flash needed. USB is ready to use.${NC}"
}

#==============================================================================
# MAIN
#==============================================================================

echo -e "${CYAN}"
cat << "EOF"
 _   _ _                 _         ___           _        _ _
| | | | |               | |       |_ _|_ __  ___| |_ __ _| | |
| | | | |__  _   _ _ __ | |_ _   _ | || '_ \/ __| __/ _` | | |
| |_| | '_ \| | | | '_ \| __| | | || || | | \__ \ || (_| | | |
 \___/|_.__/ \__,_|_| |_|\__|\__,_|___|_| |_|___/\__\__,_|_|_|

  USB Creator for x86 and Raspberry Pi 4
EOF
echo -e "${NC}"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

# Parse arguments
MODE="create"
for arg in "$@"; do
    case "$arg" in
        --update|-u)
            MODE="update"
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)          Create a new bootable install USB (full flash)"
            echo "  --update, -u    Update hostname/runner labels on existing USB (no re-flash)"
            echo "  --help,   -h    Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo $0                  # Create new USB"
            echo "  sudo $0 --update         # Update existing USB"
            exit 0
            ;;
    esac
done

# Dispatch to update mode if requested
if [ "$MODE" = "update" ]; then
    check_dependencies
    update_usb
    exit 0
fi

# Check dependencies
check_dependencies

# Select architecture
echo -e "${GREEN}Step 1: Select Architecture${NC}"
echo
echo "1) x86_64 (Intel/AMD - Lenovo laptop, desktop PC)"
echo "2) Raspberry Pi 4 (ARM64)"
echo
echo -ne "${YELLOW}Select (1-2) [1]: ${NC}"
read ARCH_CHOICE
ARCH_CHOICE=${ARCH_CHOICE:-1}

case $ARCH_CHOICE in
    1)
        ARCH="x86_64"
        ;;
    2)
        ARCH="arm64"
        # Ask for desktop or server
        echo
        echo "Image type:"
        echo "1) Desktop (GUI, recommended)"
        echo "2) Server (headless)"
        echo -ne "${YELLOW}Select (1-2) [1]: ${NC}"
        read IMAGE_TYPE_CHOICE
        IMAGE_TYPE_CHOICE=${IMAGE_TYPE_CHOICE:-1}
        if [ "$IMAGE_TYPE_CHOICE" = "2" ]; then
            PI4_IMAGE_TYPE="server"
        else
            PI4_IMAGE_TYPE="desktop"
        fi
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Selected: $ARCH${NC}"
echo

# LTS preference
echo -e "${GREEN}Step 2: Ubuntu Version${NC}"
echo
echo "1) LTS (Long Term Support - 5 years)"
echo "2) Latest (newest features - 9 months)"
echo -ne "${YELLOW}Select (1-2) [1]: ${NC}"
read LTS_CHOICE
LTS_CHOICE=${LTS_CHOICE:-1}

if [ "$LTS_CHOICE" = "2" ]; then
    LTS_ONLY="no"
else
    LTS_ONLY="yes"
fi

# Get latest version
UBUNTU_VERSION=$(get_latest_ubuntu_version "$LTS_ONLY")
echo -e "${GREEN}Ubuntu version: $UBUNTU_VERSION${NC}"
echo

# Gather configuration
echo -e "${GREEN}Step 3: Post-Install Configuration${NC}"
echo
gather_config

# WiFi config - needed for both platforms
gather_wifi_config

# User account - needed for both platforms
gather_user_account

# For x86: gather disk selection
if [ "$ARCH" = "x86_64" ]; then
    gather_config_x86_disk_selection
fi

# Select USB device
echo
echo -e "${GREEN}Step 4: Select USB Device${NC}"
echo
select_usb_device

# Create USB based on architecture
echo
echo -e "${GREEN}Step 5: Creating Install USB${NC}"
echo

if [ "$ARCH" = "x86_64" ]; then
    create_x86_usb "$UBUNTU_VERSION"
else
    create_pi4_usb "$UBUNTU_VERSION" "$PI4_IMAGE_TYPE"
fi

echo
echo -e "${GREEN}Done!${NC}"
