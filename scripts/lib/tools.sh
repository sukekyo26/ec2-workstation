# shellcheck shell=bash
# 版と sha256 を固定して GitHub のリリースから取る道具 (jv・shfmt) の表と、取る・確かめる・置くの流れ。
# scripts/install-jv.sh・scripts/install-shfmt.sh・scripts/format-shell.sh と、scripts/lib/tofu-common.sh が読む。
# 版を上げるときは、その道具の版と 4 つの sha256 (GitHub のリリースの添付ファイルの digest) を一緒に変える

# shellcheck source=scripts/lib/base.sh
. "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# jv --version は版を返さないので、置き場所に版を入れて見分ける (shfmt も同じ形にそろえる)
JV_VERSION=v6.0.3
SHFMT_VERSION=v3.14.1

# jv_sha256 <os>-<arch>: JV_VERSION の tarball の sha256
jv_sha256() {
    case "$1" in
        linux-amd64) echo 36e9ab8481cc8e2cb27c8336decc9abdcbd606b05792ca88d6188e01ec28766b ;;
        linux-arm64) echo a9b06c4d73bf3cbe9b3224aacef5329d96267c27febac1152db1ff1659550122 ;;
        darwin-amd64) echo f41e3541d0ba2b5f628d1a04701db3acefcf6aa1feb5c28e10f446dfc584952d ;;
        darwin-arm64) echo d5962c5a7abe0c82be6b69bbed6bd5c9883462f13e0353ddca9878c46ec6ed6f ;;
        *) die "no jv $JV_VERSION for $1" ;;
    esac
}

# shfmt_sha256 <os>-<arch>: SHFMT_VERSION のバイナリの sha256
shfmt_sha256() {
    case "$1" in
        linux-amd64) echo 76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf ;;
        linux-arm64) echo 5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489 ;;
        darwin-amd64) echo d33eee0da0f92835b3562e9767a05cee7e4eaeef47daa03bfd09da17b4b590a6 ;;
        darwin-arm64) echo b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5 ;;
        *) die "no shfmt $SHFMT_VERSION for $1" ;;
    esac
}

# tool_path <名前> <版>: 置き場所を組み立てるのはここだけ
tool_path() {
    echo "$REPO_ROOT/.tools/$1-$2/$1"
}

jv_path() {
    tool_path jv "$JV_VERSION"
}

shfmt_path() {
    tool_path shfmt "$SHFMT_VERSION"
}

# host_platform <名前> <版>: linux-amd64 などを返す
host_platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *) die "unsupported OS $(uname -s): run this on Linux, macOS, WSL, or the CI" ;;
    esac
    case "$(uname -m)" in
        x86_64 | amd64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) die "unsupported CPU $(uname -m): $1 $2 is released for amd64 and arm64" ;;
    esac
    echo "$os-$arch"
}

file_sha256() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum > /dev/null; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "install sha256sum or shasum to check the download"
    fi
}

# install_pinned_tool <名前> <版> <URL> <sha256> <tar の中の名前。tar でなければ ""> [--force]
# 一時ディレクトリで取って確かめ、最後に mv で置く。途中で止まっても置き場所に中途半端なものが残らない。
# 本体はサブシェルで動かす: EXIT の trap は関数の終わり (成功でも die でも) で一時ディレクトリを消し、呼び出し元の trap を上書きしない
install_pinned_tool() (
    name=$1 version=$2 url=$3 want=$4 member=$5 force=${6:-}
    dest=$(tool_path "$name" "$version")
    if [ -x "$dest" ] && [ "$force" != --force ]; then
        log "$name $version is already installed at $dest"
        exit 0
    fi

    mkdir -p "$REPO_ROOT/.tools"
    tmp=$(mktemp -d "$REPO_ROOT/.tools/tmp.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    asset=${url##*/}
    log "downloading $asset"
    # deploy のたびに GitHub Releases から取るので、一時的な失敗は取り直す。--retry-all-errors は curl 7.71 から
    retry=(--retry 3 --retry-delay 2)
    # grep -q で途中で読むのをやめると、pipefail の下で curl の SIGPIPE が失敗になるので、全部読ませる
    if curl --help all 2> /dev/null | grep -- --retry-all-errors > /dev/null; then
        retry+=(--retry-all-errors)
    fi
    curl -fsSL "${retry[@]}" --connect-timeout 10 --max-time 120 -o "$tmp/$asset" "$url"
    got=$(file_sha256 "$tmp/$asset")
    if [ "$got" != "$want" ]; then
        die "sha256 mismatch for $asset: got $got, want $want"
    fi
    if [ -n "$member" ]; then
        tar -xzf "$tmp/$asset" -C "$tmp" "$member"
        mv "$tmp/$member" "$tmp/$name.bin"
    else
        mv "$tmp/$asset" "$tmp/$name.bin"
    fi
    chmod +x "$tmp/$name.bin"
    mkdir -p "$(dirname "$dest")"
    mv "$tmp/$name.bin" "$dest"
    log "installed $name $version at $dest"
)
