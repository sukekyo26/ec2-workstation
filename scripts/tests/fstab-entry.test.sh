#!/usr/bin/env bash
# user-data の ensure_fstab_entry (fstab に行が無ければ足し、同じマウント先に別の行があれば止める) を、一時のファイルを fstab にして確かめる。
# - 関数はテンプレートからそのまま取り出し、user-data と同じく errexit の効く別のプロセス (bash -eu) で走らせる (取り出せなければ FAIL)
# - findmnt は本物を使う (fstab の読み方を findmnt に任せていることを確かめるため)
# - 終了コード・stderr の全文・走らせた後の fstab の全文を比べる
#
#   scripts/tests/fstab-entry.test.sh
set -euo pipefail

template=$(cd "$(dirname "$0")/../../opentofu/modules/workstation/templates" && pwd)/user-data.sh.tftpl
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/no-findmnt"
bash_path=$(command -v bash)

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

function_body=$(sed -n '/^ensure_fstab_entry() {$/,/^}$/p' "$template")
if ! grep -q '^ensure_fstab_entry() {$' <<< "$function_body"; then
    echo "FAIL: could not take ensure_fstab_entry() out of $template" >&2
    exit 1
fi

fstab="$work/fstab"
data_line="UUID=1111-new /data ext4 defaults,nofail 0 2"
work_line="/data/work /home/ec2-user/work none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
docker_line="/data/docker /var/lib/docker none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
data_args='"UUID=1111-new" /data ext4 defaults,nofail 2'
work_args='/data/work /home/ec2-user/work none bind,nofail,x-systemd.requires-mounts-for=/data 0'
docker_args='/data/docker /var/lib/docker none bind,nofail,x-systemd.requires-mounts-for=/data 0'

# check <名前> <前からある fstab (- なら作らない)> <呼び出しの引数> <期待の終了コード> <期待の stderr> <期待の fstab> [PATH]
check() {
    local name=$1 before=$2 args=$3 want_rc=$4 want_err=$5 want_fstab=$6 path=${7:-$PATH} rc=0
    echo "case: $name"
    rm -f "$fstab"
    if [ "$before" != - ]; then
        printf '%s' "$before" > "$fstab"
    fi
    {
        echo "FSTAB='$fstab'"
        echo "$function_body"
        echo "ensure_fstab_entry $args"
    } > "$work/run.sh"
    PATH=$path "$bash_path" -eu "$work/run.sh" > /dev/null 2> "$work/stderr" < /dev/null || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        fail "$name: want exit $want_rc, got $rc ($(cat "$work/stderr"))"
    fi
    if [ "$(cat "$work/stderr")" != "$want_err" ]; then
        fail "$name: want stderr [$want_err], got [$(cat "$work/stderr")]"
    fi
    local got_fstab=-
    if [ -e "$fstab" ]; then
        got_fstab=$(cat "$fstab")
    fi
    if [ "$got_fstab" != "$want_fstab" ]; then
        fail "$name: want fstab [$want_fstab], got [$got_fstab]"
    fi
}

# conflict <キー> <source target type> <findmnt の行>: 別の行で止まるときの stderr
conflict() {
    echo "$3"
    echo "ERROR: $fstab already has the entry above for $1, which is not \"$2\". The user-data does not overwrite it: remove that line from $fstab on the instance, then run the user-data again as the README describes."
}

root_line=$'UUID=root-0000\t/\txfs\tdefaults,noatime\t1 1\n'

check empty "$root_line" "$data_args" 0 "" "${root_line}${data_line}"
check same "$root_line$data_line"$'\n' "$data_args" 0 "" "${root_line}${data_line}"
check same-tabs $'UUID=1111-new\t/data\text4\tdefaults 0 2\n' "$data_args" 0 "" $'UUID=1111-new\t/data\text4\tdefaults 0 2'
check trailing-slash $'UUID=1111-new /data/ ext4 defaults 0 2\n' "$data_args" 0 "" 'UUID=1111-new /data/ ext4 defaults 0 2'
check comment $'# UUID=1111-new /data ext4 defaults,nofail 0 2\n' "$data_args" 0 "" "# UUID=1111-new /data ext4 defaults,nofail 0 2"$'\n'"$data_line"
check other-uuid $'UUID=0000-old /data ext4 defaults,nofail 0 2\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' 'UUID=0000-old /data ext4 defaults,nofail')" \
    'UUID=0000-old /data ext4 defaults,nofail 0 2'
check old-then-same $'UUID=0000-old /data ext4 defaults,nofail 0 2\n'"$data_line"$'\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' $'UUID=0000-old /data ext4 defaults,nofail\nUUID=1111-new /data ext4 defaults,nofail')" \
    'UUID=0000-old /data ext4 defaults,nofail 0 2'$'\n'"$data_line"
check other-type $'UUID=1111-new /data xfs defaults 0 2\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' 'UUID=1111-new /data xfs defaults')" \
    'UUID=1111-new /data xfs defaults 0 2'
check bind-tabs $'/data/work\t/home/ec2-user/work\tnone\tbind 0 0\n' "$work_args" 0 "" $'/data/work\t/home/ec2-user/work\tnone\tbind 0 0'
check bind-other-type $'/data/work /home/ec2-user/work ext4 bind 0 0\n' "$work_args" 1 \
    "$(conflict /home/ec2-user/work '/data/work /home/ec2-user/work none' '/data/work /home/ec2-user/work ext4 bind')" \
    '/data/work /home/ec2-user/work ext4 bind 0 0'
check bind-comment $'# /data/work /home/ec2-user/work none bind\n' "$work_args" 0 "" "# /data/work /home/ec2-user/work none bind"$'\n'"$work_line"
check bind-prefix $'/data/docker /var/lib/docker-old none bind 0 0\n' "$docker_args" 0 "" "/data/docker /var/lib/docker-old none bind 0 0"$'\n'"$docker_line"
check no-fstab - "$data_args" 1 \
    "ERROR: $fstab does not exist or cannot be read. Check it on the instance, then run the user-data again as the README describes." -
check no-findmnt "$root_line" "$data_args" 1 \
    "ERROR: findmnt (util-linux) is not installed, so the user-data cannot read $fstab. Install util-linux, then run the user-data again as the README describes." \
    "${root_line%$'\n'}" "$work/no-findmnt"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
