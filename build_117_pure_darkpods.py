import tarfile
import io
import os
import gzip
import plistlib
import struct
import hashlib

def resign_slice(slice_bytes):
    s = bytearray(slice_bytes)
    magic, cpu, sub, ft, ncmds, sizeofcmds, flags, res = struct.unpack('<IIIIIIII', s[:32])
    cmd_off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', s[cmd_off:cmd_off+8])
        if cmd == 0x1d: # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack('<II', s[cmd_off+8:cmd_off+16])
            blob = s[dataoff:dataoff+datasize]
            magic, length, count = struct.unpack('>III', blob[:12])
            for i in range(count):
                stype, offset = struct.unpack('>II', blob[12+i*8:12+(i+1)*8])
                sub_m, = struct.unpack('>I', blob[offset:offset+4])
                if hex(sub_m) == '0xfade0c02': # CodeDirectory
                    cd_magic, cd_len, cd_ver, cd_flags, cd_hashoff, cd_identoff, cd_nspec, cd_ncode, cd_code_limit, cd_hash_size, cd_hash_type, cd_platform, cd_page_size, cd_spare = struct.unpack('>IIIIIIIIIBBBBI', blob[offset:offset+44])
                    psize = 2**cd_page_size
                    for p in range(cd_ncode):
                        pdata = s[p*psize : min((p+1)*psize, cd_code_limit)]
                        h = hashlib.sha256(pdata).digest() if cd_hash_type == 2 else hashlib.sha1(pdata).digest()
                        h_pos = dataoff + offset + cd_hashoff + p * cd_hash_size
                        s[h_pos:h_pos+cd_hash_size] = h
        cmd_off += cmdsize
    return bytes(s)

def verify_slice_hashes(slice_bytes, name='slice'):
    s = slice_bytes
    smagic, scpu, ssub, sft, sncmds, ssizeofcmds, sflags, sres = struct.unpack('<IIIIIIII', s[:32])
    cmd_off = 32
    for _ in range(sncmds):
        cmd, cmdsize = struct.unpack('<II', s[cmd_off:cmd_off+8])
        if cmd == 0x1d:
            dataoff, datasize = struct.unpack('<II', s[cmd_off+8:cmd_off+16])
            blob = s[dataoff:dataoff+datasize]
            magic, length, count = struct.unpack('>III', blob[:12])
            for i in range(count):
                stype, offset = struct.unpack('>II', blob[12+i*8:12+(i+1)*8])
                sub_m, = struct.unpack('>I', blob[offset:offset+4])
                if sub_m == 0xfade0c02:
                    cd_ver, cd_flags, cd_hashoff, cd_identoff, cd_nspec, cd_ncode, cd_code_limit, cd_hash_size, cd_hash_type = struct.unpack('>IIIIIIIBB', blob[offset+8:offset+38])
                    psize = 4096
                    mismatch = 0
                    for p in range(cd_ncode):
                        pdata = s[p*psize : min((p+1)*psize, cd_code_limit)]
                        act = hashlib.sha256(pdata).digest() if cd_hash_type == 2 else hashlib.sha1(pdata).digest()
                        exp = blob[offset+cd_hashoff+p*cd_hash_size : offset+cd_hashoff+(p+1)*cd_hash_size]
                        if act != exp: mismatch += 1
                    print(f'{name} hashType={cd_hash_type} mismatch: {mismatch}/{cd_ncode}')
        cmd_off += cmdsize

def patch_podsgrant_dylib_pure_darkpods(raw_dylib):
    magic, nfat = struct.unpack('>II', raw_dylib[:8])
    assert hex(magic) == '0xcafebabe', "Not a FAT binary"
    
    slices_info = []
    for i in range(nfat):
        cpu, sub, off, fsize, align = struct.unpack('>IIIII', raw_dylib[8+i*20:8+(i+1)*20])
        slices_info.append((cpu, sub, off, fsize, align))

    # Slice 0: arm64 at 0x4000
    s0 = bytearray(raw_dylib[slices_info[0][2] : slices_info[0][2] + slices_info[0][3]])
    # 1. 0x4468 -> b #0x4590 (skip UIWindow / SlideUp / BackgroundView / ContainerView)
    s0[0x4468:0x446c] = struct.pack('<I', 0x1400004a)
    # 2. 0x45a0 -> b #0x45d4 (skip initWithFrame and didMoveToWindow, jump straight to setTitleView)
    s0[0x45a0:0x45a4] = struct.pack('<I', 0x1400000d)
    # 3. 0x4604 -> b #0x4620 (skip PRXFlowConfiguration init, jump straight to setSupportsDarkMode & supportsDarkMode)
    s0[0x4604:0x4608] = struct.pack('<I', 0x14000007)
    s0_resigned = resign_slice(bytes(s0))
    verify_slice_hashes(s0_resigned, 's0')

    # Slice 1: arm64e at 0x18000
    s1 = bytearray(raw_dylib[slices_info[1][2] : slices_info[1][2] + slices_info[1][3]])
    # 1. 0x84c0 -> b #0x8628 (skip UIWindow / SlideUp / BackgroundView / ContainerView)
    s1[0x84c0:0x84c4] = struct.pack('<I', 0x1400005a)
    # 2. 0x8638 -> b #0x867c (skip initWithFrame and didMoveToWindow, jump straight to setTitleView)
    s1[0x8638:0x863c] = struct.pack('<I', 0x14000011)
    # 3. 0x86b4 -> b #0x86d8 (skip PRXFlowConfiguration init, jump straight to setSupportsDarkMode & supportsDarkMode)
    s1[0x86b4:0x86b8] = struct.pack('<I', 0x14000009)
    s1_resigned = resign_slice(bytes(s1))
    verify_slice_hashes(s1_resigned, 's1')

    new_dylib = bytearray(raw_dylib)
    new_dylib[slices_info[0][2] : slices_info[0][2] + slices_info[0][3]] = s0_resigned
    new_dylib[slices_info[1][2] : slices_info[1][2] + slices_info[1][3]] = s1_resigned

    return bytes(new_dylib)

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

# Base files
base_deb_path = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogr_1.0.8_iphoneos-arm64.deb'
out_roothide_deb = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogrs_1.1.7_iphoneos-arm64e.deb'
out_rootless_deb = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogr_1.1.7_iphoneos-arm64.deb'

with open(base_deb_path, 'rb') as f:
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

postinst_sh = b"""#!/bin/sh
echo "Reloading daemons..."
killall -TERM bluetoothd 2>/dev/null || true
killall -TERM sharingd 2>/dev/null || true
killall -TERM heard 2>/dev/null || true
killall -TERM SharingViewService 2>/dev/null || true
exit 0
"""

postrm_sh = b"""#!/bin/sh
echo "Reloading daemons..."
killall -TERM bluetoothd 2>/dev/null || true
killall -TERM sharingd 2>/dev/null || true
killall -TERM SharingViewService 2>/dev/null || true
exit 0
"""

full_plist_dict = {
    'Filter': {
        'Bundles': ['com.apple.SpringBoard', 'com.apple.sharingd', 'com.apple.SharingViewService'],
        'Executables': ['bluetoothd', 'sharingd', 'SharingViewService']
    }
}
full_plist_bytes = plistlib.dumps(full_plist_dict, fmt=plistlib.FMT_BINARY)

def build_control_tar(pkg_id, pkg_name, arch, version, section, desc, depiction_url):
    control_text = f"""Package: {pkg_id}
Name: {pkg_name}
Version: {version}
Architecture: {arch}
Description: {desc}
Maintainer: Ruphane & LamKwong
Author: Ruphane & LNSSPsd & LamKwong
Section: {section}
Depends: mobilesubstrate (>= 0.9.5000)
Tag: purpose::extension
Icon: https://TrollStoreX.Github.io/sileodepiction/PodsGrant/icon.png
SileoDepiction: {depiction_url}
"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tar:
        ti = tarfile.TarInfo('./control')
        data = control_text.encode('utf-8')
        ti.size = len(data)
        ti.mode = 0o644
        tar.addfile(ti, io.BytesIO(data))
        
        ti_pi = tarfile.TarInfo('./postinst')
        ti_pi.size = len(postinst_sh)
        ti_pi.mode = 0o755
        tar.addfile(ti_pi, io.BytesIO(postinst_sh))

        ti_pr = tarfile.TarInfo('./postrm')
        ti_pr.size = len(postrm_sh)
        ti_pr.mode = 0o755
        tar.addfile(ti_pr, io.BytesIO(postrm_sh))
    return buf.getvalue()

desc_text = "提高低系统与新 AirPods 兼容性，融合 DarkPods 原生纯深色弹窗。"

# 1. Build RootHide com.lns.pogrs 1.1.7
print("Building RootHide com.lns.pogrs 1.1.7...")
rh_control_tar = build_control_tar(
    'com.lns.pogrs',
    'AirPods PodsGrant',
    'iphoneos-arm64e',
    '1.1.7',
    'AirPods',
    desc_text,
    'https://lamkwong-99.github.io/monainai/depictions/com.lns.pogrs.json'
)

raw_data = src_members['data.tar.gz']
in_tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw_data)))
rh_data_buf = io.BytesIO()
rh_out_tar = tarfile.open(fileobj=rh_data_buf, mode='w:gz')

root_ti = tarfile.TarInfo('.')
root_ti.type = tarfile.DIRTYPE
root_ti.mode = 0o755
rh_out_tar.addfile(root_ti)

seen_dirs = set(['.'])
for m in in_tar.getmembers():
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
        m.size = len(full_plist_bytes)
        rh_out_tar.addfile(m, io.BytesIO(full_plist_bytes))
    elif m.name.endswith('PodsGrant.dylib'):
        patched_dylib = patch_podsgrant_dylib_pure_darkpods(in_tar.extractfile(m).read())
        m.size = len(patched_dylib)
        rh_out_tar.addfile(m, io.BytesIO(patched_dylib))
    else:
        f = in_tar.extractfile(m) if m.isreg() else None
        rh_out_tar.addfile(m, f)
rh_out_tar.close()
rh_data_tar = rh_data_buf.getvalue()

rh_deb_data = create_ar_archive([
    ('debian-binary', b'2.0\n'),
    ('control.tar.gz', rh_control_tar),
    ('data.tar.gz', rh_data_tar)
])

with open(out_roothide_deb, 'wb') as f:
    f.write(rh_deb_data)
print(f"Generated {out_roothide_deb} ({len(rh_deb_data)} bytes)")

# 2. Build Rootless com.lns.pogr 1.1.7
print("Building Rootless com.lns.pogr 1.1.7...")
rl_control_tar = build_control_tar(
    'com.lns.pogr',
    'AirPods PodsGrant',
    'iphoneos-arm64',
    '1.1.7',
    'AirPods',
    desc_text,
    'https://lamkwong-99.github.io/monainai/depictions/com.lns.pogr.json'
)

in_tar_rl = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw_data)))
rl_data_buf = io.BytesIO()
rl_out_tar = tarfile.open(fileobj=rl_data_buf, mode='w:gz')
for m in in_tar_rl.getmembers():
    if m.name.endswith('PodsGrant.plist'):
        m.size = len(full_plist_bytes)
        rl_out_tar.addfile(m, io.BytesIO(full_plist_bytes))
    elif m.name.endswith('PodsGrant.dylib'):
        patched_dylib = patch_podsgrant_dylib_pure_darkpods(in_tar_rl.extractfile(m).read())
        m.size = len(patched_dylib)
        rl_out_tar.addfile(m, io.BytesIO(patched_dylib))
    else:
        f = in_tar_rl.extractfile(m) if m.isreg() else None
        rl_out_tar.addfile(m, f)
rl_out_tar.close()
rl_data_tar = rl_data_buf.getvalue()

rl_deb_data = create_ar_archive([
    ('debian-binary', b'2.0\n'),
    ('control.tar.gz', rl_control_tar),
    ('data.tar.gz', rl_data_tar)
])

with open(out_rootless_deb, 'wb') as f:
    f.write(rl_deb_data)
print(f"Generated {out_rootless_deb} ({len(rl_deb_data)} bytes)")
