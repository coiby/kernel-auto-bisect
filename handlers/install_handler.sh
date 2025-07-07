#!/bin/bash
#
# install_handler.sh: Contains strategies for installing kernels.
#

run_install_strategy() {
    local commit_to_install=$1
    log "--- Phase: INSTALL ---"
    
    local kernel_version_string
    case "$INSTALL_STRATEGY" in
        git)  kernel_version_string=$(install_from_git "$commit_to_install") ;;
        rpm)  kernel_version_string=$(install_from_rpm "$commit_to_install") ;;
        *)    do_abort "Unknown INSTALL_STRATEGY: ${INSTALL_STRATEGY}" ;;
    esac

    local new_kernel_path="/boot/vmlinuz-${kernel_version_string}"
    if [ ! -f "$new_kernel_path" ]; then do_abort "Installed kernel not found at ${new_kernel_path}."; fi
    
    echo "$kernel_version_string" > "$LAST_KERNEL_FILE"
    set_boot_kernel "$new_kernel_path"
}

_openssl_engine_workaround() {
    for _branch in master main; do
        if git rev-parse --verify master &> /dev/null; then
            MAIN_BRANCH=$_branch
            break
        fi
    done

    [[ -z $MAIN_BRANCH ]] && do_abort "No master or main branch exist"

    git show $MAIN_BRANCH:scripts/sign-file.c > scripts/sign-file.c
    git show $MAIN_BRANCH:certs/extract-cert.c > certs/extract-cert.c
    git show $MAIN_BRANCH:scripts/ssl-common.h > scripts/ssl-common.h
    cp scripts/ssl-common.h certs/
}

_undo_openssl_engine_workaround () {
    git checkout -- scripts/sign-file.c
    git checkout -- certs/extract-cert.c
    if ! git checkout -- scripts/ssl-common.h &> /dev/null; then
        rm -f scripts/ssl-common.h
    fi
    rm -f certs/ssl-common.h
}

install_from_git() {
    local commit_to_install=$1
    log "Strategy: install_from_git for commit ${commit_to_install}"
    cd "$KERNEL_SRC_DIR"; git checkout -q "$commit_to_install"

    modprobe squashfs
    modprobe loop
    modprobe overlay
    modprobe erofs &> /dev/null || :
    yes '' | make localmodconfig
    sed -i "/rhel.pem/d" .config

    # To avoid builidng bloated kernel image and modules, disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT to auto-disable CONFIG_DEBUG_INFO
    ./scripts/config -d DEBUG_INFO_BTF
    ./scripts/config -d DEBUG_INFO_BTF_MODULES
    ./scripts/config -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

    if grep -qs "^nfs" /etc/kdump.conf; then
        ORIGINAL_KERNEL_PATH=$(cat "$ORIGINAL_KERNEL")
        ORIGINAL_KERNEL_CONFIG=${ORIGINAL_KERNEL_PATH/vmlinuz/config}
        /usr/bin/grep NFS $ORIGINAL_KERNEL_CONFIG >> .config
    fi

    _commit_short_id=$(git rev-parse --short "$commit_to_install")
    openssl_engine_workaround
    ./scripts/config --set-str CONFIG_LOCALVERSION "-${_commit_short_id}"
    if ! yes $'\n' | make KCFLAGS="-Wno-error=calloc-transposed-args" -j"${MAKE_JOBS}" > "${STATE_DIR}/build.log" 2>&1; then do_abort "Build failed."; fi
    if ! make modules_install install >> "${STATE_DIR}/build.log" 2>&1; then _undo_openssl_engine_workaround; do_abort "Install failed."; fi
    _undo_openssl_engine_workaround
    echo "$(make -s kernelrelease)"
}

install_from_rpm() {
    local commit_to_install=$1
    log "Strategy: install_from_rpm for commit ${commit_to_install}"
    cd "$RPM_FAKE_REPO_PATH"; git checkout -q "$commit_to_install"
    
    local core_url=$(cat k_url); local base_url=$(dirname "$core_url")
    local release=$(cat k_rel); local arch=$(echo "$core_url" | rev | cut -d. -f2 | rev)
    local rpm_cache_dir="$RPM_CACHE_DIR"; mkdir -p "$rpm_cache_dir"
    local rpms_to_install=()
    
    for pkg in kernel-core kernel-modules kernel-modules-core kernel; do
        local rpm_filename="${pkg}-${release}.${arch}.rpm"
        local rpm_path="${rpm_cache_dir}/${rpm_filename}"
        local rpm_url="${base_url}/${rpm_filename}"
        if [ ! -f "$rpm_path" ]; then
            log "Downloading ${rpm_filename}..."; if ! wget -q -O "$rpm_path" "$rpm_url"; then rm -f "$rpm_path"; do_abort "Download failed."; fi
        fi
        rpms_to_install+=("$rpm_path")
    done
    
    if ! dnf install -y "${rpms_to_install[@]}" > "${STATE_DIR}/install.log" 2>&1; then do_abort "RPM install failed."; fi
    echo "$release"
}
