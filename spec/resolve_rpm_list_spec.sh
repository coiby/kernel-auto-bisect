#!/bin/bash

Describe 'resolve_rpm_list helpers'
	Include ./lib.sh

	setup_env() {
		LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"
	}
	Before 'setup_env'

	Describe 'parse_nvr_distro'
		It "detects c9s from el9 NVR"
			When call parse_nvr_distro "5.14.0-400.el9.x86_64"
			The output should equal "c9s"
			The status should be success
		End

		It "detects c10s from el10 NVR"
			When call parse_nvr_distro "6.12.0-200.el10.x86_64"
			The output should equal "c10s"
			The status should be success
		End

		It "detects fedora from fc41 NVR"
			When call parse_nvr_distro "6.16.5-100.fc41.x86_64"
			The output should equal "fedora"
			The status should be success
		End

		It "detects c9s from rt NVR"
			When call parse_nvr_distro "5.14.0-100.rt14.100.el9.x86_64"
			The output should equal "c9s"
			The status should be success
		End

		It "fails on unknown dist tag"
			When call parse_nvr_distro "5.14.0-100.unknown.x86_64"
			The status should be failure
		End

		It "fails on git commit hash"
			When call parse_nvr_distro "abc123def456789"
			The status should be failure
		End
	End

	Describe 'parse_nvr_arch'
		It "extracts x86_64"
			When call parse_nvr_arch "6.12.0-200.el10.x86_64"
			The output should equal "x86_64"
		End

		It "extracts aarch64"
			When call parse_nvr_arch "5.14.0-400.el9.aarch64"
			The output should equal "aarch64"
		End

		It "extracts s390x"
			When call parse_nvr_arch "6.12.0-100.el10.s390x"
			The output should equal "s390x"
		End

		It "extracts arch from rt NVR"
			When call parse_nvr_arch "5.14.0-100.rt14.100.el9.x86_64"
			The output should equal "x86_64"
		End
	End

	Describe 'nvr_to_rpm_url'
		It "constructs c10s URL for x86_64"
			When call nvr_to_rpm_url "6.12.0-30.el10" "x86_64"
			The output should equal \
				"https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0/30.el10/x86_64/kernel-core-6.12.0-30.el10.x86_64.rpm"
		End

		It "constructs c9s URL for aarch64"
			When call nvr_to_rpm_url "5.14.0-285.el9" "aarch64"
			The output should equal \
				"https://kojihub.stream.centos.org/kojifiles/packages/kernel/5.14.0/285.el9/aarch64/kernel-core-5.14.0-285.el9.aarch64.rpm"
		End

		It "constructs Fedora URL"
			When call nvr_to_rpm_url "6.16.5-100.fc41" "x86_64"
			The output should equal \
				"https://kojipkgs.fedoraproject.org/packages/kernel/6.16.5/100.fc41/x86_64/kernel-core-6.16.5-100.fc41.x86_64.rpm"
		End

		It "fails on unknown dist tag"
			When call nvr_to_rpm_url "6.12.0-100.unknown" "x86_64"
			The status should be failure
		End
	End

	Describe 'resolve_rpm_list'
		setup_rpm_env() {
			WORK_DIR="${SHELLSPEC_WORKDIR}/work"
			BIN_DIR="${SHELLSPEC_WORKDIR}/bin"
			mkdir -p "$WORK_DIR" "$BIN_DIR/rpm_lists"
			KERNEL_RPM_LIST=""
			INSTALL_STRATEGY=""
			GENERATE_RPM_LIST=""
			BAD_COMMIT=""
			# Create a mock shipped NVR list
			cat <<'EOF' >"$BIN_DIR/rpm_lists/c10s.list"
6.12.0-30.el10
6.12.0-31.el10
6.12.0-32.el10
EOF
		}

		cleanup_rpm_env() {
			rm -rf "${SHELLSPEC_WORKDIR}/work" "${SHELLSPEC_WORKDIR}/bin"
		}

		Before 'setup_rpm_env'
		After 'cleanup_rpm_env'

		# Suppress log output
		log() { :; }

		It "skips when KERNEL_RPM_LIST is already set"
			KERNEL_RPM_LIST="/existing/list.txt"
			BAD_COMMIT="6.12.0-200.el10.x86_64"
			When call resolve_rpm_list
			The variable KERNEL_RPM_LIST should equal "/existing/list.txt"
		End

		It "skips when INSTALL_STRATEGY is git"
			INSTALL_STRATEGY="git"
			BAD_COMMIT="6.12.0-200.el10.x86_64"
			When call resolve_rpm_list
			The variable KERNEL_RPM_LIST should equal ""
		End

		It "skips when BAD_COMMIT is not an NVR"
			BAD_COMMIT="abc123def456"
			When call resolve_rpm_list
			The variable KERNEL_RPM_LIST should equal ""
		End

		It "generates URL list from shipped NVR list"
			BAD_COMMIT="6.12.0-200.el10.x86_64"
			do_generate() {
				resolve_rpm_list
				echo "file=$KERNEL_RPM_LIST"
				head -1 "$KERNEL_RPM_LIST"
				tail -1 "$KERNEL_RPM_LIST"
			}
			When call do_generate
			The line 1 should equal "file=${WORK_DIR}/kernel_rpm_list.txt"
			The line 2 should equal \
				"https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0/30.el10/x86_64/kernel-core-6.12.0-30.el10.x86_64.rpm"
			The line 3 should equal \
				"https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0/32.el10/x86_64/kernel-core-6.12.0-32.el10.x86_64.rpm"
		End

		It "calls generator script when GENERATE_RPM_LIST=yes"
			BAD_COMMIT="6.12.0-200.el10.x86_64"
			GENERATE_RPM_LIST="yes"
			# Create mock generator script
			mkdir -p "$BIN_DIR/tools"
			cat <<'SCRIPT' >"$BIN_DIR/tools/generate_rhel_kernel_rpm_list.py"
#!/usr/bin/env python3
import sys
if "--nvr" in sys.argv:
    print("6.12.0-99.el10")
    print("6.12.0-100.el10")
SCRIPT
			chmod +x "$BIN_DIR/tools/generate_rhel_kernel_rpm_list.py"
			do_generate() {
				resolve_rpm_list
				head -1 "$KERNEL_RPM_LIST"
			}
			When call do_generate
			The output should equal \
				"https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0/99.el10/x86_64/kernel-core-6.12.0-99.el10.x86_64.rpm"
		End
	End
End
