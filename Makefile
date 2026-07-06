CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Wpedantic
CFLAGS  += -D_DARWIN_C_SOURCE -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L

BIN    = silicadbd silica
COMMON = src/wire.o src/store.o
HDRS   = src/proto.h src/wire.h src/store.h

all: $(BIN)

silicadbd: src/silicadbd.o $(COMMON)
	$(CC) $(CFLAGS) -o $@ src/silicadbd.o $(COMMON)

silica: src/silica.o $(COMMON)
	$(CC) $(CFLAGS) -o $@ src/silica.o $(COMMON)

src/%.o: src/%.c $(HDRS)
	$(CC) $(CFLAGS) -c -o $@ $<

check: all
	sh scripts/smoke.sh

clean:
	rm -f $(BIN) src/*.o

.PHONY: all check clean
