#!/usr/bin/env python3
# -*- coding:utf-8 -*-

import re
from bs4 import BeautifulSoup
from packaging.version import Version
import os
import sys
import urllib.request

nvr_mode = "--nvr" in sys.argv
if nvr_mode:
    sys.argv.remove("--nvr")

arch = sys.argv[1] if len(sys.argv) > 1 else "x86_64"


def download(url, save_path):
    if os.path.exists(save_path):
        return
    urllib.request.urlretrieve(url, save_path)


def get_kernel_versions():
    url = "https://kojipkgs.fedoraproject.org/packages/kernel/"
    path = "index.html"
    download(url, path)
    with open(path, 'r') as f:
        versions = re.findall(r'href="(\d.\d+.\d+)', f.read())
        versions.sort(key=Version)
        return versions


for version in get_kernel_versions():
    if not os.path.exists(version):
        os.mkdir(version)
    path = version + "index.html"
    url = "https://kojipkgs.fedoraproject.org/packages/kernel/{}/".format(version)
    download(url, path)

    with open(path, 'r') as fp:
        soup = BeautifulSoup(fp, 'html.parser')
        elements = soup.find_all('a', {'href': True})
        txt = elements[-1].text[0:-1]
        if ".fc" in txt:
            minor = txt
            release_version = "{}-{}".format(version, minor)
            if nvr_mode:
                print(release_version)
            else:
                url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/{arch}/kernel-core-{release_version}.{arch}.rpm'
                print(url)
