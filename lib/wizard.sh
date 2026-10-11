#!/bin/bash
# ==============================================================================
# wizard.sh - ウィザード形式の画面の共通部品
# ==============================================================================
# 利用者が「いま、どこ？」「これは、何？」「次は、何をすればいい？」と迷わないための、画面の部品。
# 画面の見た目と、操作の語彙（Enter = 次へ / 番号 = 選択 / q = 中断）は、この部品だけが決める。
# 設計: doc/wizard-ux-design.md
#
# 【前提】
#   lib/common.sh を source 済みであること（CLR_* / die / read_input を使う）。
#   表示は、標準エラー出力（log と同じ）。色は、CLR_*（端末でないときは空）。
#
# 【提供する関数】
#   wizard_banner TITLE                      ... 太枠のタイトル（開始・完了の画面）
#   wizard_rule                              ... 区切り線
#   wizard_step N TOTAL TITLE PURPOSE [完了したステップ名...]
#                                            ... ステップの見出し（現在地・完了済み・目的の 1 文）
#   wizard_checklist TITLE ITEM...           ... 「□ 項目」の一覧（事前に用意するもの）
#   wizard_do ITEM...                        ... 「▶ あなたがやること」（番号付き）
#   wizard_next TEXT                         ... 「▶ そのあと」
#   wizard_hint TEXT                         ... 操作のヒント（画面の下）
#   wizard_auto TEXT                         ... 自動の処理の 1 行表示（✔）
#   wizard_confirm [PROMPT]                  ... Enter / Y で進む。N / q は die。それ以外は、再入力
#   wizard_fail CAUSE FIX RESUME             ... 失敗の三点セット（何が起きたか / どう直すか / どこから再開か）
#   wizard_done TITLE MADE -- NEXT...        ... 完了画面（できたこと / 次にやること）
# ==============================================================================

_wiz_out() { printf '%b\n' "$*" >&2; }

# 太枠のタイトル
wizard_banner() {
    _wiz_out ""
    _wiz_out "${CLR_INFO}════════════════════════════════════════════════════════${CLR_RESET}"
    _wiz_out "${CLR_INFO}  $1${CLR_RESET}"
    _wiz_out "${CLR_INFO}════════════════════════════════════════════════════════${CLR_RESET}"
}

# 区切り線
wizard_rule() {
    _wiz_out "${CLR_INFO}────────────────────────────────────────────────────────${CLR_RESET}"
}

# ステップの見出し。引数: 番号 全体の数 タイトル 目的の 1 文 [完了したステップ名...]
wizard_step() {
    local n="$1" total="$2" title="$3" purpose="${4:-}"
    shift 4
    local done_list="" t
    for t in "$@"; do done_list+="${done_list:+・}${t}"; done
    _wiz_out ""
    wizard_rule
    _wiz_out "  ${CLR_INFO}ステップ ${n} / ${total}: ${title}${CLR_RESET}"
    [[ -n "$done_list" ]] && _wiz_out "  （完了: ${done_list}）"
    wizard_rule
    if [[ -n "$purpose" ]]; then
        _wiz_out ""
        _wiz_out "  ${purpose}"
    fi
    return 0
}

# 事前に用意するものの一覧。引数: 見出し 項目...
wizard_checklist() {
    local title="$1" item
    shift
    _wiz_out ""
    _wiz_out "  ${CLR_WARNING}${title}${CLR_RESET}"
    for item in "$@"; do
        _wiz_out "    □ ${item}"
    done
}

# 「あなたがやること」（番号付き）。引数: 手順...
wizard_do() {
    local i=1 item
    _wiz_out ""
    _wiz_out "  ${CLR_WARNING}▶ あなたがやること${CLR_RESET}"
    for item in "$@"; do
        _wiz_out "      ${i}. ${item}"
        i=$((i + 1))
    done
}

# 「そのあと」。引数: 説明
wizard_next() {
    _wiz_out ""
    _wiz_out "  ▶ そのあと"
    _wiz_out "      $1"
}

# 操作のヒント（画面の下）。引数: 文言
wizard_hint() {
    _wiz_out ""
    _wiz_out "  $1"
}

# 自動の処理の 1 行表示。引数: 説明
wizard_auto() {
    _wiz_out "  ${CLR_SUCCESS}✔${CLR_RESET} $1"
}

# 確認。Enter（空）または Y で進む。N / q は die（管理者向けコマンドの確認の規約: N / q で必ず中断）。
# それ以外の入力は、再入力（打ち間違いで、進まないため）。引数: 確認の文言（省略可）
wizard_confirm() {
    local prompt="${1:-用意ができたら Enter を押してください（q で中断）}" ans
    while true; do
        read_input ans "  ▶ ${prompt}: " || die "中断しました。"  # EOF → 中断
        case "$ans" in
            ""|Y|y) return 0 ;;
            N|n|Q|q) die "中断しました。" ;;
            *) _wiz_out "  Enter を押すと、進みます。やめる場合は、q を入力してください。" ;;
        esac
    done
}

# 失敗の三点セット。引数: 原因 直し方 再開の方法
#   die の前に呼ぶ（die のメッセージは、規約どおり、事実のみにする）
wizard_fail() {
    _wiz_out ""
    _wiz_out "  ${CLR_ERR}✖ うまくいきませんでした${CLR_RESET}"
    _wiz_out "     原因     : $1"
    [[ -n "${2:-}" ]] && _wiz_out "  【直し方】 $2"
    [[ -n "${3:-}" ]] && _wiz_out "  【やり直し】 $3"
    return 0
}

# 完了画面。引数: タイトル できたこと -- 次にやること...
wizard_done() {
    local title="$1" made="$2" item
    shift 2
    [[ "${1:-}" == "--" ]] && shift
    wizard_banner "$title"
    _wiz_out ""
    _wiz_out "  設定したもの : ${made}"
    if [[ $# -gt 0 ]]; then
        _wiz_out ""
        _wiz_out "  ${CLR_WARNING}【次にやること】${CLR_RESET}"
        for item in "$@"; do
            _wiz_out "    ${item}"
        done
    fi
    _wiz_out ""
}
