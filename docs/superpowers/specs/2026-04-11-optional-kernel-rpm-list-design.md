# Optional KERNEL_RPM_LIST with Auto-Detection

## Problem

Users must manually run a Python generator script and set `KERNEL_RPM_LIST` in
`bisect.conf` before starting an RPM bisect. This is tedious when the tool
could infer the RPM list from `BAD_COMMIT`.

## Solution

Make `KERNEL_RPM_LIST` optional. When omitted, the tool auto-detects the
distro and architecture from `BAD_COMMIT`'s NVR, selects a shipped NVR list,
constructs full RPM URLs at runtime, and writes them to
`$WORK_DIR/kernel_rpm_list.txt`. Users can opt into fresh list generation via
`GENERATE_RPM_LIST=yes`.

## Design

### 1. Shipped NVR Lists

A new `rpm_lists/` directory at the project root:

```
rpm_lists/
  c9s.list
  c10s.list
  fedora.list
```

Each `.list` file contains one NVR per line (e.g., `6.12.0-30.el10`), ordered
oldest to newest. These are committed to the repo and copied into
`$BIN_DIR/rpm_lists/` by `make install`.

### 2. NVR Parsing and Auto-Detection

A new function `resolve_rpm_list()` in `lib.sh`, called during `initialize()`
after `resolve_install_strategy()` but before the existing code that reads
`KERNEL_RPM_LIST` (i.e., before `generate_git_repo_from_package_list`). It
runs when `INSTALL_STRATEGY` is `rpm` (or auto mode) and `KERNEL_RPM_LIST` is
not set. It:

1. Parses `BAD_COMMIT` to extract distro and arch:
   - `6.12.0-200.el10.x86_64` -> distro=`c10s`, arch=`x86_64`
   - `5.14.0-400.el9.aarch64` -> distro=`c9s`, arch=`aarch64`
   - `6.16.5-100.fc41.x86_64` -> distro=`fedora`, arch=`x86_64`
2. Looks up the shipped NVR list at `$BIN_DIR/rpm_lists/<distro>.list`.
3. Constructs full URLs from each NVR + detected arch + base URL map, writes
   them to `$WORK_DIR/kernel_rpm_list.txt`.
4. Sets `KERNEL_RPM_LIST` to that generated file.

If `KERNEL_RPM_LIST` is already set by the user, this step is skipped entirely.

### 3. URL Construction

Base URL map by distro:

| Dist tag | Base URL |
|----------|----------|
| `.el9`   | `https://kojihub.stream.centos.org/kojifiles/packages/kernel` |
| `.el10`  | `https://kojihub.stream.centos.org/kojifiles/packages/kernel` |
| `.fc*`   | `https://kojipkgs.fedoraproject.org/packages/kernel` |

Each NVR (e.g., `6.12.0-30.el10`) is split into version (`6.12.0`) and
release (`30.el10`). The full URL is:

```
<base_url>/<version>/<release>/<arch>/kernel-core-<nvr>.<arch>.rpm
```

### 4. Opt-In Fresh Generation

A new config option `GENERATE_RPM_LIST` in `bisect.conf`. When set to `yes`:

1. `resolve_rpm_list()` skips the shipped static lists.
2. Detects which generator script to use from the distro tag:
   - `.el*` -> `tools/generate_rhel_kernel_rpm_list.py` (args: distro like
     `C9S`/`C10S`, arch)
   - `.fc*` -> `tools/generate_fedora_kernel_rpm_list.py` (args: arch)
3. Calls the generator with `--nvr` flag to produce NVR output.
4. Constructs URLs from the NVR output (same logic as shipped lists).
5. Saves to `$WORK_DIR/kernel_rpm_list.txt` and sets `KERNEL_RPM_LIST`.

If the Python script or its dependencies are missing, the tool aborts with a
clear error message.

### 5. Generator Script Changes

Both `tools/generate_fedora_kernel_rpm_list.py` and
`tools/generate_rhel_kernel_rpm_list.py` are extended:

- **`--nvr` flag**: Output NVRs instead of full URLs.
- **`generate_fedora_kernel_rpm_list.py`**: Accept an optional `arch` argument
  (default `x86_64` for backward compatibility).

### 6. Makefile Updates

- **`make update-rpm-lists`**: Runs the generator scripts with `--nvr` for
  each distro to refresh the shipped `.list` files in `rpm_lists/`.
- **`install` target**: Copies `rpm_lists/` into `$BIN_DIR/rpm_lists/`.

### 7. Config and Documentation

**`bisect.conf`:**
- `KERNEL_RPM_LIST` default changed to commented-out (clearly optional).
- New `GENERATE_RPM_LIST` option added (commented out).

**`README.md`:**
- RPM Mode table updated to note `KERNEL_RPM_LIST` is optional.
- `GENERATE_RPM_LIST=yes` documented.
- `make update-rpm-lists` documented for maintainers.

### 8. Testing

New ShellSpec unit tests:

- **NVR parsing**: Extracting distro and arch from various `BAD_COMMIT`
  formats (`.el9`, `.el10`, `.fc41`, different arches).
- **URL construction**: Given an NVR, distro, and arch, verify the correct
  full URL is built.
- **`resolve_rpm_list()`**: When `KERNEL_RPM_LIST` is unset, verify it picks
  the right shipped list and generates the URL file.
- **`resolve_rpm_list()` skip**: When `KERNEL_RPM_LIST` is already set,
  verify it is left untouched.
- **`GENERATE_RPM_LIST=yes`**: Verify it calls the generator script instead
  of using shipped lists (mocking the Python call).

Existing integration tests are unaffected (they all set `KERNEL_RPM_LIST`
explicitly).

## Scope

### In scope
- `resolve_rpm_list()` function in `lib.sh`
- NVR parsing and URL construction helpers in `lib.sh`
- `rpm_lists/` directory with shipped NVR lists
- `--nvr` flag and arch parameter for generator scripts
- `make update-rpm-lists` target
- `make install` update to copy `rpm_lists/`
- Config and docs updates
- ShellSpec unit tests

### Out of scope
- RHEL (non-CentOS-Stream) shipped lists (requires internal network access)
- Filtering RPM lists to good/bad range (existing git bisect handles this)
- Changes to integration tests
