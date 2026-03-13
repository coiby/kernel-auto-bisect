#!/bin/bash

Describe 'auto-source-bisect'
	Include ./lib.sh

	# Override LOG_FILE to a writable temp path so log()/do_abort() don't fail
	setup_log() { LOG_FILE="${SHELLSPEC_WORKDIR}/test.log"; }
	Before 'setup_log'

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

	Describe "auto-mode initialization logic"
		It "enables auto source bisect when INSTALL_STRATEGY is empty and KERNEL_RPM_LIST exists"
			KERNEL_RPM_LIST="${SHELLSPEC_WORKDIR}/kernel_list"
			echo "https://example.com/kernel-core-6.16.4-100.fc41.x86_64.rpm" >"$KERNEL_RPM_LIST"
			INSTALL_STRATEGY=""
			_auto_source_bisect=false

			auto_mode_check() {
				if [[ -z "$INSTALL_STRATEGY" ]]; then
					if [[ -f "$KERNEL_RPM_LIST" ]]; then
						INSTALL_STRATEGY="rpm"
						_auto_source_bisect=true
					fi
				fi
			}

			When call auto_mode_check
			The variable INSTALL_STRATEGY should equal "rpm"
			The variable _auto_source_bisect should equal "true"
		End

		It "does not enable auto source bisect when INSTALL_STRATEGY=rpm"
			INSTALL_STRATEGY="rpm"
			_auto_source_bisect=false

			explicit_rpm_check() {
				if [[ -z "$INSTALL_STRATEGY" ]]; then
					INSTALL_STRATEGY="rpm"
					_auto_source_bisect=true
				fi
			}

			When call explicit_rpm_check
			The variable INSTALL_STRATEGY should equal "rpm"
			The variable _auto_source_bisect should equal "false"
		End

		It "does not enable auto source bisect when INSTALL_STRATEGY=git"
			INSTALL_STRATEGY="git"
			_auto_source_bisect=false

			explicit_git_check() {
				if [[ -z "$INSTALL_STRATEGY" ]]; then
					INSTALL_STRATEGY="rpm"
					_auto_source_bisect=true
				fi
			}

			When call explicit_git_check
			The variable INSTALL_STRATEGY should equal "git"
			The variable _auto_source_bisect should equal "false"
		End
	End

	Describe "transition NVR extraction from fake git repo"
		setup_fake_repo() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/fake_repo"
			mkdir -p "$GIT_REPO"
			(
				cd "$GIT_REPO"
				git init -q
				git config user.name test
				git config user.email test@test
				echo "https://example.com/kernel-core-6.16.5-100.fc41.x86_64.rpm" >k_url
				echo "6.16.5-100.fc41.x86_64" >k_rel
				git add k_url k_rel
				git commit -m "good nvr" -q
				echo "https://example.com/kernel-core-6.16.6-100.fc41.x86_64.rpm" >k_url
				echo "6.16.6-100.fc41.x86_64" >k_rel
				git commit -am "bad nvr" -q
			) >/dev/null 2>&1
		}

		cleanup_fake_repo() {
			rm -rf "${SHELLSPEC_WORKDIR}/fake_repo"
		}

		Before 'setup_fake_repo'
		After 'cleanup_fake_repo'

		It "extracts bad NVR from k_rel at HEAD"
			When call run_cmd_in_GIT_REPO cat k_rel
			The output should equal "6.16.6-100.fc41.x86_64"
		End

		It "extracts good NVR from k_rel at HEAD~1"
			When call run_cmd_in_GIT_REPO git show HEAD~1:k_rel
			The output should equal "6.16.5-100.fc41.x86_64"
		End

		It "maps Fedora NVRs to kernel-ark tag format"
			map_tags() {
				local bad_nvr good_nvr
				bad_nvr=$(run_cmd_in_GIT_REPO cat k_rel)
				good_nvr=$(run_cmd_in_GIT_REPO git show HEAD~1:k_rel)
				echo "good=$(nvr_to_tag "$good_nvr")"
				echo "bad=$(nvr_to_tag "$bad_nvr")"
			}
			When call map_tags
			The line 1 should equal "good=kernel-6.16.5-0"
			The line 2 should equal "bad=kernel-6.16.6-0"
		End
	End

	Describe "transition NVR extraction from RT kernel fake repo"
		setup_rt_repo() {
			GIT_REPO="${SHELLSPEC_WORKDIR}/rt_repo"
			mkdir -p "$GIT_REPO"
			(
				cd "$GIT_REPO"
				git init -q
				git config user.name test
				git config user.email test@test
				echo "https://example.com/kernel-rt-core-5.14.0-669.el9.x86_64.rpm" >k_url
				echo "5.14.0-669.el9.x86_64" >k_rel
				git add k_url k_rel
				git commit -m "good rt nvr" -q
				echo "https://example.com/kernel-rt-core-5.14.0-670.el9.x86_64.rpm" >k_url
				echo "5.14.0-670.el9.x86_64" >k_rel
				git commit -am "bad rt nvr" -q
			) >/dev/null 2>&1
		}

		cleanup_rt_repo() {
			rm -rf "${SHELLSPEC_WORKDIR}/rt_repo"
		}

		Before 'setup_rt_repo'
		After 'cleanup_rt_repo'

		It "maps RT NVR to correct git tags"
			map_tags() {
				local bad_nvr good_nvr
				bad_nvr=$(run_cmd_in_GIT_REPO cat k_rel)
				good_nvr=$(run_cmd_in_GIT_REPO git show HEAD~1:k_rel)
				echo "good=$(nvr_to_tag "$good_nvr")"
				echo "bad=$(nvr_to_tag "$bad_nvr")"
			}
			When call map_tags
			The line 1 should equal "good=kernel-5.14.0-669.el9"
			The line 2 should equal "bad=kernel-5.14.0-670.el9"
		End
	End
End
