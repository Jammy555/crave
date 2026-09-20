#!/bin/bash
# =============================================================================
# Device Configuration Template
# =============================================================================
# Copy this file to: devices/<your_device_codename>.sh
# Example: devices/marble.sh, devices/cheetah.sh
#
# Once created, you can build it with:
#   volt.sh --device=<codename> [bacon]
# or via GitHub Actions by selecting/typing your codename in the DEVICE input!
# =============================================================================

DEVICE_CODE="mydevice"
DEVICE_NAME="My Device Brand Model (mydevice)"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_mydevice-bp4a-userdebug}"

# --- Crave Project & Clone (Optional) ----------------------------------------
# Set CRAVE_PROJECT_ID to match the project ID from `crave clone list`
# and CRAVE_CLONE_PATH to a dedicated directory under /crave-devspaces/
CRAVE_PROJECT_ID="99"
CRAVE_CLONE_PATH="/crave-devspaces/Lineage23.2"

# --- Tree lookup: "repo_url|local_path|display_name|default_branch" --------
# Define all device-specific git repositories required for this build.
# You can add or remove entries as needed.
declare -g -A TREE_LOOKUP=(
    [kernel]="https://github.com/YourUsername/android_kernel_brand_platform.git|./kernel/brand/platform|kernel|16.2"
    [device]="https://github.com/YourUsername/android_device_brand_mydevice.git|./device/brand/mydevice|device tree|16.2"
    [common]="https://github.com/YourUsername/android_device_brand_platform-common.git|./device/brand/platform-common|common tree|16.2"
    [hardware]="https://github.com/LineageOS/android_hardware_brand.git|./hardware/brand|hardware|lineage-23.2"
    [vendor]="https://github.com/YourUsername/android_vendor_brand_mydevice.git|./vendor/brand/mydevice|vendor tree|16.2"
    [vendor-common]="https://github.com/YourUsername/android_vendor_brand_platform-common.git|./vendor/brand/platform-common|vendor common|16.2"
)

# --- Signing keys (optional) -------------------------------------------------
# Set KEYS_REPO to your keys repository, or leave empty if not using private keys.
KEYS_REPO="https://github.com/Jammy555/vendor_evolution-priv_keys-template.git"
KEYS_BRANCH="master"
KEYS_DIR="vendor/lineage-priv/keys"

# --- Optional Pre-lunch Hook -------------------------------------------------
# pre_lunch_hook() {
#     # Any custom commands before lunching
#     :
# }

# --- Optional Post-clone Hook ------------------------------------------------
# post_clone_hook() {
#     # Any custom patches or setup after cloning device trees
#     :
# }
