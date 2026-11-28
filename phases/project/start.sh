#!/bin/bash
# ==============================================================================
# phases/project/start.sh - sf-project.sh の部品: オーナーとプロジェクト名（XXXX）の決定・開始画面（4 章）と、管理者用の作業フォルダ（5 章）
# ==============================================================================
# bin/sf-project.sh が source する（単独では動かさない）。変数・関数は、sf-project.sh の 1〜2 章と、先に source した部品が用意する。
# 引数（"$@"）は、sf-project.sh のものが、そのまま見える（source に引数を渡さないため。shift も、sf-project.sh の引数に効く）。
# 2026-11-28 に、929 行あった sf-project.sh の 3〜6 章と 8 章を、部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# Phase のスクリプト（phases/init/）とは別のフォルダに置く（phases/init/ の *.sh は、単独で動かす前提のテストがあるため）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-project.sh が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 4. オーナーとプロジェクト名（XXXX）の決定・開始画面
# ------------------------------------------------------------------------------
# 利用者に見せるステップ（全 9 つ）と、内部の Phase の対応。ステップ 9（動作の確認）は、Phase ではなく、verify.sh を呼ぶ最後のステップ。表示と実行順は一致させる（doc/wizard-ux-design.md 4.1）
WIZ_TOTAL=9
WIZ_STEP_TITLES=("" "準備の確認" "プロジェクトの確認" "リポジトリの作成" "ブランチの構成" "GitHub の Token" "Slack の通知" "リポジトリの設定" "Salesforce の接続" "動作の確認")
WIZ_STEP_PURPOSES=("" \
    "必要なツールと、GitHub へのログインを確認します。" \
    "作るリポジトリの名前と場所を、確認します。" \
    "GitHub にリポジトリを作り、設定ファイルを用意します。" \
    "コードを、段階的に確認してから、最後の段階（main）に出す流れ（ブランチの構成）を選びます。" \
    "自動で動くワークフローが、リポジトリを更新するための、Token を登録します。" \
    "ワークフローの結果を、Slack に通知するための設定をします。" \
    "ここまでの内容を、リポジトリに反映し、保護のルールを設定します。" \
    "Salesforce の各組織と、GitHub を、接続します。" \
    "作ったリポジトリが、実際に動くこと（環境全体・リリース・削除）を、確認します。")
#                      Phase:  0  1  2  3  4  5  6  7  8  9 10
WIZ_PHASE_STEP=(0 1 2 3 3 4 5 6 7 7 8)
# Phase ごとの、利用者向けの名前（「前回は、○○まで完了しています」の表示に使う）
WIZ_PHASE_TITLES=("" "準備の確認" "プロジェクトの確認" "リポジトリの作成" "設定ファイルの作成" "ブランチの構成" "GitHub の Token" "Slack の通知" "初回のコミット" "リポジトリの設定" "Salesforce の接続")

export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --only / --resume N（2 以上）の指定がない（通常の実行。中断後の「続きをやる」を選ぶ場合も含む）か。
#   開始画面の全体像・動作の確認の質問は、このときだけ出す
FULL_START=0
[[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]] && FULL_START=1

# 実行場所の確認: 管理者用フォルダ（admin）・クローン（force-*）の中で実行すると、その中に admin/ ができて、
#   別のクローンに書き込む経路になる。作業フォルダ（sf-job.sh を実行する場所）で実行すること
_cwd_top=$(git rev-parse --show-toplevel 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用（Git の作業ツリーの外なら、空）
if [[ "$(basename "$PWD")" == "admin" || "$(basename "$PWD")" == force-* || "$(basename "${_cwd_top:-.}")" == force-* ]]; then
    die "sf-project.sh は、管理者用フォルダ（admin）・クローン（force-*）の中では実行できません: ${PWD}"
fi

resolve_init_identity  # GITHUB_OWNER / COMPANY_NAME（XXXX）をセット（引数 → 対話）

# 開始画面（FULL_START: --resume N（2 以上）/ --only の指定がないときは、全体像つき。続き・完了済みの選択画面は、このあとに出る。
#   --only / --resume N（2 以上）は、簡易表示）
if [[ "$FULL_START" -eq 1 ]]; then
    wizard_banner "新しい Salesforce プロジェクトを作ります"
    echo "" >&2
    echo "  作るもの   : ${GITHUB_OWNER}/force-${COMPANY_NAME}（GitHub のリポジトリ）" >&2
    echo "  かかる時間 : 30〜60 分ほどが目安です（ブラウザでの作業・Salesforce の反映待ちを含みます）" >&2
    echo "" >&2
else
    log "HEADER" "新規 Salesforce プロジェクトの初期セットアップを開始します (${SCRIPT_NAME}.sh)"
fi
[[ -n "${SF_INIT_RESTARTED:-}" ]] && log "INFO" "sf-tools を更新しました。更新した sf-tools で、はじめから実行しています。"

print_admin_warning --standard "新規 Salesforce リポジトリを GitHub に作成し" "初期セットアップを行います。"

# sf-tools が古いと、古い雛形でプロジェクトを作ってしまうため、最初に最新かを確認する（P14）。
#   管理者向けの警告の後（確認の前）に行う。更新した場合は、警告・確認から、もう一度、やりなおす（確認を、飛ばさない）。
#   現在のブランチを対象にする（本番 / 検証の選択には、依存しない）。遅れていれば、確認のうえ更新し、
#   更新した sf-tools で、自動的に、もう一度、実行する（利用者に、実行しなおしを、させない）。
#   実行しなおした後（SF_INIT_RESTARTED）は、確認しない（無限に実行しなおさないため）
_cur_branch=""
if [[ -z "${SF_INIT_RESTARTED:-}" ]]; then
    # Git リポジトリのときだけ、現在のブランチを調べる（リポジトリでない・HEAD がブランチでなければ、ここでは確認しない）
    if git -C "$SF_TOOLS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        _cur_branch=$(git -C "$SF_TOOLS_DIR" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    fi
    if [[ -n "$_cur_branch" ]]; then
        ensure_sf_tools_branch "$_cur_branch"
        if [[ $? -eq 2 ]]; then
            export SF_INIT_RESTARTED=1
            log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
            # exec のため run 不使用（このプロセスを置き換える）。まだ admin/ に移動しておらず、ロックも取っていない
            exec bash "$SF_PROJECT_SELF" "${ORIG_ARGS[@]}"
        fi
    fi
fi
# このブランチは、確認済み（Phase 2 は、最新化の確認を省略し、選んだ版とのブランチ違いだけを確認する）。
#   空（確認していない: 実行しなおした後・Git リポジトリでない・HEAD がブランチでない）なら、Phase 2 が最新化を確認する
export SF_INIT_TOOLS_CHECKED_BRANCH="$_cur_branch"

if [[ "$FULL_START" -eq 1 ]]; then
    wizard_checklist "【先に、用意してください】" \
        "GitHub : ${GITHUB_OWNER} の管理者としてログインしたブラウザ" \
        "Slack : 通知用の「共有チャンネル」（全員が参加するもの）。まだなければ、いま Slack で作ってください" \
        "Salesforce : 接続する組織の、システム管理者のアカウント（ブランチの構成で選ぶ数: 1〜3 組織）"
    echo "" >&2
    echo -e "  ${CLR_WARNING}【これから行うこと】${CLR_RESET}" >&2
    for _i in $(seq 1 "$WIZ_TOTAL"); do
        echo "    ${_i}. ${WIZ_STEP_TITLES[$_i]}" >&2
    done
    # 管理者向けの確認（Enter / Y で進む。N / q は中断）
    wizard_confirm "用意ができたら Enter を押してください（q で中断）"
else
    ask_yn "続行しますか？" || die "中断しました。"
fi

check_gh_owner "$GITHUB_OWNER"

log "INFO" "セットアップ中は Ctrl+C が無効です。中断するにはターミナルを閉じてください。"

# ------------------------------------------------------------------------------
# 5. 管理者用の作業フォルダ（admin）の作成・移動
# ------------------------------------------------------------------------------
INIT_BASE="$PWD"   # 作業フォルダ（sf-job.sh を実行する場所）
INIT_DIR="${PWD}/admin"
_state_suffix="-${COMPANY_NAME}"           # 途中経過のファイルは、プロジェクトごとに分ける（同じ admin に複数のプロジェクトを置くため）
run mkdir -p "$INIT_DIR" || die "管理者用フォルダの作成に失敗しました: ${INIT_DIR}"
cd "$INIT_DIR" || die "管理者用フォルダに移動できません: ${INIT_DIR}"

# 管理者用フォルダ（admin）には、XXXX だけの名前で、クローン（force-XXXX）を置く。同じ名前で、OWNER/force-XXXX 以外のクローン
#   （別のオーナーのもの・origin がない・GitHub 以外）があるときは、中断する（このあとの Phase が、別のリポジトリのクローンに、
#   コミット・push してしまうため。状態ファイルも、消さない）。大文字と小文字は、区別しない
if [[ -d "${PWD}/force-${COMPANY_NAME}/.git" ]] \
   && ! clone_matches_repo "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then
    die "管理者用フォルダ（${PWD}）の force-${COMPANY_NAME} は、${GITHUB_OWNER}/force-${COMPANY_NAME} のクローンではありません（origin: $(git_origin_redacted "${PWD}/force-${COMPANY_NAME}")）。"
fi
