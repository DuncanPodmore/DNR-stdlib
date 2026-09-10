CC = ldc2
# betterC, MSVC runtime — same toolchain as the Dopashooter game. No external
# libraries: dnr-std is pure D over core.stdc. No globbing — every module is
# listed, same discipline as the game's makefile.
CFLAGS = -betterC -mscrtlib=msvcrt
OUT = build

LIB_SRC  = src/dnr/mem.d src/dnr/array.d src/dnr/algo.d src/dnr/math.d src/dnr/rng.d src/dnr/str.d src/dnr/testing.d
TEST_SRC = $(LIB_SRC) src/dnr/mem_test.d src/dnr/array_test.d src/dnr/algo_test.d src/dnr/math_test.d src/dnr/rng_test.d src/dnr/str_test.d src/test_all.d

test: $(TEST_SRC)
	$(CC) $(CFLAGS) $(TEST_SRC) -of $(OUT)/test
	./$(OUT)/test

# Type-check the library on its own (no test code, no main).
check: $(LIB_SRC)
	$(CC) $(CFLAGS) -o- $(LIB_SRC)

.PHONY: test check
