# rundird

A simple daemon and PAM module providing the XDG_RUNTIME_DIR of the
[freedesktop.org base directory spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

## Building

rundird requires [zig](https://ziglang.org) 0.8 and PAM. To build and install
the daemon to `/usr` run:

```
zig build -Drelease-safe --prefix /usr install
```

## PAM configuration

To enable the pam module, add the following recommended configuration to
`/etc/pam.d/login`:

```
session		optional	pam_rundird.so
```

See also `pam.conf(5)`.
