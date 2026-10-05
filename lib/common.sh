#!/bin/bash
# ==============================================================================
# common.sh - sf-tools 共通関数ライブラリ
# ==============================================================================
# sf-tools の全スクリプトが source して使用する共通ライブラリです。
#
# 【source 前に必須の変数定義】
#   readonly SCRIPT_NAME=...   スクリプト名（拡張子なし）
#   readonly LOG_FILE=...      ログファイルパス（例: ./logs/${SCRIPT_NAME}.log）
#   readonly LOG_MODE=...      NEW=実行ごとにリセット / APPEND=追記
#   ※ SILENT_EXEC は source 後に自動設定されます（--verbose / -v オプションで制御）
#
# 【提供する関数】
#   log LEVEL MESSAGE [DEST]  ... 画面とログファイルへ出力
#   run CMD [ARGS...]         ... コマンドを実行してログに記録
#   die MESSAGE [EXIT_CODE]   ... エラーログを出力して終了
#   get_target_org [ALIAS]    ... 接続先組織エイリアスを解決
#   check_force_dir           ... force-* ディレクトリ内か確認
#   check_home_dir            ... ~/home/{owner}/{company}/ の正しい階層か確認し GITHUB_OWNER/COMPANY_NAME をセット
#   check_gh_owner OWNER      ... gh 認証ユーザーが期待するオーナーと一致するか確認（組織の有効な admin も許可）
#   is_gitbash                     ... Windows の Git Bash か判定（$OSTYPE が msys / mingw / cygwin）
#   run_isolated_home CMD [ARGS]   ... 一時的なホームフォルダの中でコマンドを実行（sf の認証・エイリアスを隔離）
#   check_sf_cli [--warn-only] [--cache] ... sf が終了コードを正しく返すか確認（npm 版が前提。NG なら案内して die）
#   open_browser URL               ... OS を判定してブラウザを開く（Git Bash/WSL/macOS/Linux 対応）
#   read_input VARNAME [PROMPT]    ... readline 対応インタラクティブ入力
#   read_key VARNAME [PROMPT] [V]  ... 1文字即時入力（Enter 不要・空 Enter 無視）
#   press_enter [MSG]              ... Enter 待ち（q で中断）
#   read_or_quit VARNAME PROMPT    ... テキスト入力（空 Enter 無視・q で中断）
#   read_secret VARNAME PROMPT     ... 秘密情報の入力（画面に表示しない・空 Enter 無視・q で中断）
#   ask_yn QUESTION                ... Y/N/q 確認（1文字即時入力）
#
# 【戻り値定数】
#   RET_OK=0        正常終了
#   RET_NG=1        異常終了
#   RET_NO_CHANGE=2 変更なし（NothingToDeploy）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Bash バージョンチェック
# ------------------------------------------------------------------------------
# nameref (local -n) は Bash 4.3 以降の機能。
# 未満の場合は環境アップグレードを促して即終了する。
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "[ERROR] Bash 4.3 以上が必要です（現在: ${BASH_VERSION}）" >&2
    echo "  macOS の場合: brew install bash" >&2
    echo "  その後 /etc/shells に追加して chsh で既定シェルを変更してください。" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. 状態定数
# ------------------------------------------------------------------------------
readonly RET_OK=0           # 正常終了
readonly RET_NG=1           # 異常終了
readonly RET_NO_CHANGE=2    # 変更なし

# ------------------------------------------------------------------------------
# 3. 必須変数のバリデーションとログ初期化
# ------------------------------------------------------------------------------
if [[ -z "${LOG_FILE:-}" ]]; then
    echo "[FATAL ERROR] LOG_FILE が未定義です。source 前に定義してください。" >&2
    exit 1
fi

# force-* ディレクトリ内でのみ実行を許可（mkdir-p より前に実行）
# SF_INIT_MODE=1 の場合は sf-init.sh による初期化実行のためチェックをスキップする
if [[ "${SF_INIT_MODE:-0}" != "1" ]]; then
    [[ "$(basename "$PWD")" =~ ^force- ]] \
        || { echo "[ERROR] このスクリプトは 'force-*' ディレクトリ内で実行してください。" >&2; exit 1; }
fi

mkdir -p "$(dirname "$LOG_FILE")"
chmod 700 "$(dirname "$LOG_FILE")" 2>/dev/null || true  # run 不使用: Windows では効果なし・意図的エラー無視
[[ "${LOG_MODE:-}" == "NEW" ]] && : > "$LOG_FILE"

# SILENT_EXEC: --verbose / -v が指定されていれば 0（応答表示あり）、デフォルト 1（応答表示なし）
# ※ 各スクリプトで宣言不要。common.sh が $@ をスキャンして自動設定します。
_sf_verbose=0
for _sf_arg in "$@"; do
    [[ "$_sf_arg" == "--verbose" || "$_sf_arg" == "-v" ]] && _sf_verbose=1 && break
done
readonly SILENT_EXEC=$(( _sf_verbose ? 0 : 1 ))
unset _sf_verbose _sf_arg

# ------------------------------------------------------------------------------
# 4. カラー定義（端末非対応環境では空文字に設定して制御コードの混入を防ぐ）
# ------------------------------------------------------------------------------
if [ -t 0 ] || [ -t 2 ]; then
    readonly CLR_INFO='\033[36m'     # シアン    (情報・進行中)
    readonly CLR_SUCCESS='\033[32m'  # グリーン  (成功・完了)
    readonly CLR_WARNING='\033[33m'  # イエロー  (警告)
    readonly CLR_ERR='\033[31m'      # レッド    (エラー)
    readonly CLR_FATAL='\033[1;31m'  # 太字レッド (致命的エラー・即終了)
    readonly CLR_PROMPT='\033[35m'   # マゼンタ  (ユーザー入力要求)
    readonly CLR_RESET='\033[0m'     # リセット
else
    readonly CLR_INFO=''
    readonly CLR_SUCCESS=''
    readonly CLR_WARNING=''
    readonly CLR_ERR=''
    readonly CLR_FATAL=''
    readonly CLR_PROMPT=''
    readonly CLR_RESET=''
fi

# ------------------------------------------------------------------------------
# 5. show_help - --help / -h オプションの処理
# ------------------------------------------------------------------------------
# 呼び出し元スクリプトの冒頭コメント（2つ目の === と 3つ目の === の間）を
# 画面に出力して終了する。
show_help() {
    local script="${BASH_SOURCE[1]}"
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "$script"
    exit 0
}

# ------------------------------------------------------------------------------
# 6. log - 画面とログファイルへの統合出力
# ------------------------------------------------------------------------------
# 【使い方】
#   log LEVEL MESSAGE [DEST]
#
# 【引数】
#   LEVEL   : 出力レベル（下記参照）
#   MESSAGE : 出力するメッセージ本文
#   DEST    : 出力先。省略時は BOTH。
#               BOTH   = 画面とログファイルの両方（デフォルト）
#               SCREEN = 画面のみ
#               FILE   = ログファイルのみ
#
# 【LEVEL の種類と用途】
#   HEADER  : 処理ブロックの開始を区切り線つきで強調表示する
#   INFO    : 処理の進行状況を通知する（シアン）
#   SUCCESS : 処理の正常完了を通知する（グリーン）
#   WARNING : 問題があるが続行可能な状態を通知する（イエロー）
#   ERROR   : エラーが発生したが処理を続行する（レッド）
#   FATAL   : 致命的エラー。die() が使用する。即終了（太字レッド）
#   CMD     : run 関数が実行コマンドを記録するために使用する（色なし）
#
# 【使用例】
#   log "INFO"    "処理を開始します..."
#   log "SUCCESS" "完了しました。"
#   log "WARNING" "接続に失敗しました（続行します）"
#   log "ERROR"   "エラーが発生しました（続行します）"
#   log "HEADER"  "スタートアップを開始します"
# ------------------------------------------------------------------------------
log() {
    local level="$1" message="$2" dest="${3:-BOTH}"
    local ts
    ts=$(date +'%Y-%m-%d %H:%M:%S')

    # A. ログファイル出力 (色コードなし)
    if [[ "$dest" == "BOTH" || "$dest" == "FILE" ]]; then
        if [[ "$level" == "HEADER" ]]; then
            printf "\n[%s] [=== %s ===]\n" "$ts" "$message" >> "$LOG_FILE"
        elif [[ "$level" == "CMD" ]]; then
            printf "[%s] [CMD] Command: %s\n" "$ts" "$message" >> "$LOG_FILE"
        else
            printf "[%s] [%s] %s\n" "$ts" "$level" "$message" >> "$LOG_FILE"
        fi
    fi

    # B. 画面出力 (色付き)
    if [[ "$dest" == "BOTH" || "$dest" == "SCREEN" ]]; then
        case "$level" in
            HEADER)
                echo "-------------------------------------------------------" >&2
                echo -e "${CLR_INFO}>> ${message}${CLR_RESET}" >&2
                echo "-------------------------------------------------------" >&2 ;;
            INFO)
                echo -e "${CLR_INFO}[INFO] ${message}${CLR_RESET}" >&2 ;;
            SUCCESS)
                echo -e "${CLR_SUCCESS}[SUCCESS] ${message}${CLR_RESET}" >&2 ;;
            WARNING)
                echo -e "${CLR_WARNING}[WARNING] ${message}${CLR_RESET}" >&2 ;;
            ERROR)
                echo -e "${CLR_ERR}[ERROR] ${message}${CLR_RESET}" >&2 ;;
            FATAL)
                echo -e "${CLR_FATAL}[FATAL] ${message}${CLR_RESET}" >&2 ;;
            CMD)
                echo "> Command: ${message}" >&2 ;;
            *)
                echo -e "${message}" >&2 ;;
        esac
    fi
    return $RET_OK
}

# _mask_secrets - 文字列中の Token らしい文字列を伏せ字にする（コマンドのログへの混入を防ぐ保険）
# ------------------------------------------------------------------------------
# 【使い方】
#   masked=$(_mask_secrets "$text")
#
# 【対象】
#   GitHub の Token（ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_）と Slack の Token（xoxb- 等）
#   本来は Token をコマンドの引数に含めない（環境変数・標準入力・GIT_ASKPASS で渡す）。これは万一の保険。
# ------------------------------------------------------------------------------
_mask_secrets() {
    printf '%s' "$1" | sed -E \
        -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1***masked***/g' \
        -e 's/github_pat_[A-Za-z0-9_]+/github_pat_***masked***/g' \
        -e 's/(xox[abprs]-)[A-Za-z0-9-]+/\1***masked***/g'
}

# ------------------------------------------------------------------------------
# 6. run - コマンド実行ラッパー（通常呼び出し・命令置換の両対応）
# ------------------------------------------------------------------------------
# 【使い方】
#   run CMD [ARGS...]           # 通常呼び出し
#   VAR=$(run CMD [ARGS...])    # 命令置換（出力を変数に受け取る）
#
# 【引数】
#   CMD     : 実行するコマンド
#   ARGS... : コマンドに渡す引数
#
# 【戻り値】
#   RET_OK        (0) : 成功
#   RET_NO_CHANGE (2) : 変更なし（NothingToDeploy / No local changes to deploy）
#   RET_NG        (1) : 失敗
#
# 【命令置換での自動判定】
#   stdout が端末でない場合（命令置換 $(...) 内）は出力を自動的に返します。
#   通常呼び出し時は出力を返しません。この切り替えは自動で行われます。
#   命令置換内でも CMD ログ行（> Command: ...）はコンソールに表示されます。
#   例: VAR=$(run git symbolic-ref --short HEAD)
#
# 【SILENT_EXEC の挙動】
#   Command行（> Command: ...）は SILENT_EXEC の値にかかわらず常にコンソールへ表示します。
#   SILENT_EXEC=1 : コマンドの応答（出力）をログファイルのみに記録（コンソールには表示しない）【デフォルト】
#   SILENT_EXEC=0 : コマンドの応答（出力）をコンソールとログファイルの両方に表示（--verbose / -v で有効）
#
# 【ログファイルへの出力】
#   コマンド出力に含まれる ANSI エスケープコードおよび絵文字を除去してから記録します。
#   各行には "[timestamp] [OUT]" のプレフィックスを付与します（空行は除く）。
#
# 【成功判定のルール】
#   終了コードが 0 であれば成功とします（終了コードのみを信頼する。出力の文字列では判定しない）。
#   ただし、出力に NothingToDeploy / "No local changes to deploy" が含まれる場合は RET_NO_CHANGE とします
#   （終了コードより優先）。
#   ※ 以前は出力の成功キーワード（"Successfully" 等）でも RET_OK にしていたが、失敗を成功と誤判定する
#     恐れがあるため削除した（2026-03-24）。
#   ※ Salesforce CLI が、成功しても終了コード 1 を返す環境（Windows の Git Bash で、公式インストーラー版を
#     自動更新した場合）では、終了コードに頼る処理が失敗扱いになる。そのため sf-tools は Salesforce CLI の
#     npm 版を前提とし、sf-init.sh / sf-start.sh / sf-release.sh / sf-metasync.sh / sf-update-secret.sh の
#     最初に check_sf_cli で確認する（NG なら中断。sf-install.sh だけは警告のみ）。sf の成否は、すべて終了コードで判定する。
#
# 【使用例】
#   run bash "./sf-install.sh"                      || die "失敗"
#   run mkdir -p "release/${BRANCH_NAME}"           || return $RET_NG
#   run sf org login web --set-default --alias "$A" || die "失敗"
#   printf '{"target-org": "%s"}\n' "$A" | run tee .sf/config.json
#   BRANCH=$(run git symbolic-ref --short HEAD)
#   JSON=$(run sf org display --json || echo "")
# ------------------------------------------------------------------------------
run() {
    local cmd=("$@")
    # git add -A との競合を避けるため、プロジェクト内ディレクトリは使わずシステム tmp を使用
    local _run_tmpdir="${TMPDIR:-/tmp}"
    local tmp_out
    tmp_out=$(mktemp "${_run_tmpdir}/cmd_out.XXXXXX") \
        || tmp_out="${_run_tmpdir}/cmd_out_$$_${RANDOM}.tmp"  # run 不使用: 変数代入・mktemp フォールバック
    local status

    log "CMD" "[${SCRIPT_NAME}.sh] $(_mask_secrets "${cmd[*]}")"

    if [[ "${SILENT_EXEC:-}" != "1" ]]; then
        # リアルタイム表示: stderr に流しつつ tmp に保存（命令置換の stdout には影響しない）
        "${cmd[@]}" 2>&1 | tee "$tmp_out" >&2
        status="${PIPESTATUS[0]}"
    else
        "${cmd[@]}" > "$tmp_out" 2>&1
        status=$?
    fi

    # 命令置換 $(...) 内の場合（stdout が端末でない）は出力を返す
    if [[ ! -t 1 ]]; then
        cat "$tmp_out"
    fi

    local is_success=$RET_NG
    # A. 変更なし（NothingToDeploy）の検知（終了コードより優先）
    if grep -qE "NothingToDeploy|No local changes to deploy" "$tmp_out"; then
        log "WARNING" "組織との差分が検出されませんでした (NothingToDeploy)。ローカルのソースはすでに組織と一致しています。"
        is_success=$RET_NO_CHANGE
    # B. 成功判定（終了コードのみを信頼する）
    elif [[ $status -eq 0 ]]; then
        is_success=$RET_OK
    fi

    local log_ts
    log_ts=$(date +'%Y-%m-%d %H:%M:%S')
    # ANSI エスケープコード・絵文字を除去してから記録
    # LC_ALL=C により . が任意の1バイトにマッチする（日本語は \xe3〜\xe9 始まりのため除去対象外）
    #   \x1b\[...[a-zA-Z] : ANSI エスケープコード
    #   \xf0...            : 4バイトUTF-8絵文字 (U+10000 以降: 🔥✨ 等)
    #   \xe2..             : 3バイトUTF-8絵文字 (U+2000-U+2FFF: ✅❌⚠️ 等)
    #   \xef\xb8\x8f       : 異体字セレクタ U+FE0F
    LC_ALL=C sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\xf0...//g; s/\xe2..//g; s/\xef\xb8\x8f//g' "$tmp_out" | \
        sed "/./s/^/[${log_ts}] [OUT] /" >> "$LOG_FILE"

    # 失敗時は error.log にも記録（前回エラーとの区切りが明確になるよう都度追記）
    if [[ $is_success -eq $RET_NG ]] && [[ -n "${LOG_FILE:-}" ]]; then
        local err_log
        err_log="$(dirname "$LOG_FILE")/error.log"
        {
            echo "====== [${log_ts}] ERROR: [${SCRIPT_NAME}] ${cmd[*]} ======"
            LC_ALL=C sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\xf0...//g; s/\xe2..//g; s/\xef\xb8\x8f//g' "$tmp_out" | \
                sed "/./s/^/  /"
        } >> "$err_log"
    fi

    rm -f "$tmp_out"
    return $is_success
}

# ------------------------------------------------------------------------------
# 7. Git フック共通定数
# ------------------------------------------------------------------------------
# sf-hook.sh が生成するラッパーファイルの識別マーカー。
# sf-unhook.sh はこのマーカーで「sf-tools が管理するフックか」を判定してから削除する。
readonly SF_HOOK_MARKER="# Generated by sf-tools: wrapper for pre-push hook"

# ------------------------------------------------------------------------------
# 8. die - 致命的エラーログを出力して終了
# ------------------------------------------------------------------------------
# 【使い方】
#   die MESSAGE [EXIT_CODE]
#
# 【引数】
#   MESSAGE   : エラーメッセージ（ログレベル FATAL で出力される）
#   EXIT_CODE : 終了コード。省略時は RET_NG (1)。
#
# 【使用例】
#   check_force_dir || die "force-* ディレクトリ内で実行してください。"
#   run sf org login web ... || die "ログインに失敗しました。"
# ------------------------------------------------------------------------------
die() {
    log "FATAL" "$1"
    exit "${2:-$RET_NG}"
}

# ------------------------------------------------------------------------------
# 9. ユーティリティ関数
# ------------------------------------------------------------------------------

# get_target_org - 接続先組織エイリアスを解決して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   TARGET=$(get_target_org [ALIAS]) || die "組織を特定できません。"
#
# 【解決の優先順位】
#   1. 引数 ALIAS（明示指定）
#   2. 環境変数 SF_TARGET_ORG（GitHub Actions の secrets 等）
#   3. ローカル接続情報（sf org display の出力）
#
# 【戻り値】
#   RET_OK (0) : エイリアスを echo して正常終了
#   RET_NG (1) : どこからも特定できなかった場合
#
# 【使用例】
#   TARGET_ORG=$(get_target_org "$OPT_TARGET") || die "接続先を特定できません。"
#   TARGET_ORG=$(get_target_org)               || die "接続先を特定できません。"
# ------------------------------------------------------------------------------
get_target_org() {
    local target="$1"
    [[ -z "$target" ]] && target="$SF_TARGET_ORG"
    if [[ -z "$target" ]]; then
        local current_alias
        current_alias=$(run sf org display --json | grep '"alias"' | head -n 1 | cut -d '"' -f 4 | tr -d '\r')
        [[ -n "$current_alias" && "$current_alias" != "null" ]] && target="$current_alias"
    fi
    [[ -z "$target" ]] && return $RET_NG
    echo "$target"
    return $RET_OK
}

# check_force_dir - カレントディレクトリが force-* であるか確認する
# ------------------------------------------------------------------------------
# 【使い方】
#   check_force_dir || die "force-* ディレクトリ内で実行してください。"
#
# 【戻り値】
#   RET_OK (0) : カレントディレクトリ名が force- で始まる
#   RET_NG (1) : それ以外
# ------------------------------------------------------------------------------
check_force_dir() {
    [[ "$(basename "$PWD")" =~ ^force- ]] && return $RET_OK
    return $RET_NG
}

# check_gh_owner - gh 認証ユーザーがリポジトリオーナーと一致するか確認する
# ------------------------------------------------------------------------------
# 【使い方】
#   check_gh_owner "$GITHUB_OWNER"          # 失敗時は die で終了
#   check_gh_owner "${REPO_FULL_NAME%%/*}"  # OWNER/REPO 形式からオーナーを抽出して渡す
#
# 【検証内容】
#   - gh api user でログイン中のユーザー名を取得
#   - 期待するオーナーと一致すれば通過
#   - 一致しない場合、オーナーが組織で認証ユーザーがその組織の有効な管理者（admin かつ active）なら通過
#   - 上記以外は die（組織 API が失敗した場合も通過させない）
#   - gh コマンドが使えない場合（ユーザー名が空）はチェックをスキップ（ネットワーク障害等への配慮）
# ------------------------------------------------------------------------------
check_gh_owner() {
    local expected_owner="$1"
    local gh_user org_status
    gh_user=$(gh api user --jq '.login' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    [[ -z "$gh_user" || "$gh_user" == "$expected_owner" ]] && return $RET_OK
    # 不一致: オーナーが組織なら、認証ユーザーがその組織の有効な管理者かを確認する
    org_status=$(gh api "user/memberships/orgs/${expected_owner}" --jq '.role + " " + .state' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$org_status" == "admin active" ]]; then
        log "INFO" "gh の認証ユーザー（${gh_user}）は組織 ${expected_owner} の管理者です。続行します。"
        return $RET_OK
    fi
    die "gh の認証ユーザー（${gh_user}）がリポジトリオーナー（${expected_owner}）と一致せず、組織の管理者（admin）でもありません。"
}

# check_home_dir - ~/home/{owner}/{company}/ の正しい階層か確認し変数をセットする
# ------------------------------------------------------------------------------
# 【使い方】
#   check_home_dir   # 失敗時は die で終了
#   # 成功時: GITHUB_OWNER / COMPANY_NAME がセットされる
#
# 【検証内容】
#   - PWD が */home/ 配下にある
#   - home/ からの深さがちょうど 2（{owner}/{company}）
#
# 【セット先変数】
#   GITHUB_OWNER  : 1つ上のフォルダ名（例: tamashimon-org）
#   COMPANY_NAME  : カレントフォルダ名（例: yamada）
# ------------------------------------------------------------------------------
check_home_dir() {
    local rest depth
    rest="${PWD#*/home/}"
    if [[ "$rest" == "$PWD" ]]; then
        die "~/home/ 配下で実行してください。
  正しい場所: ~/home/{github-owner}/{company}/
  現在の場所: ${PWD}"
    fi
    depth=$(printf '%s' "$rest" | tr -cd '/' | wc -c)
    if [[ $depth -ne 1 ]]; then
        die "実行フォルダの階層が正しくありません。
  正しい場所: ~/home/{github-owner}/{company}/
  現在の場所: ${PWD}"
    fi
    GITHUB_OWNER=$(basename "$(dirname "$PWD")")
    COMPANY_NAME=$(basename "$PWD")
}

# get_branch_list - branches.txt からブランチ一覧を取得して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   branches=$(get_branch_list)
#
# 【ファイル参照先】
#   sf-tools/config/branches.txt（プロジェクト内）
#
# 【戻り値】
#   RET_OK (0) : ブランチ一覧を echo して正常終了（main が含まれない場合も WARNING）
#   RET_NG (1) : ファイルが存在しない場合
# ------------------------------------------------------------------------------
readonly BRANCH_LIST_FILE="sf-tools/config/branches.txt"

get_branch_list() {
    if [[ ! -f "$BRANCH_LIST_FILE" ]]; then
        log "WARNING" "ブランチ構成ファイルが見つかりません: ${BRANCH_LIST_FILE}（デフォルト: main のみ）"
        echo "main"
        return $RET_OK
    fi
    local branches="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                          # CR 除去（Windows 対応）
        [[ "$line" =~ ^[[:space:]]*# ]] && continue  # コメント行スキップ
        [[ -z "${line//[[:space:]]/}" ]] && continue  # 空行スキップ
        branches="${branches}${branches:+$'\n'}${line}"
    done < "$BRANCH_LIST_FILE"
    if [[ -z "$branches" ]]; then
        log "WARNING" "${BRANCH_LIST_FILE} にブランチが定義されていません。デフォルト: main のみ"
        echo "main"
        return $RET_OK
    fi
    echo "$branches"
    return $RET_OK
}

# is_reserved_org_alias - 共有環境の組織エイリアス（sf-tools の予約名）かを返す
# ------------------------------------------------------------------------------
# 【背景】
#   共有環境（本番・staging・develop）へのリリースは、ローカルの PC からはできない。
#   GitHub にコミットし、レビューを通して、GitHub Actions で行う。
#   sf-init は、組織のエイリアスとして prod / staging / develop を付ける（sf-start.sh も prod を本番として扱う）。
#   この名前を予約名とし、ローカルからのリリースを禁止する（sf-release.sh / sf-deploy.sh）。
#   main は、ブランチ名と同じ名前（互換のため、予約名に含める）。
#   予約名以外の名前に付け替えた場合は、動作を保証しない（個人用の Sandbox / Developer Edition / Scratch Org の想定）。
#
# 【使い方】
#   is_reserved_org_alias "$TARGET_ORG" && die "ローカルからは実行できません。"
#
# 【戻り値】
#   RET_OK (0) : 予約名（共有環境）
#   RET_NG (1) : それ以外
# ------------------------------------------------------------------------------
readonly SF_RESERVED_ORG_ALIASES="prod staging develop main"

is_reserved_org_alias() {
    local alias_name="$1" reserved
    for reserved in $SF_RESERVED_ORG_ALIASES; do
        [[ "$alias_name" == "$reserved" ]] && return $RET_OK
    done
    return $RET_NG
}

# is_protected_branch - 指定ブランチが branches.txt の保護対象かを返す
# ------------------------------------------------------------------------------
# 【使い方】
#   is_protected_branch "staging" && die "直接プッシュ禁止"
#
# 【戻り値】
#   RET_OK (0) : 保護対象ブランチである
#   RET_NG (1) : 保護対象外
# ------------------------------------------------------------------------------
is_protected_branch() {
    local branch="$1"
    local branches
    branches=$(get_branch_list)
    echo "$branches" | grep -qx "$branch" && return $RET_OK
    return $RET_NG
}


# read_input - readline 対応インタラクティブ入力（矢印キー・BS 等が正常に動作する）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_input VARNAME [PROMPT]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力）
#
# 【使用例】
#   read_input ORG_ALIAS "組織エイリアスを入力: "
#   read_input answer
# ------------------------------------------------------------------------------
read_input() {
    local _varname="$1" _prompt="${2:-}"
    if [[ -n "$_prompt" ]]; then
        # readline にプロンプトを渡し、ANSI カラーコードを \001..\002 で囲む
        # （カーソル位置計算を正しくし、行折り返し時のプロンプト上書きを防止）
        local _rl_prompt
        _rl_prompt=$(printf '%b' "$_prompt" | sed $'s/\033\\[[0-9;]*m/\001&\002/g')
        read -rep "$_rl_prompt" "$_varname"
    else
        read -re "$_varname"
    fi
}

# read_key - 1文字即時入力（Enter不要・空 Enter 無視）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_key VARNAME [PROMPT]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力）
#
# 【使用例】
#   read_key choice "  番号を入力 [1-3/q]: "
#   read_key answer "  削除してよいですか？ [Y/N/q]: "
# ------------------------------------------------------------------------------
read_key() {
    local _varname="$1" _prompt="${2:-}" _valid="${3:-}"
    while true; do
        [[ -n "$_prompt" ]] && printf "%s" "$_prompt" >&2
        read -rsn1 "$_varname" || { printf "\n" >&2; die "入力が中断されました。"; }
        # 空 Enter または無効文字 → 行クリアして再プロンプト（同じ行に留まる）
        if [[ -z "${!_varname}" ]] || { [[ -n "$_valid" ]] && ! [[ "${!_varname}" =~ $_valid ]]; }; then
            printf "\r\033[K" >&2
            continue
        fi
        printf "%s\n" "${!_varname}" >&2  # 有効文字のみエコー
        break
    done
}

# is_gitbash - Windows の Git Bash（MSYS2 / Cygwin 系の Bash）かどうか
# ------------------------------------------------------------------------------
# $OSTYPE は、Git Bash でも環境により msys / mingw / cygwin のいずれにもなる
# （cygwin になる環境があり、msys / mingw だけを見ていると判定を外す）。
# 【使い方】  if is_gitbash; then ...
# ------------------------------------------------------------------------------
is_gitbash() { [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; }

# run_isolated_home - コマンドを、一時的なホームフォルダの中で実行する（sf の認証・エイリアスを隔離する）
# ------------------------------------------------------------------------------
# 【背景】
#   sf の認証は「ユーザー名単位」で ~/.sfdx に保存される。JWT の接続テスト（sf org login jwt）を、そのまま
#   実行すると、エイリアスが増える上に、同じユーザーの既存の認証が、JWT の認証に置き換わってしまう
#   （その JWT の鍵・アプリを後で消すと、そのユーザーの sf が使えなくなる）。
#   HOME と USERPROFILE（Windows は USERPROFILE を見る）を一時フォルダにすると、認証・エイリアス・暗号鍵が、
#   すべて一時フォルダの中に作られ、本物の ~/.sfdx は変わらない（実機で確認）。
#
# 【使い方】
#   out=$(run_isolated_home sf org login jwt --client-id ... --alias prod)   # 標準出力・標準エラーを受け取る
#   rc=$?                                                                    # コマンドの終了コード
#
# 【動作】
#   ・mktemp -d で一時フォルダを作り、HOME / USERPROFILE をそれにしてコマンドを実行する
#   ・終了後に、一時フォルダを削除する（アクセストークンなどが入るため、必ず消す）
#   ・出力（標準出力と標準エラー）を、標準出力に返す。戻り値は、コマンドの終了コード
# ------------------------------------------------------------------------------
run_isolated_home() {
    local tmp_home out rc
    tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sf-tools-home.XXXXXX") || return $RET_NG  # VAR=$(cmd) のため run 不使用
    out=$(HOME="$tmp_home" USERPROFILE="$tmp_home" "$@" 2>&1)  # VAR=$(cmd) のため run 不使用（認証情報をログに出さない）
    rc=$?
    rm -rf "${tmp_home:?}"  # run 不使用: 認証情報を含む一時フォルダの確実な削除
    printf '%s' "$out"
    return $rc
}

# check_sf_cli - sf（Salesforce CLI）が、終了コードを正しく返すか確認する
# ------------------------------------------------------------------------------
# 【背景】
#   Windows の Git Bash で、Salesforce CLI の公式インストーラー版（自動更新後）を使うと、sf が成功しても
#   常に終了コード 1 を返す（npm 版では正しく返る。Salesforce 側の起動用ファイルの問題）。
#   run() は終了コードで成否を判定するため、この環境では、成功した処理も失敗扱いになる。
#   そのため sf-tools は、Salesforce CLI の npm 版（npm install -g @salesforce/cli）を前提とする。
#
# 【使い方】
#   check_sf_cli                       # 終了コードが 0 以外なら、案内を表示して die する
#   check_sf_cli --warn-only           # 案内を表示するだけで、続行する（戻り値 1）。die したくない呼び出し元用（sf-install.sh）
#   check_sf_cli --cache               # 日常のコマンド用。成功したら 24 時間は、確認を省略する（下記）。NG なら die する
#
# 【動作】
#   ・GitHub Actions 上（GITHUB_ACTIONS=true）では、何もしない（Linux の npm 版のため）
#   ・sf が未インストールなら、何もしない（各スクリプトの環境チェックが扱う）
#   ・--cache のとき、成功を ~/.sf-tools-sf-check（環境変数 SF_TOOLS_SF_CHECK_STAMP で変更可）に、sf の場所を
#     記録し、同じ場所の sf なら、24 時間は sf --version（1〜2 秒）の実行を省略する。失敗は、記録せず、毎回確認する
#   ・sf --version の終了コードが 0 なら、何も表示しない
#   ・0 以外なら、sf の場所と対処（npm 版への入れ替え）を ERROR で表示する
# ------------------------------------------------------------------------------
check_sf_cli() {
    local warn_only=0 use_cache=0 out rc sf_path stamp arg
    for arg in "$@"; do
        case "$arg" in
            --warn-only) warn_only=1 ;;
            --cache)     use_cache=1 ;;
        esac
    done

    [[ "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
    command -v sf >/dev/null 2>&1 || return 0  # 存在確認のため run 不使用

    sf_path=$(command -v sf)  # VAR=$(cmd) のため run 不使用
    stamp="${SF_TOOLS_SF_CHECK_STAMP:-$HOME/.sf-tools-sf-check}"
    if [[ $use_cache -eq 1 && -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$sf_path" \
          && -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]]; then
        return 0   # 24 時間以内に、同じ場所の sf で成功を確認済み
    fi

    out=$(sf --version 2>&1)  # VAR=$(cmd) のため run 不使用（終了コードを自分で判定する）
    rc=$?
    if [[ $rc -eq 0 ]]; then
        [[ $use_cache -eq 1 ]] && { printf '%s' "$sf_path" > "$stamp" 2>/dev/null || true; }  # 記録に失敗しても続行（意図的エラー無視）
        return 0
    fi

    log "ERROR" "sf（Salesforce CLI）の終了コードが 0 ではありません（sf --version: 終了コード ${rc}）。"
    log "ERROR" "  sf の場所: ${sf_path}"
    [[ -n "$out" ]] && log "ERROR" "  出力: $(printf '%s' "$out" | head -1)"
    log "ERROR" "  Windows の Git Bash で、Salesforce CLI の公式インストーラー版を使うと、成功しても終了コード 1 になり、"
    log "ERROR" "  sf-tools の処理が、成功しても失敗扱いになります。sf-tools は、npm 版の Salesforce CLI を前提としています。"
    log "ERROR" "  対処: インストーラー版をアンインストールし、npm 版をインストールしてください（詳細は README の前提条件）。"
    log "ERROR" "    npm install -g @salesforce/cli"
    if [[ $warn_only -eq 1 ]]; then
        return 1
    fi
    die "sf の終了コードが 0 ではないため、処理を中断しました。"
}

# open_browser - OS を判定してブラウザを開く
# ------------------------------------------------------------------------------
# 【使い方】
#   open_browser URL
#
# 【対応環境】
#   Git Bash : start ""
#   WSL      : powershell.exe Start-Process
#   macOS    : open
#   Linux    : xdg-open
# ------------------------------------------------------------------------------
open_browser() {
    local url="$1"
    # stdin を /dev/null にリダイレクトし、パイプ入力の消費を防止する
    # （Git Bash の判定を先にする。WSL の判定は /proc/version を読むため、$OSTYPE の判定のほうが確実）
    if is_gitbash; then
        # Git Bash / MSYS2 / Cygwin
        start "" "$url" < /dev/null 2>/dev/null || true
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        # WSL 環境
        powershell.exe -c "Start-Process '$url'" < /dev/null 2>/dev/null || true
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open "$url" < /dev/null 2>/dev/null || true  # open は macOS 標準のため直接実行
    elif command -v xdg-open &>/dev/null; then
        # Linux
        xdg-open "$url" < /dev/null 2>/dev/null || true  # xdg-open は存在確認のため直接実行
    fi
}

# press_enter - Enter キー待ち（q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   press_enter [MSG]
#
# 【引数】
#   MSG : 省略時は「続行するには Enter キーを押してください（q で中断）...」
#
# 【使用例】
#   press_enter "ブラウザでログインしたら Enter を押してください..."
# ------------------------------------------------------------------------------
press_enter() {
    local msg="${1:-続行するには Enter キーを押してください（q で中断）...}"
    echo ""
    local _input
    read_input _input "  ▶ $msg" || die "中断しました。"  # EOF → 中断
    [[ "$_input" == "q" || "$_input" == "Q" ]] && die "中断しました。"
}

# read_or_quit - テキスト入力（空 Enter 無視・q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_or_quit VARNAME PROMPT
#
# 【引数】
#   VARNAME : 入力値を格納する変数名（nameref: Bash 4.3 以降必須）
#   PROMPT  : プロンプト文字列
#
# 【使用例】
#   read_or_quit JOB_NAME "  ジョブ名: "
#   read_or_quit PAT_TOKEN "  トークンを貼り付けてください（q で中断）: "
# ------------------------------------------------------------------------------
read_or_quit() {
    local -n _rq_var=$1
    local prompt="$2"
    while true; do
        read_input _rq_var "$prompt" || die "中断しました。"  # EOF → 中断
        [[ "$_rq_var" == "q" || "$_rq_var" == "Q" ]] && die "中断しました。"
        [[ -n "$_rq_var" ]] && break  # 空 Enter → 再入力
    done
}

# read_secret - 秘密情報の入力（画面に表示しない・空 Enter 無視・q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_secret VARNAME PROMPT
#
# 【動作】
#   - 入力した文字を画面に表示しない（read -s）。貼り付けた Token が画面・スクロールバックに残らない
#   - 空 Enter は無視して再入力。q / Q で die。EOF も die
#   - 末尾の CR（Windows の貼り付け）は除去する
#
# 【使用例】
#   read_secret SF_TOOLS_TOKEN_VALUE "  Token を貼り付けてください（画面には表示されません・q で中断）："
# ------------------------------------------------------------------------------
read_secret() {
    local -n _rs_var=$1
    local prompt="$2"
    while true; do
        printf "%s" "$prompt" >&2
        IFS= read -rs _rs_var || { printf "\n" >&2; die "入力が中断されました。"; }
        printf "\n" >&2
        _rs_var="${_rs_var%$'\r'}"
        [[ "$_rs_var" == "q" || "$_rs_var" == "Q" ]] && die "中断しました。"
        [[ -n "$_rs_var" ]] && break  # 空 Enter → 再入力
    done
}

# Y / N / q を明示的に入力させる（1文字即時入力・q で即中断）
# 使い方: ask_yn "質問文" && echo "Yes" || echo "No"
ask_yn() {
    local prompt="$1" answer
    read_key answer "  ${prompt} [Y/N/q]: " "[YyNnQq]"
    case "$answer" in
        [Yy]) return 0 ;;
        [Nn]) return 1 ;;
        [Qq]) die "中断しました。" ;;
    esac
}
