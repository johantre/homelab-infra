#!/bin/bash
set -e

# Check for test mode
TEST_MODE=false
if [[ "$1" == "--test-mode" ]] || [[ "$1" == "--test" ]]; then
    TEST_MODE=true
    echo -e "\033[1;33m"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   TEST MODE: Will only generate setup-machine.sh         ║"
    echo "║   Skipping ISO download and USB creation                 ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "\033[0m"
    echo
fi

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
    local arch=$1     # "amd64" or "arm64"
    local lts_only=$2 # "yes" or "no"

    # ALL debug output goes to stderr (&2)
    if [[ "$lts_only" == "yes" ]]; then
        echo -e "${BLUE}Fetching latest LTS Ubuntu Desktop version for $arch...${NC}" >&2
    else
        echo -e "${BLUE}Fetching latest Ubuntu Desktop version for $arch...${NC}" >&2
    fi

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

        # Extract versions
        local all_versions=$(echo "$releases_page" | \
            grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' | \
            grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | \
            sort -Vr)

        # Filter for LTS if requested (even-year .04 versions only)
        local latest_version
        if [[ "$lts_only" == "yes" ]]; then
            # LTS = even year + .04 (e.g., 24.04, 26.04, 28.04)
            latest_version=$(echo "$all_versions" | grep -E '^[0-9]*[02468]\.04' | head -1)
            echo -e "${YELLOW}[DEBUG] Filtering for LTS versions only (even years)${NC}" >&2
        else
            latest_version=$(echo "$all_versions" | head -1)
        fi

        echo -e "${YELLOW}[DEBUG] Extracted version: '$latest_version'${NC}" >&2

        if [[ -z "$latest_version" ]]; then
            echo -e "${YELLOW}[WARNING] Could not extract version, using fallback: 24.04${NC}" >&2
            latest_version="24.04"
        fi

        # Check if it's LTS (even year + .04)
        if [[ "$latest_version" =~ ^[0-9]*[02468]\.04 ]]; then
            echo -e "${GREEN}[INFO] Selected: $latest_version (LTS)${NC}" >&2
        else
            echo -e "${YELLOW}[INFO] Selected: $latest_version (non-LTS, 9 months support)${NC}" >&2
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
        echo -e "${YELLOW}[DEBUG] Fetching from: https://cdimage.ubuntu.com/releases/24.04/release/${NC}" >&2

        # For ARM, we'll check the 24.04 LTS directory which usually has latest
        local cdimage_page=$(curl -s "https://cdimage.ubuntu.com/releases/24.04/release/" 2>&1)
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
            echo -e "${YELLOW}[WARNING] Could not extract ISO, using fallback: ubuntu-24.04.1-desktop-arm64.iso${NC}" >&2
            latest_iso="ubuntu-24.04.1-desktop-arm64.iso"
        fi

        # ARM desktop is typically LTS-based
        echo -e "${GREEN}[INFO] Selected: $latest_iso (LTS)${NC}" >&2

        local iso_url="https://cdimage.ubuntu.com/releases/24.04/release/${latest_iso}"
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

    # Check 1: Is it marked as removable?
    if [ "$(cat /sys/block/$device/removable 2>/dev/null)" = "1" ]; then
        # Still need to check it's not root/boot
        if mount | grep -q "^/dev/${device}[0-9]* on / "; then
            return 1
        fi
        if lsblk -no MOUNTPOINT "/dev/$device" 2>/dev/null | grep -qE "^/$|^/boot$|^/home$"; then
            return 1
        fi
        return 0
    fi

    # Check 2: Is it on USB bus (e.g., NVMe in USB enclosure)?
    if readlink -f /sys/block/$device 2>/dev/null | grep -q "/usb"; then
        # Double check it's not root/boot/home
        if mount | grep -q "^/dev/${device}[0-9]* on / "; then
            return 1
        fi
        if lsblk -no MOUNTPOINT "/dev/$device" 2>/dev/null | grep -qE "^/$|^/boot$|^/home$"; then
            return 1
        fi
        return 0
    fi

    # Not safe
    return 1
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

if [ "$TEST_MODE" = false ]; then
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

    # Ask for LTS preference
    echo -e "${BLUE}Ubuntu Version Type:${NC}"
    echo -e "  ${GREEN}LTS${NC} (Long Term Support): 5 years of updates - recommended for production"
    echo -e "  ${YELLOW}Latest${NC}: Newest features, 9 months support - for testing/development"
    echo
    echo -ne "${YELLOW}Prefer LTS versions only? (yes/no) [yes]: ${NC}"
    read LTS_ONLY
    LTS_ONLY=${LTS_ONLY:-yes}

    echo

    # Fetch latest ISO info
    ISO_INFO=$(get_latest_desktop_iso "$ARCH_API" "$LTS_ONLY")
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
else
    echo -e "${YELLOW}[TEST MODE] Skipping architecture and ISO selection${NC}"
    echo
fi

echo -e "${GREEN}Step 2: Configuration for post-install script${NC}"
echo

# Config
echo -ne "${YELLOW}Hostname [homeassistant]: ${NC}"
read HOSTNAME
HOSTNAME=${HOSTNAME:-homeassistant}

echo
echo -e "${BLUE}Note: Script will configure the user created during installation${NC}"
echo

echo -e "${YELLOW}SSH Public Key (paste with Ctrl+Shift+v and press Enter, or leave empty to skip):${NC}"
echo -ne "${YELLOW}SSH Key: ${NC}"
read SSH_KEY
if [ -n "$SSH_KEY" ]; then
    # Ga 1 regel omhoog en overschrijf met sterren
    tput cuu1  # Cursor up 1 line
    echo -ne "\r${YELLOW}SSH Key: ${NC}"
    printf '*%.0s' $(seq 1 ${#SSH_KEY})
    tput el    # Clear to end of line (removes any leftover chars)
    echo
    echo -e "${GREEN}✓ SSH key received (${#SSH_KEY} characters)${NC}"
else
    echo -e "${YELLOW}✓ SSH key skipped${NC}"
fi

echo
echo -e "${BLUE}GitHub Runner Configuration (for self-hosted runner):${NC}"
echo

echo -ne "${YELLOW}GitHub Username [johantre]: ${NC}"
read GH_USER
GH_USER=${GH_USER:-johantre}

echo -ne "${YELLOW}GitHub Repository [homelab-infra]: ${NC}"
read GH_REPO
GH_REPO=${GH_REPO:-homelab-infra}

echo
echo -e "${YELLOW}GitHub Personal Access Token (PAT):${NC}"
echo -e "${BLUE}  Needs scopes: repo, workflow, admin:org (manage_runners)${NC}"
echo -e "${BLUE}  Create at: https://github.com/settings/tokens/new${NC}"
echo -ne "${YELLOW}PAT: ${NC}"
IFS= read -r GH_PAT
if [ -z "$GH_PAT" ]; then
    echo -e "${RED}ERROR: GitHub PAT is required for runner setup${NC}"
    exit 1
fi
# Ga 1 regel omhoog en overschrijf met sterren
tput cuu1  # Cursor up 1 line
echo -ne "\r${YELLOW}PAT: ${NC}"
printf '*%.0s' $(seq 1 ${#GH_PAT})
tput el    # Clear to end of line
echo
echo -e "${GREEN}✓ GitHub PAT received (${#GH_PAT} characters)${NC}"
GH_REPO_URL="https://github.com/${GH_USER}/${GH_REPO}"
echo -e "${BLUE}Will configure runner for: $GH_REPO_URL${NC}"

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

if [ "$TEST_MODE" = false ]; then
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
else
    # Test mode: only need USB 2 for setup script
    if [ ${#SAFE_DEVICES[@]} -lt 1 ]; then
        echo -e "${RED}Need at least 1 USB device for setup script! Found: ${#SAFE_DEVICES[@]}${NC}"
        echo -e "${YELLOW}Please insert USB stick${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[TEST MODE] Select USB for SETUP script only (no ISO will be created)${NC}"
    echo -ne "${YELLOW}Select USB number for setup script [1]: ${NC}"
    read USB2_NUM
    USB2_NUM=${USB2_NUM:-1}
    idx=$((USB2_NUM - 1))
    USB2_DEVICE="${SAFE_DEVICES[$idx]}"

    echo
    echo -e "${BLUE}Selected:${NC}"
    echo "  USB (Setup):    /dev/$USB2_DEVICE"
    echo

    # Confirmation
    echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: USB DEVICE WILL BE ERASED!         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
    echo -ne "${YELLOW}Continue? (yes/no) [no]: ${NC}"
    read CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
fi

echo
echo -e "${GREEN}Step 4: Preparing workspace...${NC}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ "$TEST_MODE" = false ]; then
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
else
    echo -e "${YELLOW}[TEST MODE] Skipping ISO download${NC}"
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
echo -e "${GREEN}[1/6] Setting hostname...${NC}"
hostnamectl set-hostname HOSTNAME_PLACEHOLDER
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname

# Update hosts file
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1    HOSTNAME_PLACEHOLDER" >> /etc/hosts
echo -e "   ${GREEN}✓${NC} Hostname set to HOSTNAME_PLACEHOLDER"

# SSH key setup
SSH_KEY_PROVIDED="SSH_KEY_PLACEHOLDER"
if [ -n "$SSH_KEY_PROVIDED" ] && [ "$SSH_KEY_PROVIDED" != "SKIP" ]; then
    echo -e "${GREEN}[2/6] Adding SSH key...${NC}"

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
    echo -e "${YELLOW}[2/5] No SSH key configured (skipped)${NC}"
fi

# Sudo passwordless
echo -e "${GREEN}[3/6] Configuring sudo...${NC}"
if ! grep -q "^${ACTUAL_USER}.*NOPASSWD" /etc/sudoers.d/${ACTUAL_USER} 2>/dev/null; then
    echo "${ACTUAL_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${ACTUAL_USER}
    chmod 440 /etc/sudoers.d/${ACTUAL_USER}
    echo -e "   ${GREEN}✓${NC} Passwordless sudo enabled"
else
    echo -e "   ${YELLOW}Already configured${NC}"
fi

# Ensure openssh-server
echo -e "${GREEN}[4/6] Checking SSH server...${NC}"
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

# GitHub Self-Hosted Runner
echo -e "${GREEN}[5/6] Installing GitHub Self-Hosted Runner...${NC}"

GH_USER="GH_USER_PLACEHOLDER"
GH_REPO="GH_REPO_PLACEHOLDER"
GH_PAT="GH_PAT_PLACEHOLDER"
GH_REPO_URL="GH_REPO_URL_PLACEHOLDER"

if [ -n "$GH_PAT" ] && [ "$GH_PAT" != "SKIP" ]; then
    echo -e "${BLUE}   Setting up runner for: $GH_REPO_URL${NC}"

    # Clean up any old GitHub CLI repo (from previous runs)
    rm -f /etc/apt/sources.list.d/github-cli.list

    # Install curl first (needed for everything else)
    if ! command -v curl &> /dev/null; then
        echo -e "   ${YELLOW}Installing curl...${NC}"
        apt-get update -qq
        apt-get install -y -qq curl
    fi

    # Install GitHub CLI
    echo -e "   ${YELLOW}Installing GitHub CLI...${NC}"

    # Download and install GPG key
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg

    # Verify key was downloaded
    if [ ! -f /usr/share/keyrings/githubcli-archive-keyring.gpg ]; then
        echo -e "   ${RED}✗${NC} Failed to download GitHub CLI GPG key"
        exit 1
    fi

    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

    # Add repository with signed-by pointing to the keyring
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    # Now update apt with the key in place
    apt-get update -qq
    apt-get install -y -qq gh jq wget

    # Authenticate with PAT
    echo -e "   ${YELLOW}Authenticating with GitHub...${NC}"
    # Logout first to clear any cached tokens
    sudo -u ${ACTUAL_USER} gh auth logout 2>/dev/null || true
    echo "$GH_PAT" | sudo -u ${ACTUAL_USER} gh auth login --with-token

    # Get runner registration token
    echo -e "   ${YELLOW}Generating runner token...${NC}"
    #RUNNER_TOKEN=$(sudo -u ${ACTUAL_USER} gh api /repos/${GH_USER}/${GH_REPO}/actions/runners/registration-token | jq -r .token)
    RUNNER_TOKEN=$(
          sudo -u ${ACTUAL_USER} gh api \
            --method POST \
            -H "Accept: application/vnd.github+json" \
            /repos/${GH_USER}/${GH_REPO}/actions/runners/registration-token \
            | jq -r .token
        )

    if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
        echo -e "   ${RED}✗${NC} Failed to get runner token"
        echo -e "   ${YELLOW}Check PAT permissions: repo, workflow, admin:org${NC}"
    else
        # Download and install runner
        USER_HOME=$(eval echo ~${ACTUAL_USER})
        RUNNER_DIR="$USER_HOME/actions-runner"

        echo -e "   ${YELLOW}Downloading runner...${NC}"
        mkdir -p "$RUNNER_DIR"
        chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$RUNNER_DIR"
        cd "$RUNNER_DIR"

        # Get latest runner version
        RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/v//')
        RUNNER_FILE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

        # Download runner with wget progress bar (same style as ISO download)
        if ! sudo -u ${ACTUAL_USER} wget -q --show-progress \
          "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_FILE}" \
          -O "$RUNNER_FILE"; then
            echo -e "   ${RED}✗${NC} Failed to download GitHub Actions runner"
            echo -e "   ${YELLOW}Check network / DNS / GitHub releases availability${NC}"
            exit 1
        fi

        sudo -u ${ACTUAL_USER} tar xzf "$RUNNER_FILE"
        rm "$RUNNER_FILE"

        # Configure runner
        echo -e "   ${YELLOW}Configuring runner...${NC}"
        if [ -f ".runner" ]; then
            echo -e "   ${YELLOW}Runner already configured, skipping config.sh${NC}"
        else
            RUNNER_NAME="$(hostname)"

            # Remove any existing runners in GitHub with the same name
            EXISTING_IDS=$(sudo -u ${ACTUAL_USER} gh api \
                /repos/${GH_USER}/${GH_REPO}/actions/runners \
                --paginate \
                -q '.runners[] | select(.name=="'"${RUNNER_NAME}"'") | .id' || true)

            if [ -n "$EXISTING_IDS" ]; then
                echo -e "   ${YELLOW}Found existing runner(s) named ${RUNNER_NAME} in GitHub, deleting...${NC}"
                for id in $EXISTING_IDS; do
                    echo -e "   ${YELLOW}   - Deleting runner ID ${id}${NC}"
                    sudo -u ${ACTUAL_USER} gh api \
                        --method DELETE \
                        "/repos/${GH_USER}/${GH_REPO}/actions/runners/${id}" \
                        >/dev/null 2>&1 || true
                done
            else
                echo -e "   ${YELLOW}No existing GitHub runners named ${RUNNER_NAME} found, nothing to delete${NC}"
            fi

            # Register new runner
            sudo -u ${ACTUAL_USER} ./config.sh \
                --url "$GH_REPO_URL" \
                --token "$RUNNER_TOKEN" \
                --name "${RUNNER_NAME}" \
                --labels "self-hosted,linux,$(uname -m)" \
                --unattended
        fi
        # Install as service
        echo -e "   ${YELLOW}Installing runner service...${NC}"
        ./svc.sh install ${ACTUAL_USER} || echo -e "   ${YELLOW}Runner service already installed (svc.sh install)${NC}"
        ./svc.sh start || echo -e "   ${YELLOW}Runner service already running (svc.sh start)${NC}"

        echo -e "   ${GREEN}✓${NC} GitHub runner installed and running"
        echo -e "   ${BLUE}Runner name: $(hostname)${NC}"
        echo -e "   ${BLUE}Check at: ${GH_REPO_URL}/settings/actions/runners${NC}"
    fi
else
    echo -e "${YELLOW}   GitHub runner setup skipped (no PAT provided)${NC}"
fi

echo -e "${GREEN}[6/6] Final system check...${NC}"
echo -e "   ${GREEN}✓${NC} Configuration complete"

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
echo -e "${YELLOW}System configured:${NC}"
echo "  ✓ Hostname: HOSTNAME_PLACEHOLDER"
echo "  ✓ SSH access configured"
echo "  ✓ Passwordless sudo enabled"
if [ -n "$GH_PAT" ] && [ "$GH_PAT" != "SKIP" ]; then
    echo "  ✓ GitHub runner installed and running"
fi
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Reboot the machine"
echo "  2. SSH in: ssh ${ACTUAL_USER}@HOSTNAME_PLACEHOLDER.local"
if [ -n "$GH_PAT" ] && [ "$GH_PAT" != "SKIP" ]; then
    echo "  3. Trigger GitHub workflows to deploy with Ansible"
else
    echo "  3. Run your Ansible playbook from controller"
fi
echo
echo -e "${GREEN}Machine is ready! 🚀${NC}"
echo
echo -e "${RED}╔═════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ⚠️  MISSION IMPOSSIBLE PROTOCOL ACTIVE  ⚠️   ║${NC}"
echo -e "${RED}╚═════════════════════════════════════════════╝${NC}"
echo
echo -e "${YELLOW}This script contains sensitive data (SSH key, GitHub PAT).${NC}"
echo
echo -e "${RED}This script will self-destruct in 5 seconds${NC}"
    echo
    echo -e "${RED}Initiating self-destruct sequence...${NC}"
    for i in 5 4 3 2 1; do
        echo -e "${RED}$i...${NC}"
        sleep 1
    done
    echo -e "${RED}💣 BOOM! Script deleted.${NC}"
    SCRIPT_PATH="${BASH_SOURCE[0]}"
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}✓ Sensitive data removed${NC}"

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

# Replace GitHub placeholders
sed -i "s|GH_USER_PLACEHOLDER|$GH_USER|g" setup-machine.sh
sed -i "s|GH_REPO_PLACEHOLDER|$GH_REPO|g" setup-machine.sh
sed -i "s|GH_REPO_URL_PLACEHOLDER|$GH_REPO_URL|g" setup-machine.sh

if [ -z "$GH_PAT" ]; then
    sed -i "s|GH_PAT_PLACEHOLDER|SKIP|" setup-machine.sh
else
    # Escape special characters for sed
    GH_PAT_ESCAPED=$(echo "$GH_PAT" | sed 's/[\/&]/\\&/g')
    sed -i "s|GH_PAT_PLACEHOLDER|$GH_PAT_ESCAPED|" setup-machine.sh
fi

chmod +x setup-machine.sh

if [ "$TEST_MODE" = false ]; then
    echo -e "${GREEN}Step 7: Creating USB 1 (Boot ISO)...${NC}"

    # Unmount USB1
    umount "/dev/${USB1_DEVICE}"* 2>/dev/null || true
    sleep 2

    echo -e "${BLUE}Flashing ISO to USB1...${NC}"
    dd if="$ISO_NAME" of="/dev/$USB1_DEVICE" bs=4M status=progress conv=fsync
    sync
    sleep 2
else
    echo -e "${YELLOW}[TEST MODE] Skipping USB 1 (Boot ISO) creation${NC}"
fi

echo -e "${GREEN}Step 8: Creating USB 2 (Setup Script)...${NC}"

# Unmount USB2 aggressively
echo -e "${BLUE}Unmounting /dev/$USB2_DEVICE...${NC}"

# First try normal unmount
for part in /dev/${USB2_DEVICE}*; do
    if [ -b "$part" ]; then
        umount "$part" 2>/dev/null || true
    fi
done

# Kill processes using the device
fuser -km "/dev/$USB2_DEVICE" 2>/dev/null || true
sleep 1

# Force unmount if still mounted (lazy unmount)
for part in /dev/${USB2_DEVICE}*; do
    if [ -b "$part" ]; then
        umount -l "$part" 2>/dev/null || true
    fi
done

# Wipe all filesystem signatures
echo -e "${BLUE}Wiping filesystem signatures...${NC}"
wipefs -af "/dev/$USB2_DEVICE" 2>/dev/null || true
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
✓ GitHub self-hosted runner

After setup, your machine is ready to:
- Run GitHub workflows that trigger Ansible deployments
- Or use traditional Ansible from controller
README_EOF

sync
umount /mnt/setup
rmdir /mnt/setup

echo
if [ "$TEST_MODE" = false ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          SUCCESS! Both USB drives ready!      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
else
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   TEST MODE: Setup USB Created Successfully!  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${YELLOW}Note: Only USB 2 (SETUP) was created. Boot from existing installation.${NC}"
fi

echo
echo -e "${YELLOW}Configuration Summary:${NC}"
echo -e "  Hostname:      ${GREEN}$HOSTNAME${NC}"
echo -e "  SSH Key:       ${GREEN}$([ -n "$SSH_KEY" ] && echo "Configured" || echo "Skipped")${NC}"
echo -e "  GitHub Repo:   ${GREEN}$GH_REPO_URL${NC}"
echo -e "  GitHub Runner: ${GREEN}Will be installed${NC}"
echo
echo -e "${YELLOW}USB Setup:${NC}"
echo -e "  ${GREEN}USB 1 (/dev/$USB1_DEVICE):${NC} Ubuntu Desktop ISO (bootable, GUI installer!)"
echo -e "  ${GREEN}USB 2 (/dev/$USB2_DEVICE):${NC} Post-install script (labeled SETUP)"
echo
echo -e "${YELLOW}Installation Process:${NC}"
echo -e "  ${BLUE}1.${NC} Boot from USB 1 (GUI installer with mouse support!)"
echo -e "  ${BLUE}2.${NC} Manual install (~10 min):"
echo -e "     - Select language"
echo -e "     - Select disk (choose target SSD)"
echo -e "     - Create user (any username you want)"
echo -e "     - Configure WiFi"
echo -e "  ${BLUE}3.${NC} After first boot, insert USB 2"
echo -e "  ${BLUE}4.${NC} Run: ${GREEN}sudo bash /media/USERNAME/SETUP/setup-machine.sh${NC}"
echo -e "  ${BLUE}5.${NC} Follow prompts for disk partitioning (optional)"
echo -e "  ${BLUE}6.${NC} Watch self-destruct sequence 💣 (script will delete itself!)"
echo -e "  ${BLUE}7.${NC} Reboot"
echo -e "  ${BLUE}8.${NC} SSH in: ${GREEN}ssh USERNAME@$HOSTNAME.local${NC}"
echo -e "  ${BLUE}9.${NC} GitHub runner is active! Trigger workflows or use Ansible directly"
echo
echo -e "${BLUE}GitHub Runner Configuration:${NC}"
echo -e "  Repository: ${GREEN}$GH_REPO_URL${NC}"
echo -e "  Runner will appear at: ${BLUE}$GH_REPO_URL/settings/actions/runners${NC}"
echo
echo -e "${YELLOW}⚠️  Security Note:${NC}"
echo -e "  Setup script contains sensitive data but will self-destruct after run!"
echo
echo -e "${BLUE}Note: Setup script auto-detects the user created during installation${NC}"
echo -e "${BLUE}Desktop environment can be disabled after install if not needed${NC}"
echo
echo -e "${GREEN}Architecture: $ARCH${NC}"
echo -e "${GREEN}ISO: $ISO_NAME${NC}"
echo -e "${GREEN}Ready to install! 🚀${NC}"

cd /
rm -rf "$WORK_DIR"
