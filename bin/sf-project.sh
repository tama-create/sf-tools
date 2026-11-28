#!/bin/bash
# ==============================================================================
# sf-project.sh - プロジェクトの作成と保守（管理者向け。2026-11-28 に sf-init.sh から改名）
# ==============================================================================
# 新しい force-XXXX リポジトリを GitHub に作成し、sf-tools と連携させるまでの一連のセットアップ（Phase 1〜10 と後処理）を
# 自動化する。セットアップ後の保守用のモード（--add-tier / --remove-tier / --reconnect / --status / --verify）も持つ。管理者向けのコマンド。
#
# 【使い方】
#   cd {作業フォルダ}                                  # sf-job.sh を実行する場所（admin・force-* の中は不可）
#   ~/sf-tools/bin/sf-project.sh [--owner OWNER] [--project XXXX]
#   ~/sf-tools/bin/sf-project.sh [--owner OWNER] [--project XXXX] --resume N
#   ~/sf-tools/bin/sf-project.sh [--owner OWNER] [--project XXXX] --only N
#
#   cd {作業フォルダ}/admin/force-XXXX                 # 保守用のモードは、force-* の中で実行する
#   ~/sf-tools/bin/sf-project.sh --add-tier staging|develop
#   ~/sf-tools/bin/sf-project.sh --remove-tier staging|develop [--purge-secrets]
#   ~/sf-tools/bin/sf-project.sh --reconnect main|staging|develop
#   ~/sf-tools/bin/sf-project.sh --status
#   ~/sf-tools/bin/sf-project.sh --verify [--plan] [--cleanup] [--no-metasync] [--components] [--validate-only] [--with-objects]
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
#   --add-tier staging|develop
#                         : 既存プロジェクトに staging / develop の段階を追加する（phases/init/add_tier.sh）
#   --remove-tier staging|develop
#                         : 既存プロジェクトから staging / develop の段階を外す（phases/init/remove_tier.sh）。branches.txt から
#                           その段階の行を消す PR を作るだけ（ブランチ・Secrets / Variables・Ruleset・組織は変えない）。
#                           値がなければ終了する。--add-tier と同時には指定できない（終了する）
#     --purge-secrets     : （--remove-tier と一緒に）行を消す PR のマージ後に、その段階の接続情報（Secrets / Variables）を消す。
#                           --remove-tier なしで指定すると終了する
#   --reconnect <段階>    : 1 つの段階（main / staging / develop）の、接続先の Salesforce 組織を付け替える（phases/init/reconnect.sh）。
#                           値がなければ終了する
#   --status              : セットアップの診断（リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。不足は、
#                           直し方つき）と、段階ごとの接続先（ログイン先・組織の種類・ユーザー・組織 ID）を一覧にする
#                           （読み取りのみ。phases/init/status.sh）
#   --verify              : 動作の確認（実際のリポジトリ・組織に、Hello World を、リリースして、削除する。phases/init/verify.sh）。
#                           環境全体の確認（SF_TOOLS_BRANCH・ログに Token が残っていない・wf-metasync）も、リリースの前に行う
#                           （--cleanup のときは行わない）
#     --plan              : （--verify と一緒に）診断と、実行内容の表示だけ（何も変更しない）
#     --cleanup           : （--verify と一緒に）削除のみ（検証が途中で止まって、組織に Hello World が残ったときの後始末）
#     --no-metasync       : （--verify と一緒に）環境の確認のうち、wf-metasync の実行を、省略する
#     --components        : （--verify と一緒に）Hello World の代わりに、パターン別のサンプル（種類は phases/init/verify.sh）を、
#                           develop の組織だけに、リリースして、削除する（develop がある 3 層の構成のみ）。既定では、オブジェクト系
#                           （トリガー・Layout・オブジェクト・項目）と Flow は、リリース・削除に含めない（Flow は --validate-only で検証する）
#     --validate-only     : （--verify --components と一緒に）検証（wf-validate = dry-run）だけ。PR は、マージせずに閉じる。組織には、何も反映しない
#     --with-objects      : （--verify --components と一緒に）オブジェクト系も、リリースして、削除する
#                           （削除したオブジェクトの名前は、15 日間、予約される）
#                           ※ --plan〜--with-objects を --verify なしで指定すると終了する（--add-tier / --remove-tier と一緒のときは、無視する）
#   -h, --help            : このヘルプを表示して終了する（終了コード 0）
#
# 【処理の流れ】
#   1. 引数の解析と、sf の確認（sf --version の終了コードが 0 以外なら、案内を表示して終了）。
#      --add-tier → --remove-tier → --verify → --status → --reconnect の順で、最初に該当した 1 つだけを実行して終了する（ほかのモードの指定は無視。
#      ただし、--add-tier と --remove-tier の同時の指定・--remove-tier なしの --purge-secrets は、終了する）。
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
#        「用意ができたら Enter を押してください」（Enter / Y で進む。N / q / EOF で終了）。指定があるときは「続行しますか？」
#        （Y/N/q。N / q / EOF で終了）
#      - gh の認証ユーザーが、オーナーと一致するか、オーナーの組織の有効な管理者（admin・active）でなければ、終了する
#        （gh の認証ユーザーを取得できないときは、確認しない）
#   4. 実行した場所に admin/ を作って移動する。admin/force-XXXX が、OWNER/force-XXXX 以外を origin とするクローン
#      （.git フォルダがあり、origin が別のリポジトリ・origin がない・GitHub 以外）なら、終了する（大文字・小文字は区別しない）。
#      そのあと、排他のロックを取る（【補足】同時実行）
#   5. 前回の状態の判定（【補足】途中で止まったとき・完了済みのとき）
#   6. 新規の実行（--resume N（2 以上）/ --only の指定なし、かつ「続きをやる」を選んでいない）では、admin/force-XXXX の
#      完了の印を 0（やり直し中）にし、状態ファイル（admin/.sf-init-XXXX.env / admin/.sf-init-XXXX.progress）を消す
#   7. Phase の実行（失敗したら、やり直し方を表示して終了する。--only のときは、やり直し方を表示しない）
#        Phase 1:  環境チェック（ツール確認・GitHub CLI 認証確認）
#        Phase 2:  プロジェクト情報の確認（OWNER・XXXX の確認、sf-tools の版（配布版 main / 開発版 development）の選択、
#                  .sf-init-XXXX.env の作成）
#        Phase 3:  リポジトリ作成（gh repo create + git clone）
#        Phase 4:  ファイル生成（sf-refresh.sh。sf-refresh.sh が sf-hook.sh でフックを設置する）
#        Phase 5:  ブランチ構成（対話選択 → branches.txt 更新）
#        Phase 6:  PAT_TOKEN の設定
#        Phase 7:  Slack 連携の設定
#        Phase 8:  初回コミット＆プッシュ
#        Phase 9:  GitHub リポジトリ設定・Ruleset の適用
#        Phase 10: JWT 認証情報の設定（Salesforce GitHub Secrets 登録）
#      画面には、Phase の番号ではなく、利用者向けの 9 つのステップ（準備の確認 〜 Salesforce の接続・動作の確認）の見出しを出す
#      （--only のときは出さない）。--resume N（2 以上）/ --only のときは、「実行フェーズ: Phase N 〜 Phase M」も表示する
#   8. 後処理（条件は項目ごと。a〜e は、実行範囲の終わりが Phase 10 のときだけ。--only 10・--resume N を含む）
#      a. .sf-init-XXXX.env があれば、Token の値の行（^[A-Z_]*TOKEN_VALUE=）を消す
#      b. 最初のメタデータの同期（--only なし、開始が Phase 10 以下、.sf-init-XXXX.env に REPO_DIR・REPO_FULL_NAME があるとき）:
#         wf-metasync を起動して完了を待ち（既定 1200 秒。SF_INIT_SYNC_TIMEOUT。時間切れなら、実行を取り消す）、成功したら、
#         管理者用のクローンを main にして git pull --ff-only origin main。失敗しても、セットアップは成功のまま、完了画面で知らせる
#      c. 動作の確認（任意。【補足】動作の確認）
#      d. 管理者用のクローンを admin ブランチにして、GitHub にも push する（REPO_DIR があるとき。【補足】admin フォルダ）
#      e. 完了の印を 1 にし、状態ファイルを消す（--only なしのとき。印を付けられなければ、状態ファイルは残す）
#      f. 完了画面（常に表示する。--resume N / --only N のときも。admin ブランチ・同期を行わなかったときは、行っていないことと、
#         その理由（途中までの実行 / --only の実行 / 状態ファイルに REPO_DIR などがない）を表示する）
#
# 【前提条件】
#   - 実行する場所: 通常の実行は、作業フォルダ（sf-job.sh を実行する場所。どこでもよい。おすすめ: ~/sf のような、短い名前のフォルダ）。
#     実行した場所に admin/force-XXXX ができる。保守用のモード（--add-tier / --remove-tier / --reconnect / --status / --verify）は、force-* の中
#   - Salesforce CLI（sf）は npm 版（npm install -g @salesforce/cli）であること。起動時に sf --version の終了コードを確認し、
#     0 以外なら案内を表示して終了する（Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。
#     この確認は、--help 以外のすべてのモードで行う（sf が未インストールのとき・GitHub Actions 上では、確認しない）
#   - gh の認証ユーザーが、オーナー本人か、オーナーの組織の有効な管理者であること（【処理の流れ】3）
#   - 手動の操作が必要なもの:
#     Salesforce 組織へのブラウザログイン / GitHub Classic PAT トークンの作成（repo + workflow スコープ）/
#     Slack App の作成・Bot Token の取得 / 通知先 Slack チャンネルで Bot を招待（/invite @sf-notify-<プロジェクト名>）
#
# 【補足】
#   - 本体は、このファイル（1〜2 章・7 章の Phase のループ）と、phases/project/ の部品 4 つ（args = 3 章・start = 4〜5 章・
#     env = 6 章・finish = 8 章）に分けてある（2026-11-28。部品は、このファイルが元の章の位置で順に source する。引数は共有）。
#     Phase のスクリプト（phases/init/）とは別のフォルダ。自分を動かし直す exec は、SF_PROJECT_SELF（このファイルの場所）を使う
#   - 内部の名前（状態ファイル admin/.sf-init-XXXX.env・.progress・.lock、環境変数 SF_INIT_*、phases/init/、ログの名前を除く
#     一時ファイル）は、改名（2026-11-28。sf-init.sh → sf-project.sh）の前の名前のまま（既存の管理者フォルダを壊さないため）
#   - 開始画面（--resume N（2 以上）/ --only の指定がないとき。続き・完了済みの選択画面より前に出る）には、作るもの・
#     かかる時間の目安（30〜60 分。ブラウザでの作業と Salesforce の反映待ちを含む）・先に用意するもの・9 つのステップを表示する
#   ◆ 途中で止まったとき（続きから）
#     - Phase 2 以降が成功するたびに、admin/.sf-init-XXXX.progress を SF_INIT_DONE_PHASE=N・SF_INIT_DONE_AT で上書きする
#       （--only のとき・.sf-init-XXXX.env がないときは、記録しない）
#     - --resume N（2 以上）/ --only の指定なしで起動し、進捗が 2〜9 で、.sf-init-XXXX.env の REPO_FULL_NAME が OWNER/force-XXXX
#       （大文字・小文字は区別しない）なら、次から選ばせる（既定値はない）。選択は、【処理の流れ】3 の警告・確認と、
#       4 のロックのあとに出る
#         [1] 続きをやる: Phase 1 を実行してから、次の Phase〜10 を実行する（保存済みの入力内容を使う）。
#             進捗が 8 以上なのに、GitHub の main ブランチを確認できない（gh api の失敗を含む）ときは、終了する
#         [2] 最初からやり直す: 【処理の流れ】6 のとおり（作成済みのリポジトリ・admin フォルダは、そのまま使う）
#         [q] 中断（終了コード 1）
#     - Phase 10 は、段階（main / staging / develop）ごとに、完了を進捗に記録し、再実行では、完了した段階を、スキップする
#       （登録した Secret が、いまもあるときだけ。--only 10 では、記録も、スキップも、しない）
#   ◆ 完了済みのとき
#     - 判定: 状態ファイルが 2 つともあるときは、進捗が 10 で、REPO_FULL_NAME が OWNER/force-XXXX であること（完了の直前で止まった・完了の印を付けられなかった・以前の版が残した状態）。
#       そろっていないときは、admin/force-XXXX の origin が OWNER/force-XXXX で、完了の印（git config sf-tools.setup-complete）が 1 であること。
#       印が未設定なら、ローカルに admin ブランチがあれば完了済みとみなし、印を 1 にする。印が 0 は、やり直し中（未完了）
#     - --resume N（2 以上）/ --only の指定なしで起動したとき（続きの対象でないとき）は、次から選ばせる。状態ファイルが
#       1 つでも残っているときは、先に GitHub の main ブランチを確認し（確認できなければ終了）、後片付け（admin ブランチ・
#       push・完了の印・状態ファイルの削除。クローンが OWNER/force-XXXX のものでなければ、何もしない）を済ませる
#         [1] いまの Salesforce の接続を見る（クローンで status.sh。何も変更しない。不足があっても終了コード 0）
#         [2] 動作を確認する（クローンで verify.sh。確認は verify.sh が聞く。終了コードは verify.sh のもの）
#             [1]・[2] は、クローンのフォルダがなければ終了する（終了コード 1）
#         [3] 最初からやり直す（【処理の流れ】6。作成済みのリポジトリは、そのまま使い、設定を、上書きする）
#         [q] 終了（終了コード 0）
#     - --resume N（2 以上）と --only N は、拒否する（終了コード 1）
#   ◆ --only N と状態ファイル
#     - Phase 3〜10 のスクリプトは、Phase 2 が作る .sf-init-XXXX.env の値（REPO_FULL_NAME など）がないと、「〜が未設定です」で
#       終了する。完了済みのプロジェクトでは、--only N は、Phase を実行する前に拒否する（◆ 完了済みのとき。終了コード 1）
#   ◆ 同時実行
#     - 同じ admin・同じ XXXX で、sf-project.sh を、同時に 2 つ動かすことはできない（後から起動した方は「すでに実行中です」で終了する）。
#       admin/.sf-init-XXXX.lock（フォルダ。中に PID）で排他する。PID のプロセスがもういないときは、古いロックとして引き継ぐ。
#       ロックを取るのは【処理の流れ】4（警告・確認のあと）。保守用のモードは、ロックを取らない。
#       Phase 2 の終了コード 75 で実行しなおすときは、作業フォルダに戻り、ロックを解放してから、実行しなおす
#   ◆ 動作の確認（【処理の流れ】8c）
#     - 聞く条件: 実行範囲の終わりが Phase 10、--resume N（2 以上）/ --only の指定なし（中断後の「続きをやる」を含む）、
#       GITHUB_ACTIONS が true でない、標準入力が端末（または SF_INIT_VERIFY_ASK=1）
#     - 「動作を確認しますか？ [Enter = 確認する / s = あとで]」。Enter / Y で確認する。s / n / q と EOF は、あとで。ほかは再入力
#     - 確認するときは、管理者用のクローン（REPO_DIR）で、verify.sh（環境全体の確認 → Hello World のリリースと削除）を、
#       SF_VERIFY_CONFIRMED=1 で実行する（verify.sh の確認は出ない）。失敗しても、セットアップの失敗にはしない（完了画面に結果を出す）
#   ◆ admin フォルダ（管理者用フォルダ）
#     - 完了後も削除しない（削除の質問は廃止した）。ワークフローの更新（sf-update-workflows.sh）・--status・--reconnect などの保守に使う。
#       日常の開発には使わない（開発は、sf-job.sh の作業フォルダで行う）。完了画面に、このフォルダのパスを表示する
#     - 同じ admin に、複数のプロジェクトを置ける（状態ファイル・ロックは、XXXX ごとに分かれる）
#     - admin ブランチ: ローカルに admin があれば切り替え、なければ main から作る。動作の確認を実行し、クローンが main のときは、
#       先に git pull --ff-only origin main を行う。そのあと git push --no-verify -u origin admin（強制 push はしない）。
#       失敗しても、セットアップは成功のまま、完了画面で知らせる。admin は main から古くなる（使う前に、main を取り込む）
#     - 完了の印は、クローンの .git/config にあり、GitHub には送られない
#   ◆ sf-tools の最新化
#     - 【処理の流れ】3 で、~/sf-tools の現在のブランチが origin より遅れていないかを確認する。Git リポジトリでない・HEAD が
#       ブランチでないときは、ここでは確認しない（警告も出さない。Phase 2 が、選んだ版で確認する）。fetch できない・origin に
#       ブランチがないときは、警告して続行する。未コミットの変更か未 push のコミットがあれば、更新せずに続行する。
#       遅れていれば、確認（Y/N/q）のうえ git pull --ff-only し、同じ引数で自動的に実行しなおす
#       （N なら更新せずに続行。q・更新の失敗は終了）。実行しなおしたあとは、この確認をしない
#     - Phase 2 は、選んだ版のブランチと、現在のブランチが違えば、確認する（N / q で終了）。実行しなおしたあと（または、
#       【処理の流れ】3 で確認しなかったとき）は、Phase 2 が、選んだ版で最新化を確認する。Phase 2 が更新したとき
#       （終了コード 75）は、まだ実行しなおしていなければ、作業フォルダに戻り、ロックを解放して、同じ引数で実行しなおし
#       （警告・確認から、もう一度。通常の流れでは起きない、備えの経路）、実行しなおしたあとなら
#       「sf-tools を更新しても、最新になりませんでした。」で終了する
#   ◆ 引数の解析
#     - --only / --resume は、Phase 番号（1〜10 の整数。先頭の 0 は不可）だけを受け付ける。値なし・数字以外・範囲外は、
#       エラーで終了する（終了コード 1）。--add-tier は、次の引数（- で始まらないもの）を値として受け取り、値なしは
#       エラーで終了する（staging / develop かどうかは、add_tier.sh が確認する）。--remove-tier も同じ（remove_tier.sh が確認する）。
#       --purge-secrets は、値を取らない。--reconnect は、次の引数を値として受け取り
#       （- で始まるものも受け取る）、値なしはエラーで終了する（段階の名前かどうかは、reconnect.sh が確認する）
#     - 知らないオプションは、使い方を表示して終了する
#   ◆ そのほか
#     - Ctrl+C は、--help の判定のあと、引数の解析の前から無効（trap '' INT。子プロセスにも継承）。中断するには、ターミナルを閉じる
#     - ログ: ~/sf-tools/logs/sf-project.log（起動のたびに空にする。各 Phase は追記する）。verify.sh（--verify・動作の確認）の
#       記録は ~/sf-tools/logs/verify.log
#     - 終了コード: 0 = 成功（完了済みの選択画面の [1] / [q] を含む）/ 1 = エラー（die）/
#       --verify・--status・完了済みの [2] は、verify.sh・status.sh の終了コードを、そのまま返す
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
# sf-project.sh はプロジェクト外から実行するため、ログは sf-tools 配下に記録する
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh（run）の読み込み前の準備（意図的エラー無視）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"  # 司令塔が起動のたびにログをリセットする

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
# sf-project.sh はプロジェクト外から実行するため、force-* チェックをバイパスする
export SF_INIT_MODE=1

# 自分のファイル（部品の中から exec で動かし直すときに使う。部品の中の BASH_SOURCE[0] は、部品のファイルになるため）
readonly SF_PROJECT_SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 共通ライブラリ（第 1 引数の -h / --help も、ここで処理する: lib/common.sh の 0 章）
source "${SCRIPT_DIR}/../lib/common.sh" \
    || { echo "[FATAL ERROR] Library not found: ${SCRIPT_DIR}/../lib/common.sh" >&2; exit 1; }  # run 不使用: run の定義前
source "${SCRIPT_DIR}/../lib/wizard.sh"                 # ウィザード形式の画面の部品（doc/wizard-ux-design.md）
source "${SCRIPT_DIR}/../phases/init/init-common.sh"    # ensure_sf_tools_branch など（各フェーズと共通）
source "${SCRIPT_DIR}/../lib/verify-common.sh"           # 最初のメタデータの同期（initial_metadata_sync）が使う、ワークフローの起動・待ち

trap '' INT  # Ctrl+C を無効化（子プロセスにも継承される）

ORIG_ARGS=("$@")   # sf-tools を更新したあと、同じ引数で、実行しなおすために覚えておく（対話で決めたオーナー・XXXX は、
                   #   resolve_init_identity が export する SF_INIT_OWNER / SF_INIT_PROJECT で引き継ぐ）

# ------------------------------------------------------------------------------
# 3〜6 章: 引数・開始画面・作業フォルダ・環境の準備（phases/project/。2026-11-28 に、このファイルから分けた。読み込む順番は、元の章の順のまま）
# ------------------------------------------------------------------------------
for _part in args start env; do
    source "${SCRIPT_DIR%/*}/phases/project/${_part}.sh" \
        || die "sf-project.sh の部品を読み込めません: ${SCRIPT_DIR%/*}/phases/project/${_part}.sh"
done
unset _part

# ------------------------------------------------------------------------------
# 7. メイン実行フロー（フェーズループ）
# ------------------------------------------------------------------------------
# 通常の実行では、Phase の番号は出さない（ステップの見出しを出す）。--resume N（2 以上）/ --only のときだけ、範囲を出す
[[ "$FULL_START" -eq 1 ]] || log "INFO" "実行フェーズ: Phase ${START_PHASE} 〜 Phase ${END_PHASE}"
[[ -z "$ONLY_PHASE" ]] || log "WARNING" "--only は、指定した Phase だけを実行します。進捗は、更新しません（通常の「続きをやる」の状態は、変わりません）。"

# 続きから始める場合も、Phase 1（環境チェック。状態を持たない）は、毎回実行する
PHASE_LIST="$(seq "$START_PHASE" "$END_PHASE")"  # VAR=$(cmd) のため run 不使用
[[ "$RESUMED" -eq 1 ]] && PHASE_LIST="1 ${PHASE_LIST}"

# ステップの見出しを出す（同じステップの Phase が続くときは、最初の 1 回だけ）。引数: Phase 番号
_show_step_header() {
    local p="$1" s i done_titles=()
    s="${WIZ_PHASE_STEP[$p]}"
    [[ "$s" == "$_LAST_STEP_SHOWN" ]] && return 0
    _LAST_STEP_SHOWN="$s"
    # 完了したステップ（1〜s-1）。s = 1 のときは、ない（seq 1 0 は、macOS（BSD）では 1 0 と逆順に出るため、呼ばない）
    if [[ "$s" -gt 1 ]]; then
        for i in $(seq 1 $((s - 1))); do done_titles+=("${WIZ_STEP_TITLES[$i]}"); done
    fi
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
    bash "$phase_script"  # 対話があるため run 不使用（run は出力を一時ファイルに書き出す）。終了コードは、下で判定する
    phase_rc=$?
    if [[ $phase_rc -eq 75 ]]; then
        # sf-tools を更新した（Phase 2）。更新した sf-tools で、最初から、実行しなおす（1 回だけ。無限に繰り返さない）。
        #   実行しなおす前に、作業フォルダ（INIT_BASE）に戻り、ロックを解放する。admin/ の中のままだと、実行場所の確認で終了し、
        #   ロックが残ったままだと（exec では EXIT トラップが動かず、PID も同じ）、「すでに実行中です」で終了するため
        [[ -z "${SF_INIT_RESTARTED:-}" ]] || die "sf-tools を更新しても、最新になりませんでした。"
        export SF_INIT_RESTARTED=1
        log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
        cd "$INIT_BASE" || die "作業フォルダに移動できません: ${INIT_BASE}"
        run rm -rf "$_init_lock_dir" || die "ロックを解放できません: ${_init_lock_dir}"
        exec bash "$SF_PROJECT_SELF" "${ORIG_ARGS[@]}"  # exec のため run 不使用（このプロセスを置き換える）
    fi
    if [[ $phase_rc -ne 0 ]]; then
        # 失敗の三点セット（原因は、直前の表示。直し方は、各 Phase の表示。ここでは、やり直しの方法を、正確に出す）。
        #   --only のときは、やり直しの方法を出さずに、終了する
        if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 3 ]]; then
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-project.sh を実行し、「続きをやる」を選ぶと、「${WIZ_PHASE_TITLES[$phase_num]}」の最初から、再開します（ここまでの内容は、保存されています）"
        elif [[ -z "$ONLY_PHASE" ]]; then
            # 準備の確認・プロジェクトの確認: 保存された状態がないため、最初から、実行しなおす
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-project.sh を実行してください（最初から、始まります）"
        fi
        die "「${WIZ_PHASE_TITLES[$phase_num]}」が失敗しました。"
    fi
    # 成功した Phase を記録する（上書き。Phase 1 は、状態を持たないため、記録しない。--only・.sf-init-XXXX.env がないときは、
    #   記録しない）。上書きのため、Phase 10 が追記した段階ごとの記録（SF_INIT_DONE_TIER_*）も、ここで消える
    if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 2 && -f "$SF_INIT_ENV_FILE" ]]; then
        {
            printf 'SF_INIT_DONE_PHASE=%s\n' "$phase_num"
            printf 'SF_INIT_DONE_AT="%s"\n'  "$(date '+%Y-%m-%d %H:%M')"
        } > "$SF_INIT_PROGRESS_FILE" || die "進捗ファイルを更新できません: ${SF_INIT_PROGRESS_FILE}"
    fi
done

# ------------------------------------------------------------------------------
# 8 章: 後処理（phases/project/。2026-11-28 に、このファイルから分けた。読み込む順番は、元の章の順のまま）
# ------------------------------------------------------------------------------
for _part in finish; do
    source "${SCRIPT_DIR%/*}/phases/project/${_part}.sh" \
        || die "sf-project.sh の部品を読み込めません: ${SCRIPT_DIR%/*}/phases/project/${_part}.sh"
done
unset _part

