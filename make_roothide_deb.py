import tarfile
import io
import os
import gzip
import lzma

deb_path = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogr_1.0.8_iphoneos-arm64.deb'
out_deb_path = r'C:\Users\Microsoft\.gemini\antigravity\scratch\cydia-repo\debs\com.lns.pogrs_1.0.8_iphoneos-arm64e.deb'

with open(deb_path, 'rb') as f:
    raw_deb = f.read()

members = {}
idx = 8
while idx < len(raw_deb):
    hdr = raw_deb[idx:idx+60]
    if len(hdr) < 60:
        break
    name = hdr[:16].decode('latin1').strip()
    size = int(hdr[48:58].decode('latin1').strip())
    content = raw_deb[idx+60:idx+60+size]
    members[name] = content
    idx += 60 + size
    if size % 2 == 1:
        idx += 1

# 1. Modify control.tar.gz
control_tar_data = None
for k in members:
    if 'control.tar' in k:
        decompressed = gzip.decompress(members[k]) if k.endswith('.gz') else members[k]
        in_tar = tarfile.open(fileobj=io.BytesIO(decompressed))
        out_buf = io.BytesIO()
        out_tar = tarfile.open(fileobj=out_buf, mode='w:gz')
        for m in in_tar.getmembers():
            f = in_tar.extractfile(m) if m.isreg() else None
            if m.name.endswith('control') and f:
                c_text = f.read().decode('utf-8')
                c_text = c_text.replace('Package: com.lns.pogr', 'Package: com.lns.pogrs')
                c_text = c_text.replace('Name: PodsGrant Enhanced', 'Name: PodsGrant Enhanced (RootHide)')
                c_text = c_text.replace('Architecture: iphoneos-arm64', 'Architecture: iphoneos-arm64e')
                new_f_data = c_text.encode('utf-8')
                m.size = len(new_f_data)
                out_tar.addfile(m, io.BytesIO(new_f_data))
            else:
                out_tar.addfile(m, f)
        out_tar.close()
        control_tar_data = out_buf.getvalue()
        break

# 2. Modify data.tar.gz
data_tar_data = None
for k in members:
    if 'data.tar' in k:
        if k.endswith('.lzma') or k.endswith('.xz'):
            decomp = lzma.decompress(members[k])
        elif k.endswith('.gz'):
            decomp = gzip.decompress(members[k])
        else:
            decomp = members[k]
        in_tar = tarfile.open(fileobj=io.BytesIO(decomp))
        out_buf = io.BytesIO()
        out_tar = tarfile.open(fileobj=out_buf, mode='w:gz')

        root_ti = tarfile.TarInfo('.')
        root_ti.type = tarfile.DIRTYPE
        root_ti.mode = 0o755
        out_tar.addfile(root_ti)

        seen_dirs = set(['.'])

        for m in in_tar.getmembers():
            orig_name = m.name
            clean_name = orig_name
            if clean_name.startswith('./'):
                clean_name = clean_name[2:]
            if clean_name.startswith('var/jb/'):
                clean_name = clean_name[7:]
            elif clean_name == 'var/jb' or clean_name == 'var' or clean_name == '.':
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
                    out_tar.addfile(d_ti)
                    seen_dirs.add(cur)

            m.name = clean_name
            f = in_tar.extractfile(m) if m.isreg() else None
            out_tar.addfile(m, f)

        out_tar.close()
        data_tar_data = out_buf.getvalue()
        break

# 3. Assemble new ar archive
def make_ar_header(name, size):
    hdr = f"{name:<16}{'0':<12}{'0':<6}{'0':<6}{'100644':<8}{str(size):<10}`\n"
    assert len(hdr) == 60, f"Header length is {len(hdr)}: {hdr}"
    return hdr.encode('latin1')

new_deb_buf = io.BytesIO()
new_deb_buf.write(b'!<arch>\n')

# debian-binary
db_content = b'2.0\n'
new_deb_buf.write(make_ar_header('debian-binary', len(db_content)))
new_deb_buf.write(db_content)

# control.tar.gz
new_deb_buf.write(make_ar_header('control.tar.gz', len(control_tar_data)))
new_deb_buf.write(control_tar_data)
if len(control_tar_data) % 2 == 1:
    new_deb_buf.write(b'\n')

# data.tar.gz
new_deb_buf.write(make_ar_header('data.tar.gz', len(data_tar_data)))
new_deb_buf.write(data_tar_data)
if len(data_tar_data) % 2 == 1:
    new_deb_buf.write(b'\n')

with open(out_deb_path, 'wb') as f:
    f.write(new_deb_buf.getvalue())

print(f"Successfully generated valid RootHide deb, size: {len(new_deb_buf.getvalue())} bytes")
