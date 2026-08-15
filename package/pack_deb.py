#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pack dist/ -> pkg/hudcontrol_jb.deb (stdlib only: ar + tar.gz).
Run after package/build_all.sh has staged dist/ (macOS/iOS SDK build).
Can also be smoke-tested on any OS with placeholder files.
Includes ./postinst in control.tar.gz (mode 0755)."""
import io, tarfile, hashlib, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIST = os.path.join(ROOT, 'dist')
OUT = os.path.join(ROOT, 'pkg', 'hudcontrol_jb.deb')
POSTINST = os.path.join(HERE, 'postinst')

CONTROL = """Package: com.ctf.hudcontrol
Name: HUDControl
Version: 3.0.0
Architecture: iphoneos-arm
Description: HUD one-button control for ComicReader (jailbroken direct version). Tap "start HUD" and the button flips to "stop HUD". Runs no-sandbox: spawns the ComicReader -hud helper directly via posix_spawn (mirrors C5 argv), stops it via Darwin notify_post(com.test.notification.hud.dismissal) with kill() fallback. No daemon needed. Install with Sileo/Zebra; postinst refreshes the icon cache so the app appears immediately.
Maintainer: ctf
Section: Utilities
"""

def walk_files():
    out = []
    for base, _, names in os.walk(DIST):
        for n in sorted(names):
            p = os.path.join(base, n)
            rel = './' + os.path.relpath(p, DIST).replace('\\', '/')
            with open(p, 'rb') as f:
                out.append((rel, f.read()))
    return out

def tar_gz(members):
    # members: list of (arcname, data, mode)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as tf:
        for arcname, data, mode in members:
            ti = tarfile.TarInfo(arcname)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 1700000000
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()

def ar_member(name, payload):
    hdr = name.encode().ljust(16, b' ') + b'1700000000  ' + b'0     ' + b'0     ' + b'100644  ' + str(len(payload)).encode().ljust(10, b' ') + b'`\n'
    assert len(hdr) == 60, 'ar header must be 60 bytes'
    return hdr + payload + (b'\n' if len(payload) % 2 else b'')

def main():
    data_files = walk_files()
    md5 = ''.join('%s  %s\n' % (hashlib.md5(d).hexdigest(), n) for n, d in data_files)
    md5 += hashlib.md5(CONTROL.encode()).hexdigest() + '  ./control\n'
    control_members = [('./control', CONTROL.encode(), 0o644), ('./md5sums', md5.encode(), 0o644)]
    if os.path.exists(POSTINST):
        with open(POSTINST, 'rb') as f:
            control_members.append(('./postinst', f.read(), 0o755))
    control_tar = tar_gz(control_members)
    data_members = []
    for n, d in data_files:
        mode = 0o755 if n.endswith('/HUDControl') else 0o644
        data_members.append((n, d, mode))
    data_tar = tar_gz(data_members)
    ar = b'!<arch>\n' + ar_member('debian-binary', b'2.0\n') + ar_member('control.tar.gz', control_tar) + ar_member('data.tar.gz', data_tar)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(ar)
    print('written:', OUT, len(ar), 'bytes')
    print('sha256:', hashlib.sha256(ar).hexdigest())
    print('control members:', [m[0] for m in control_members])
    print('data members:')
    for n, d in data_files:
        print('  ', n, len(d), 'bytes')
    # self-check: re-open the deb and verify structure
    pos = 8
    while pos < len(ar):
        name = ar[pos:pos+16].rstrip(b' ').decode()
        size = int(ar[pos+48:pos+58])
        print('ar member:', name, size)
        pos += 60 + size + (1 if size % 2 else 0)
    return 0

if __name__ == '__main__':
    sys.exit(main())