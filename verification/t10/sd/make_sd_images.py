"""Generate sparse TF-card images for the bmp_read fast-locate simulation.

Each image is a dict {sector: 512 bytes}; sectors not present read as zero.
Output per scenario (in OUT/<name>/):
  index.txt  : "N" then N lines "start_sector count data_sector_offset" (decimal)
  data.hex   : one byte per line, concatenated extent data ($readmemh)
  expect.txt : expected BMP start sectors (physical order) and pixel checksums
Nothing here touches a real disk/device; it only writes regular files.

Usage: python make_sd_images.py <bmp_asset_dir> <out_dir>
"""
import os
import struct
import sys

SECTOR = 512
NAMES = ('00_cover_loudness.bmp', '01_cover_tone.bmp', '02_cover_vowel.bmp',
         '03_bg_loudness.bmp', '04_bg_tone.bmp', '05_bg_vowel.bmp')
CARD_SECTORS_32G = 62333952          # typical "32GB" SDHC capacity in sectors


def load_bmps(asset_dir):
    out = []
    for n in NAMES:
        d = open(os.path.join(asset_dir, n), 'rb').read()
        assert len(d) == 921654 and d[:2] == b'BM'
        assert struct.unpack_from('<ii', d, 18) == (640, 480)
        out.append((n, d))
    return out


def pixel_checksum(d):
    off = struct.unpack_from('<I', d, 10)[0]
    s = 0
    px = d[off:off + 921600]
    for i in range(0, 921600, 3):
        s += (px[i + 2] << 24) | (px[i + 1] << 16) | (px[i] << 8)
    return s & 0xffffffff


def put_file(img, start, data):
    n = (len(data) + SECTOR - 1) // SECTOR
    data = data + bytes(n * SECTOR - len(data))
    for k in range(n):
        img[start + k] = data[k * SECTOR:(k + 1) * SECTOR]
    return n


def mbr(part_lba, part_sectors, ptype=0x0c):
    s = bytearray(SECTOR)
    s[0:3] = b'\xfa\x33\xc0'                       # some boot code bytes
    e = bytearray(16)
    e[0] = 0x00
    e[1:4] = b'\xfe\xff\xff'
    e[4] = ptype
    e[5:8] = b'\xfe\xff\xff'
    struct.pack_into('<II', e, 8, part_lba, part_sectors)
    s[446:462] = e
    s[510] = 0x55
    s[511] = 0xaa
    return bytes(s)


def fat32_sizes(part_sectors, spc, reserved, nfats):
    # Microsoft fatgen103 style iteration
    fatsz = 1
    while True:
        clusters = (part_sectors - reserved - nfats * fatsz) // spc
        need = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        if need <= fatsz:
            return fatsz, clusters
        fatsz = need


def vbr(part_lba, part_sectors, spc, reserved, nfats, fatsz):
    s = bytearray(SECTOR)
    s[0:3] = b'\xeb\x58\x90'
    s[3:11] = b'MSDOS5.0'
    struct.pack_into('<HBHBHHBHHHII', s, 11, 512, spc, reserved, nfats, 0, 0,
                     0xf8, 0, 63, 255, part_lba, part_sectors)
    struct.pack_into('<IHHIHH', s, 36, fatsz, 0, 0, 2, 1, 6)
    s[64] = 0x80
    s[66] = 0x29
    struct.pack_into('<I', s, 67, 0x1234abcd)
    s[71:82] = b'NO NAME    '
    s[82:90] = b'FAT32   '
    s[510] = 0x55
    s[511] = 0xaa
    return bytes(s)


def fsinfo():
    s = bytearray(SECTOR)
    struct.pack_into('<I', s, 0, 0x41615252)
    struct.pack_into('<III', s, 484, 0x61417272, 0xffffffff, 0xffffffff)
    s[510] = 0x55
    s[511] = 0xaa
    return bytes(s)


def dirent(name11, attr, clus, size):
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    struct.pack_into('<H', e, 20, clus >> 16)
    struct.pack_into('<H', e, 26, clus & 0xffff)
    struct.pack_into('<I', e, 28, size)
    return bytes(e)


def fat32_card(bmps, part_lba, spc=32, reserved=32, nfats=2, gap_after=(),
               bmp_in_data=True, card_sectors=CARD_SECTORS_32G):
    """Windows-like FAT32: root dir (cl2), System Volume Information (cl3) with
    two small files (cl4, cl5), then the BMP files in contiguous clusters."""
    img = {}
    part_sectors = card_sectors - part_lba
    fatsz, clusters = fat32_sizes(part_sectors, spc, reserved, nfats)
    img[0] = mbr(part_lba, part_sectors)
    img[part_lba] = vbr(part_lba, part_sectors, spc, reserved, nfats, fatsz)
    img[part_lba + 1] = fsinfo()
    img[part_lba + 6] = vbr(part_lba, part_sectors, spc, reserved, nfats, fatsz)
    img[part_lba + 7] = fsinfo()
    data_start = part_lba + reserved + nfats * fatsz

    def clus_lba(c):
        return data_start + (c - 2) * spc
    fat = {0: 0x0ffffff8, 1: 0x0fffffff, 2: 0x0fffffff, 3: 0x0fffffff,
           4: 0x0fffffff, 5: 0x0fffffff}
    root = [dirent(b'NO NAME    ', 0x08, 0, 0),
            dirent(b'SYSTEM~1   ', 0x16, 3, 0)]
    svi = [dirent(b'.          ', 0x10, 3, 0), dirent(b'..         ', 0x10, 0, 0),
           dirent(b'WPSETT~1DAT', 0x20, 4, 12), dirent(b'INDEXE~1   ', 0x20, 5, 76)]
    put_file(img, clus_lba(3), b''.join(svi))
    put_file(img, clus_lba(4), bytes(range(12)))
    put_file(img, clus_lba(5), bytes(76))
    starts = []
    c = 6
    for i, (n, d) in enumerate(bmps):
        ncl = (len(d) + spc * SECTOR - 1) // (spc * SECTOR)
        if bmp_in_data:
            put_file(img, clus_lba(c), d)
            starts.append(clus_lba(c))
        for k in range(ncl):
            fat[c + k] = c + k + 1 if k < ncl - 1 else 0x0fffffff
        base, ext = n.upper().split('.')
        short = (base[:6] + '~1').ljust(8)[:8] + ext[:3]
        root.append(dirent(short.encode('ascii'), 0x20, c, len(d)))
        c += ncl
        if i in gap_after:
            c += 1                                  # a free cluster (deleted file)
    put_file(img, clus_lba(2), b''.join(root))
    fat_bytes = bytearray(((max(fat) + 1) * 4 + SECTOR - 1) // SECTOR * SECTOR)
    for k, v in fat.items():
        struct.pack_into('<I', fat_bytes, k * 4, v)
    for f in range(nfats):
        put_file(img, part_lba + reserved + f * fatsz, bytes(fat_bytes))
    info = dict(part_lba=part_lba, spc=spc, reserved=reserved, nfats=nfats,
                fatsz=fatsz, clusters=clusters, data_start=data_start)
    return img, starts, info


def raw_layout(bmps):
    img = {}
    starts = []
    sector = 0
    for n, d in bmps:
        starts.append(sector)
        sector += put_file(img, sector, d)
    return img, starts, dict(layout='raw, make_tf_layout.py style')


def superfloppy(bmps, spc=32, reserved=32, nfats=2):
    """FAT32 boot sector at sector 0 (no MBR)."""
    img, starts, info = fat32_card(bmps, 0, spc, reserved, nfats)
    # fat32_card wrote an MBR at 0 and then the VBR at part_lba=0 over it.
    assert img[0][82:90] == b'FAT32   '
    info['layout'] = 'superfloppy'
    return img, starts, info


def write_image(out_dir, name, img, starts, bmps_by_start, info):
    d = os.path.join(out_dir, name)
    os.makedirs(d, exist_ok=True)
    keys = sorted(img)
    extents = []
    for k in keys:
        if extents and extents[-1][0] + extents[-1][1] == k:
            extents[-1][1] += 1
        else:
            extents.append([k, 1])
    off = 0
    with open(os.path.join(d, 'index.txt'), 'w', newline='\n') as f:
        f.write('%d\n' % len(extents))
        for s, n in extents:
            f.write('%d %d %d\n' % (s, n, off))
            off += n
    with open(os.path.join(d, 'data.hex'), 'w', newline='\n') as f:
        for k in keys:
            f.write('\n'.join('%02x' % b for b in img[k]))
            f.write('\n')
    with open(os.path.join(d, 'expect.txt'), 'w', newline='\n') as f:
        f.write('info %s\n' % info)
        f.write('extents %d sectors_defined %d\n' % (len(extents), off))
        for s in starts:
            f.write('bmp_start %d checksum %08x name %s\n'
                    % (s, bmps_by_start[s][1], bmps_by_start[s][0]))
    print(name, info, 'bmp_starts', starts, 'defined_sectors', off)


def main():
    asset_dir, out_dir = sys.argv[1], sys.argv[2]
    bmps = load_bmps(asset_dir)
    sums = [(n, pixel_checksum(d)) for n, d in bmps]

    def emit(name, built, bmp_names=None):
        img, starts, info = built
        names = bmp_names if bmp_names is not None else [s[0] for s in sums]
        by = {s: (names[i], dict(sums)[names[i]]) for i, s in enumerate(starts)}
        write_image(out_dir, name, img, starts, by, info)

    emit('A2048', fat32_card(bmps, 2048))
    emit('A8192', fat32_card(bmps, 8192))
    emit('A8192_spc64_gap', fat32_card(bmps, 8192, spc=64, gap_after=(2,)))
    emit('B_raw', raw_layout(bmps))
    # C: valid MBR, BPB bytes_per_sector corrupted to 1024 -> fallback
    img, starts, info = fat32_card(bmps, 2048)
    s = bytearray(img[2048])
    struct.pack_into('<H', s, 11, 1024)
    img[2048] = bytes(s)
    info['corrupt'] = 'BPB bytes_per_sector=1024'
    emit('C_badbpb', (img, starts, info))
    # D: valid FAT32, no BMP in the data area; one BMP planted inside FAT #1
    img, _, info = fat32_card(bmps, 2048, bmp_in_data=False)
    planted = 2048 + 32 + 100
    for k in range(planted, planted + 1801):
        img.pop(k, None)
    put_file(img, planted, bmps[0][1])
    info['planted_bmp_in_fat_at'] = planted
    emit('D_fatregion', (img, [planted], info), [bmps[0][0]])
    emit('E_superfloppy', superfloppy(bmps))


if __name__ == '__main__':
    main()
