#!/bin/bash
# =============================================================================
# Device Configuration: OnePlus 9 (lemonade)
# =============================================================================
# Architecture: Qualcomm Snapdragon 888 (SM8350)
# Vendor: OnePlus / OPlus
# =============================================================================

DEVICE_CODE="lemonade"
DEVICE_NAME="OnePlus 9 (lemonade)"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_lemonade-bp4a-userdebug}"

# --- Tree lookup: "repo_url|local_path|display_name|default_branch" --------
declare -g -A TREE_LOOKUP=(
    [kernel]="https://github.com/Jammy555/android_kernel_oneplus_sm8350.git|./kernel/oneplus/sm8350|kernel|16.2"
    [device]="https://github.com/Jammy555/android_device_oneplus_lemonade.git|./device/oneplus/lemonade|device tree|LUN"
    [common]="https://github.com/Jammy555/android_device_oneplus_sm8350-common.git|./device/oneplus/sm8350-common|common tree|16.2"
    [hardware]="https://github.com/Jammy555/hardware_oplus.git|./hardware/oplus|hardware|16.2"
    [vendor]="https://github.com/Jammy555/vendor_oneplus_lemonade.git|./vendor/oneplus/lemonade|vendor lemonade|VOS-t"
    [vendor-common]="https://github.com/Jammy555/vendor_oneplus_sm8350-common.git|./vendor/oneplus/sm8350-common|vendor common|Lun"
    [camera]="https://github.com/Jammy555/vendor_oplus_camera.git|./vendor/oplus/camera|oplus camera|16"
    [dolby]="https://github.com/Jammy555/vendor_oneplus_dolby.git|./vendor/sony/dolby|dolby|D2"
    [pixelworks]="https://github.com/LineageOS/android_hardware_pixelworks_interfaces.git|hardware/pixelworks/interfaces|pixelworks|lineage-23.2"
)

# --- Signing keys (optional) -------------------------------------------------
KEYS_REPO="https://github.com/Jammy555/vendor_evolution-priv_keys-template.git"
KEYS_BRANCH="master"
KEYS_DIR="vendor/lineage-priv/keys"
