PREFIX ?= /usr

all: rundird pam_rundird

pam_rundird: pam_rundird.zig
	zig build-lib -dynamic -fPIC -lc -lpam pam_rundird.zig

rundird: rundird.zig
	zig build-exe -lc rundird.zig

install: pam_rundird
	install -Dm644 libpam_rundird.so.0.0.0 $(PREFIX)/lib/security/pam_rundird.so

uninstall:
	rm $(PREFIX)/lib/security/pam_rundird.so
