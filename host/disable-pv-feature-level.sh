#!/bin/sh
# Clear the unrestricted Metal feature-level host preference.
set -eu

if defaults read com.apple.gpusw.ParavirtualizedGraphics \
  ForceUnrestrictedDeviceFeatureLevel >/dev/null 2>&1
then
  defaults delete com.apple.gpusw.ParavirtualizedGraphics \
    ForceUnrestrictedDeviceFeatureLevel
fi

if defaults read com.apple.gpusw.ParavirtualizedGraphics >/dev/null 2>&1
then
  printf 'Remaining ParavirtualizedGraphics defaults:\n'
  defaults read com.apple.gpusw.ParavirtualizedGraphics
else
  printf 'ParavirtualizedGraphics host preference cleared.\n'
fi

printf 'Stop and start Anka VMs so they pick up the change.\n'
