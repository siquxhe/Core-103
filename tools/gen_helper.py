# 用固定种子执行 test-program 下的 helper.py，使重新生成的用例可复现。
# 用法: py -3 gen_helper.py <helper.py 路径> <seed>
import random
import sys

if len(sys.argv) != 3:
    sys.stderr.write("usage: gen_helper.py <helper.py> <seed>\n")
    sys.exit(1)

random.seed(int(sys.argv[2]))
with open(sys.argv[1], "r", encoding="utf-8") as f:
    exec(f.read())
