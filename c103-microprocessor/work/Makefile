CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Iengine -I../../../simulator/src_c

# 原型自检：引擎 FSM 独立模型
ENGINE_OBJS = engine/copy_engine.o tb/test_engine.o

# 集成测试：引擎桥接模拟器 machine_mem
INTEG_OBJS = engine/copy_engine.o engine/engine_bridge.o tb/test_integration.o ../../../simulator/src_c/103.o

all: test_engine test_integration

test_engine: $(ENGINE_OBJS)
	$(CC) $(CFLAGS) $(ENGINE_OBJS) -o $@

test_integration: $(INTEG_OBJS)
	$(CC) $(CFLAGS) $(INTEG_OBJS) -o $@

engine/%.o: engine/%.c
	$(CC) $(CFLAGS) -c $< -o $@

tb/%.o: tb/%.c
	$(CC) $(CFLAGS) -c $< -o $@

../../../simulator/src_c/103.o: ../../../simulator/src_c/103.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f engine/*.o tb/*.o ../../../simulator/src_c/103.o test_engine test_engine.exe test_integration test_integration.exe

.PHONY: all clean
