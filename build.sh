#!/bin/bash

set -euo pipefail

set -x

export PATH="$PATH:/sbin:/usr/sbin"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
DEFAULT_JOBS="$(( $(getconf _NPROCESSORS_ONLN) * 2 ))"
ARCH_VALUE="arm64"
CROSS_COMPILE_VALUE="aarch64-linux-gnu-"
APT_UPDATED=0
APT_RUNNER=()
KERNEL_PACKAGES=(
    git
    lsb-release
    gcc-aarch64-linux-gnu
    bison
    flex
    libssl-dev
    libssl-dev:arm64
    libelf-dev
    debhelper
    bc
    rsync
    kmod
    cpio
    libdw-dev
    python3
)
BOOTIMG_PACKAGES=(
    coreutils
    curl
    xz-utils
    tar
    binfmt-support
    proot
    qemu-user-static
    mkbootimg
    util-linux
)
DOWNLOAD_SERVER="images.linuxcontainers.org"
DOWNLOAD_INDEX_PATH="/meta/1.0/index-system"
DOWNLOAD_DISTRO="debian;trixie;arm64;default"
DTB_FILE="msm8916-thwc-ufi003.dtb"
DTB_FILE_NO_MODEM="msm8916-thwc-ufi003-no-modem.dtb"
DTB_FILE_NO_MODEM_OC="msm8916-thwc-ufi003-no-modem-oc.dtb"
RAMDISK_FILE="initrd.img"
ROOT_PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
BOOT_CMDLINE="earlycon root=PARTUUID=$ROOT_PARTUUID console=ttyMSM0,115200 no_framebuffer=true rw"

usage() {
    cat <<'EOF'
Usage: ./build.sh [kernel|bootimg|all|clean|deps]

Commands:
  kernel   Build arm64 kernel .deb packages into ./artifacts (default)
  bootimg  Build boot images from packages already present in ./artifacts
  all      Build kernel packages, then build boot images
  clean    Remove generated packages, boot images, and temporary build files
  deps     Print the apt packages needed on Debian 13 (Trixie)

Environment overrides:
  JOBS=<n>              Parallel jobs for make, default: CPU threads / 2
  ARTIFACTS_DIR=<path>  Output directory for generated artifacts
  ARCH=<arch>           Defaults to arm64
  CROSS_COMPILE=<pref>  Defaults to aarch64-linux-gnu-

This script requires Debian 13 (Trixie) and will install missing packages automatically.
EOF
}

log() {
    printf '[build.sh] %s\n' "$*"
}

die() {
    printf '[build.sh] ERROR: %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd="$1"

    command_exists "$cmd" || die "Missing command: $cmd"
}

setup_apt_runner() {
    if [[ ${#APT_RUNNER[@]} -gt 0 ]]; then
        return
    fi

    if [[ $(id -u) -eq 0 ]]; then
        APT_RUNNER=()
        return
    fi

    require_command sudo
    APT_RUNNER=(sudo)
}

apt_run() {
    "${APT_RUNNER[@]}" "$@"
}

run_as_root() {
    setup_apt_runner
    "${APT_RUNNER[@]}" "$@"
}

ensure_debian13() {
    local distro_id=""
    local version_id=""
    local version_codename=""

    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; Debian 13 (Trixie) is required."

    distro_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    version_id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    version_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"

    if [[ "$distro_id" != "debian" || "$version_id" != "13" || "$version_codename" != "trixie" ]]; then
        die "Unsupported host: ${distro_id:-unknown} ${version_id:-unknown} (${version_codename:-unknown}). Debian 13 (Trixie) is required."
    fi
}

ensure_arm64_architecture() {
    if dpkg --print-foreign-architectures | grep -qx 'arm64'; then
        return
    fi

    setup_apt_runner
    log "Adding arm64 as a foreign architecture"
    apt_run dpkg --add-architecture arm64
}

apt_update_once() {
    if [[ "$APT_UPDATED" -eq 1 ]]; then
        return
    fi

    setup_apt_runner
    log "Running apt-get update"
    apt_run apt-get update
    APT_UPDATED=1
}

install_missing_packages() {
    local packages=("$@")
    local missing_packages=()
    local package_name=""

    for package_name in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q 'install ok installed'; then
            missing_packages+=("$package_name")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return
    fi

    apt_update_once
    log "Installing missing packages: ${missing_packages[*]}"
    apt_run apt-get install -y "${missing_packages[@]}"
}

print_deps() {
    cat <<'EOF'
Required host system:
    Debian 13 (Trixie)

Kernel package build dependencies:
  git lsb-release gcc-aarch64-linux-gnu bison flex libssl-dev \
  libssl-dev:arm64 libelf-dev debhelper bc rsync kmod cpio

Boot image build dependencies:
    coreutils curl xz-utils tar binfmt-support proot qemu-user-static mkbootimg util-linux

Example:
  sudo dpkg --add-architecture arm64
  sudo apt-get update
  sudo apt-get install -y git lsb-release gcc-aarch64-linux-gnu bison flex \
    libssl-dev libssl-dev:arm64 libelf-dev debhelper bc rsync kmod cpio \
    coreutils curl xz-utils tar binfmt-support proot qemu-user-static mkbootimg util-linux
EOF
}

prepare_artifacts_dir() {
    mkdir -p "$ARTIFACTS_DIR"
}

has_qemu_binfmt() {
    [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]
}

run_rootfs_script() {
    local rootfs_dir="$1"

    log "Using binfmt_misc + chroot for arm64 rootfs"
    # docker run --privileged --rm tonistiigi/binfmt --install arm64

    cleanup_bootimg_mounts() {
        local mount_path=""

        for mount_path in "$rootfs_dir/proc" "$rootfs_dir/dev/pts" "$rootfs_dir/dev" "$rootfs_dir/sys"; do
            if run_as_root mountpoint -q "$mount_path"; then
                run_as_root umount "$mount_path"
            fi
        done
    }

    trap cleanup_bootimg_mounts RETURN

    run_as_root mount --bind /proc "$rootfs_dir/proc"
    run_as_root mount --bind /dev "$rootfs_dir/dev"
    run_as_root mount --bind /dev/pts "$rootfs_dir/dev/pts"
    run_as_root mount --bind /sys "$rootfs_dir/sys"
    run_as_root env LANG=C LANGUAGE=C LC_ALL=C chroot "$rootfs_dir" /tmp/chroot.sh

    trap - RETURN
    cleanup_bootimg_mounts
    return
}

write_chroot_script() {
    local chroot_script="$1"

    cat > "$chroot_script" <<EOF
#!/bin/bash

set -euo pipefail

cat <<EOI > /etc/fstab
PARTUUID=$ROOT_PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOI

#rm -rf /etc/resolv.conf
#echo "nameserver 8.8.8.8" > /etc/resolv.conf

cat <<EOI > /etc/apt/sources.list
deb http://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security/ trixie-security main contrib non-free non-free-firmware
EOI

apt-get update
apt-get install -y initramfs-tools
apt-get install -y /tmp/*.deb

EOF

    chmod 755 "$chroot_script"
}

build_boot_image_variant() {
    local image_gz="$1"
    local dtb_path="$2"
    local ramdisk_path="$3"
    local output_path="$4"
    local kernel_dtb_path="$5"

    cat "$image_gz" "$dtb_path" > "$kernel_dtb_path"
    mkbootimg \
        --base 0x80000000 \
        --kernel_offset 0x00080000 \
        --ramdisk_offset 0x02000000 \
        --tags_offset 0x01e00000 \
        --pagesize 2048 \
        --second_offset 0x00f00000 \
        --ramdisk "$ramdisk_path" \
        --cmdline "$BOOT_CMDLINE" \
        --kernel "$kernel_dtb_path" -o "$output_path"
}

build_kernel() {
    local jobs="${JOBS:-$DEFAULT_JOBS}"
    local arch="${ARCH:-$ARCH_VALUE}"
    local cross_compile="${CROSS_COMPILE:-$CROSS_COMPILE_VALUE}"

    ensure_debian13
    ensure_arm64_architecture
    install_missing_packages "${KERNEL_PACKAGES[@]}"
    require_command make
    require_command dpkg-buildpackage
    require_command "${cross_compile}gcc"
    prepare_artifacts_dir

    log "Building kernel Debian packages"
    log "ARCH=$arch CROSS_COMPILE=$cross_compile JOBS=$jobs"

    (
        cd "$ROOT_DIR"
        export ARCH="$arch"
        export CROSS_COMPILE="$cross_compile"

        make ufi003_defconfig
        make deb-pkg -j"$jobs"
    )

    log "Collecting build artifacts into $ARTIFACTS_DIR"

    find "$ROOT_DIR/.." -maxdepth 1 -type f \( \
        -name 'linux-image-*.deb' -o \
        -name 'linux-headers-*.deb' -o \
        -name 'linux-libc-dev_*.deb' -o \
        -name 'linux-image-*.changes' -o \
        -name 'linux-headers-*.changes' -o \
        -name 'linux-libc-dev_*.changes' -o \
        -name 'linux-*.buildinfo' -o \
        -name 'linux-*.tar.gz' -o \
        -name 'linux-*.dsc' \) \
        -exec cp -f -t "$ARTIFACTS_DIR" {} +

    if ! compgen -G "$ARTIFACTS_DIR/linux-image-*.deb" >/dev/null; then
        die "Kernel packages were not produced. Check the build log above."
    fi

    log "Kernel packages are ready in $ARTIFACTS_DIR"
}

build_bootimg() {
    local work_dir="$ROOT_DIR/.bootimg-work"
    local rootfs_dir="$work_dir/rootfs"
    local rootfs_tarball="$work_dir/rootfs.tar.xz"
    local rootfs_url=""
    local chroot_script="$rootfs_dir/tmp/chroot.sh"
    local image_gz="$work_dir/Image.gz"
    local ramdisk_path="$work_dir/$RAMDISK_FILE"
    local kernel_dtb_path="$work_dir/kernel-dtb"
    local image_packages=()
    local latest_image_package=""

    ensure_debian13
    ensure_arm64_architecture
    install_missing_packages "${BOOTIMG_PACKAGES[@]}"
    require_command curl
    require_command tar
    require_command mkbootimg
    require_command qemu-aarch64-static
    require_command chroot
    require_command mount
    require_command mountpoint
    require_command umount

    if ! compgen -G "$ARTIFACTS_DIR/linux-image-*.deb" >/dev/null; then
        die "No linux-image package found in $ARTIFACTS_DIR. Run './build.sh kernel' first."
    fi

    prepare_artifacts_dir

    rootfs_url="https://$DOWNLOAD_SERVER$(curl -m 10 -fsSL "https://$DOWNLOAD_SERVER$DOWNLOAD_INDEX_PATH" | grep "$DOWNLOAD_DISTRO" | cut -f 6 -d ';')rootfs.tar.xz"
    [[ "$rootfs_url" != "https://${DOWNLOAD_SERVER}rootfs.tar.xz" ]] || die "Failed to resolve rootfs download URL."

    run_as_root rm -rf "$work_dir"
    mkdir -p "$rootfs_dir"
    mkdir -p "$rootfs_dir/tmp"

    log "Downloading rootfs from $rootfs_url"
    curl -L -o "$rootfs_tarball" "$rootfs_url"
    tar -xf "$rootfs_tarball" -C "$rootfs_dir"
    rm -f "$rootfs_tarball"
    mkdir -p "$rootfs_dir/proc" "$rootfs_dir/dev/pts" "$rootfs_dir/sys"

    write_chroot_script "$chroot_script"
    image_packages=("$ARTIFACTS_DIR"/linux-image-*.deb)
    latest_image_package="$(printf '%s\n' "${image_packages[@]}" | sort -V | tail -n 1)"
    cp "$latest_image_package" "$rootfs_dir/tmp/"
    rm -rf "$rootfs_dir/etc/resolv.conf"
    cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
    log "Installing kernel package into rootfs and generating initramfs"
    run_rootfs_script "$rootfs_dir"

    cp "$rootfs_dir"/boot/vmlinuz* "$image_gz"
    cp "$rootfs_dir"/boot/initrd.img* "$ramdisk_path"
    find "$rootfs_dir/usr/lib" -path '*/qcom/*ufi003*.dtb' -type f -exec cp -f -t "$work_dir" {} +

    build_boot_image_variant "$image_gz" "$work_dir/$DTB_FILE" "$ramdisk_path" "$ARTIFACTS_DIR/boot.img" "$kernel_dtb_path"
    build_boot_image_variant "$image_gz" "$work_dir/$DTB_FILE_NO_MODEM" "$ramdisk_path" "$ARTIFACTS_DIR/boot-no-modem.img" "$kernel_dtb_path"
    build_boot_image_variant "$image_gz" "$work_dir/$DTB_FILE_NO_MODEM_OC" "$ramdisk_path" "$ARTIFACTS_DIR/boot-no-modem-oc.img" "$kernel_dtb_path"

    if ! compgen -G "$ARTIFACTS_DIR/boot*.img" >/dev/null; then
        die "Boot images were not produced. Check the script output above."
    fi

    log "Boot images are ready in $ARTIFACTS_DIR"
}

clean_artifacts() {
    log "Removing build artifacts and temporary files"

    run_as_root rm -rf "$ROOT_DIR/.bootimg-work"
    run_as_root rm -rf "$ARTIFACTS_DIR"
    run_as_root rm -rf "$ROOT_DIR/linux.tar.gz"

    find "$ROOT_DIR/.." -maxdepth 1 -type f \( \
        -name 'linux-image-*.deb' -o \
        -name 'linux-headers-*.deb' -o \
        -name 'linux-libc-dev_*.deb' -o \
        -name 'linux-image-*.changes' -o \
        -name 'linux-headers-*.changes' -o \
        -name 'linux-libc-dev_*.changes' -o \
        -name 'linux-*.buildinfo' -o \
        -name 'linux-*.tar.gz' -o \
        -name 'linux-*.dsc' -o \
        -name 'linux-*.debian.tar.gz' -o \
        -name 'linux-*.orig.tar.gz' \) \
        -delete

    ensure_debian13
    require_command make
    make clean
    make mrproper

    log "Cleanup completed"
}

main() {
    local mode="${1:-all}"

    case "$mode" in
        kernel)
            build_kernel
            ;;
        bootimg)
            build_bootimg
            ;;
        all)
            build_kernel
            build_bootimg
            ;;
        clean)
            clean_artifacts
            ;;
        deps)
            print_deps
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            die "Unknown command: $mode"
            ;;
    esac
}

main "$@"
