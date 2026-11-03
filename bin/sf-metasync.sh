#!/bin/bash
# ==============================================================================
# sf-metasync.sh - Salesforce メタデータ Git 自動同期スクリプト
# ==============================================================================
# main の組織（sf-init で 1 番目に登録した組織。本番・Sandbox・Developer Edition のどれでもよい）から、メタデータを取得し、
# main ブランチの「同期の対象のフォルダ」（【補足】）を、取得した内容と同じにして（追加・変更・削除）、コミットして push する。
# push したときは、branches.txt の main 以外のブランチへ、main をマージして push する。
# Salesforce 組織の内容を正とする。どのブランチから実行しても、main に切り替えて処理し、終了時に元のブランチへ戻る。
# 設計: doc/sf-metasync-redesign.md
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-metasync.sh [オプション]     # force-* ディレクトリで実行する（管理者向け）
#
# 【オプション】
#   -n, --dry-run         : 手順 9 の計画の表示までで終了する（作業ツリーの変更・コミット・push・伝播は行わない）。
#                           組織からの取得は行う（読み取りのみ）。終了コードは 0
#   -y, --yes             : --dry-run のときだけ、手順 3 の続行の確認を省く（--dry-run なしで指定すると、中断する）
#       --allow-mass-delete : 手順 8 の削除の保留のうち、S3（消えたフォルダ）・S4（削除が多い）を解く。手元で実行したときだけ
#                           （GitHub Actions 上で指定すると、中断する）。手順 9 の確認は、省かない
#       --full            : 手順 5 の変更の検知で「変更なし」でも、取得を省かず、全件取得する（検知は、状態の更新のために行う）。
#                           毎日 1 回の全件取得（wf-metasync.yml）と、手動の実行で使う
#   -j, --json            : 手順 6 の取得の応答（JSON）の先頭を、ログにも記録する
#   -v, --verbose         : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help            : このヘルプを表示して終了する
#   ※ 上記以外のオプション・引数を指定すると、中断する（終了コード 1）
#
# 【処理の流れ】
#   1. sf の確認: sf --version の終了コードが 0 以外なら、案内を表示して中断する（check_sf_cli --cache）。
#      引数の解析（【オプション】）は、この確認のあとに行う
#   2. 事前の確認（上から順に確かめ、満たされなければ、何も変更せずに中断する）
#      - 接続先の組織（main の組織）を決める。手元と GitHub Actions 上で、決め方が違う:
#          手元: エイリアスの名前には頼らず、組織 ID で決める。git remote get-url origin から owner/repo を特定し、
#                gh variable get SF_ORG_ID_PROD（sf-init が記録した、1 番目の組織の ID）を読み、sf org list --json の
#                ログイン済みの組織から、ID（上位 15 文字）が一致するものを探して、そのユーザー名を接続先にする。
#                次のどれかなら、何も変更せずに中断する（推測して別の組織に進まない。prod エイリアスには、フォールバックしない）:
#                origin から特定できない／ SF_ORG_ID_PROD を読み取れない／ 一致する組織が、この PC の sf にない
#          GitHub Actions 上: ワークフローが JWT で作る prod エイリアスを使う（gh は見ない）
#      - sf org display --target-org <接続先> --json の終了コードが 0 であること。
#        出力は、表示もログへの記録もしない（アクセストークンを含むため）
#      - 現在の HEAD がブランチを指していること（git symbolic-ref -q HEAD の終了コードが 0。detached HEAD では中断する）
#      - ./sf-tools/config/metadata.txt が存在すること（コメント行・空行を除いた各行を、取得するメタデータの種類とする。
#        行末の CR は除く）
#   3. 管理者向けの警告を表示し、続行の確認（Y/N）を取る。N・q なら中断する（GitHub Actions 上では、表示・確認しない）
#   4. main ブランチへ切り替える（実行時のブランチが main 以外のとき）→ リモートの最新を取り込む
#      - 追跡中のファイルに未コミットの変更があれば、git stash で退避してから git checkout main する
#      - main で、追跡中のファイルに未コミットの変更があれば、中断する（ローカルの変更は、同期に含めない）
#      - 手元で実行したときは、追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）があっても、中断する（【補足】）
#      - git fetch origin（失敗しても WARNING を表示して続行）→ git pull origin main --rebase
#        （失敗したら git rebase --abort して中断する）
#   5. 一時プロジェクトの準備: sfdx-project.json の packageDirectories が 1 つでなければ、中断する（S8）。
#      一時フォルダ（${TMPDIR:-/tmp}/sf-metasync-XXXXXX）に、sfdx-project.json と .forceignore（あれば）を写す。
#      作業ツリーには、まだ何も書かない。
#      続けて、環境変数 SF_METASYNC_DETECT が shadow または on のとき、変更の検知を行う（node lib/metasync.js detect。読み取りのみ。
#      設定変更の履歴と、更新日時の一覧で、組織に変更があるかを、全件取得の前に調べる）。on で、結果が「変更なし」のとき
#      （--full・--dry-run でなく、未プッシュのコミットがないとき）は、手順 6 以降を行わず、終了する（コミット・push・伝播はしない）。
#      検知の失敗・不明・変更ありは、すべて、手順 6 の全件取得に進む（検知は、取得を省くための手がかりで、失敗が取りこぼしにならない）
#   6. 組織からメタデータを取得する: 一時フォルダで sf project retrieve start --target-org prod --ignore-conflicts --json に、
#      metadata.txt の全種類を --metadata で指定して実行する。取得先は一時フォルダのため、失敗しても作業ツリーは変わらない。
#      終了コードが 0 以外で、応答が一時的なエラー（MetadataTransferError・ERROR_HTTP_404・接続の切断・503 など）なら、60 秒待って
#      1 回だけやり直す（環境変数 SF_METASYNC_RETRY_WAIT で秒数を変えられる）。それでも失敗したら、中断する
#   7. 直近にマージされたファイルの一覧を作る（S5 用）: 直近 24 時間に、同期以外のコミットで変わった、同期の対象のパス
#      （git log --first-parent -m --since="24 hours ago" --invert-grep --grep=<同期のコミットの件名> --name-only）
#   8. 計画を作る（node lib/metasync.js plan）: 同期の対象のフォルダごとに、手元と取得結果を比べる。追加・変更・削除と、
#      削除の守りで保留にした分（ファイルは残す）を決める。保留の条件（lib/metasync.js の冒頭に詳細）:
#        S2 取得の応答に、問題の報告がある ／ S3 手元に 1 件以上あったフォルダが、取得結果で 0 件 ／
#        S4 削除の件数が max(100, 手元の同期の対象のファイルの 10%) を超える ／ S5 手順 7 の一覧にあるファイル
#      取得の応答の status が 0 以外（S1）のときは、中断する
#   9. 計画の要約（件数・削除の一覧の先頭 30 件・保留とその理由）を表示する。手元で、変更があるときは、続行の確認
#      （Y/N。N・q なら中断する）を取る（GitHub Actions 上では、表示のみ）。--dry-run は、ここで終了する
#   10. 計画を作業ツリーに反映する（node lib/metasync.js apply。保留の削除は、行わない）
#   11. （手順 5 の検知が、変更あり・不明のとき）検知の状態を ./sf-tools/metasync/state.json に書く。
#      git add -A -- <パッケージのフォルダ>（と、書いたときは状態ファイル。sf-tools/release/ は含めない）でステージし、HEAD との差分で分岐する
#      - 差分あり: 「定期更新: Salesforce変更の自動反映 (YYYY-MM-DD)」でコミットし（本文に件数）、git push --no-verify origin main する
#      - 差分なし・origin/main より先のコミットあり（前回の同期の push の失敗など）: そのコミットの一覧（git log --oneline）を
#        表示して確認を取り、git push --no-verify origin main だけ行う（GitHub Actions 上では、確認しない）
#      - 差分なし・先のコミットなし: 「完了: Salesforce 組織側に変更はありませんでした。」と表示して終了する（手順 12 は行わない）
#      コミット・push の失敗は、中断する
#   12. （手順 11 で push したときのみ。ただし、状態ファイルの更新だけのコミットのときは、伝播しない）
#      branches.txt の main 以外の各ブランチへ、main を伝播する
#      - リモートに無いブランチは、WARNING を表示してスキップする
#      - git checkout <ブランチ> → git pull origin <ブランチ> --rebase → git merge main --no-edit →
#        git push --no-verify origin <ブランチ>。失敗したら、WARNING を表示して、そのブランチをスキップする
#        （pull の失敗: git rebase --abort → git checkout main。merge の失敗: git merge --abort → git checkout main。
#         push の失敗: git checkout main。checkout の失敗: そのままスキップ）
#      - 最後に git checkout main する（失敗したら中断する）
#   13. 終了時（手順 2 の HEAD の確認より後に、中断したときも）: 手順 10 のあと、コミットの前に中断したときは、
#       同期の対象のパッケージのフォルダを HEAD に戻す（git reset -q HEAD -- ・git checkout HEAD -- ・git clean -fdq --）。
#       元のブランチへ git checkout し、手順 4 で退避していれば git stash pop する。一時フォルダを削除する
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する（終了コード 1）
#   - 手元で実行するとき: main の組織（sf-init で 1 番目に登録した組織）が、この PC の sf にログイン済みであること
#     （エイリアスの名前は、何でもよい。sf-init は、この PC の sf にエイリアスを残さない。sf org login web --alias <名前> などでログインする）。
#     gh が使え、リポジトリの Variable（SF_ORG_ID_PROD）を読めること
#   - Salesforce CLI（sf）は npm 版であること。手順 1 の確認は、成功したら 24 時間は省略する（GitHub Actions 上では、確認しない）
#   - node があること（sf が npm 版のため、通常はある）。sf のプラグインは不要（以前使っていた sfdx-git-delta は、使わない）
#   - 変更の検知（SF_METASYNC_DETECT が shadow・on）を使うときは、接続ユーザーに「設定・定義の参照」の権限があること
#     （ないと、履歴の問い合わせが失敗し、毎回、全件取得になる）
#
# 【補足】
#   - 変更の検知: 環境変数 SF_METASYNC_DETECT（既定 off）。off = 行わない（従来どおり、毎回、全件取得）／
#     shadow = 検知の結果をログに出すが、取得は常に行う（検知が「変更なし」なのに、実際は変更があったときは、WARNING で
#     その一覧を出す。運用の前の確かめ用）／ on = 「変更なし」のとき、取得を省く。種類ごとの区分は config/metasync-detect.txt
#     （A 履歴・B 更新日時の一覧。表にない種類は C = 毎日の全件取得でだけ反映される。最大約 1 日の遅れ）。
#     off 以外では、状態を ./sf-tools/metasync/state.json に持つ（最後に全件取得した時刻と、区分 B の記録。変更あり・不明の
#     全件取得のあとにだけ更新するため、変更のない回は、コミットを作らない。ファイルが変わらず、状態だけが変わるときは、
#     状態だけのコミットになる）。状態は、速くするための手がかりで、壊れていても全件取得になる。設計: doc/sf-metasync-redesign.md 15 章
#   - 終了コード: 0（同期した・変更がなかった）／ 1（中断した）／ 3（同期した（追加・変更の push・伝播まで行った）が、
#     削除の保留（S2・S3・S4）がある。GitHub Actions では、ジョブが失敗として表示される）。S5 の保留だけのときは 0
#   - 同期の対象のフォルダ: <パッケージのフォルダ>/main/default の下の、config/metadata-dirs.txt（sf-tools 側）で、
#     metadata.txt の種類に当たるフォルダと、取得結果にあるフォルダ。それ以外（metadata.txt にない種類のフォルダなど）は触らない。
#     フォルダを共有する種類（objects など）は、フォルダ単位で同じにする（metadata.txt から種類を外すと、そのファイルは削除になる）
#   - 残すファイル（削除しない）: .gitkeep と、.forceignore の行に当たるファイル（否定の ! の行は、解釈しない）
#   - 削除の保留は、ファイルを残す（以前の動作と同じ）。次の回に、条件が解ければ削除される。初回など、古いファイルが
#     たまっている場合は、手元で --dry-run で確かめてから、--allow-mass-delete で実行する
#   - 手順 4・11 の「未コミットの変更」の判定（git diff-index HEAD）と git stash は、追跡中のファイルだけが対象。
#   - 追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）がある場合、手元で実行したときは、手順 4 で中断する
#     （同期のコミットに、無関係なファイルが含まれてしまうため）。GitHub Actions 上では、確認しない。
#     sf-tools/release/（作業ブランチの作業用ファイル）は、確認の対象外で、同期のコミットにも含めない
#   - main への push（手順 11）と、伝播の push（手順 12）は、--no-verify（pre-push フックを通さない）。pre-push フック
#     （sf-prepush.sh）は、branches.txt のブランチ（保護ブランチ）の上からの push・保護ブランチへの push を、必ず拒否するため
#     （手元で実行したとき、--no-verify がないと、伝播の push は、すべて失敗する）。サーバー側の保護（Ruleset）は、そのまま効く
#   - branches.txt が無い・ブランチの定義が無いときは、WARNING を表示し、main のみとして扱う（手順 12 の対象なし）
#   - 手順 12 の完了のメッセージは、実際に伝播できたブランチだけを表示する。スキップしたブランチ（リモートにない・失敗）が
#     あれば、WARNING で一覧する（終了コードは 0 のまま）
#   - ログ: ./sf-tools/logs/sf-metasync.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"  # run 不使用: common.sh の読み込み前（run が未定義）
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # run 不使用: common.sh の読み込み前（run が未定義）
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
    exit 0
fi
source "$COMMON_LIB"
source "${SCRIPT_DIR}/../lib/org.sh"   # org_find_username_by_id（組織 ID から、ログイン済みの組織を探す）

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "メタデータ同期（Salesforce -> Git）を開始します (${SCRIPT_NAME}.sh)"

# sf が終了コードを正しく返すか確認する（npm 版が前提。異常なら中断する）。成功は 24 時間は確認を省略する
# （GitHub Actions 上では、確認を省略する）
check_sf_cli --cache

# ------------------------------------------------------------------------------
# 4. 実行時引数の解析
# ------------------------------------------------------------------------------
JSON_ECHO=0       # -j: 取得の応答（JSON）の先頭を、ログにも記録する
DRY_RUN=0         # -n: 計画の表示までで終了する
ASSUME_YES=0      # -y: --dry-run のときだけ、続行の確認を省く
ALLOW_MASS=0      # --allow-mass-delete: S3・S4 の削除の保留を解く
FULL=0            # --full: 変更の検知が「変更なし」でも、取得を省かない

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --json|-j)    JSON_ECHO=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --full)       FULL=1 ;;
        --allow-mass-delete) ALLOW_MASS=1 ;;
        --verbose|-v) : ;;  # SILENT_EXEC は common.sh が設定済み
        --*)
            die "不明なオプションです: $1"
            ;;
        *)
            die "不明な引数です: $1"
            ;;
    esac
    shift
done

# -y は、push の確認を省く手段にしない（--dry-run のときだけ）。大量削除の保留を解く指定は、手元で、人が確認できるときだけ
[[ "$ASSUME_YES" -eq 1 && "$DRY_RUN" -eq 0 ]] && die "-y / --yes は --dry-run と一緒にだけ指定できます。"
[[ "$ALLOW_MASS" -eq 1 && "${GITHUB_ACTIONS:-false}" == "true" ]] && die "--allow-mass-delete は GitHub Actions 上では指定できません。"

# 変更の検知のモード（off = 行わない（既定）／ shadow = 検知はするが、取得は常に行う／ on = 「変更なし」なら取得を省く）
readonly DETECT_MODE="${SF_METASYNC_DETECT:-off}"
[[ "$DETECT_MODE" == "off" || "$DETECT_MODE" == "shadow" || "$DETECT_MODE" == "on" ]] \
    || die "SF_METASYNC_DETECT は off / shadow / on のどれかにしてください: ${DETECT_MODE}"

# ------------------------------------------------------------------------------
# 5. 固有設定
# ------------------------------------------------------------------------------
# 接続先の組織（main の組織。本番・Sandbox・Developer Edition のどれでもよい）
#   ・GitHub Actions 上: ワークフローが JWT で作る prod エイリアスを使う（gh は見ない）
#   ・手元: エイリアスの名前には頼らず、組織 ID で決める。sf-init が GitHub の Variable SF_ORG_ID_PROD に記録した、1 番目（main）の
#     組織の ID と、この PC の sf にログイン済みの組織の ID を突き合わせ、一致した組織のユーザー名を接続先にする。
#     名前は付け替えられ、同じ PC の別のプロジェクトと衝突する。ID で決めれば、取り違え（別のプロジェクトの組織で main を書き換える）を防げる。
#     見つからなければ、何も変えずに中断する（推測して、別の組織に進まない。prod エイリアスには、フォールバックしない）
# run 不使用: 終了コードで判定するため（run は、失敗しても、エラーの文言を標準出力に返すため、出力が空かでは判定できない）。
#   出力は捨てる（--json の出力には、アクセストークンが含まれる。run は、出力をログに記録する）
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    TARGET_ORG="prod"
    if ! sf org display --target-org "$TARGET_ORG" --json > /dev/null 2>&1; then
        die "prod エイリアスの組織情報を取得できませんでした（sf org display --target-org ${TARGET_ORG} が失敗しました）。"
    fi
    log "INFO" "接続先組織: ${TARGET_ORG}"
else
    _origin_url=$(git remote get-url origin 2>/dev/null) || _origin_url=""  # VAR=$(cmd) のため run 不使用
    _repo_pair=$(parse_github_remote "$_origin_url") || _repo_pair=""        # VAR=$(cmd) のため run 不使用
    [[ -n "$_repo_pair" ]] || die "origin の URL から、GitHub のリポジトリを特定できません: ${_origin_url:-（origin なし）}"
    _repo_full="${_repo_pair%% *}/${_repo_pair##* }"
    _main_org_id=$(gh variable get SF_ORG_ID_PROD -R "$_repo_full" 2>/dev/null | tr -d '\r') || _main_org_id=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$_main_org_id" ]] || die "GitHub の Variable SF_ORG_ID_PROD を読み取れませんでした（${_repo_full}）。"
    TARGET_ORG=""
    org_find_username_by_id "$_main_org_id" TARGET_ORG \
        || die "この PC の sf に、組織 ID ${_main_org_id}（SF_ORG_ID_PROD。main の組織）の組織が、ログインされていません。"
    if ! sf org display --target-org "$TARGET_ORG" --json > /dev/null 2>&1; then
        die "接続先の組織情報を取得できませんでした（sf org display --target-org ${TARGET_ORG} が失敗しました）。"
    fi
    log "INFO" "接続先組織: ${TARGET_ORG}（組織 ID ${_main_org_id}。GitHub の SF_ORG_ID_PROD と一致）"
fi
readonly TARGET_ORG

# 常に main ブランチで作業する
readonly BRANCH_NAME="main"
# 元のブランチ（終了時に戻る先）。detached HEAD のときは、戻る先のブランチがないため、何もせずに中断する（stash の前）
#   run 不使用: 終了コードで判定するため（run は、失敗しても、エラーの文言を標準出力に返す。以前は、その文言と「main」が
#   元のブランチとして入り、終了時に戻れないまま、main の上で git stash pop していた）
ORIGINAL_BRANCH=$(git symbolic-ref -q --short HEAD) \
    || die "現在の HEAD がブランチを指していません（detached HEAD）。元のブランチに戻れないため、中断します。"

STASH_USED=0
WORK_DIR=""       # 取得先の一時プロジェクト（手順 5 で作る。終了時に削除）
PKG_PATH=""       # sfdx-project.json の packageDirectories の path（例: force-app）。手順 5 で決める
APPLIED=0         # 1 = 計画を作業ツリーに反映した（手順 10 の開始以降）
COMMITTED=0       # 1 = 反映の内容をコミットした
readonly STATE_FILE="sf-tools/metasync/state.json"   # 変更の検知の状態（main にコミットする。手順 11）
STATE_WRITTEN=0   # 1 = 状態ファイルを書いた（コミットする前に中断したら、戻す）

# 終了時の後始末: ① 反映したが、コミットする前に中断したときは、同期の対象のパッケージのフォルダを HEAD に戻す
#   （手元の実行では、手順 4 で、追跡していないファイルがないことを確かめているため、clean で消えるのは、今回写したファイルだけ）
#   ② 元のブランチへ復帰し、stash した変更を復元 ③ 一時フォルダを削除
#   rm は run 不使用: 終了時の後始末のため（失敗しても、ほかの後始末を止めない。消すだけの操作をログに残さない）
cleanup_on_exit() {
    if [[ "$APPLIED" -eq 1 && "$COMMITTED" -eq 0 && -n "$PKG_PATH" ]]; then
        run git reset -q HEAD -- "$PKG_PATH" 2>/dev/null       # ステージ済みの新規ファイルを、インデックスから外す（checkout HEAD は、HEAD にあるファイルしか戻さない）
        run git checkout HEAD -- "$PKG_PATH" 2>/dev/null       # 変更・削除したファイルを戻す
        run git clean -fdq -- "$PKG_PATH" 2>/dev/null          # 新しく書いたファイルを消す
    fi
    # 検知の状態ファイルを書いたが、コミットする前に中断したときは、元に戻す（HEAD にあれば戻し、なければ消す）
    if [[ "$STATE_WRITTEN" -eq 1 && "$COMMITTED" -eq 0 ]]; then
        run git reset -q HEAD -- "$STATE_FILE" 2>/dev/null
        run git checkout HEAD -- "$STATE_FILE" 2>/dev/null || rm -f "$STATE_FILE" 2>/dev/null   # rm は run 不使用: 終了時の後始末（失敗しても止めない）
    fi
    run git checkout "$ORIGINAL_BRANCH" 2>/dev/null
    [[ "$STASH_USED" -eq 1 ]] && run git stash pop 2>/dev/null
    [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null
    return 0
}
trap cleanup_on_exit EXIT

readonly COMMIT_MSG="定期更新: Salesforce変更の自動反映 ($(date +'%Y-%m-%d'))"

# 計画・反映を行う Node の部品（lib/metasync.js）。テストでは、SF_METASYNC_NODE で node を差し替える
readonly NODE_BIN="${SF_METASYNC_NODE:-node}"
readonly METASYNC_JS="${SCRIPT_DIR}/../lib/metasync.js"
command -v "$NODE_BIN" > /dev/null 2>&1 || die "node が見つかりません（sf CLI は npm 版が前提のため、通常は、あります）。"  # 存在確認のため run 不使用
[[ -f "$METASYNC_JS" ]] || die "lib/metasync.js が見つかりません: ${METASYNC_JS}"

# Node の出力（複数行）を、1 行ずつ log に出す。先頭が「[WARNING] 」の行は、WARNING として出す（[WARNING] の文字は外す）。
# そのまま log "INFO" に渡すと、「[INFO] [WARNING] …」と、二重になる
_log_node_lines() {
    local text="$1" line
    while IFS= read -r line; do
        case "$line" in
            "[WARNING] "*) log "WARNING" "${line#"[WARNING] "}" ;;
            *)             log "INFO" "$line" ;;
        esac
    done <<< "$text"
}

readonly METADATA_CONFIG="./sf-tools/config/metadata.txt"
[[ ! -f "$METADATA_CONFIG" ]] && die "メタデータ設定ファイルが見つかりません: ${METADATA_CONFIG}"
METADATA_TYPES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"  # 行末の CR を除く（Windows で編集された CRLF のファイルでも、種類の名前に CR が付かないように）
    [[ "$line" =~ ^[[:space:]]*# ]] && continue  # コメント行をスキップ
    [[ -z "${line//[[:space:]]/}" ]] && continue  # 空行をスキップ
    METADATA_TYPES+=("$line")
done < "$METADATA_CONFIG"
readonly METADATA_TYPES
log "INFO" "対象メタデータ (${#METADATA_TYPES[@]} 件): ${METADATA_TYPES[*]}"

# ------------------------------------------------------------------------------
# 6. フェーズ定義
# ------------------------------------------------------------------------------

# 【SWITCH】main ブランチへ切替（他ブランチから実行した場合は、追跡中のファイルに未コミットの変更があれば stash してから切替）
phase_switch_to_main() {
    if [[ "$ORIGINAL_BRANCH" == "main" ]]; then
        return $RET_OK
    fi

    log "INFO" "main ブランチへ切り替えます（現在: ${ORIGINAL_BRANCH}）..."

    # 作業中の変更を一時退避
    if ! run git diff-index --quiet HEAD --; then
        log "INFO" "ローカルの変更を一時退避します (git stash)..."
        run git stash || return $RET_NG
        STASH_USED=1  # trap で stash pop するためフラグを立てる
    fi

    run git checkout main || return $RET_NG
    return $RET_OK
}

# 【GIT】リモートの変更を取り込む
phase_git_update() {
    log "INFO" "リモートの最新状態を取り込んでいます..."

    # main ブランチのローカル変更は Salesforce 組織の内容より優先されないため中止する
    # （stash して復元すると、ローカル変更が retrieve 後にコミットされてしまうため）
    if ! run git diff-index --quiet HEAD --; then
        die "main ブランチに、追跡中のファイルの未コミットの変更があります（Salesforce 組織の内容を正として同期するため、ローカルの変更は、同期に含めません）。"
    fi

    # 手元で実行したときは、追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）がある場合も中止する。
    #   後の git add -A で、無関係なファイルが、同期のコミットに含まれてしまうため（以前は、含めていた）。
    #   sf-tools/release/ は、作業ブランチの日常的な作業用ファイル（sf-install.sh が作る）のため、対象外（ステージもしない）。
    #   GitHub Actions 上では、確認しない（クリーンなチェックアウトで、定期の同期を、予期しないファイルで止めないため）
    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        local untracked
        untracked=$(git ls-files --others --exclude-standard -- . ':!sf-tools/release' | head -5)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$untracked" ]]; then
            die "main ブランチに、追跡していないファイルがあります（同期のコミットに含まれてしまうため中止します）: $(echo "$untracked" | tr '
' ' ')"
        fi
    fi

    run git fetch origin || log "WARNING" "git fetch に失敗しました。ローカルキャッシュで続行します。"

    if ! run git pull origin "$BRANCH_NAME" --rebase; then
        run git rebase --abort
        return $RET_NG
    fi

    return $RET_OK
}

# 【PREPARE】取得先の一時プロジェクトを作る（手順 5）。作業ツリーには、まだ何も書かない
phase_prepare_work() {
    # run 不使用: 標準出力（パッケージのフォルダの path）を変数に受けるため。S8（packageDirectories が 1 つでない）もここで検出する
    PKG_PATH=$("$NODE_BIN" "$METASYNC_JS" root --repo .) || return $RET_NG
    [[ -n "$PKG_PATH" ]] || return $RET_NG
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-metasync-XXXXXX") || return $RET_NG  # VAR=$(cmd) のため run 不使用
    run cp sfdx-project.json "$WORK_DIR/" || return $RET_NG
    [[ -f .forceignore ]] && { run cp .forceignore "$WORK_DIR/" || return $RET_NG; }
    run mkdir -p "$WORK_DIR/$PKG_PATH" || return $RET_NG
    RETRIEVE_JSON="$WORK_DIR/retrieve.json"
    RETRIEVE_ERR="$WORK_DIR/retrieve.err"
    PLAN_FILE="$WORK_DIR/plan.tsv"
    RECENT_FILES="$WORK_DIR/recent.txt"
    return $RET_OK
}

# 【DETECT】組織に変更があるかを、全件取得の前に調べる（手順 5。SF_METASYNC_DETECT が off 以外のとき）
#   結果は DETECT_RC に入る: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明 ／ -1 = 検知しなかった（off）。0 以外は、すべて全件取得に進む。
#   検知の失敗は、取得を止めない（検知は、取得を省くための手がかりで、失敗が取りこぼしにならないように、全件取得へ倒す）
DETECT_RC=-1
DETECT_STATE_NEW=""
phase_detect_changes() {
    [[ "$DETECT_MODE" == "off" ]] && return $RET_OK
    local table="${SCRIPT_DIR}/../config/metasync-detect.txt" out
    if [[ ! -f "$table" ]]; then
        log "WARNING" "検知の区分の表が見つかりません（${table}）。検知は行わず、全件取得します。"
        return $RET_OK
    fi
    DETECT_STATE_NEW="$WORK_DIR/state.new.json"
    log "INFO" "変更の検知を行います（SF_METASYNC_DETECT=${DETECT_MODE}。読み取りのみ）..."
    # run 不使用: 戻り値（0 / 10 / 11）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" detect --org "$TARGET_ORG" --types-file "$METADATA_CONFIG" --table "$table" \
        --state "$STATE_FILE" --out-state "$DETECT_STATE_NEW" 2>&1)
    DETECT_RC=$?
    _log_node_lines "$out"
    if [[ $DETECT_RC -ne 0 && $DETECT_RC -ne 10 ]]; then
        [[ $DETECT_RC -eq 11 ]] || log "WARNING" "検知が異常終了しました（終了コード ${DETECT_RC}）。不明として扱い、全件取得します。"
        DETECT_RC=11
    fi
    return $RET_OK
}

# 【RETRIEVE】組織からメタデータを、一時プロジェクトに取得する（手順 6）
#   run 不使用: 応答（JSON）を判定に使うため、ファイルへ受ける（run は、出力をログに記録し、戻り値も変える。JSON は大きい）
phase_retrieve_metadata() {
    local cmd=(sf project retrieve start --target-org "$TARGET_ORG" --ignore-conflicts --json)
    local type attempt rc
    for type in "${METADATA_TYPES[@]}"; do
        cmd+=(--metadata "$type")
    done
    for attempt in 1 2; do
        log "INFO" "組織からメタデータを取得します（一時プロジェクトへ。種類 ${#METADATA_TYPES[@]} 件。試行 ${attempt}/2）..."
        ( cd "$WORK_DIR" && "${cmd[@]}" ) > "$RETRIEVE_JSON" 2> "$RETRIEVE_ERR"
        rc=$?
        if [[ "$JSON_ECHO" -eq 1 ]]; then
            log "INFO" "取得の応答（先頭 2000 バイト）: $(_mask_secrets "$(head -c 2000 "$RETRIEVE_JSON")")"
        fi
        [[ $rc -eq 0 ]] && return $RET_OK
        log "WARNING" "取得が失敗しました（終了コード ${rc}）: $(_mask_secrets "$(head -c 600 "$RETRIEVE_ERR"; head -c 600 "$RETRIEVE_JSON")" | tr '\n' ' ')"
        # 一時的なエラー（組織側の処理・接続の切断）なら、待って 1 回だけやり直す（読み取りのみのため、やり直しても安全）
        if [[ $attempt -eq 1 ]] && grep -qE 'MetadataTransferError|UNKNOWN_EXCEPTION|ERROR_HTTP_404|ECONNRESET|ETIMEDOUT|socket hang up|fetch failed|503|Service Unavailable' "$RETRIEVE_JSON" "$RETRIEVE_ERR" 2>/dev/null; then
            log "WARNING" "一時的なエラーの可能性があるため、${SF_METASYNC_RETRY_WAIT:-60} 秒待って 1 回だけやり直します。"
            sleep "${SF_METASYNC_RETRY_WAIT:-60}"  # run 不使用: 待機
            continue
        fi
        break
    done
    return $RET_NG
}

# 【RECENT】直近 24 時間に、同期以外のコミット（PR のマージなど）で変わったファイルの一覧を作る（手順 7。S5 用）
#   組織にまだリリースされていない（リリース中・失敗した）部品は、組織にないため、鏡像では削除の対象になってしまう。それを保留にする
#   run 不使用: 出力をファイルへ受けるため。失敗しても、空の一覧にして続ける（S5 が働かないだけ）
phase_recent_files() {
    git log --first-parent -m --since="24 hours ago" --invert-grep --grep='^定期更新: Salesforce変更の自動反映' \
        --name-only --format= HEAD -- "$PKG_PATH" > "$RECENT_FILES" 2>/dev/null || : > "$RECENT_FILES"
    return $RET_OK
}

# 【PLAN】手元と取得結果を比べて、計画（追加・変更・削除・保留）を作り、要約を表示する（手順 8・9）
#   戻り値: 0（計画できた）／ NG（作れなかった）。保留の有無は PLAN_RC（0 または 3）に入る
PLAN_RC=0
phase_plan() {
    local args=(plan --repo . --fetched "$WORK_DIR" --types-file "$METADATA_CONFIG" --dirs-table "${SCRIPT_DIR}/../config/metadata-dirs.txt"
                --out "$PLAN_FILE" --recent-files "$RECENT_FILES" --retrieve-json "$RETRIEVE_JSON")
    [[ "$ALLOW_MASS" -eq 1 ]] && args+=(--allow-mass-delete)
    local summary line
    # run 不使用: 戻り値（0 / 3 / 1）で分岐し、要約をログにも記録するため
    summary=$("$NODE_BIN" "$METASYNC_JS" "${args[@]}" 2>&1)
    PLAN_RC=$?
    _log_node_lines "$summary"
    [[ $PLAN_RC -eq 0 || $PLAN_RC -eq 3 ]] || return $RET_NG
    # コミットの本文・確認の要否に使う件数（VAR=$(cmd) のため run 不使用）
    PLAN_COUNTS=$(awk -F'\t' '{c[$1]++} END{printf "追加 %d 件 / 変更 %d 件 / 削除 %d 件 / 削除の保留 %d 件", c["A"], c["M"], c["D"], c["H"]}' "$PLAN_FILE")
    PLAN_CHANGES=$(awk -F'\t' '$1=="A"||$1=="M"||$1=="D"{n++} END{print n+0}' "$PLAN_FILE")
    # 検知が「変更なし」だったのに、実際は変更があったとき（shadow の確かめ、および --full の日次の取得）は、一覧を出す。
    #   区分 C の種類（検知できない）の変更を含む。検知の取りこぼしの有無を、運用で確かめるための記録
    if [[ "$DETECT_RC" -eq 0 && "$PLAN_CHANGES" -gt 0 ]]; then
        log "WARNING" "検知は「変更なし」でしたが、実際は ${PLAN_CHANGES} 件の変更がありました（区分 C の種類の変更を含む）。先頭 10 件:"
        awk -F'\t' '$1=="A"||$1=="M"||$1=="D"{print "  " $1 " " $2}' "$PLAN_FILE" | head -10 | while IFS= read -r line; do log "WARNING" "$line"; done
    fi
    return $RET_OK
}

# 【APPLY】計画を作業ツリーに反映する（手順 10）。保留の削除は、行わない
phase_apply_plan() {
    APPLIED=1   # 途中で失敗しても、終了時に HEAD へ戻せるように、先に立てる
    local out
    out=$("$NODE_BIN" "$METASYNC_JS" apply --plan "$PLAN_FILE" --repo . --fetched "$WORK_DIR" 2>&1) || { log "ERROR" "$out"; return $RET_NG; }  # run 不使用: 戻り値で判定する
    log "INFO" "$out"
    # 検知の状態を書く（検知が、変更あり・不明のとき。全件取得と反映が成功したあとにだけ書く。変更なしのときは、書かない）
    if [[ "$DETECT_MODE" != "off" && ( "$DETECT_RC" -eq 10 || "$DETECT_RC" -eq 11 ) && -f "$DETECT_STATE_NEW" ]]; then
        STATE_WRITTEN=1   # 途中で失敗しても、終了時に戻せるように、先に立てる
        run mkdir -p "${STATE_FILE%/*}" || return $RET_NG
        run cp "$DETECT_STATE_NEW" "$STATE_FILE" || return $RET_NG
        log "INFO" "検知の状態を更新しました: ${STATE_FILE}"
    fi
    return $RET_OK
}

# 【SYNC】変更を Git へ反映
phase_git_sync() {
    log "INFO" "Git リポジトリへ反映中..."
    # 同期の対象のパッケージのフォルダ（と、書いたときは検知の状態ファイル）だけをステージする
    #   （それ以外が変わる理由がない。sf-tools/release/ も含めない）
    local add_paths=("$PKG_PATH")
    [[ "$STATE_WRITTEN" -eq 1 ]] && add_paths+=("$STATE_FILE")
    run git add -A -- "${add_paths[@]}" || return $RET_NG

    # ステージに変更がなければ、未プッシュのコミットを確認する。あれば（前回、コミットのあとに push が失敗した）、push だけ行う。
    #   なければ、早期終了（組織側に変更なし）
    if run git diff-index --quiet HEAD --; then
        local _ahead
        _ahead=$(git rev-list --count "origin/${BRANCH_NAME}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
        if [[ "$_ahead" =~ ^[0-9]+$ && "$_ahead" -gt 0 ]]; then
            log "INFO" "未プッシュのコミットが ${_ahead} 件あります（前回の同期のコミットの push が、失敗した可能性があります）。push だけ行います。"
            if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
                git log --oneline "origin/${BRANCH_NAME}..HEAD" >&2  # run 不使用: 確認表示のため
                ask_yn "上記のコミットを main にプッシュします。よろしいですか？" || die "中断しました。"
            fi
            run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
            return $RET_OK
        fi
        return $RET_NO_CHANGE
    fi

    # コミットの本文に、計画の件数を書く（確認は、手順 9 で済んでいる）。検知の状態を更新したときは、その旨も書く
    local body="$PLAN_COUNTS"
    if [[ "$STATE_WRITTEN" -eq 1 ]]; then
        if [[ "$PLAN_CHANGES" -eq 0 ]]; then body="${body}（検知の状態の更新のみ）"; else body="${body}（検知の状態も更新）"; fi
    fi
    run git commit -m "$COMMIT_MSG" -m "$body" || return $RET_NG
    COMMITTED=1
    # --no-verify: このコマンドは、main への同期の専用（管理者が、確認して実行する。GitHub Actions では、フックがない）。
    #   pre-push フック（開発者の main への直接 push を止める）を、ここでだけ通さない。サーバー側の保護（Ruleset）は、そのまま効く
    run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
}

# 【PROPAGATE】main の変更を、branches.txt の main 以外の各ブランチへ、マージして push する（例: main → staging、main → develop）
PROPAGATED_OK=""        # 伝播できたブランチ（空白区切り）
PROPAGATED_SKIPPED=""   # 伝播をスキップしたブランチ（ない・失敗）
phase_propagate_downstream() {
    local downstream_branches
    downstream_branches=$(get_branch_list | grep -v '^main$')  # VAR=$(cmd) のため run 不使用
    for branch in $downstream_branches; do
        # リモートにブランチが存在するか確認（出力は不要なため直接呼び出し）
        if ! git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            log "WARNING" "${branch} ブランチがリモートに存在しないためスキップします"
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        log "INFO" "main → ${branch} へマージします..."

        if ! run git checkout "$branch"; then
            log "WARNING" "${branch} のチェックアウトに失敗しました（スキップ）"
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        if ! run git pull origin "$branch" --rebase; then
            log "WARNING" "${branch} の pull に失敗しました（スキップ）"
            run git rebase --abort
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        if ! run git merge "main" --no-edit; then
            log "WARNING" "${branch} へのマージに失敗しました（スキップ）"
            run git merge --abort
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        # --no-verify: 伝播先は branches.txt のブランチ（保護ブランチ）のため、pre-push フック（sf-prepush.sh）は、必ず拒否する
        #   （以前は付けておらず、手元で実行すると、伝播の push は、すべて失敗していた）。サーバー側の保護（Ruleset）は、そのまま効く
        if ! run git push --no-verify origin "$branch"; then
            log "WARNING" "${branch} の push に失敗しました（スキップ）"
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        log "SUCCESS" "${branch} への伝播が完了しました"
        PROPAGATED_OK="${PROPAGATED_OK}${branch} "
    done

    # 作業ブランチを main に戻す
    run git checkout main || die "main ブランチへの復帰に失敗しました。"
}

# ------------------------------------------------------------------------------
# 7. メインフロー
# ------------------------------------------------------------------------------
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    print_admin_warning --standard "main の Salesforce 組織からメタデータを取得し" "main ブランチへ push します。"
    # -y は --dry-run のときだけ（引数の検査で確認済み）。警告は、-y でも表示する
    if [[ "$ASSUME_YES" -eq 0 ]]; then
        ask_yn "続行しますか？" || die "中断しました。"
    fi
fi

phase_switch_to_main    || die "main ブランチへの切替に失敗しました。"
log "SUCCESS" "main ブランチへの切替完了"

phase_git_update        || die "Git 更新に失敗しました。"
log "SUCCESS" "Git 更新完了"

phase_prepare_work      || die "取得先の一時プロジェクトの準備に失敗しました。"
log "SUCCESS" "一時プロジェクトの準備完了（パッケージのフォルダ: ${PKG_PATH}）"

# 変更の検知（手順 5）。on で「変更なし」なら、取得を省いて終了する。--full・--dry-run のとき、および未プッシュのコミットが
#   あるとき（前回の push の失敗。phase_git_sync が push だけ行う）は、省かない
phase_detect_changes
if [[ "$DETECT_MODE" == "on" && "$DETECT_RC" -eq 0 ]]; then
    UNPUSHED=$(git rev-list --count "origin/${BRANCH_NAME}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    if [[ "$FULL" -eq 1 ]]; then
        log "INFO" "--full が指定されているため、検知の結果にかかわらず、全件取得します。"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        log "INFO" "--dry-run のため、検知の結果にかかわらず、全件取得して計画を作ります（本番の実行では、取得を省きます）。"
    elif [[ "$UNPUSHED" =~ ^[0-9]+$ && "$UNPUSHED" -gt 0 ]]; then
        log "INFO" "未プッシュのコミットがあるため、検知の結果にかかわらず、全件取得します。"
    else
        log "SUCCESS" "完了: 検知の結果、Salesforce 組織側に変更はありませんでした（全件取得を省きました）。"
        exit $RET_OK
    fi
fi

phase_retrieve_metadata || die "メタデータの取得に失敗しました。"
log "SUCCESS" "メタデータ取得完了"

phase_recent_files
phase_plan              || die "計画の作成に失敗しました。"
log "SUCCESS" "計画の作成完了（${PLAN_COUNTS}）"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "SUCCESS" "完了: --dry-run のため、計画の表示までで終了します（作業ツリー・コミット・push・伝播は行いません）。"
    exit $RET_OK
fi

# 手元では、変更があるときだけ、反映の確認を取る（GitHub Actions 上では、表示のみ）
if [[ "${GITHUB_ACTIONS:-false}" != "true" && "$PLAN_CHANGES" -gt 0 ]]; then
    ask_yn "上記の計画を main に反映して、コミット&プッシュします。よろしいですか？" || die "中断しました。"
fi

phase_apply_plan        || die "計画の反映に失敗しました。"

phase_git_sync
RES=$?

if [[ $RES -eq $RET_OK ]]; then
    log "SUCCESS" "完了: リポジトリを最新に更新しました。"
    if [[ "$STATE_WRITTEN" -eq 1 && "$COMMITTED" -eq 1 && "$PLAN_CHANGES" -eq 0 ]]; then
        # 検知の状態ファイルの更新だけのコミット（メタデータの変更はない）は、下流のブランチへ伝播しない（main の中だけで使う状態のため）
        log "INFO" "検知の状態ファイルの更新だけのコミットのため、下流ブランチへの伝播は行いません。"
    else
        phase_propagate_downstream || die "下流ブランチへの伝播に失敗しました。"
        # 実際に伝播できたブランチだけを表示する（以前は、branches.txt の内容や、スキップの有無にかかわらず、固定の文言を出していた）
        log "SUCCESS" "下流ブランチへの伝播完了（伝播したブランチ: ${PROPAGATED_OK% }$([[ -z "$PROPAGATED_OK" ]] && echo なし)）"
        [[ -z "$PROPAGATED_SKIPPED" ]] || log "WARNING" "伝播できなかったブランチ（スキップ）: ${PROPAGATED_SKIPPED% }"
    fi
elif [[ $RES -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "完了: Salesforce 組織側に変更はありませんでした。"
else
    die "Git への同期中にエラーが発生しました。"
fi

# 削除の保留（S2・S3・S4）があるときは、追加・変更の同期は済んだうえで、終了コード 3 で知らせる（Actions では、ジョブが失敗として表示される）
if [[ "$PLAN_RC" -eq 3 ]]; then
    log "WARNING" "削除を保留したものがあります（ファイルは残しています）。原因を確かめてください（手元で --dry-run、必要なら --allow-mass-delete）。"
    exit 3
fi
exit $RET_OK
