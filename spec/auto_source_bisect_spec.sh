#!/bin/bash

Describe 'auto-source-bisect'
	Include ./lib.sh

	# Override LOG_FILE to a writable temp path so log()/do_abort() don't fail
	setup_log() { LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"; }
	Before 'setup_log'

	Describe 'is_nvr'
		It "detects el9 NVR"
			When call is_nvr "5.14.0-284.el9.x86_64"
			The status should be success
		End

		It "detects el10 NVR"
			When call is_nvr "6.12.0-55.el10.aarch64"
			The status should be success
		End

		It "detects fc41 NVR"
			When call is_nvr "6.16.4-100.fc41.x86_64"
			The status should be success
		End

		It "rejects a git commit hash"
			When call is_nvr "abc123def456789"
			The status should be failure
		End

		It "rejects a full git commit hash"
			When call is_nvr "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
			The status should be failure
		End

		It "detects kernel-rt NVR"
			When call is_nvr "5.14.0-100.rt14.100.el9.x86_64"
			The status should be success
		End
	End

	Describe "nvr_to_tag"
		It "converts standard el9 NVR to kernel tag"
			When call nvr_to_tag "5.14.0-670.el9.x86_64"
			The output should equal "kernel-5.14.0-670.el9"
		End

		It "converts el9 aarch64 NVR to kernel tag"
			When call nvr_to_tag "5.14.0-670.el9.aarch64"
			The output should equal "kernel-5.14.0-670.el9"
		End

		It "converts el10 NVR to kernel tag"
			When call nvr_to_tag "6.12.0-55.el10.x86_64"
			The output should equal "kernel-6.12.0-55.el10"
		End

		It "converts fc41 NVR to kernel-ark tag format"
			When call nvr_to_tag "6.16.4-100.fc41.x86_64"
			The output should equal "kernel-6.16.4-0"
		End
	End

	Describe "detect_git_repo_url"
		setup_url() { GIT_REPO_URL=""; }
		Before 'setup_url'

		It "detects centos-stream-9 repo from el9 NVR"
			When call detect_git_repo_url "5.14.0-670.el9.x86_64"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-9.git"
		End

		It "detects centos-stream-9 repo from el9 NVR without arch"
			When call detect_git_repo_url "5.14.0-670.el9"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-9.git"
		End

		It "detects centos-stream-10 repo from el10 NVR"
			When call detect_git_repo_url "6.12.0-55.el10.x86_64"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git"
		End

		It "detects centos-stream-10 repo from el10 NVR without arch"
			When call detect_git_repo_url "6.12.0-55.el10"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git"
		End

		It "detects kernel-ark repo from fc41 NVR"
			When call detect_git_repo_url "6.16.4-100.fc41.x86_64"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/cki-project/kernel-ark.git"
		End

		It "detects kernel-ark repo from fc40 NVR"
			When call detect_git_repo_url "6.10.0-200.fc40.x86_64"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/cki-project/kernel-ark.git"
		End

		It "detects kernel-ark repo from fc NVR without arch"
			When call detect_git_repo_url "6.16.4-100.fc41"
			The status should be success
			The output should include "Auto-detected GIT_REPO_URL"
			The variable GIT_REPO_URL should equal \
				"https://gitlab.com/cki-project/kernel-ark.git"
		End

		It "preserves pre-configured GIT_REPO_URL"
			GIT_REPO_URL="https://example.com/my-repo.git"
			When call detect_git_repo_url "5.14.0-670.el9.x86_64"
			The status should be success
			The output should include "Using configured GIT_REPO_URL"
			The variable GIT_REPO_URL should equal "https://example.com/my-repo.git"
		End

		It "aborts on unknown dist tag"
			When run detect_git_repo_url "5.14.0-670.unknown.x86_64"
			The status should be failure
			The output should include "Cannot auto-detect"
		End
	End

	Describe 'resolve_install_strategy'
		setup_strategy_env() {
			LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"
			INSTALL_STRATEGY=""
			KERNEL_RPM_LIST=""
			GIT_REPO_URL=""
			GOOD_COMMIT=""
			BAD_COMMIT=""
			_auto_source_bisect=false
		}

		Before 'setup_strategy_env'

		It "keeps explicit rpm strategy"
			INSTALL_STRATEGY="rpm"
			When call resolve_install_strategy
			The variable INSTALL_STRATEGY should equal "rpm"
			The variable _auto_source_bisect should equal "false"
		End

		It "keeps explicit git strategy"
			INSTALL_STRATEGY="git"
			When call resolve_install_strategy
			The variable INSTALL_STRATEGY should equal "git"
			The variable _auto_source_bisect should equal "false"
		End

		It "auto-detects rpm+transition when KERNEL_RPM_LIST is set"
			KERNEL_RPM_LIST="/path/to/rpms.txt"
			GOOD_COMMIT="5.14.0-283.el9.x86_64"
			BAD_COMMIT="5.14.0-284.el9.x86_64"
			When call resolve_install_strategy
			The variable INSTALL_STRATEGY should equal "rpm"
			The variable _auto_source_bisect should equal "true"
		End

		It "auto-detects git when only GIT_REPO_URL with commit hashes"
			GIT_REPO_URL="https://gitlab.com/some/repo.git"
			GOOD_COMMIT="abc123"
			BAD_COMMIT="def456"
			When call resolve_install_strategy
			The variable INSTALL_STRATEGY should equal "git"
			The variable _auto_source_bisect should equal "false"
		End

		It "auto-detects rpm+transition when GIT_REPO_URL with NVRs"
			GIT_REPO_URL="https://gitlab.com/some/repo.git"
			GOOD_COMMIT="5.14.0-283.el9.x86_64"
			BAD_COMMIT="5.14.0-284.el9.x86_64"
			When call resolve_install_strategy
			The variable INSTALL_STRATEGY should equal "rpm"
			The variable _auto_source_bisect should equal "true"
		End
	End

End
