# rundird

A simple daemon and PAM module providing the XDG_RUNTIME_DIR of the
[freedesktop.org base directory spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

*Note: this software is considered to be experimental and unstable, use at
your own risk*

## Building

rundird currently depends on the zig master branch, last tested at commit
`1eaf069`. When zig 0.7.0 is released, rundird will stick with that version.

In addition to zig, you will need the development headers for PAM
installed. Then run, for example:

```
zig build -Drelease-safe=true --prefix /usr install
```

## PAM configuration

To enable the pam module, add the following recommended configuration to
`/etc/pam.d/login`:

```
session		optional	pam_rundird.so
```

See also `pam.conf(5)`.
