# 独立 Python 64 位模型，对照 103.c do_mul / do_div 语义核对重新生成的用例。
# 用法: py -3 oracle-mul-div.py <input.103> <output.103> mul|div
import re
import sys

WORD_RE = re.compile(r'^([0-7]{4})@\s*([+-])([0-7]{10})\s*$')


def parse_words(path):
    words = {}
    for line in open(path, encoding="utf-8"):
        m = WORD_RE.match(line.strip())
        if m:
            addr = int(m.group(1), 8)
            sign = -1 if m.group(2) == "-" else 1
            val = int(m.group(3), 8)
            words[addr] = (sign, val)
    return words


def fmt(sign, val):
    return f"{'+' if sign >= 0 else '-'}{val:010o}"


def main():
    inp, outp, kind = sys.argv[1], sys.argv[2], sys.argv[3]
    words = parse_words(inp)
    base = 0o3000
    pairs = []
    i = base
    while i in words and (i + 1) in words:
        pairs.append((words[i], words[i + 1]))
        i += 2

    oracle = []
    for (sa, a), (sb, b) in pairs:
        if kind == "mul":
            res = (b * a) >> 30
            s = sa * sb
        else:
            res = (b << 30) // a
            s = sa * sb
        res &= 0x3FFFFFFF
        oracle.append(fmt(s, res))

    out_lines = [l.strip() for l in open(outp, encoding="utf-8") if l.strip()]
    print(f"pairs={len(pairs)}  output_lines={len(out_lines)}")
    print("--- 前 8 条 oracle ---")
    for v in oracle[:8]:
        print(v)
    print("--- 前 8 条 simulator 输出 ---")
    for v in out_lines[:8]:
        print(v)

    # 逐条顺序核对：oracle[k] 应出现在输出序列中；统计命中/缺失
    missing = [v for v in oracle if v not in out_lines]
    print(f"\noracle 结果在输出中缺失: {len(missing)} / {len(oracle)}")
    for v in missing[:10]:
        print("  MISS", v)

    # 顺序对齐核对（按输出前 len(oracle) 行）
    aligned = sum(1 for k, v in enumerate(oracle) if k < len(out_lines) and out_lines[k] == v)
    print(f"顺序对齐命中: {aligned} / {min(len(oracle), len(out_lines))}")


if __name__ == "__main__":
    main()
