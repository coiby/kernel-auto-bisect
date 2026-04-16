# Optional KERNEL_RPM_LIST Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KERNEL_RPM_LIST optional by auto-detecting distro/arch from BAD_COMMIT, using shipped NVR lists to construct RPM URLs at runtime, with opt-in fresh generation via GENERATE_RPM_LIST=yes.

**Architecture:** New helper functions in lib.sh (parse_nvr_distro, parse_nvr_arch, nvr_to_rpm_url, resolve_rpm_list) auto-generate KERNEL_RPM_LIST from shipped NVR list files in rpm_lists/. The resolve_rpm_list function runs early in initialize(), before resolve_install_strategy(), so KERNEL_RPM_LIST is set before strategy detection. Generator scripts are extended with --nvr flag and arch parameter for opt-in fresh list generation.

**Tech Stack:** Bash (lib.sh, ShellSpec tests), Python (generator scripts), Make

**Spec:** `docs/superpowers/specs/2026-04-11-optional-kernel-rpm-list-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lib.sh` | Modify | Add parse_nvr_distro, parse_nvr_arch, nvr_to_rpm_url, resolve_rpm_list; integrate into initialize() |
| `spec/resolve_rpm_list_spec.sh` | Create | ShellSpec unit tests for all new helpers |
| `tools/generate_fedora_kernel_rpm_list.py` | Modify | Add --nvr flag and arch parameter |
| `tools/generate_rhel_kernel_rpm_list.py` | Modify | Add --nvr flag |
| `rpm_lists/c9s.list` | Create | Shipped CentOS Stream 9 NVR list |
| `rpm_lists/c10s.list` | Create | Shipped CentOS Stream 10 NVR list |
| `rpm_lists/fedora.list` | Create | Shipped Fedora NVR list |
| `Makefile` | Modify | Add update-rpm-lists target, update install target |
| `bisect.conf` | Modify | Comment out KERNEL_RPM_LIST, add GENERATE_RPM_LIST |
| `README.md` | Modify | Document optional KERNEL_RPM_LIST, GENERATE_RPM_LIST, make update-rpm-lists |

---

### Task 1: NVR Parsing Helpers

**Files:**
- Create: `spec/resolve_rpm_list_spec.sh`
- Modify: `lib.sh` (add after `nvr_to_tag` function, ~line 225)

- [ ] **Step 1: Write failing tests for parse_nvr_distro and parse_nvr_arch**

Create `spec/resolve_rpm_list_spec.sh`:

```bash
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
End
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: FAIL — `parse_nvr_distro` and `parse_nvr_arch` not defined

- [ ] **Step 3: Implement parse_nvr_distro and parse_nvr_arch**

In `lib.sh`, add after the `nvr_to_tag()` function (after line 225):

```bash
# Extract distro identifier from NVR for RPM list lookup
# e.g., "6.12.0-200.el10.x86_64" -> "c10s"
parse_nvr_distro() {
	local nvr=$1
	if [[ "$nvr" =~ \.el9[.] ]] || [[ "$nvr" =~ \.el9$ ]]; then
		echo "c9s"
	elif [[ "$nvr" =~ \.el10[.] ]] || [[ "$nvr" =~ \.el10$ ]]; then
		echo "c10s"
	elif [[ "$nvr" =~ \.fc[0-9]+ ]]; then
		echo "fedora"
	else
		return 1
	fi
}

# Extract architecture from NVR (last dot-separated component)
# e.g., "6.12.0-200.el10.x86_64" -> "x86_64"
parse_nvr_arch() {
	echo "${1##*.}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: All tests PASS

- [ ] **Step 5: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add spec/resolve_rpm_list_spec.sh lib.sh
git commit -m "Add parse_nvr_distro and parse_nvr_arch helpers"
```

---

### Task 2: URL Construction Helper

**Files:**
- Modify: `spec/resolve_rpm_list_spec.sh` (append inside `Describe 'resolve_rpm_list helpers'`)
- Modify: `lib.sh` (add after `parse_nvr_arch`)

- [ ] **Step 1: Write failing tests for nvr_to_rpm_url**

Append to `spec/resolve_rpm_list_spec.sh`, inside the `Describe 'resolve_rpm_list helpers'` block (before the final `End`):

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: FAIL — `nvr_to_rpm_url` not defined

- [ ] **Step 3: Implement nvr_to_rpm_url**

In `lib.sh`, add after `parse_nvr_arch()`:

```bash
# Construct full kernel-core RPM URL from NVR and arch
# e.g., nvr_to_rpm_url "6.12.0-30.el10" "x86_64" ->
#   https://kojihub.stream.centos.org/kojifiles/packages/kernel/6.12.0/30.el10/x86_64/kernel-core-6.12.0-30.el10.x86_64.rpm
nvr_to_rpm_url() {
	local nvr=$1 arch=$2
	local base_url version release

	version="${nvr%%-*}"
	release="${nvr#*-}"

	if [[ "$nvr" =~ \.el[0-9]+ ]]; then
		base_url="https://kojihub.stream.centos.org/kojifiles/packages/kernel"
	elif [[ "$nvr" =~ \.fc[0-9]+ ]]; then
		base_url="https://kojipkgs.fedoraproject.org/packages/kernel"
	else
		return 1
	fi

	echo "${base_url}/${version}/${release}/${arch}/kernel-core-${nvr}.${arch}.rpm"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: All tests PASS

- [ ] **Step 5: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add spec/resolve_rpm_list_spec.sh lib.sh
git commit -m "Add nvr_to_rpm_url helper for URL construction"
```

---

### Task 3: resolve_rpm_list Function

**Files:**
- Modify: `spec/resolve_rpm_list_spec.sh` (append inside `Describe 'resolve_rpm_list helpers'`)
- Modify: `lib.sh` (add after `nvr_to_rpm_url`)

- [ ] **Step 1: Write failing tests for resolve_rpm_list**

Append to `spec/resolve_rpm_list_spec.sh`, inside the `Describe 'resolve_rpm_list helpers'` block (before the final `End`):

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: FAIL — `resolve_rpm_list` not defined

- [ ] **Step 3: Implement resolve_rpm_list**

In `lib.sh`, add after `nvr_to_rpm_url()`:

```bash
# Auto-generate KERNEL_RPM_LIST from shipped NVR lists or generator scripts.
# Called when KERNEL_RPM_LIST is not set and BAD_COMMIT is an NVR.
resolve_rpm_list() {
	[[ -n "$KERNEL_RPM_LIST" ]] && return 0
	[[ "$INSTALL_STRATEGY" == "git" ]] && return 0
	is_nvr "$BAD_COMMIT" || return 0

	local distro arch url_file

	distro=$(parse_nvr_distro "$BAD_COMMIT") || do_abort "Cannot detect distro from BAD_COMMIT: $BAD_COMMIT"
	arch=$(parse_nvr_arch "$BAD_COMMIT")
	url_file="$WORK_DIR/kernel_rpm_list.txt"

	if [[ "$GENERATE_RPM_LIST" == "yes" ]]; then
		local generator_script generator_args
		case "$distro" in
		c9s)
			generator_script="$BIN_DIR/tools/generate_rhel_kernel_rpm_list.py"
			generator_args=(C9S "$arch")
			;;
		c10s)
			generator_script="$BIN_DIR/tools/generate_rhel_kernel_rpm_list.py"
			generator_args=(C10S "$arch")
			;;
		fedora)
			generator_script="$BIN_DIR/tools/generate_fedora_kernel_rpm_list.py"
			generator_args=("$arch")
			;;
		esac

		if ! command -v python3 &>/dev/null; then
			do_abort "GENERATE_RPM_LIST=yes requires python3"
		fi

		local nvr_output
		if ! nvr_output=$(python3 "$generator_script" --nvr "${generator_args[@]}"); then
			do_abort "Failed to generate RPM list with $generator_script"
		fi

		>"$url_file"
		while IFS= read -r nvr; do
			[[ -z "$nvr" ]] && continue
			nvr_to_rpm_url "$nvr" "$arch" >>"$url_file"
		done <<<"$nvr_output"
	else
		local nvr_list_file="$BIN_DIR/rpm_lists/${distro}.list"
		if [[ ! -f "$nvr_list_file" ]]; then
			do_abort "Shipped RPM list not found: $nvr_list_file. Set KERNEL_RPM_LIST or use GENERATE_RPM_LIST=yes."
		fi

		>"$url_file"
		while IFS= read -r nvr; do
			[[ -z "$nvr" ]] && continue
			nvr_to_rpm_url "$nvr" "$arch" >>"$url_file"
		done <"$nvr_list_file"
	fi

	KERNEL_RPM_LIST="$url_file"
	log "Auto-generated KERNEL_RPM_LIST from ${distro} NVR list for ${arch}: $KERNEL_RPM_LIST"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellspec spec/resolve_rpm_list_spec.sh`
Expected: All tests PASS

- [ ] **Step 5: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add spec/resolve_rpm_list_spec.sh lib.sh
git commit -m "Add resolve_rpm_list for auto-generating KERNEL_RPM_LIST"
```

---

### Task 4: Generator Script Changes

**Files:**
- Modify: `tools/generate_fedora_kernel_rpm_list.py`
- Modify: `tools/generate_rhel_kernel_rpm_list.py`

- [ ] **Step 1: Add --nvr flag and arch parameter to Fedora generator**

In `tools/generate_fedora_kernel_rpm_list.py`, add after the existing imports (after line 6):

```python
nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

arch = sys.argv[1] if len(sys.argv) > 1 else "x86_64"
```

This requires adding `import sys` to the imports. The full import block becomes:

```python
import re
import sys
from bs4 import BeautifulSoup
from packaging.version import Version
import os
import urllib.request
```

Then replace the print statement at the end (line 42-43) from:

```python
            url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/x86_64/kernel-core-{release_version}.x86_64.rpm'
            print(url)
```

to:

```python
            if nvr_mode:
                print(release_version)
            else:
                url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
                print(url)
```

- [ ] **Step 2: Add --nvr flag to RHEL generator**

In `tools/generate_rhel_kernel_rpm_list.py`, add after the existing imports (after line 8):

```python
nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")
```

Then replace the print statement at the end (line 53) from:

```python
    url = f'{base_url}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
    print(url)
```

to:

```python
    if nvr_mode:
        print(release_version)
    else:
        url = f'{base_url}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
        print(url)
```

- [ ] **Step 3: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add tools/generate_fedora_kernel_rpm_list.py tools/generate_rhel_kernel_rpm_list.py
git commit -m "Add --nvr flag and arch parameter to RPM list generators"
```

---

### Task 5: Ship NVR Lists

**Files:**
- Create: `rpm_lists/c9s.list`
- Create: `rpm_lists/c10s.list`
- Create: `rpm_lists/fedora.list`

- [ ] **Step 1: Generate NVR lists using the updated generators**

```bash
mkdir -p rpm_lists
python3 tools/generate_rhel_kernel_rpm_list.py --nvr C9S x86_64 > rpm_lists/c9s.list
python3 tools/generate_rhel_kernel_rpm_list.py --nvr C10S x86_64 > rpm_lists/c10s.list
python3 tools/generate_fedora_kernel_rpm_list.py --nvr > rpm_lists/fedora.list
```

- [ ] **Step 2: Verify list contents**

```bash
head -3 rpm_lists/c10s.list
tail -3 rpm_lists/c10s.list
wc -l rpm_lists/*.list
```

Expected: NVRs like `6.12.0-30.el10` (no URLs, no arch), reasonable line
counts matching the existing `c10s_nvrs/url_list` (~158 lines for c10s).

- [ ] **Step 3: Commit**

```bash
git add rpm_lists/
git commit -m "Ship NVR lists for c9s, c10s, and fedora"
```

---

### Task 6: Integrate resolve_rpm_list into initialize()

**Files:**
- Modify: `lib.sh:409` (initialize function)

- [ ] **Step 1: Add resolve_rpm_list call to initialize()**

In `lib.sh`, in the `initialize()` function, add `resolve_rpm_list` after
`mkdir -p "$WORK_DIR"` (line 409) and before `resolve_install_strategy`
(line 411). The block changes from:

```bash
	mkdir -p "$WORK_DIR"

	resolve_install_strategy
```

to:

```bash
	mkdir -p "$WORK_DIR"

	resolve_rpm_list

	resolve_install_strategy
```

- [ ] **Step 2: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add lib.sh
git commit -m "Integrate resolve_rpm_list into initialize()"
```

---

### Task 7: Makefile Updates

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Update .PHONY, add variables, update help, add update-rpm-lists, update install**

In `Makefile`, change the `.PHONY` line (line 17) from:

```makefile
.PHONY: all install uninstall clean help
```

to:

```makefile
.PHONY: all install uninstall clean help update-rpm-lists
```

Add after the `HANDLER_SRCS` variable (after line 15):

```makefile
RPM_LIST_DIR := rpm_lists
RPM_LIST_DIR_TARGET := $(BIN_DIR)/rpm_lists
```

Add to the `help` target output, after the `uninstall` line:

```makefile
	@echo "  update-rpm-lists  Refresh shipped NVR lists from upstream repos (requires python3)."
```

Add the `update-rpm-lists` target before the `install` target:

```makefile
update-rpm-lists:
	python3 tools/generate_rhel_kernel_rpm_list.py --nvr C9S x86_64 > $(RPM_LIST_DIR)/c9s.list
	python3 tools/generate_rhel_kernel_rpm_list.py --nvr C10S x86_64 > $(RPM_LIST_DIR)/c10s.list
	python3 tools/generate_fedora_kernel_rpm_list.py --nvr > $(RPM_LIST_DIR)/fedora.list
```

In the `install` target, after copying handler scripts (after the `chmod +x`
line for handlers, line 71), add:

```makefile
	@echo "Copying RPM NVR lists to $(RPM_LIST_DIR_TARGET)/"
	@mkdir -p $(RPM_LIST_DIR_TARGET)
	@cp $(RPM_LIST_DIR)/*.list $(RPM_LIST_DIR_TARGET)/
```

- [ ] **Step 2: Verify Makefile**

Run: `make help`
Expected: Shows `update-rpm-lists` in the target list

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "Add update-rpm-lists target and install rpm_lists/"
```

---

### Task 8: Config and Documentation Updates

**Files:**
- Modify: `bisect.conf`
- Modify: `README.md`

- [ ] **Step 1: Update bisect.conf**

Change the `KERNEL_RPM_LIST` line (line 40) from:

```bash
KERNEL_RPM_LIST="/path/to/your/kernel_rpm_list.txt"
```

to:

```bash
# KERNEL_RPM_LIST is optional. When omitted, the tool auto-selects a shipped
# NVR list based on BAD_COMMIT's dist tag and constructs RPM URLs at runtime.
# Set this to override with your own list of kernel RPM URLs (one per line).
#KERNEL_RPM_LIST="/path/to/your/kernel_rpm_list.txt"
```

Add after the `RPM_CACHE_DIR` line (after line 41):

```bash

# GENERATE_RPM_LIST: Set to "yes" to generate a fresh NVR list at runtime
# using the Python scripts in tools/ instead of the shipped static lists.
# Requires python3 with beautifulsoup4 and packaging modules.
#GENERATE_RPM_LIST="yes"
```

- [ ] **Step 2: Update README.md RPM Mode table**

Change the `KERNEL_RPM_LIST` row (line 89) from:

```markdown
| `KERNEL_RPM_LIST` | Path to a file listing kernel RPM URLs, one per line (ordered from good to bad) |
```

to:

```markdown
| `KERNEL_RPM_LIST` | Path to a file listing kernel RPM URLs, one per line (ordered from good to bad). Optional — when omitted, auto-selected from shipped NVR lists based on `BAD_COMMIT`. |
```

- [ ] **Step 3: Add GENERATE_RPM_LIST to Other Options table in README.md**

In the Other Options table (after line 106), add a new row:

```markdown
| `GENERATE_RPM_LIST` | Set to `yes` to generate a fresh RPM list at runtime using Python scripts instead of shipped lists |
```

- [ ] **Step 4: Add RPM Lists section to README.md**

After the "Installation (optional for remote mode)" section (after line 60),
add:

```markdown
## RPM Lists

The tool ships pre-built NVR lists in `rpm_lists/` for CentOS Stream 9,
CentOS Stream 10, and Fedora. When `KERNEL_RPM_LIST` is not set, the tool
auto-detects the distro and architecture from `BAD_COMMIT` and uses the
appropriate shipped list to construct RPM URLs at runtime.

To generate a fresh RPM list at runtime (requires `python3`,
`beautifulsoup4`, `packaging`), set in `bisect.conf`:

```
GENERATE_RPM_LIST="yes"
```

To refresh the shipped lists (maintainer use):

```bash
make update-rpm-lists
```
```

- [ ] **Step 5: Run full checks**

Run: `make format-check static-analysis unit-tests`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add bisect.conf README.md
git commit -m "Document optional KERNEL_RPM_LIST and GENERATE_RPM_LIST"
```
