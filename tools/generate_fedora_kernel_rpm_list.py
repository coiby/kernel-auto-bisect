#!/usr/bin/env python3
# -*- coding:utf-8 -*-

import re
from bs4 import BeautifulSoup
from packaging.version import Version
import os
import urllib.request


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
            url = f'https://kojipkgs.fedoraproject.org/packages/kernel/{version}/{minor}/x86_64/kernel-core-{release_version}.x86_64.rpm'
            print(url)
