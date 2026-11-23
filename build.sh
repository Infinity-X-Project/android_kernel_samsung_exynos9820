#!/bin/bash

set -e

DEVICES=("beyond0lte" "beyond1lte" "beyond2lte" "beyondx" "d1" "d1x" "d2s" "d2x" "f62")
KERNEL_DIR="$(pwd)"
OUT_BASE="$KERNEL_DIR/out"
AK3_DIR="$KERNEL_DIR/AnyKernel"
AK3_REPO="https://github.com/Lordify97/Anykernel.git"
TOOLCHAIN_DIR="/home/jay/infinity/prebuilts/clang/host/linux-x86/clang-r584948b"
GITHUB_REPO="git@github.com:LeDrew2017/FreeRunnerKernel.git"
RELEASE_DIR="$KERNEL_DIR/releases"

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="Lordify"
export KBUILD_BUILD_HOST="Meow"

if command -v ccache &> /dev/null; then
    export CC="ccache clang"
    export CXX="ccache clang++"
    echo "🚀 Using ccache to speed up compilation."
else
    export CC="clang"
    export CXX="clang++"
fi

USE_KSU=false
KSU_VERSION=""
RELEASE_TAG_VERSION=""

USE_NETHUNTER=false
NETHUNTER_CONFIG="$KERNEL_DIR/arch/arm64/configs/nethunter.config"

perform_clean() {
    echo "🧹 Cleaning all output directories..."
    rm -rf "$OUT_BASE"
    echo "✅ Clean complete."
}

print_header() {
    echo -e "\n=========================================="
    echo "$1"
    echo "=========================================="
}

print_section() {
    echo -e "\n--- $1 ---"
}

# Label artifacts with the KazeSU revision actually present in this kernel.
detect_kazesu_version() {
    local driver_dir
    local source_dir
    local git_root

    driver_dir=$(readlink -f "$KERNEL_DIR/drivers/kernelsu")
    if [ ! -f "$driver_dir/Kconfig" ]; then
        echo "❌ ERROR: KazeSU is not integrated. Run its legacy setup script first."
        return 1
    fi
    source_dir=$(dirname "$driver_dir")
    git_root=$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null) || {
        echo "❌ ERROR: Cannot read the KazeSU checkout's Git metadata."
        return 1
    }
    if [ "$git_root" != "$source_dir" ]; then
        echo "❌ ERROR: drivers/kernelsu must point to a separate KazeSU checkout."
        return 1
    fi
    if ! grep -q '^config KSU_SUSFS_DEINLINE$' "$driver_dir/Kconfig"; then
        echo "❌ ERROR: This non-GKI tree requires the updated KazeSU legacy source."
        return 1
    fi
    KSU_VERSION=$(git -C "$source_dir" describe --tags --always --dirty)
    echo "✅ KazeSU version: $KSU_VERSION"
}

build_device() {
    local device="$1"
    local kernel_version="$2"
    local release_subdir="$3"
    local defconfig="exynos9820-${device}_defconfig"
    local out_dir="${OUT_BASE}/${device}"
    local image_path="$out_dir/arch/arm64/boot/Image"

    echo -e "\n🔧 Starting build for: $device"

    make -C "$KERNEL_DIR" O="$out_dir" "$defconfig" LLVM=1 CC="$CC"

    # Merge NetHunter config fragment on top of defconfig, overriding any conflicts
    if [ "$USE_NETHUNTER" = true ]; then
        if [ ! -f "$NETHUNTER_CONFIG" ]; then
            echo "❌ ERROR: nethunter.config not found at $NETHUNTER_CONFIG"
            return 1
        fi
        echo "🩸 Merging NetHunter config fragment (overrides defconfig where conflicts exist)..."
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$out_dir" "$out_dir/.config" "$NETHUNTER_CONFIG"
        echo "✅ NetHunter config merged."
    fi

    # Apply the selected root mode after fragments so stock artifacts contain no KSU.
    if [ "$USE_KSU" = true ]; then
        "$KERNEL_DIR/scripts/config" --file "$out_dir/.config" \
            --enable KSU --enable KSU_MANUAL_HOOK \
            --disable KSU_TRACEPOINT_HOOK --disable KSU_TAMPER_SYSCALL_TABLE \
            --disable KSU_SUSFS_INLINE_HOOK
    else
        "$KERNEL_DIR/scripts/config" --file "$out_dir/.config" --disable KSU
    fi

    make -C "$KERNEL_DIR" O="$out_dir" olddefconfig LLVM=1 CC="$CC"

    local build_start=$(date +%s)
    make -C "$KERNEL_DIR" O="$out_dir" -j"$(nproc)" LLVM=1 CC="$CC"
    local build_end=$(date +%s)
    local duration=$((build_end - build_start))

    if [ ! -f "$image_path" ]; then
        echo "❌ Build FAILED for $device after $(printf "%02d:%02d" $((duration/60)) $((duration%60)))"
        return 1
    fi
    echo "✅ Build completed for $device in $(printf "%02d:%02d" $((duration/60)) $((duration%60)))"

    package_kernel "$device" "$kernel_version" "$image_path" "$release_subdir"
}

package_kernel() {
    local device="$1"
    local kernel_version="$2"
    local image_path="$3"
    local release_subdir="$4"

    echo "🧹 Cleaning up old kernel image from AnyKernel directory..."
    rm -f "${AK3_DIR}/Image"

    echo "📦 Copying new kernel Image to AnyKernel directory..."
    cp "$image_path" "$AK3_DIR/Image"

    pushd "$AK3_DIR" > /dev/null

    local version_suffix=""

    # Add KazeSU version to suffix if enabled
    if [ "$USE_KSU" = true ] && [[ -n "$KSU_VERSION" ]]; then
        version_suffix="-KazeSU-${KSU_VERSION}"
    fi

    # Add NetHunter to suffix if enabled
    if [ "$USE_NETHUNTER" = true ]; then
        version_suffix="${version_suffix}-NetHunter"
    fi

    local zip_name="FrEeRuNnErKeRnEl-${device}-${kernel_version}${version_suffix}-Anykernel3.zip"
    echo "📦 Creating AnyKernel zip: $zip_name..."
    sed -i "/device.name1=.*/c\device.name1=$device" $AK3_DIR/anykernel.sh
    zip -r9 "$zip_name" * -x .git\* README.md\* > /dev/null

    if [ -f "$zip_name" ]; then
        mkdir -p "$release_subdir"
        mv "$zip_name" "$release_subdir/"
        echo "✅ Packaged $zip_name successfully."
        rm -f Image
    else
        echo "❌ Failed to create AnyKernel zip for $device."
    fi

    popd > /dev/null
}

build_selected_devices() {
    local selected_devices=("$@")

    print_header "🚀 Building selected devices: ${selected_devices[*]}"

    local release_subdir="$RELEASE_DIR"
    if [ "$USE_KSU" = true ] && [ "$USE_NETHUNTER" = true ]; then
        release_subdir="$RELEASE_DIR/kazesu-nethunter"
    elif [ "$USE_KSU" = true ]; then
        release_subdir="$RELEASE_DIR/kazesu"
    elif [ "$USE_NETHUNTER" = true ]; then
        release_subdir="$RELEASE_DIR/nethunter"
    else
        release_subdir="$RELEASE_DIR/stock"
    fi
    mkdir -p "$release_subdir"

    local first_device=true
    for device in "${selected_devices[@]}"; do
        echo "=================================================="
        echo "Processing: $device"

        local defconfig_path="arch/arm64/configs/exynos9820-${device}_defconfig"
        if [ ! -f "$defconfig_path" ]; then
            echo "⚠️ Defconfig for $device not found. Skipping."
            continue
        fi

        local raw_version=$(grep 'CONFIG_LOCALVERSION=' "$defconfig_path" | cut -d'"' -f2)
        local kernel_version=$(echo "$raw_version" | grep -oP 'v[0-9]+(\.[0-9]+)*')

        if [ -z "$kernel_version" ]; then
            echo "⚠️ Could not extract kernel version for $device. Skipping."
            continue
        fi
        echo "📖 Detected kernel version for $device: $kernel_version"

        if [ "$first_device" = true ]; then
            RELEASE_TAG_VERSION="$kernel_version"
            first_device=false
        fi

        build_device "$device" "$kernel_version" "$release_subdir"
    done

    echo -e "\n✅ All selected device builds complete."
}

create_github_release() {
    if [ -z "$RELEASE_TAG_VERSION" ]; then
        echo "⚠️ Kernel version for release tag not set. Skipping release."
        return
    fi

    print_section "GitHub Release"
    echo "Select which builds to release:"
    echo "  1) All builds in releases folder"
    echo "  2) Only Stock builds (releases/stock)"
    echo "  3) Only KazeSU builds (releases/kazesu)"
    read -p "Select option (1-3) [default: 1]: " release_choice

    local zip_files=()
    case "$release_choice" in
        2)
            if [ -d "$RELEASE_DIR/stock" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/stock" -name "*.zip" -print0)
                echo "✔ Selected: Stock builds only"
            else
                echo "⚠️ Stock folder not found."
            fi
            ;;
        3)
            if [ -d "$RELEASE_DIR/kazesu" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/kazesu" -name "*.zip" -print0)
                echo "✔ Selected: KazeSU builds only"
            else
                echo "⚠️ KazeSU folder not found."
            fi
            ;;
        1|"")
            while IFS= read -r -d '' file; do
                zip_files+=("$file")
            done < <(find "$RELEASE_DIR" -name "*.zip" -print0)
            echo "✔ Selected: All builds"
            ;;
        *)
            echo "❌ Invalid selection. Using all builds."
            while IFS= read -r -d '' file; do
                zip_files+=("$file")
            done < <(find "$RELEASE_DIR" -name "*.zip" -print0)
            ;;
    esac

    if [ ${#zip_files[@]} -eq 0 ]; then
        echo "⚠️ No .zip files found. Skipping release."
        return
    fi

    read -p "Do you want to create a GitHub release with tag '$RELEASE_TAG_VERSION'? (y/N): " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo "Skipping GitHub release."
        return
    fi

    read -p "Enter Release Title: " release_title

    local temp_notes_file=$(mktemp)
    echo "Press Enter to open your default editor (${EDITOR:-nano}) to write the release notes."
    read -r
    ${EDITOR:-nano} "$temp_notes_file"

    if [ ! -s "$temp_notes_file" ]; then
        echo "❌ Release notes are empty. Aborting release."
        rm "$temp_notes_file"
        exit 1
    fi

    echo "🚀 Creating release and uploading artifacts..."
    gh release create "$RELEASE_TAG_VERSION" "${zip_files[@]}" \
        -R "$GITHUB_REPO" \
        --title "$release_title" \
        --notes-file "$temp_notes_file"

    echo "✅ GitHub release created successfully."
    rm "$temp_notes_file"
}

get_build_type_selection() {
    print_section "Build Type Selection"
    echo "Build options:"
    echo "  1) Stock"
    echo "  2) KazeSU"
    echo "  3) KazeSU + NetHunter"
    read -p "Select option (1-3) [default: 1]: " build_choice

    build_choice=${build_choice:-1}

    case "$build_choice" in
        1)
            echo "✔ Selected: Stock kernel"
            USE_KSU=false
            USE_NETHUNTER=false
            ;;
        2)
            echo "✔ Selected: KazeSU kernel"
            USE_KSU=true
            USE_NETHUNTER=false
            detect_kazesu_version
            echo "📌 KazeSU Version: $KSU_VERSION"
            ;;
        3)
            echo "✔ Selected: KazeSU + NetHunter kernel"
            USE_KSU=true
            USE_NETHUNTER=true
            if [ ! -f "$NETHUNTER_CONFIG" ]; then
                echo "❌ ERROR: nethunter.config not found at $NETHUNTER_CONFIG"
                exit 1
            fi
            detect_kazesu_version
            echo "📌 KazeSU Version: $KSU_VERSION"
            ;;
        *)
            echo "❌ Invalid selection. Using stock kernel."
            USE_KSU=false
            USE_NETHUNTER=false
            ;;
    esac
}

get_device_selection() {
    echo -e "\nPlease select device(s) to build:" >&2
    for i in "${!DEVICES[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${DEVICES[i]}" >&2
    done
    local all_option_num=$(( ${#DEVICES[@]} + 1 ))
    printf "  %2d) %s\n" "$all_option_num" "Build All Devices" >&2

    echo -e "\nYou can select:" >&2
    echo "  - A single device (e.g., 1)" >&2
    echo "  - Multiple devices separated by spaces (e.g., 1 3 5)" >&2
    echo "  - $all_option_num for all devices" >&2
    read -p "Enter selection: " selection

    IFS=' ' read -ra SELECTIONS <<< "$selection"

    local selected_devices=()
    local build_all=false

    for sel in "${SELECTIONS[@]}"; do
        if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
            echo "❌ Invalid selection: $sel. Please enter numbers only."
            exit 1
        fi

        if [ "$sel" -eq "$all_option_num" ]; then
            build_all=true
            break
        fi

        if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#DEVICES[@]}" ]; then
            echo "❌ Invalid selection: $sel. Please enter a number between 1 and $all_option_num."
            exit 1
        fi

        selected_devices+=("${DEVICES[((sel-1))]}")
    done

    if [ "$build_all" = true ]; then
        echo "all"
    else
        if [ ${#selected_devices[@]} -eq 0 ]; then
            echo "❌ No valid devices selected."
            exit 1
        fi
        echo "${selected_devices[@]}"
    fi
}


main() {
    if [[ "$1" == "--clean" ]]; then
        perform_clean
        exit 0
    fi

    if [ ! -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        echo "❌ ERROR: Infinity prebuilt Clang not found at $TOOLCHAIN_DIR/bin/clang"
        exit 1
    fi

    for cmd in git zip gh clang clang++; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ $cmd is not installed. Please install it to continue."
            exit 1
        fi
    done

    echo "🔧 Using Infinity prebuilt Clang: $(command -v clang)"
    clang --version

    if [ ! -d "$AK3_DIR" ]; then
        echo "AnyKernel directory not found. Cloning from repository..."
        git clone "$AK3_REPO" "$AK3_DIR"
    fi

    mkdir -p "$RELEASE_DIR"

    get_build_type_selection

    local device_selection=$(get_device_selection)
    local selected_devices=()

    if [ "$device_selection" == "all" ]; then
        selected_devices=("${DEVICES[@]}")
        echo -e "\n👍 You selected: Build All Devices"
    else
        read -ra selected_devices <<< "$device_selection"
        echo -e "\n👍 You selected: ${selected_devices[*]}"
    fi

    build_selected_devices "${selected_devices[@]}"

    if [ "$device_selection" == "all" ]; then
        create_github_release
    else
        echo -e "\n🎉 Build complete for selected devices."
    fi
}

main "$@"
