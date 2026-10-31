"""T10 仿真期望值：调用 doc/mockup/thumb_model.py（big 模式）导出 SDRAM 预置、缓存与整帧。

用法：python -I -X utf8 gen_vectors.py <tf_card目录> <big.mem> <输出目录>
输出：sdram_slots.mem（3x307200 字）、cache_<mask>.mem、frame_<mask>_f<focus>.mem
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'doc' / 'mockup'))
import thumb_model as tm  # noqa: E402

CASES = {'111': (1, 1, 1), '101': (1, 0, 1)}
FRAMES = [('111', 0), ('111', 1), ('111', 2), ('101', 0), ('101', 1)]


def main():
    tf_dir, mem, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    # 与 thumb_model.main() 的 big 模式相同的全局设置
    tm.LABEL_X0, tm.LABEL_W = 8, 144
    tm.LINE0_X, tm.LINE1_X = (280, 360), (45, 595)
    ink, lid = tm.render_text(tm.load_font(mem))
    slots = tm.load_slots(tf_dir)
    with open(out / 'sdram_slots.mem', 'w') as f:
        for img in slots:
            for y in range(tm.H):
                for x in range(tm.W):
                    r, g, b = (int(v) for v in img[y, x])
                    f.write('%02x%02x%02x00\n' % (r, g, b))
    caches = {}
    for name, valid in CASES.items():
        caches[name] = tm.build_cache(slots, ink, lid, valid)
        tm.export_cache_mem(*caches[name], out / ('cache_%s.mem' % name))
    for name, focus in FRAMES:
        frame = tm.render_after(*caches[name], focus, CASES[name])
        tm.export_frame_mem(frame, out / ('frame_%s_f%d.mem' % (name, focus)))
        if name == '111' and focus == 1:
            tm.save(frame, out / 'frame_111_f1.png')
    print('ok', out)


if __name__ == '__main__':
    main()
