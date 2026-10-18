#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Package a built Girasol.app as a .deb for jailbroken iOS, with nothing but
Python: no dpkg-deb, no tar or ar binaries, no Theos (see Makefile `deb`).

A .deb is an ar archive of three members, in this order:
  debian-binary    "2.0\\n"
  control.tar.gz   ./control and the maintainer scripts
  data.tar.gz      the files, at their install paths (./Applications/…)
Both tarballs are GNU format (what every iOS dpkg reads, long names
included), owned by root, with sorted entries and one fixed time, so the
same build always gives the same bytes.
"""
import argparse
import gzip
import io
import os
import stat
import tarfile

AR_MAGIC = b"!<arch>\n"


def ar_member(name, data, mtime):
    """One ar member: a 60-byte header (name, time, uid, gid, mode, size,
    terminator), the data, and a newline pad to an even offset."""
    header = (
        f"{name:<16}{mtime:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}".encode("ascii")
        + b"`\n"
    )
    assert len(header) == 60
    return header + data + (b"\n" if len(data) % 2 else b"")


def tar_info(name, kind, mode, mtime, size=0, linkname=""):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.mtime = mtime
    info.size = size
    info.linkname = linkname
    info.uid = info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    return info


def gzip_bytes(raw, mtime):
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", compresslevel=9, mtime=mtime) as gz:
        gz.write(raw)
    return out.getvalue()


def data_tar(app, prefix, mtime):
    """The install tree: every directory down to the app, then the app."""
    raw = io.BytesIO()
    total = 0
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        path = "."
        tar.addfile(tar_info("./", tarfile.DIRTYPE, 0o755, mtime))
        for part in [p for p in prefix.split("/") if p] + ["Applications"]:
            path += "/" + part
            tar.addfile(tar_info(path + "/", tarfile.DIRTYPE, 0o755, mtime))
        base = f"{path}/{os.path.basename(app.rstrip('/'))}"
        for root, dirs, files in os.walk(app):
            dirs.sort()
            rel = os.path.relpath(root, app)
            here = base if rel == "." else f"{base}/{rel}"
            tar.addfile(tar_info(here + "/", tarfile.DIRTYPE, 0o755, mtime))
            for name in sorted(files):
                full = os.path.join(root, name)
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    tar.addfile(tar_info(f"{here}/{name}", tarfile.SYMTYPE, 0o777, mtime,
                                         linkname=os.readlink(full)))
                    continue
                executable = st.st_mode & 0o111
                with open(full, "rb") as handle:
                    content = handle.read()
                total += len(content)
                tar.addfile(tar_info(f"{here}/{name}", tarfile.REGTYPE, 0o755 if executable else 0o644,
                                     mtime, size=len(content)), io.BytesIO(content))
    return raw.getvalue(), total


def control_tar(files, mtime):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        tar.addfile(tar_info("./", tarfile.DIRTYPE, 0o755, mtime))
        for name, (content, mode) in files.items():
            data = content.encode("utf-8")
            tar.addfile(tar_info(f"./{name}", tarfile.REGTYPE, mode, mtime, size=len(data)), io.BytesIO(data))
    return raw.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="the built .app")
    parser.add_argument("--output", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", required=True, help="iphoneos-arm (rootful) or iphoneos-arm64 (rootless)")
    parser.add_argument("--prefix", default="", help='"" (rootful) or /var/jb (rootless)')
    parser.add_argument("--min-firmware", required=True)
    parser.add_argument("--maintainer", required=True)
    parser.add_argument("--homepage", default="")
    parser.add_argument("--icon", default="")
    parser.add_argument("--summary", required=True)
    parser.add_argument("--description", default="")
    parser.add_argument("--mtime", type=int, default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")))
    args = parser.parse_args()

    data, size = data_tar(args.app, args.prefix, args.mtime)
    app_path = f"{args.prefix}/Applications/{os.path.basename(args.app.rstrip('/'))}"
    fields = [
        ("Package", args.package),
        ("Name", args.name),
        ("Version", args.version),
        ("Architecture", args.arch),
        ("Section", "Applications"),
        ("Priority", "optional"),
        ("Depends", f"firmware (>= {args.min_firmware})"),
        ("Installed-Size", str((size + 1023) // 1024)),
        ("Maintainer", args.maintainer),
        ("Homepage", args.homepage),
        ("Icon", args.icon),
        ("Description", args.summary),
    ]
    control = "".join(f"{key}: {value}\n" for key, value in fields if value)
    for line in filter(None, args.description.split("\n")):
        control += f" {line}\n"
    # The home screen learns of an app in /Applications only through uicache.
    scripts = {
        "control": (control, 0o644),
        "postinst": (f'#!/bin/sh\nuicache -p "{app_path}" 2>/dev/null || uicache -a || true\nexit 0\n', 0o755),
        "postrm": ("#!/bin/sh\nuicache -a || true\nexit 0\n", 0o755),
    }

    deb = AR_MAGIC
    deb += ar_member("debian-binary", b"2.0\n", args.mtime)
    deb += ar_member("control.tar.gz", gzip_bytes(control_tar(scripts, args.mtime), args.mtime), args.mtime)
    deb += ar_member("data.tar.gz", gzip_bytes(data, args.mtime), args.mtime)
    with open(args.output, "wb") as out:
        out.write(deb)
    print(f"Built {args.output} ({len(deb) // 1024} KiB, installs {app_path})")


if __name__ == "__main__":
    main()
