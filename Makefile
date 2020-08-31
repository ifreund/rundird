PREFIX ?= /usr

all: xdg-runtime-dir
	
xdg-runtime-dir: xdg_runtime_dir.zig
	zig build-lib -dynamic -fPIC -lc -lpam xdg_runtime_dir.zig

install: xdg-runtime-dir
	install -Dm644 libxdg_runtime_dir.so.0.0.0 $(PREFIX)/lib/security/xdg-runtime-dir.so

uninstall:
	rm $(PREFIX)/lib/security/xdg-runtime-dir.so
