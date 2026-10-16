#!/bin/bash
# ==============================================================================
# sf-init.sh - 新規 Salesforce プロジェクトの初期セットアップ
# ==============================================================================
# 新しい force-xxx プロジェクトを GitHub に作成し、sf-tools と連携させるまでの
# 一連のセットアップを自動化する。
#
# 【プロジェクト名と、実行する場所】
#   リポジトリ名は「force-XXXX」。force- は固定で、XXXX（プロジェクト名）は、管理者が決める。
#   フォルダ構成には、決まりがない（どこで実行してもよい）。オーナーと XXXX は、次の順で決める:
#     1. 引数 --owner / --project（--project には、XXXX だけを指定する。force- まで書いても、除いて扱う）
#     2. 従来のフォルダ構成 …/home/{github-owner}/{company}/ で実行したとき（引数がなければ）、そこから自動で取る
#        （従来の環境は、そのまま動く。管理者用の作業フォルダは、init）
#     3. 対話: オーナーは、gh のログインから候補を出す（管理者の組織。1 つなら自動、複数なら番号で選ぶ）。
#        XXXX は、入力する（すでにあるプロジェクトの一覧を、参考に表示する。確認の画面つき）
#   2 以外（新しい形）の管理者用の作業フォルダは、admin（固定）。実行した場所（作業フォルダ）に、admin/force-XXXX ができる。
#   複数のプロジェクトを、同じ admin に作ってもよい（途中経過のファイルは、プロジェクトごとに分かれる:
#   .sf-init-XXXX.env / .sf-init-XXXX.progress。従来の構成の init は、.sf-init.env / .sf-init.progress のまま）。
#   ※ 管理者用の作業フォルダ（init / admin）の中や、force-* の中から実行すると、その中に作られてしまうため、
#      作業フォルダ（sf-job.sh を実行する場所）で実行すること
#
# 【処理フロー】
#   Phase 1:  環境チェック（ツール確認・GitHub CLI 認証確認）
#   Phase 2:  プロジェクト情報の確認（フォルダ構成からOWNERとプロジェクト名を自動導出）
#   Phase 3:  リポジトリ作成（gh repo create + git clone）
#   Phase 4:  ファイル生成（sf-install.sh / sf-hook.sh）
#   Phase 5:  ブランチ構成（対話選択 → branches.txt 更新）
#   Phase 6:  PAT_TOKEN の設定
#   Phase 7:  Slack 連携の設定
#   Phase 8:  初回コミット＆プッシュ
#   Phase 9:  GitHub リポジトリ設定・Ruleset の適用
#   Phase 10: JWT 認証情報の設定（Salesforce GitHub Secrets 登録）
#
# 【前提】
#   Salesforce CLI（sf）は npm 版（npm install -g @salesforce/cli）であること。
#   起動時に sf --version の終了コードを確認し、0 以外なら案内を表示して中断する
#   （Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。
#
# 【手動操作が必要なステップ】
#   - Salesforce 組織へのブラウザログイン
#   - GitHub Classic PAT トークンの作成（repo + workflow スコープ）
#   - Slack App の作成・Bot Token の取得
#   - 通知先 Slack チャンネルで Bot を招待（/invite @sf-notify-<プロジェクト名>）
#
# 【使い方】
#   cd {作業フォルダ}                    # 好きな場所（従来の …/home/{owner}/{company}/ でもよい）
#   ~/sf-tools/bin/sf-init.sh [--owner OWNER] [--project XXXX] [--resume N] [--only N]
#
#   cd {作業フォルダ}/admin/force-XXXX      # 管理者用の作業フォルダの中（従来の構成では init/force-XXXX）
#   ~/sf-tools/bin/sf-init.sh --add-tier staging   # staging tier を追加
#   ~/sf-tools/bin/sf-init.sh --add-tier develop   # develop tier を追加
#
# 【途中で止まったとき（続きから）】
#   各 Phase が成功するたびに、進捗を管理者用の作業フォルダの .sf-init.progress（新しい形では .sf-init-XXXX.progress）に記録する（SF_INIT_DONE_PHASE）。
#   途中（Phase 2〜9 まで完了）で止まった状態が残っていて、そのリポジトリがこの作業フォルダのものなら、
#   引数なしで起動したとき、次の 2 つから選ばせる（既定値はなく、番号を入力する）。
#     [1] 次の Phase から続きをやる（Phase 1 の環境チェックを実行したうえで、続きから。保存済みの入力内容を使う）
#     [2] 最初からやり直す（保存した状態を消して Phase 1 から。作成済みのリポジトリ・init フォルダは、そのまま使う）
#   管理者向けの警告・確認と gh のオーナー確認は、どちらの場合も、毎回、実行する。
#   --resume N / --only N を指定した場合は、この質問をせず、指定を優先する。ただし、完了済みのプロジェクトでは、
#   --resume N は拒否する（接続処理などを、確認なしで、やり直さないため）。
#   Phase 10（Salesforce の接続）は、段階（main / staging / develop）ごとに、完了を進捗に記録し、再実行では、完了した段階を、
#   スキップする（登録した Secret が、いまもあるときだけ。--only 10 では、記録も、スキップも、しない）。
#   セットアップが完了済み（SF_INIT_DONE_PHASE=10）のプロジェクトで起動したときは、「続きをやる」ではなく、
#   [1] いまの Salesforce の接続を見る（status.sh。何も変更しない） / [2] 動作を確認する（verify.sh = --verify） /
#   [3] 最初からやり直す / [q] 終了 を選ばせる。
#
# 【動作の確認（最後のステップ）】
#   最後（Phase 10）まで実行したあと、対話できる端末のときは、「動作を確認しますか？ [Enter = 確認する / s = あとで]」を聞く
#   （通しの実行と、中断後の「続きをやる」のときだけ。--resume N / --only N では、聞かない）。
#   Enter なら、管理者用フォルダで、verify.sh（環境全体の確認 → Hello World のリリースと削除）を、確認なしで実行する
#   （確認は、ここの 1 回だけ。SF_VERIFY_CONFIRMED=1）。確認の失敗は、セットアップの失敗にはしない（結果と、直し方を表示する）。
#   完了済みのプロジェクトで再実行したときは、[2] 動作を、確認する、でも実行できる。
#
# 【init フォルダ（管理者用フォルダ）】
#   セットアップが終わっても、init フォルダは削除しない（削除の質問は廃止した）。管理者用のフォルダとして残し、
#   ワークフローの更新（sf-sync-wf.sh）・接続の確認（--status）・接続先の付け替え（--reconnect）などのメンテナンスに使う。
#   日常の開発には使わない（開発は、sf-job.sh の作業フォルダで行う）。完了画面に、このフォルダのパスを表示する。
#   残るファイルに秘密情報が含まれないよう、完了時に .sf-init.env から Token の値の行（*TOKEN_VALUE=）を消す。
#   このフォルダの force-XXXX は、完了時に、admin ブランチ（main から作る）にし、GitHub にも push する（git push -u origin admin）。
#   main は保護ブランチのため、その上で作業しないようにするため。すでに admin があれば、作り直さず、切り替える。
#   admin は、main から古くなる（使う前に、main を取り込む）。push に失敗しても、セットアップは成功のまま、完了画面で知らせる。
#
# 【オプション】
#   --owner OWNER         : GitHub のオーナー（組織名またはユーザー名）。省略すると、gh のログインから候補を出す（対話）
#   --project XXXX        : プロジェクト名（リポジトリ force-XXXX の XXXX）。省略すると、入力を求める（対話）
#   --resume N            : Phase N から再開（Phase N 以降を、質問なしで実行する）
#   --only N              : Phase N のみ実行（デバッグ・単体テストに使用。進捗は記録しない）
#   --add-tier staging    : 既存プロジェクトに staging tier を追加
#   --add-tier develop    : 既存プロジェクトに develop tier を追加
#   --reconnect <段階>    : 1 つの段階（main / staging / develop）の、接続先の Salesforce 組織を付け替える（force-* 内で実行）
#   --status              : セットアップの診断（リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。不足は、直し方つき）と、段階ごとの、接続先（ログイン先・組織の種類・ユーザー・組織 ID）を一覧にする（読み取りのみ。force-* 内で実行）
#   --verify              : 動作の確認（実際のリポジトリ・組織に、Hello World を、リリースして、削除する。管理者向け。force-* 内で実行）。
#                           環境全体の確認（SF_TOOLS_BRANCH・ログに Token が残っていない・wf-metasync）も、最初に行う。詳細は phases/init/verify.sh
#     --plan              : （--verify と一緒に）診断と、実行内容の表示だけ（何も変更しない）
#     --cleanup           : （--verify と一緒に）削除のみ（検証が途中で止まって、組織に Hello World が残ったときの後始末）
#     --no-metasync       : （--verify と一緒に）環境の確認のうち、wf-metasync の実行を、省略する
#     --components        : （--verify と一緒に）Hello World の代わりに、パターン別のサンプル（Apex・トリガー・LWC・Aura・Flow・
#                           権限セット・Layout・メール テンプレート・オブジェクト・項目など）を、develop の組織だけに、リリースして、削除する
#     --validate-only     : （--verify --components と一緒に）検証（wf-validate = dry-run）だけ。PR は、マージせずに閉じる。組織には、何も反映しない
#     --with-objects      : （--verify --components と一緒に）オブジェクト系（トリガー・Layout・オブジェクト・項目）も、リリースして、削除する
#                           （削除したオブジェクトの名前は、15 日間、予約される）
#   --legacy-connected-app: 従来の接続アプリケーション（手動の入力。今後廃止予定）を使う。既定は、外部クライアントアプリ（自動で作成）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
# sf-init.sh はプロジェクト外から実行するため、ログは sf-tools 配下に記録する
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"  # 司令塔が起動のたびにログをリセットする

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
# sf-init.sh はプロジェクト外から実行するため、force-* チェックをバイパスする
export SF_INIT_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"
source "${SCRIPT_DIR}/../lib/wizard.sh"                 # ウィザード形式の画面の部品（doc/wizard-ux-design.md）
source "${SCRIPT_DIR}/../phases/init/init-common.sh"    # ensure_sf_tools_branch など（各フェーズと共通）

trap '' INT  # Ctrl+C を無効化（子プロセスにも継承される）

ORIG_ARGS=("$@")   # sf-tools を更新したあと、同じ引数で、実行しなおすために覚えておく

# ------------------------------------------------------------------------------
# 3. 引数解析
# ------------------------------------------------------------------------------
ONLY_PHASE=""
RESUME_PHASE=1
ADD_TIER_MODE=""
RECONNECT_MODE=""
STATUS_MODE=0
VERIFY_MODE=0
VERIFY_ARGS=()   # --verify のオプション（--plan / --cleanup / --no-metasync / --components / --validate-only）。verify.sh に、そのまま渡す

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help ;;
        --owner)
            [[ -n "${2:-}" ]] || die "--owner には、GitHub のオーナー（組織名またはユーザー名）を指定してください。"
            export SF_INIT_OWNER="$2"
            shift 2
            ;;
        --project)
            [[ -n "${2:-}" ]] || die "--project には、プロジェクト名（force-XXXX の XXXX の部分）を指定してください。"
            export SF_INIT_PROJECT="$2"
            shift 2
            ;;
        --only)
            ONLY_PHASE="$2"
            shift 2
            ;;
        --resume)
            RESUME_PHASE="$2"
            shift 2
            ;;
        --add-tier)
            ADD_TIER_MODE="$2"
            shift 2
            ;;
        --reconnect)
            RECONNECT_MODE="$2"
            [[ -n "$RECONNECT_MODE" ]] || die "--reconnect には、main・staging・develop のいずれかを指定してください。"
            shift 2
            ;;
        --status)
            STATUS_MODE=1
            shift
            ;;
        --verify)
            VERIFY_MODE=1
            shift
            ;;
        --plan|--cleanup|--no-metasync|--components|--validate-only|--with-objects)
            VERIFY_ARGS+=("$1")   # --verify と一緒に指定するもの（下で、--verify なしの指定を拒否する）
            shift
            ;;
        --legacy-connected-app)
            # 従来の接続アプリケーション（今後廃止予定）を使う。既定は、外部クライアントアプリ（自動で作成）
            export SF_INIT_LEGACY_CONNECTED_APP=1
            shift
            ;;
        *)
            die "不明なオプションです: $1
使い方:
  ~/sf-tools/bin/sf-init.sh                       # Phase 1〜10 を順次実行（途中で止まった状態があれば、続き / 最初からを選ぶ）
  ~/sf-tools/bin/sf-init.sh --project XXXX         # プロジェクト名（force-XXXX の XXXX）を指定する（--owner でオーナーも指定できる）
  ~/sf-tools/bin/sf-init.sh --resume N             # Phase N から最後まで順次実行（質問なし）
  ~/sf-tools/bin/sf-init.sh --only N               # Phase N のみ実行
  ~/sf-tools/bin/sf-init.sh --add-tier staging     # staging tier を追加
  ~/sf-tools/bin/sf-init.sh --add-tier develop     # develop tier を追加
  ~/sf-tools/bin/sf-init.sh --reconnect main       # main の接続先（Salesforce 組織）を付け替える
  ~/sf-tools/bin/sf-init.sh --status               # セットアップの診断と、段階ごとの接続先を一覧にする
  ~/sf-tools/bin/sf-init.sh --verify               # 動作の確認（Hello World を、各段階にリリースして、削除する。--plan / --cleanup / --no-metasync）
  ~/sf-tools/bin/sf-init.sh --verify --components  # パターン別のサンプルを、develop の組織だけに、リリースして、削除する（--validate-only: 検証のみ）
  ~/sf-tools/bin/sf-init.sh --legacy-connected-app # 従来の接続アプリケーションを使う（今後廃止予定）"
            ;;
    esac
done

# sf が終了コードを正しく返すか確認する（npm 版が前提。NG なら案内を表示して中断する）
# --resume / --only / --add-tier のときも確認する（どの Phase でも sf を使うため）
check_sf_cli

# --add-tier モードは通常のフェーズループとは別処理
if [[ -n "$ADD_TIER_MODE" ]]; then
    log "HEADER" "tier 追加モード: ${ADD_TIER_MODE} (${SCRIPT_NAME}.sh)"
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export ADD_TIER="$ADD_TIER_MODE"
    bash "${SCRIPT_DIR}/../phases/init/add_tier.sh" \
        || die "--add-tier ${ADD_TIER_MODE} が失敗しました。"
    exit $RET_OK
fi

# --plan / --cleanup / --no-metasync / --components / --validate-only / --with-objects は、--verify と一緒にだけ指定できる
if [[ "$VERIFY_MODE" -eq 0 && ${#VERIFY_ARGS[@]} -gt 0 ]]; then
    die "${VERIFY_ARGS[*]} は、--verify と一緒に指定してください。"
fi

# --verify モード（動作の確認。force-* ディレクトリの中で実行する。管理者向けの警告・確認は、verify.sh が行う）
if [[ "$VERIFY_MODE" -eq 1 ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # 検証の失敗（終了コード 1）は、表示のとおり。エラー終了のメッセージは、出さない
    bash "${SCRIPT_DIR}/../phases/init/verify.sh" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}
    exit $?
fi

# --status モード（読み取りのみ。force-* ディレクトリの中で実行する）
if [[ "$STATUS_MODE" -eq 1 ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # 診断で不足があるとき（終了コード 1）は、表示のとおり。エラー終了のメッセージは、出さない
    bash "${SCRIPT_DIR}/../phases/init/status.sh"
    exit $?
fi

# --reconnect モード（1 つの段階の接続先を付け替える。force-* ディレクトリの中で実行する）
if [[ -n "$RECONNECT_MODE" ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export RECONNECT_TIER="$RECONNECT_MODE"
    bash "${SCRIPT_DIR}/../phases/init/reconnect.sh" || die "--reconnect ${RECONNECT_MODE} が失敗しました。"
    exit $RET_OK
fi

# 実行範囲を決定する
if [[ -n "$ONLY_PHASE" ]]; then
    START_PHASE=$ONLY_PHASE
    END_PHASE=$ONLY_PHASE
else
    START_PHASE=$RESUME_PHASE
    END_PHASE=10
fi

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
    "コードを、段階的に確認してから本番に出す流れ（ブランチの構成）を選びます。" \
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

# --only / --resume N の指定がない（通常の新規実行）か。開始画面の全体像は、このときだけ出す
FULL_START=0
[[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]] && FULL_START=1

resolve_init_identity  # GITHUB_OWNER / COMPANY_NAME（XXXX）/ PROJECT_LAYOUT をセット（引数 → 従来の構成 → 対話）

# 開始画面（通常の新規実行は、全体像つき。--only / --resume N は、簡易表示）
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
    # Git リポジトリのときだけ、現在のブランチを調べる（リポジトリでなければ、確認しない）
    if git -C "$SF_TOOLS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        _cur_branch=$(git -C "$SF_TOOLS_DIR" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    fi
    if [[ -n "$_cur_branch" ]]; then
        ensure_sf_tools_branch "$_cur_branch"
        if [[ $? -eq 2 ]]; then
            export SF_INIT_RESTARTED=1
            log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
            exec bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
        fi
    fi
fi
# このブランチは、確認済み（Phase 2 の確認を、省略するため）
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
# 5. 管理者用の作業フォルダ（従来の構成: init / 新しい形: admin）の作成・移動
# ------------------------------------------------------------------------------
INIT_BASE="$PWD"   # 作業フォルダ（sf-job.sh を実行する場所）
if [[ "$PROJECT_LAYOUT" == "legacy" ]]; then
    INIT_DIR="${PWD}/init"
    _state_suffix=""                       # 従来の構成: .sf-init.env / .sf-init.progress
else
    INIT_DIR="${PWD}/admin"
    _state_suffix="-${COMPANY_NAME}"       # 新しい形: プロジェクトごとに分ける（同じ admin に複数のプロジェクトを置くため）
fi
run mkdir -p "$INIT_DIR" || die "init フォルダの作成に失敗しました: ${INIT_DIR}"
cd "$INIT_DIR" || die "init フォルダに移動できません: ${INIT_DIR}"

# ------------------------------------------------------------------------------
# 6. 環境変数の export（各フェーズスクリプトから参照）
# ------------------------------------------------------------------------------
export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# .sf-init.env は管理者用の作業フォルダに配置する（cd 後の PWD が init/ か admin/ になる）
export SF_INIT_ENV_FILE="${PWD}/.sf-init${_state_suffix}.env"

# 進捗ファイル（成功した Phase を記録する。.sf-init.env とは別にする: 書き換えるときに、外部コマンドを使わないため）
export SF_INIT_PROGRESS_FILE="${PWD}/.sf-init${_state_suffix}.progress"
# Phase 10 の、段階ごとの再開（完了した段階を、進捗に記録し、再実行ではスキップする）。--only のときは、使わない
[[ -z "$ONLY_PHASE" ]] && export SF_INIT_TIER_RESUME=1

# ファイル（KEY=値 の行）から、値を 1 つ取り出す（source しない）。引数: キー ファイル。なければ空
_kv_value() {
    grep "^${1}=" "$2" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/\r$//; s/^"//; s/"$//'  # 取得専用のため run 不使用
}

# 前回の続きの確認（引数なしで起動したときだけ）
#   前回、途中まで進んでいて（SF_INIT_DONE_PHASE が 2〜9）、そのリポジトリが、この作業フォルダのものなら、
#   「続きをやる / 最初からやり直す」を選ばせる。続きを選ぶと、Phase 1（環境チェック）を実行したうえで、次の Phase から始める
#   表示は、Phase の番号ではなく、利用者向けの名前（WIZ_PHASE_TITLES）で出す
RESUMED=0
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
    prev_done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
    prev_at=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")        # VAR=$(cmd) のため run 不使用
    prev_repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
    if [[ "$prev_done" =~ ^[0-9]+$ && "$prev_done" -ge 2 && "$prev_done" -lt 10 \
          && "$prev_repo" == "${GITHUB_OWNER}/force-${COMPANY_NAME}" ]]; then
        next_phase=$((prev_done + 1))
        echo "" >&2
        log "INFO" "前回のセットアップは、「${WIZ_PHASE_TITLES[$prev_done]}」まで完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] 「${WIZ_PHASE_TITLES[$next_phase]}」から、続きをやる   ← おすすめ" >&2
        echo "    [2] 最初からやり直す（作成済みのリポジトリ・init フォルダは、そのまま使います）" >&2
        echo "    [q] 中断" >&2
        echo "" >&2
        read_key resume_choice "  ▶ 番号を入力してください [1-2/q]: " "[12Qq]"
        # shellcheck disable=SC2154  # resume_choice は、read_key（lib/input.sh）が、名前で受け取って代入する
        case "$resume_choice" in
            1) RESUMED=1
               START_PHASE=$next_phase
               END_PHASE=10
               ;;
            2) ;;  # 最初から（下で .sf-init.env を削除する）
            *) die "中断しました。" ;;
        esac
    elif [[ "$prev_done" == "10" && "$prev_repo" == "${GITHUB_OWNER}/force-${COMPANY_NAME}" ]]; then
        # 完了済みのプロジェクト: 「続きをやる」は意味がないため、完了済みであることと、できることを案内する
        prev_dir=$(_kv_value REPO_DIR "$SF_INIT_ENV_FILE")   # VAR=$(cmd) のため run 不使用
        echo "" >&2
        log "INFO" "このプロジェクトは、セットアップが、すでに完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] いまの Salesforce の接続を、見る（何も変更しません）   ← おすすめ" >&2
        echo "    [2] 動作を、確認する（Hello World を、各段階にリリースして、削除します。約 20 分）" >&2
        echo "    [3] 最初から、やり直す（作成済みのリポジトリは、そのまま使い、設定を、上書きします）" >&2
        echo "    [q] 終了" >&2
        echo "" >&2
        read_key done_choice "  ▶ 番号を入力してください [1-3/q]: " "[123Qq]"
        # shellcheck disable=SC2154  # done_choice も同様（read_key が代入する）
        case "$done_choice" in
            1) [[ -d "$prev_dir" ]] || die "管理者用のフォルダが見つかりません: ${prev_dir}"
               # 診断で不足があっても（終了コード 1）、表示のとおり。ここでは、エラー終了にしない
               ( cd "$prev_dir" && bash "${SF_TOOLS_DIR}/phases/init/status.sh" ) || true  # 不足の表示は、status.sh が行う
               exit $RET_OK
               ;;
            2) [[ -d "$prev_dir" ]] || die "管理者用のフォルダが見つかりません: ${prev_dir}"
               # 動作の確認（verify.sh）。結果は、verify.sh が、表示する。確認は、verify.sh の中で、聞く
               ( cd "$prev_dir" && bash "${SF_TOOLS_DIR}/phases/init/verify.sh" )
               exit $?
               ;;
            3) ;;  # 最初から（下で .sf-init.env を削除する）
            *) exit $RET_OK ;;
        esac
    fi
fi

# 完了済みのプロジェクトで、--resume N を明示した場合は、拒否する（接続処理などを、確認なしで、やり直さないため）。
#   やり直したいときは、引数なしで実行して選ぶ（[1] 接続を見る / [2] 動作を確認 / [3] 最初から）か、--reconnect を使う
if [[ "$RESUME_PHASE" -gt 1 && -z "$ONLY_PHASE" && -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
    _pd=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
    _pr=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
    if [[ "$_pd" == "10" && "$_pr" == "${GITHUB_OWNER}/force-${COMPANY_NAME}" ]]; then
        log "ERROR" "  このプロジェクト（${_pr}）は、セットアップが、すでに完了しています。"
        log "WARNING" "  接続先を付け替える        : force-* の中で sf-init.sh --reconnect <main|staging|develop>"
        log "WARNING" "  いまの状態を見る・動作を確認する・最初からやり直す : 引数なしで sf-init.sh を実行して、選んでください"
        die "完了済みのプロジェクトでは、--resume は使えません。"
    fi
fi

# 新規実行時（--resume / --only 時、前回の続きを選んだ時以外）は、前回の残骸を削除する（空ファイルは作らない）
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && "$RESUMED" -eq 0 ]]; then
    rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE"  # 新規実行時は残骸削除のみ（Phase 2 が初回書き出し）
fi

# ------------------------------------------------------------------------------
# 7. メイン実行フロー（フェーズループ）
# ------------------------------------------------------------------------------
# 通常の実行では、Phase の番号は出さない（ステップの見出しを出す）。--resume / --only のときだけ、範囲を出す
[[ "$FULL_START" -eq 1 ]] || log "INFO" "実行フェーズ: Phase ${START_PHASE} 〜 Phase ${END_PHASE}"
[[ -z "$ONLY_PHASE" ]] || log "WARNING" "--only は、指定した Phase だけを実行します。進捗は、更新しません（通常の「続きをやる」の状態は、変わりません）。"

# 続きから始める場合も、Phase 1（環境チェック。状態を持たない）は、毎回実行する
PHASE_LIST="$(seq "$START_PHASE" "$END_PHASE")"
[[ "$RESUMED" -eq 1 ]] && PHASE_LIST="1 ${PHASE_LIST}"

# ステップの見出しを出す（同じステップの Phase が続くときは、最初の 1 回だけ）。引数: Phase 番号
_show_step_header() {
    local p="$1" s i done_titles=()
    s="${WIZ_PHASE_STEP[$p]}"
    [[ "$s" == "$_LAST_STEP_SHOWN" ]] && return 0
    _LAST_STEP_SHOWN="$s"
    for i in $(seq 1 $((s - 1))); do done_titles+=("${WIZ_STEP_TITLES[$i]}"); done
    wizard_step "$s" "$WIZ_TOTAL" "${WIZ_STEP_TITLES[$s]}" "${WIZ_STEP_PURPOSES[$s]}" "${done_titles[@]}"
}
_LAST_STEP_SHOWN=""

for phase_num in $PHASE_LIST; do
    phase_script=$(ls "${SCRIPT_DIR}/../phases/init/$(printf '%02d' "$phase_num")"_*.sh 2>/dev/null | head -1) # VAR=$(cmd) のため run 不使用（Phase のスクリプトの検索。空なら、直後で die）
    if [[ -z "$phase_script" ]]; then
        die "Phase ${phase_num} のスクリプトが見つかりません: ${SCRIPT_DIR}/../phases/init/"
    fi
    # 通常の実行（--only なし）では、ステップの見出しを出す
    [[ -z "$ONLY_PHASE" ]] && _show_step_header "$phase_num"
    bash "$phase_script"
    phase_rc=$?
    if [[ $phase_rc -eq 75 ]]; then
        # sf-tools を更新した（Phase 2）。更新した sf-tools で、最初から、実行しなおす（1 回だけ。無限に繰り返さない）
        [[ -z "${SF_INIT_RESTARTED:-}" ]] || die "sf-tools を更新しても、最新になりませんでした。"
        export SF_INIT_RESTARTED=1
        log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
        exec bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
    fi
    if [[ $phase_rc -ne 0 ]]; then
        # 失敗の三点セット（原因は、直前の表示。直し方は、各 Phase の表示。ここでは、やり直しの方法を、正確に出す）
        if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 3 ]]; then
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-init.sh を実行し、「続きをやる」を選ぶと、「${WIZ_PHASE_TITLES[$phase_num]}」の最初から、再開します（ここまでの内容は、保存されています）"
        elif [[ -z "$ONLY_PHASE" ]]; then
            # 準備の確認・プロジェクトの確認: 保存された状態がないため、最初から、実行しなおす
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-init.sh を実行してください（最初から、始まります）"
        fi
        die "「${WIZ_PHASE_TITLES[$phase_num]}」が失敗しました。"
    fi
    # 成功した Phase を記録する（Phase 1 は、状態を持たないため、記録しない。--only は、記録しない）
    if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 2 && -f "$SF_INIT_ENV_FILE" ]]; then
        {
            printf 'SF_INIT_DONE_PHASE=%s\n' "$phase_num"
            printf 'SF_INIT_DONE_AT="%s"\n'  "$(date '+%Y-%m-%d %H:%M')"
        } > "$SF_INIT_PROGRESS_FILE" || die "進捗ファイルを更新できません: ${SF_INIT_PROGRESS_FILE}"
    fi
done

# ------------------------------------------------------------------------------
# 8. 後処理（全フェーズ完了後）
# ------------------------------------------------------------------------------
# .sf-init.env から REPO_DIR などを取得（完了画面の管理者用フォルダの案内に使用）
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# init フォルダは、削除せずに残す（管理者用のフォルダ。更新・接続の確認・やり直しなどのメンテナンスに使う）
#   以前は、最後に削除する質問を出していたが、廃止した。残るファイルに、秘密情報（Token の値）が含まれないように、
#   念のため、Token の値の行を .sf-init.env から消す（通常は、Phase 8 の push 後に、消えている）。
#   最後（Phase 10）まで実行したときだけ行う（--only 6 などの途中までの実行では、Phase 8 が、あとで使うため、消さない）
if [[ "$END_PHASE" -eq 10 && -f "$SF_INIT_ENV_FILE" ]]; then
    run sed_inplace '/^[A-Z_]*TOKEN_VALUE=/d' "$SF_INIT_ENV_FILE"
fi

# ステップ 9: 動作の確認（verify.sh）。聞くのは、「通しの実行」と、中断後の「続きをやる」だけ（FULL_START。
#   --resume N / --only N を明示した実行では、聞かない: Phase 単位のやり直しに、20 分ほどの検証を、混ぜないため）。
#   対話できる端末のときだけ聞く（SF_INIT_VERIFY_ASK=1 で、端末でなくても聞く: テスト用。GITHUB_ACTIONS 上では、聞かない）
#   Enter = 確認する / s = あとで。標準入力が閉じている（EOF）ときは、あとで、とする。確認の失敗は、セットアップの失敗にはしない
VERIFY_RESULT=""   # "" = 聞かなかった / done = 成功 / failed = 失敗あり / skipped = あとで
if [[ "$END_PHASE" -eq 10 && "$FULL_START" -eq 1 && "${GITHUB_ACTIONS:-}" != "true" \
      && ( -t 0 || "${SF_INIT_VERIFY_ASK:-}" == "1" ) ]]; then
    _done_titles=()
    for _i in $(seq 1 $((WIZ_TOTAL - 1))); do _done_titles+=("${WIZ_STEP_TITLES[$_i]}"); done
    wizard_step "$WIZ_TOTAL" "$WIZ_TOTAL" "${WIZ_STEP_TITLES[$WIZ_TOTAL]}" "${WIZ_STEP_PURPOSES[$WIZ_TOTAL]}" "${_done_titles[@]}"
    echo "" >&2
    echo "  環境全体の確認と、Hello World（誰も使わない、単純な Apex）の、リリースと削除を、各段階の組織で行います。" >&2
    echo "  所要時間の目安: 約 $((${BRANCH_COUNT:-1} * 6 + 3)) 分（Actions の混み具合で、前後します）。実際の組織にデプロイします（Hello World は、最後に削除します）。" >&2
    echo "" >&2
    while true; do
        read_input _vans "  ▶ 動作を確認しますか？ [Enter = 確認する / s = あとで]: " || _vans="s"  # EOF → あとで
        case "$_vans" in
            ""|Y|y) _vrun=1; break ;;
            S|s|Q|q|N|n) _vrun=0; break ;;
            *) echo "  Enter を押すと、確認します。あとで確認する場合は、s を入力してください。" >&2 ;;
        esac
    done
    if [[ "$_vrun" -eq 1 ]]; then
        # REPO_DIR が空のときは、現在のフォルダで実行する（${REPO_DIR:-.}）。Bash 5.3（Git for Windows 2.55 以降）は、
        #   cd "" を「cd: null directory」のエラーにする（3.2・5.2 は、何もせず成功する）。通常は、Phase 2 が設定する
        if ( cd "${REPO_DIR:-.}" && SF_VERIFY_CONFIRMED=1 bash "${SF_TOOLS_DIR}/phases/init/verify.sh" ); then  # 条件チェック
            VERIFY_RESULT="done"
        else
            VERIFY_RESULT="failed"
        fi
    else
        VERIFY_RESULT="skipped"
    fi
fi

# 管理者用のクローンを、admin ブランチにして、GitHub にも push する（main の上で、作業しないため）。
#   最後（Phase 10）まで実行したときだけ。動作の確認（verify.sh）のあとに行う。
#   どちらに失敗しても、セットアップは成功のまま、完了画面で知らせる
_admin_branch_line="     ・ブランチは admin です（このコンピューターと GitHub の両方にあります）"
_admin_stale_line="     ・admin は、main から古くなります。使う前に、main を取り込んでください（git pull origin main）"
if [[ "$END_PHASE" -eq 10 && -n "${REPO_DIR:-}" ]]; then
    if ! ensure_admin_branch "$REPO_DIR"; then
        log "WARNING" "管理者用のクローンを admin ブランチにできませんでした: ${REPO_DIR}"
        _admin_branch_line="     ・admin ブランチを作れませんでした（main のままです）。管理者用フォルダで、git switch -c admin を実行してください"
    elif ! push_admin_branch "$REPO_DIR"; then
        log "WARNING" "admin ブランチを GitHub に push できませんでした: ${REPO_DIR}"
        _admin_branch_line="     ・admin ブランチは、このコンピューターだけにあります（GitHub に push できませんでした）。管理者用フォルダで、git push -u origin admin を実行してください"
    fi
else
    _admin_branch_line="     ・ブランチは、そのままです（途中までの実行のため）"
    _admin_stale_line=""
fi

# 完了画面（できたこと / 次にやること / 管理者用のフォルダ）
_org_count=$(( ${BRANCH_COUNT:-1} ))
_admin_dir="${REPO_DIR:-${INIT_DIR}/force-${COMPANY_NAME}}"
# 動作の確認の結果の行。$( ) の中に case を書かない（Bash 3.2 は、case の「)」を、$( ) の終わりと取り違える）
case "$VERIFY_RESULT" in
    done)    _verify_line="4. 動作の確認: 成功しました（リリースと削除を、各段階の組織で確認済みです）" ;;
    failed)  _verify_line="4. 動作の確認: 失敗した項目があります。上の [NG] を確認してください（削除のみのやり直し: sf-init.sh --verify --cleanup）" ;;
    skipped) _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-init.sh --verify（または、sf-init.sh を再実行して、2 を選ぶ）" ;;
    *)       _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-init.sh --verify" ;;
esac
wizard_done "できました: ${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}" \
    "GitHub リポジトリ / Token / Slack 通知 / Salesforce の接続（${_org_count} 組織）" \
    -- \
    "1. 開発を始める人は、次のフォルダで、次のコマンドを実行してください" \
    "     cd \"${INIT_BASE}\"" \
    "     sf-job.sh" \
    "2. リポジトリを見る:" \
    "     https://github.com/${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}" \
    "3. 【管理者用フォルダ】は、残してあります（削除しないでください）:" \
    "     ${_admin_dir}" \
    "     ・ワークフローの更新・接続の確認・接続先の付け替えなど、管理者のメンテナンスに使います" \
    "$_admin_branch_line" \
    "$_admin_stale_line" \
    "     ・日常の開発には使わないでください（開発は、上の sf-job.sh の作業フォルダで行います）" \
    "$_verify_line"

exit $RET_OK
