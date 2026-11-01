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
#   3. メニュー（番号: 表示名 → 実行するスクリプト）:
#        1: Check → sf-check.sh   2: Push → sf-push.sh       3: Next → sf-next.sh
#        4: Dryrun → sf-dryrun.sh 5: Deploy → sf-deploy.sh   6: Start → sf-start.sh   7: Restart → sf-restart.sh
#      VS Code のターミナル（環境変数 TERM_PROGRAM=vscode）では 6・7 を表示しない（番号 6・7 は範囲外になる）
#   4. 選んだコマンドは、このスクリプトと同じフォルダの sf-xxx.sh を、引数なしで bash で実行する。
#      スクリプトがなければ、警告を表示する
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
DIM='\033[2m'
RESET='\033[0m'

# ------------------------------------------------------------------------------
# メニュー定義 (コマンド名 | 説明)
# VSCode 内では start / restart を除外（code . の二重起動・表示乱れ防止）
# ------------------------------------------------------------------------------
MENU_ITEMS_ALL=(
    "sf-check    | ターゲットファイルの構文チェック"
    "sf-push     | 変更をコミット & プッシュ"
    "sf-next     | 次の PR 先ブランチを確認"
    "sf-dryrun   | 現在接続中の組織へリリース検証"
    "sf-deploy   | 現在接続中の組織へリリース"
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
print_menu() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  >> Launcher <<${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────────────${RESET}"

    local num=1
    for item in "${MENU_ITEMS[@]}"; do
        local cmd="${item%%|*}"
        local desc="${item#*|}"
        local label="${cmd// /}"
        label="${label#sf-}"
        # 先頭を大文字に（${label^} は Bash 4 以降のため使わない。macOS 標準の Bash 3.2 で動かす）
        label="$(printf '%s' "${label:0:1}" | tr '[:lower:]' '[:upper:]')${label:1}"
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
    bash "$script"
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
        local input cmd

        # 入力ループ（1文字即時入力・無効入力は行クリアして待機）
        while true; do
            printf "  番号を入力 (1-%d / q で終了): " "$count"
            read -rsn1 input || { printf "\n"; exit 0; }  # EOF → 正常終了

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
