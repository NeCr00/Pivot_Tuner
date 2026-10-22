# SSH Pivot Tune

**Reversible Linux tuning for SSH SOCKS proxies.**  
Adjusts TCP settings and existing SSH workers’ open-file limits. No Python or pip required.

##  Quick start

Copy `ssh-pivot-tune.sh` to the pivot host.

**1. Connect from your workstation**

```bash
ssh -D 127.0.0.1:1090 user@IP
```

**2. Apply tuning inside the SSH session, on the pivot**

```bash
sudo bash ssh-pivot-tune.sh apply
```

Configure your applications to use **SOCKS5 → `127.0.0.1:1090`**. Keep the SSH session open.

## Restore

Stop proxied traffic first, then run on the pivot:

```bash
sudo bash ssh-pivot-tune.sh restore
```

##  Essentials

- **Requirements:** Linux, root, Bash 4+, `sysctl`, `prlimit`, `flock`, `awk`, and coreutils.
- **New connections:** run `apply` again for each new SSH worker. Some TCP changes require reconnecting, then reapplying.
- **Runtime only:** keep `/run/ssh-pivot-tune` until restore completes. Failed or conflicting restores retain records for retry.
- **Exit codes:** `0` complete · `1` error · `2` partial—review the warnings.

**More options:** `bash ssh-pivot-tune.sh --help`
