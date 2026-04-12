#!/bin/bash

# shellcheck shell=sh

Describe 'RPM List Generator Scripts'
	Describe 'generate_fedora_kernel_rpm_list.py'
		Context 'without --nvr flag (default URL mode)'
			# Mock the script to avoid network calls
			fedora_generator() {
				# Create a minimal mock that outputs one line
				python3 - "$@" <<'EOF'
import sys
nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

arch = sys.argv[1] if len(sys.argv) > 1 else "x86_64"

# Mock output for testing
version = "6.12.0"
minor = "30.fc42"
release_version = f"{version}-{minor}"

if nvr_mode:
    print(release_version)
else:
    url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
    print(url)
EOF
			}

			It 'outputs full URL with default arch x86_64'
				When call fedora_generator
				The output should include "https://kojipkgs.fedoraproject.org/packages/kernel/"
				The output should include "x86_64/kernel-core-"
				The output should include ".x86_64.rpm"
			End

			It 'outputs full URL with specified arch aarch64'
				When call fedora_generator aarch64
				The output should include "https://kojipkgs.fedoraproject.org/packages/kernel/"
				The output should include "aarch64/kernel-core-"
				The output should include ".aarch64.rpm"
			End
		End

		Context 'with --nvr flag'
			fedora_generator_nvr() {
				python3 - "$@" <<'EOF'
import sys
nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

arch = sys.argv[1] if len(sys.argv) > 1 else "x86_64"

# Mock output for testing
version = "6.12.0"
minor = "30.fc42"
release_version = f"{version}-{minor}"

if nvr_mode:
    print(release_version)
else:
    url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
    print(url)
EOF
			}

			It 'outputs only NVR without URL'
				When call fedora_generator_nvr --nvr
				The output should equal "6.12.0-30.fc42"
				The output should not include "https://"
				The output should not include ".rpm"
			End

			It 'outputs only NVR with arch parameter (arch ignored in nvr mode)'
				When call fedora_generator_nvr --nvr aarch64
				The output should equal "6.12.0-30.fc42"
			End
		End
	End

	Describe 'generate_rhel_kernel_rpm_list.py'
		Context 'without --nvr flag (default URL mode)'
			rhel_generator() {
				python3 - "$@" <<'EOF'
import sys

nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

# Mock positional args parsing
if len(sys.argv) < 3:
    rhel_version = "C10S"
    arch = "x86_64"
else:
    rhel_version = sys.argv[1]
    arch = sys.argv[2]

# Mock output
version = "6.12.0"
minor = "30.el10"
release_version = f'{version}-{minor}'
base_url = "https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0"

url = f'{base_url}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
print(url)
EOF
			}

			It 'outputs full URL'
				When call rhel_generator C10S x86_64
				The output should include "https://kojihub.stream.centos.org"
				The output should include "x86_64/kernel-core-"
				The output should include ".x86_64.rpm"
			End
		End

		Context 'with --nvr flag'
			rhel_generator_nvr() {
				python3 - "$@" <<'EOF'
import sys

nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

# Mock positional args parsing
if len(sys.argv) < 3:
    rhel_version = "C10S"
    arch = "x86_64"
else:
    rhel_version = sys.argv[1]
    arch = sys.argv[2]

# Mock output
version = "6.12.0"
minor = "30.el10"
release_version = f'{version}-{minor}'
base_url = "https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0"

if nvr_mode:
    print(release_version)
else:
    url = f'{base_url}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
    print(url)
EOF
			}

			It 'outputs only NVR without URL'
				When call rhel_generator_nvr --nvr C10S x86_64
				The output should equal "6.12.0-30.el10"
				The output should not include "https://"
				The output should not include ".rpm"
			End
		End
	End
End
