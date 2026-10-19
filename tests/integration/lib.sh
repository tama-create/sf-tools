#!/bin/bash
# ==============================================================================
# lib.sh - 結合テスト（L1 ローカル結合）のハーネス
# ==============================================================================
# 実際の git と、ローカルの bare リポジトリ（origin の代わり）で、sf-tools のコマンドを連動させて動かす。
# gh・sf・npm・curl・code は、状態を持つ fake（PATH の先頭に置く）。sf-tools 本体のコードは、変えない。
# 計画: doc/integration-test-plan.md（4.2・4.4・4.5）
#
# 【作業用の場所（it_setup が作る。終了時に it_teardown が消す）】
#   $IT_ROOT/home    HOME。~/sf-tools に、本物の bin / lib / hooks / config / templates / phases の写しを置く
#   $IT_ROOT/bin     fake（gh・sf・npm・curl・code など）
#   $IT_ROOT/state   fake の状態（呼び出しの記録・ログイン状態・故障注入のルール）
#   $IT_ROOT/origin.git  bare の origin（実 git）。https://github.com/ を ssh://git@github.com/ に読み替え、fake の ssh で、ここに向ける
#   $IT_ROOT/work    作業フォルダ（sf-job などの実行場所）
#
# 【主な関数】
#   it_setup / it_teardown        作業用の場所の作成・削除
#   it_seed_repo [層数]            テンプレートから、最小のリポジトリを作り、origin に push する（1 / 2 / 3 層）
#   it_run DIR [-i 入力] CMD ...   サンドボックスの環境で実行。結果: $IT_OUT（出力のファイル）・$IT_RC（終了コード）
#   it_fault CMD パターン N 回数 終了コード メッセージ [遅延]   故障注入（CMD の、パターンに合う N 回目から、回数だけ失敗させる）
#   it_calls [CMD]                 fake の呼び出しの記録（CMD で、絞り込める）
#   it_snap DIR / it_remote_snap   不変条件の確認用の、ローカル・リモートの状態
#   it_leak_count 文字列           サンドボックス内のファイル（出力・ログ・状態）に、文字列が何件あるか（秘密の漏れの確認）
# ==============================================================================

# run_with_timeout（時間の上限つき実行。macOS にも動く）
# shellcheck source=../../lib/platform.sh
source "${SF_TOOLS_DIR:?}/lib/platform.sh"

IT_OWNER="${IT_OWNER:-tamashimon-org}"
IT_PROJECT="${IT_PROJECT:-itproj}"
IT_REPO="force-${IT_PROJECT}"
IT_N=0
IT_COMMIT_MSG_DEFAULT="it: 結合テスト"

# ------------------------------------------------------------------------------
# 作業用の場所
# ------------------------------------------------------------------------------
it_setup() {
    IT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/it-XXXXXX") || return 1
    IT_HOME="$IT_ROOT/home"; IT_BIN="$IT_ROOT/bin"; IT_STATE="$IT_ROOT/state"
    IT_ORIGIN="$IT_ROOT/origin.git"; IT_WORK="$IT_ROOT/work"
    mkdir -p "$IT_HOME/sf-tools" "$IT_BIN" "$IT_STATE" "$IT_WORK"
    local d
    for d in bin lib hooks config templates phases; do
        cp -R "$SF_TOOLS_DIR/$d" "$IT_HOME/sf-tools/$d"
    done
    # git の設定（HOME の ~/.gitconfig。システムの設定は、読まない）
    _it_git config --global user.name "IT Tester"
    _it_git config --global user.email "it@example.invalid"
    _it_git config --global init.defaultBranch main
    _it_git config --global core.autocrlf false
    _it_git config --global protocol.file.allow always
    _it_git config --global advice.detachedHead false
    # ~/sf-tools を git リポジトリにする（sf-install の git pull が、本物と同じように動くように。origin は、ローカルの bare）
    _it_git init -q --bare -b main "$IT_ROOT/sftools-origin.git"
    (
        cd "$IT_HOME/sf-tools" || exit 1
        _it_git init -q -b main
        _it_git remote add origin "$IT_ROOT/sftools-origin.git"
        _it_git add -A >/dev/null 2>&1
        _it_git commit -q -m "sf-tools の写し" || exit 1
        _it_git push -q -u origin main
    ) || return 1
    # sf-install のツール更新（24 時間に 1 回）を、止める。Windows では git update-git-for-windows（本物の更新）が動くため。
    #   更新の経路を確かめるときは、it_block_git_update を呼んでから、スタンプを消すこと
    touch "$IT_HOME/.sf-tools-last-update"
    _it_write_fakes
}

# 既存のサンドボックスに、つなぎ直す（調査用。IT_KEEP=1 で残したものに対して使う）
it_attach() { IT_ROOT="$1"; IT_HOME="$IT_ROOT/home"; IT_BIN="$IT_ROOT/bin"; IT_STATE="$IT_ROOT/state"; IT_ORIGIN="$IT_ROOT/origin.git"; IT_WORK="$IT_ROOT/work"; }

it_teardown() {
    [[ -n "${IT_SHOW_RUNS:-}" && -f "$IT_STATE/runs.log" ]] && sort -rn "$IT_STATE/runs.log" | head -15
    [[ -n "${IT_KEEP:-}" ]] && { echo "IT_KEEP: $IT_ROOT" >&2; return 0; }
    [[ -n "${IT_ROOT:-}" && -d "$IT_ROOT" ]] && rm -rf "$IT_ROOT"
    IT_ROOT=""
}

# サンドボックスの環境で git を実行する（ハーネスの内部用）
_it_git() {
    ( export HOME="$IT_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0; git "$@" )
}

# ------------------------------------------------------------------------------
# リポジトリ（テンプレートから、最小のものを作る。sf-init の生成物そのものではない）
# ------------------------------------------------------------------------------
it_seed_repo() {
    local layout="${1:-1}" seed="$IT_ROOT/seed" br
    _it_git init -q --bare -b main "$IT_ORIGIN" || return 1
    mkdir -p "$seed"
    cp -R "$SF_TOOLS_DIR/templates/." "$seed/"
    {
        echo "# branches.txt（結合テスト用）"
        echo "main"
        [[ "$layout" -ge 2 ]] && echo "staging"
        [[ "$layout" -ge 3 ]] && echo "develop"
    } > "$seed/sf-tools/config/branches.txt"
    (
        cd "$seed" || exit 1
        _it_git init -q -b main
        _it_git add -A
        _it_git commit -q -m "seed: テンプレートから生成" || exit 1
        _it_git remote add origin "$IT_ORIGIN"
        _it_git push -q origin main || exit 1
        [[ "$layout" -ge 2 ]] && { _it_git push -q origin main:refs/heads/staging || exit 1; }
        [[ "$layout" -ge 3 ]] && { _it_git push -q origin main:refs/heads/develop || exit 1; }
        exit 0
    ) || return 1
    echo "${IT_OWNER}/${IT_REPO}" >> "$IT_STATE/repos"
    # https://github.com/ を ssh://git@github.com/ に読み替え、ssh の代わりの fake が、ローカルの bare に向ける
    #   （https のままだと、git remote get-url が、ローカルのパスを返し、オーナー・リポジトリ名を読むコードが動かないため）
    _it_git config --global "url.ssh://git@github.com/.insteadOf" "https://github.com/"
}

# ------------------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------------------
# it_run DIR [-i 入力] CMD ARGS...
#   結果: IT_OUT（標準出力・標準エラーのファイル）・IT_RC（終了コード）。入力は、printf '%b' で、標準入力に流す
it_run() {
    local dir="$1" input="" t0=$SECONDS
    shift
    if [[ "${1:-}" == "-i" ]]; then input="$2"; shift 2; fi
    IT_N=$((IT_N + 1))
    IT_OUT="$IT_ROOT/out.${IT_N}.txt"
    (
        cd "$dir" || exit 99
        export HOME="$IT_HOME" PATH="$IT_BIN:$PATH" IT_STATE IT_ORIGIN
        # CI（GitHub Actions）の環境変数を持ち込まない（持ち込むと、管理者向けの確認が省略され、結果が変わる）。X6-1 は env で明示する
        unset GITHUB_ACTIONS CI GH_TOKEN GITHUB_TOKEN
        export SF_LAUNCHER_ACTIVE=1 SF_TOOLS_SF_CHECK_STAMP=/dev/null
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$IT_BIN/ssh"
        export E2E_COMMIT_MSG="${IT_COMMIT_MSG:-$IT_COMMIT_MSG_DEFAULT}"
        printf '%b' "$input" | run_with_timeout "${IT_TIMEOUT:-120}" "$@"
    ) > "$IT_OUT" 2>&1
    IT_RC=$?
    printf '%s秒 rc=%s %s\n' "$((SECONDS - t0))" "$IT_RC" "$*" >> "$IT_STATE/runs.log"   # 所要時間の記録（遅い呼び出しの特定用）
}

it_out() { cat "$IT_OUT" 2>/dev/null; }
it_out_has() { grep -qF -- "$1" "$IT_OUT" 2>/dev/null; }

# ------------------------------------------------------------------------------
# 故障注入と、呼び出しの記録
# ------------------------------------------------------------------------------
# it_fault CMD パターン N 回数 終了コード メッセージ [遅延秒]
#   CMD（gh / sf / npm / curl）の呼び出しの引数（1 つの文字列）が、パターン（case の glob）に合うとき、
#   合う N 回目から、「回数」回だけ、メッセージを標準エラーに出して、終了コードで終わる（遅延秒だけ、待ってから）
it_fault() {
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-0}" >> "$IT_STATE/faults"
}
it_fault_clear() { rm -f "$IT_STATE"/faults "$IT_STATE"/fault.*.cnt; }

it_calls() {
    if [[ -n "${1:-}" ]]; then grep -E "^$1 " "$IT_STATE/calls.log" 2>/dev/null; else cat "$IT_STATE/calls.log" 2>/dev/null; fi
}
it_calls_clear() { : > "$IT_STATE/calls.log"; }
it_unsupported() { cat "$IT_STATE/unsupported.log" 2>/dev/null; }

# ------------------------------------------------------------------------------
# 不変条件の確認用（計画 4.5）
# ------------------------------------------------------------------------------
# ローカルの状態を、key=value の行で出す。引数: クローンのフォルダ
it_snap() {
    (
        cd "$1" || exit 1
        echo "head=$(_it_git rev-parse HEAD 2>/dev/null)"
        echo "count=$(_it_git rev-list --count HEAD 2>/dev/null)"
        echo "branches=$(_it_git branch --format='%(refname:short)' 2>/dev/null | tr '\n' ',')"
        echo "hooks=$(find .git/hooks -type f ! -name '*.sample' 2>/dev/null | wc -l | tr -d ' ')"
        echo "status=$(_it_git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    )
}
it_snap_get() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }   # 引数: it_snap の出力 キー

# リモート（bare の origin）の状態: ブランチと SHA の一覧
it_remote_snap() { _it_git --git-dir="$IT_ORIGIN" for-each-ref --format='%(refname) %(objectname)' refs/heads 2>/dev/null; }
it_remote_count() { _it_git --git-dir="$IT_ORIGIN" rev-list --count "${1:-main}" 2>/dev/null; }

# サンドボックスの中のファイル（出力・ログ・状態・作業フォルダ。.git の中は除く）に、文字列が、何ファイルにあるか
it_leak_count() {
    local n
    n=$(grep -rlF --exclude-dir=.git -- "$1" "$IT_ROOT" 2>/dev/null | grep -c . || true)
    printf '%s' "${n:-0}"
}

# ------------------------------------------------------------------------------
# fake（PATH の先頭に置く）
# ------------------------------------------------------------------------------
_it_write_fakes() {
    # --- 故障注入の共通部品（各 fake が source する）---
    cat > "$IT_BIN/_fault.sh" << 'FAULTEOF'
# _it_fault CMD "引数の文字列": ルール（$IT_STATE/faults）に合えば、遅延・メッセージ・終了をする
_it_fault() {
    local cmd="$1" args="$2" f="$IT_STATE/faults" c pat nth cnt code msg delay n key
    [[ -f "$f" ]] || return 0
    while IFS='|' read -r c pat nth cnt code msg delay; do
        [[ "$c" == "$cmd" ]] || continue
        # shellcheck disable=SC2254
        case "$args" in $pat) ;; *) continue ;; esac
        key="$IT_STATE/fault.$(printf '%s' "${c}|${pat}" | cksum | cut -d' ' -f1).cnt"
        n=$(( $(cat "$key" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$key"
        if (( n >= nth && n < nth + cnt )); then
            [[ -n "$delay" && "$delay" != "0" ]] && sleep "$delay"
            [[ -n "$msg" ]] && echo "$msg" >&2
            exit "${code:-1}"
        fi
    done < "$f"
}
_it_unsupported() { echo "$1 $2" >> "$IT_STATE/unsupported.log"; echo "fake $1: 未対応の呼び出し: $2" >&2; exit 99; }
FAULTEOF

    # --- gh（最小。状態は $IT_STATE と、bare の origin）---
    cat > "$IT_BIN/gh" << 'GHEOF'
#!/bin/bash
. "$(dirname "$0")/_fault.sh"
echo "gh $*" >> "$IT_STATE/calls.log"
_it_fault gh "$*"
_login=$(cat "$IT_STATE/gh.login" 2>/dev/null || echo "tamashimon-org")
_has_jq=0; for _a in "$@"; do [[ "$_a" == "--jq" ]] && _has_jq=1; done
case "$1 $2" in
    "auth status"|"auth login") exit 0 ;;
    "auth token") echo "fake-token"; exit 0 ;;
    "repo view")
        grep -qxF "$3" "$IT_STATE/repos" 2>/dev/null && { echo '{"name":"x"}'; exit 0; }
        echo "Could not resolve to a Repository with the name '$3'." >&2; exit 1 ;;
esac
if [[ "$1" == "api" ]]; then
    _path=""; _i=0; _prev=""
    for _a in "${@:2}"; do
        if [[ "$_a" != -* && "$_prev" != "-f" && "$_prev" != "-F" && "$_prev" != "--field" && "$_prev" != "--raw-field" && "$_prev" != "--method" && "$_prev" != "-X" && "$_prev" != "--jq" && "$_prev" != "-H" && -z "$_path" ]]; then _path="$_a"; fi
        _prev="$_a"
    done
    case "$_path" in
        user) echo "$_login"; exit 0 ;;
        user/memberships/orgs/*) cat "$IT_STATE/gh.org_role" 2>/dev/null || exit 1; exit 0 ;;
        repos/*/branches/*)
            _b="${_path##*/branches/}"
            _sha=$(git --git-dir="$IT_ORIGIN" rev-parse --verify -q "refs/heads/$_b") || { echo '{"message":"Branch not found"}' >&2; exit 1; }
            if [[ $_has_jq -eq 1 ]]; then echo "$_sha"; else echo "{\"commit\":{\"sha\":\"$_sha\"}}"; fi
            exit 0 ;;
        repos/*/git/refs)
            _ref=""; _sha=""; _prev=""
            for _a in "$@"; do
                [[ "$_prev" == "-f" || "$_prev" == "-F" || "$_prev" == "--field" || "$_prev" == "--raw-field" ]] && { case "$_a" in ref=*) _ref="${_a#ref=}" ;; sha=*) _sha="${_a#sha=}" ;; esac; }
                _prev="$_a"
            done
            [[ -n "$_ref" && -n "$_sha" ]] || _it_unsupported gh "$*"
            git --git-dir="$IT_ORIGIN" update-ref "$_ref" "$_sha" || exit 1
            echo "{\"ref\":\"$_ref\"}"; exit 0 ;;
    esac
fi
_it_unsupported gh "$*"
GHEOF

    # --- sf（最小。ログイン状態は $IT_STATE/sf.alias）---
    cat > "$IT_BIN/sf" << 'SFEOF'
#!/bin/bash
. "$(dirname "$0")/_fault.sh"
echo "sf $*" >> "$IT_STATE/calls.log"
_it_fault sf "$*"
_alias=$(cat "$IT_STATE/sf.alias" 2>/dev/null || true)
[[ "$1" == "--version" ]] && { echo "@salesforce/cli/2.0.0 linux-x64 node-v20.0.0"; exit 0; }
case "$1 $2" in
    "org display")
        if [[ -z "$_alias" ]]; then echo '{"status":1,"name":"NoDefaultEnvError","message":"No default org"}'; exit 1; fi
        echo "{\"status\":0,\"result\":{\"alias\":\"$_alias\",\"id\":\"00D000000000001AAA\",\"username\":\"it@example.invalid\",\"instanceUrl\":\"https://it.my.salesforce.com\",\"connectedStatus\":\"Connected\"}}"
        exit 0 ;;
    "org login")
        _al=""; _p=""; for _a in "$@"; do [[ "$_p" == "--alias" || "$_p" == "-a" ]] && _al="$_a"; _p="$_a"; done
        echo "${_al:-itorg}" > "$IT_STATE/sf.alias"; exit 0 ;;
    "org logout") : > "$IT_STATE/sf.alias"; exit 0 ;;
    "org open"|"alias unset"|"alias set"|"config set"|"config unset") exit 0 ;;
    "alias list") echo '{"status":0,"result":[]}'; exit 0 ;;
    "config get") echo '{"status":0,"result":[]}'; exit 0 ;;
    "project generate")
        _out="."; _name="package.xml"; _p=""; _files=()
        for _a in "${@:3}"; do
            case "$_p" in
                --output-dir|-d) _out="$_a" ;;
                --name|-n) _name="$_a" ;;
                --source-dir|-p) _files+=("$_a") ;;
            esac
            _p="$_a"
        done
        mkdir -p "$_out"
        { echo '<?xml version="1.0" encoding="UTF-8"?>'
          echo '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
          for _f in "${_files[@]}"; do _m=$(basename "$_f"); echo "    <types><members>${_m%%.*}</members><name>ApexClass</name></types>"; done
          echo '    <version>60.0</version>'; echo '</Package>'; } > "$_out/$_name"
        echo "successfully wrote $_name to $_out"; exit 0 ;;
    "project deploy")
        if [[ -f "$IT_STATE/sf.lock" ]]; then echo "UNABLE_TO_LOCK_ROW: unable to obtain exclusive access to this record" >&2; exit 1; fi
        if [[ -f "$IT_STATE/sf.testfail" ]]; then echo "Test Failures: SampleTest.testSomething: System.AssertException" >&2; exit 1; fi
        echo "Deploy Succeeded."; echo "Test Results Summary"; echo "Passing: 1"; echo "Failing: 0"
        exit 0 ;;
esac
_it_unsupported sf "$*"
SFEOF

    # --- npm / curl / code / ブラウザ ---
    cat > "$IT_BIN/npm" << 'NPMEOF'
#!/bin/bash
. "$(dirname "$0")/_fault.sh"
echo "npm $*" >> "$IT_STATE/calls.log"
_it_fault npm "$*"
exit 0
NPMEOF
    cat > "$IT_BIN/curl" << 'CURLEOF'
#!/bin/bash
. "$(dirname "$0")/_fault.sh"
echo "curl $*" >> "$IT_STATE/calls.log"
_it_fault curl "$*"
echo '{"ok":true}'
exit 0
CURLEOF
    cat > "$IT_BIN/code" << 'CODEEOF'
#!/bin/bash
# コミットメッセージの入力（code --wait <ファイル>）の代わりに、IT の既定のメッセージを書く
_last=""; _wait=0
for _a in "$@"; do [[ "$_a" == "--wait" || "$_a" == "-w" ]] && _wait=1; _last="$_a"; done
echo "code $*" >> "$IT_STATE/calls.log"
[[ $_wait -eq 1 && -f "$_last" ]] && printf '%s\n' "${E2E_COMMIT_MSG:-it}" > "$_last"
exit 0
CODEEOF
    # ssh の代わり: git が送る「git-upload-pack / git-receive-pack」を、ローカルの bare に向けて実行する
    cat > "$IT_BIN/ssh" << "SSHEOF"
#!/bin/bash
_cmd="${!#}"
_svc="${_cmd%% *}"
case "$_svc" in
    git-upload-pack|git-receive-pack) exec "$_svc" "$IT_ORIGIN" ;;
esac
echo "fake ssh: 未対応の呼び出し: $*" >&2
exit 99
SSHEOF
    local n
    for n in open start xdg-open wslview powershell.exe; do
        printf '#!/bin/bash\nexit 0\n' > "$IT_BIN/$n"
    done
    chmod +x "$IT_BIN"/*
}

# git の update-git-for-windows（本物の更新）だけを、止める git の包み。スタンプを消して sf-upgrade を動かすテストの前に、必ず呼ぶ
it_block_git_update() {
    [[ -f "$IT_STATE/realgit" ]] || command -v git > "$IT_STATE/realgit"   # 本物の git の場所（2 回目以降は、包みを指さないように、最初の 1 回だけ）
    cat > "$IT_BIN/git" << 'GITEOF'
#!/bin/bash
if [[ "$1" == "update-git-for-windows" ]]; then echo "git $*" >> "$IT_STATE/calls.log"; echo "（結合テスト: 本物の更新は、実行しない）"; exit 0; fi
exec "$(cat "$IT_STATE/realgit")" "$@"
GITEOF
    chmod +x "$IT_BIN/git"
}

# fake の呼び出しの記録から、「外部へ書き込む」呼び出しだけを出す（確認で止めたはずのコマンドが、書き込んでいないことの確認用）
#   gh: secret / variable / workflow / release / repo create・delete・edit / pr create・merge・close・comment・edit / api の書き込み
#   sf: dry-run でない deploy / org login・logout
it_mutating_calls() {
    grep -E '^gh (secret|variable|workflow|release|label|ruleset) |^gh repo (create|delete|edit|rename) |^gh pr (create|merge|close|comment|edit|review) |^gh api .*(--method|-X) *(POST|PUT|PATCH|DELETE)|^gh api .*(-f|-F|--field|--raw-field) |^sf org (login|logout) ' "$IT_STATE/calls.log" 2>/dev/null
    grep -E '^sf project deploy start ' "$IT_STATE/calls.log" 2>/dev/null | grep -v -- '--dry-run'
    return 0
}

# bare の origin に、プッシュを拒否させる／戻す（プッシュ失敗の再現。実 git の pre-receive フック）
it_origin_reject() {
    if [[ "$1" == "on" ]]; then
        printf '#!/bin/sh\necho "remote: 拒否されました（結合テスト）" >&2\nexit 1\n' > "$IT_ORIGIN/hooks/pre-receive"
        chmod +x "$IT_ORIGIN/hooks/pre-receive"
    else
        rm -f "$IT_ORIGIN/hooks/pre-receive"
    fi
}
