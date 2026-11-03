#!/usr/bin/env bash
# check_all.sh
# Master diagnostic checker runner for all Eldrid Linux hardware modules

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD='\033[1m'; NC='\033[0m'

echo "=================================================================="
echo -e "${BOLD}   ELDRID LINUX FIXES - COMPREHENSIVE HARDWARE DIAGNOSTICS        ${NC}"
echo "=================================================================="

bash "$DIR/check_touchscreen.sh"
bash "$DIR/check_keyboard.sh"
bash "$DIR/check_tablet.sh"
bash "$DIR/check_battery.sh"
bash "$DIR/check_fingerprint.sh"

echo ""
echo "=================================================================="
echo -e "${BOLD} DIAGNOSTIC RUN COMPLETE ${NC}"
echo "=================================================================="
