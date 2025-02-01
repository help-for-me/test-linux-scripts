#!/bin/bash
# cd_ripper.sh
#
# This script automates CD ripping using whipper, beets, and dialog for user input.
#
# Features:
#   • On first interactive run (if no configuration file exists), prompt via dialog for:
#         - Temporary ripping directory
#         - Final destination directory for processed CDs
#         - Discord webhook URL for notifications
#     Then automatically write these settings (read-only) to a configuration file.
#
#   • When run with "--install", the script installs itself as a systemd service so that
#     it runs automatically on boot.
#
#   • When run with "--update", the script downloads a fresh copy of itself from the
#     specified URL and replaces the current version.
#
#   • When running normally, it:
#         1. Waits for a CD to be inserted (using whipper for detection).
#         2. On the first CD, extracts the drive offset from whipper’s output and sends a
#            Discord notification (including the offset).
#         3. Rips the CD using that offset into a temporary directory.
#         4. Uses beets to tag, rename, and add artwork.
#         5. Moves the album to a final location with the structure:
#                [FINAL_DEST]/[artist]/[artist] - [album] - [year]/
#         6. Sends a Discord notification for success or failure.
#         7. Ejects the CD (without attempting to “close” the drive).
#
# Dependencies: dialog, whipper, beets, eject, curl, systemctl (for installation)
#

# --------------------------------------------------
# Section A: Update Routine (--update)
# --------------------------------------------------
if [ "$1" == "--update" ]; then
    # URL for the latest version of this script.
    UPDATE_URL="https://raw.githubusercontent.com/help-for-me/test/refs/heads/main/cd_ripper.sh?token=GHSAT0AAAAAAC6GZ5P2TNSKWRJ4NBROREDYZ46KQRQ"
    # Determine the absolute path to this script.
    SCRIPT_PATH="$(readlink -f "$0")"
    TMPFILE=$(mktemp /tmp/cd_ripper.sh.XXXXXX)
    
    echo "Downloading the latest version of cd_ripper.sh..."
    curl -sSL "$UPDATE_URL" -o "$TMPFILE"
    
    if [ $? -eq 0 ]; then
        chmod +x "$TMPFILE"
        # Overwrite the current script file.
        mv "$TMPFILE" "$SCRIPT_PATH"
        echo "Update successful. Please re-run the script."
        exit 0
    else
        echo "Update failed. Please check your network connection or URL."
        exit 1
    fi
fi

# --------------------------------------------------
# Section B: Auto-install Required Dependencies
# --------------------------------------------------
# Define a mapping between required command names and their Debian package names.
declare -A pkgMap=(
    ["dialog"]="dialog"
    ["whipper"]="whipper"
    ["beet"]="beets"
    ["eject"]="eject"
    ["curl"]="curl"
)

MISSING_PACKAGES=()
for cmd in "${!pkgMap[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("${pkgMap[$cmd]}")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "Missing dependencies detected: ${MISSING_PACKAGES[*]}"
    echo "Updating package lists and installing missing packages..."
    apt-get update && apt-get install -y "${MISSING_PACKAGES[@]}"
fi

# --------------------------------------------------
# Section C: Self‑Installation Routine (--install)
# --------------------------------------------------
if [ "$1" == "--install" ]; then
    # Determine the absolute path of this script.
    SCRIPT_PATH="$(readlink -f "$0")"
    SERVICE_FILE="/etc/systemd/system/cd_ripper.service"

    cat <<EOF | sudo tee "$SERVICE_FILE" >/dev/null
[Unit]
Description=CD Ripping Service
After=network.target

[Service]
ExecStart=${SCRIPT_PATH}
Restart=always
User=$(whoami)
# If dialog is required and an X display is available, adjust DISPLAY accordingly.
Environment=DISPLAY=:0
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=cd_ripper

[Install]
WantedBy=multi-user.target
EOF

    echo "Systemd service file created at $SERVICE_FILE"
    sudo systemctl daemon-reload
    sudo systemctl enable cd_ripper.service
    sudo systemctl start cd_ripper.service
    echo "cd_ripper service enabled and started."
    exit 0
fi

# --------------------------------------------------
# Section D: Preliminary Checks (for safety)
# --------------------------------------------------
for cmd in dialog whipper beet eject curl; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done

# --------------------------------------------------
# Section E: Configuration (via Dialog)
# --------------------------------------------------
# We will store configuration in /etc/cd_ripper.conf.
# This file is auto‑generated (and should not be manually edited by the user).
CONFIG_FILE="/etc/cd_ripper.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    # If running interactively, prompt the user for configuration values.
    if [ -t 0 ]; then
        TEMP_RIP_DIR=$(dialog --stdout --title "Temporary Ripping Directory" \
            --inputbox "Enter the temporary directory where CDs will be ripped:" 8 60)
        FINAL_DEST=$(dialog --stdout --title "Final Destination Directory" \
            --inputbox "Enter the final destination directory for processed CDs:" 8 60)
        DISCORD_WEBHOOK_URL=$(dialog --stdout --title "Discord Webhook URL" \
            --inputbox "Enter the Discord webhook URL for notifications:" 8 60)

        # Validate input (basic check).
        if [ -z "$TEMP_RIP_DIR" ] || [ -z "$FINAL_DEST" ] || [ -z "$DISCORD_WEBHOOK_URL" ]; then
            echo "All configuration values are required. Exiting."
            exit 1
        fi

        # Write the configuration file (as root if needed).
        CONFIG_DATA="TEMP_RIP_DIR=\"$TEMP_RIP_DIR\"
FINAL_DEST=\"$FINAL_DEST\"
DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\""
        if ! echo "$CONFIG_DATA" | sudo tee "$CONFIG_FILE" >/dev/null; then
            echo "Failed to write configuration to $CONFIG_FILE. Exiting."
            exit 1
        fi
        echo "Configuration saved to $CONFIG_FILE."
    else
        echo "Error: No configuration file found and not running interactively." >&2
        exit 1
    fi
fi

# Load configuration (do not allow user to edit manually).
source "$CONFIG_FILE"

# Ensure the temporary directory exists.
mkdir -p "$TEMP_RIP_DIR"

# --------------------------------------------------
# Section F: Global Variables
# --------------------------------------------------
DRIVE_OFFSET=""

# --------------------------------------------------
# Section G: Helper Functions
# --------------------------------------------------
send_discord() {
    # Sends a generic message to Discord.
    local message="$1"
    curl -s -H "Content-Type: application/json" -X POST \
         -d "{\"content\": \"${message//\"/\\\"}\"}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
}

notify_success() {
    local artist="$1" album="$2" year="$3"
    local msg="**CD Ripping: Success**"
    [ -n "$artist" ] && msg+="\n**Artist:** $artist"
    [ -n "$album"  ] && msg+="\n**Album:** $album"
    [ -n "$year"   ] && msg+="\n**Year:** $year"
    send_discord "$msg"
}

notify_failure() {
    local reason="$1"
    send_discord "**CD Ripping: Failure**\n$reason"
}

# Extract album info from a directory name formatted as "Artist - Album - Year"
parse_album_info() {
    local dirname="$1"
    IFS=' - ' read -r artist album year <<< "$(basename "$dirname")"
    echo "$artist|$album|$year"
}

# Processes a single CD.
process_cd() {
    # Confirm a CD is present.
    if ! whipper cd-info > /dev/null 2>&1; then
        return 1
    fi

    dialog --msgbox "CD detected. Starting ripping process." 5 50

    # Determine drive offset on the first rip.
    if [ -z "$DRIVE_OFFSET" ]; then
        # Adjust parsing as needed based on whipper output.
        DRIVE_OFFSET=$(whipper cd-info 2>&1 | grep -i "offset" | head -n1 | grep -oE '[0-9]+')
        [ -z "$DRIVE_OFFSET" ] && DRIVE_OFFSET=0
        dialog --msgbox "Drive offset detected: $DRIVE_OFFSET" 5 50
        send_discord "Drive offset detected: $DRIVE_OFFSET"
    fi

    # Clear the temporary directory.
    rm -rf "$TEMP_RIP_DIR"/*
    dialog --infobox "Ripping the CD...\nPlease wait." 5 50

    # Rip the disc using the determined offset (adjust options as needed).
    if ! whipper rip --offset "$DRIVE_OFFSET" --output "$TEMP_RIP_DIR"; then
        dialog --msgbox "Error during ripping." 5 50
        notify_failure "Error during ripping."
        eject
        return 1
    fi
    dialog --msgbox "CD ripping completed successfully." 5 50

    dialog --infobox "Tagging and renaming the CD with beets...\nPlease wait." 5 50
    if ! beet import "$TEMP_RIP_DIR" --quiet; then
        dialog --msgbox "Beets encountered an error during import." 5 50
        notify_failure "Beets import error."
        # Continue even if tagging fails.
    else
        dialog --msgbox "Tagging and renaming completed." 5 50
    fi

    # Locate the album directory created by beets.
    album_dir=$(find "$TEMP_RIP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$album_dir" ]; then
        dialog --msgbox "No album directory found." 5 50
        notify_failure "No album directory found after tagging."
    else
        IFS='|' read -r artist album year <<< "$(parse_album_info "$album_dir")"
        dest_path="$FINAL_DEST/$artist/$(basename "$album_dir")"
        mkdir -p "$(dirname "$dest_path")"
        mv "$album_dir" "$dest_path"
        dialog --msgbox "Album moved to: $dest_path" 5 50
        notify_success "$artist" "$album" "$year"
    fi

    eject
    return 0
}

# --------------------------------------------------
# Section H: Main Loop
# --------------------------------------------------
while true; do
    dialog --infobox "Waiting for a CD to be inserted...\n\nPlease insert a CD." 5 50
    sleep 2

    # If a CD is detected, process it.
    if process_cd; then
        sleep 5
    else
        sleep 3
    fi
done
