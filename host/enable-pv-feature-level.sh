#!/bin/sh
# Enable unrestricted Metal feature levels for Virtualization.framework
# guests started by this macOS user (required for Anka Metal boost).
set -eu

defaults write com.apple.gpusw.ParavirtualizedGraphics \
  ForceUnrestrictedDeviceFeatureLevel -bool true

printf 'Host preference enabled:\n'
defaults read com.apple.gpusw.ParavirtualizedGraphics
printf '\nStop and start Anka VMs so they pick up the new preference.\n'
