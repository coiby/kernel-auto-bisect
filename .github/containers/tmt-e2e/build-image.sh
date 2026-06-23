#!/usr/bin/env bash
set -euo pipefail

export LIBGUESTFS_BACKEND=${LIBGUESTFS_BACKEND:-direct}

fedora_release=${FEDORA_RELEASE:-43}
arch=${ARCH:-x86_64}
image_dir=${KAB_IMAGE_DIR:-/opt/kab/images}
rpm_cache_dir=/tmp/kdump-bisect-rpms
package_cache_dir=${rpm_cache_dir}/packages
raw_image=${image_dir}/fedora-${fedora_release}-cloud.${arch}.qcow2
custom_image=${image_dir}/fedora-${fedora_release}-kab.${arch}.qcow2
cloud_index="https://download.fedoraproject.org/pub/fedora/linux/releases/${fedora_release}/Cloud/${arch}/images/"
image_packages=(
	make
	wget2-wget
	criu
	cronie
	kexec-tools
	kdump-utils
	rsync
	openssh-clients
	git
	grubby
)

mkdir -p "${image_dir}" "${rpm_cache_dir}" "${package_cache_dir}"

if [[ -z "${FEDORA_CLOUD_IMAGE_URL:-}" ]]; then
	image_name=$(
		curl -fsSL --retry 5 "${cloud_index}" |
			grep -Eo "Fedora-Cloud-Base-Generic-${fedora_release}-[0-9.]+\\.${arch}\\.qcow2" |
			sort -V |
			tail -n 1
	)
	FEDORA_CLOUD_IMAGE_URL="${cloud_index}${image_name}"
fi

curl -fL --retry 5 --retry-delay 5 -o "${raw_image}" "${FEDORA_CLOUD_IMAGE_URL}"

for version in 6.16.4 6.16.5 6.16.6 6.16.7; do
	release="${version}-100.fc41.${arch}"
	base_url="https://kojipkgs.fedoraproject.org/packages/kernel/${version}/100.fc41/${arch}"
	for pkg in core modules modules-core modules-extra; do
		curl -fL --retry 5 --retry-delay 5 \
			-o "${rpm_cache_dir}/kernel-${pkg}-${release}.rpm" \
			"${base_url}/kernel-${pkg}-${release}.rpm"
	done
done

dnf download -y --resolve --alldeps --destdir "${package_cache_dir}" "${image_packages[@]}"

cp "${raw_image}" "${custom_image}"

virt-customize -a "${custom_image}" \
	--mkdir /var/cache/kdump-bisect-rpms \
	--copy-in "${rpm_cache_dir}":/var/cache \
	--run-command 'dnf -y --disablerepo="*" install /var/cache/kdump-bisect-rpms/packages/*.rpm' \
	--run-command 'dnf clean all'

rm -f "${raw_image}"
rm -rf "${rpm_cache_dir}"
