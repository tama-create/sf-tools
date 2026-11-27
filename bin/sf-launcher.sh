#!/bin/bash
# ==============================================================================
# sf-launcher.sh - sf-tools コマンドランチャー
# ==============================================================================
# sf-tools の日常のコマンドを、メニューから番号（または fzf）で選んで実行するランチャー。
# sf-start.sh の最後に自動で起動する。手動でも実行できる。
#
# 【使い方】
#   sf-launcher.sh              : メニューを表示する。番号を 1 文字入力すると（Enter 不要）実行し、終わるとメニューに戻る。
#                                 q で終了。範囲外の数字・数字と q 以外の入力は無視する
#   sf-launcher.sh <番号>       : その番号のコマンドを 1 回だけ実行して終了する（例: sf-launcher.sh 1）
#   sf-launcher.sh --fzf        : fzf でインクリメンタル検索して実行する（Enter: 実行 / Esc: 終了）。実行後は選択に戻る
#
# 【オプション】
#   <番号>     : 実行するコマンドの番号（下のメニューの番号）。数字だけを受け付け、10 進数として扱う（08 は 8。
#                先頭の 0 は無視する）。先頭の 0 を除いて 10 桁以上は範囲外
#   --fzf      : fzf モードで起動する
#   -h, --help : この説明を表示して終了する（第 1 引数のときのみ。force-* フォルダの外でも動く）
#   それ以外の引数（数字以外）は、エラーで終了する（終了コード 1）。見るのは第 1 引数だけ（2 つ目以降は無視する）。
#   引数の確認は、処理の流れ 2（force-* フォルダの確認）のあとに行う
#
# 【処理の流れ】
#   1. 環境変数 SF_LAUNCHER_ACTIVE=1 を export する（sf-start.sh が、ランチャーを二重に起動しないため）
#   2. カレントフォルダの名前が force- で始まらなければ、警告を表示して終了する（終了コード 1）
#   3. メニュー（番号: 表示名 → 実行するスクリプト）。1〜5 は、日々の作業の順（上から順に押せば、確かめる → 試す → 反映 → コミット → PR）:
#        1: Check → sf-check.sh   2: Dryrun → sf-dryrun.sh   3: Deploy → sf-deploy.sh
#        4: Push → sf-push.sh     5: Next → sf-next.sh
#        6: Start → sf-start.sh   7: Restart → sf-restart.sh（1 日の最初・組織の切り替えのときだけ使うため、5 との間に線を引く）
#      VS Code のターミナル（環境変数 TERM_PROGRAM=vscode）では 6・7 を表示しない（番号 6・7 は範囲外になる。線も引かない）
#      （2026-11-26 に、1: Check 2: Push 3: Next 4: Dryrun 5: Deploy の並びから、作業の順に並べ替えた）
#   4. 選んだコマンドは、このスクリプトと同じフォルダの sf-xxx.sh を、引数なしで bash で実行する。
#      スクリプトがなければ、警告を表示する
#   5. メニューを表示するたびに、見出しの下に、デバッグログ（sf-log.sh）の状態を 1 行表示する（logs/apex/.status の STATE による:
#      collecting = 取得中（組織・期限・今日の本数）/ starting = 準備中 / skipped = 取っていません / error = 取れていません /
#      stopped = 止まっています。WARNING があれば、もう 1 行）。ファイルがない・STATE がそれ以外なら、何も表示しない。
#      色は状態で変える（取得中 = 太字の緑 / 準備中 = 太字の水色 / 取れていません = 太字の赤 / 取っていません・止まっています = 黄色。
#      メニューの中で目立たせ、ひと目で取れているかが分かるようにする）
#      キー=値 の行を while read で読み、source しない。
#      準備中（starting）のあいだは、入力を 5 秒ずつ待ち（read -t）、STATE が変わったら、コマンドを動かさずにメニューを描き直す
#      （裏の準備は数分かかることがあり、つながっても「準備中」のままだと迷うため）。待ち切れと EOF は、待った時間でも見分ける（Bash 3.2）
#   6. メニューを表示するたびに、見出しの下に、今の状況を表示する（読み取りのみ。通信しない。2026-11-27）:
#        ブランチ（git symbolic-ref。ブランチの上にいなければ、その旨だけ）・組織（.sf/config.json の target-org を node で読む。
#        読めなければ出さない）・未コミットの変更の数（git status --porcelain の行数）・push していないコミットの数
#        （git rev-list --count @{u}..HEAD。追跡先がなければ「追跡先なし」）・次の PR 先（sf-tools/logs/next-status.txt。
#        sf-next.sh が最後に判定した結果を書く。HEAD= が今の先端のコミットと同じときだけ使い、違う・ない・読めないときは
#        「5 Next で確かめる」）。キー=値 の行を while read で読み、source しない。
#        続けて「次の目安」を 1 行出す（上から順に当てはまったもの。番号は、メニューの並びから引く）:
#          未コミットの変更がある → Check → Dryrun → Deploy で確かめてから、Push / push していないコミットがある・追跡先がない → Push /
#          次の PR 先: none → 全段階にリリース済み / 発行中の PR → その PR の検証を待つ / 出すものなし → ターゲットファイルに書く /
#          段階 → Next（その段階へ PR）/ 分からない → Next（出し先を確かめる）
#        環境ブランチ（sf-tools/config/branches.txt の行。ファイルがない・空なら main だけ）の上では、変更・次の目安の代わりに、
#        「環境ブランチの上です」と出す
#   7. コマンドが終わったら、結果を 1 行で出す: 終了コード 0 → 「✓ <名前>: 終わりました（成功）」（太字の緑）/
#      それ以外 → 「✗ <名前>: 失敗、または中断しました（終了コード N）」（太字の赤。q での中断も 1 になるため、両方を書く）
#
# 【前提条件】
#   - force-* フォルダで実行する（処理の流れ 2）
#   - --fzf を使うときは fzf が必要。なければ、警告を表示して終了する（終了コード 1）
#   - lib/common.sh を読み込まない単独の設計（ログファイルは作らない）
#
# 【補足】
#   - 終了コード: メニューを q・EOF で終了 → 0 / --fzf を Esc で終了 → 0 / <番号> → 実行したコマンドの終了コード
#     （番号が範囲外・スクリプトがない → 1）
#   - メニュー・fzf モードでは、実行したコマンドが失敗しても、ランチャーは終了しない
# ==============================================================================

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --help / -h: 冒頭コメントを表示して終了
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh を読み込まない単独の設計（run が未定義）
    exit 0
fi

# ------------------------------------------------------------------------------
# カラー定義
# ------------------------------------------------------------------------------
BOLD='\033[1m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

# ------------------------------------------------------------------------------
# メニュー定義 (コマンド名 | 説明)。日々の作業の順に並べる（上から順に押す）。start / restart は最後（線の下）
# VSCode 内では start / restart を除外（code . の二重起動・表示乱れ防止）
# ------------------------------------------------------------------------------
MENU_ITEMS_ALL=(
    "sf-check    | ターゲットファイルの構文チェック"
    "sf-dryrun   | 現在接続中の組織へリリース検証"
    "sf-deploy   | 現在接続中の組織へリリース"
    "sf-push     | 変更をコミット & プッシュ"
    "sf-next     | 次の PR 先ブランチを確認"
    "sf-start    | 開発環境を起動（Salesforce ログイン・VSCode 起動）"
    "sf-restart  | 接続組織を切り替えて Start 実行"
)

# VSCode 内では start / restart を除外
MENU_ITEMS=()
for _item in "${MENU_ITEMS_ALL[@]}"; do
    if [[ "$TERM_PROGRAM" == "vscode" ]]; then
        [[ "$_item" =~ ^(sf-start|sf-restart) ]] && continue
    fi
    MENU_ITEMS+=("$_item")
done
unset _item

# ------------------------------------------------------------------------------
# メニュー表示
# ------------------------------------------------------------------------------
# デバッグログ（sf-log.sh）の状態を 1 行で表示する（logs/apex/.status。なければ何も表示しない。doc/sf-log-design.md 5.4）
#   common.sh を読まないため、キー=値 の行を while read で読み、決まったキーだけを使う（source しない）
print_apexlog_status() {
    local f="logs/apex/.status" line k v state="" org="" at="" cnt="" reason="" warn="" text color
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            STATE) state="$v" ;; ORG) org="$v" ;; EXPIRES_AT) at="$v" ;; COUNT_TODAY) cnt="$v" ;;
            REASON) reason="$v" ;; WARNING) warn="$v" ;;
        esac
    done < "$f"
    case "$state" in
        collecting) text="取得中（${org}${at:+・期限 ${at}}${cnt:+・今日 ${cnt} 本}）"; color="${BOLD}${GREEN}" ;;
        starting)   text="準備中（${org}）"; color="${BOLD}${CYAN}" ;;
        skipped)    text="取っていません${reason:+（${reason}）}"; color="${YELLOW}" ;;
        error)      text="取れていません${reason:+（${reason}）}"; color="${BOLD}${RED}" ;;
        stopped)    text="止まっています${reason:+（${reason}）}"; color="${YELLOW}" ;;
        *)          return 0 ;;
    esac
    # 色は状態で変える（以前は薄い灰色で、メニューの中で目立たなかった。2026-11-24）
    echo -e "${color}  デバッグログ: ${text}${RESET}"
    [[ -n "$warn" ]] && echo -e "${YELLOW}  ⚠ デバッグログ: ${warn}${RESET}"
    return 0
}

# デバッグログの状態（.status の STATE）だけを読む（なければ空）。準備中のあいだの描き直しの判定に使う
apexlog_state() {
    local f="logs/apex/.status" line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == STATE=* ]] && { printf '%s' "${line#STATE=}"; return 0; }
    done < "$f"
    return 0
}
APEXLOG_REFRESH=5   # 準備中のあいだ、状態を見直す間隔（秒）

# ------------------------------------------------------------------------------
# 今の状況（メニューの上の数行。読み取りのみ。通信しない。冒頭コメントの処理の流れ 6）
# ------------------------------------------------------------------------------
NEXT_STATUS_FILE="sf-tools/logs/next-status.txt"   # sf-next.sh が、最後に判定した結果を書く（ここでは読むだけ）

# コマンド名（sf-check など）→ メニューの番号。並びが変わっても、案内の番号が合うように、MENU_ITEMS から引く
number_of() {
    local want="$1" num=1 item c
    for item in "${MENU_ITEMS[@]}"; do
        c="${item%%|*}"; c="${c// /}"
        [[ "$c" == "$want" ]] && { printf '%s' "$num"; return 0; }
        (( num++ ))
    done
    return 1
}

# コマンド名 → 表示名（sf-check → Check）。${x^} は Bash 4 以降のため、tr で先頭を大文字にする
label_of() {
    local l="${1#sf-}"
    printf '%s' "$(printf '%s' "${l:0:1}" | tr '[:lower:]' '[:upper:]')${l:1}"
}

# 環境ブランチか（sf-tools/config/branches.txt の行。# の行・空行を除き、CR と前後の空白を除く。ファイルがない・空なら main だけ）
is_env_branch() {
    local b="$1" line
    [[ "$b" == "main" ]] && return 0
    [[ -f "sf-tools/config/branches.txt" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == "$b" ]] && return 0
    done < "sf-tools/config/branches.txt"
    return 1
}

# つないでいる組織（.sf/config.json の target-org。JSON は node で読む（grep・sed で読まない）。読めなければ空。
#   表示を崩さないよう、制御文字・幅のない文字・文字の向きを変える文字を除き、60 文字を超えたら切って … を付ける）
target_org() {
    [[ -f ".sf/config.json" ]] || return 0
    command -v node >/dev/null 2>&1 || return 0
    node -e 'try{const j=JSON.parse(require("fs").readFileSync(".sf/config.json","utf8"));const v=j["target-org"];if(typeof v==="string"){const t=v.replace(/[\x00-\x1f\x7f-\x9f​-‏‪-‮⁦-⁩﻿]/g,"");process.stdout.write(t.length>60?t.slice(0,60)+"…":t)}}catch(e){}' 2>/dev/null
    return 0
}

print_status() {
    local branch org head changes ahead="" has_up=0 line k v nhead="" next="" pr="" skipped="" hint
    local n_check n_dryrun n_deploy n_push n_next
    branch=$(git symbolic-ref -q --short HEAD 2>/dev/null) || branch=""   # VAR=$(cmd)（common.sh を読まない単独の設計。以下も同じ）
    org=$(target_org)
    # 表示は echo -e のため、値の \ を \\ にする（値の中の \033 などを、端末の制御として解釈させない）。
    #   ブランチ名は、git の参照名の決まりで \ を含まない。次の PR 先・PR の番号は、下で形を確かめる（\ を通さない）
    org="${org//\\/\\\\}"
    if [[ -z "$branch" ]]; then
        echo -e "  ブランチ: ${YELLOW}（ブランチの上にいません）${RESET}${org:+   組織: ${BOLD}${org}${RESET}}"
        return 0
    fi
    echo -e "  ブランチ: ${BOLD}${branch}${RESET}${org:+   組織: ${BOLD}${org}${RESET}}"
    if is_env_branch "$branch"; then
        echo -e "${YELLOW}  ⚠ 環境ブランチの上です。作業は、sf-job.sh で作ったブランチで行います${RESET}"
        return 0
    fi
    changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [[ "$changes" =~ ^[0-9]+$ ]] || changes=0
    if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        has_up=1
        ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null)
        [[ "$ahead" =~ ^[0-9]+$ ]] || ahead=0
    fi
    # 次の PR 先: sf-next.sh が最後に判定した結果（今の先端のコミットと同じときだけ使う。source しない）
    head=$(git rev-parse -q --verify HEAD 2>/dev/null) || head=""
    if [[ -f "$NEXT_STATUS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            k="${line%%=*}"; v="${line#*=}"
            case "$k" in HEAD) nhead="$v" ;; NEXT) next="$v" ;; PR) pr="$v" ;; SKIPPED) skipped="$v" ;; esac
        done < "$NEXT_STATUS_FILE"
    fi
    if [[ -z "$head" || "$nhead" != "$head" ]] || ! [[ "$next" =~ ^[A-Za-z0-9._/-]{1,40}$ ]]; then
        next=""; pr=""; skipped=""
    fi
    [[ "$pr" =~ ^[0-9]{1,9}$ ]] || pr=""   # 長さにも上限（表示を崩さないため）

    if [[ $has_up -eq 1 ]]; then
        echo -e "  未コミットの変更: ${BOLD}${changes}${RESET} 件   push していないコミット: ${BOLD}${ahead}${RESET} 件"
    else
        echo -e "  未コミットの変更: ${BOLD}${changes}${RESET} 件   push していないコミット: ${YELLOW}（追跡先なし）${RESET}"
    fi
    if [[ "$skipped" == "true" ]]; then
        echo -e "  次の PR 先: 出すものなし（ターゲットファイルが空）"
    elif [[ "$next" == "none" ]]; then
        echo -e "  次の PR 先: ${GREEN}全段階にリリース済み${RESET}"
    elif [[ -n "$next" && -n "$pr" ]]; then
        echo -e "  次の PR 先: ${BOLD}${next}${RESET}（PR 発行中 #${pr}）"
    elif [[ -n "$next" ]]; then
        echo -e "  次の PR 先: ${BOLD}${next}${RESET}"
    else
        echo -e "  次の PR 先: ${DIM}（Next で確かめる）${RESET}"
    fi

    n_check=$(number_of sf-check); n_dryrun=$(number_of sf-dryrun); n_deploy=$(number_of sf-deploy)
    n_push=$(number_of sf-push); n_next=$(number_of sf-next)
    if [[ "$changes" -gt 0 ]]; then
        hint="${n_check} Check → ${n_dryrun} Dryrun → ${n_deploy} Deploy で確かめてから、${n_push} Push"
    elif [[ $has_up -eq 0 || "$ahead" -gt 0 ]]; then
        hint="${n_push} Push（push していないコミットがあります）"
    elif [[ "$skipped" == "true" ]]; then
        hint="ターゲットファイル（sf-tools/release/${branch}/）に、出すものを書く"
    elif [[ "$next" == "none" ]]; then
        hint="全段階にリリース済みです（このブランチの作業は終わり）"
    elif [[ -n "$next" && -n "$pr" ]]; then
        hint="PR #${pr} の検証が緑になったら、マージする"
    elif [[ -n "$next" ]]; then
        hint="${n_next} Next（${next} へ PR を出す）"
    else
        hint="${n_next} Next（次の出し先を確かめる）"
    fi
    echo -e "${BOLD}${CYAN}  ▶ 次の目安: ${hint}${RESET}"
    return 0
}

print_menu() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  >> Launcher <<${RESET}"
    print_status
    print_apexlog_status
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"

    local num=1
    for item in "${MENU_ITEMS[@]}"; do
        local cmd="${item%%|*}"
        local desc="${item#*|}"
        local label="${cmd// /}"
        label="${label#sf-}"
        # 先頭を大文字に（${label^} は Bash 4 以降のため使わない。macOS 標準の Bash 3.2 で動かす）
        label="$(printf '%s' "${label:0:1}" | tr '[:lower:]' '[:upper:]')${label:1}"
        # 日々の作業（1〜5）と、環境の起動・切り替え（Start・Restart）の間に線を引く
        [[ "$label" == "Start" ]] && echo -e "${DIM}  ──────────${RESET}"
        printf "  ${CYAN}[%d]${RESET} ${BOLD}%-10s${RESET}${DIM}%s${RESET}\n" "$num" "$label" "$desc"
        (( num++ ))
    done

    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# 番号からコマンド名を取得
# ------------------------------------------------------------------------------
get_command_by_number() {
    local target="$1"
    local num=1
    for item in "${MENU_ITEMS[@]}"; do
        if [[ "$num" -eq "$target" ]]; then
            echo "${item%%|*}" | tr -d ' '
            return 0
        fi
        (( num++ ))
    done
    return 1
}

# ------------------------------------------------------------------------------
# コマンド実行
# ------------------------------------------------------------------------------
run_command() {
    local cmd="$1"
    local script="${SCRIPT_DIR}/${cmd}.sh"

    if [[ ! -f "$script" ]]; then
        echo -e "${YELLOW}  ⚠ ${cmd}.sh が見つかりません${RESET}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}  ▶ ${cmd}${RESET}"
    echo ""
    local rc=0
    bash "$script" || rc=$?
    # 結果を 1 行で出す（出力が流れても、成功か失敗かが、ひと目で分かるように。処理の流れ 7）
    echo ""
    if [[ $rc -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}  ✓ $(label_of "$cmd"): 終わりました（成功）${RESET}"
    else
        echo -e "${BOLD}${RED}  ✗ $(label_of "$cmd"): 失敗、または中断しました（終了コード ${rc}）${RESET}"
    fi
    return $rc
}

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
main() {
    export SF_LAUNCHER_ACTIVE=1  # sf-start.sh からの二重起動を防止

    # force-* ディレクトリチェック
    if [[ ! "$(basename "$PWD")" =~ ^force- ]]; then
        echo -e "${YELLOW}  ⚠ force-* ディレクトリ内で実行してください。${RESET}"
        echo -e "${DIM}  現在: ${PWD}${RESET}"
        echo ""
        exit 1
    fi

    # fzf モード
    if [[ "$1" == "--fzf" ]]; then
        fzf_mode
        exit 0
    fi

    # 番号を引数で直接指定した場合
    if [[ -n "$1" ]]; then
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            local cmd n
            # 10 進数として扱う（08・09 を 8 進数と解釈させない）。先頭の 0 を除いて 10 桁以上なら、算術の桁あふれで
            #   小さな数に化けないよう、範囲外（0）とする
            n="${1#"${1%%[!0]*}"}"   # 先頭の 0 を除く（すべて 0 なら空）
            if [[ -z "$n" ]]; then n=0; elif [[ ${#n} -le 9 ]]; then n=$((10#$n)); else n=0; fi
            cmd=$(get_command_by_number "$n") || {
                echo -e "${YELLOW}  ⚠ 番号 $1 は範囲外です${RESET}"
                exit 1
            }
            run_command "$cmd"
            exit $?
        else
            echo -e "${YELLOW}  ⚠ 引数には番号を指定してください（例: sf-launcher.sh 1）${RESET}"
            exit 1
        fi
    fi

    # インタラクティブメニュー
    while true; do
        print_menu

        local count="${#MENU_ITEMS[@]}"
        local input cmd shown t0 rc redraw=0
        shown=$(apexlog_state)   # 表示したデバッグログの状態（準備中のあいだは、変わったら描き直す）

        # 入力ループ（1文字即時入力・無効入力は行クリアして待機）
        while true; do
            printf "  番号を入力 (1-%d / q で終了): " "$count"
            if [[ "$shown" == "starting" ]]; then
                # 準備中: APEXLOG_REFRESH 秒ずつ待ち、状態が変わったら、メニューを描き直す（裏の準備は数分かかることがある。2026-11-23）
                t0=$SECONDS; rc=0
                read -rsn1 -t "$APEXLOG_REFRESH" input || rc=$?
                if [[ $rc -ne 0 ]]; then
                    # 待ち切れ（Bash 4 以降は 128 より大きい。Bash 3.2 は 1 のため、待った時間でも見分ける）と EOF を分ける
                    if (( rc > 128 || SECONDS - t0 >= APEXLOG_REFRESH - 1 )); then
                        printf "\r\033[K"
                        [[ "$(apexlog_state)" == "starting" ]] && continue
                        printf "\n"; redraw=1; break
                    fi
                    printf "\n"; exit 0   # EOF → 正常終了
                fi
            else
                read -rsn1 input || { printf "\n"; exit 0; }  # EOF → 正常終了
            fi

            # 空 Enter / 数字・q 以外 → 行クリアして待機（エコーしない）
            if [[ -z "$input" ]] || ! [[ "$input" =~ ^[0-9qQ]$ ]]; then
                printf "\r\033[K"
                continue
            fi

            # q / Q: 入力をエコーして終了（終了コード 0）
            if [[ "$input" == "q" || "$input" == "Q" ]]; then
                printf "%s\n" "$input"
                echo -e "  ${DIM}終了しました${RESET}"
                echo ""
                exit 0
            fi

            # 範囲外の数字 → 行クリアして待機（エコーしない）
            cmd=$(get_command_by_number "$input") || { printf "\r\033[K"; continue; }

            # 有効な入力のみエコー
            printf "%s\n" "$input"
            break
        done

        [[ $redraw -eq 1 ]] && continue   # デバッグログの状態が変わった → コマンドは動かさず、メニューを描き直す
        run_command "$cmd"
    done
}

# ------------------------------------------------------------------------------
# fzf モード（sf-launcher.sh --fzf）
# ------------------------------------------------------------------------------
fzf_mode() {
    if ! command -v fzf &>/dev/null; then
        echo -e "${YELLOW}  ⚠ fzf がインストールされていません${RESET}"
        exit 1
    fi

    while true; do
        # fzf 用リスト生成（コマンド名 + 説明）
        local lines=()
        for item in "${MENU_ITEMS[@]}"; do
            local cmd="${item%%|*}"
            local desc="${item#*|}"
            local label="${cmd// /}"
            label="${label#sf-}"
            lines+=("$(printf "%-10s %s" "$label" "$desc")")
        done

        local selected
        selected=$(printf '%s\n' "${lines[@]}" | fzf \
            --prompt="  sf-tools > " \
            --height=50% \
            --border=rounded \
            --layout=reverse \
            --info=inline \
            --header="  Enter: 実行 / Esc: 終了" \
            --color="prompt:cyan,header:dim,pointer:green")

        # Esc またはキャンセル
        [[ -z "$selected" ]] && break

        local label
        label=$(echo "$selected" | awk '{print tolower($1)}')
        run_command "sf-${label}"
    done
}

main "$@"
