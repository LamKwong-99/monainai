import tarfile
import io
import os
import gzip
import lzma
import plistlib

def make_ar_header(name, size):
    hdr = f"{name:<16}{'0':<12}{'0':<6}{'0':<6}{'100644':<8}{str(size):<10}`\n"
    assert len(hdr) == 60, f"Header length is {len(hdr)}: {hdr}"
    return hdr.encode('latin1')

def create_ar_archive(members):
    buf = io.BytesIO()
    buf.write(b'!<arch>\n')
    for name, data in members:
        buf.write(make_ar_header(name, len(data)))
        buf.write(data)
        if len(data) % 2 == 1:
            buf.write(b'\n')
    return buf.getvalue()

src_deb_path = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogr_1.0.8_iphoneos-arm64.deb'
out_rootless_deb = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogr_1.1.2_iphoneos-arm64.deb'
out_roothide_deb = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogrs_1.1.2_iphoneos-arm64e.deb'

with open(src_deb_path, 'rb') as f:
    raw_deb = f.read()

src_members = {}
idx = 8
while idx < len(raw_deb):
    hdr = raw_deb[idx:idx+60]
    if len(hdr) < 60:
        break
    name = hdr[:16].decode('latin1').strip()
    size = int(hdr[48:58].decode('latin1').strip())
    content = raw_deb[idx+60:idx+60+size]
    src_members[name] = content
    idx += 60 + size
    if size % 2 == 1:
        idx += 1

# New binary plist content (NO SharingViewService!)
new_plist_dict = {
    'Filter': {
        'Bundles': ['com.apple.SpringBoard', 'com.apple.sharingd'],
        'Executables': ['bluetoothd', 'sharingd']
    }
}
new_plist_bytes = plistlib.dumps(new_plist_dict, fmt=plistlib.FMT_BINARY)

# Function to build control.tar.gz
def build_control_tar(pkg_id, pkg_name, arch, version, desc):
    control_text = f"""Package: {pkg_id}
Name: {pkg_name}
Version: {version}
Architecture: {arch}
Description: {desc}
Maintainer: LamKwong <abc999mn@163.com>
Author: LNSSPsd & iCraze & LamKwong
Section: Tweaks
Depends: mobilesubstrate (>= 0.9.5000)
Tag: purpose::extension
Icon: https://raw.githubusercontent.com/LNSSPsd/PodsGrant/main/podsgrantsettings/Resources/icon%402x.png
"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tar:
        ti = tarfile.TarInfo('./control')
        data = control_text.encode('utf-8')
        ti.size = len(data)
        ti.mode = 0o644
        tar.addfile(ti, io.BytesIO(data))
    return buf.getvalue()

desc_text = "优化版 AirPods/Beats 兼容插件 (方案1解耦版)\n - 与独立 DarkPods 插件完美共存：彻底移除 SharingViewService 的 UI 注入，由 DarkPods 独立负责弹窗渲染，彻底解决冲突闪退无弹窗。\n - 专精底层蓝牙与配对协议：负责 bluetoothd 与 sharingd 广播重写与蓝牙配对。\n - 稳定支持 iOS 15-16 Rootless / RootHide 环境。"

# --- 1. Build Rootless deb (1.1.2) ---
print("Building Rootless deb...")
rootless_control_tar = build_control_tar(
    'com.lns.pogr',
    'PodsGrant Enhanced',
    'iphoneos-arm64',
    '1.1.2',
    desc_text
)

# Extract and rewrite data.tar
raw_data = src_members['data.tar.gz']
in_tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw_data)))
data_buf = io.BytesIO()
out_tar = tarfile.open(fileobj=data_buf, mode='w:gz')
for m in in_tar.getmembers():
    if m.name.endswith('PodsGrant.plist'):
        m.size = len(new_plist_bytes)
        out_tar.addfile(m, io.BytesIO(new_plist_bytes))
    else:
        f = in_tar.extractfile(m) if m.isreg() else None
        out_tar.addfile(m, f)
out_tar.close()
rootless_data_tar = data_buf.getvalue()

rootless_deb_data = create_ar_archive([
    ('debian-binary', b'2.0\n'),
    ('control.tar.gz', rootless_control_tar),
    ('data.tar.gz', rootless_data_tar)
])

with open(out_rootless_deb, 'wb') as f:
    f.write(rootless_deb_data)
print(f"Rootless deb written: {out_rootless_deb} ({len(rootless_deb_data)} bytes)")

# --- 2. Build RootHide deb (1.1.2) ---
print("Building RootHide deb...")
roothide_control_tar = build_control_tar(
    'com.lns.pogrs',
    'PodsGrant Enhanced (RootHide)',
    'iphoneos-arm64e',
    '1.1.2',
    desc_text
)

in_tar2 = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw_data)))
rh_data_buf = io.BytesIO()
rh_out_tar = tarfile.open(fileobj=rh_data_buf, mode='w:gz')

root_ti = tarfile.TarInfo('.')
root_ti.type = tarfile.DIRTYPE
root_ti.mode = 0o755
rh_out_tar.addfile(root_ti)

seen_dirs = set(['.'])
for m in in_tar2.getmembers():
    clean_name = m.name
    if clean_name.startswith('./'):
        clean_name = clean_name[2:]
    if clean_name.startswith('var/jb/'):
        clean_name = clean_name[7:]
    elif clean_name in ('var/jb', 'var', '.'):
        continue

    clean_name = './' + clean_name
    parts = clean_name.split('/')
    cur = '.'
    for p in parts[1:-1]:
        cur += '/' + p
        if cur not in seen_dirs:
            d_ti = tarfile.TarInfo(cur)
            d_ti.type = tarfile.DIRTYPE
            d_ti.mode = 0o755
            rh_out_tar.addfile(d_ti)
            seen_dirs.add(cur)

    m.name = clean_name
    if m.name.endswith('PodsGrant.plist'):
        m.size = len(new_plist_bytes)
        rh_out_tar.addfile(m, io.BytesIO(new_plist_bytes))
    else:
        f = in_tar2.extractfile(m) if m.isreg() else None
        rh_out_tar.addfile(m, f)
rh_out_tar.close()
roothide_data_tar = rh_data_buf.getvalue()

roothide_deb_data = create_ar_archive([
    ('debian-binary', b'2.0\n'),
    ('control.tar.gz', roothide_control_tar),
    ('data.tar.gz', roothide_data_tar)
])

with open(out_roothide_deb, 'wb') as f:
    f.write(roothide_deb_data)
print(f"RootHide deb written: {out_roothide_deb} ({len(roothide_deb_data)} bytes)")
