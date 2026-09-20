#!/bin/bash
# =============================================================================
# Device Configuration: Motorola Moto G10/Power (capri)
# =============================================================================
# Architecture: Qualcomm Snapdragon 680 (SM6225)
# Vendor: Motorola
# =============================================================================

DEVICE_CODE="capri"
DEVICE_NAME="Motorola Moto G10 / G10 Power (capri)"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_capri-bp4a-userdebug}"

# --- Tree lookup: "repo_url|local_path|display_name|default_branch" --------
declare -g -A TREE_LOOKUP=(
    [kernel]="https://github.com/Jammy555/kernel_motorola_sm6225.git|./kernel/motorola/sm6225|kernel|16.2"
    [device]="https://github.com/Jammy555/device_motorola_capri.git|./device/motorola/capri|device tree|16.2"
    [common]="https://github.com/Jammy555/device_motorola_sm6225-common.git|./device/motorola/sm6225-common|common tree|16.2"
    [hardware]="https://github.com/LineageOS/android_hardware_motorola.git|./hardware/motorola|hardware|lineage-23.2"
    [vendor]="https://github.com/Jammy555/vendor_motorola_capri.git|./vendor/motorola/capri|vendor capri|lineage-23.2"
    [vendor-common]="https://github.com/Jammy555/vendor_motorola_sm6225-common.git|./vendor/motorola/sm6225-common|vendor common|16.2"
    [dolby]="https://github.com/Jammy555/vendor_oneplus_dolby.git|./vendor/sony/dolby|dolby|D2"
)

# --- Signing keys (optional) -------------------------------------------------
KEYS_REPO="https://github.com/Jammy555/vendor_evolution-priv_keys-template.git"
KEYS_BRANCH="master"
KEYS_DIR="vendor/lineage-priv/keys"
