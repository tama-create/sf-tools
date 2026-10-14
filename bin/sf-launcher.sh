#!/bin/bash
# ==============================================================================
# sf-launcher.sh - sf-tools コマンドランチャー
# ==============================================================================
# Git Bash から起動するメニュー形式ランチャー。
# 番号を入力して sf-xxx.sh を選択・実行します。
#
# 【使い方】
#   sf-launcher.sh              : メニューを表示して選択実行（番号入力）
#   sf-launcher.sh <番号>       : 番号を直接指定して即実行（例: sf-launcher.sh 1）
#   sf-launcher.sh --fzf        : fzf でインクリメンタル検索して選択実行
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --help / -h: 冒頭コメントを表示して終了
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
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
            local cmd
            cmd=$(get_command_by_number "$1") || {
                echo -e "${YELLOW}  ⚠ 番号 $1 は範囲外です${RESET}"
                exit 1
            }
            run_command "$cmd"
            exit $?
        else
            echo -e "${YELLOW}  ⚠ 引数には番号を指定してください（例: sfl 1）${RESET}"
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

            # 終了（エコー前に確認）
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
# fzf モード（sflf から呼ばれる）
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
