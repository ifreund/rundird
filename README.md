# rundird

A simple daemon and PAM module providing the XDG_RUNTIME_DIR of the
[freedesktop.org base directory spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

*Note: this software is considered to be experimental and unstable, use at
your own risk*

## PAM configuration

The recommended pam configuration is:

```
session		optional	pam_rundird.so
```

See also `pam.conf(5)`.
