"""T10 缩略图选择页的位级参考模型（效果图 + 后续仿真期望值共用）。

用法：python -I -X utf8 thumb_model.py <tf_card目录> <compressed.mem> <输出目录> [focus]
输出：before_T9.png（T9 现状模型）、after_T10.png（T10 方案）、after_T10_x2.png（2 倍放大）。
RTL 只能用移位/加法/小表实现，下面每个公式都按此写，RTL 必须逐位照抄。
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

W, H = 640, 480
CARD_X = (56, 240, 424)
CARD_W, CARD_H = 160, 120
CARD_Y0 = 180                     # 屏幕 y，180..299
STRIP_Y0, STRIP_Y1 = 64, 335      # 缓存条带（屏幕 y，含端点）
SLOT_BASE = (0, 0x04B000, 0x096000)
LABEL_X0, LABEL_W = 32, 96        # 标签窗口（相对卡片左边）；T10 大字版为 8, 144
LINE0_X, LINE1_X = (284, 356), (116, 524)   # 标题/说明行窗口；T10 大字版 (280,360),(47,593)

# ---- 圆角：每行内缩表（半径 6），行 0..5，之后为 0 ----
CORNER_INSET = (6, 4, 2, 1, 1, 0)   # 手工定的 6 行表，RTL 照抄
BORDER_W = 2                        # 烘焙白边
BAND_W = 4                          # 焦点黄框宽度（实时）
SHADOW_D = 4                        # 阴影偏移


def inset(ly):
    r = min(ly, CARD_H - 1 - ly)
    return CORNER_INSET[r] if r < len(CORNER_INSET) else 0


def in_round(lx, ly, shrink=0):
    """(lx,ly) 是否在圆角矩形内；shrink 为向内收缩的像素数。"""
    if ly < shrink or ly > CARD_H - 1 - shrink:
        return False
    ins = inset(ly) + shrink
    return ins <= lx <= CARD_W - 1 - ins


def sky(y):
    """天空蓝竖向渐变，仅移位加法：顶 (80,160,224) -> 底 (199,219,238)。"""
    return (0x50 + (y >> 2), 0xA0 + (y >> 3), 0xE0 + (y >> 5))


def darken75(c):
    return tuple((v >> 1) + (v >> 2) for v in c)


def dim62(c):
    return tuple((v >> 1) + (v >> 3) for v in c)


# ---- 字库（与 thumbnail_text_serial.v 同一读法）----
def load_font(mem_path):
    words = [int(l, 16) for l in Path(mem_path).read_text().split()]
    return lambda a: (words[a] >> 12) & 0xF if a < 6144 else 0


def text_lines():
    # (line_id, y0, x0, x1)：与 text_serial 的行/列窗口一致
    out = [(0, 68) + LINE0_X, (1, 98) + LINE1_X]
    for k, x0 in enumerate(CARD_X):
        out.append((2 + k, 307, x0 + LABEL_X0, x0 + LABEL_X0 + LABEL_W))
    return out


def render_text(nib):
    """返回 ink[y][x] 与 line_id[y][x]（-1 = 无）。"""
    ink = np.zeros((H, W), bool)
    lid = np.full((H, W), -1, int)
    for line_id, y0, x0, x1 in text_lines():
        for row in range(20):
            y = y0 + row
            cell, col, glyph, width = 0, 0, 0, 6
            for x in range(x0, x1):
                if col == 0:
                    base = 4500 + ((line_id << 6) + cell) * 3
                    meta = nib(base) | (nib(base + 1) << 4) | (nib(base + 2) << 8)
                    glyph, width = meta & 0x3F, (meta >> 6) & 0x1F
                a = glyph * 100 + row * 5 + (col >> 2)
                if (nib(a) >> (col & 3)) & 1:
                    ink[y, x] = True
                lid[y, x] = line_id
                if col == (width - 1) & 0x1F:
                    col, cell = 0, cell + 1
                else:
                    col += 1
    return ink, lid


def load_slots(tf_dir):
    files = sorted(Path(tf_dir).glob('*.bmp'))[:3]
    return [np.asarray(Image.open(f).convert('RGB'), dtype=np.int32) for f in files]


def thumb_point(img):
    return img[0::4, 0::4]


def thumb_box(img):
    s = img.reshape(120, 4, 160, 4, 3).sum(axis=(1, 3))
    return s >> 4


def render_before(slots, ink, lid, focus, valid=(1, 1, 1)):
    """T9 现状：点采样、黑底、2px 白框、选中标签黄色。"""
    out = np.zeros((H, W, 3), np.int32)
    for k, x0 in enumerate(CARD_X):
        if valid[k]:
            out[CARD_Y0:CARD_Y0 + CARD_H, x0:x0 + CARD_W] = thumb_point(slots[k])
    col = {0: (0x38, 0xBD, 0xF8)}
    for y, x in zip(*np.nonzero(ink)):
        out[y, x] = col.get(lid[y, x], (0x94, 0xA3, 0xB8))
        l = lid[y, x]
        if l >= 2 and l - 2 == focus:
            out[y, x] = (0xFA, 0xCC, 0x15)
    x0 = CARD_X[focus]
    for ly in range(CARD_H):
        for lx in range(CARD_W):
            if lx < 2 or lx >= 158 or ly < 2 or ly > 117:
                out[CARD_Y0 + ly, x0 + lx] = (255, 255, 255)
    out[:STRIP_Y0] = 0
    out[STRIP_Y1 + 1:] = 0
    return out


# 缓存低 8 位标记（T10）：bit0 字迹，bit2:1 卡/标签槽（3=无），bit3 焦点带，bit4 卡片像素，bit5 标签字迹
def build_cache(slots, ink, lid, valid=(1, 1, 1)):
    """返回条带缓存 rgb[272,640,3] 与 flags[272,640]，即引擎写入 SDRAM 的内容。"""
    rgb = np.zeros((STRIP_Y1 - STRIP_Y0 + 1, W, 3), np.int32)
    flg = np.zeros(rgb.shape[:2], np.int32)
    thumbs = [thumb_box(s) for s in slots]
    TITLE = (0x1E, 0x3A, 0x8A)
    BODY = (0x33, 0x41, 0x55)
    for sy in range(rgb.shape[0]):
        y = sy + STRIP_Y0
        bg = sky(y)
        for x in range(W):
            c, f = bg, 0b110            # 槽=3
            # 阴影
            for k, x0 in enumerate(CARD_X):
                lx, ly = x - x0 - SHADOW_D, y - CARD_Y0 - SHADOW_D
                if 0 <= lx < CARD_W and 0 <= ly < CARD_H and in_round(lx, ly):
                    c = darken75(bg)
            # 卡片
            for k, x0 in enumerate(CARD_X):
                lx, ly = x - x0, y - CARD_Y0
                if 0 <= lx < CARD_W and 0 <= ly < CARD_H and in_round(lx, ly):
                    f = (k << 1) | 0x10
                    if not in_round(lx, ly, BAND_W):
                        f |= 0x08
                    if not in_round(lx, ly, BORDER_W):
                        c = (255, 255, 255)
                    elif valid[k]:
                        c = tuple(thumbs[k][ly, lx])
                    else:   # 缺图：沿用 T9 暗底 + 叉号（diagonal = 条带行 - 96）
                        d = sy - 96
                        cross = (d <= lx < d + 2) or (158 <= lx + d <= 159)
                        c = (0x47, 0x55, 0x69) if cross else (0x11, 0x18, 0x27)
            # 文字
            if ink[y, x]:
                l = lid[y, x]
                c = TITLE if l == 0 else BODY
                f = (f & ~0b110) | 0x01
                if l >= 2:
                    f = 0x01 | 0x20 | ((l - 2) << 1)
                else:
                    f |= 0b110
            rgb[sy, x] = c
            flg[sy, x] = f
    return rgb, flg


def render_after(cache_rgb, cache_flg, focus, valid=(1, 1, 1)):
    """视频管线实时部分：条带外渐变、焦点黄框、非焦点压暗、标签重着色。"""
    out = np.zeros((H, W, 3), np.int32)
    YELLOW = (0xFA, 0xCC, 0x15)
    LABEL_SEL = (0xB4, 0x53, 0x09)
    LABEL_BAD = (0x94, 0xA3, 0xB8)
    for y in range(H):
        if y < STRIP_Y0 or y > STRIP_Y1:
            out[y, :] = sky(y)
            continue
        for x in range(W):
            c = tuple(cache_rgb[y - STRIP_Y0, x])
            f = cache_flg[y - STRIP_Y0, x]
            slot = (f >> 1) & 3
            if f & 0x10:
                if slot == focus:
                    if (f & 0x08) and valid[slot]:
                        c = YELLOW
                else:
                    c = dim62(c)
            elif f & 0x20:
                if not valid[slot]:
                    c = LABEL_BAD
                elif slot == focus:
                    c = LABEL_SEL
            out[y, x] = c
    return out


def save(a, path, scale=1):
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    if scale > 1:
        im = im.resize((W * scale, H * scale), Image.NEAREST)
    im.save(path)


# ---- 仿真期望值导出（只导出，不改任何渲染语义）----
def export_cache_mem(cache_rgb, cache_flg, path):
    """缓存 174080 字，每行 8 位十六进制 {R,G,B,flags}，条带光栅顺序（= SDRAM 1C2000 起的字序）。"""
    with open(path, 'w') as f:
        for sy in range(cache_rgb.shape[0]):
            for x in range(W):
                r, g, b = (int(v) for v in cache_rgb[sy, x])
                f.write('%02x%02x%02x%02x\n' % (r, g, b, int(cache_flg[sy, x]) & 0xFF))


def export_frame_mem(frame, path):
    """整帧 307200 像素，每行 6 位十六进制 RGB，屏幕光栅顺序。"""
    with open(path, 'w') as f:
        for y in range(H):
            for x in range(W):
                r, g, b = (int(v) for v in frame[y, x])
                f.write('%02x%02x%02x\n' % (r, g, b))


def main():
    tf_dir, mem, out_dir = sys.argv[1:4]
    focus = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    mode = sys.argv[5] if len(sys.argv) > 5 else ''
    global LABEL_X0, LABEL_W, LINE0_X, LINE1_X
    if mode in ('biglabel', 'big'):
        LABEL_X0, LABEL_W = 8, 144
    if mode == 'big':
        LINE0_X, LINE1_X = (280, 360), (45, 595)
    out = Path(out_dir)
    nib = load_font(mem)
    ink, lid = render_text(nib)
    slots = load_slots(tf_dir)
    save(render_before(slots, ink, lid, focus), out / 'before_T9.png')
    crgb, cflg = build_cache(slots, ink, lid)
    after = render_after(crgb, cflg, focus)
    save(after, out / 'after_T10.png')
    save(after, out / 'after_T10_x2.png', 2)
    print('ok', out)


if __name__ == '__main__':
    main()
