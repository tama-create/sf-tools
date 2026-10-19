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
#   it_leak_count 文字列 [除外するファイル名]   サンドボックス内のファイル（出力・ログ・状態・一時ファイル。fake が保持する秘密の保管場所は除く）に、文字列が何件あるか（秘密の漏れの確認）
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
    # https://github.com/ を ssh://git@github.com/ に読み替える（fake の ssh が、ローカルの bare に向ける。理由は、it_seed_repo の説明）
    _it_git config --global "url.ssh://git@github.com/.insteadOf" "https://github.com/"
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
    # sf-start がバックグラウンドで起動した sf-install などが、まだ書き込んでいることがある。消えるまで、数回やり直す
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        [[ -n "${IT_ROOT:-}" && -d "$IT_ROOT" ]] || break
        rm -rf "$IT_ROOT" 2>/dev/null
        [[ -d "$IT_ROOT" ]] && sleep 2
    done
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
        mkdir -p "$IT_ROOT/tmp"; export TMPDIR="$IT_ROOT/tmp"   # 一時ファイルの残りを、サンドボックスの中で検査できるように
        export SF_LAUNCHER_ACTIVE=1 SF_TOOLS_SF_CHECK_STAMP=/dev/null
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$IT_BIN/ssh"
        export E2E_COMMIT_MSG="${IT_COMMIT_MSG:-$IT_COMMIT_MSG_DEFAULT}"
        printf '%b' "$input" | run_with_timeout "${IT_TIMEOUT:-300}" "$@"
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
    n=$(grep -rlF --exclude-dir=.git --exclude-dir=secrets --exclude-dir=variables --exclude="${2:-.it-no-exclude}" -- "$1" "$IT_ROOT" 2>/dev/null | grep -c . || true)
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
    "--version "*) echo "gh version 2.50.0 (2026-01-01)"; exit 0 ;;
    "auth token") echo "fake-token"; exit 0 ;;
    "repo create")
        # 新しいリポジトリ = 空の bare の origin（すでに登録されていれば、名前の衝突で失敗する）
        grep -qxF "$3" "$IT_STATE/repos" 2>/dev/null && { echo "GraphQL: Name already exists on this account (createRepository)" >&2; exit 1; }
        [[ -d "$IT_ORIGIN" ]] || git init -q --bare -b main "$IT_ORIGIN" || exit 1
        echo "$3" >> "$IT_STATE/repos"; echo "https://github.com/$3"; exit 0 ;;
    "repo edit") exit 0 ;;
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
        user)
            for _a in "$@"; do
                [[ "$_a" == "--include" ]] && { printf "HTTP/2.0 200 OK
X-Oauth-Scopes: %s

{\"login\":\"%s\"}
" "$(cat "$IT_STATE/gh.scopes" 2>/dev/null || echo "repo, workflow")" "$_login"; exit 0; }
            done
            echo "$_login"; exit 0 ;;
        repos/*/rulesets)
            # 一覧（GET）: 保存済みの名前に合うものの ID を出す（--jq の select(.name=="…") の名前で探す）。作成（POST --input -）: 本文を保存する
            mkdir -p "$IT_STATE/rulesets"
            if [[ " $* " == *" --method POST "* || " $* " == *" -X POST "* ]]; then
                _n=$(( $(ls "$IT_STATE/rulesets" | wc -l | tr -d ' ') + 1 )); cat > "$IT_STATE/rulesets/$_n"; echo "{\"id\":$_n}"; exit 0
            fi
            _want=$(printf '%s' "$*" | sed -n 's/.*select(.name=="\([^"]*\)").*/\1/p')
            for _f in $(ls "$IT_STATE/rulesets" 2>/dev/null | sort -n); do
                tr -d ' \n' < "$IT_STATE/rulesets/$_f" | grep -q "\"name\":\"$_want\"" && echo "$_f"
            done; exit 0 ;;
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
        repos/*/*)   # リポジトリの情報（permissions.admin など）。他のパターンに合わなかった repos/OWNER/REPO だけ
            case "$_path" in repos/*/*/*) ;; *)
                if [[ $_has_jq -eq 1 ]]; then echo "$(cat "$IT_STATE/gh.repo_admin" 2>/dev/null || echo true)"; else echo "{\"permissions\":{\"admin\":true}}"; fi; exit 0 ;;
            esac ;;
    esac
fi
case "$1 $2" in
    "workflow run")
        # ワークフローの手動起動: 実行の記録を作る（結果は state/gh.run_conclusion。既定は success）
        _wf="$3"; _ev=workflow_dispatch; mkdir -p "$IT_STATE/runs"
        _id=$(( $(ls "$IT_STATE/runs" | wc -l | tr -d " ") + 1001 ))
        printf "wf=%s
event=%s
status=completed
conclusion=%s
" "$_wf" "$_ev" "$(cat "$IT_STATE/gh.run_conclusion" 2>/dev/null || echo success)" > "$IT_STATE/runs/$_id"
        exit 0 ;;
    "run list")
        _wf=""; _ev=""; _jq=""; _p=""; for _a in "$@"; do case "$_p" in --workflow) _wf="$_a" ;; --event) _ev="$_a" ;; --jq) _jq="$_a" ;; esac; _p="$_a"; done
        _last=""; for _f in $(ls "$IT_STATE/runs" 2>/dev/null | sort -n); do
            grep -qxF "wf=$_wf" "$IT_STATE/runs/$_f" || continue
            [[ -z "$_ev" ]] || grep -qxF "event=$_ev" "$IT_STATE/runs/$_f" || continue
            _last="$_f"; done
        if [[ -n "$_last" ]]; then echo "$_last"; else case "$_jq" in *"// 0"*) echo 0 ;; esac; fi; exit 0 ;;
    "run view")
        _id="$3"; [[ -f "$IT_STATE/runs/$_id" ]] || { echo "HTTP 404: Not Found" >&2; exit 1; }
        _jq=""; _p=""; for _a in "$@"; do [[ "$_p" == "--jq" ]] && _jq="$_a"; _p="$_a"; done
        case "$_jq" in
            .status) sed -n "s/^status=//p" "$IT_STATE/runs/$_id" ;;
            .conclusion) sed -n "s/^conclusion=//p" "$IT_STATE/runs/$_id" ;;
            .attempt) echo 1 ;;
            *) echo "Slack response: {\"ok\":true}" ;;
        esac; exit 0 ;;
    "run cancel"|"run rerun") exit 0 ;;
    "secret set")   mkdir -p "$IT_STATE/secrets"; cat > "$IT_STATE/secrets/$3"; exit 0 ;;   # 値は、標準入力から読み、state/secrets にだけ置く（呼び出しの記録には、値を残さない）
    "secret list")  ls "$IT_STATE/secrets" 2>/dev/null; exit 0 ;;
    "variable set")
        _v=""; _p=""; for _a in "$@"; do [[ "$_p" == "--body" || "$_p" == "-b" ]] && _v="$_a"; _p="$_a"; done
        mkdir -p "$IT_STATE/variables"; printf "%s" "$_v" > "$IT_STATE/variables/$3"; exit 0 ;;
    "variable get")  [[ -f "$IT_STATE/variables/$3" ]] && { cat "$IT_STATE/variables/$3"; exit 0; }; echo "HTTP 404: Not Found" >&2; exit 1 ;;
    "variable list") ls "$IT_STATE/variables" 2>/dev/null; exit 0 ;;
esac
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
    "data query")
        case "$*" in *"Profile.Name"*) echo "{\"status\":0,\"result\":{\"records\":[{\"Profile\":{\"Name\":\"System Administrator\"}}],\"totalSize\":1}}"; exit 0 ;; esac
        echo "{\"status\":0,\"result\":{\"records\":[{\"Id\":\"00D000000000001AAA\",\"Name\":\"IT Org\",\"IsSandbox\":false,\"OrganizationType\":\"Developer Edition\",\"TrialExpirationDate\":null}],\"totalSize\":1}}"; exit 0 ;;
    "sgd source")
        # 差分の抽出（sf sgd source delta ... --output-dir D）: 出力フォルダだけ作る（package.xml は作らない）
        _o=""; _p=""; for _a in "$@"; do [[ "$_p" == "--output-dir" ]] && _o="$_a"; _p="$_a"; done
        [[ -f "$IT_STATE/sf.sgdfail" ]] && { cat "$IT_STATE/sf.sgdfail" >&2; exit 1; }
        [[ -n "$_o" ]] && mkdir -p "$_o"; exit 0 ;;
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
    "project retrieve")
        case "$*" in *ExtlClntAppGlobalOauthSettings:*) ;; *)
            # 一般の retrieve（sf-metasync など）: state/sf.retrieve の「パス|内容」の行を、カレントに書く。state/sf.retrievefail があれば、その内容で失敗する
            [[ -f "$IT_STATE/sf.retrievefail" ]] && { cat "$IT_STATE/sf.retrievefail" >&2; exit 1; }
            if [[ -f "$IT_STATE/sf.retrieve" ]]; then
                while IFS="|" read -r _fp _fc; do [[ -n "$_fp" ]] || continue; mkdir -p "$(dirname "$_fp")"; printf "%s
" "$_fc" > "$_fp"; done < "$IT_STATE/sf.retrieve"
            fi
            exit 0 ;;
        esac
        # コンシューマー鍵の取得（ExtlClntAppGlobalOauthSettings:名前_glbloauth）。鍵の値は、名前から決まる目印
        _m=""; _p=""; for _a in "$@"; do [[ "$_p" == "--metadata" ]] && _m="$_a"; _p="$_a"; done
        _n="${_m#*:}"; mkdir -p force-app/main/default/extlClntAppGlobalOauthSets
        printf "<ExtlClntAppGlobalOauthSettings><consumerKey>ITECAKEY-%s</consumerKey></ExtlClntAppGlobalOauthSettings>
" "$_n" > "force-app/main/default/extlClntAppGlobalOauthSets/${_n}.ecaGlblOauth-meta.xml"
        exit 0 ;;
    "project deploy")
        if [[ -f "$IT_STATE/sf.deployfail" ]]; then cat "$IT_STATE/sf.deployfail" >&2; exit 1; fi
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
if [[ -f "$IT_STATE/ssh.fail" ]]; then echo "ssh: Could not resolve hostname github.com: Temporary failure in name resolution" >&2; exit 255; fi
_cmd="${!#}"
_svc="${_cmd%% *}"
case "$_svc" in
    git-upload-pack|git-receive-pack)
        # 登録されているリポジトリ（OWNER/REPO。state/repos）だけに、つなぐ。別の名前は、「見つからない」（別のリポジトリへの誤接続の再現）
        _q="'"; _repo="${_cmd#* }"; _repo="${_repo//$_q/}"; _repo="${_repo%.git}"; _repo="${_repo#/}"
        if [[ -f "$IT_STATE/repos" ]] && ! grep -qixF "$_repo" "$IT_STATE/repos"; then
            echo "ERROR: Repository not found." >&2; echo "fatal: Could not read from remote repository." >&2; exit 128
        fi
        exec "$_svc" "$IT_ORIGIN" ;;
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

# ------------------------------------------------------------------------------
# 作業用のクローンを、手早く作る（sf-job・sf-start・sf-install を通さない版。通しは A13a が確認する）
# ------------------------------------------------------------------------------
# it_make_clone 名前 ブランチ [分岐元]  → クローンを $IT_WORK/名前/$IT_REPO に作り、IT_CL に入れる
#   ・origin からクローン → ブランチを作って push → sf のログイン状態 → sf-hook でフック設置 → release/ブランチ/ を準備
it_make_clone() {
    local name="$1" branch="$2" base="${3:-main}"
    IT_CL="$IT_WORK/$name/$IT_REPO"
    mkdir -p "$IT_WORK/$name"
    it_run "$IT_WORK/$name" git clone -q "https://github.com/${IT_OWNER}/${IT_REPO}.git" "$IT_CL" || return 1
    [[ $IT_RC -eq 0 ]] || return 1
    it_run "$IT_CL" bash -c "git checkout -q -b '$branch' 'origin/$base' && git push -q -u origin '$branch'" || return 1
    [[ $IT_RC -eq 0 ]] || return 1
    echo "itorg" > "$IT_STATE/sf.alias"
    it_run "$IT_CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh" || return 1
    [[ $IT_RC -eq 0 ]] || return 1
    mkdir -p "$IT_CL/sf-tools/release/$branch"
    printf '%s\n' "$branch" > "$IT_CL/sf-tools/release/branch_name.txt"
    cp "$IT_HOME/sf-tools/templates/sf-tools/release/__BRANCH__/"*.txt "$IT_CL/sf-tools/release/$branch/"
    mkdir -p "$IT_CL/force-app/main/default/classes"
    return 0
}

# Apex クラスを 1 つ作る（クラスと meta）。引数: クローン 名前 [内容]
it_add_class() {
    printf '%s\n' "${3:-public class $2 { }}" > "$1/force-app/main/default/classes/$2.cls"
    printf '<?xml version="1.0"?>\n<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata"><apiVersion>60.0</apiVersion><status>Active</status></ApexClass>\n' \
        > "$1/force-app/main/default/classes/$2.cls-meta.xml"
}

# deploy-target.txt を書く。引数: クローン ブランチ [ファイル...]（[files] セクション）
it_set_deploy_target() {
    local cl="$1" branch="$2"; shift 2
    { echo "[files]"; for f in "$@"; do echo "$f"; done; } > "$cl/sf-tools/release/$branch/deploy-target.txt"
}

# bare の origin に、別の開発者として、コミットを積む（フックを通さない）。引数: ブランチ ファイルのパス 内容 メッセージ
it_origin_commit() {
    local br="$1" path="$2" content="$3" msg="$4" w="$IT_ROOT/other.$$.$RANDOM"
    _it_git clone -q "$IT_ORIGIN" "$w" || return 1
    ( cd "$w" || exit 1
      _it_git checkout -q "$br" || exit 1
      mkdir -p "$(dirname "$path")"; printf '%s\n' "$content" > "$path"
      _it_git add -A && _it_git commit -q -m "$msg" --no-verify && _it_git push -q origin "$br" ) || { rm -rf "$w"; return 1; }
    rm -rf "$w"
}

# fake の ssh（git の通信）を失敗させる／戻す（ネットワークの断の再現）
it_ssh_fail() {
    if [[ "$1" == "on" ]]; then : > "$IT_STATE/ssh.fail"; else rm -f "$IT_STATE/ssh.fail"; fi
}

# デプロイを失敗させる／戻す（コンパイルエラーなど）。引数: on メッセージ | off
it_deploy_fail() {
    if [[ "$1" == "on" ]]; then printf '%s\n' "${2:-Deploy failed}" > "$IT_STATE/sf.deployfail"; else rm -f "$IT_STATE/sf.deployfail"; fi
}

# ~/sf-tools の origin（ローカルの bare）に、新しいコミットを積む（利用者の ~/sf-tools が古くなった状態を作る）
it_sftools_advance() {
    local w="$IT_ROOT/sftools-w.$$"
    _it_git clone -q "$IT_ROOT/sftools-origin.git" "$w" || return 1
    ( cd "$w" || exit 1
      echo "# 新しい版 $RANDOM" >> README.md
      _it_git add -A && _it_git commit -q -m "sf-tools の新しい版" && _it_git push -q origin main ) || { rm -rf "$w"; return 1; }
    rm -rf "$w"
}

# 組織からの取得（retrieve）で、カレントに書かれるファイルを決める。引数: 「パス|内容」…（なければ、何も書かない）
it_set_retrieve() { : > "$IT_STATE/sf.retrieve"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$IT_STATE/sf.retrieve"; done; }
