#!/bin/bash
#
# install_handler.sh: Contains strategies for installing kernels.
#

run_install_strategy() {
	local commit_to_install=$1
	log "--- Phase: INSTALL ---"

	local kernel_version_string
	case "$INSTALL_STRATEGY" in
	git) install_from_git "$commit_to_install" ;;
	rpm) install_from_rpm "$commit_to_install" ;;
	*) do_abort "Unknown INSTALL_STRATEGY: ${INSTALL_STRATEGY}" ;;
	esac

	kernel_version_string="$TESTED_KERNEL"
	local new_kernel_path="/boot/vmlinuz-${kernel_version_string}"
	if [ ! -f "$new_kernel_path" ]; then do_abort "Installed kernel not found at ${new_kernel_path}."; fi

	set_boot_kernel "$new_kernel_path"
}

_openssl_engine_workaround() {
	for _branch in master main; do
		if git rev-parse --verify master &>/dev/null; then
			MAIN_BRANCH=$_branch
			break
		fi
	done

	[[ -z $MAIN_BRANCH ]] && do_abort "No master or main branch exist"

	git show $MAIN_BRANCH:scripts/sign-file.c >scripts/sign-file.c
	git show $MAIN_BRANCH:certs/extract-cert.c >certs/extract-cert.c
	git show $MAIN_BRANCH:scripts/ssl-common.h >scripts/ssl-common.h
	cp scripts/ssl-common.h certs/
}

_undo_openssl_engine_workaround() {
	git checkout -- scripts/sign-file.c
	git checkout -- certs/extract-cert.c
	if ! git checkout -- scripts/ssl-common.h &>/dev/null; then
		rm -f scripts/ssl-common.h
	fi
	rm -f certs/ssl-common.h
}

install_from_git() {
	local commit_to_install=$1
	log "Strategy: install_from_git for commit ${commit_to_install}"

	yes '' | make localmodconfig
	sed -i "/rhel.pem/d" .config

	# To avoid builidng bloated kernel image and modules, disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT to auto-disable CONFIG_DEBUG_INFO
	./scripts/config -d DEBUG_INFO_BTF
	./scripts/config -d DEBUG_INFO_BTF_MODULES
	./scripts/config -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

	ORIGINAL_KERNEL_CONFIG=${ORIGINAL_KERNEL/vmlinuz/config}

	# Enable loop, quashfs, overlay and erofs
	grep -e BLK_DEV_LOOP -e SQUASHFS -e OVERLAY -e EROFS_FS "$ORIGINAL_KERNEL_CONFIG" >>.config

	if grep -qs "^nfs" /etc/kdump.conf; then
		/usr/bin/grep NFS $ORIGINAL_KERNEL_CONFIG >>.config
	fi

	_commit_short_id=$(git rev-parse --short "$commit_to_install")
	_openssl_engine_workaround
	./scripts/config --set-str CONFIG_LOCALVERSION "-${_commit_short_id}"
	if ! yes $'\n' | make KCFLAGS="-Wno-error=calloc-transposed-args" -j"${MAKE_JOBS}" >"/var/log/build.log" 2>&1; then do_abort "Build failed."; fi
	if ! _module_install_output=$(make modules_install -j); then
		_undo_openssl_engine_workaround
		do_abort "Install failed."
	fi
	echo "$_module_install_output" >>"/var/log/build.log"
	if ! make install >>"/var/log/build.log" 2>&1; then
		_undo_openssl_engine_workaround
		do_abort "Install failed."
	fi
	_undo_openssl_engine_workaround
	_kernelrelease_str=$(make -s kernelrelease)
	_dirty_str=-dirty
	grep -qe "$_dirty_str$" <<<"$_module_install_output" && ! grep -qe "$_dirty_str$" <<<"$_kernelrelease_str" && _kernelrelease_str+=$_dirty_str
	TESTED_KERNEL="$_kernelrelease_str"
}

install_from_rpm() {
	local commit_to_install=$1
	log "Strategy: install_from_rpm for commit ${commit_to_install}"

	safe_cd "$GIT_REPO"
	# No need for bisect but needed for verifying initial good/bad commit
	git checkout -q "$commit_to_install"

	if ! command -v wget; then
		run_cmd dnf install wget -yq
	fi

	local core_url=$(cat k_url)
	local base_url=$(dirname "$core_url")
	local release=$(cat k_rel)
	local arch=$(echo "$core_url" | rev | cut -d. -f2 | rev)
	local rpm_cache_dir="$RPM_CACHE_DIR"
	mkdir -p "$rpm_cache_dir"
	local rpms_to_install=()

	for pkg in kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel; do
		local rpm_filename="${pkg}-${release}.rpm"
		local rpm_path="${rpm_cache_dir}/${rpm_filename}"
		local rpm_url="${base_url}/${rpm_filename}"
		if [ ! -f "$rpm_path" ]; then
			log "Downloading ${rpm_filename}..."
			if ! run_cmd wget --no-check-certificate -q -O "$rpm_path" "$rpm_url"; then
				rm -f "$rpm_path"
				log "Download failed. Ignore the error"
			else
				rpms_to_install+=("$rpm_path")
			fi
		else
			rpms_to_install+=("$rpm_path")
		fi
	done

	if ! run_cmd dnf install -y "${rpms_to_install[@]}" >"/var/log/install.log" 2>&1; then do_abort "RPM install failed."; fi
	TESTED_KERNEL="$release"
}
