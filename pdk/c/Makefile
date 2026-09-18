# Build a bario module written in C.
#
#   make MODULE=mymodule
#
# Needs a clang that can link wasm — the wasi-sdk is the usual way to get one:
#   brew install wasi-sdk    (or download from github.com/WebAssembly/wasi-sdk)
#
# Apple's /usr/bin/clang can *compile* wasm32 but ships no wasm-ld, so it cannot link.

MODULE ?= example
CC     ?= $(shell command -v wasi-clang 2>/dev/null || echo /opt/wasi-sdk/bin/clang)
CFLAGS ?= --target=wasm32 -nostdlib -O2 -Wall -Wextra
LDFLAGS ?= -Wl,--no-entry -Wl,--export-dynamic -Wl,--allow-undefined

$(MODULE).wasm: $(MODULE).c bario.c bario.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(MODULE).c bario.c

clean:
	rm -f *.wasm

.PHONY: clean
