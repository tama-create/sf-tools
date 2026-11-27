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
#   5. メニューを表示するたびに、見出し（線・>> Launcher <<・線）の下に、今の状況を表示する（読み取りのみ。通信しない。2026-11-27）
#      1 行目: 「<ブランチ> ｜ <組織> ｜ ログ <デバッグログの状態>」（ないものは出さない）
#        表示する値（ブランチ・組織・デバッグログの期限・本数・理由・WARNING）は、すべて clean_text で掃除する（制御文字・
#        幅のない文字・文字の向きを変える文字・BOM を除き、echo -e のため \ を 2 つ重ねる。値の中の文字で、画面を崩させない）
#        ブランチ: git symbolic-ref。ブランチの上にいなければ「（ブランチの上にいません）」だけを出して終わる
#        組織: .sf/config.json の target-org を node で読む（読めなければ出さない。表示を崩す文字を除き、60 文字で切る）
#        デバッグログ: logs/apex/.status の STATE による（collecting = ● 取得中（期限・今日の本数）/ starting = ● 準備中 /
#          skipped = ● 取っていません / error = ● 取れていません / stopped = ● 止まっています。理由（REASON）があれば括弧で添える）。
#          色は状態で変える（取得中 = 太字の緑 / 準備中 = 太字の水色 / 取れていません = 太字の赤 / 取っていません・止まっています = 黄色）。
#          WARNING があれば「⚠ デバッグログ: …」をもう 1 行。ファイルがない・STATE がそれ以外なら、ログの部分を出さない。
#          キー=値 の行を while read で読み、source しない。
#          準備中（starting）のあいだは、入力を 5 秒ずつ待ち（read -t）、STATE が変わったら、コマンドを動かさずにメニューを描き直す
#          （裏の準備は数分かかることがあり、つながっても「準備中」のままだと迷うため）。待ち切れと EOF は、待った時間でも見分ける（Bash 3.2）
#      環境ブランチ（sf-tools/config/branches.txt の行。ファイルがない・空なら main だけ）の上では、続けて
#      「⚠ 環境ブランチの上です」を出して終わる（流れの絵は出さない）
#   6. 続けて、作業の流れ「1 Check  >  2 Dryrun  >  3 Deploy  >  4 Push  >  5 Next」（番号はメニューの並びから引く）を出し、
#      今の段階を太字の水色にして、その真下に「^ <説明>」の印を出す（印の位置は、流れの文字数で合わせる。流れと印は ASCII の
#      記号だけで作る。丸数字・罫線は、端末によって 1 文字幅か 2 文字幅かが変わり、印がずれるため）。
#      今の段階は、上から順に当てはまったもの:
#        未コミットの変更がある（git status --porcelain の行数）→ Check「ここから（未コミットの変更 N 件）」/
#        追跡先がない → Push「ここ（まだ push していません。追跡先なし）」/
#        push していないコミットがある（git rev-list --count @{u}..HEAD）→ Push「ここ（push していないコミット N 件）」/
#        次の PR 先（下）が「出すものなし」→ 印の代わりに「▶ ターゲットファイル（…）に、出すものを書きます」/
#        none → 印の代わりに「✓ 全段階にリリース済みです」/ 発行中の PR → Next「ここ（PR #N の検証が緑になったら、マージ）」/
#        段階 → Next「ここ（<段階> へ PR を出す）」/ 分からない → Next「ここ（次の出し先を確かめる）」
#      次の PR 先は、sf-tools/logs/next-status.txt（sf-next.sh が判定のたびに書く HEAD=・NEXT=・PR=・SKIPPED=）。HEAD= が今の
#      先端のコミットと同じで、NEXT= が段階名の形（40 文字まで）のときだけ使う。PR= は 9 桁まで。キー=値 を while read で読み、source しない
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
# 表示する値から、画面を崩す文字を除く（制御文字 \x00-\x1f・\x7f と、C1 制御 U+0080〜U+009F・幅のない文字 U+200B〜U+200F・
#   文字の向きを変える文字 U+202A〜U+202E・U+2066〜U+2069・BOM U+FEFF の UTF-8 のバイト列）。
#   さらに、表示は echo -e のため、\ を \\ にする（\033 などの並びを、制御として解釈させない）。結果は標準出力
clean_text() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' \
        | LC_ALL=C sed -e $'s/\xe2\x80[\x8b-\x8f\xaa-\xae]//g' -e $'s/\xe2\x81[\xa6-\xa9]//g' -e $'s/\xef\xbb\xbf//g' -e $'s/\xc2[\x80-\x9f]//g' \
        | sed -e 's/\\/\\\\/g'
}

# デバッグログ（sf-log.sh）の状態を、短い表示にする（logs/apex/.status。なければ空。doc/sf-log-design.md 5.4）
#   結果は AL_TEXT（表示）・AL_COLOR（色）・AL_WARN（WARNING の文。あれば、もう 1 行出す）に入れる（$( ) を使わず、変数で返す）
#   common.sh を読まないため、キー=値 の行を while read で読み、決まったキーだけを使う（source しない）
apexlog_summary() {
    local f="logs/apex/.status" line k v state="" at="" cnt="" reason=""
    AL_TEXT=""; AL_COLOR=""; AL_WARN=""
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            STATE) state="$v" ;; EXPIRES_AT) at="$v" ;; COUNT_TODAY) cnt="$v" ;;
            REASON) reason="$v" ;; WARNING) AL_WARN="$v" ;;
        esac
    done < "$f"
    at=$(clean_text "$at"); cnt=$(clean_text "$cnt"); reason=$(clean_text "$reason"); AL_WARN=$(clean_text "$AL_WARN")   # VAR=$(cmd)
    # 色は状態で変える（取得中 = 太字の緑 / 準備中 = 太字の水色 / 取れていません = 太字の赤 / 取っていません・止まっています = 黄色）
    case "$state" in
        collecting) AL_TEXT="● 取得中（${at:+期限 ${at}・}今日 ${cnt:-0} 本）"; AL_COLOR="${BOLD}${GREEN}" ;;
        starting)   AL_TEXT="● 準備中"; AL_COLOR="${BOLD}${CYAN}" ;;
        skipped)    AL_TEXT="● 取っていません${reason:+（${reason}）}"; AL_COLOR="${YELLOW}" ;;
        error)      AL_TEXT="● 取れていません${reason:+（${reason}）}"; AL_COLOR="${BOLD}${RED}" ;;
        stopped)    AL_TEXT="● 止まっています${reason:+（${reason}）}"; AL_COLOR="${YELLOW}" ;;
        *)          AL_WARN="" ;;   # 知らない STATE・ファイルが壊れている → 何も出さない
    esac
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
    node -e 'try{const j=JSON.parse(require("fs").readFileSync(".sf/config.json","utf8"));const v=j["target-org"];if(typeof v==="string"){const t=v.replace(/[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g,"");process.stdout.write(t.length>60?t.slice(0,60)+"…":t)}}catch(e){}' 2>/dev/null
    return 0
}

print_status() {
    local branch org head changes ahead="" has_up=0 line k v nhead="" next="" pr="" skipped=""
    local top cur=-1 msg="" endmsg="" i seg pos off=3 plain="" colored="" cmd
    local stages=(sf-check sf-dryrun sf-deploy sf-push sf-next)
    branch=$(git symbolic-ref -q --short HEAD 2>/dev/null) || branch=""   # VAR=$(cmd)（common.sh を読まない単独の設計。以下も同じ）
    org=$(target_org)
    # 表示する値は clean_text で掃除する（画面を崩す文字を除き、echo -e のため \ を \\ にする）。
    #   次の PR 先・PR の番号は、下で形を確かめる（英数字と記号の一部だけを通す）
    org=$(clean_text "$org"); branch=$(clean_text "$branch")   # VAR=$(cmd)
    apexlog_summary   # AL_TEXT・AL_WARN は、中で clean_text を通した値から作る

    # 1 行目: ブランチ ｜ 組織 ｜ ログ（ないものは出さない）
    if [[ -n "$branch" ]]; then top="${BOLD}${branch}${RESET}"; else top="${YELLOW}（ブランチの上にいません）${RESET}"; fi
    [[ -n "$org" ]] && top="${top} ｜ ${org}"
    [[ -n "$AL_TEXT" ]] && top="${top} ｜ ログ ${AL_COLOR}${AL_TEXT}${RESET}"
    echo -e "  ${top}"
    [[ -n "$AL_WARN" ]] && echo -e "${YELLOW}  ⚠ デバッグログ: ${AL_WARN}${RESET}"
    [[ -z "$branch" ]] && return 0
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

    # 今の段階（cur = stages の位置。-1 = 流れの下に印を出さない）と、印の横の文
    if [[ "$changes" -gt 0 ]]; then
        cur=0; msg="ここから（未コミットの変更 ${changes} 件）"
    elif [[ $has_up -eq 0 ]]; then
        cur=3; msg="ここ（まだ push していません。追跡先なし）"
    elif [[ "$ahead" -gt 0 ]]; then
        cur=3; msg="ここ（push していないコミット ${ahead} 件）"
    elif [[ "$skipped" == "true" ]]; then
        endmsg="▶ ターゲットファイル（sf-tools/release/${branch}/）に、出すものを書きます"
    elif [[ "$next" == "none" ]]; then
        endmsg="${GREEN}✓ 全段階にリリース済みです（このブランチの作業は終わり）${RESET}"
    elif [[ -n "$next" && -n "$pr" ]]; then
        cur=4; msg="ここ（PR #${pr} の検証が緑になったら、マージ）"
    elif [[ -n "$next" ]]; then
        cur=4; msg="ここ（${next} へ PR を出す）"
    else
        cur=4; msg="ここ（次の出し先を確かめる）"
    fi

    # 作業の流れ（1 Check  >  2 Dryrun  >  …）。今の段階は太字の水色。幅が必ず 1 文字の ASCII だけで作り、
    #   下の印（^）の位置を、文字数で合わせる（丸数字・罫線は、端末によって幅が 1 か 2 か変わり、ずれるため）
    echo ""
    for i in 0 1 2 3 4; do
        cmd="${stages[$i]}"
        seg="$(number_of "$cmd") $(label_of "$cmd")"
        [[ $i -gt 0 ]] && { plain="${plain}  >  "; colored="${colored}${DIM}  >  ${RESET}"; }
        [[ $i -eq $cur ]] && off=$(( 3 + ${#plain} ))
        plain="${plain}${seg}"
        if [[ $i -eq $cur ]]; then colored="${colored}${BOLD}${CYAN}${seg}${RESET}"; else colored="${colored}${seg}"; fi
    done
    echo -e "   ${colored}"
    if [[ $cur -ge 0 ]]; then
        pos=$(printf '%*s' "$off" '')
        echo -e "${pos}${BOLD}${CYAN}^ ${msg}${RESET}"
    elif [[ -n "$endmsg" ]]; then
        echo -e "   ${endmsg}"
    fi
    return 0
}

print_menu() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  >> Launcher <<${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    print_status
    echo ""
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
