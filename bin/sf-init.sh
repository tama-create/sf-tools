#!/bin/bash
# ==============================================================================
# sf-init.sh - 新規 Salesforce プロジェクトの初期セットアップ
# ==============================================================================
# 新しい force-XXXX リポジトリを GitHub に作成し、sf-tools と連携させるまでの一連のセットアップ（Phase 1〜10 と後処理）を
# 自動化する。セットアップ後の保守用のモード（--add-tier / --reconnect / --status / --verify）も持つ。管理者向けのコマンド。
#
# 【使い方】
#   cd {作業フォルダ}                                  # sf-job.sh を実行する場所（admin・force-* の中は不可）
#   ~/sf-tools/bin/sf-init.sh [--owner OWNER] [--project XXXX] [--legacy-connected-app]
#   ~/sf-tools/bin/sf-init.sh [--owner OWNER] [--project XXXX] --resume N
#   ~/sf-tools/bin/sf-init.sh [--owner OWNER] [--project XXXX] --only N
#
#   cd {作業フォルダ}/admin/force-XXXX                 # 保守用のモードは、force-* の中で実行する
#   ~/sf-tools/bin/sf-init.sh --add-tier staging|develop
#   ~/sf-tools/bin/sf-init.sh --reconnect main|staging|develop
#   ~/sf-tools/bin/sf-init.sh --status
#   ~/sf-tools/bin/sf-init.sh --verify [--plan] [--cleanup] [--no-metasync] [--components] [--validate-only] [--with-objects]
#
# 【オプション】
#   --owner OWNER         : GitHub のオーナー（組織名またはユーザー名）。英数字とハイフンのみ（先頭・末尾は英数字。39 文字まで）。
#                           不正なら終了する（検証は【処理の流れ】2）。省略すると、対話で決める
#   --project XXXX        : プロジェクト名（リポジトリ force-XXXX の XXXX）。先頭の force-（大文字・小文字を問わない）は除いて扱う。
#                           使える文字は、英数字・ハイフン・アンダースコア・ピリオド。区切り（- _ .）は英数字の間に 1 つだけ
#                           （連続・先頭・末尾は不可）。50 文字まで。末尾の .git は不可。不正なら終了する。省略すると、入力を求める
#   --resume N            : Phase N（1〜10 の整数）から Phase 10 までを実行する（続きの質問・完了済みの選択画面は出さない）。
#                           完了済みのプロジェクトでは拒否する（終了コード 1）。N = 1 は、指定なしと同じ扱い。
#                           値なし・1〜10 以外（数字でない、0、11 以上、先頭が 0 など）は、実行の前にエラーで終了する（終了コード 1）
#   --only N              : Phase N（1〜10 の整数。--resume と同じ検査）だけを実行する（デバッグ・単体テスト用）。進捗を記録しない。続きの質問・完了済みの選択画面は
#                           出さない。完了済みのプロジェクトでは拒否する（終了コード 1）。Phase 3 以降は、.sf-init-XXXX.env が必要（【補足】）。
#                           phases/init/NN_*.sh（NN = N の 2 桁）がなければ終了する
#   --legacy-connected-app: 従来の接続アプリケーション（手動の入力。今後廃止予定）を使う。既定は、外部クライアントアプリ（自動で作成）
#   --add-tier staging|develop
#                         : 既存プロジェクトに staging / develop の段階を追加する（phases/init/add_tier.sh）
#   --reconnect <段階>    : 1 つの段階（main / staging / develop）の、接続先の Salesforce 組織を付け替える（phases/init/reconnect.sh）。
#                           値がなければ終了する
#   --status              : セットアップの診断（リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。不足は、
#                           直し方つき）と、段階ごとの接続先（ログイン先・組織の種類・ユーザー・組織 ID）を一覧にする
#                           （読み取りのみ。phases/init/status.sh）
#   --verify              : 動作の確認（実際のリポジトリ・組織に、Hello World を、リリースして、削除する。phases/init/verify.sh）。
#                           環境全体の確認（SF_TOOLS_BRANCH・ログに Token が残っていない・wf-metasync）も、最初に行う
#     --plan              : （--verify と一緒に）診断と、実行内容の表示だけ（何も変更しない）
#     --cleanup           : （--verify と一緒に）削除のみ（検証が途中で止まって、組織に Hello World が残ったときの後始末）
#     --no-metasync       : （--verify と一緒に）環境の確認のうち、wf-metasync の実行を、省略する
#     --components        : （--verify と一緒に）Hello World の代わりに、パターン別のサンプル（種類は phases/init/verify.sh）を、
#                           develop の組織だけに、リリースして、削除する（develop がある 3 層の構成のみ）。既定では、オブジェクト系
#                           （トリガー・Layout・オブジェクト・項目）と Flow は、リリース・削除に含めない（Flow は --validate-only で検証する）
#     --validate-only     : （--verify --components と一緒に）検証（wf-validate = dry-run）だけ。PR は、マージせずに閉じる。組織には、何も反映しない
#     --with-objects      : （--verify --components と一緒に）オブジェクト系も、リリースして、削除する
#                           （削除したオブジェクトの名前は、15 日間、予約される）
#                           ※ --plan〜--with-objects を --verify なしで指定すると終了する（--add-tier と一緒のときは、無視する）
#   -h, --help            : このヘルプを表示して終了する（終了コード 0）
#
# 【処理の流れ】
#   1. 引数の解析と、sf の確認（sf --version の終了コードが 0 以外なら、案内を表示して終了）。
#      --add-tier → --verify → --status → --reconnect の順で、最初に該当した 1 つだけを実行して終了する（ほかのモードの指定は無視）。
#      以下の 2〜8 は、通常の実行（--resume / --only を含む）
#   2. 実行場所の確認と、オーナー・XXXX の決定
#      - カレントのフォルダ名が admin か force-*、または Git の作業ツリーの最上位が force-* なら、拒否して終了する
#      - 決める順: 引数 --owner / --project → 対話
#      - オーナーの候補は、gh のログインから（管理者（admin・active）の組織 → 自分のアカウント。重複なし）。
#        0 件なら入力、1 件なら自動、複数なら番号で選ぶ
#      - XXXX は入力する（そのオーナーの既存の force-* の XXXX を、参考に表示する。「これでよいですか？」で確認）。
#        入力した XXXX が既存のリポジトリ名（大文字・小文字を区別しない）なら、拒否して再入力させる。ただし、admin/force-XXXX が
#        そのリポジトリのクローンか、admin/.sf-init-XXXX.env がそのリポジトリの状態なら、確認の画面を出さずに受け付ける。
#        --project で指定したときは、ここでは既存かどうかを確認しない
#   3. 開始画面と、管理者向けの確認
#      - 管理者向けの警告（赤いボックス）
#      - sf-tools の最新化の確認（【補足】sf-tools の最新化）
#      - 確認: --resume N（2 以上）/ --only N の指定がないときは、用意するものと、9 つのステップを表示して、
#        「用意ができたら Enter を押してください」（Enter / Y で進む。N / q / EOF で終了）。指定があるときは「続行しますか？」（Y/N/q）
#      - gh の認証ユーザーが、オーナーと一致するか、オーナーの組織の有効な管理者（admin・active）でなければ、終了する
#        （gh の認証ユーザーを取得できないときは、確認しない）
#   4. 実行した場所に admin/ を作って移動し、排他のロックを取る（【補足】同時実行）。
#      admin/force-XXXX が、OWNER/force-XXXX 以外を origin とするクローンなら、終了する（大文字・小文字は区別しない）
#   5. 前回の状態の判定（【補足】途中で止まったとき・完了済みのとき）
#   6. 新規の実行（--resume N（2 以上）/ --only の指定なし、かつ「続きをやる」を選んでいない）では、admin/force-XXXX の
#      完了の印を 0（やり直し中）にし、状態ファイル（admin/.sf-init-XXXX.env / admin/.sf-init-XXXX.progress）を消す
#   7. Phase の実行（失敗したら、やり直し方を表示して終了する）
#        Phase 1:  環境チェック（ツール確認・GitHub CLI 認証確認）
#        Phase 2:  プロジェクト情報の確認（OWNER・XXXX の確認、sf-tools の版（配布版 main / 開発版 development）の選択、
#                  .sf-init-XXXX.env の作成）
#        Phase 3:  リポジトリ作成（gh repo create + git clone）
#        Phase 4:  ファイル生成（sf-install.sh。sf-install.sh が sf-hook.sh でフックを設置する）
#        Phase 5:  ブランチ構成（対話選択 → branches.txt 更新）
#        Phase 6:  PAT_TOKEN の設定
#        Phase 7:  Slack 連携の設定
#        Phase 8:  初回コミット＆プッシュ
#        Phase 9:  GitHub リポジトリ設定・Ruleset の適用
#        Phase 10: JWT 認証情報の設定（Salesforce GitHub Secrets 登録）
#      画面には、Phase の番号ではなく、利用者向けの 9 つのステップ（準備の確認 〜 Salesforce の接続・動作の確認）の見出しを出す
#      （--only のときは出さない）
#   8. 後処理（実行範囲の終わりが Phase 10 のとき。--only 10・--resume N を含む。条件は項目ごと）
#      a. .sf-init-XXXX.env があれば、Token の値の行（^[A-Z_]*TOKEN_VALUE=）を消す
#      b. 最初のメタデータの同期（--only なし、開始が Phase 10 以下、.sf-init-XXXX.env に REPO_DIR・REPO_FULL_NAME があるとき）:
#         wf-metasync を起動して完了を待ち（既定 1200 秒。SF_INIT_SYNC_TIMEOUT。時間切れなら、実行を取り消す）、成功したら、
#         管理者用のクローンを main にして git pull --ff-only origin main。失敗しても、セットアップは成功のまま、完了画面で知らせる
#      c. 動作の確認（任意。【補足】動作の確認）
#      d. 管理者用のクローンを admin ブランチにして、GitHub にも push する（REPO_DIR があるとき。【補足】admin フォルダ）
#      e. 完了の印を 1 にし、状態ファイルを消す（--only なしのとき）
#      f. 完了画面（--resume N / --only N のときも表示する）
#
# 【前提条件】
#   - 実行する場所: 通常の実行は、作業フォルダ（sf-job.sh を実行する場所。どこでもよい。おすすめ: ~/sf のような、短い名前のフォルダ）。
#     実行した場所に admin/force-XXXX ができる。保守用のモード（--add-tier / --reconnect / --status / --verify）は、force-* の中
#   - Salesforce CLI（sf）は npm 版（npm install -g @salesforce/cli）であること。起動時に sf --version の終了コードを確認し、
#     0 以外なら案内を表示して終了する（Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。
#     この確認は、--help 以外のすべてのモードで行う
#   - gh の認証ユーザーが、オーナー本人か、オーナーの組織の有効な管理者であること（【処理の流れ】3）
#   - 手動の操作が必要なもの:
#     Salesforce 組織へのブラウザログイン / GitHub Classic PAT トークンの作成（repo + workflow スコープ）/
#     Slack App の作成・Bot Token の取得 / 通知先 Slack チャンネルで Bot を招待（/invite @sf-notify-<プロジェクト名>）
#
# 【補足】
#   ◆ 途中で止まったとき（続きから）
#     - Phase 2 以降が成功するたびに、admin/.sf-init-XXXX.progress を SF_INIT_DONE_PHASE=N・SF_INIT_DONE_AT で上書きする
#       （--only のとき・.sf-init-XXXX.env がないときは、記録しない）
#     - --resume N（2 以上）/ --only の指定なしで起動し、進捗が 2〜9 で、.sf-init-XXXX.env の REPO_FULL_NAME が OWNER/force-XXXX
#       （大文字・小文字は区別しない）なら、次から選ばせる（既定値はない）。選択は、【処理の流れ】3 の警告・確認のあとに出る
#         [1] 続きをやる: Phase 1 を実行してから、次の Phase〜10 を実行する（保存済みの入力内容を使う）。
#             進捗が 8 以上なのに、GitHub の main ブランチを確認できない（gh api の失敗を含む）ときは、終了する
#         [2] 最初からやり直す: 【処理の流れ】6 のとおり（作成済みのリポジトリ・admin フォルダは、そのまま使う）
#         [q] 中断（終了する）
#     - Phase 10 は、段階（main / staging / develop）ごとに、完了を進捗に記録し、再実行では、完了した段階を、スキップする
#       （登録した Secret が、いまもあるときだけ。--only 10 では、記録も、スキップも、しない）
#   ◆ 完了済みのとき
#     - 判定: 状態ファイルが 2 つともあるときは、進捗が 10 で、REPO_FULL_NAME が OWNER/force-XXXX であること（完了の直前で止まった状態）。
#       そろっていないときは、admin/force-XXXX の origin が OWNER/force-XXXX で、完了の印（git config sf-tools.setup-complete）が 1 であること。
#       印が未設定なら、ローカルに admin ブランチがあれば完了済みとみなし、印を 1 にする。印が 0 は、やり直し中（未完了）
#     - --resume N（2 以上）/ --only の指定なしで起動したとき（続きの対象でないとき）は、次から選ばせる。状態ファイルが残っている
#       ときは、先に GitHub の main ブランチを確認し（確認できなければ終了）、後片付け（admin ブランチ・push・完了の印・
#       状態ファイルの削除）を済ませる
#         [1] いまの Salesforce の接続を見る（status.sh。何も変更しない。終了コード 0）
#         [2] 動作を確認する（verify.sh。確認は verify.sh が聞く。終了コードは verify.sh のもの）
#         [3] 最初からやり直す（【処理の流れ】6。作成済みのリポジトリは、そのまま使い、設定を、上書きする）
#         [q] 終了（終了コード 0）
#     - --resume N（2 以上）と --only N は、拒否する（終了コード 1）
#   ◆ --only N と状態ファイル
#     - Phase 3〜10 のスクリプトは、Phase 2 が作る .sf-init-XXXX.env の値（REPO_FULL_NAME など）がないと終了する。
#       状態ファイルは完了時に消えるため、完了後に --only N（3 以上）だけを実行すると、「〜が未設定です」で終了する
#   ◆ 同時実行
#     - 同じ admin・同じ XXXX で、sf-init.sh を、同時に 2 つ動かすことはできない（後から起動した方は「すでに実行中です」で終了する）。
#       admin/.sf-init-XXXX.lock（フォルダ。中に PID）で排他する。PID のプロセスがもういないときは、古いロックとして引き継ぐ。
#       ロックを取るのは【処理の流れ】4（警告・確認のあと）。保守用のモードは、ロックを取らない
#   ◆ 動作の確認（【処理の流れ】8c）
#     - 聞く条件: 実行範囲の終わりが Phase 10、--resume N（2 以上）/ --only の指定なし（中断後の「続きをやる」を含む）、
#       GITHUB_ACTIONS が true でない、標準入力が端末（または SF_INIT_VERIFY_ASK=1）
#     - 「動作を確認しますか？ [Enter = 確認する / s = あとで]」。Enter / Y で確認する。s / n / q と EOF は、あとで。ほかは再入力
#     - 確認するときは、管理者用のクローン（REPO_DIR）で、verify.sh（環境全体の確認 → Hello World のリリースと削除）を、
#       SF_VERIFY_CONFIRMED=1 で実行する（verify.sh の確認は出ない）。失敗しても、セットアップの失敗にはしない（完了画面に結果を出す）
#   ◆ admin フォルダ（管理者用フォルダ）
#     - 完了後も削除しない（削除の質問は廃止した）。ワークフローの更新（sf-sync-wf.sh）・--status・--reconnect などの保守に使う。
#       日常の開発には使わない（開発は、sf-job.sh の作業フォルダで行う）。完了画面に、このフォルダのパスを表示する
#     - 同じ admin に、複数のプロジェクトを置ける（状態ファイル・ロックは、XXXX ごとに分かれる）
#     - admin ブランチ: ローカルに admin があれば切り替え、なければ main から作る。動作の確認を実行し、クローンが main のときは、
#       先に git pull --ff-only origin main を行う。そのあと git push --no-verify -u origin admin（強制 push はしない）。
#       失敗しても、セットアップは成功のまま、完了画面で知らせる。admin は main から古くなる（使う前に、main を取り込む）
#     - 完了の印は、クローンの .git/config にあり、GitHub には送られない
#   ◆ sf-tools の最新化
#     - 【処理の流れ】3 で、~/sf-tools の現在のブランチが origin より遅れていないかを確認する。Git リポジトリでない・HEAD が
#       ブランチでない・fetch できない・origin にブランチがないときは、警告して続行する。未コミットの変更か未 push のコミットが
#       あれば、更新せずに続行する。遅れていれば、確認（Y/N/q）のうえ git pull --ff-only し、同じ引数で自動的に実行しなおす
#       （N なら更新せずに続行。q・更新の失敗は終了）。実行しなおしたあとは、この確認をしない
#     - Phase 2 は、選んだ版のブランチと、現在のブランチが違えば、確認する（N / q で終了）。実行しなおしたあとは、Phase 2 が、
#       選んだ版で最新化を確認する。Phase 2 が更新したとき（終了コード 75）は、まだ実行しなおしていなければ実行しなおし、
#       実行しなおしたあとなら「sf-tools を更新しても、最新になりませんでした。」で終了する
#   ◆ 引数の解析
#     - --only / --resume は、Phase 番号（1〜10 の整数。先頭の 0 は不可）だけを受け付ける。値なし・数字以外・範囲外は、
#       エラーで終了する（終了コード 1）。--add-tier は、次の引数（- で始まらないもの）を値として受け取り、値なしは
#       エラーで終了する（staging / develop かどうかは、add_tier.sh が確認する）
#     - 知らないオプションは、使い方を表示して終了する
#   ◆ そのほか
#     - Ctrl+C は、--help の判定のあと、引数の解析の前から無効（trap '' INT。子プロセスにも継承）。中断するには、ターミナルを閉じる
#     - ログ: ~/sf-tools/logs/sf-init.log（起動のたびに空にする。各 Phase は追記する）
#     - 終了コード: 0 = 成功（完了済みの選択画面の [1] / [q] を含む）/ 1 = エラー（die）/
#       --verify・--status・完了済みの [2] は、verify.sh・status.sh の終了コードを、そのまま返す
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
source "${SCRIPT_DIR}/../lib/verify-common.sh"           # 最初のメタデータの同期（initial_metadata_sync）が使う、ワークフローの起動・待ち

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

# --only / --resume の値の検査（Phase 番号 1〜10 の整数だけ）。値なしだと shift 2 が失敗して引数の解析が終わらず（Ctrl+C は無効）、
# 数字以外・範囲外だと存在しない Phase を「成功」として実行してしまうため、解析の時点で拒否する。
_require_phase_number() {
    local opt="$1" val="${2-}"
    [[ "$val" =~ ^([1-9]|10)$ ]] || die "${opt} には、Phase 番号（1〜10 の整数）を指定してください: ${val:-（指定なし）}"
}

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
            _require_phase_number "--only" "${2-}"
            ONLY_PHASE="$2"
            shift 2
            ;;
        --resume)
            _require_phase_number "--resume" "${2-}"
            RESUME_PHASE="$2"
            shift 2
            ;;
        --add-tier)
            [[ -n "${2:-}" && "${2}" != -* ]] || die "--add-tier には、追加する段階（staging または develop）を指定してください。"
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
# --resume / --only / --add-tier / --verify / --status / --reconnect のときも確認する（--help 以外の、すべての実行で確認する）
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

# 実行場所の確認: 管理者用フォルダ（admin）・クローン（force-*）の中で実行すると、その中に admin/ ができて、
#   別のクローンに書き込む経路になる。作業フォルダ（sf-job.sh を実行する場所）で実行すること
_cwd_top=$(git rev-parse --show-toplevel 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用（Git の作業ツリーの外なら、空）
if [[ "$(basename "$PWD")" == "admin" || "$(basename "$PWD")" == force-* || "$(basename "${_cwd_top:-.}")" == force-* ]]; then
    die "sf-init.sh は、管理者用フォルダ（admin）・クローン（force-*）の中では実行できません: ${PWD}"
fi

resolve_init_identity  # GITHUB_OWNER / COMPANY_NAME（XXXX）をセット（引数 → 対話）

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
# 5. 管理者用の作業フォルダ（admin）の作成・移動
# ------------------------------------------------------------------------------
INIT_BASE="$PWD"   # 作業フォルダ（sf-job.sh を実行する場所）
INIT_DIR="${PWD}/admin"
_state_suffix="-${COMPANY_NAME}"           # 途中経過のファイルは、プロジェクトごとに分ける（同じ admin に複数のプロジェクトを置くため）
run mkdir -p "$INIT_DIR" || die "管理者用フォルダの作成に失敗しました: ${INIT_DIR}"
cd "$INIT_DIR" || die "管理者用フォルダに移動できません: ${INIT_DIR}"

# 管理者用フォルダ（admin）には、XXXX だけの名前で、クローン（force-XXXX）を置く。同じ XXXX で、別のオーナーのクローンがあるときは、
#   中断する（このあとの Phase が、別のリポジトリのクローンに、コミット・push してしまうため。状態ファイルも、消さない）。
#   大文字と小文字は、区別しない
if [[ -d "${PWD}/force-${COMPANY_NAME}/.git" ]] \
   && ! clone_matches_repo "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then
    die "管理者用フォルダ（${PWD}）の force-${COMPANY_NAME} は、${GITHUB_OWNER}/force-${COMPANY_NAME} のクローンではありません（origin: $(git_origin_redacted "${PWD}/force-${COMPANY_NAME}")）。"
fi

# ------------------------------------------------------------------------------
# 6. 環境変数の export（各フェーズスクリプトから参照）
# ------------------------------------------------------------------------------
export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# .sf-init-XXXX.env は管理者用の作業フォルダに配置する（cd 後の PWD が admin/ になる）
export SF_INIT_ENV_FILE="${PWD}/.sf-init${_state_suffix}.env"

# 進捗ファイル（成功した Phase を記録する。.sf-init-XXXX.env とは別にする: 書き換えるときに、外部コマンドを使わないため）
export SF_INIT_PROGRESS_FILE="${PWD}/.sf-init${_state_suffix}.progress"

# 同じプロジェクト（同じ admin フォルダ・同じ XXXX）の sf-init を、同時に 2 つ動かさない（状態ファイルの取り合い・重複作成を防ぐ）。
#   ロックは、フォルダ（mkdir は、原子的）。中に、実行中の PID を書く。PID のプロセスが、もういなければ、古いロックとして引き継ぐ
#   （強制終了・SIGTERM では、ロックが残るため）。終了時に、削除する（EXIT トラップ）
_init_lock_dir="${PWD}/.sf-init${_state_suffix}.lock"
if ! mkdir "$_init_lock_dir" 2>/dev/null; then  # 条件チェックのため run 不使用（ロックの取得は、mkdir の成否で決まる）
    _init_lock_pid=$(cat "$_init_lock_dir/pid" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$_init_lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$_init_lock_pid" 2>/dev/null; then  # 存在確認のため run 不使用
        die "同じプロジェクト（${COMPANY_NAME}）の sf-init が、すでに実行中です（PID ${_init_lock_pid}。${_init_lock_dir}）。"
    fi
    log "WARNING" "前回の sf-init の、古いロックを引き継ぎます（実行中のプロセスは、ありません）: ${_init_lock_dir}"
    rm -rf "$_init_lock_dir"  # 古いロックの削除（実行中のプロセスがいないことを確認済み）
    mkdir "$_init_lock_dir" 2>/dev/null || die "ロックを取得できません（別の sf-init が、同時に、起動した可能性があります）: ${_init_lock_dir}"
fi
echo "$$" > "$_init_lock_dir/pid"
trap 'rm -rf "$_init_lock_dir"' EXIT
# Phase 10 の、段階ごとの再開（完了した段階を、進捗に記録し、再実行ではスキップする）。--only のときは、使わない
[[ -z "$ONLY_PHASE" ]] && export SF_INIT_TIER_RESUME=1

# ファイル（KEY=値 の行）から、値を 1 つ取り出す（source しない）。引数: キー ファイル。なければ空
_kv_value() {
    grep "^${1}=" "$2" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/\r$//; s/^"//; s/"$//'  # 取得専用のため run 不使用
}

# 完了済みのプロジェクトか（戻り値 0 = 完了済み）。完了時に、状態ファイルは消す（完了後は、読む場所がないため）ので、
#   ・状態ファイルがある: 進捗が Phase 10 で、リポジトリが一致すること（以前の版が残した、完了済みの状態）
#   ・状態ファイルがない: このフォルダ（admin）の、同じリポジトリのクローン（force-XXXX）が、セットアップ済みであること
#     （clone_setup_completed: クローンの git config sf-tools.setup-complete が 1。未設定のときは、admin ブランチがあれば、
#     印を導入する前の版で完了したものとみなす。0 は、やり直し中）。やり直しの開始時に、印を 0 にする
#   進捗が 2〜9（途中まで）のときは、完了済みではない（続きをやる、の対象）。結果: COMPLETED_REPO / COMPLETED_DIR / COMPLETED_AT
COMPLETED_REPO=""; COMPLETED_DIR=""; COMPLETED_AT=""
_project_completed() {
    local want="${GITHUB_OWNER}/force-${COMPANY_NAME}" _done _repo
    COMPLETED_REPO=""; COMPLETED_DIR=""; COMPLETED_AT=""
    if [[ -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
        _done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
        _repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
        [[ "$_done" == "10" ]] && state_matches_repo "$SF_INIT_ENV_FILE" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 1   # リポジトリ名は、大文字と小文字を区別しない
        COMPLETED_REPO="$_repo"
        COMPLETED_DIR=$(_kv_value REPO_DIR "$SF_INIT_ENV_FILE")          # VAR=$(cmd) のため run 不使用
        COMPLETED_AT=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")  # VAR=$(cmd) のため run 不使用
        return 0
    fi
    clone_setup_completed "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 1
    COMPLETED_REPO="$want"
    COMPLETED_DIR="${PWD}/force-${COMPANY_NAME}"
    return 0
}

# 前回、完了の直前で中断したときの後片付け（進捗は 10 まで進んだが、admin ブランチの作成・完了の印・状態ファイルの削除が、
#   済んでいない）。何度実行しても、同じ結果になる。引数: クローンのフォルダ
#   クローンがあれば、admin ブランチにして GitHub にも push し、完了の印を付けてから、状態ファイルを削除する
_finish_unfinished_setup() {
    local dir="$1"
    [[ -d "$dir/.git" ]] || return 0   # クローンがないときは、何もしない（状態ファイルも、そのまま）
    # 状態ファイルの REPO_DIR が指すクローンが、このプロジェクトのものであること（別の場所の、別のクローンに、push しないため）
    clone_matches_repo "$dir" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 0
    log "INFO" "前回のセットアップの、最後の後片付け（admin ブランチ・完了の印・状態ファイルの整理）が、済んでいません。いま、済ませます。"
    if ensure_admin_branch "$dir"; then
        push_admin_branch "$dir" || log "WARNING" "admin ブランチを GitHub に push できませんでした: ${dir}"
    else
        log "WARNING" "管理者用のクローンを admin ブランチにできませんでした: ${dir}"
    fi
    if mark_setup_complete "$dir"; then
        run rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE" \
            || log "WARNING" "状態ファイルを削除できませんでした: ${SF_INIT_ENV_FILE}"
    else
        log "WARNING" "完了の印を付けられなかったため、状態ファイルは、残します: ${dir}"
    fi
    return 0
}

# origin に main ブランチがあることを確認する。なければ die（事実のみ）。引数: リポジトリ（OWNER/REPO） 理由の文（先頭に付ける）
#   gh で確認できないとき（通信の失敗など）も、確認できないため、die する
_require_origin_main() {
    local repo="$1" why="$2"
    gh api "repos/${repo}/branches/main" >/dev/null 2>&1 \
        || die "${why}が、${repo} の main ブランチを確認できません（状態ファイルと、実際の GitHub が、食い違っている可能性があります）。"   # 条件チェックのため run 不使用
}

# 前回の続きの確認（引数なしで起動したときだけ）
#   前回、途中まで進んでいて（SF_INIT_DONE_PHASE が 2〜9）、そのリポジトリが、この作業フォルダのものなら、
#   「続きをやる / 最初からやり直す」を選ばせる。続きを選ぶと、Phase 1（環境チェック）を実行したうえで、次の Phase から始める
#   表示は、Phase の番号ではなく、利用者向けの名前（WIZ_PHASE_TITLES）で出す
RESUMED=0
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]]; then
    prev_done=""; prev_at=""; prev_repo=""
    if [[ -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
        prev_done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
        prev_at=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")        # VAR=$(cmd) のため run 不使用
        prev_repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
    fi
    if [[ "$prev_done" =~ ^[0-9]+$ && "$prev_done" -ge 2 && "$prev_done" -lt 10 \
          ]] && state_matches_repo "$SF_INIT_ENV_FILE" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then
        next_phase=$((prev_done + 1))
        echo "" >&2
        log "INFO" "前回のセットアップは、「${WIZ_PHASE_TITLES[$prev_done]}」まで完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] 「${WIZ_PHASE_TITLES[$next_phase]}」から、続きをやる   ← おすすめ" >&2
        echo "    [2] 最初からやり直す（作成済みのリポジトリ・admin フォルダは、そのまま使います）" >&2
        echo "    [q] 中断" >&2
        echo "" >&2
        read_key resume_choice "  ▶ 番号を入力してください [1-2/q]: " "[12Qq]"
        # shellcheck disable=SC2154  # resume_choice は、read_key（lib/input.sh）が、名前で受け取って代入する
        case "$resume_choice" in
            1) # Phase 8（初回コミットの push）まで完了と記録されているのに、origin に main がないときは、続けない
               #   （状態ファイルと、実際の GitHub が、食い違っている。続けると、main のないまま、完了と表示してしまう）
               if [[ "$prev_done" -ge 8 ]]; then
                   _require_origin_main "$prev_repo" "「${WIZ_PHASE_TITLES[$prev_done]}」まで完了と記録されています"
               fi
               RESUMED=1
               START_PHASE=$next_phase
               END_PHASE=10
               ;;
            2) ;;  # 最初から（下で .sf-init-XXXX.env を削除する）
            *) die "中断しました。" ;;
        esac
    elif _project_completed; then
        # 状態ファイルが残っているとき（完了の直前の中断）は、origin に main があること（なければ、完了にしない）
        if [[ -f "$SF_INIT_ENV_FILE" || -f "$SF_INIT_PROGRESS_FILE" ]]; then
            _require_origin_main "$COMPLETED_REPO" "セットアップは完了と記録されています"
        fi
        # 完了済みのプロジェクト: 「続きをやる」は意味がないため、完了済みであることと、できることを案内する
        prev_dir="$COMPLETED_DIR"; prev_repo="$COMPLETED_REPO"; prev_at="$COMPLETED_AT"
        # 状態ファイルが残っている（以前の版・完了の直前の中断）ときは、後片付けを済ませる
        if [[ -f "$SF_INIT_ENV_FILE" || -f "$SF_INIT_PROGRESS_FILE" ]]; then
            _finish_unfinished_setup "$prev_dir"
        fi
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
            3) ;;  # 最初から（下で .sf-init-XXXX.env を削除する）
            *) exit $RET_OK ;;
        esac
    fi
fi

# 完了済みのプロジェクトで、--resume N（2 以上）または --only N を明示した場合は、拒否する（接続処理などを、確認なしで、
#   やり直さないため。--only も、同じ Phase を、確認なしで実行できてしまう。以前は、--only は拒否しなかった）。
#   やり直したいときは、引数なしで実行して選ぶ（[1] 接続を見る / [2] 動作を確認 / [3] 最初から）か、--reconnect を使う
if [[ ( "$RESUME_PHASE" -gt 1 || -n "$ONLY_PHASE" ) ]] && _project_completed; then
    log "ERROR" "  このプロジェクト（${COMPLETED_REPO}）は、セットアップが、すでに完了しています。"
    log "WARNING" "  接続先を付け替える        : force-* の中で sf-init.sh --reconnect <main|staging|develop>"
    log "WARNING" "  いまの状態を見る・動作を確認する・最初からやり直す : 引数なしで sf-init.sh を実行して、選んでください"
    die "完了済みのプロジェクトでは、--resume / --only は使えません。"
fi

# 新規実行時（--resume / --only 時、前回の続きを選んだ時以外）は、前回の残骸を削除する（空ファイルは作らない）
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && "$RESUMED" -eq 0 ]]; then
    # 前回の「最初から、やり直す」が、途中で止まったままか（印が 0）を、利用者に知らせる（完了済みの案内も、続きの選択も、出ないため）
    if [[ ! -f "$SF_INIT_ENV_FILE" && ! -f "$SF_INIT_PROGRESS_FILE" \
          && "$(git -C "${PWD}/force-${COMPANY_NAME}" config --get sf-tools.setup-complete 2>/dev/null || true)" == "0" ]] \
       && clone_matches_repo "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then  # 条件チェックのため run 不使用
        log "INFO" "前回の「最初から、やり直す」が、途中で止まっています。最初から、やり直します（作成済みのリポジトリ・クローンは、そのまま使います）。"
    fi
    # 完了の印を 0（やり直し中）にする（やり直しの途中で止まったとき、クローンがあるだけで、完了済みと判定しないため）
    clear_setup_mark "${PWD}/force-${COMPANY_NAME}"
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
# .sf-init-XXXX.env から REPO_DIR などを取得（完了画面の管理者用フォルダの案内に使用）
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# admin フォルダは、削除せずに残す（管理者用のフォルダ。更新・接続の確認・やり直しなどのメンテナンスに使う）
#   以前は、最後に削除する質問を出していたが、廃止した。残るファイルに、秘密情報（Token の値）が含まれないように、
#   念のため、Token の値の行を .sf-init-XXXX.env から消す（通常は、Phase 8 の push 後に、消えている）。
#   最後（Phase 10）まで実行したときだけ行う（--only 6 などの途中までの実行では、Phase 8 が、あとで使うため、消さない）
if [[ "$END_PHASE" -eq 10 && -f "$SF_INIT_ENV_FILE" ]]; then
    run sed_inplace '/^[A-Z_]*TOKEN_VALUE=/d' "$SF_INIT_ENV_FILE"
fi

# 最初のメタデータの同期: セットアップが終わった瞬間に、Salesforce のメタデータが、リポジトリ（main）と、管理者用のクローンに、
#   全部入っているようにする（初期コミットの force-app は、空のひな型。何もしないと、次の定期実行（平日 3 時間おき）まで入らない）。
#   Phase 10（接続情報の登録）のあとでないと動かないため、クローンの作成（Phase 3）のあと。wf-metasync を実行し、
#   終わったら、クローンに git pull する。失敗しても、セットアップは成功のまま、完了画面で知らせる。
#   Phase 10 を実行した、最後までの実行のときだけ（--only N では行わない）
SYNC_RESULT=""   # "" = 行わなかった / done = 同期して、クローンに取り込んだ / failed = できなかった
if [[ "$END_PHASE" -eq 10 && -z "$ONLY_PHASE" && "$START_PHASE" -le 10 && -n "${REPO_DIR:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
    log "HEADER" "最初のメタデータの同期（Salesforce → GitHub → この管理者用のクローン）"
    if initial_metadata_sync "$REPO_FULL_NAME" "$REPO_DIR"; then
        SYNC_RESULT="done"
    else
        SYNC_RESULT="failed"
    fi
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
#   実行範囲の終わりが Phase 10 のときだけ（--only 10・--resume N を含む）。動作の確認（verify.sh）のあとに行う。
#   どちらに失敗しても、セットアップは成功のまま、完了画面で知らせる
_admin_branch_line="     ・ブランチは admin です（このコンピューターと GitHub の両方にあります）"
_admin_stale_line="     ・admin は、main から古くなります。使う前に、main を取り込んでください（git pull origin main）"
if [[ "$END_PHASE" -eq 10 && -n "${REPO_DIR:-}" ]]; then
    # 動作の確認（verify.sh）で、Hello World のリリースと削除が main に入っているときは、最新の main を取り込んでから、admin を作る
    if [[ "$VERIFY_RESULT" == "done" || "$VERIFY_RESULT" == "failed" ]] \
       && [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || true)" == "main" ]]; then  # 条件チェックのため run 不使用
        run git -C "$REPO_DIR" pull --ff-only origin main \
            || log "WARNING" "動作の確認のあとの main を、取り込めませんでした: ${REPO_DIR}"
    fi
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

# 状態ファイル（.sf-init-XXXX.env / .progress）は、セットアップが最後まで終わったら、消す。
#   完了後は、読む場所がないため（完了済みかどうかは、このフォルダのクローンで判定する: _project_completed）。
#   途中で止まったときは、続きをやるために残る。--only N の実行は、状態を持ち越すため、消さない
if [[ "$END_PHASE" -eq 10 && -z "$ONLY_PHASE" ]]; then
    mark_setup_complete "${REPO_DIR:-}" \
        || log "WARNING" "完了の印を付けられませんでした（クローンがありません）: ${REPO_DIR:-なし}"
    run rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE" \
        || log "WARNING" "状態ファイルを削除できませんでした: ${SF_INIT_ENV_FILE}"
fi

# 完了画面（できたこと / 次にやること / 管理者用のフォルダ）
_org_count=$(( ${BRANCH_COUNT:-1} ))
_admin_dir="${REPO_DIR:-${INIT_DIR}/force-${COMPANY_NAME}}"
# 動作の確認の結果の行。$( ) の中に case を書かない（Bash 3.2 は、case の「)」を、$( ) の終わりと取り違える）
case "$VERIFY_RESULT" in
    done)    _verify_line="4. 動作の確認: 成功しました（リリースと削除を、各段階の組織で確認済みです）" ;;
    failed)  _verify_line="4. 動作の確認: 失敗した項目があります。上の [NG] を確認してください（削除のみのやり直し: sf-init.sh --verify --cleanup）" ;;
    skipped) _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-init.sh --verify（または、作業フォルダ（${INIT_BASE}）で、同じオーナー・プロジェクト名で sf-init.sh を再実行して、2 を選ぶ）" ;;
    *)       _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-init.sh --verify" ;;
esac
# 最初のメタデータの同期の結果の行
case "$SYNC_RESULT" in
    done)   _sync_line="5. Salesforce のメタデータは、同期済みです（リポジトリにも、この管理者用のクローンにも、入っています）。以後は、平日 3 時間おきに、自動で同期されます" ;;
    failed) _sync_line="5. Salesforce のメタデータの同期は、できませんでした（セットアップは、完了しています）。次の定期実行（平日 3 時間おき）で入ります。すぐ同期するには: gh workflow run wf-metasync.yml -R ${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}（終わったら、管理者用フォルダで git pull origin main）" ;;
    *)      _sync_line="5. （途中までの実行のため、メタデータの同期は、行っていません。定期実行は、平日 3 時間おきです）" ;;
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
    "$_verify_line" \
    "$_sync_line"

exit $RET_OK
