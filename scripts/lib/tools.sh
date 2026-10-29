# shellcheck shell=bash
# 版と sha256 を固定して GitHub のリリースから取る道具 (jv・shfmt・tofu・just・shellcheck・gitleaks) の表と、取る・確かめる・置くの流れ。
# scripts/install-*.sh・scripts/format-shell.sh と、scripts/lib/tofu-common.sh が読む。
# 版を上げるときは、その道具の版と 4 つの sha256 (GitHub のリリースの添付ファイルの digest) を一緒に変える

# shellcheck source=scripts/lib/base.sh
. "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# 版は置き場所 (.tools/<名前>-<版>) に入れて見分ける (jv --version は版を返さない)。
# jv は glibc に動的にリンクされていて、v6.0.3 は GLIBC_2.34 まで要る (CodeBuild の Amazon Linux 2023 の glibc は 2.34)。
# jv の版を上げるときは readelf -V で要る glibc の版を見る。ほかの道具は静的にリンクされている
JV_VERSION=v6.0.3
SHFMT_VERSION=v3.14.1
TOFU_VERSION=v1.13.2
JUST_VERSION=1.59.0
SHELLCHECK_VERSION=v0.11.0
GITLEAKS_VERSION=v8.30.1

# tool_sha256 <名前> <os>-<arch>: その道具の版の、その環境の添付ファイルの sha256
tool_sha256() {
    case "$1 $2" in
        "jv linux-amd64") echo 36e9ab8481cc8e2cb27c8336decc9abdcbd606b05792ca88d6188e01ec28766b ;;
        "jv linux-arm64") echo a9b06c4d73bf3cbe9b3224aacef5329d96267c27febac1152db1ff1659550122 ;;
        "jv darwin-amd64") echo f41e3541d0ba2b5f628d1a04701db3acefcf6aa1feb5c28e10f446dfc584952d ;;
        "jv darwin-arm64") echo d5962c5a7abe0c82be6b69bbed6bd5c9883462f13e0353ddca9878c46ec6ed6f ;;
        "shfmt linux-amd64") echo 76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf ;;
        "shfmt linux-arm64") echo 5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489 ;;
        "shfmt darwin-amd64") echo d33eee0da0f92835b3562e9767a05cee7e4eaeef47daa03bfd09da17b4b590a6 ;;
        "shfmt darwin-arm64") echo b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5 ;;
        "tofu linux-amd64") echo ac05d9952662c7db28dd57e93f0a68018837bfdf9342384ec0987977c16a9645 ;;
        "tofu linux-arm64") echo 88e2d9e3f94f97b76ab2faf55ade87578f56aed19c5e45fa139d70e994366d1f ;;
        "tofu darwin-amd64") echo dc6e4eb1d3ed6550c2ef052596f933dbcd8c806957665ea83ae7537147cb3074 ;;
        "tofu darwin-arm64") echo 0d1cdc85f38992055b48e7fb161304a2ddfe2e5ee0ff68ffec9d0349c8bd1b59 ;;
        "just linux-amd64") echo 409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e ;;
        "just linux-arm64") echo 23871b1702bfd550fb5f901778fd4290ecf2ee034a45a889fbe96d89b188086d ;;
        "just darwin-amd64") echo 036ead9df9bc31dbae9934ae3b4236ed124d0bafcffd33439460ae084d5c9cb7 ;;
        "just darwin-arm64") echo 6574cea774ed4cae12e24b6aa11857de33e80dab4667cf628fd5840df96a2a9d ;;
        "shellcheck linux-amd64") echo b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6 ;;
        "shellcheck linux-arm64") echo 68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc ;;
        "shellcheck darwin-amd64") echo c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51 ;;
        "shellcheck darwin-arm64") echo 339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f ;;
        "gitleaks linux-amd64") echo 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
        "gitleaks linux-arm64") echo e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
        "gitleaks darwin-amd64") echo dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
        "gitleaks darwin-arm64") echo b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
        *) die "no sha256 for $1 on $2" ;;
    esac
}

# tool_version <名前>
tool_version() {
    case "$1" in
        jv) echo "$JV_VERSION" ;;
        shfmt) echo "$SHFMT_VERSION" ;;
        tofu) echo "$TOFU_VERSION" ;;
        just) echo "$JUST_VERSION" ;;
        shellcheck) echo "$SHELLCHECK_VERSION" ;;
        gitleaks) echo "$GITLEAKS_VERSION" ;;
        *) die "unknown tool $1" ;;
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

# tools_path: 全部の道具の置き場所のディレクトリを : でつなぐ (CodeBuild の buildspec が PATH の先頭に足す)
tools_path() {
    local name dirs=()
    for name in jv shfmt tofu just shellcheck gitleaks; do
        dirs+=("$REPO_ROOT/.tools/$name-$(tool_version "$name")")
    done
    local IFS=:
    echo "${dirs[*]}"
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

    # if・&&・|| の条件で呼ばれると set -e が効かないので、失敗を見落とせない所は || die で止める
    mkdir -p "$REPO_ROOT/.tools" || die "could not create $REPO_ROOT/.tools"
    tmp=$(mktemp -d "$REPO_ROOT/.tools/tmp.XXXXXX") || die "could not create a temporary directory in $REPO_ROOT/.tools"
    trap 'rm -rf "$tmp"' EXIT

    asset=${url##*/}
    log "downloading $asset"
    # deploy のたびに GitHub Releases から取るので、一時的な失敗は取り直す。--retry-all-errors は curl 7.71 から
    retry=(--retry 3 --retry-delay 2)
    # grep -q で途中で読むのをやめると、pipefail の下で curl の SIGPIPE が失敗になるので、全部読ませる
    if curl --help all 2> /dev/null | grep -- --retry-all-errors > /dev/null; then
        retry+=(--retry-all-errors)
    fi
    curl -fsSL "${retry[@]}" --connect-timeout 10 --max-time 120 -o "$tmp/$asset" "$url" || die "could not download $url"
    got=$(file_sha256 "$tmp/$asset") || die "could not compute the sha256 of $asset"
    if [ "$got" != "$want" ]; then
        die "sha256 mismatch for $asset: got $got, want $want"
    fi
    if [ -n "$member" ]; then
        tar -xzf "$tmp/$asset" -C "$tmp" "$member" || die "could not extract $member from $asset"
        mv "$tmp/$member" "$tmp/$name.bin" || die "could not find $member in $asset"
    else
        mv "$tmp/$asset" "$tmp/$name.bin" || die "could not move $asset"
    fi
    chmod +x "$tmp/$name.bin" || die "could not make $name executable"
    mkdir -p "${dest%/*}" || die "could not create ${dest%/*}"
    mv "$tmp/$name.bin" "$dest" || die "could not install $name at $dest"
    log "installed $name $version at $dest"
)

# install_tool <名前> [--force]: 道具ごとの添付ファイルの名前の形から URL を作り、install_pinned_tool で入れる
install_tool() {
    local name=$1 force=${2:-} version platform os arch url member
    version=$(tool_version "$name")
    platform=$(host_platform "$name" "$version")
    os=${platform%-*} arch=${platform#*-}
    case "$name" in
        jv)
            url="https://github.com/santhosh-tekuri/jsonschema/releases/download/$version/jv-$version-$platform.tar.gz"
            member=jv
            ;;
        shfmt)
            # tar でなくバイナリそのもので、名前は shfmt_<版>_linux_amd64 の形
            url="https://github.com/mvdan/sh/releases/download/$version/shfmt_${version}_${os}_$arch"
            member=
            ;;
        tofu)
            url="https://github.com/opentofu/opentofu/releases/download/$version/tofu_${version#v}_${os}_$arch.tar.gz"
            member=tofu
            ;;
        just)
            local triple
            case "$platform" in
                linux-amd64) triple=x86_64-unknown-linux-musl ;;
                linux-arm64) triple=aarch64-unknown-linux-musl ;;
                darwin-amd64) triple=x86_64-apple-darwin ;;
                darwin-arm64) triple=aarch64-apple-darwin ;;
            esac
            url="https://github.com/casey/just/releases/download/$version/just-$version-$triple.tar.gz"
            member=just
            ;;
        shellcheck)
            local cpu=x86_64
            if [ "$arch" = arm64 ]; then
                cpu=aarch64
            fi
            url="https://github.com/koalaman/shellcheck/releases/download/$version/shellcheck-$version.$os.$cpu.tar.gz"
            member="shellcheck-$version/shellcheck"
            ;;
        gitleaks)
            local cpu=x64
            if [ "$arch" = arm64 ]; then
                cpu=arm64
            fi
            url="https://github.com/gitleaks/gitleaks/releases/download/$version/gitleaks_${version#v}_${os}_$cpu.tar.gz"
            member=gitleaks
            ;;
        *) die "unknown tool $name" ;;
    esac
    local want
    want=$(tool_sha256 "$name" "$platform")
    install_pinned_tool "$name" "$version" "$url" "$want" "$member" "$force"
}
