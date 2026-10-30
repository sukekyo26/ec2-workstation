#!/usr/bin/env bash
# user-data の prepare_data_fs (データボリュームを、マウントの前にその OS の e2fsprogs で扱える形にする) を、
# 偽の e2fsck・dumpe2fs・tune2fs で確かめる。
# - 関数はテンプレートからそのまま取り出して走らせる (取り出せなければ FAIL)
# - 関数は user-data と同じく errexit の効く別のプロセス (bash -eu) で走らせる (サブシェルの || の下では errexit が効かないため)
# - 偽の dumpe2fs の出力は実物 (e2fsprogs 1.47.3 で al2027-preview の既定の mkfs、1.46.5 で al2023 の既定の mkfs) の先頭。
#   orphan_file を含む別の語だけの行は、実物の 1.46.5 の行に orphan_present を足して作った
# - 偽のコマンドは、FAKE_E2FSCK_STATUS で e2fsck の終了コードを、FAKE_DUMPE2FS で dumpe2fs の出力 (fail なら失敗) を、
#   FAKE_TUNE2FS_STATUS で tune2fs の終了コードを選び、呼ばれた引数を FAKE_LOG に書く
#
#   scripts/tests/data-volume-fs.test.sh
set -euo pipefail

template=$(cd "$(dirname "$0")/../../opentofu/modules/workstation/templates" && pwd)/user-data.sh.tftpl
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

cat > "$work/bin/e2fsck" << 'FAKE'
#!/usr/bin/env bash
echo "e2fsck $*" >> "$FAKE_LOG"
exit "$FAKE_E2FSCK_STATUS"
FAKE
cat > "$work/bin/dumpe2fs" << 'FAKE'
#!/usr/bin/env bash
echo "dumpe2fs $*" >> "$FAKE_LOG"
if [ "$FAKE_DUMPE2FS" = fail ]; then
    echo "dumpe2fs: No such file or directory while trying to open /dev/fake" >&2
    exit 2
fi
echo "dumpe2fs 1.47.3 (8-Jul-2025)" >&2
cat "$FAKE_DUMPE2FS"
FAKE
cat > "$work/bin/tune2fs" << 'FAKE'
#!/usr/bin/env bash
echo "tune2fs $*" >> "$FAKE_LOG"
if [ "$FAKE_TUNE2FS_STATUS" -ne 0 ]; then
    echo "fake tune2fs: failed" >&2
fi
exit "$FAKE_TUNE2FS_STATUS"
FAKE
chmod +x "$work/bin/"*

cat > "$work/with-orphan-file" << 'OUT'
Filesystem volume name:   <none>
Last mounted on:          <not available>
Filesystem UUID:          a22dbc7f-6adc-454f-be82-50726b76cef4
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index orphan_file filetype extent 64bit flex_bg metadata_csum_seed sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash
OUT
cat > "$work/without-orphan-file" << 'OUT'
Filesystem volume name:   <none>
Last mounted on:          <not available>
Filesystem UUID:          62c70bd2-ed5b-469c-a091-ddf300ba448b
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash
OUT
sed 's/^\(Filesystem features: .*\) filetype /\1 orphan_present filetype /' "$work/without-orphan-file" > "$work/orphan-present-only"
if ! grep -q ' orphan_present filetype ' "$work/orphan-present-only"; then
    fail "could not make the orphan_present-only output"
fi

functions=$(sed -n -e '/^print_recreate_hint() {$/,/^}$/p' -e '/^prepare_data_fs() {$/,/^}$/p' "$template")
for name in print_recreate_hint prepare_data_fs; do
    if ! grep -q "^$name() {\$" <<< "$functions"; then
        fail "could not take $name() out of $template"
    fi
done
if [ "$failures" -ne 0 ]; then
    exit 1
fi
{
    echo 'DATA_VOLUME_ID=vol-0123 WORKSTATION_USER=alice'
    echo "$functions"
    echo 'prepare_data_fs /dev/fake'
} > "$work/run.sh"

hint="  tofu apply -replace='module.workstation[\"alice\"].aws_instance.this'"
error_unsupported="ERROR: e2fsck on this OS could not check data volume vol-0123 (exit STATUS; its message is above). If it reports unsupported feature(s), a newer OS formatted the volume: set os to al2027-preview and apply, wait until the user-data finishes, then set os back to this one and apply."
error_not_clean="ERROR: e2fsck could not leave data volume vol-0123 clean (exit STATUS; its output is above). Fix what it reports on the instance (for example with 'sudo e2fsck -f /dev/fake'), then recreate it:"$'\n'"$hint"
error_tune2fs="fake tune2fs: failed"$'\n'"ERROR: tune2fs could not remove orphan_file from data volume vol-0123 (its message is above). Inspect it with 'sudo tune2fs -l /dev/fake', then recreate the instance:"$'\n'"$hint"
error_dumpe2fs="dumpe2fs: No such file or directory while trying to open /dev/fake"$'\n'"ERROR: dumpe2fs could not read data volume vol-0123 (its message is above), so whether it has orphan_file is unknown. Inspect it with 'sudo dumpe2fs -f -h /dev/fake', then recreate the instance:"$'\n'"$hint"

# check <名前> <期待の終了コード> <期待の stderr> <期待の呼び出し>: e2fsck と dumpe2fs の振る舞いは FAKE_* で渡す
check() {
    local name=$1 want_rc=$2 want_err=$3 want_calls=$4 rc=0
    echo "case: $name"
    : > "$work/calls"
    bash -eu "$work/run.sh" > /dev/null 2> "$work/stderr" < /dev/null || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        fail "$name: want exit $want_rc, got $rc ($(cat "$work/stderr"))"
    fi
    if [ "$(cat "$work/stderr")" != "$want_err" ]; then
        fail "$name: want stderr [$want_err], got [$(cat "$work/stderr")]"
    fi
    if [ "$(cat "$work/calls")" != "$want_calls" ]; then
        fail "$name: want calls [$want_calls], got [$(cat "$work/calls")]"
    fi
}

export FAKE_LOG="$work/calls"
export PATH="$work/bin:$PATH"
export FAKE_TUNE2FS_STATUS=0
banner="dumpe2fs 1.47.3 (8-Jul-2025)"
remove_calls=$'e2fsck -p /dev/fake\ndumpe2fs -f -h /dev/fake\ntune2fs -O ^orphan_file /dev/fake'

FAKE_E2FSCK_STATUS=0 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check orphan 0 "$banner" "$remove_calls"
FAKE_E2FSCK_STATUS=0 FAKE_DUMPE2FS="$work/without-orphan-file" \
    check plain 0 "$banner" $'e2fsck -p /dev/fake\ndumpe2fs -f -h /dev/fake'
FAKE_E2FSCK_STATUS=1 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check corrected 0 "$banner" "$remove_calls"
FAKE_E2FSCK_STATUS=2 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check reboot 0 "$banner" "$remove_calls"
FAKE_E2FSCK_STATUS=3 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check corrected-reboot 0 "$banner" "$remove_calls"
FAKE_E2FSCK_STATUS=0 FAKE_DUMPE2FS="$work/orphan-present-only" \
    check orphan-present-only 0 "$banner" $'e2fsck -p /dev/fake\ndumpe2fs -f -h /dev/fake'
FAKE_E2FSCK_STATUS=12 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check unsupported 1 "${error_unsupported/STATUS/12}" 'e2fsck -p /dev/fake'
FAKE_E2FSCK_STATUS=8 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check operational 1 "${error_unsupported/STATUS/8}" 'e2fsck -p /dev/fake'
FAKE_E2FSCK_STATUS=4 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check uncorrected 1 "${error_not_clean/STATUS/4}" 'e2fsck -p /dev/fake'
FAKE_E2FSCK_STATUS=16 FAKE_DUMPE2FS="$work/with-orphan-file" \
    check usage 1 "${error_not_clean/STATUS/16}" 'e2fsck -p /dev/fake'
FAKE_E2FSCK_STATUS=0 FAKE_DUMPE2FS="$work/with-orphan-file" FAKE_TUNE2FS_STATUS=1 \
    check tune2fs-fails 1 "$banner"$'\n'"$error_tune2fs" "$remove_calls"
FAKE_E2FSCK_STATUS=0 FAKE_DUMPE2FS=fail \
    check dumpe2fs-fails 1 "$error_dumpe2fs" $'e2fsck -p /dev/fake\ndumpe2fs -f -h /dev/fake'

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
