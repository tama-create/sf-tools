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
#        4: Push → sf-push.sh     5: PullRequest → sf-next.sh（中身は、次の段階へプルリクエストを出す。出し先を確かめる）
#        6: Start → sf-start.sh   7: Restart → sf-restart.sh（1 日の最初・組織の切り替えのときだけ使うため、5 との間に線を引く）
#      表示名は、sf- を除いて先頭を大文字にした名前（sf-next だけは PullRequest）。名前の欄は 11 文字の幅でそろえる。
#      起動のときに 1 回だけ作る（MENU_LABELS）。fzf モードも同じ表示名で出し、選んだ表示名から、実行するスクリプトを引く
#      VS Code のターミナル（環境変数 TERM_PROGRAM=vscode）では 6・7 を表示しない（番号 6・7 は範囲外になる。線も引かない）
#      （2026-11-26 に、1: Check 2: Push 3: Next 4: Dryrun 5: Deploy の並びから、作業の順に並べ替えた。2026-11-27 に、
#       5 の表示名を Next から PullRequest にした）
#   4. 選んだコマンドは、このスクリプトと同じフォルダの sf-xxx.sh を、引数なしで bash で実行する。
#      スクリプトがなければ、警告を表示する
#   5. メニューを表示するたびに、線と線の間に、見出しの 2 行を表示する（読み取りのみ。通信しない。2026-11-27）
#      1 行目: 「  >> LAUNCHER <<   <ブランチ> @ <組織> ／ 変更 N 件 ／ Log: <デバッグログの状態>」（ないものは出さない）
#        2 行目以降は、頭に「  >> LAUNCHER <<   」と同じ幅（19 文字）の空白を置き、1 行目のブランチ名の位置にそろえる
#        表示する値（ブランチ・組織・デバッグログの期限・本数・理由・WARNING）は、すべて clean_into で掃除する（制御文字・
#        幅のない文字・文字の向きを変える文字・BOM を除き、echo -e のため \ を 2 つ重ねる。値の中の文字で、画面を崩させない）
#        ブランチ・先端のコミット・変更の数は、1 回の git status --porcelain=v2 --branch から読む（描画のたびの git の
#          起動を 1 回にする）。変更の数は、変更・追跡していないファイルの行の数（名前の変更も 1 件）。
#          ブランチの上にいなければ「（ブランチの上にいません）」（と組織）だけを出して終わる
#        組織: .sf/config.json の target-org を node で読む（読めなければ出さない。表示を崩す文字を除き、60 文字で切る。
#          ファイルの中身が前回と同じなら、node を起動せず、前回の結果を使う）
#        デバッグログ: logs/apex/.status の STATE による（collecting = 取得中 (<期限>/<今日の本数>本) / starting = 準備中 /
#          skipped = 取っていません / error = 取れていません / stopped = 止まっています。理由（REASON）があれば括弧で添える）。
#          色は状態で変える（取得中 = 太字の緑 / 準備中 = 太字の水色 / 取れていません = 太字の赤 / 取っていません・止まっています = 黄色）。
#          WARNING があれば「⚠ Log: …」をもう 1 行。ファイルがない・STATE がそれ以外なら、ログの部分を出さない。
#          キー=値 の行を while read で読み、source しない。
#          準備中（starting）のあいだは、入力を 5 秒ずつ待ち（read -t）、STATE が変わったら、コマンドを動かさずにメニューを描き直す
#          （裏の準備は数分かかることがあり、つながっても「準備中」のままだと迷うため）。待ち切れと EOF は、待った時間でも見分ける（Bash 3.2）
#      環境ブランチ（sf-tools/config/branches.txt の行。ファイルがない・空なら main だけ）の上では、続けて
#      「⚠ 環境ブランチの上です」を出して終わる（Branch: の行は出さない）
#   6. 2 行目: 「Branch: <段階の並び>」。段階を下から順に「 ⇒ 」でつなぎ、出し終わった段階 = 「✓ <段階>」（緑）/
#      次の段階 = 「▸ <段階> (次のPR)」、発行中の PR があれば「▸ <段階> (PR #N 発行中)」（太字の水色）/ まだの段階 = 「× <段階>」（薄く）。
#      全段階に出し終わり（NEXT=none）→ すべて ✓ で、最後に「(全段階にリリース済み)」。
#      出すものなし（SKIPPED=true）→ 「出すものなし（ターゲットファイル sf-tools/release/<ブランチ>/ が空）」。
#      元は、sf-tools/logs/next-status.txt（sf-next.sh が判定のたびに書く HEAD=・NEXT=・PR=・SKIPPED=・TIERS=）。
#      HEAD= が今の先端のコミットと同じで、NEXT= が段階名の形（40 文字まで）、TIERS= が段階名を空白でつないだ形（10 個まで）、
#      TIERS= に同じ段階が 2 回出てこず、NEXT= が none か TIERS= の中にあり、SKIPPED= が true か false のときだけ使う。PR= は 9 桁まで。キー=値 を while read で読み、source しない。
#      使えないとき（ファイルがない・古い・形が違う）は、裏で sf-next.sh --status を動かし（標準入力・出力は閉じる。判定だけで、
#      PR は作らない）、終わるまで「（確かめています…）」と出す。終わったら（待ち切れのときに kill -0 で見る）、メニューを描き直す。
#      裏の判定は、先端のコミットごとに 1 回だけ（失敗しても繰り返さない）。判定できなかったとき（オフライン・gh の認証切れ・
#      push していない変更など）は「（5 PullRequest で確かめる）」（番号はメニューの並びから引く）。環境変数
#      SF_LAUNCHER_BG_STATUS=0 で、裏の判定を止められる（テスト用）。2026-11-27
#      ランチャーを終えても、裏の判定は止めない（終わるまで動いて、結果を書く）。読み込み直す（処理の流れ 8）ときは、
#      判定したコミットとプロセスの番号を、環境変数（SF_LAUNCHER_BG_HEAD・SF_LAUNCHER_BG_PID）で新しい版へ引き継ぐ
#      （exec のあとも同じプロセスのため、裏の判定は、そのまま子として残る）。前面の 5 PullRequest と同時に動いても、
#      sf-next.sh は、一時ファイルに書いてから置き換えるため、書きかけを読まない
#   7. コマンドが終わったら、結果を 1 行で出す: 終了コード 0 → 「✓ <表示名>: 終わりました（成功）」（太字の緑）/
#      それ以外 → 「✗ <表示名>: 失敗、または中断しました（終了コード N）」（太字の赤。q での中断も 1 になるため、両方を書く）
#   8. メニューの入力は、5 秒ずつ待つ（read -t。Bash 3.2 は、待ち切れと EOF の戻り値が同じ 1 のため、待った時間で見分ける。
#      4 秒以上たってからの EOF は、1 回だけ待ち切れとして扱い、次の読み取り（すぐ EOF で返る）で終わる）。待ち切れたとき・メニューを描き直す前に、
#      このスクリプト自身のファイルが、起動のあとに書き換わったかを見る（起動のときに sf-tools/logs/.launcher-<PID> を作り、
#      それより新しいか（-nt）で比べる。コマンドを起動しない）。書き換わっていたら「↻ …読み込み直します」と出して、新しい版を
#      同じ引数なし（メニュー）で exec し直す（sf-start.sh は、裏の sf-install.sh が git pull で sf-tools を最新にするのと同時に、
#      前面でランチャーを起動するため、ランチャーは古い版を読み込んだまま動いていた。2026-11-27）。
#      sf-tools/logs がない・印のファイルを作れないときは、確かめない。秒の単位で比べる環境（Bash 3.2）では、起動と同じ秒の
#      書き換えは見分けられない。印のファイルは、終了のときに消す（exec の前にも消す）。メニューのとき（引数なし）だけ
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
    "sf-next     | 次の段階へプルリクエストを出す（出し先を確かめる）"
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
# 表示する値から、画面を崩す文字を除き、変数 $1 に入れる（clean_into 変数名 値）。除くのは、制御文字 \x00-\x1f・\x7f と、
#   C1 制御 U+0080〜U+009F・幅のない文字 U+200B〜U+200F・文字の向きを変える文字 U+202A〜U+202E・U+2066〜U+2069・BOM U+FEFF の
#   UTF-8 のバイト列。表示は echo -e のため、\ を 2 つ重ねる（\033 などの並びを、制御として解釈させない）。
#   速い道: 英数字と、よく使う記号・空白だけの値は、そのまま使う（コマンドを起動しない。描画のたびの起動を減らすため。
#   Windows の Git Bash では、コマンドの起動が特に遅い）。それ以外（日本語・\・制御文字を含む）だけ、tr と sed で掃除する
clean_into() {
    local _v="$2" _r
    case "$_v" in
        *[!A-Za-z0-9._/:@+=,\ -]*)
            _r=$(printf '%s' "$_v" | LC_ALL=C tr -d '\000-\037\177' \
                | LC_ALL=C sed -e $'s/\xe2\x80[\x8b-\x8f\xaa-\xae]//g' -e $'s/\xe2\x81[\xa6-\xa9]//g' -e $'s/\xef\xbb\xbf//g' -e $'s/\xc2[\x80-\x9f]//g' \
                | sed -e 's/\\/\\\\/g') ;;   # VAR=$(cmd)
        *)  _r="$_v" ;;
    esac
    printf -v "$1" '%s' "$_r"
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
    clean_into at "$at"; clean_into cnt "$cnt"; clean_into reason "$reason"; clean_into AL_WARN "$AL_WARN"
    # 色は状態で変える（取得中 = 太字の緑 / 準備中 = 太字の水色 / 取れていません = 太字の赤 / 取っていません・止まっています = 黄色）
    case "$state" in
        collecting) AL_TEXT="取得中 (${at:+${at}/}${cnt:-0}本)"; AL_COLOR="${BOLD}${GREEN}" ;;   # (期限/今日の本数)
        starting)   AL_TEXT="準備中"; AL_COLOR="${BOLD}${CYAN}" ;;
        skipped)    AL_TEXT="取っていません${reason:+（${reason}）}"; AL_COLOR="${YELLOW}" ;;
        error)      AL_TEXT="取れていません${reason:+（${reason}）}"; AL_COLOR="${BOLD}${RED}" ;;
        stopped)    AL_TEXT="止まっています${reason:+（${reason}）}"; AL_COLOR="${YELLOW}" ;;
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

# コマンド名 → 表示名（sf-check → Check・sf-next → PR）。${x^} は Bash 4 以降のため、tr で先頭を大文字にする
label_of() {
    [[ "$1" == "sf-next" ]] && { printf 'PullRequest'; return 0; }   # 中身は、次の段階へプルリクエストを出す（出し先を確かめる）
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

# 組織を ORG に入れる（掃除した値）。.sf/config.json の中身が前回と同じなら、node を起動せず、前回の結果を使う
#   （中身は read の組み込みで読むため、コマンドを起動しない。描画のたびの node の起動を減らす）
ORG_CACHE_SET=0; ORG_CACHE_KEY=""; ORG_CACHE_VAL=""
read_target_org() {
    local content=""
    ORG=""
    [[ -f ".sf/config.json" ]] || return 0
    IFS= read -r -d '' content < ".sf/config.json" || true   # 最後まで読むと終了コードが 0 以外になるため、無視する（中身は入る）
    if [[ $ORG_CACHE_SET -eq 1 && "$content" == "$ORG_CACHE_KEY" ]]; then ORG="$ORG_CACHE_VAL"; return 0; fi   # 空の中身も、前回と同じなら使う
    ORG=$(target_org)   # VAR=$(cmd)
    clean_into ORG "$ORG"
    ORG_CACHE_SET=1; ORG_CACHE_KEY="$content"; ORG_CACHE_VAL="$ORG"
    return 0
}

# メニューの表示名（MENU_ITEMS と同じ並び。sf-next は「PR」。それ以外は、sf- を除いて先頭を大文字にした名前）。
#   描画のたびには変わらないため、起動のときに 1 回だけ作る（描画のたびの tr の起動を減らす。Windows の Git Bash では、起動が特に遅い）
MENU_LABELS=()
for _item in "${MENU_ITEMS[@]}"; do _c="${_item%%|*}"; MENU_LABELS+=("$(label_of "${_c// /}")"); done
unset _item _c

# 見出しの 2 行目以降の頭（「  >> LAUNCHER <<   」と同じ幅の空白。1 行目のブランチ名の位置にそろえる。ASCII なので、文字数 = 幅）
HEAD_PAD="                   "

# 2 行目の裏の判定（処理の流れ 6）。print_menu は $( ) の中で呼ばないため、ここの変数は、描き直しのあいだも残る
BG_HEAD=""   # 裏の判定を始めた先端のコミット（同じコミットでは、もう始めない）
BG_PID=""    # 裏の判定のプロセス（終わったら空にする）
# 読み込み直し（exec。処理の流れ 8）の前の値を引き継ぐ（exec のあとも同じプロセスのため、裏の判定は、そのまま子として残る。
#   引き継がないと、同じコミットで、もう一度判定してしまう）。形が違えば使わない
[[ "${SF_LAUNCHER_BG_HEAD:-}" =~ ^[0-9a-f]{40,64}$ ]] && BG_HEAD="$SF_LAUNCHER_BG_HEAD"
[[ "${SF_LAUNCHER_BG_PID:-}" =~ ^[0-9]{1,10}$ ]] && BG_PID="$SF_LAUNCHER_BG_PID"
unset SF_LAUNCHER_BG_HEAD SF_LAUNCHER_BG_PID   # 子のコマンドには渡さない
bg_status_start() {
    [[ -n "$1" && "$1" != "$BG_HEAD" ]] || return 0
    [[ "${SF_LAUNCHER_BG_STATUS:-1}" == "1" && -f "$SCRIPT_DIR/sf-next.sh" ]] || return 0
    BG_HEAD="$1"
    bash "$SCRIPT_DIR/sf-next.sh" --status < /dev/null > /dev/null 2>&1 &   # cmd &（裏で動かす。結果は next-status.txt）
    BG_PID=$!
}
bg_status_running() { [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; }   # kill は組み込み（コマンドを起動しない）

print_status() {
    local branch="" org head="" changes=0 ahead=0 has_up=0 st line k v nhead="" next="" pr="" skipped="" tiers=""
    local parts t i=0 nidx=-1 rel="" seg
    # 1 回の git で、ブランチ・先端のコミット・追跡先・push していない数・変更の数を読む（git status --porcelain=v2 --branch。
    #   描画のたびの git の起動を 1 回にする）。git のリポジトリでなければ、空（ブランチの上にいない扱い）
    st=$(git status --porcelain=v2 --branch 2>/dev/null) || st=""   # VAR=$(cmd)（common.sh を読まない単独の設計）
    while IFS= read -r line; do
        case "$line" in
            "# branch.oid "*)      head="${line#\# branch.oid }" ;;
            "# branch.head "*)     branch="${line#\# branch.head }" ;;
            "# branch.ab +"*)      has_up=1; ahead="${line#\# branch.ab +}"; ahead="${ahead%% *}" ;;   # 追跡先があり、比べられるときだけ出る
            "#"*|"")               ;;
            *)                     changes=$((changes + 1)) ;;   # 変更・追跡していないファイルの行（無視の対象は出ない）
        esac
    done <<< "$st"
    [[ "$branch" == "(detached)" ]] && branch=""
    [[ "$head" == "(initial)" ]] && head=""
    [[ "$ahead" =~ ^[0-9]+$ ]] || ahead=0
    # 表示する値は clean_into で掃除する（画面を崩す文字を除き、echo -e のため \ を 2 つ重ねる）。
    #   次の PR 先・段階の名前・PR の番号は、下で形を確かめる（英数字と記号の一部だけを通す）
    clean_into branch "$branch"
    read_target_org; org="$ORG"
    apexlog_summary   # AL_TEXT・AL_WARN は、中で clean_into を通した値から作る

    # 1 行目: >> LAUNCHER <<   <ブランチ> @ <組織> ／ 変更 N 件 ／ Log: <状態>（ないものは出さない。／ は項目の区切り）
    if [[ -n "$branch" ]]; then
        parts="${BOLD}${branch}${RESET}${org:+ @ ${org}} ${DIM}／${RESET} 変更 ${changes} 件"
    else
        parts="${YELLOW}（ブランチの上にいません）${RESET}${org:+ ${DIM}／${RESET} ${org}}"
    fi
    [[ -n "$AL_TEXT" ]] && parts="${parts} ${DIM}／${RESET} Log: ${AL_COLOR}${AL_TEXT}${RESET}"
    echo -e "  ${BOLD}>> LAUNCHER <<${RESET}   ${parts}"
    [[ -n "$AL_WARN" ]] && echo -e "${HEAD_PAD}${YELLOW}⚠ Log: ${AL_WARN}${RESET}"
    [[ -z "$branch" ]] && return 0
    if is_env_branch "$branch"; then
        echo -e "${HEAD_PAD}${YELLOW}⚠ 環境ブランチの上です。作業は、sf-job.sh で作ったブランチで行います${RESET}"
        return 0
    fi

    # 2 行目: Branch: 段階の並び（sf-next.sh が最後に判定した結果。今の先端のコミットと同じときだけ使う。source しない）
    bg_status_running || BG_PID=""   # 裏の判定が終わっていれば、待つのをやめる（結果は、下でファイルから読む）
    if [[ -f "$NEXT_STATUS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            k="${line%%=*}"; v="${line#*=}"
            case "$k" in HEAD) nhead="$v" ;; NEXT) next="$v" ;; PR) pr="$v" ;; SKIPPED) skipped="$v" ;; TIERS) tiers="$v" ;; esac
        done < "$NEXT_STATUS_FILE"
    fi
    if [[ -z "$head" || "$nhead" != "$head" ]] || ! [[ "$next" =~ ^[A-Za-z0-9._/-]{1,40}$ ]] \
        || ! [[ "$tiers" =~ ^[A-Za-z0-9._/-]{1,40}( [A-Za-z0-9._/-]{1,40}){0,9}$ ]]; then
        next=""; pr=""; skipped=""; tiers=""   # 古い・ない・形が違う → 使わない（段階は 10 個まで）
    fi
    [[ "$pr" =~ ^[0-9]{1,9}$ ]] || pr=""   # 長さにも上限（表示を崩さないため）
    [[ "$skipped" == "true" || "$skipped" == "false" ]] || { next=""; pr=""; skipped=""; tiers=""; }   # SKIPPED= は true / false だけ

    if [[ "$skipped" == "true" ]]; then
        rel="出すものなし（ターゲットファイル sf-tools/release/${branch}/ が空）"
    elif [[ -n "$tiers" ]]; then
        # 段階の位置: next（none なら、全部が出し終わり）。同じ段階が 2 回出てくる一覧は、形の崩れとして使わない
        local seen=" " dup=0
        for t in $tiers; do
            [[ "$seen" == *" $t "* ]] && dup=1
            seen="${seen}${t} "
            [[ "$t" == "$next" ]] && nidx=$i
            i=$((i + 1))
        done
        if [[ $dup -eq 1 || ( "$next" != "none" && $nidx -lt 0 ) ]]; then
            rel="${DIM}（$(number_of sf-next) PullRequest で確かめる）${RESET}"   # 段階の重複・次の段階が一覧にない（形の崩れ）→ 使わない
        else
            i=0
            for t in $tiers; do
                if [[ "$next" == "none" || $i -lt $nidx ]]; then
                    seg="${GREEN}✓ ${t}${RESET}"
                elif [[ $i -eq $nidx ]]; then
                    if [[ -n "$pr" ]]; then seg="${BOLD}${CYAN}▸ ${t} (PR #${pr} 発行中)${RESET}"; else seg="${BOLD}${CYAN}▸ ${t} (次のPR)${RESET}"; fi
                else
                    seg="${DIM}× ${t}${RESET}"
                fi
                [[ $i -gt 0 ]] && rel="${rel} ${DIM}⇒${RESET} "
                rel="${rel}${seg}"
                i=$((i + 1))
            done
            [[ "$next" == "none" ]] && rel="${rel}  ${GREEN}(全段階にリリース済み)${RESET}"
        fi
    else
        # 使える結果がない → 裏で判定する（先端のコミットごとに 1 回）。動いているあいだは「確かめています」
        bg_status_start "$head"
        if bg_status_running; then
            rel="${DIM}（確かめています…）${RESET}"
        else
            rel="${DIM}（$(number_of sf-next) PullRequest で確かめる）${RESET}"
        fi
    fi
    echo -e "${HEAD_PAD}Branch: ${rel}"
    return 0
}

print_menu() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    print_status
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"

    local num=1 label
    for item in "${MENU_ITEMS[@]}"; do
        local desc="${item#*|}"
        label="${MENU_LABELS[$((num - 1))]}"
        # 日々の作業（1〜5）と、環境の起動・切り替え（Start・Restart）の間に線を引く
        [[ "$label" == "Start" ]] && echo -e "${DIM}  ──────────${RESET}"
        printf "  ${CYAN}[%d]${RESET} ${BOLD}%-11s${RESET} ${DIM}%s${RESET}\n" "$num" "$label" "$desc"
        (( num++ ))
    done

    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
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
# 自分の書き換わりを見る（処理の流れ 8）
# ------------------------------------------------------------------------------
LAUNCHER_SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
LAUNCHER_STAMP=""
start_self_watch() {
    [[ -d sf-tools/logs ]] || return 0
    LAUNCHER_STAMP="sf-tools/logs/.launcher-$$"
    { : > "$LAUNCHER_STAMP"; } 2>/dev/null || { LAUNCHER_STAMP=""; return 0; }   # 起動のときの時刻の印（: > はコマンドを起動しない）
    trap 'rm -f "$LAUNCHER_STAMP"' EXIT   # 終わったら印を消す（common.sh を読まない単独の設計のため、run は使わない）
}
reload_if_updated() {
    [[ -n "$LAUNCHER_STAMP" && "$LAUNCHER_SELF" -nt "$LAUNCHER_STAMP" ]] || return 0
    echo -e "  ${CYAN}↻ sf-tools が更新されたため、ランチャーを読み込み直します${RESET}"
    rm -f "$LAUNCHER_STAMP"; trap - EXIT   # exec では EXIT の trap が動かないため、先に消す
    SF_LAUNCHER_BG_HEAD="$BG_HEAD" SF_LAUNCHER_BG_PID="$BG_PID" exec bash "$LAUNCHER_SELF"   # 裏の判定の状態を引き継ぐ
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
    start_self_watch
    while true; do
        reload_if_updated   # 前のコマンド（Start など）の中で、sf-tools が更新されていたら、新しい版で描く
        print_menu

        local count="${#MENU_ITEMS[@]}"
        local input cmd shown t0 rc redraw=0
        shown=$(apexlog_state)   # 表示したデバッグログの状態（準備中のあいだは、変わったら描き直す）

        # 入力ループ（1文字即時入力・無効入力は行クリアして待機）
        while true; do
            printf "  番号を入力 (1-%d / q で終了): " "$count"
            # APEXLOG_REFRESH 秒ずつ待つ。待ち切れたら、自分の書き換わり（処理の流れ 8）と、準備中のあいだはデバッグログの
            #   状態を見て、変わっていたら描き直す（裏の準備は数分かかることがある。2026-11-23）
            t0=$SECONDS; rc=0
            read -rsn1 -t "$APEXLOG_REFRESH" input || rc=$?
            if [[ $rc -ne 0 ]]; then
                # 待ち切れ（Bash 4 以降は 128 より大きい。Bash 3.2 は 1 のため、待った時間でも見分ける）と EOF を分ける。
                #   4 秒以上たってからの EOF は、ここで 1 回だけ待ち切れとして扱われるが、次の read がすぐ EOF で返り、下で終わる
                if (( rc > 128 || SECONDS - t0 >= APEXLOG_REFRESH - 1 )); then
                    printf "\r\033[K"
                    reload_if_updated
                    if [[ "$shown" == "starting" && "$(apexlog_state)" != "starting" ]]; then printf "\n"; redraw=1; break; fi
                    if [[ -n "$BG_PID" ]] && ! bg_status_running; then printf "\n"; redraw=1; break; fi   # 裏の判定が終わった → 2 行目を描き直す
                    continue
                fi
                printf "\n"; exit 0   # EOF → 正常終了
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
        local idx=0
        for item in "${MENU_ITEMS[@]}"; do
            lines+=("$(printf "%-11s %s" "${MENU_LABELS[$idx]}" "${item#*|}")")
            idx=$((idx + 1))
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

        # 選んだ行の表示名から、コマンドを引く（表示名とコマンドの名前が違うもの（PullRequest → sf-next）があるため、MENU_LABELS で照らす）
        local label cmd=""
        label="${selected%% *}"
        idx=0
        for item in "${MENU_ITEMS[@]}"; do
            if [[ "${MENU_LABELS[$idx]}" == "$label" ]]; then cmd="${item%%|*}"; cmd="${cmd// /}"; break; fi
            idx=$((idx + 1))
        done
        [[ -n "$cmd" ]] && run_command "$cmd"
    done
}

main "$@"
