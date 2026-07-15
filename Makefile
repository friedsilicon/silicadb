all:
	zig build

test:
	zig build test

check: all
	BIN=zig-out/bin sh scripts/smoke.sh

clean:
	rm -rf zig-out .zig-cache

.PHONY: all test check clean
