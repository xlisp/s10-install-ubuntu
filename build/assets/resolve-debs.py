#!/usr/bin/env python3
"""Resolve a deb dependency closure for Ubuntu 26.04 (resolute) arm64 from TUNA
and download the .deb files. Seeds: systemd + udev + kmod + openssh-server etc.

ubuntu-base 26.04 no longer ships systemd, so we pre-download the init system
and flash it from TWRP via chroot+dpkg (no on-device network needed).
"""
import gzip
import os
import re
import subprocess
import sys
import urllib.request
from email.parser import Parser

MIRROR = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
DIST = "resolute"
COMPONENTS = ["main", "universe", "restricted", "multiverse"]
BASE_STATUS = "/tmp/ubx/var/lib/dpkg/status"  # extracted ubuntu-base dpkg db
OUT_DIR = "/Users/xlisp/PyPro/s10-install-ubuntu/build/flash/debs"

SEEDS = [
    "systemd",
    "systemd-sysv",      # provides /sbin/init
    "udev",
    "kmod",              # depmod/modprobe
    "openssh-server",
    "sudo",
    "netbase",
    "dbus",
    "iproute2",
    "locales",
    "console-setup",
    "adduser",
    "apt-utils",
    "software-properties-common",  # for do-release-upgrade / add-apt-repo later
]

field_re = re.compile(r"^([A-Za-z0-9-]+):\s*(.*)$")


def fetch(url: str, dest: str) -> str:
    dest = os.path.join("/tmp", dest)
    if not os.path.exists(dest):
        print(f"fetch {url}")
        subprocess.run(
            ["curl", "-fsSL", "--retry", "5", "--retry-delay", "2", "--max-time", "300", url, "-o", dest],
            check=True,
        )
    return dest


def load_index() -> dict:
    pkgs = {}
    for comp in COMPONENTS:
        url = f"{MIRROR}/dists/{DIST}/{comp}/binary-arm64/Packages.gz"
        path = fetch(url, f"Packages-{comp}.gz")
        data = gzip.open(path, "rt", errors="replace").read()
        for stanza in data.split("\n\n"):
            if not stanza.strip():
                continue
            msg = Parser().parsestr(stanza)
            name = msg.get("Package")
            if name and name not in pkgs:
                pkgs[name] = {k.lower(): v for k, v in msg.items()}
    print(f"index: {len(pkgs)} packages")
    return pkgs


def load_installed() -> set:
    installed = set()
    provides = set()
    with open(BASE_STATUS) as f:
        for stanza in f.read().split("\n\n"):
            if not stanza.strip():
                continue
            msg = Parser().parsestr(stanza)
            name = msg.get("Package")
            status = msg.get("Status", "")
            if name and "installed" in status:
                installed.add(name)
                for p in (msg.get("Provides") or "").split(","):
                    p = p.strip().split(" ")[0]
                    if p:
                        provides.add(p)
    print(f"installed in base: {len(installed)}")
    return installed | provides


def deps_of(pkg: dict) -> list:
    raw = (pkg.get("depends", "") + ", " + pkg.get("pre-depends", "")).strip(", ")
    out = []
    for clause in raw.split(","):
        clause = clause.strip()
        if not clause:
            continue
        alts = [a.strip() for a in clause.split("|")]
        out.append(alts)
    return out


def clean_name(alt: str) -> str:
    return re.sub(r"[\s(:\[<].*$", "", alt).strip()


def resolve(pkgs: dict, installed: set) -> set:
    todo = [s for s in SEEDS if s not in installed]
    resolved = set()
    while todo:
        name = todo.pop()
        if name in resolved or name in installed:
            continue
        if name not in pkgs:
            print(f"  WARN: {name} not in index (virtual?) — skipping")
            continue
        resolved.add(name)
        for alts in deps_of(pkgs[name]):
            picked = None
            for alt in alts:
                n = clean_name(alt)
                if n in installed:
                    picked = None  # satisfied by base
                    break
                if n in pkgs:
                    picked = n
                    # prefer first alternative; keep scanning only if missing
                    break
            if picked and picked not in resolved:
                todo.append(picked)
    return resolved


def main() -> None:
    pkgs = load_index()
    installed = load_installed()
    resolved = resolve(pkgs, installed)
    total = 0
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = []
    for name in sorted(resolved):
        info = pkgs[name]
        fn = os.path.basename(info["filename"])
        url = f"{MIRROR}/{info['filename']}"
        dest = os.path.join(OUT_DIR, fn)
        if not os.path.exists(dest):
            subprocess.run(["curl", "-sL", "--retry", "3", "--max-time", "300", url, "-o", dest], check=True)
        size = os.path.getsize(dest)
        total += size
        manifest.append(f"{fn}")
        print(f"  {name}: {fn} ({size // 1024} KB)")
    with open(os.path.join(OUT_DIR, "manifest.txt"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    print(f"\n{len(resolved)} debs, {total // 1024 // 1024} MB total -> {OUT_DIR}")


if __name__ == "__main__":
    sys.exit(main())
