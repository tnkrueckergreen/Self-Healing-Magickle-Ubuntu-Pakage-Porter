#!/bin/bash

set -eo pipefail

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script variables
PACKAGE_DIR="/tmp/ubuntu_package_porter"
LOG_FILE="$PACKAGE_DIR/package_porter.log"
DEBUG_MODE=false
VERSION="2.0 (beta)"
MAX_RETRIES=5
RETRY_DELAY=5
UNFETCHABLE_DEPS=()
CONFLICT_RESOLUTION_LOG="$PACKAGE_DIR/conflict_resolution.log"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to check if running in a terminal that supports ASCII escape codes
supports_color() {
    test -t 1 && tput colors >/dev/null 2>&1
}

# Initialize color support
if supports_color; then
    USE_COLOR=true
else
    USE_COLOR=false
fi

# Color output function
cecho() {
    if [ "$USE_COLOR" = true ]; then
        echo -e "${1}${2}${NC}"
    else
        echo "${2}"
    fi
}

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Debug logging function
debug() {
    if [ "$DEBUG_MODE" = true ]; then
        log "DEBUG: $1"
    fi
}

# Enhanced message functions
show_message() { cecho "$GREEN" "\n✨ $1"; log "INFO: $1"; }
show_warning() { cecho "$YELLOW" "\n⚠️ Warning: $1"; log "WARNING: $1"; }
show_error() { cecho "$RED" "\n❌ Error: $1" >&2; log "ERROR: $1"; }
show_info() { cecho "$BLUE" "ℹ️ $1"; log "INFO: $1"; }

# Function to ensure running with sudo
ensure_sudo() {
    if [[ $EUID -ne 0 ]]; then
        show_error "This tool needs administrator privileges."
        show_message "Please run this script with sudo: sudo $0"
        exit 1
    fi
}

# Function to create necessary directories
create_directories() {
    mkdir -p "$PACKAGE_DIR"
    log "Created directory: $PACKAGE_DIR"
}

# Function to handle network issues by retrying commands with exponential backoff
retry_command() {
    local retries=$MAX_RETRIES
    local count=0
    local delay=$RETRY_DELAY

    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ "$count" -lt "$retries" ]; then
            show_warning "Command failed: $*. Retrying in $delay seconds ($count/$retries)..."
            sleep $delay
            delay=$((delay * 2))
        else
            show_error "Command failed after $retries attempts: $*"
            return $exit_code
        fi
    done
    return 0
}

# Function to check and fix package manager
check_and_fix_package_manager() {
    show_info "🔧 Checking package manager status..."
    if ! dpkg --configure -a; then
        show_warning "Package manager is in an inconsistent state. Attempting to fix..."
        retry_command apt-get update --fix-missing
        retry_command dpkg --configure -a
        retry_command apt-get install -f -y
        show_message "Package manager fixed successfully."
    else
        show_info "Package manager is in a good state."
    fi
}

# Ubuntu specific installation wrapper
ubuntu_install() {
    retry_command apt-get install -y "$@"
}

# Ubuntu specific download wrapper
ubuntu_download() {
    retry_command apt-get download "$@"
}

# Function to install apt-rdepends if not installed
install_apt_rdepends() {
    if ! command -v apt-rdepends &> /dev/null; then
        show_message "📦 Installing apt-rdepends to resolve dependencies..."
        retry_command apt-get update
        ubuntu_install apt-rdepends
    fi
}

# Function to copy a .deb package and resolve dependencies
copy_and_resolve_dependencies() {
    local deb_file=$1
    if [[ ! -f "$deb_file" ]]; then
        show_error "The specified file does not exist: $deb_file"
        exit 1
    fi

    show_message "🔮 Analyzing package and resolving dependencies..."
    if ! cp "$deb_file" "$PACKAGE_DIR" 2>> "$LOG_FILE"; then
        show_error "Failed to copy $deb_file to $PACKAGE_DIR. Check your permissions."
        exit 1
    fi

    local package_name=$(dpkg-deb -f "$deb_file" Package)
    install_apt_rdepends

    local processed_deps="$PACKAGE_DIR/processed_dependencies.txt"
    touch "$processed_deps"

    resolve_dependencies() {
        local pkg=$1
        local depth=$2

        if grep -q "^$pkg$" "$processed_deps"; then
            return
        fi

        echo "$pkg" >> "$processed_deps"

        local indent=$(printf '%*s' "$depth" | tr ' ' '  ')
        show_info "${indent}📦 Resolving: $pkg"

        local deps=$(apt-cache depends "$pkg" | grep 'Depends:' | cut -d ':' -f 2 | tr -d ' ')

        for dep in $deps; do
            if [[ "$dep" != "$package_name" ]] && ! grep -q "^$dep$" "$processed_deps"; then
                show_info "${indent}  ⬇️ Downloading: $dep"
                if ! ubuntu_download "$dep"; then
                    show_warning "Failed to download: $dep. Trying alternative sources..."
                    if ! ubuntu_download -t $(lsb_release -cs)-backports "$dep"; then
                        if ! ubuntu_download -t $(lsb_release -cs)-updates "$dep"; then
                            show_warning "Failed to download $dep from all sources. Adding to unfetchable list."
                            handle_unfetchable_dep "$dep"
                        fi
                    fi
                fi
                if ! mv *.deb "$PACKAGE_DIR" 2>> "$LOG_FILE"; then
                    show_error "Failed to move .deb files to $PACKAGE_DIR. Check your permissions."
                    exit 1
                fi
                resolve_dependencies "$dep" $((depth + 1))
            fi
        done
    }

    show_message "🌠 Resolving and downloading ALL dependencies for $package_name..."
    resolve_dependencies "$package_name" 0

    local total_deps=$(wc -l < "$processed_deps")
    show_message "✅ Finished resolving dependencies."
    show_info "📊 Total unique dependencies processed: $total_deps"
}

# Function to check integrity of downloaded packages
check_package_integrity() {
    show_info "🔍 Verifying integrity of downloaded packages..."
    local total=$(ls "$PACKAGE_DIR"/*.deb | wc -l)
    local current=0

    for deb in "$PACKAGE_DIR"/*.deb; do
        current=$((current + 1))
        echo -ne "\r${BLUE}Checking package [$current/$total] ${NC}"

        if ! dpkg-deb --info "$deb" &> /dev/null; then
            show_warning "Corrupted package detected: $deb. Removing and retrying..."
            rm "$deb"
            local package_name=$(basename "$deb" .deb | cut -d '_' -f 1)
            if ! ubuntu_download "$package_name"; then
                show_warning "Failed to re-download $package_name. Attempting to find an alternative..."
                if ! ubuntu_download -t $(lsb_release -cs)-backports "$package_name"; then
                    if ! ubuntu_download -t $(lsb_release -cs)-updates "$package_name"; then
                        show_error "Failed to find an alternative for $package_name. Adding to unfetchable list."
                        handle_unfetchable_dep "$package_name"
                    fi
                fi
            fi
        fi
    done
    echo
}

# Function to resolve package conflicts
resolve_package_conflicts() {
    local package=$1
    local version=$2
    local installed_version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)

    if [[ -n "$installed_version" ]]; then
        if dpkg --compare-versions "$installed_version" gt "$version"; then
            show_warning "Conflict detected: Installed version of $package ($installed_version) is newer than the version to be installed ($version)."
            show_info "Keeping the newer installed version to maintain compatibility with the current system."
            echo "Kept: $package $installed_version (installed) over $version" >> "$CONFLICT_RESOLUTION_LOG"
            return 1
        else
            show_info "Updating $package from $installed_version to $version"
            echo "Updated: $package $installed_version -> $version" >> "$CONFLICT_RESOLUTION_LOG"
            return 0
        fi
    fi
    return 0
}

# Function to handle unfetchable dependencies
handle_unfetchable_dep() {
    local dep=$1
    read -p "$(cecho "$YELLOW" "⚠️ Failed to fetch $dep. Continue anyway? [y/N]: ")" choice
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        show_error "Aborting due to unfetchable dependency: $dep"
        exit 1
    fi
    UNFETCHABLE_DEPS+=("$dep")
}

# Cleanup function in case of failure
cleanup_on_failure() {
    show_warning "🧹 Cleaning up after failure..."
    retry_command apt-get install -f -y
    dpkg --configure -a
    retry_command apt-get autoremove -y
    retry_command apt-get clean
    show_message "System cleaned successfully. You can retry the operation."
}

# Enhanced install_packages function
install_packages() {
    show_message "🚀 Commencing intelligent package installation..."
    local total=$(ls "$PACKAGE_DIR"/*.deb | wc -l)
    local current=0
    local installation_order=()
    local failed_packages=()
    local retry_queue=()

    # First pass: Gather dependency information and create installation order
    for deb in "$PACKAGE_DIR"/*.deb; do
        local package_name=$(dpkg-deb -f "$deb" Package)
        local package_deps=$(dpkg-deb -f "$deb" Depends | tr ',' '\n' | awk -F'[()]' '{print $1}' | tr -d ' ')
        echo "$package_name: $package_deps" >> "$TEMP_DIR/dep_info.txt"
    done

    # Topological sort to determine installation order
    tsort "$TEMP_DIR/dep_info.txt" 2>/dev/null > "$TEMP_DIR/install_order.txt" || true
    mapfile -t installation_order < <(tac "$TEMP_DIR/install_order.txt")

    # Function to install a single package
    install_single_package() {
        local deb=$1
        local package_name=$(dpkg-deb -f "$deb" Package)
        local package_version=$(dpkg-deb -f "$deb" Version)

        if resolve_package_conflicts "$package_name" "$package_version"; then
            if ! dpkg -i "$deb" 2>> "$LOG_FILE"; then
                show_warning "Failed to install $deb. Adding to retry queue..."
                retry_queue+=("$deb")
                return 1
            fi
        else
            show_info "Skipping installation of $package_name due to conflict resolution."
        fi
        return 0
    }

    # Main installation loop
    for package in "${installation_order[@]}"; do
        local deb=$(find "$PACKAGE_DIR" -name "${package}_*.deb" -print -quit)
        if [[ -n "$deb" ]]; then
            current=$((current + 1))
            echo -ne "\r${BLUE}Installing package [$current/$total] ${package} ${NC}"
            install_single_package "$deb" || true
        fi
    done
    echo

    # Retry failed installations
    if [[ ${#retry_queue[@]} -gt 0 ]]; then
        show_info "🔄 Retrying failed package installations..."
        for deb in "${retry_queue[@]}"; do
            show_info "Retrying installation of $(basename "$deb")..."
            if ! install_single_package "$deb"; then
                failed_packages+=("$(basename "$deb")")
            fi
        done
    fi

    # Final dependency resolution
    show_info "🧩 Resolving any remaining dependencies..."
    retry_command apt-get install -f -y

    # Handle any remaining failed packages
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        show_warning "The following packages could not be installed:"
        for pkg in "${failed_packages[@]}"; do
            echo "  - $pkg"
        done
        show_info "Attempting advanced recovery for failed packages..."
        for pkg in "${failed_packages[@]}"; do
            show_info "Recovering $pkg..."
            apt-get download $(dpkg-deb -f "$PACKAGE_DIR/$pkg" Package) || true
            if [[ -f *.deb ]]; then
                if dpkg -i *.deb; then
                    show_message "Successfully recovered $pkg!"
                    rm *.deb
                else
                    show_warning "Could not recover $pkg. Manual intervention may be required."
                    UNFETCHABLE_DEPS+=($(dpkg-deb -f "$PACKAGE_DIR/$pkg" Package))
                fi
            else
                show_warning "Could not find a suitable version of $pkg for recovery."
                UNFETCHABLE_DEPS+=($(dpkg-deb -f "$PACKAGE_DIR/$pkg" Package))
            fi
        done
    fi

    # Check for broken packages and attempt to fix
    show_info "🔍 Checking for broken packages..."
    if dpkg-query -W -f='${Status}\n' | grep -q "installed.*unpacked"; then
        show_warning "Detected broken packages. Attempting to fix..."
        apt-get install --fix-broken -y
        dpkg --configure -a
        apt-get update
        apt-get upgrade -y
    fi

    # Final system update and cleanup
    show_info "🧹 Performing final system update and cleanup..."
    apt-get update
    apt-get upgrade -y
    apt-get autoremove -y
    apt-get clean

    show_message "🎉 Intelligent package installation completed!"
}

# Confirmation function before long operations
confirm() {
    read -p "$(cecho "$YELLOW" "⚠️ Are you sure you want to proceed? [y/N]: ")" choice
    case "$choice" in 
        y|Y ) return 0 ;;
        * ) return 1 ;;
    esac
}

# Main menu function
main_menu() {
    while true; do
        cecho "$CYAN" "\n--- Self-Healing Magical Ubuntu Package Porter v$VERSION ---"
        echo "1) Make Ported Package"
        echo "2) Install Ported Package"
        echo "3) Exit"
        read -rp "$(cecho "$MAGENTA" "Please choose an option: ")" choice

        case $choice in
            1)
                if confirm; then
                    make_ported_package
                else
                    show_message "Aborted Make Ported Package."
                fi
                ;;
            2)
                if confirm; then
                    install_packages
                else
                    show_message "Aborted Install Ported Package."
                fi
                ;;
            3) 
                show_message "Thank you for using the Self-Healing Magical Ubuntu Package Porter. Goodbye!"; exit 0 ;;
            *) 
                show_error "Invalid option. Please try again." ;;
        esac
    done
}

# Ensure the script is running with sudo
ensure_sudo

# Create necessary directories and start the main menu
create_directories
main_menu
