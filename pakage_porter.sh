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
VERSION="3.0"
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
        show_message "🔐 This tool needs administrator privileges. Please enter your password if prompted."
        if sudo -v &>/dev/null; then
            exec sudo "$0" "$@"
        else
            show_error "Failed to obtain sudo privileges. Please run this script with sudo."
            exit 1
        fi
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

# Function to install apt-rdepends if not installed
install_apt_rdepends() {
    if ! command -v apt-rdepends &> /dev/null; then
        show_message "📦 Installing apt-rdepends to resolve dependencies..."
        retry_command apt-get update
        retry_command apt-get install -y apt-rdepends
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
    cp "$deb_file" "$PACKAGE_DIR" 2>> "$LOG_FILE"

    # Store the main package name
    local package_name=$(dpkg-deb -f "$deb_file" Package)
    echo "$package_name" > "$PACKAGE_DIR/main_package.txt"
    
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
                if ! retry_command apt-get download "$dep"; then
                    show_warning "Failed to download: $dep. Trying alternative sources..."
                    if ! retry_command apt-get -t $(lsb_release -cs)-backports download "$dep"; then
                        if ! retry_command apt-get -t $(lsb_release -cs)-updates download "$dep"; then
                            show_warning "Failed to download $dep from all sources. Adding to unfetchable list."
                            UNFETCHABLE_DEPS+=("$dep")
                        fi
                    fi
                fi
                mv *.deb "$PACKAGE_DIR" 2>> "$LOG_FILE" || true
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
            if ! retry_command apt-get download "$package_name"; then
                show_warning "Failed to re-download $package_name. Attempting to find an alternative..."
                if ! retry_command apt-get -t $(lsb_release -cs)-backports download "$package_name"; then
                    if ! retry_command apt-get -t $(lsb_release -cs)-updates download "$package_name"; then
                        show_error "Failed to find an alternative for $package_name. Adding to unfetchable list."
                        UNFETCHABLE_DEPS+=("$package_name")
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

# Function to install all packages
install_packages() {
    show_message "🚀 Commencing intelligent package installation..."
    local total=$(ls "$PACKAGE_DIR"/*.deb | wc -l)
    local current=0
    local installation_order=()
    local failed_packages=()
    local retry_queue=()

    # Read the main package name
    if [[ -f "$PACKAGE_DIR/main_package.txt" ]]; then
        main_package=$(cat "$PACKAGE_DIR/main_package.txt")
    else
        show_error "Could not identify the main package. Exiting."
        exit 1
    fi

    # First pass: Gather dependency information and create installation order
    for deb in "$PACKAGE_DIR"/*.deb; do
        local package_name=$(dpkg-deb -f "$deb" Package)
        local package_deps=$(dpkg-deb -f "$deb" Depends | tr ',' '\n' | awk -F'[()]' '{print $1}' | tr -d ' ')
        echo "$package_name: $package_deps" >> "$TEMP_DIR/dep_info.txt"
    done

    # Topological sort to determine installation order
    tsort "$TEMP_DIR/dep_info.txt" 2>/dev/null > "$TEMP_DIR/install_order.txt" || true
    mapfile -t installation_order < <(tac "$TEMP_DIR/install_order.txt")

    # Remove main package from installation order (to be installed last)
    installation_order=(${installation_order[@]/$main_package})

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

    # Install dependencies
    for package in "${installation_order[@]}"; do
        local deb=$(find "$PACKAGE_DIR" -name "${package}_*.deb" -print -quit)
        if [[ -n "$deb" ]]; then
            current=$((current + 1))
            echo -ne "\r${BLUE}Installing dependency [$current/$total] ${package} ${NC}"
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

    # Resolve any remaining dependencies
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

    # Install the main package
    show_message "📦 Installing the main package: $main_package"
    local main_deb=$(find "$PACKAGE_DIR" -name "${main_package}_*.deb" -print -quit)
    if [[ -n "$main_deb" ]]; then
        if ! install_single_package "$main_deb"; then
            show_error "Failed to install the main package. Manual intervention may be required."
            UNFETCHABLE_DEPS+=("$main_package")
        else
            show_message "✅ Main package installed successfully!"
        fi
    else
        show_error "Could not find the main package file. Manual intervention required."
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

# Function to clean up in case of failure
cleanup_on_failure() {
    show_warning "🧹 Cleaning up partial installations..."
    retry_command apt-get install -f -y
    dpkg --configure -a
    retry_command apt-get autoremove -y
}

# Function to report unfetchable dependencies
report_unfetchable_dependencies() {
    if [ ${#UNFETCHABLE_DEPS[@]} -eq 0 ]; then
        show_message "🎉 Woohoo! Package porting complete with flying colors! 🌈"
        show_message "Every single dependency was successfully fetched and installed."
        show_message "Your ported package is ready to rock on the new system! 🚀"
    else
        show_warning "⚠️ The following dependencies could not be fetched or installed:"
        for dep in "${UNFETCHABLE_DEPS[@]}"; do
            echo "  - $dep"
        done
        show_info "Please check these dependencies manually and install them if necessary."
    fi
}

# Function to make a ported package (on old Ubuntu)
make_ported_package() {
    show_message "🧙‍♂️ Welcome to the Ported Package Creator!"
    read -p "$(cecho "$WHITE" "📜 Please provide the path to the .deb package you want to port: ")" package_path

    if [[ ! -f "$package_path" ]]; then
        show_error "The specified file does not exist: $package_path"
        return 1
    fi

    copy_and_resolve_dependencies "$package_path"
    check_package_integrity

    show_message "🎉 Ported package has been created successfully!"
    show_message "📁 The ported package and its dependencies are located in: $PACKAGE_DIR"
    show_message "📋 Instructions for the new Ubuntu system:"
    show_message "1. Copy the entire '$PACKAGE_DIR' folder to the new Ubuntu system."
    show_message "2. Place it in the exact same location: $PACKAGE_DIR"
    show_message "3. Run this script on the new system and choose 'Install Ported Package' from the menu."
}

# Function to install ported package (on new Ubuntu)
install_ported_package() {
    show_message "🧙‍♂️ Welcome to the Ported Package Installer!"
    show_message "🔍 Looking for the ported package folder..."

    if [ -d "$PACKAGE_DIR" ]; then
        show_message "✅ Ported package folder found: $PACKAGE_DIR"
        install_packages
        report_unfetchable_dependencies

        if [ -s "$CONFLICT_RESOLUTION_LOG" ]; then
            show_info "📋 Package conflict resolutions:"
            cat "$CONFLICT_RESOLUTION_LOG"
        fi

        show_message "🌟 Thank you for using the Self-Healing Magical Ubuntu Package Porter. May your packages always be compatible!"
    else
        show_error "❌ Ported package folder not found at: $PACKAGE_DIR"
        show_message "Please make sure you've copied the folder from the old Ubuntu system to this location."
    fi
}

# Function to display the main menu
show_menu() {
    clear
    cecho "$MAGENTA" "🧙‍♂️ Self-Healing Magical Ubuntu Package Porter v$VERSION"
    echo "----------------------------------------"
    echo "1. Make Ported Package (on old Ubuntu)"
    echo "2. Install Ported Package (on new Ubuntu)"
    echo "3. Exit"
    echo "----------------------------------------"
}

# Function to check system requirements
check_system_requirements() {
    if ! command -v apt-get &> /dev/null; then
        show_error "This script requires an Ubuntu-based system with apt package manager."
        exit 1
    fi
}

# Main script execution
main() {
    trap cleanup_on_failure ERR

    check_system_requirements
    ensure_sudo
    create_directories
    check_and_fix_package_manager

    while true; do
        show_menu
        read -p "Enter your choice [1-3]: " choice

        case $choice in
            1) make_ported_package ;;
            2) install_ported_package ;;
            3) show_message "Thank you for using the Self-Healing Magical Ubuntu Package Porter. Goodbye!"; exit 0 ;;
            *) show_error "Invalid option. Please try again." ;;
        esac

        read -p "Press Enter to continue..."
    done
}

# Run the main function
main "$@"
