#!/usr/bin/env bash
# user-data の ensure_fstab_entry (fstab に行が無ければ足し、同じマウント先に別の行があれば止める) を、一時のファイルを fstab にして確かめる。
# - 関数はテンプレートからそのまま取り出し、user-data と同じく errexit の効く別のプロセス (bash -eu) で走らせる (取り出せなければ FAIL)
# - findmnt は本物を使う (fstab の読み方を findmnt に任せていることを確かめるため)。findmnt が 0・1 以外で終わる場合だけは、
#   版で起きたり起きなかったりする (壊れた行で 2.41.5 は rc=139、2.37.4・2.39.3 は飛ばして rc=0) ので、偽の findmnt で起こす
# - 終了コード・stderr の全文・走らせた後の fstab の全文を比べる。テンプレートの呼び出しの行が期待どおりかも見る
#
#   scripts/tests/fstab-entry.test.sh
set -euo pipefail

template=$(cd "$(dirname "$0")/../../opentofu/modules/workstation/templates" && pwd)/user-data.sh.tftpl
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/no-findmnt" "$work/broken-findmnt"
cat > "$work/broken-findmnt/findmnt" << 'FAKE'
#!/usr/bin/env bash
echo "findmnt: $3: parse error at line 1 -- ignored" >&2
exit 139
FAKE
chmod +x "$work/broken-findmnt/findmnt"
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
# 呼び出しの引数 (UUID= の前置き・型・options・pass) は、テンプレートの行をそのまま見る
for call in \
    'ensure_fstab_entry "UUID=$DATA_UUID" "$DATA_MOUNT" ext4 defaults,nofail 2' \
    '    ensure_fstab_entry "$source_dir" "$mount_point" none "bind,nofail,x-systemd.requires-mounts-for=$DATA_MOUNT" 0'; do
    if ! grep -qxF -- "$call" "$template"; then
        fail "the call [$call] is not in $template"
    fi
done

fstab="$work/fstab"
data_line="UUID=1111-new /data ext4 defaults,nofail 0 2"
work_line="/data/work /home/ec2-user/work none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
docker_line="/data/docker /var/lib/docker none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
data_args='"UUID=1111-new" /data ext4 defaults,nofail 2'
work_args='/data/work /home/ec2-user/work none bind,nofail,x-systemd.requires-mounts-for=/data 0'
docker_args='/data/docker /var/lib/docker none bind,nofail,x-systemd.requires-mounts-for=/data 0'

# check <名前> <前からある fstab (- なら作らない)> <呼び出しの引数> <期待の終了コード> <期待の stderr (* なら最後の行が ERROR: で始まること)> <期待の fstab> [PATH]
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
    if [ "$want_err" = '*' ]; then
        if ! tail -n 1 "$work/stderr" | grep -q '^ERROR: '; then
            fail "$name: want the last line of stderr to start with ERROR:, got [$(cat "$work/stderr")]"
        fi
    elif [ "$(cat "$work/stderr")" != "$want_err" ]; then
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
# 既定の出力 (-r 無し) なら幅をそろえて空白が増えるよう、古い行の source は長くする
old_line="UUID=00000000-0000-0000-0000-000000000000 /data ext4 defaults,nofail 0 2"
old_entry="UUID=00000000-0000-0000-0000-000000000000 /data ext4 defaults,nofail"

check empty "$root_line" "$data_args" 0 "" "${root_line}${data_line}"
check same "$root_line$data_line"$'\n' "$data_args" 0 "" "${root_line}${data_line}"
check same-tabs $'UUID=1111-new\t/data\text4\tdefaults 0 2\n' "$data_args" 0 "" $'UUID=1111-new\t/data\text4\tdefaults 0 2'
check trailing-slash $'UUID=1111-new /data/ ext4 defaults 0 2\n' "$data_args" 0 "" 'UUID=1111-new /data/ ext4 defaults 0 2'
check comment $'# UUID=1111-new /data ext4 defaults,nofail 0 2\n' "$data_args" 0 "" "# UUID=1111-new /data ext4 defaults,nofail 0 2"$'\n'"$data_line"
check other-uuid $'UUID=0000-old /data ext4 defaults,nofail 0 2\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' 'UUID=0000-old /data ext4 defaults,nofail')" \
    'UUID=0000-old /data ext4 defaults,nofail 0 2'
check old-then-same "$old_line"$'\n'"$data_line"$'\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' "$old_entry"$'\n''UUID=1111-new /data ext4 defaults,nofail')" \
    "$old_line"$'\n'"$data_line"
check same-then-old "$data_line"$'\n'"$old_line"$'\n' "$data_args" 1 \
    "$(conflict /data 'UUID=1111-new /data ext4' 'UUID=1111-new /data ext4 defaults,nofail'$'\n'"$old_entry")" \
    "$data_line"$'\n'"$old_line"
check broken-line $'garbage\n'"$old_line"$'\n' "$data_args" 1 '*' $'garbage\n'"$old_line"
check findmnt-fails "$old_line"$'\n' "$data_args" 1 \
    "findmnt: $fstab: parse error at line 1 -- ignored"$'\n'"ERROR: findmnt could not read $fstab (exit 139; its message is above). Fix $fstab on the instance, then run the user-data again as the README describes." \
    "$old_line" "$work/broken-findmnt:$PATH"
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
