CC = ldc2
CFLAGS = -betterC -mscrtlib=msvcrt
OUT = build

# Build config lives in nobd.d now, not here — see it for why (short version:
# building D in D is more powerful and pleasant than Makefile syntax, in the
# spirit of tsoding/nob.h). make's only remaining job is the one bootstrapping
# step every nob-style tool needs: (re)compile nobd whenever nobd.d changes —
# ordinary mtime-prerequisite tracking, the one thing make is unambiguously
# good at — then hand off to it for everything else.
# -i pulls in every module nobd.d imports (dnr.process, dnr.fs, ...) without
# listing them by hand; -Isrc is where those dnr.* modules live.
$(OUT)/nobd: nobd.d
	$(CC) $(CFLAGS) -i -Isrc nobd.d -of $(OUT)/nobd

test: $(OUT)/nobd
	./$(OUT)/nobd test

check: $(OUT)/nobd
	./$(OUT)/nobd check

.PHONY: test check
