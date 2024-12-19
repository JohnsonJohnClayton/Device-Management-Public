#!/bin/zsh

# Define the SMB server details
SERVER_NAME="Pinpoint Merch File Server"
SERVER_URL="//192.168.144.2/data"

# Add the server to Finder favorites
defaults write com.apple.sidebarlists favoriteservers -array-add "<dict><key>Name</key><string>$SERVER_NAME</string><key>URL</key><string>$SERVER_URL</string></dict>"

# Restart Finder to apply changes
killall Finder

# Check if defaults command succeeded
if [ $? -eq 0 ]; then
    echo "$SERVER_NAME ($SERVER_URL) added to Finder favorites successfully."

    # Restart Finder safely
    osascript -e 'tell application "Finder" to quit'
    sleep 2  # Give it a moment to quit completely
    open /System/Library/CoreServices/Finder.app
else
    echo "Failed to add server to Finder favorites."
fi