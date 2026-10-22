#!/usr/bin/env bash
# Runtime tuning for a Linux OpenSSH SOCKS pivot. No Python/pip dependencies.
# Usage on the PIVOT: sudo bash ssh-pivot-tune.sh apply | restore
# Apply network settings before a fresh transport; apply again for its worker.
# Stop proxied workloads before restore; see --defer-live-limits for busy hosts.
# Requires Bash 4+, procps sysctl, util-linux prlimit/flock, and coreutils/awk.
# References: https://docs.kernel.org/networking/ip-sysctl.html
#             https://man7.org/linux/man-pages/man1/prlimit.1.html
#             https://man.openbsd.org/ssh_config

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
shopt -s nullglob
STATE_DIR=/run/ssh-pivot-tune
PROC_ROOT=/proc
warnings=0 changed=0 workers=0
pid_filter='' uid_filter='' nofile_override='' rmem_override='' wmem_override=''
defer_live=0 adopt_legacy=0

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
number() { [[ $1 =~ ^(0|[1-9][0-9]*)$ ]]; }
limit_value() { number "$1" || [[ $1 == unlimited ]]; }
# Decimal comparison also handles unsigned sysctl values above Bash's INT64_MAX.
uint_lt() {
    if (( ${#1} != ${#2} )); then (( ${#1} < ${#2} )); else [[ $1 < $2 ]]; fi
}

parse_args() {
    local option value maximum
    local -A seen=()
    action=${1:-}; [[ $action == apply || $action == restore ]] || { help_text >&2; exit 1; }
    shift
    while (( $# )); do
        option=$1
        [[ -n $option ]] || die 'Empty option.'
        [[ ! ${seen[$option]+yes} ]] || die "Repeated option: $option"
        seen[$option]=1
        case $option in
            --pid|--uid|--nofile|--tcp-rmem-max|--tcp-wmem-max)
                [[ $action == apply ]] || die "$option is only valid with apply."
                (( $# >= 2 )) || die "Missing value for $option"
                value=$2; maximum=2147483647
                [[ $option != --uid ]] || maximum=4294967294
                number "$value" && ! uint_lt "$maximum" "$value" || die "Invalid numeric value for $option"
                [[ $option == --uid || $value != 0 ]] || die "$option must be greater than zero."
                case $option in
                    --pid) pid_filter=$value ;;
                    --uid) uid_filter=$value ;;
                    --nofile) nofile_override=$value ;;
                    --tcp-rmem-max|--tcp-wmem-max)
                        ! uint_lt "$value" 65536 || die "$option must be at least 65536 bytes."
                        if [[ $option == --tcp-rmem-max ]]; then rmem_override=$value; else wmem_override=$value; fi ;;
                esac
                shift 2 ;;
            --defer-live-limits)
                [[ $action == restore ]] || die "$option is only valid with restore."
                defer_live=1; shift ;;
            --adopt-legacy-state) adopt_legacy=1; shift ;;
            *) die "Unknown option: $option" ;;
        esac
    done
    [[ -z $pid_filter || -z $uid_filter ]] || die 'Choose either --pid or --uid.'
}

validate_namespaces() {
    local proc_pidns
    boot=$(< "$PROC_ROOT/sys/kernel/random/boot_id")
    netns=$(readlink -- "$PROC_ROOT/self/ns/net") || die 'Cannot identify network namespace.'
    pidns=$(readlink -- "$PROC_ROOT/self/ns/pid") || die 'Cannot identify PID namespace.'
    proc_pidns=$(readlink -- "$PROC_ROOT/1/ns/pid") || die 'Cannot identify the /proc PID view.'
    [[ -n $pidns && $pidns == "$proc_pidns" ]] ||
        die '/proc and caller use different PID namespaces; no tuning is safe in this view.'
    # stat starttime is adjusted to the reader's time namespace on newer Linux.
    timens=unavailable
    if [[ -L $PROC_ROOT/self/ns/time ]]; then
        timens=$(readlink -- "$PROC_ROOT/self/ns/time") || die 'Cannot identify time namespace.'
    fi
    [[ -n $boot && -n $netns && -n $timens ]] || die 'Incomplete namespace identity.'
}

check_context() {
    local file pending_pid=0 pending_any=0
    local -a context
    for file in "$STATE_DIR/sysctl/"* "$STATE_DIR/limits/"*; do
        [[ $file != *.tmp ]] || continue
        pending_any=1
        [[ $file != "$STATE_DIR/limits/"* ]] || pending_pid=1
    done
    if [[ ! -e $STATE_DIR/context ]]; then
        (( pending_any == 0 )) || die 'Context missing while rollback records exist; refusing to infer their owner.'
    else
        mapfile -t context < "$STATE_DIR/context" || die 'Cannot read saved context.'
        if [[ ${#context[@]} == 2 ]]; then
            [[ ${context[0]} == "$boot" && ${context[1]} == "$netns" ]] ||
                die 'Legacy state belongs to a different boot/network namespace.'
            if (( pending_pid && ! adopt_legacy )); then
                die 'Legacy state lacks PID/time namespace identity. Only in its ORIGINAL PID/time namespaces, rerun with --adopt-legacy-state. Records were preserved.'
            fi
            if (( pending_pid )); then say 'INFO: Explicitly adopting legacy records in the current PID/time namespaces.'; fi
        else
            [[ ${#context[@]} == 5 && ${context[0]} == v2 && ${context[1]} == "$boot" &&
               ${context[2]} == "$netns" && ${context[3]} == "$pidns" && ${context[4]} == "$timens" ]] ||
                die 'Saved state belongs to a different boot/network/PID/time namespace or unsupported format; records preserved.'
            return 0
        fi
    fi
    record "$STATE_DIR/context" v2 "$boot" "$netns" "$pidns" "$timens"
}

help_text() {
    cat <<'HELP'
Usage: sudo bash ssh-pivot-tune.sh apply [options]
       sudo bash ssh-pivot-tune.sh restore [options]

apply   Raise TCP autotuning ceilings and limits of existing authenticated
        SSH workers. Preserve higher settings and the first saved baseline.
restore Restore saved values. Stop proxied traffic first. Conflicting edits,
        busy workers, and failed restores retain their records for retry.

Apply options (plain apply uses automatic defaults):
  --pid PID              Tune one authenticated SSH worker.
  --uid UID              Tune authenticated SSH workers with this numeric UID.
                         Choose at most one selector. Default: all recognized
                         workers in the current network namespace.
  --nofile N             Requested per-worker open-file soft-limit floor.
  --tcp-rmem-max BYTES   Requested TCP receive-autotuning ceiling floor.
  --tcp-wmem-max BYTES   Requested TCP send-autotuning ceiling floor.
                         Buffer values are decimal bytes, at least 65536.
                         All targets only raise values; they are not caps.

Restore option:
  --defer-live-limits     Restore sysctls, but retain changed worker limits
                         until those workers exit. Rerun restore afterward.

Either action:
  --adopt-legacy-state    Adopt old PID records ONLY when running in the same
                         PID/time namespaces that created them. Old records
                         cannot verify this. Known namespace mismatches still
                         fail. Use only if upgrading an already-applied copy.

Run on the Linux pivot as root; requires Bash 4+, sysctl, prlimit, flock,
awk and coreutils. No Python, pip, daemon restart or configuration-file edit.
Changes are runtime-only. Records live in /run/ssh-pivot-tune; keep them until
restore completes. Normally a reboot resets both the changes and the records.

Recommended order:
  1. From an existing administrative connection, run apply on the pivot.
  2. Open a fresh SSH transport from your workstation, for example:
  ssh -NT -D 127.0.0.1:1090 -o ControlPath=none -o Compression=no \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=6 user@IP
  3. In the administrative connection, run apply again for the new worker.
     Keep the administrative connection available for restore.

An existing SSH TCP connection may need replacement after increasing receive
ceilings or enabling window scaling: its negotiated window scale cannot be
renegotiated. New SSH workers need a new apply; no watcher/service is installed.
Existing shells/descendants are not modified directly. Later children may
inherit raised limits; this script does not track those children for restore.

Automatic floors: TCP maxima 4/8/16 MiB for a visible memory budget below
1/below 4/at least 4 GiB; worker nofile 4096 below 1 GiB, else 8192, bounded
by fs.nr_open. The smallest selected worker's budget sets the TCP profile.
Incomplete cgroup visibility limits the policy budget to at most 512 MiB;
this is not a measured limit. Below 64 MiB visible headroom, automatic buffer
and affected-worker limit increases are skipped. Explicit targets override
that guard with a warning. Current larger values are always preserved.

System file-max planning uses current allocation, selected workers' planned
FD growth, and a reserve of max(1024, 10% of allocation). It is an estimate,
not a reservation. TCP maxima allow growth; memory is not preallocated.
Sysctls affect the network namespace/host, even when a PID/UID selector is used.
Restore replays ALL saved changes, not only the most recently selected worker.
Stop new proxied traffic before normal restore; descriptor checks are a
snapshot and cannot eliminate races with a live process. Use the defer option
if traffic cannot be stopped. It intentionally returns partial until retry.

These are conservative starting floors, not benchmarked maximum capacity.
Bound application concurrency, keep client file limits sufficient, use remote
DNS when needed (SOCKS5 hostname mode), and measure client/server CPU, memory,
loss, RTT and socket queues. CPU quota, SSH channel behavior and application
timeouts cannot be fixed by enlarging kernel limits. No zero-drop guarantee.

Exit status: 0 completed; 1 fatal error; 2 partial result requiring attention.
HELP
}

secure_dir() {
    [[ ! -L $1 ]] || die "Refusing symlink directory: $1"
    [[ -e $1 ]] || mkdir -m 700 -- "$1"
    [[ -d $1 && $(stat -c '%u:%a' -- "$1") == 0:700 ]] ||
        die "State directory must be root-owned with mode 700: $1"
}

# Write the baseline BEFORE changing the host. Never source/eval saved data.
record() {
    local file=$1; shift
    [[ ! -L $file && ! -L $file.tmp ]] || die "Refusing symlink record: $file"
    printf '%s\n' "$@" > "$file.tmp" && mv -f -- "$file.tmp" "$file" ||
        die "Cannot commit rollback record: $file"
}

get_sysctl() { sysctl -n "$1" | awk '{$1=$1; print}'; }

# Accept original-format records. New records also retain the value observed
# before an in-flight write, so failed profile updates remain recoverable.
read_sysctl_record() {
    local file=$1 value
    local -a saved
    mapfile -t saved < "$file" || die "Cannot read record: $file"
    [[ ${#saved[@]} == 2 || ${#saved[@]} == 3 ]] || die "Invalid record: $file"
    for value in "${saved[@]}"; do
        [[ $value =~ ^[0-9]+(\ [0-9]+)*$ ]] || die "Invalid record: $file"
    done
    journal_original=${saved[0]}; journal_target=${saved[1]}
    journal_previous=${saved[2]:-${saved[1]}}
}

read_limit_record() {
    local file=$1 value
    local -a saved
    mapfile -t saved < "$file" || die "Cannot read record: $file"
    [[ ${#saved[@]} == 4 || ${#saved[@]} == 6 ]] || die "Invalid record: $file"
    for value in "${saved[@]}"; do limit_value "$value" || die "Invalid record: $file"; done
    journal_original="${saved[0]} ${saved[1]}"
    journal_target="${saved[2]} ${saved[3]}"
    journal_previous="${saved[4]:-${saved[2]}} ${saved[5]:-${saved[3]}}"
}

owned_value() {
    [[ $1 == "$journal_original" || $1 == "$journal_target" || $1 == "$journal_previous" ]]
}

check_sysctl_owner() {
    local key=$1 current=$2 file="$STATE_DIR/sysctl/$1"
    [[ -f $file ]] || return 0
    read_sysctl_record "$file"
    if ! owned_value "$current"; then
        warn "$key changed outside this script; left unchanged; rollback record retained."
        return 1
    fi
}

set_tunable() {
    local key=$1 desired=$2 expected=$3 current original file="$STATE_DIR/sysctl/$1"
    current=$(get_sysctl "$key") || { warn "Cannot read $key; skipped."; return; }
    [[ $current == "$expected" ]] || { warn "$key changed during inspection; rerun apply."; return; }
    check_sysctl_owner "$key" "$current" || return 0
    [[ $current != "$desired" ]] || return 0
    original=$current
    if [[ -f $file ]]; then
        read_sysctl_record "$file"; original=$journal_original
    fi
    record "$file" "$original" "$desired" "$current"
    if sysctl -q -w "$key=$desired" &&
       [[ $(get_sysctl "$key") == "$desired" ]]; then
        record "$file" "$original" "$desired" "$desired"
        say "SET $key: $current -> $desired"
        changed=$((changed + 1))
    else
        warn "Could not set/verify $key; rollback record retained."
    fi
}

raise_scalar() {
    local current
    current=$(get_sysctl "$1") || { warn "Cannot read $1; skipped."; return; }
    number "$current" || { warn "Unexpected value for $1; skipped."; return; }
    check_sysctl_owner "$1" "$current" || return 0
    if uint_lt "$current" "$2"; then set_tunable "$1" "$2" "$current"; fi
}

raise_tcp_max() {
    local key=$1 target=${2:-$buffer_max} current value
    local -a values
    current=$(get_sysctl "$key") || { warn "Cannot read $key; skipped."; return; }
    read -r -a values <<< "$current"
    [[ ${#values[@]} == 3 ]] || { warn "Unexpected $key; skipped."; return; }
    for value in "${values[@]}"; do
        number "$value" || { warn "Invalid $key; skipped."; return; }
    done
    check_sysctl_owner "$key" "$current" || return 0
    if uint_lt "${values[2]}" "$target"; then
        set_tunable "$key" "${values[0]} ${values[1]} $target" "$current"
    fi
}

start_time() {
    local data
    local -a fields
    IFS= read -r data < "$PROC_ROOT/$1/stat" 2>/dev/null || return 1
    read -r -a fields <<< "${data##*) }"
    number "${fields[19]:-}" || return 1
    printf '%s\n' "${fields[19]}"
}

is_worker() {
    local pid=$1 name title='' exe ns
    IFS= read -r name < "$PROC_ROOT/$pid/comm" 2>/dev/null || return 1
    case $name in sshd|sshd-session) ;; *) return 1 ;; esac
    exe=$(readlink -- "$PROC_ROOT/$pid/exe") || return 1
    exe=${exe% (deleted)}
    case ${exe##*/} in sshd|sshd-session) ;; *) return 1 ;; esac
    ns=$(readlink -- "$PROC_ROOT/$pid/ns/net") || return 1
    [[ $ns == "$netns" ]] || return 1
    IFS= read -r -d '' title < "$PROC_ROOT/$pid/cmdline" || :
    case $title in 'sshd: '*|'sshd-session: '*) ;; *) return 1 ;; esac
    title=${title#*: }
    # Plain username is normal for -N -D. Preauth/monitor/listener titles
    # contain spaces or begin with [accepted]/[rexeced]/[net]. Never tune them.
    [[ -n $title && $title != *[[:space:]]* && $title != \[* ]]
}

get_limits() {
    awk '/^Max open files[[:space:]]/ {print $4, $5; found=1; exit}
         END {if (!found) exit 1}' "$PROC_ROOT/$1/limits" 2>/dev/null
}

apply_worker() {
    local pid=$1 expected_start=$2 fd_target=$3 start current soft hard newhard file fd_desired original_soft original_hard
    start=$(start_time "$pid") || return 0
    [[ $start == "$expected_start" ]] && is_worker "$pid" ||
        { warn "SSH PID $pid changed after resource planning; rerun apply."; return; }
    if [[ -n $uid_filter && $(worker_uid "$pid") != "$uid_filter" ]]; then
        warn "SSH PID $pid no longer matches the requested UID; skipped."; return
    fi
    current=$(get_limits "$pid") || { warn "Cannot read limits for PID $pid."; return; }
    read -r soft hard <<< "$current"
    limit_value "$soft" && limit_value "$hard" || { warn "Invalid limits for PID $pid."; return; }
    workers=$((workers + 1))
    file="$STATE_DIR/limits/$pid.$start"
    original_soft=$soft; original_hard=$hard
    if [[ -f $file ]]; then
        read_limit_record "$file"
        if ! owned_value "$current"; then
            warn "SSH PID $pid limits changed outside this script; skipped; record retained."; return
        fi
        read -r original_soft original_hard <<< "$journal_original"
    fi
    if [[ $soft == unlimited ]] || ! uint_lt "$soft" "$fd_target"; then
        say "KEEP SSH PID $pid: nofile $soft:$hard"; return
    fi
    newhard=$hard
    if [[ $hard != unlimited ]] && uint_lt "$hard" "$fd_target"; then newhard=$fd_target; fi
    fd_desired=$fd_target
    [[ $(start_time "$pid") == "$start" ]] && is_worker "$pid" ||
        { warn "SSH PID $pid changed during inspection; rerun apply."; return; }
    [[ $(get_limits "$pid") == "$current" ]] ||
        { warn "SSH PID $pid limits changed during inspection; rerun apply."; return; }
    if [[ -n $uid_filter && $(worker_uid "$pid") != "$uid_filter" ]]; then
        warn "SSH PID $pid no longer matches the requested UID; skipped."; return
    fi
    record "$file" "$original_soft" "$original_hard" "$fd_desired" "$newhard" "$soft" "$hard"
    if prlimit --pid "$pid" --nofile="$fd_desired:$newhard" &&
       [[ $(start_time "$pid") == "$start" ]] &&
       [[ $(get_limits "$pid") == "$fd_desired $newhard" ]]; then
        record "$file" "$original_soft" "$original_hard" "$fd_desired" "$newhard" "$fd_desired" "$newhard"
        say "SET SSH PID $pid: nofile $soft:$hard -> $fd_desired:$newhard"
        changed=$((changed + 1))
    else
        warn "Could not set/verify limits for PID $pid; record retained."
    fi
}

# Read-only cgroup budgets. Uses the WORKER's membership, never our own.
# Unknown/hidden constraints are reported; 512 MiB is a policy budget, not
# a discovered limit. Requires existing say(), number(), ram_kb, available_kb.
resource_path_ok() {
    [[ $1 == /* && $1 != *[[:cntrl:]]* ]] || return 1
    [[ $1 != / ]] || return 0
    case "$1/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
}

resource_mount_decode() {
    local value=$1
    case $value in *\\011*|*\\012*) return 1 ;; esac
    value=${value//\\040/ }; value=${value//\\011/$'\t'}
    value=${value//\\012/$'\n'}; value=${value//\\134/\\}
    printf '%s' "$value"
}

# Set caller-local cg_dir/cg_base/cg_root; prefer the widest visible hierarchy.
resource_mount() {
    local kind=$1 path=$2 line root base relative resolved i fs options
    local -a fields
    cg_dir=''; cg_base=''; cg_root=''
    resource_path_ok "$path" || return 1
    [[ -r $PROC_ROOT/self/mountinfo ]] || return 1
    while IFS= read -r line; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 10 )) || continue
        for ((i=6; i+3<${#fields[@]}; i++)); do
            [[ ${fields[i]} != - ]] || break
        done
        (( i+3 < ${#fields[@]} )) || continue
        fs=${fields[i+1]}; options=,${fields[i+3]},
        if [[ $kind == v2 ]]; then
            [[ $fs == cgroup2 ]] || continue
        else
            [[ $fs == cgroup && $options == *",$kind,"* ]] || continue
        fi
        root=$(resource_mount_decode "${fields[3]}") || continue
        base=$(resource_mount_decode "${fields[4]}") || continue
        resource_path_ok "$root" && resource_path_ok "$base" || continue
        if [[ $root == / ]]; then relative=${path#/}
        elif [[ $path == "$root" ]]; then relative=''
        elif [[ $path == "$root/"* ]]; then relative=${path#"$root/"}
        else continue; fi
        base=$(readlink -e -- "$base" 2>/dev/null) || continue
        resolved=$(readlink -e -- "$base/$relative" 2>/dev/null) || continue
        [[ -d $resolved && ( $resolved == "$base" || $resolved == "${base%/}/"* ) ]] || continue
        if [[ -z $cg_dir ]] || (( ${#root} < ${#cg_root} )); then
            cg_dir=$resolved; cg_base=$base; cg_root=$root
        fi
    done 2>/dev/null < "$PROC_ROOT/self/mountinfo"
    [[ -n $cg_dir ]]
}

# Exact decimal subtraction/division; never feed huge kernel limits to Bash
# arithmetic or subtract rounded awk floating-point representations.
resource_bounds() {
    awk -v limit="$1" -v used="$2" -v ceiling="$ram_kb" '
    function less(a,b) {
        return length(a)!=length(b) ? length(a)<length(b) : "x" a < "x" b
    }
    function subtract(a,b, i,j,d,borrow,out) {
        j=length(b); borrow=0; out=""
        for (i=length(a); i>0; i--) {
            d=substr(a,i,1)-(j>0 ? substr(b,j--,1) : 0)-borrow
            borrow=(d<0); if (borrow) d+=10
            out=d out
        }
        sub(/^0+/,"",out); return out=="" ? "0" : out
    }
    function kib(n, i,remainder,d,out) {
        remainder=0; out=""
        for (i=1; i<=length(n); i++) {
            remainder=remainder*10+substr(n,i,1)
            d=int(remainder/1024); remainder%=1024
            if (out!="" || d) out=out d
        }
        if (out=="") out="0"
        return less(out,ceiling) ? out : ceiling
    }
    BEGIN { print kib(limit), less(used,limit) ? kib(subtract(limit,used)) : 0 }'
}

inspect_worker_resources() {
    local pid=$1 id controllers path v2='' memory='' cpu='' kind unknown=0
    local cg_dir cg_base cg_root dir file limit usage math_usage cap head seen=0
    local quota period extra pressure cpu_seen=0
    local -a memory_files
    resource_cap_kb=$ram_kb; resource_headroom_kb=$available_kb
    if [[ -r $PROC_ROOT/$pid/cgroup ]]; then
        while IFS=: read -r id controllers path; do
            if [[ $id == 0 && -z $controllers ]]; then v2=$path; fi
            [[ ,$controllers, != *,memory,* ]] || memory=$path
            [[ ,$controllers, != *,cpu,* ]] || cpu=$path
        done 2>/dev/null < "$PROC_ROOT/$pid/cgroup" || unknown=1
    fi
    if [[ -n $memory ]]; then
        kind=memory; path=$memory; memory_files=(memory.limit_in_bytes)
    else
        kind=v2; path=$v2; memory_files=(memory.max memory.high)
    fi
    if resource_mount "$kind" "$path"; then
        say "INFO SSH PID $pid: visible $kind cgroup $cg_dir."
        if [[ $cg_root != / || ( $kind == v2 &&
              ( -e $cg_base/memory.max || -e $cg_base/cgroup.type || -e $cg_base/cgroup.events ) ) ]]; then
            say "INFO SSH PID $pid: cgroup ancestors are hidden above this mount."
            unknown=1
        fi
        if [[ $kind == memory ]]; then
            say "INFO SSH PID $pid: v1 ancestor/namespace visibility is unknown."
            unknown=1
        fi
        dir=$cg_dir
        while :; do
            usage=''
            if [[ $kind == v2 ]]; then file=memory.current; else file=memory.usage_in_bytes; fi
            IFS= read -r usage 2>/dev/null < "$dir/$file" || :
            for file in "${memory_files[@]}"; do
                if [[ ! -e $dir/$file ]]; then
                    [[ $kind != memory ]] || unknown=1
                    continue
                fi
                seen=1
                if ! IFS= read -r limit 2>/dev/null < "$dir/$file"; then unknown=1; continue; fi
                [[ $limit != max ]] || continue
                if ! number "$limit"; then unknown=1; continue; fi
                math_usage=$usage
                if ! number "$usage"; then
                    unknown=1; resource_headroom_kb=0; usage=unknown; math_usage=0
                fi
                read -r cap head < <(resource_bounds "$limit" "$math_usage")
                # A sub-KiB/zero hard limit still returns a positive profile
                # capacity, with zero usable headroom.
                if [[ $file != memory.high ]]; then
                    (( cap > 0 )) || cap=1
                    if (( cap < resource_cap_kb )); then resource_cap_kb=$cap; fi
                fi
                if (( head < resource_headroom_kb )); then resource_headroom_kb=$head; fi
                say "INFO SSH PID $pid: $file=$limit bytes; usage=$usage bytes ($dir)."
            done
            [[ $dir != "$cg_base" ]] || break
            dir=${dir%/*}; [[ -n $dir ]] || dir=/
        done
        if (( ! seen )) && [[ ! -r $cg_base/cgroup.controllers ]]; then unknown=1; fi
    else unknown=1; fi
    if (( unknown )); then
        (( resource_cap_kb <= 524288 )) || resource_cap_kb=524288
        (( resource_headroom_kb <= 524288 )) || resource_headroom_kb=524288
        say "INFO SSH PID $pid: memory constraints unknown/incomplete; budget capped at 512 MiB (not a measured limit)."
    fi
    if (( resource_headroom_kb > resource_cap_kb )); then resource_headroom_kb=$resource_cap_kb; fi
    say "INFO SSH PID $pid: memory capacity budget ${resource_cap_kb} KiB; available headroom ${resource_headroom_kb} KiB."

    # Hybrid systems may put CPU and memory on different hierarchies.
    if [[ -n $cpu ]]; then kind=cpu; path=$cpu; else kind=v2; path=$v2; fi
    if resource_mount "$kind" "$path"; then
        dir=$cg_dir
        for file in memory.pressure cpu.pressure; do
            if IFS= read -r pressure 2>/dev/null < "$dir/$file"; then
                say "INFO SSH PID $pid: $file $pressure"
            fi
        done
        while :; do
            quota=''; period=''; extra=''
            if [[ $kind == v2 ]]; then
                read -r quota period extra 2>/dev/null < "$dir/cpu.max" || :
            else
                IFS= read -r quota 2>/dev/null < "$dir/cpu.cfs_quota_us" || :
                IFS= read -r period 2>/dev/null < "$dir/cpu.cfs_period_us" || :
            fi
            if number "$quota" && number "$period" && [[ $period != 0 && -z $extra ]]; then
                say "INFO SSH PID $pid: CPU quota $quota/$period microseconds per period ($dir)."
                cpu_seen=1
            fi
            [[ $dir != "$cg_base" ]] || break
            dir=${dir%/*}; [[ -n $dir ]] || dir=/
        done
        if [[ $cg_root != / || ( $kind == v2 && -e $cg_base/cgroup.type ) ]]; then
            say "INFO SSH PID $pid: CPU quota ancestors above this mount are hidden."
        fi
    else
        say "INFO SSH PID $pid: CPU quota visibility unknown (no usable cgroup mapping)."
    fi
    if (( ! cpu_seen )); then say "INFO SSH PID $pid: no finite CPU quota visible; host CPU/affinity may still constrain throughput."; fi
}

worker_uid() {
    awk '/^Uid:/ {print $2; found=1; exit} END {if (!found) exit 1}' "$PROC_ROOT/$1/status" 2>/dev/null
}

passive_diagnostics() {
    local relative line
    for relative in sys/net/ipv4/ip_local_port_range sys/net/ipv4/ip_local_reserved_ports \
                    sys/net/netfilter/nf_conntrack_count sys/net/netfilter/nf_conntrack_max \
                    pressure/memory pressure/cpu net/sockstat; do
        if [[ -r $PROC_ROOT/$relative ]]; then
            while IFS= read -r line; do
                say "INFO $relative: $line"
            done < "$PROC_ROOT/$relative"
        fi
    done
}

# Audit saved ownership even when a low-memory guard suppresses a new increase.
audit_sysctl() {
    local current
    [[ -f $STATE_DIR/sysctl/$1 ]] || return 0
    current=$(get_sysctl "$1") || { warn "Cannot read $1; saved record retained."; return; }
    check_sysctl_owner "$1" "$current" || return 0
}

apply_all() {
    local ram_kb available_kb nr_open dir pid uid start current soft hard target open_fds
    local profile_kb resource_cap_kb resource_headroom_kb low_memory=0 buffer_max rmem_target wmem_target
    local selected_count=0 i additions=0 file_counts allocated reserve file_floor affinity
    local -a selected_pids=() selected_starts=() selected_targets=() fds=()
    ram_kb=$(awk '/^MemTotal:/ {print $2; exit}' "$PROC_ROOT/meminfo")
    number "$ram_kb" && [[ $ram_kb != 0 ]] && ! uint_lt 9223372036854775807 "$ram_kb" ||
        die 'Cannot determine physical RAM within supported integer range.'
    available_kb=$(awk '/^MemAvailable:/ {available=$2} /^MemFree:/ {free=$2}
        END {if (available!="") print available; else if (free!="") print free}' "$PROC_ROOT/meminfo")
    if ! number "$available_kb" || uint_lt 9223372036854775807 "$available_kb"; then
        available_kb=0; warn 'Memory headroom is unreadable; automatic resource increases will be limited.'
    fi
    if (( available_kb > ram_kb )); then available_kb=$ram_kb; fi
    if (( available_kb < 65536 )); then low_memory=1; fi
    profile_kb=$ram_kb
    nr_open=$(get_sysctl fs.nr_open) || die 'Cannot read fs.nr_open.'
    number "$nr_open" && [[ $nr_open != 0 ]] || die 'Invalid fs.nr_open.'
    say "INFO: physical RAM $ram_kb KiB; visible host headroom $available_kb KiB."
    # Collect a stable identity and resource plan before any host-setting write.
    for dir in "$PROC_ROOT"/[0-9]*; do
        pid=${dir##*/}
        [[ -z $pid_filter || $pid == "$pid_filter" ]] || continue
        is_worker "$pid" || continue
        start=$(start_time "$pid") || { warn "Cannot identify SSH PID $pid; skipped."; continue; }
        uid=$(worker_uid "$pid") || uid=unknown
        if [[ -n $uid_filter && $uid != "$uid_filter" ]]; then continue; fi
        current=$(get_limits "$pid") || { warn "Cannot read limits for SSH PID $pid; skipped."; continue; }
        read -r soft hard <<< "$current"
        limit_value "$soft" && limit_value "$hard" || { warn "Invalid SSH PID $pid limits; skipped."; continue; }
        inspect_worker_resources "$pid"
        if (( resource_cap_kb < profile_kb )); then profile_kb=$resource_cap_kb; fi
        target=4096
        if (( resource_cap_kb >= 1048576 )); then target=8192; fi
        if [[ -n $nofile_override ]]; then target=$nofile_override; fi
        if uint_lt "$nr_open" "$target"; then
            [[ -z $nofile_override ]] || warn "Requested nofile $target exceeds fs.nr_open=$nr_open; clamped for PID $pid."
            target=$nr_open
        fi
        if (( resource_headroom_kb < 65536 )); then
            low_memory=1
            warn "SSH PID $pid has less than 64 MiB visible memory headroom; automatic growth is skipped; explicit targets remain requested."
            [[ -n $nofile_override ]] || target=0
        fi
        selected_pids[selected_count]=$pid; selected_starts[selected_count]=$start
        selected_targets[selected_count]=$target; selected_count=$((selected_count + 1))
        open_fds=unknown
        if [[ -r $dir/fd && -x $dir/fd ]]; then
            fds=("$dir/fd/"*); open_fds=${#fds[@]}
            if (( target > open_fds )); then additions=$((additions + target - open_fds)); fi
        else
            # Count the whole planned floor when no FD snapshot is available.
            additions=$((additions + target))
            warn "Cannot count PID $pid descriptors; file-max planning assumes $target additional handles."
        fi
        say "INFO SSH PID $pid UID $uid: nofile $soft:$hard; open FDs $open_fds; requested floor $target (0 means automatic increase skipped)."
        affinity=$(awk '/^Cpus_allowed_list:/ {print $2; exit}' "$dir/status" 2>/dev/null) || affinity=''
        if [[ -n $affinity ]]; then say "INFO SSH PID $pid: allowed CPUs $affinity."; fi
    done
    if [[ -n $pid_filter ]] && (( selected_count == 0 )); then
        die "PID $pid_filter is not an inspectable authenticated SSH worker in this network namespace."
    fi
    if (( selected_count == 0 )); then
        (( profile_kb <= 524288 )) || profile_kb=524288
        say 'INFO: Future worker constraints are unknown; automatic memory policy budget is at most 512 MiB until a worker can be inspected.'
    fi
    buffer_max=4194304
    if (( profile_kb >= 1048576 )); then buffer_max=8388608; fi
    if (( profile_kb >= 4194304 )); then buffer_max=16777216; fi
    rmem_target=${rmem_override:-$buffer_max}; wmem_target=${wmem_override:-$buffer_max}
    if (( low_memory )); then
        warn 'Low visible memory headroom: automatic TCP buffer increases are skipped; explicit buffer targets override this guard.'
        [[ -n $rmem_override ]] || rmem_target=0
        [[ -n $wmem_override ]] || wmem_target=0
    fi
    say "Profile: TCP receive/send max floors $rmem_target/$wmem_target bytes; $selected_count selected SSH worker(s)."
    passive_diagnostics
    # Estimate capacity for selected workers, not every unused descriptor in
    # pre-existing higher process limits. Values are snapshots, not reservations.
    file_counts=$(get_sysctl fs.file-nr) || file_counts=''
    allocated=${file_counts%% *}
    if number "$allocated" && ! uint_lt 9223372036854775807 "$allocated"; then
        reserve=$((allocated / 10)); (( reserve >= 1024 )) || reserve=1024
        if (( allocated <= 9223372036854775807 - additions - reserve )); then
            file_floor=$((allocated + additions + reserve))
            say "INFO: file-max floor $file_floor = $allocated allocated + $additions planned growth + $reserve reserve."
            raise_scalar fs.file-max "$file_floor"
        else
            warn 'Global file-handle estimate would overflow; file-max left unchanged.'
            audit_sysctl fs.file-max
        fi
    else
        warn 'Cannot read a supported system file-handle allocation; file-max left unchanged.'
        audit_sysctl fs.file-max
    fi
    if (( rmem_target )); then raise_tcp_max net.ipv4.tcp_rmem "$rmem_target"; else audit_sysctl net.ipv4.tcp_rmem; fi
    if (( wmem_target )); then raise_tcp_max net.ipv4.tcp_wmem "$wmem_target"; else audit_sysctl net.ipv4.tcp_wmem; fi
    raise_scalar net.ipv4.tcp_moderate_rcvbuf 1
    raise_scalar net.ipv4.tcp_window_scaling 1
    raise_scalar net.ipv4.tcp_mtu_probing 1
    for ((i=0; i<selected_count; i++)); do
        apply_worker "${selected_pids[i]}" "${selected_starts[i]}" "${selected_targets[i]}"
    done
    if (( workers == 0 )); then
        warn 'No authenticated SSH workers matched the requested selection and remained inspectable. Start the tunnel, then rerun apply on the pivot.'
    fi
    say "Apply: $changed verified changes; $workers authenticated SSH workers inspected."
    say 'New receive/window settings may need a fresh SSH transport. Apply again for its new worker; existing larger limits are kept.'
}

restore_all() {
    local file key current pid start actual fd busy file_counts allocated original soft hard probe
    local -a fds
    # FD inspection is a snapshot: stop new proxied traffic before normal
    # restore. --defer-live-limits never lowers a tracked live worker's limits.
    for file in "$STATE_DIR/limits/"*; do
        [[ $file != *.tmp ]] || continue
        key=${file##*/}
        [[ $key =~ ^([0-9]+)\.([0-9]+)$ ]] || die "Invalid record: $file"
        pid=${BASH_REMATCH[1]}; start=${BASH_REMATCH[2]}
        number "$pid" && [[ $pid != 0 ]] && ! uint_lt 2147483647 "$pid" && number "$start" ||
            die "Invalid PID identity in record: $file"
        if [[ ! -d $PROC_ROOT/$pid ]]; then
            # hidepid can hide a live process in an otherwise matching procfs
            # namespace. Signal 0 only probes existence/permission; no signal
            # is sent. Only the known LC_ALL=C ESRCH diagnostic proves exit.
            if probe=$(builtin kill -0 -- "$pid" 2>&1); then
                warn "PID $pid still exists but is not visible in /proc; record retained."
            elif [[ $probe == *' - No such process' ]]; then
                rm -- "$file"
            else
                warn "Cannot establish that PID $pid exited; record retained. $probe"
            fi
            continue
        fi
        actual=$(start_time "$pid") || { warn "Cannot identify PID $pid; record retained."; continue; }
        if [[ $actual != "$start" ]]; then rm -- "$file"; continue; fi
        is_worker "$pid" || { warn "PID $pid is no longer a recognized SSH worker; record retained."; continue; }
        read_limit_record "$file"
        original=$journal_original; read -r soft hard <<< "$original"
        current=$(get_limits "$pid") || { warn "Cannot read PID $pid limits."; continue; }
        if [[ $current == "$original" ]]; then rm -- "$file"; continue; fi
        if ! owned_value "$current"; then
            warn "PID $pid limits changed outside this script; record retained."; continue
        fi
        if (( defer_live )); then
            warn "PID $pid is still alive; limit restore deferred until it exits; record retained."; continue
        fi
        [[ -r $PROC_ROOT/$pid/fd && -x $PROC_ROOT/$pid/fd ]] ||
            { warn "Cannot inspect PID $pid descriptors; record retained."; continue; }
        fds=("$PROC_ROOT/$pid/fd/"*); busy=0
        if [[ $soft != unlimited ]]; then
            if ! uint_lt "${#fds[@]}" "$soft"; then busy=1; fi
            for fd in "${fds[@]}"; do
                if ! uint_lt "${fd##*/}" "$soft"; then busy=1; break; fi
            done
        fi
        if (( busy )); then
            warn "PID $pid is busy. Stop proxied traffic, then rerun restore; record retained."; continue
        fi
        [[ $(start_time "$pid") == "$start" && $(get_limits "$pid") == "$current" ]] ||
            { warn "PID $pid changed during restore; record retained for retry."; continue; }
        if prlimit --pid "$pid" --nofile="$soft:$hard" &&
           [[ $(start_time "$pid") == "$start" ]] &&
           [[ $(get_limits "$pid") == "$original" ]]; then
            say "RESTORED SSH PID $pid: nofile $soft:$hard"
            rm -- "$file"; changed=$((changed + 1))
        else
            warn "Could not restore/verify PID $pid; record retained."
        fi
    done
    for file in "$STATE_DIR/sysctl/"*; do
        [[ $file != *.tmp ]] || continue
        key=${file##*/}
        case $key in fs.file-max|net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.ipv4.tcp_moderate_rcvbuf|net.ipv4.tcp_window_scaling|net.ipv4.tcp_mtu_probing) ;; *) die "Invalid sysctl record: $key" ;; esac
        read_sysctl_record "$file"; original=$journal_original
        current=$(get_sysctl "$key") || { warn "Cannot read $key; record retained."; continue; }
        if [[ $current == "$original" ]]; then rm -- "$file"; continue; fi
        if ! owned_value "$current"; then
            warn "$key changed outside this script; record retained. Current: $current; original: $original; applied: $journal_target"; continue
        fi
        if [[ $key == fs.file-max ]]; then
            file_counts=$(get_sysctl fs.file-nr) || { warn 'Cannot inspect system file usage; fs.file-max record retained.'; continue; }
            allocated=${file_counts%% *}
            if ! number "$allocated" || ! uint_lt "$allocated" "$original"; then
                warn 'System file handles still exceed the old ceiling or usage is unreadable. Stop workloads, then rerun restore; fs.file-max record retained.'
                continue
            fi
        fi
        if [[ $(get_sysctl "$key") != "$current" ]]; then
            warn "$key changed during restore; record retained for retry."; continue
        fi
        if sysctl -q -w "$key=$original" &&
           [[ $(get_sysctl "$key") == "$original" ]]; then
            say "RESTORED $key: $original"
            rm -- "$file"; changed=$((changed + 1))
        else
            warn "Could not restore/verify $key; record retained."
        fi
    done
    say "Restore: $changed verified changes."
    if (( warnings == 0 )); then say 'All saved changes restored, or their original SSH processes have exited.'; fi
}

case ${1:-} in -h|--help|help) help_text; exit 0 ;; esac
(( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required.'
parse_args "$@"
(( EUID == 0 )) || die 'Run as root: sudo bash ssh-pivot-tune.sh apply|restore'
[[ -r $PROC_ROOT/sys/kernel/random/boot_id ]] || die 'Linux /proc is required.'
for command in sysctl prlimit flock awk stat readlink mkdir mv rm cat; do
    command -v "$command" >/dev/null || die "Missing Linux utility: $command (no pip packages needed)."
done
trap 'rc=$?; printf "Interrupted/failed; existing rollback records remain in %s. Run restore to undo changes.\n" "$STATE_DIR" >&2; exit "$rc"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
validate_namespaces
secure_dir "$STATE_DIR"
[[ ! -L $STATE_DIR/lock ]] || die 'Refusing symlink lock file.'
exec 9> "$STATE_DIR/lock"
flock -n 9 || die 'Another apply/restore is running.'
secure_dir "$STATE_DIR/sysctl"
secure_dir "$STATE_DIR/limits"
check_context
if [[ $action == apply ]]; then apply_all; else restore_all; fi
if (( warnings > 0 )); then
    say "PARTIAL: $warnings warning(s). See above; rollback records remain available."
    exit 2
fi
