# rundird

A simple daemon and PAM module providing the XDG_RUNTIME_DIR of the
[freedesktop.org base directory spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

*Note: this software is considered to be experimental and unstable, use at
your own risk*

## Building

rundird depends on [zig](https://ziglang.org) 0.7.0 and PAM. To build and install
the daemon to `/usr/`:

```
zig build -Drelease-safe=true --prefix /usr/ install
```

## PAM configuration

To enable the pam module, add the following recommended configuration to
`/etc/pam.d/login`:

```
session		optional	libpam_rundird.so
```

See also `pam.conf(5)`.
