PREFIX ?= /usr
ZIG ?= zig

all: rundird pam_rundird

rundird: rundird.zig
	$(ZIG) build-exe -lc rundird.zig

pam_rundird: pam_rundird.zig
	$(ZIG) build-lib -dynamic -fPIC -lc -lpam pam_rundird.zig

install: rundird pam_rundird
	install -Dm755 rundird $(PREFIX)/bin/rundird
	install -Dm644 libpam_rundird.so.0.0.0 $(PREFIX)/lib/security/pam_rundird.so

uninstall:
	rm $(PREFIX)/lib/security/pam_rundird.so
	rm $(PREFIX)/bin/rundird
