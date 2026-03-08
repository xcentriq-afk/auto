#!/usr/bin/env bash

IFS=$'\n\t'

# load shared helpers
source "$(dirname "$0")/common.sh"


echo
info ">>> Uruchamianie snapped.sh..."
echo

chmod +x snapped.sh stage1.sh stage2.sh
bash ./snapped.sh
bash ./stage1.sh