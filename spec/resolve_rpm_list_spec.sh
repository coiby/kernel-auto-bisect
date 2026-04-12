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
End
