#!/bin/bash
# ==============================================================================
# sf-log.sh - AI の開発サイクル用に、デバッグログを手元に取り、AI 向けの要約を作る
# ==============================================================================
# 自分のユーザーのデバッグログ（ApexLog。Apex だけでなく、フロー・入力規則・重複ルールなど、1 回の処理の動きの記録）を、TraceFlag で出させて手元（logs/apex/）に保存し、AI が最初に読む要約
# （logs/apex/latest.md）を作る。ログを読むのは人ではなく AI（Claude Code など）。
# 設計: doc/sf-log-design.md（要約・一覧の検査・日時の計算は lib/apexlog.js）
#
# 【使い方】
#   sf-log.sh pull [-o ALIAS] [--max N] [--since 分]      # 新しいログを取って、要約を作る（AI が実行する。組織には書き込まない）
#   sf-log.sh status [-o ALIAS]                           # 状態を表示する（読み取りのみ）
#   sf-log.sh auto on|off [-o ALIAS]                      # sf-start のときに自動で取るか（このプロジェクトの答え）を変える
#   sf-log.sh start [-o ALIAS] [--level standard|detail] [--hours N] [-y]   # 取り始める（TraceFlag を作る・延ばす）
#   sf-log.sh stop [-o ALIAS]                             # 止める（自分が作った TraceFlag を消す）
#   sf-log.sh begin -o ALIAS --owner 印                   # 内部用（sf-start.sh が前面で呼ぶ。sf を呼ばずに判定し、準備と取得役を裏で起動する）
#   sf-log.sh start --auto [--collect [--retry N]] [--owner 印]   # 内部用（begin が裏で呼ぶ。尋ねない。--collect なら、成功のあと取得役になる）
#   sf-log.sh collect                                     # 内部用（裏の取得役。sf-start.sh が裏で起動する）
#   sf-log.sh leave --owner 印                            # 内部用（sf-start.sh の終了時。持ち主の一覧から外れる）
#
# 【オプション】
#   -o ALIAS            : 接続先の組織のエイリアス（省略時: 環境変数 SF_TARGET_ORG > sf org display の alias）
#   --level standard|detail : （start）ログの詳しさ（doc/sf-log-design.md 7 章）。既定 standard。--auto は常に standard
#   --hours N           : （start）TraceFlag の期限（時間）。1〜23 の整数（公式: 開始から 24 時間未満）。既定 2
#   -y                  : （start）AI への送信の確認と、ほかの USER_DEBUG の TraceFlag を止める確認を省く（手動のみ）
#   --auto              : （start）sf-start.sh からの自動の取り始め。終了コード 0 = 取り始めた／10 = 取らない／1 = 失敗
#   --owner 印          : （begin・start --auto・leave）持ち主（sf-start）の印。「PID:起動の時刻:環境の名前と乱数」（数字:数字:英数字。
#                         例 1234:1795500000:wsl8f3a。環境の名前は gitbash / wsl / macos / linux / unknown。doc/sf-log-design.md 5.6）
#   --collect           : （start --auto）準備が成功したら、同じプロセスで取得役（collect）になる（begin が使う）
#   --retry N           : （start --auto --collect）準備が失敗したとき（終了コード 1。「取らない」の 10 は除く）に、やり直す回数（0〜3。既定 0。
#                         begin は 1 を付ける）。持ち主が生きていて、後始末の最中でなければ、30 秒待ってから、回数を 1 減らして自分を exec する
#   --max N             : （pull）要約に入れるログの数の上限（1 以上の整数。既定 50。超えたら新しいほうから）
#   --since 分          : （pull）前回の pull を無視して、直近 N 分に始まったログを要約する（1 以上の整数）
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help          : このヘルプを表示する（1 番目の引数のときだけ）
#
# 【処理の流れ】
#   共通（status・auto 以外）:
#     0. （start のみ）sf の更新（sf-update-cli.sh。ロック ~/.sf-tools-upgrade.lock の PID が生きている）が動いていれば、
#        終わるまで最大 10 分待つ（sf の入れ替えの途中に sf を呼ぶと、部品が見つからずに失敗するため。2026-11-24。
#        sf-start は、sf-refresh.sh（その中で sf-update-cli.sh）と begin を同時に裏で動かす）。.status の WARNING に、待っていることを書く。
#        待つあいだに持ち主（--owner）がいなくなれば、準備をやめて 0 で終わる。待ち切れなければ、WARNING を出して進む
#     1a. 環境の判断（status 以外。0 より前。Git Bash と WSL の混在。doc/sf-log-design.md 5.6）: 手元のファイル（.collector・.claim）だけを
#        読み、別の環境が、このプロジェクトのログを扱っていれば、ファイル・ロック・組織に触れずに終える
#        （begin・start --auto: 終了コード 10／leave・collect: 0／start・pull・stop・auto: 中断）。別の環境が扱っている、とみなすのは:
#          a. 名乗り（.claim）の RUNTIME が自分と違い、AT が 30 分以内（読めない・未来の時刻を含む）
#          b. .collector の STARTED が 12 時間以内（読めない記録・12 時間より古い記録は、止まったもの）で、
#             RUNTIME がない（この変更の前の取得役。kill -0 によらず「環境不明」）か、RUNTIME が自分と違い、HEARTBEAT が 30 分以内（同上）
#        環境の名前（detect_runtime）は、unknown 同士でも同じとみなさない。記録の名前が 4 つ（gitbash / wsl / macos / linux）以外なら「環境不明」。
#        自分の環境が unknown のときは、この判断をしない（これまでの動き）
#     1. sf の確認（check_sf_cli --cache）・接続先の決定（get_target_org）
#     2. （start・pull）接続先が予約名（prod / staging / develop / main）・本番・種類を確認できない組織なら止める
#        （手動: 中断／--auto: 終了コード 10）
#     3. 自分のユーザー ID と組織 ID（sf org display user --json）
#   begin（sf-start の前面。sf を呼ばない。ランチャーを待たせないため）:
#     1. GitHub Actions 上・予約名 → 10
#     2. このプロジェクトの答え（logs/apex/.consent の AUTO・ORG（エイリアス）・VERSION）で判定する。「取らない」→ 10。
#        答えがない・エイリアスが変わった・注意の文面の版が変わったときは、注意を表示して Y/N で聞く（端末でない・q・N は「取らない」。
#        端末でないときは、答えを保存しない）
#     3. 持ち主の一覧に --owner の印を足す（後始末の最中なら、最大 60 秒待つ。終わらなければ 10）。同じ短いロックの中で、別の環境が
#        扱っていないかを確かめ直し（扱っていれば、何も書かずに 10）、扱う環境の名乗り（.claim の RUNTIME・OWNER・AT）を書いてから足す。
#        同じ環境の名乗りがあり、その印の持ち主が生きていれば、印は変えずに AT だけ今にする
#     4. .status を starting にし、start --auto --collect --retry 1 を nohup で裏に起動して、すぐ 0 で終わる
#        （ふつうの出力は捨て、エラー出力は sf-log.log に追記する）
#   start:
#     4. （--auto）GitHub Actions 上なら 10。尋ねない: 答え（.consent）が「取る」で、エイリアスと文面の版が同じでなければ 10。
#        答えの組織 ID（ORG_ID）が空なら、今の組織 ID を書く。違えば（同じエイリアスで別の組織に入り直した）、答えを消して 10
#        （次の sf-start の begin で聞き直す。同意のない組織のログを取らない）
#        （手動）注意を表示し、ask_yn || die（-y で省く）
#        --owner があれば、持ち主の一覧（logs/apex/.owners）に足す（同じ印は 2 回足さない。begin の 3 と同じ。名乗りも書く）。
#        後始末の最中（CLOSING）なら、終わるまで最大 60 秒待つ（CLOSING の持ち主が死んでいれば（別の環境の印を含む）消して進む。
#        待っても終わらなければ 10）
#     5. DebugLevel「sf_tools_log_<level>」を名前で探し、あれば 7 章の値で上書き、なければ作る（2 つ以上なら止める）
#     6. 自分のユーザーの TraceFlag を探す（lib/apexlog.js tflist で、有効・期限切れ・これから始まるものに分ける）
#        a. .state の TRACE_FLAG_ID と一致する USER_DEBUG → DebugLevel・開始（今）・期限（今から --hours 時間）を更新
#        b. ほかの有効な USER_DEBUG が 2 つ以上 → 止める／1 つ → 手動: 表示して確認のあと、期限を「元の期限」と
#           「今から 2 分後」の早いほうに縮める（今にはできない）。--auto: 触らずに 10
#           DEVELOPER_LOG・ほかの種類には触れない（USER_DEBUG とぶつからない）
#        c. 作る（USER_DEBUG。開始は今。b で縮めたときは、その期限の 1 秒後。それが過ぎていれば今）。
#           b で縮めたあとに作成が失敗しても、元に戻さない（縮めた ID・元の期限・縮めた期限を書く）
#     7. 組織を切り替えた（.state の ORG と違う）なら、前の組織の、sf-log.sh が作った TraceFlag を消す（消せなければ WARNING）
#        .state に組織・ユーザー ID・TraceFlag の ID を書く（組織・ユーザーが変わったら、取得と要約の時刻を今にする）
#     8. 組織のログの量を表示し、700MB を超えていれば WARNING（組織の上限は 1,000MB）
#     9. .status に STATE=collecting・期限（EXPIRES は UTC・EXPIRES_AT は PC の時刻の HH:MM。ランチャーが表示する）・
#        今日の本数（COUNT_TODAY。今日の日付のフォルダの *.log の数。前回の値を残さない）を書く。
#        --collect なら、同じプロセスで collect になる（exec）。
#     （--auto で取らない・失敗のとき）.status に理由を書き、別の組織の取得役（この環境のもの）が動いていれば、止まるよう頼む（5.3）。
#        自分の名乗り（.claim の OWNER が自分の印）は、同じ環境のほかの生きている持ち主がいなくて、この環境の取得役も動いていなければ消す
#        （別の環境を 30 分待たせない）。sf の更新を待つあいだに持ち主がいなくなって準備をやめるときも、同じく消す
#     （--retry が残っていて、失敗のとき）.status を starting に戻して WARNING（やり直しています）を書き、30 秒後にやり直す。
#        成功したら WARNING を消す。待つあいだに持ち主が終了した・後始末が始まったら、やり直さずに失敗として終わる
#   pull:
#     4. 取得役（logs/apex/.collector の PID）が生きていれば、自分では取らず、依頼（logs/apex/requests/pull.<ID>）を置いて、
#        自分の ID の応答（done.<ID>）を最大 90 秒待つ（待っても来なければ、手元にある分で要約し、その旨を書く）。
#        別の組織の取得役なら中断する。取得役がいなければ、取得のロック（logs/apex/.fetch.lock。最大 90 秒待つ）を持ち、しおり（.state の LAST_FETCH・LAST_FETCH_ID）から
#        古い順に取る（1 回 50 本。最大 4 回 = 200 本）。一覧は全ユーザーの見出し（run を通さない。他の人の ID を記録しない）、
#        本文は自分のログだけを保存する。取りたいログより新しいログがすべて自分のものなら sf apex get log -n でまとめて、
#        それ以外は -i で 1 本ずつ取る。本文は logs/apex/.fetch/ に書かせ、取りたい ID 以外は中を読まずに消す。
#        追いついたら（残りがなければ）、取得のロックを持ったまま、遅れて現れたログを拾い直す（下の「拾い直し」）
#     5. 保存: logs/apex/<日付>/<時刻>_<ID>_<操作>.log（日付・時刻は PC のタイムゾーン）と、目録 logs/apex/.index
#     6. 要約のロック（logs/apex/.read.lock。最大 90 秒）を取り、そのあとで、しおり（.state の LAST_READ_LINE・LAST_READ_ID）を読む。
#        目録は 1 回だけ読み、改行で終わる行だけを使う。選び方（開始時刻ではなく、目録に足された順）:
#          --since: しおりを使わず、目録の全行から直近 N 分に始まったログ
#          しおりが使えない（ない・形が違う・LAST_READ_ID が見つからない）・ロックが取れない: 目録の全行から直近 30 分に始まったログ（WARNING）
#          それ以外: LAST_READ_LINE 行目より後のすべての行（LAST_READ_LINE 行目の ID が LAST_READ_ID と違えば、ID で行を探し直す）
#        古い .state（LAST_READ・LAST_READ_IDS）は、開始が LAST_READ より前の行と、同じ秒で LAST_READ_IDS にある行を「見た」として移す。
#        --max を超えたら、開始時刻の新しいほう。要約の中は開始時刻の順
#     7. 要約を作り（node lib/apexlog.js summarize）、logs/apex/summaries/<時刻>.md と logs/apex/latest.md に書く
#     8. 成功したら（--since とロックが取れないときを除く）、読んだ目録の最後の行の番号と ID を LAST_READ_LINE・LAST_READ_ID にし、
#        要約のロックを外す。要約の 1 行目と latest.md のパスを表示する
#   拾い直し（取得役と pull の自分での取得。通常の取得が追いついた回に 1 回。doc/sf-log-design.md 8.3）:
#     ApexLog は処理が終わってから一覧に現れる（Id と StartTime は始まったときのもの）。長い処理のログは、しおりより前に
#     始まっていて、通常の取得では二度と取れないため、「今から 30 分前」（前の回の失敗で残した .state の LATE_FROM があれば、
#     その早いほう）から、しおりまでに始まった自分のログ（LogUserId で絞る。他の人の見出しは入らない）を、新しい順に 200 本ずつ
#     （最大 5 回 = 1,000 本）問い合わせ、目録にない ID を -i で 1 本ずつ取る（-n は使わない）。しおりは動かさない。
#     しおりが 30 分より古く、LATE_FROM もなければ、動かさない。失敗したら、その回の下限を LATE_FROM に残す（次の回にやり直す。
#     成功で消す。24 時間より古ければ消して WARNING）。1,000 本で範囲の終わりに届かなければ、限界として WARNING（LATE_FROM は消す）。
#     WARNING は sf-log.log と .status（WARNING・LATE_WARNING）に書き、pull は要約の先頭に書く
#   stop（人の判断。持ち主の一覧にかかわらず止める。別の環境の取得役には、何も送らない）:
#     4. .owners を CLOSING だけにする。取得役が生きていれば、停止の依頼（requests/stop）を置き、最大 30 秒待つ。
#        止まらなければ TERM で止め、さらに最大 10 秒待つ。それでも生きていれば、TraceFlag は消さずに中断する
#     5. .state の TRACE_FLAG_ID の TraceFlag を消す（すでになければ WARNING。消せなければ中断し、ID は残す）
#     6. TRACE_FLAG_ID・.collector・.owners を消し、.status を stopped にする（期限の表示も消す）。DebugLevel・手元のログは消さない。
#        後始末が済んだら、最後に名乗り（.claim）を消す（.owners を消したあと。別の環境は、そのあとで名乗れる）
#   leave --owner 印（sf-start の終了時）:
#     4. 持ち主の一覧から自分の印を外す。ほかの持ち主が残っていれば、何も止めずに終わる
#     5. 誰もいなければ、CLOSING を書いて、stop の 4〜6 と同じ後始末をする（名乗りも最後に消す）。失敗は WARNING だけ（終了コードは 0）
#   collect（裏の取得役。.state の組織・ユーザーで取る。出力は sf-log.log と .status だけ）:
#     4. 取得役の印（.collector）を確かめる（短いロックの中で、別の環境が扱っていないかも確かめ直す。扱っていれば 0 で終わる）:
#        同じ組織の取得役（この環境のもの）が生きていれば、何もせずに終わる。別の組織なら、止めてもらって入れ替わる。
#        印には PID・STARTED・ORG・RUNTIME（環境の名前）・HEARTBEAT（生きている合図。エポック秒）を書き、名乗りの AT も今にする
#     5. 5 秒ごとに目を覚まし、次を繰り返す（sf を呼ぶのは、取得と延長のときだけ）。目を覚ますたび・sf を呼ぶ直前・ログを 1 本保存する
#        たびに、合図（HEARTBEAT）と名乗りの AT を書き直す（30 秒より短い間隔では書かない。別の環境は、30 分途絶えたら止まったとみなす）:
#        a. 持ち主の見張り: 死んだ持ち主（kill -0）と、環境の名前が自分と違う印（前に別の環境で使ったときの残り）を一覧から外す。
#           一覧が空 → 自分で後始末（TraceFlag を消す）をして止まる。
#           起動から 12 時間（SF_LOG_MAX_SECONDS）でも、同じく止まる
#        b. 停止の依頼・CLOSING・印の入れ替わり → 組織に何もせずに止まる（延長の直前にも確かめる）
#        c. 間隔（SF_LOG_INTERVAL）が来た・pull の依頼がある・取り残しがある → 取得のロックが取れたら、pull と同じ方法で 1 回取る。
#           sf の更新（sf-update-cli.sh）が動いているあいだは、取らずに次に回す（start の 0 と同じ理由）。
#           追いついた回は、取得のロックを持ったまま拾い直し（pull の「拾い直し」）をし、目録に書き終えてから、待っている pull に応える。
#           追いついたら、待っている pull に応答する。失敗したら、次の取得までの間隔を倍にする（最大 600 秒）
#        d. TraceFlag の残りが 60 分未満なら、ID と種類を確かめてから、今から 2 時間に延ばす
#        e. 5 分より古い依頼・応答を消す
#   status: 取得役が動いているか、手元の状態（.status・.state）、持ち主の数、自分のユーザーの TraceFlag、自分のログの本数と合計を表示する（読み取りのみ）。
#     取得役の行: 別の環境が扱っていれば「別の環境（X）で動作中（最後の合図は N 秒前）」、名乗りだけなら「取得役の起動待ち」、
#     古い形・形の正しくない記録は「状態不明」。.status の ORG が接続先と違えば「状態不明」。組織に問い合わせできなくても、止めずにその旨を表示する
#   auto on|off: logs/apex/.consent の AUTO・ORG（エイリアス）・ORG_ID・VERSION を書く（組織には書き込まない）
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること
#   - Salesforce CLI（npm 版）と Node（sf に含まれる）。接続ユーザーが DebugLevel・TraceFlag を作れること
#   - 一人用の開発組織（Developer Edition・Sandbox・スクラッチ組織）で、ダミーデータで使うこと
#
# 【補足】
#   - 終了コード: 0 = 成功／1 = 失敗（手動の中断を含む）／10 = 取らない（start --auto のみ）
#   - ログには、レコードの値・SOQL の条件などが載る。AI に読ませると、AI の提供元に送られる（start の確認）
#   - 手元のログ（logs/apex/）は Git の管理外。stop も消さない。消すときは、日付のフォルダを手で消す
#   - 他の人のログは、本文を保存・記録・要約しない。sf apex get log -n の直後にできた他の人のログが
#     logs/apex/.fetch/ に一瞬書かれることがあるが、中を読まずに消す（取得のたびに空にする）
#   - sf-start.sh が、ランチャーを開く前に begin、終了時に leave を呼ぶ（5 章）。ランチャーは .status を 1 行で表示する
#   - 環境変数: SF_LOG_INTERVAL（取得の間隔。秒。30〜600。既定 180。sf の 1 回が約 10 秒かかるため。pull はすぐ取らせる）・
#     SF_LOG_MAX_SECONDS（取得役の上限。秒。既定 43200 = 12 時間）・SF_LOG_TEST_FAST=1（テスト用。間隔の下限を 1 にし、待ち時間を短くする）・
#     SF_TOOLS_UPGRADE_LOCK（sf の更新のロックの場所。既定 ~/.sf-tools-upgrade.lock。sf-update-cli.sh と同じ。テストで差し替える）・
#     SF_LOG_TEST_RUNTIME（テスト用。自分の環境の名前を決める。英小文字だけ）
#   - 持ち主の生死は kill -0 で見る（PID が使い回されたときは、12 時間の上限で止まる）。別の環境（Git Bash と WSL）の PID は見えないため、
#     環境の名前で見分ける（1a・doc/sf-log-design.md 5.6）。1 つのプロジェクトのログは、同時には 1 つの環境だけが扱う
#   - ロック（.lock・.fetch.lock・.read.lock。mkdir）の pid ファイルは「PID 環境 取った時刻（エポック秒）」の 1 行（一時ファイルから置き換える）。
#     同じ環境（または環境のない古い形）なら PID が死んでいれば、別の環境なら取った時刻から 10 分より古ければ、残ったロックとして消す。
#     pid ファイルがない・形が違う・時刻が未来のロックは、奪わずに、それぞれの上限まで待つ
#   - ログ: ./sf-tools/logs/sf-log.log（追記）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"   # pull・start・stop が同じログに書く（取得の記録を残す）

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
source "${SCRIPT_DIR}/../lib/org.sh"   # org_local_release_check（組織の種類の確認）

# ------------------------------------------------------------------------------
# 3. 定数・引数
# ------------------------------------------------------------------------------
readonly AJS="${SCRIPT_DIR}/../lib/apexlog.js"
readonly APEX_DIR="logs/apex"
readonly STATE_F="${APEX_DIR}/.state"
readonly STATUS_F="${APEX_DIR}/.status"
readonly CONSENT_F="${APEX_DIR}/.consent"
readonly OWNERS_F="${APEX_DIR}/.owners"
readonly COLLECTOR_F="${APEX_DIR}/.collector"
readonly INDEX_F="${APEX_DIR}/.index"
readonly LOCK_DIR="${APEX_DIR}/.lock"
readonly FETCH_LOCK="${APEX_DIR}/.fetch.lock"
readonly FETCH_TMP="${APEX_DIR}/.fetch"
readonly READ_LOCK="${APEX_DIR}/.read.lock"   # 要約のロック（pull が、しおりを読んでから書くまで。4.4 の 3）
readonly CLAIM_F="${APEX_DIR}/.claim"         # 扱う環境の名乗り（5.6。begin・start --auto が書き、取得役が AT を書き直す）
readonly MIX_STALE=1800 FOREIGN_LOCK_AGE=600   # 5.6: 別の環境の合図・名乗りは 30 分、別の環境のロックは 10 分で、古いとみなす
readonly LATE_WINDOW=1800 LATE_PAGE=200 LATE_MAX_PAGES=5 LATE_MAX_AGE=86400   # 拾い直し（8.3）: 30 分・200 本ずつ・最大 5 回・LATE_FROM は 24 時間まで
readonly REQ_DIR="${APEX_DIR}/requests"
readonly CONSENT_VERSION="1"            # AI への送信の注意の文面の版（変えたら上げる。10.2）
readonly ORG_LOG_WARN_BYTES=$((700 * 1024 * 1024))
readonly ID_RE='^[A-Za-z0-9]{15}([A-Za-z0-9]{3})?$'
readonly ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

CMD="${1:-}"
[[ -n "$CMD" ]] || die "サブコマンドを指定してください（pull / status / auto / start / stop / collect / leave / begin）。"
shift
AUTO_ARG=""
if [[ "$CMD" == "auto" ]]; then
    AUTO_ARG="${1:-}"
    [[ "$AUTO_ARG" == "on" || "$AUTO_ARG" == "off" ]] || die "auto には on か off を指定してください。"
    shift
fi
ORG_ARG=""; LEVEL="standard"; HOURS=2; YES=0; AUTO=0; OWNER=""; MAX_LOGS=50; SINCE_MIN=""; COLLECT_AFTER=0; RETRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)        [[ -n "${2:-}" && "${2:-}" != -* ]] || die "-o の値（組織のエイリアス）がありません。"; ORG_ARG="$2"; shift ;;
        --level)   LEVEL="${2:-}"; shift ;;
        --hours)   HOURS="${2:-}"; shift ;;
        -y)        YES=1 ;;
        --auto)    AUTO=1 ;;
        --collect) COLLECT_AFTER=1 ;;
        --retry)   RETRY="${2:-}"; shift ;;
        --owner)   OWNER="${2:-}"; shift ;;
        --max)     MAX_LOGS="${2:-}"; shift ;;
        --since)   SINCE_MIN="${2:-}"; shift ;;
        -v|--verbose) : ;;   # SILENT_EXEC は common.sh が設定済み
        *)         die "不明なオプションです: $1" ;;
    esac
    shift
done
case "$CMD" in
    start|pull|stop|status|auto|collect|leave|begin) ;;
    *) die "不明なサブコマンドです: ${CMD}（pull / status / auto / start / stop / collect / leave / begin）" ;;
esac
[[ ( "$CMD" != "leave" && "$CMD" != "begin" ) || -n "$OWNER" ]] || die "${CMD} には --owner が要ります。"
[[ "$CMD" != "begin" || -n "$ORG_ARG" ]] || die "begin には -o が要ります。"
[[ $COLLECT_AFTER -eq 0 || $AUTO -eq 1 ]] || die "--collect は start --auto だけに付けられます。"
[[ "$RETRY" =~ ^[0-3]$ ]] || die "--retry は 0〜3 の整数です: ${RETRY}"
[[ "$RETRY" -eq 0 || $COLLECT_AFTER -eq 1 ]] || die "--retry は start --auto --collect だけに付けられます。"
[[ "$LEVEL" == "standard" || "$LEVEL" == "detail" ]] || die "--level は standard か detail です: ${LEVEL}"
[[ "$HOURS" =~ ^[0-9]+$ && "$HOURS" -ge 1 && "$HOURS" -le 23 ]] || die "--hours は 1〜23 の整数です: ${HOURS}"
[[ "$MAX_LOGS" =~ ^[0-9]+$ && "$MAX_LOGS" -ge 1 ]] || die "--max は 1 以上の整数です: ${MAX_LOGS}"
[[ -z "$SINCE_MIN" || ( "$SINCE_MIN" =~ ^[0-9]+$ && "$SINCE_MIN" -ge 1 ) ]] || die "--since は 1 以上の整数（分）です: ${SINCE_MIN}"
[[ -z "$OWNER" || "$OWNER" =~ ^[0-9]+:[0-9]+:[A-Za-z0-9]+$ ]] || die "--owner の形が正しくありません: ${OWNER}"
if [[ $AUTO -eq 1 ]]; then
    [[ "$CMD" == "start" ]] || die "--auto は start だけに付けられます。"
    LEVEL="standard"; YES=0
fi
# 取得役の時間（4.3）。SF_LOG_TEST_FAST=1 はテスト用（下限を外し、目を覚ます間隔と待ち時間を短くする）
_fast=0; [[ "${SF_LOG_TEST_FAST:-}" == "1" ]] && _fast=1
INTERVAL="${SF_LOG_INTERVAL:-180}"      # 取得の間隔（秒）。sf の 1 回が約 10 秒かかるため、既定 180（2026-11-23。pull はすぐ取らせる）
_min_iv=30; [[ $_fast -eq 1 ]] && _min_iv=1
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge $_min_iv && "$INTERVAL" -le 600 ]] || die "SF_LOG_INTERVAL は ${_min_iv}〜600（秒）の整数です: ${INTERVAL}"
TICK=5; [[ $_fast -eq 1 ]] && TICK=1    # 取得役が目を覚ます間隔（秒。sf は呼ばない）
MAX_RUN="${SF_LOG_MAX_SECONDS:-43200}"  # 取得役の上限（秒。12 時間。PID の再利用への備え。5.5）
[[ "$MAX_RUN" =~ ^[0-9]+$ && "$MAX_RUN" -ge 1 ]] || die "SF_LOG_MAX_SECONDS は 1 以上の整数です: ${MAX_RUN}"
PULL_WAIT=90; STOP_WAIT=30; CLOSING_WAIT=60; RETRY_WAIT=30   # RETRY_WAIT: 裏の準備の失敗から、やり直すまで（秒）
UPGRADE_WAIT=600   # sf の更新（sf-update-cli.sh）が終わるのを待つ上限（秒）。WSL の実機で、sf の入れ替えに約 3 分かかった（2026-11-24）
READ_TRIES=450     # 要約のロックを待つ回数（0.2 秒ごと。最大 90 秒）
[[ $_fast -eq 1 ]] && { PULL_WAIT=30; STOP_WAIT=10; CLOSING_WAIT=10; RETRY_WAIT=1; UPGRADE_WAIT=10; READ_TRIES=10; }
# sf の更新のロック（sf-update-cli.sh が、動いているあいだ PID を書く。場所は sf-update-cli.sh と同じ）
UPGRADE_LOCK="${SF_TOOLS_UPGRADE_LOCK:-${HOME}/.sf-tools-upgrade.lock}"
# 動いている環境（5.6。gitbash / wsl / macos / linux / unknown）。SF_LOG_TEST_RUNTIME はテスト用（別の環境の代わりをする）
RUNTIME_SELF=$(detect_runtime)  # VAR=$(cmd) のため run 不使用
[[ -n "${SF_LOG_TEST_RUNTIME:-}" ]] && RUNTIME_SELF="$SF_LOG_TEST_RUNTIME"
[[ "$RUNTIME_SELF" =~ ^[a-z]+$ ]] || die "環境の名前の形が正しくありません: ${RUNTIME_SELF}"
HB_EVERY=30; [[ $_fast -eq 1 ]] && HB_EVERY=1   # 取得役が合図（HEARTBEAT）を書く最短の間隔（秒。目安の 30 分より十分に短い）
IS_COLLECTOR=0; HB_LAST=0
command -v node >/dev/null 2>&1 || die "node が見つかりません（sf CLI の npm 版に必要です）。"  # 存在確認のため run 不使用
mkdir -p "$APEX_DIR"  # run 不使用: 自分の作業フォルダを作るだけ（失敗は、次の書き込みで分かる）

# ------------------------------------------------------------------------------
# 4. 小さな部品
# ------------------------------------------------------------------------------
# キー=値 のファイルから 1 つ読む（source しない。決まったキーだけ）
kv_get() {
    local f="$1" k="$2" line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "$k="* ]]; then printf '%s' "${line#*=}"; return 0; fi
    done < "$f"
}

# キー=値 のファイルの、指定したキーだけを差し替える（一時ファイルに書いてから mv。短いロックの中で呼ぶ）
#   引数: ファイル KEY=VALUE ...（値に改行を入れない）
kv_set() {
    local f="$1"; shift
    local tmp="${f}.tmp.$$" line kv skip
    : > "$tmp" || return 1
    if [[ -f "$f" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            skip=0
            for kv in "$@"; do [[ "$line" == "${kv%%=*}="* ]] && skip=1; done
            [[ $skip -eq 1 ]] || printf '%s\n' "$line" >> "$tmp"
        done < "$f"
    fi
    for kv in "$@"; do printf '%s\n' "${kv//$'\n'/ }" >> "$tmp"; done
    mv -f "$tmp" "$f"
}

# ロック（mkdir。macOS に flock がないため）。中の pid ファイルに「PID 環境 取った時刻（エポック秒）」を書く（5.6）。
#   古いロックとして消すのは、次のときだけ: 環境が自分と同じ（または環境のない古い形）で、その PID が死んでいる／
#   環境が自分と違い、取った時刻から 10 分より古い（別の環境の PID は見えないため）。
#   pid ファイルがない・形が違う・時刻が未来のロックは、奪わずに待つ（上限まで待って取れなければ 1）
#   引数: フォルダ 待つ回数（0.2 秒ごと）。取れなければ 1
lock_take() {
    local d="$1" tries="$2" i=0 line
    while ! mkdir "$d" 2>/dev/null; do  # 条件チェックのため run 不使用（作れたら自分のもの）
        line=$(cat "$d/pid" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
        if lock_is_stale "$line"; then
            rm -rf "$d" 2>/dev/null || true   # 意図的エラー無視: 古いロック（ほかの人が先に消すこともある）
            continue
        fi
        i=$((i + 1))
        [[ $i -ge $tries ]] && return 1
        sleep 0.2  # run 不使用: 待つだけ
    done
    # 一時ファイルに書いてから置き換える（書きかけの pid ファイルを、ほかの人に読ませない）
    printf '%s %s %s\n' "$$" "$RUNTIME_SELF" "$(date +%s)" > "$d/pid.tmp.$$" && mv -f "$d/pid.tmp.$$" "$d/pid"
}
# ロックの pid ファイルの 1 行から、古いロックかを判断する（lock_take）。古い = 0
lock_is_stale() {
    local pid rt at rest now
    read -r pid rt at rest <<< "$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -z "$rt" || "$RUNTIME_SELF" == "unknown" ]] || same_rt "$rt"; then
        ! kill -0 "$pid" 2>/dev/null   # 条件チェックのため run 不使用（同じ環境・古い形: 持ち主の生死）
        return
    fi
    [[ "$at" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    [[ $at -le $now && $((now - at)) -gt $FOREIGN_LOCK_AGE ]]
}
lock_drop() { rm -rf "$1" 2>/dev/null || true; }  # 意図的エラー無視: 自分のロックを外すだけ

# .state などを書き換える（短いロックの中で kv_set）
state_set() {
    local f="$1"; shift
    lock_take "$LOCK_DIR" 50 || { log "WARNING" "手元の状態のロックを取れませんでした（${LOCK_DIR}）。"; return 1; }
    kv_set "$f" "$@"; local rc=$?
    lock_drop "$LOCK_DIR"
    return $rc
}

aj() { node "$AJS" "$@"; }   # lib/apexlog.js（境界は 1 か所）
now_z() { aj time now; }
# UTC の日時を、PC のタイムゾーンの HH:MM にする（ランチャーの表示用。ランチャーは日時を計算しない）
local_hm() {
    local t
    t=$(aj time local "$1" 2>/dev/null) || return 0  # VAR=$(cmd) のため run 不使用
    t="${t#*$'\t'}"
    printf '%s:%s' "${t:0:2}" "${t:2:2}"
}
# 今日（PC の日付）の保存済みのログの本数（ランチャーの「今日 N 本」。begin と取得役で同じ数え方にする）
count_today() {
    find "${APEX_DIR}/$(date +%Y%m%d)" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' '
}

# 失敗・取らないときの終わり方。手動: die（取らない理由も中断）／--auto: .status に書いて、終了コードで返す
#   引数: 終了コード（1 / 10） 理由
finish_auto_or_die() {
    local code="$1" reason="$2"
    if [[ $AUTO -eq 1 ]]; then
        # 別の組織の取得役が動いていれば、止まるよう頼む（つないでいない組織のログを取り続けないため。5.3。待たない）
        local cpid; cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
        if pid_alive "$cpid" && [[ -n "${TARGET_ORG:-}" && "$(kv_get "$COLLECTOR_F" ORG)" != "$TARGET_ORG" ]]; then
            mkdir -p "$REQ_DIR" && : > "${REQ_DIR}/stop"
        fi
        if [[ "$code" -eq 10 ]]; then
            log "INFO" "デバッグログは取りません（${reason}）。"
            state_set "$STATUS_F" "STATE=skipped" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true   # 意図的エラー無視: 表示用
        else
            retry_prepare "$reason"   # やり直せるときは、ここで exec する（戻らない）。やり直さないときだけ、下へ進む
            log "WARNING" "デバッグログを取れませんでした（${reason}）。"
            state_set "$STATUS_F" "STATE=error" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true      # 意図的エラー無視: 表示用
        fi
        claim_release   # 取得役が立たない: 自分の名乗りを消す（5.6。別の環境を 30 分待たせない）
        exit "$code"
    fi
    die "$reason"
}

# 別の環境が扱っているときの終わり方（5.6）。.status・.owners・名乗りに触れない（扱っている環境の表示を、上書きしない）
#   begin・start --auto: 終了コード 10／leave・collect: 0／それ以外（start・pull・stop・auto）: 中断
refuse_other_runtime() {
    case "$CMD" in
        begin|start)
            if [[ "$CMD" == "begin" || $AUTO -eq 1 ]]; then
                log "INFO" "別の環境（${OTHER_RT}）で、デバッグログを取っています。この環境では取りません。"
                exit 10
            fi ;;
        leave)   log "INFO" "別の環境（${OTHER_RT}）で、デバッグログを取っています。この環境では何もしません。"; exit 0 ;;
        collect) note_log "取得役: 別の環境（${OTHER_RT}）が扱っているため、起動しません"; exit 0 ;;
    esac
    die "別の環境（${OTHER_RT}）で、デバッグログを取っています。"
}

# 持ち主（--owner の sf-start）が、まだ一覧にいて生きているか。後始末の最中（CLOSING）なら、いないとみなす
owner_present() {
    [[ -n "$OWNER" ]] || return 1
    grep -qxF -- "$OWNER" "$OWNERS_F" 2>/dev/null || return 1   # 条件チェックのため run 不使用
    [[ -z "$(kv_get "$OWNERS_F" CLOSING)" ]] || return 1
    pid_alive "${OWNER%%:*}"
}

# 裏の準備（begin が起動した start --auto --collect --retry N）の失敗を、やり直す（sf の一時的な失敗で、その日の取得が抜けないため。
#   2026-11-23 に実機で、sf 自身の読み込みエラー（MODULE_NOT_FOUND）で準備が 1 回失敗し、2 回目の起動では通った）。
#   「取らない」判断（終了コード 10）は、やり直さない（finish_auto_or_die が、終了コード 1 のときだけ呼ぶ）。
#   持ち主がもういない・後始末の最中なら、やり直さない（戻り値 1）。やり直すときは、残りの回数を 1 減らして exec する（戻らない）
retry_prepare() {
    local reason="$1"
    [[ $AUTO -eq 1 && $COLLECT_AFTER -eq 1 && $RETRY -gt 0 && -n "$ORG_ARG" ]] || return 1
    owner_present || return 1
    log "WARNING" "デバッグログの準備に失敗しました（${reason}）。${RETRY_WAIT} 秒後に、もう一度やります。"
    state_set "$STATUS_F" "STATE=starting" "ORG=${ORG_ARG}" "REASON=" "WARNING=準備に失敗しました（${reason}）。やり直しています" || true   # 意図的エラー無視: 表示用
    sleep "$RETRY_WAIT"  # run 不使用: 待つだけ（sf の一時的な失敗が収まるのを待つ）
    owner_present || { log "INFO" "待つあいだに sf-start が終了したため、やり直しません。"; return 1; }
    exec bash "${SCRIPT_DIR}/sf-log.sh" start --auto --collect -o "$ORG_ARG" --owner "$OWNER" --retry $((RETRY - 1))
}

# sf の --json の応答から name を読む（読めなければ「不明」）
sf_err_name() { local n; n=$(json_get "$1" name 2>/dev/null) || n=""; printf '%s' "${n:-不明}"; }  # VAR=$(cmd) のため run 不使用

# プロセスが生きているか（kill -0。PID が使い回されたときは「生きている」に見えるため、取得役は 12 時間で必ず止まる。5.5）
pid_alive() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }  # 条件チェックのため run 不使用

# ---- 環境の混在（5.6）。1 つのプロジェクトのログは、同時には 1 つの環境だけが扱う ----
# 記録の環境の名前が、決まった 4 つのどれかか（unknown・空・不正な値は「環境不明」）
rt_known() { case "$1" in gitbash|wsl|macos|linux) return 0 ;; esac; return 1; }
# 記録の環境が、自分と同じか（unknown は、unknown 同士でも同じとみなさない）
same_rt() { [[ "$RUNTIME_SELF" != "unknown" && "$1" == "$RUNTIME_SELF" ]]; }
# 表示用の環境の名前
rt_label() { if rt_known "$1"; then printf '%s' "$1"; elif [[ -z "$1" ]]; then printf '不明（古い形の記録）'; else printf '不明'; fi; }
# 持ち主の印（PID:起動の時刻:環境の名前と乱数）が生きているか。環境の名前が自分と違う印は、生きていないとみなす
#   （別の環境の PID は、自分の環境の kill -0 では分からない。名乗りのない別の環境は、印を登録しないため、残りだけ）。
#   環境の名前のない古い印は、これまでどおり kill -0。自分の環境が unknown のときは、環境を見ない（これまでの動き）
mark_alive() {
    local r="${1##*:}" rt=""
    case "$r" in gitbash*) rt=gitbash ;; wsl*) rt=wsl ;; macos*) rt=macos ;; linux*) rt=linux ;; unknown*) rt=unknown ;; esac
    if [[ -n "$rt" && "$RUNTIME_SELF" != "unknown" ]] && ! same_rt "$rt"; then return 1; fi
    pid_alive "${1%%:*}"
}
# 取得役の PID（この環境のものだけ。別の環境の記録なら空。環境の記録のない古い形は、これまでどおり PID を出す）。
#   別の環境の PID に、kill -0・TERM を使わないため（たまたま同じ番号の、関係のないプロセスがある）
collector_pid_local() {
    local rt; rt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$rt" && "$RUNTIME_SELF" != "unknown" ]] && ! same_rt "$rt"; then return 0; fi
    kv_get "$COLLECTOR_F" PID
}
# 時刻（エポック秒）が、今から sec 秒以内か。読めない・未来の時刻も「以内」とみなす（分からないものは、扱っているかもしれない側に倒す）
#   引数: 時刻 秒 今
_recent() { [[ ! "$1" =~ ^[0-9]+$ ]] || [[ $1 -gt $3 ]] || [[ $(($3 - $1)) -le $2 ]]; }
# 別の環境が、このプロジェクトのログを扱っているか（5.6 の判断。上から順に見る）。扱っている = 0。
#   結果: OTHER_RT（表示用の環境の名前）・OTHER_AGO（最後の合図・名乗りから何秒前か。分からなければ空）・OTHER_SRC（claim / collector）
#   自分の環境が unknown のときは、判断しない（1 を返す。これまでの動き）
other_runtime_active() {
    local now rt at started hb
    OTHER_RT=""; OTHER_AGO=""; OTHER_SRC=""
    [[ "$RUNTIME_SELF" == "unknown" ]] && return 1
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    # 1. 名乗り（.claim）が別の環境で、30 分以内（読めない・未来の時刻を含む）
    if [[ -f "$CLAIM_F" ]]; then
        rt=$(kv_get "$CLAIM_F" RUNTIME); at=$(kv_get "$CLAIM_F" AT)  # VAR=$(cmd) のため run 不使用
        if ! same_rt "$rt" && _recent "$at" "$MIX_STALE" "$now"; then
            OTHER_RT=$(rt_label "$rt"); OTHER_SRC="claim"
            [[ "$at" =~ ^[0-9]+$ && $at -le $now ]] && OTHER_AGO=$((now - at))
            return 0
        fi
    fi
    # 2. 取得役の記録がない
    [[ -f "$COLLECTOR_F" ]] || return 1
    # 3. 起動の時刻が読めない・12 時間（取得役の上限）より古い → 止まったものとみなす
    started=$(kv_get "$COLLECTOR_F" STARTED)  # VAR=$(cmd) のため run 不使用
    [[ "$started" =~ ^[0-9]+$ ]] || return 1
    [[ $started -le $now && $((now - started)) -ge $MAX_RUN ]] && return 1
    rt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    # 4. 環境の記録がない（この変更の前の取得役）→ kill -0 によらず「環境不明が扱っている」
    if [[ -z "$rt" ]]; then OTHER_RT=$(rt_label ""); OTHER_SRC="collector"; return 0; fi
    # 5. 自分と同じ環境 → これまでどおり（kill -0 は、呼び出し側が見る）
    same_rt "$rt" && return 1
    # 6. 別の環境 → 合図が 30 分以内（読めない・未来の時刻を含む）なら、扱っている
    hb=$(kv_get "$COLLECTOR_F" HEARTBEAT)  # VAR=$(cmd) のため run 不使用
    _recent "$hb" "$MIX_STALE" "$now" || return 1
    OTHER_RT=$(rt_label "$rt"); OTHER_SRC="collector"
    [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && OTHER_AGO=$((now - hb))
    return 0
}
# 持ち主の一覧に、指定した印のほかに、同じ環境の生きている印があるか（名乗りを消すかの判断）。ある = 0
same_env_owner_other() {
    local line
    [[ -f "$OWNERS_F" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" && "$line" != CLOSING=* && "$line" != "$1" ]] || continue
        mark_alive "$line" && return 0
    done < "$OWNERS_F"
    return 1
}
# 名乗り（.claim）を書く・書き直す（短いロック .lock の中で呼ぶ）。引数: 印 今
#   同じ環境の名乗りがあり、その印の持ち主が生きていれば、印は変えずに AT だけ今にする（入れ子・2 つ目の sf-start）
claim_write_locked() {
    local mark="$1" now="$2" cown
    if [[ -f "$CLAIM_F" ]] && same_rt "$(kv_get "$CLAIM_F" RUNTIME)"; then
        cown=$(kv_get "$CLAIM_F" OWNER)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$cown" ]] && grep -qxF -- "$cown" "$OWNERS_F" 2>/dev/null && mark_alive "$cown"; then  # 条件チェックのため run 不使用
            kv_set "$CLAIM_F" "AT=${now}"
            return
        fi
    fi
    kv_set "$CLAIM_F" "RUNTIME=${RUNTIME_SELF}" "OWNER=${mark}" "AT=${now}"
}
# 取り始めに失敗して取得役が立たないときに、自分の名乗りを消す（start --auto・begin の失敗。5.6）。
#   消すのは、名乗りの印が自分の印で、同じ環境のほかの生きている持ち主がいなくて、この環境の取得役も動いていないときだけ
claim_release() {
    [[ -n "$OWNER" && -f "$CLAIM_F" ]] || return 0
    lock_take "$LOCK_DIR" 50 || return 0
    if [[ "$(kv_get "$CLAIM_F" OWNER)" == "$OWNER" ]] && ! same_env_owner_other "$OWNER" && ! pid_alive "$(collector_pid_local)"; then
        rm -f "$CLAIM_F" 2>/dev/null || true   # 意図的エラー無視: 消せなくても、30 分で古いとみなされる
    fi
    lock_drop "$LOCK_DIR"
}
# 取得役の生きている合図（.collector の HEARTBEAT）と、名乗りの AT を書き直す（5.6）。取得役のときだけ。
#   目を覚ますたび・sf を呼ぶ直前・ログを 1 本保存するたびに呼ぶ（HB_EVERY 秒より短い間隔では書かない）
heartbeat() {
    local now
    [[ $IS_COLLECTOR -eq 1 ]] || return 0
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    [[ $((now - HB_LAST)) -ge $HB_EVERY ]] || return 0
    lock_take "$LOCK_DIR" 5 || return 0   # 取れなければ、次の機会に書く
    if [[ "$(kv_get "$COLLECTOR_F" PID)" == "$$" ]]; then   # 後始末で消えた印を、書き直して作り直さない
        kv_set "$COLLECTOR_F" "HEARTBEAT=${now}"
        claim_refresh_locked "$now"
    fi
    lock_drop "$LOCK_DIR"
    HB_LAST=$now
}
# 取得役が、名乗りの AT を書き直す（短いロックの中）。名乗りがない・古い別の環境のものなら、自分の環境で書く。
#   新しい別の環境の名乗りには触れない
claim_refresh_locked() {
    local now="$1" rt
    rt=$(kv_get "$CLAIM_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    if [[ -f "$CLAIM_F" ]] && same_rt "$rt"; then
        kv_set "$CLAIM_F" "AT=${now}"
    elif [[ ! -f "$CLAIM_F" ]] || ! _recent "$(kv_get "$CLAIM_F" AT)" "$MIX_STALE" "$now"; then
        kv_set "$CLAIM_F" "RUNTIME=${RUNTIME_SELF}" "OWNER=$$:$(date +%s):collector" "AT=${now}"
    fi
}

# sf の更新（sf-update-cli.sh）が動いているか（ロックの PID が生きている）。sf の入れ替えの途中に sf を呼ばないため（2026-11-24）
upgrade_running() { pid_alive "$(kv_get "$UPGRADE_LOCK" PID)"; }

# sf の更新が終わるのを待つ（start の最初。最大 UPGRADE_WAIT 秒）。待つあいだに持ち主がいなくなれば、準備をやめて 0 で終わる。
#   2026-11-24 に WSL の実機で、sf-start が裏で動かす sf-update-cli.sh（npm install -g @salesforce/cli@latest）と、裏の準備が重なり、
#   sf の部品が見つからずに準備が失敗した。やり直しでは、入れ替えの途中で消えていた WSL の sf の代わりに、PATH の後ろの
#   Windows の sf を拾い、とても遅くなった
wait_sf_upgrade() {
    local waited=0
    upgrade_running || return 0
    log "INFO" "sf の更新（sf-update-cli.sh）が終わるのを待ちます（最大 ${UPGRADE_WAIT} 秒）..."
    [[ $AUTO -eq 1 ]] && { state_set "$STATUS_F" "WARNING=sf の更新が終わるのを待っています" || true; }   # 意図的エラー無視: 表示用
    while upgrade_running; do
        if [[ -n "$OWNER" ]] && ! owner_present; then
            log "INFO" "待つあいだに sf-start が終了したため、準備をやめます。"
            claim_release   # 取得役が立たない: 自分の名乗りを消す（5.6）
            exit 0
        fi
        if [[ $waited -ge $UPGRADE_WAIT ]]; then
            log "WARNING" "sf の更新が ${UPGRADE_WAIT} 秒たっても終わりません。待たずに進みます。"
            return 0
        fi
        sleep "$TICK"  # run 不使用: 待つだけ
        waited=$((waited + TICK))
    done
    log "INFO" "sf の更新が終わりました（${waited} 秒待ちました）。"
    return 0
}

# 持ち主の一覧（.owners）から、死んだ持ち主（と、別の環境の印。5.6）を外す（短いロックの中）。出力: 生きている持ち主の数。後始末の最中（CLOSING）なら -1
owners_prune() {
    local line alive=() dead=0 closing="" tmp="${OWNERS_F}.tmp.$$"
    lock_take "$LOCK_DIR" 50 || { echo "?"; return 1; }
    if [[ -f "$OWNERS_F" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -n "$line" ]] || continue
            if [[ "$line" == CLOSING=* ]]; then closing="$line"; continue; fi
            if mark_alive "$line"; then alive+=("$line"); else dead=1; fi   # 別の環境の印は、残りとして外す（5.6）
        done < "$OWNERS_F"
        if [[ $dead -eq 1 ]]; then
            : > "$tmp"
            [[ -n "$closing" ]] && printf '%s\n' "$closing" >> "$tmp"
            [[ ${#alive[@]} -gt 0 ]] && printf '%s\n' "${alive[@]}" >> "$tmp"
            mv -f "$tmp" "$OWNERS_F"
        fi
    fi
    lock_drop "$LOCK_DIR"
    if [[ -n "$closing" ]]; then echo "-1"; else echo "${#alive[@]}"; fi
}

# 持ち主の一覧から 1 行を外し、残りの持ち主（CLOSING 以外）の数を出す（短いロックの中で呼ぶ）。引数: 外す行（空なら外さない）
owners_remove_locked() {
    local rm_line="$1" line n=0 tmp="${OWNERS_F}.tmp.$$"
    : > "$tmp"
    if [[ -f "$OWNERS_F" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -n "$line" && "$line" != "$rm_line" ]] || continue
            printf '%s\n' "$line" >> "$tmp"
            [[ "$line" == CLOSING=* ]] || n=$((n + 1))
        done < "$OWNERS_F"
    fi
    mv -f "$tmp" "$OWNERS_F"
    echo "$n"
}

# 持ち主の一覧に、自分の印を足す（5.1 の b。begin・start --auto --owner）。後始末の最中（CLOSING）なら、終わるまで最大 60 秒待つ。
#   CLOSING の印の持ち主が死んでいれば（別の環境の印を含む）、古いものとして消して進む。
#   同じロックの中で、別の環境が扱っていないかを、もう一度確かめ（5.6）、扱う環境の名乗り（.claim）を書いてから、印を足す。
#   戻り値: 0 = 足した／1 = 足せない（後始末が終わらない・ロックが取れない）／2 = 別の環境が扱っている（何も書かない）
register_owner() {
    local mark="$1" waited=0 closing
    while true; do
        lock_take "$LOCK_DIR" 50 || return 1
        if other_runtime_active; then lock_drop "$LOCK_DIR"; return 2; fi   # 後始末の最中の別の環境も、名乗りが残るため、ここで分かる
        closing=$(kv_get "$OWNERS_F" CLOSING)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$closing" ]] && mark_alive "$closing"; then
            lock_drop "$LOCK_DIR"
            [[ $waited -ge $((CLOSING_WAIT * 5)) ]] && return 1
            waited=$((waited + 1)); sleep 0.2  # run 不使用: 後始末が終わるのを待つだけ
            continue
        fi
        [[ -n "$closing" ]] && owners_remove_locked "CLOSING=${closing}" >/dev/null
        claim_write_locked "$mark" "$(date +%s)"
        if ! grep -qxF -- "$mark" "$OWNERS_F" 2>/dev/null; then  # 条件チェックのため run 不使用（同じ印を 2 回足さない。入れ子の sf-start）
            printf '%s\n' "$mark" >> "$OWNERS_F"
        fi
        lock_drop "$LOCK_DIR"
        return 0
    done
}

# 取得役に止まるよう頼み、止まるのを待つ（4.5 の 1）。止まった・いない = 0／止まらない = 1
stop_collector() {
    local pid i
    pid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用（別の環境の PID には、何も送らない。5.6）
    pid_alive "$pid" || return 0
    [[ "$pid" == "$$" ]] && return 0
    mkdir -p "$REQ_DIR" && : > "${REQ_DIR}/stop"
    for ((i = 0; i < STOP_WAIT; i++)); do
        pid_alive "$pid" || { rm -f "${REQ_DIR}/stop"; return 0; }
        sleep 1  # run 不使用: 止まるのを待つだけ
    done
    kill -TERM "$pid" 2>/dev/null || true  # 意図的エラー無視: すでに止まっていることがある
    for ((i = 0; i < 10; i++)); do
        pid_alive "$pid" || { rm -f "${REQ_DIR}/stop"; return 0; }
        sleep 1  # run 不使用: 止まるのを待つだけ
    done
    return 1
}

# 後始末（4.5 の 1〜4。stop・leave・取得役の自分の後始末）。引数: 理由（.status の REASON）・self（取得役自身なら 1）
#   戻り値: 0 = 済んだ／1 = 取得役が止まらない（TraceFlag は残した）／2 = TraceFlag を消せなかった（ID は残した）
do_cleanup() {
    local reason="$1" self="${2:-0}" org tf j name
    if [[ "$self" != "1" ]] && ! stop_collector; then
        log "WARNING" "取得役が止まりません（PID $(kv_get "$COLLECTOR_F" PID)）。TraceFlag は残しました（最大 2 時間で切れます）。"
        state_set "$STATUS_F" "STATE=error" "REASON=取得役が止まりません" || true   # 意図的エラー無視: 表示用
        return 1
    fi
    org=$(kv_get "$STATE_F" ORG); tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ -n "$ORG_ARG" ]] && org="$ORG_ARG"   # 消す先は、TraceFlag を作った組織（.state の ORG）。-o があれば、それ
    if [[ "$tf" =~ $ID_RE ]]; then
        check_sf_cli --cache
        if [[ -z "$org" ]]; then org=$(get_target_org "") || { log "WARNING" "接続先の組織エイリアスを特定できません。"; return 2; }; fi
        if j=$(run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$tf" --target-org "$org" --json); then
            log "SUCCESS" "TraceFlag を消しました（${tf}・組織: ${org}）。"
        else
            name=$(sf_err_name "$j")
            case "$name" in
                *NOT_FOUND*|*ENTITY_IS_DELETED*|*INVALID_CROSS_REFERENCE_KEY*)
                    log "WARNING" "TraceFlag（${tf}）は、すでにありません（${name}）。" ;;
                *)
                    log "WARNING" "TraceFlag（${tf}）を消せませんでした（${name}）。最大 2 時間で切れます。"
                    state_set "$STATUS_F" "STATE=error" "REASON=TraceFlag を消せませんでした（${name}）" || true   # 意図的エラー無視: 表示用
                    return 2 ;;
            esac
        fi
    else
        log "INFO" "sf-log.sh が作った TraceFlag はありません。"
    fi
    state_set "$STATE_F" "TRACE_FLAG_ID=" || true                               # 意図的エラー無視: 次の start で作り直す
    state_set "$STATUS_F" "STATE=stopped" "EXPIRES=" "EXPIRES_AT=" "REASON=${reason}" "BACKLOG=" || true   # 意図的エラー無視: 表示用（消した期限を残さない）
    rm -f "$COLLECTOR_F" 2>/dev/null || true                                    # 意図的エラー無視: 取得役の印を消す
    return 0
}

# ------------------------------------------------------------------------------
# 5. 接続先の確認（4.1）
#   引数: full（予約名・本番も確かめる）/ light
# ------------------------------------------------------------------------------
TARGET_ORG=""; USER_ID=""; ORG_ID=""
prepare_org() {
    local mode="$1" rc j
    check_sf_cli --cache
    TARGET_ORG=$(get_target_org "$ORG_ARG") || finish_auto_or_die 1 "接続先の組織エイリアスを特定できません"
    if [[ "$mode" == "full" ]]; then
        if is_reserved_org_alias "$TARGET_ORG"; then
            finish_auto_or_die 10 "${TARGET_ORG} は共有環境（予約名）のため"
        fi
        rc=0
        org_local_release_check "$TARGET_ORG" || rc=$?  # run 不使用: 戻り値で分岐する（run は、戻り値を変える）
        case "$rc" in
            1) finish_auto_or_die 10 "${TARGET_ORG} は本番組織のため" ;;
            2) finish_auto_or_die 10 "${TARGET_ORG} の組織の種類を確認できないため" ;;
        esac
    fi
    j=$(run sf org display user --target-org "$TARGET_ORG" --json) || finish_auto_or_die 1 "ユーザーの情報を取得できません（$(sf_err_name "$j")）"
    USER_ID=$(json_get "$j" result.id) || USER_ID=""   # VAR=$(cmd) のため run 不使用
    ORG_ID=$(json_get "$j" result.orgId) || ORG_ID=""  # VAR=$(cmd) のため run 不使用
    [[ "$USER_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "ユーザー ID の形が正しくありません"
    [[ "$ORG_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "組織 ID の形が正しくありません"
}

# ------------------------------------------------------------------------------
# 6. start（4.2）
# ------------------------------------------------------------------------------
NOTICE_TEXT="ログには、レコードの値・SOQL の条件・コールアウトの内容が載ります。ログは AI に読ませる前提で、読ませると AI の提供元に送られます。ダミーデータの組織で使ってください。本番のデータを写した Sandbox（Full・Partial）では、使わないでください。"

# 確認（10.2）。begin（sf-start の前面）が、手元の答え（.consent の AUTO・ORG（エイリアス）・VERSION）だけで、その場で判定する
#   （sf を呼ばない。ランチャーを待たせないため。2026-11-23。13.3）。答えがない・エイリアスが変わった・文面の版が変わったときだけ聞く。
#   端末でない・q・N は「取らない」。0 = 取る／1 = 取らない
consent_local() {
    local a o v ans
    a=$(kv_get "$CONSENT_F" AUTO); o=$(kv_get "$CONSENT_F" ORG); v=$(kv_get "$CONSENT_F" VERSION)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$a" && "$o" == "$TARGET_ORG" && "$v" == "$CONSENT_VERSION" ]]; then
        [[ "$a" == "on" ]] && return 0
        return 1
    fi
    log "INFO" "ランチャーの起動中、この組織（${TARGET_ORG}）のデバッグログを、裏で自動で手元に保存できます。"
    log "INFO" "  ${NOTICE_TEXT}"
    log "INFO" "  あとから sf-log.sh auto on|off で変えられます。"
    if [[ ! -t 0 ]]; then
        log "INFO" "  確認できない（端末ではない）ため、今回は取りません（答えは保存しません）。"
        return 1
    fi
    # read_key は EOF で die するため、$( ) の中で呼ぶ（ランチャーを止めない）。q も「取らない」。
    #   AI 操作（SF_TOOLS_AI=1）では、標準入力が端末でないため、上で「今回は取らない」と返り、ここには来ない
    #   （入力の関数を $( ) の中で呼ぶのは、この 1 か所だけ。tests/test_common.sh の書き方の検査で、理由つきで除外する）
    ans=$(read_key _k "  自動で取りますか？ [Y/N/q]: " "[YyNnQq]"; printf '%s' "${_k:-}") || ans=""  # VAR=$(cmd) のため run 不使用
    case "$ans" in
        [Yy]) state_set "$CONSENT_F" "AUTO=on" "ORG=${TARGET_ORG}" "ORG_ID=" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 0 ;;
        [Nn]|[Qq]) state_set "$CONSENT_F" "AUTO=off" "ORG=${TARGET_ORG}" "ORG_ID=" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 1 ;;
        *) return 1 ;;
    esac
}

# start --auto（裏）の確認。尋ねない。手元の答えが「取る」で、組織 ID が答えたときと同じなら 0
#   組織 ID がまだ空（begin で答えた直後）なら、今の組織 ID を書く。違えば（同じエイリアスで別の組織に入り直した）、
#   答えを消して 1（次の sf-start で、もう一度聞く。同意のない組織のログを取らない）。結果の理由: CONSENT_REASON
CONSENT_REASON=""
auto_consent() {
    local a o oid v
    a=$(kv_get "$CONSENT_F" AUTO); o=$(kv_get "$CONSENT_F" ORG); oid=$(kv_get "$CONSENT_F" ORG_ID); v=$(kv_get "$CONSENT_F" VERSION)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$a" || "$o" != "$TARGET_ORG" || "$v" != "$CONSENT_VERSION" ]]; then
        CONSENT_REASON="この組織で自動で取るかの答えがないため（sf-start で聞きます）"; return 1
    fi
    if [[ "$a" != "on" ]]; then CONSENT_REASON="このプロジェクトでは、自動で取らない設定のため"; return 1; fi
    if [[ -n "$oid" && "$oid" != "$ORG_ID" ]]; then
        state_set "$CONSENT_F" "AUTO=" "ORG_ID=" || true   # 意図的エラー無視: 次の sf-start で聞き直す
        CONSENT_REASON="同じエイリアスで、別の組織に入り直したため（次の sf-start で、もう一度聞きます）"; return 1
    fi
    if [[ -z "$oid" ]]; then state_set "$CONSENT_F" "ORG_ID=${ORG_ID}" || true; fi   # 意図的エラー無視: 次の照らし合わせに使う
    return 0
}

debuglevel_values() {
    case "$LEVEL" in
        standard) echo "ApexCode=FINE ApexProfiling=INFO Workflow=FINE Database=INFO Validation=INFO Callout=INFO System=DEBUG Visualforce=INFO" ;;
        detail)   echo "ApexCode=FINEST ApexProfiling=FINE Workflow=FINER Database=FINEST Validation=INFO Callout=FINEST System=DEBUG Visualforce=FINE" ;;
    esac
}

# DebugLevel を探し、上書きするか作る（8.1）。結果: DL_ID
DL_ID=""
ensure_debuglevel() {
    local name="sf_tools_log_${LEVEL}" j n vals
    vals=$(debuglevel_values)
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id FROM DebugLevel WHERE DeveloperName = '${name}'") || finish_auto_or_die 1 "DebugLevel を検索できません（$(sf_err_name "$j")）"
    n=$(json_get "$j" result.totalSize) || n=""  # VAR=$(cmd) のため run 不使用
    case "$n" in
        0)
            j=$(run sf data create record --use-tooling-api --sobject DebugLevel --target-org "$TARGET_ORG" --json \
                --values "DeveloperName=${name} MasterLabel=${name} ${vals}") || finish_auto_or_die 1 "DebugLevel を作れません（$(sf_err_name "$j")）"
            DL_ID=$(json_get "$j" result.id) || DL_ID=""  # VAR=$(cmd) のため run 不使用
            ;;
        1)
            DL_ID=$(json_get "$j" result.records.0.Id) || DL_ID=""  # VAR=$(cmd) のため run 不使用
            [[ "$DL_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "DebugLevel の ID の形が正しくありません"
            run sf data update record --use-tooling-api --sobject DebugLevel --record-id "$DL_ID" --target-org "$TARGET_ORG" --json \
                --values "$vals" >/dev/null || finish_auto_or_die 1 "DebugLevel を上書きできません"
            ;;
        *)
            finish_auto_or_die 10 "DebugLevel「${name}」が 1 つに決まりません（${n:-不明} 件）"
            ;;
    esac
    [[ "$DL_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "DebugLevel の ID の形が正しくありません"
}

# TraceFlag を延ばすか作る（4.2 の 3・8.2）。結果: TF_ID・TF_EXPIRES
TF_ID=""; TF_EXPIRES=""
ensure_traceflag() {
    local j now tsv mine other_ids=() other_exp=() line id type st ex state dl start new_exp shrunk="" rc
    now=$(now_z)
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") \
        || finish_auto_or_die 1 "TraceFlag を検索できません（$(sf_err_name "$j")）"
    tsv=$(printf '%s' "$j" | aj tflist --now "$now") || finish_auto_or_die 1 "TraceFlag の検索の応答の形が正しくありません"
    mine=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ "$mine" =~ $ID_RE ]] || mine=""
    local found_mine=0
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ -n "$id" ]] || continue
        if [[ -n "$mine" && "$id" == "$mine" && "$type" == "USER_DEBUG" ]]; then found_mine=1; continue; fi
        if [[ "$type" == "USER_DEBUG" && "$state" == "active" ]]; then other_ids+=("$id"); other_exp+=("$ex"); fi
    done <<< "$tsv"

    # a. 自分が作ったもの → 延ばす
    if [[ $found_mine -eq 1 ]]; then
        TF_EXPIRES=$(aj time add "$now" --sec $((HOURS * 3600)))
        j=$(run sf data update record --use-tooling-api --sobject TraceFlag --record-id "$mine" --target-org "$TARGET_ORG" --json \
            --values "DebugLevelId=${DL_ID} StartDate=${now} ExpirationDate=${TF_EXPIRES}") \
            || finish_auto_or_die 1 "TraceFlag を延ばせません（$(sf_err_name "$j")）"
        TF_ID="$mine"
        return 0
    fi

    # b. ほかの有効な USER_DEBUG
    start="$now"
    if [[ ${#other_ids[@]} -ge 2 ]]; then
        finish_auto_or_die 10 "このユーザーに、有効な USER_DEBUG の TraceFlag が ${#other_ids[@]} つあります"
    elif [[ ${#other_ids[@]} -eq 1 ]]; then
        if [[ $AUTO -eq 1 ]]; then
            log "WARNING" "ほかの USER_DEBUG の TraceFlag（${other_ids[0]}・期限 ${other_exp[0]}）があります。sf-log.sh start で置き換えられます。"
            finish_auto_or_die 10 "ほかの USER_DEBUG の TraceFlag があるため"
        fi
        log "WARNING" "このユーザーに、ほかの USER_DEBUG の TraceFlag があります（設定画面などで作られた、このユーザーのログの設定です）。"
        log "WARNING" "  ID: ${other_ids[0]}・期限: ${other_exp[0]}"
        log "WARNING" "  止めると、期限を「元の期限」と「今から 2 分後」の早いほうに縮めます（消しません）。"
        if [[ $YES -eq 0 ]]; then ask_yn "この TraceFlag を止めて、sf-log.sh の TraceFlag を作りますか？" || die "中断しました。"; fi
        new_exp=$(aj time min "${other_exp[0]}" "$(aj time now --plus-sec 120)")
        if [[ "$new_exp" != "${other_exp[0]}" ]]; then
            run sf data update record --use-tooling-api --sobject TraceFlag --record-id "${other_ids[0]}" --target-org "$TARGET_ORG" --json \
                --values "ExpirationDate=${new_exp}" >/dev/null || die "ほかの TraceFlag の期限を縮められません（新しい TraceFlag は作っていません）。"
            shrunk="${other_ids[0]}（元の期限 ${other_exp[0]} → ${new_exp}）"
        fi
        start=$(aj time add "$new_exp" --sec 1)
        # 作る直前に今と比べ、過ぎていれば今にする（止めたものは、もう有効でないため重ならない）
        now=$(now_z)
        [[ "$(aj time cmp "$start" "$now")" == "-1" ]] && start="$now"
    fi

    # c. 作る
    TF_EXPIRES=$(aj time add "$start" --sec $((HOURS * 3600)))
    rc=0
    j=$(run sf data create record --use-tooling-api --sobject TraceFlag --target-org "$TARGET_ORG" --json \
        --values "TracedEntityId=${USER_ID} LogType=USER_DEBUG DebugLevelId=${DL_ID} StartDate=${start} ExpirationDate=${TF_EXPIRES}") || rc=$?
    if [[ $rc -ne 0 ]]; then
        [[ -n "$shrunk" ]] && log "ERROR" "縮めた TraceFlag は、元に戻していません: ${shrunk}"
        finish_auto_or_die 1 "TraceFlag を作れません（$(sf_err_name "$j")）"
    fi
    TF_ID=$(json_get "$j" result.id) || TF_ID=""  # VAR=$(cmd) のため run 不使用
    [[ "$TF_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "作った TraceFlag の ID の形が正しくありません"
}

cmd_start() {
    local prev_org prev_user prev_tf now vol n s rc
    if [[ $AUTO -eq 1 && "${GITHUB_ACTIONS:-}" == "true" ]]; then
        log "INFO" "GitHub Actions の上では、デバッグログを取りません。"
        exit 10
    fi
    wait_sf_upgrade   # sf の入れ替えの途中に、sf を呼ばない（処理の流れ 0）
    prepare_org full
    if [[ $AUTO -eq 1 ]]; then
        auto_consent || finish_auto_or_die 10 "$CONSENT_REASON"
    else
        log "WARNING" "$NOTICE_TEXT"
        if [[ $YES -eq 0 ]]; then ask_yn "${TARGET_ORG} のデバッグログを取り始めますか？" || die "中断しました。"; fi
    fi
    # 持ち主（sf-start）の登録（5.1 の b）。後始末の最中なら、終わってから登録する（古い後始末が、新しい TraceFlag を消さないため）
    if [[ -n "$OWNER" ]]; then
        rc=0; register_owner "$OWNER" || rc=$?
        [[ $rc -eq 2 ]] && refuse_other_runtime   # 同じロックの中で、別の環境が名乗っていた（5.6）
        [[ $rc -eq 0 ]] || finish_auto_or_die 10 "前の後始末が終わらないため（${CLOSING_WAIT} 秒待ちました）"
    fi
    prev_org=$(kv_get "$STATE_F" ORG); prev_user=$(kv_get "$STATE_F" USER_ID); prev_tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    ensure_debuglevel
    ensure_traceflag

    # 組織を切り替えた（sf-switch-org）: 前の組織の、sf-log.sh が作った TraceFlag を消す（5.3。消せなければ、最大 2 時間で切れる）
    if [[ -n "$prev_org" && "$prev_org" != "$TARGET_ORG" && "$prev_tf" =~ $ID_RE ]]; then
        if run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$prev_tf" --target-org "$prev_org" --json >/dev/null; then
            log "INFO" "前の組織（${prev_org}）の TraceFlag（${prev_tf}）を消しました。"
        else
            log "WARNING" "前の組織（${prev_org}）の TraceFlag（${prev_tf}）を消せませんでした（最大 2 時間で切れます）。"
        fi
    fi

    # .state（組織・ユーザーが変わったら、取得のしおりを今に、要約のしおりを今の目録の最後の行にする）
    now=$(now_z)
    if [[ "$prev_org" != "$TARGET_ORG" || "$prev_user" != "$USER_ID" || -z "$(kv_get "$STATE_F" LAST_FETCH)" ]]; then
        local mark; mark=$(index_mark_now)  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" \
            "LAST_FETCH=${now}" "LAST_FETCH_ID=" "LATE_FROM=" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" \
            "LAST_READ=" "LAST_READ_IDS=" || finish_auto_or_die 1 "手元の状態を書けません"
    else
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" || finish_auto_or_die 1 "手元の状態を書けません"
    fi
    # WARNING= : 裏の準備のやり直し（retry_prepare）の「やり直しています」を消す
    # COUNT_TODAY: 前回の値（前の日など）を残さない。ランチャーは「取得中」に変わった時点で 1 回だけ描き直すため、ここで正しい数を書く
    state_set "$STATUS_F" "STATE=collecting" "ORG=${TARGET_ORG}" "EXPIRES=${TF_EXPIRES}" "EXPIRES_AT=$(local_hm "$TF_EXPIRES")" "COUNT_TODAY=$(count_today)" "REASON=" "WARNING=" || true   # 意図的エラー無視: 表示用

    # 組織のログの量（8.6）
    vol=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT COUNT(Id) n, SUM(LogLength) s FROM ApexLog") || vol=""
    n=$(json_get "$vol" result.records.0.n 2>/dev/null) || n=""   # VAR=$(cmd) のため run 不使用
    s=$(json_get "$vol" result.records.0.s 2>/dev/null) || s=""   # VAR=$(cmd) のため run 不使用
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    log "SUCCESS" "デバッグログを取り始めました（組織: ${TARGET_ORG}・TraceFlag: ${TF_ID}・期限: ${TF_EXPIRES}（UTC））。"
    [[ "$n" =~ ^[0-9]+$ ]] && log "INFO" "  組織のログ: ${n} 本・$((s / 1024 / 1024))MB（上限 1,000MB）"
    if [[ "$s" -gt "$ORG_LOG_WARN_BYTES" ]]; then
        log "WARNING" "組織のログが 700MB を超えています。1,000MB を超えると、TraceFlag を作れなくなります。"
    fi
    if [[ $COLLECT_AFTER -eq 1 ]]; then
        exec bash "${SCRIPT_DIR}/sf-log.sh" collect   # begin から裏で起動されたとき: 準備ができたら、そのまま取得役になる
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# 7. 取得（4.3 の 2c・8.3・8.4）
# ------------------------------------------------------------------------------
# 操作名をファイル名の飾りにする（英数字・_・- 以外を _ に。先頭と末尾の _ を除く。最大 30 文字）
op_slug() {
    local s
    s=$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_-]/_/g; s/^_*//; s/_*$//')  # VAR=$(cmd) のため run 不使用
    printf '%s' "${s:0:30}"
}

# 1 本を保存する（置き換えで。同じ名前がすでにあれば、成功として扱う）。引数: 元のファイル ID 開始 操作 状態 長さ 所要
save_one() {
    local src="$1" id="$2" st="$3" op="$4" status="$5" len="$6" dur="$7" dt d t slug name dir tmp
    dt=$(aj time local "$st") || return 1
    d="${dt%%$'\t'*}"; t="${dt#*$'\t'}"
    slug=$(op_slug "$op")
    name="${t}_${id}${slug:+_${slug}}.log"
    dir="${APEX_DIR}/${d}"
    mkdir -p "$dir" || return 1
    if [[ ! -e "${dir}/${name}" ]]; then
        tmp="${dir}/.tmp.${id}.$$"
        cp "$src" "$tmp" && mv -f "$tmp" "${dir}/${name}" || { rm -f "$tmp"; return 1; }
    fi
    if ! grep -qF -- "	${id}	" "$INDEX_F" 2>/dev/null; then  # 条件チェックのため run 不使用（目録に同じ ID があれば足さない）
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${dir}/${name}" "$id" "$st" "$op" "$status" "$len" "$dur" >> "$INDEX_F"
    fi
    heartbeat   # ログを 1 本保存するたび（5.6。取得役のときだけ書く）
}

# sf-log.log にだけ書く（画面に出さない。取得の件数など）
note_log() { printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }
note_warn() { printf '[%s] [WARNING] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

# 目録（.index）の写しを作る（改行で終わる行だけ。取得役が書いている途中の行を読まないため。4.4 の 3）。引数: 写しのファイル
index_snapshot() {
    local out="$1"
    : > "$out" || return 1
    [[ -f "$INDEX_F" ]] || return 0
    cp "$INDEX_F" "$out" || return 1
    if [[ -s "$out" && -n "$(tail -c 1 "$out")" ]]; then   # 最後が改行で終わらない → 書きかけの行を除く
        sed '$d' "$out" > "${out}.t" && mv -f "${out}.t" "$out" || return 1
    fi
}
# 目録（の写し）の行数と、最後の行のログの ID（タブ区切り。空なら「0<タブ>」）。要約のしおり（LAST_READ_LINE・LAST_READ_ID）にする
index_mark() {
    [[ -s "$1" ]] || { printf '0\t'; return 0; }
    awk -F'\t' 'END { printf "%d\t%s", NR, $2 }' "$1"
}
# 今の目録の印（start・組織の切り替えで、要約のしおりを「今」にするため）
index_mark_now() {
    local t m
    t=$(mktemp "${TMPDIR:-/tmp}/sf-log-idx.XXXXXX") || { printf '0\t'; return 0; }  # VAR=$(cmd) のため run 不使用
    if index_snapshot "$t"; then m=$(index_mark "$t"); else m=$'0\t'; fi  # VAR=$(cmd) のため run 不使用
    rm -f "$t" "${t}.t" 2>/dev/null || true   # 意図的エラー無視: 一時ファイルの後始末
    printf '%s' "$m"
}

# 1 回の取得。戻り値: 0 = 追いついた／2 = まだ残りがある／1 = 失敗
fetch_round() {
    local last lastid where q lj tsv name rc
    local ids=() mine=() starts=() lens=() durs=() ops=() stats=()
    local id m st len dur op status total more=0 first=-1 others_after=0 i n f
    last=$(kv_get "$STATE_F" LAST_FETCH); lastid=$(kv_get "$STATE_F" LAST_FETCH_ID)  # VAR=$(cmd) のため run 不使用
    if [[ ! "$last" =~ $ISO_RE ]]; then last=$(aj time add "$(now_z)" --sec -1800); lastid=""; fi
    [[ "$lastid" =~ $ID_RE ]] || lastid=""
    if [[ -n "$lastid" ]]; then
        where="StartTime > ${last} OR (StartTime = ${last} AND Id > '${lastid}')"
    else
        where="StartTime >= ${last}"
    fi
    q="SELECT Id, LogUserId, StartTime, Operation, Request, Status, LogLength, DurationMilliseconds FROM ApexLog WHERE ${where} ORDER BY StartTime ASC, Id ASC LIMIT 51"
    heartbeat   # sf を呼ぶ直前（5.6。取得役のときだけ書く）
    # run を通さない（応答に他の人のログの見出しが入るため。run は出力を sf-log.log・error.log・画面に出す。8.3）
    if lj=$(sf data query --use-tooling-api --target-org "$TARGET_ORG" --json --query "$q" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用（上の理由）
        if ! tsv=$(printf '%s' "$lj" | aj list --user "$USER_ID" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用
            note_log "ApexLog の一覧: 失敗（応答の形が正しくありません）"
            return 1
        fi
    else
        name=$(sf_err_name "$lj")
        note_log "ApexLog の一覧: 失敗（${name}）"
        return 1
    fi
    lj=""
    while IFS=$'\t' read -r id m st len dur op status; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); mine+=("$m"); starts+=("$st"); lens+=("$len"); durs+=("$dur"); ops+=("$op"); stats+=("$status")
    done <<< "$tsv"
    tsv=""
    total=${#ids[@]}
    if [[ $total -gt 50 ]]; then more=1; total=50; fi
    n=0
    for ((i = 0; i < total; i++)); do
        if [[ "${mine[i]}" == "1" ]]; then
            n=$((n + 1)); [[ $first -lt 0 ]] && first=$i
        elif [[ $first -ge 0 ]]; then
            others_after=1
        fi
    done
    if [[ $more -eq 1 ]]; then note_log "ApexLog の一覧: ${total} 本（自分のログ ${n} 本）・残りあり"
    else note_log "ApexLog の一覧: ${total} 本（自分のログ ${n} 本）"; fi
    if [[ $total -eq 0 ]]; then return 0; fi
    if [[ $first -lt 0 ]]; then
        state_set "$STATE_F" "LAST_FETCH=${starts[total-1]}" "LAST_FETCH_ID=${ids[total-1]}" || return 1
        [[ $more -eq 1 ]] && return 2
        return 0
    fi

    # 本文を取る。一時フォルダは、取得のロックを持った状態で、毎回まず空にする（他の人の本文を残さない。8.4）
    rm -rf "$FETCH_TMP" && mkdir -p "$FETCH_TMP" || return 1
    if [[ $more -eq 0 && $others_after -eq 0 ]]; then
        heartbeat
        run sf apex get log -n "$((total - first))" -d "$FETCH_TMP" --target-org "$TARGET_ORG" >/dev/null || { rm -rf "$FETCH_TMP"; return 1; }
    fi
    for f in "$FETCH_TMP"/* "$FETCH_TMP"/.[!.]*; do
        [[ -e "$f" ]] || continue
        if [[ ! "${f##*/}" =~ ^[A-Za-z0-9]{15}([A-Za-z0-9]{3})?\.log$ ]]; then
            note_log "本文の取得: 想定しない名前のファイルがあったため、この回を失敗にします"
            rm -rf "$FETCH_TMP"; return 1
        fi
    done
    rc=0
    for ((i = 0; i < total; i++)); do
        if [[ "${mine[i]}" == "1" ]]; then
            f="${FETCH_TMP}/${ids[i]}.log"
            if [[ ! -f "$f" ]]; then
                # -n で押し出された・1 本ずつ取る場合（-i は ID を指定するので、他の人のログは入らない）
                rm -rf "${FETCH_TMP}/one" && mkdir -p "${FETCH_TMP}/one" || { rc=1; break; }
                heartbeat
                run sf apex get log -i "${ids[i]}" -d "${FETCH_TMP}/one" --target-org "$TARGET_ORG" >/dev/null || { rc=1; break; }
                [[ -f "${FETCH_TMP}/one/${ids[i]}.log" ]] || { note_log "本文の取得: ${ids[i]} のファイルがありません"; rc=1; break; }
                f="${FETCH_TMP}/one/${ids[i]}.log"
            fi
            save_one "$f" "${ids[i]}" "${starts[i]}" "${ops[i]}" "${stats[i]}" "${lens[i]}" "${durs[i]}" || { rc=1; break; }
        fi
        state_set "$STATE_F" "LAST_FETCH=${starts[i]}" "LAST_FETCH_ID=${ids[i]}" || { rc=1; break; }
    done
    rm -rf "$FETCH_TMP" 2>/dev/null || true   # 意図的エラー無視: 次の取得の最初にも空にする
    [[ $rc -ne 0 ]] && return 1
    [[ $more -eq 1 ]] && return 2
    return 0
}

# 遅れて現れるログの拾い直し（doc/sf-log-design.md 8.3。冒頭コメントの「拾い直し」）。
#   取得のロックを持ったまま、通常の取得が追いついた回（fetch_round が 0）に 1 回だけ呼ぶ。
#   結果: LATE_WARN（空 = 知らせることなし）。戻り値は常に 0（失敗しても、その回の取得は成功として扱う。しおりは進めてある）
#   2026-11-24 に tama-dev で、9.5 秒の匿名 Apex のログが、あとから始まった短い処理のログより遅れて一覧に現れることを確かめた
late_recheck() {
    local last now lower lf page=0 before_st="" before_id="" where q lj tsv n got=0 seen=0 failed=0 full=0 i f
    local ids=() mine=() starts=() lens=() durs=() ops=() stats=() id m st len dur op status
    LATE_WARN=""
    last=$(kv_get "$STATE_F" LAST_FETCH)  # VAR=$(cmd) のため run 不使用
    [[ "$last" =~ $ISO_RE ]] || return 0
    now=$(now_z); lower=$(aj time add "$now" --sec "-${LATE_WINDOW}")  # VAR=$(cmd) のため run 不使用
    lf=$(kv_get "$STATE_F" LATE_FROM)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$lf" && ! "$lf" =~ $ISO_RE ]]; then state_set "$STATE_F" "LATE_FROM=" || true; lf=""; fi   # 意図的エラー無視: 形が違えば消すだけ
    if [[ -n "$lf" && "$(aj time cmp "$lf" "$(aj time add "$now" --sec "-${LATE_MAX_AGE}")")" == "-1" ]]; then
        state_set "$STATE_F" "LATE_FROM=" || true   # 意図的エラー無視: 次の回にも同じ判定で消える
        LATE_WARN="遅れて現れたログの拾い直しの失敗が 24 時間続いたため、${lf}（UTC）からの分の拾い直しをやめました"
        note_warn "拾い直し: ${LATE_WARN}"
        lf=""
    fi
    # しおりが 30 分より古く、前の回の失敗もなければ、範囲が空（しおりより後は、通常の取得が取る）
    if [[ -z "$lf" && "$(aj time cmp "$last" "$lower")" == "-1" ]]; then return 0; fi
    [[ -n "$lf" && "$(aj time cmp "$lf" "$lower")" == "-1" ]] && lower="$lf"
    if [[ "$(aj time cmp "$lower" "$last")" == "1" ]]; then state_set "$STATE_F" "LATE_FROM=" || true; return 0; fi   # 意図的エラー無視: 範囲が空

    while [[ $page -lt $LATE_MAX_PAGES ]]; do
        page=$((page + 1))
        where="LogUserId = '${USER_ID}' AND StartTime >= ${lower} AND StartTime <= ${last}"
        [[ -n "$before_st" ]] && where="${where} AND (StartTime < ${before_st} OR (StartTime = ${before_st} AND Id < '${before_id}'))"
        q="SELECT Id, LogUserId, StartTime, Operation, Request, Status, LogLength, DurationMilliseconds FROM ApexLog WHERE ${where} ORDER BY StartTime DESC, Id DESC LIMIT ${LATE_PAGE}"
        # run を通さない（8.3 の一覧と扱いをそろえる。応答は自分のログの見出しだけ）
        heartbeat
        if ! lj=$(sf data query --use-tooling-api --target-org "$TARGET_ORG" --json --query "$q" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用（上の理由）
            note_warn "拾い直し: 一覧の失敗（$(sf_err_name "$lj")）"; failed=1; break
        fi
        if ! tsv=$(printf '%s' "$lj" | aj list --user "$USER_ID" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用
            note_warn "拾い直し: 一覧の応答の形が正しくありません"; failed=1; break
        fi
        lj=""
        # 先に配列へ読む（本文の取得の sf が、標準入力の残りを読まないため）
        ids=(); mine=(); starts=(); lens=(); durs=(); ops=(); stats=()
        while IFS=$'\t' read -r id m st len dur op status; do
            [[ -n "$id" ]] || continue
            ids+=("$id"); mine+=("$m"); starts+=("$st"); lens+=("$len"); durs+=("$dur"); ops+=("$op"); stats+=("$status")
        done <<< "$tsv"
        tsv=""
        n=${#ids[@]}
        for ((i = 0; i < n; i++)); do
            before_st="${starts[i]}"; before_id="${ids[i]}"
            [[ "${mine[i]}" == "1" ]] || continue   # 念のため（検索は自分のログだけ）
            seen=$((seen + 1))
            grep -qF -- "	${ids[i]}	" "$INDEX_F" 2>/dev/null && continue  # 条件チェックのため run 不使用（目録にあれば取らない）
            # -i で 1 本だけ取る（ID を指定するので、他の人のログは入らない）
            { rm -rf "$FETCH_TMP" && mkdir -p "${FETCH_TMP}/one"; } || { failed=1; break; }
            heartbeat
            run sf apex get log -i "${ids[i]}" -d "${FETCH_TMP}/one" --target-org "$TARGET_ORG" >/dev/null || { failed=1; break; }
            f="${FETCH_TMP}/one/${ids[i]}.log"
            [[ -f "$f" ]] || { note_warn "拾い直し: ${ids[i]} のファイルがありません"; failed=1; break; }
            save_one "$f" "${ids[i]}" "${starts[i]}" "${ops[i]}" "${stats[i]}" "${lens[i]}" "${durs[i]}" || { failed=1; break; }
            got=$((got + 1))
        done
        [[ $failed -eq 1 ]] && break
        [[ $n -lt $LATE_PAGE ]] && break
        [[ $page -ge $LATE_MAX_PAGES ]] && full=1
    done
    rm -rf "$FETCH_TMP" 2>/dev/null || true   # 意図的エラー無視: 次の取得の最初にも空にする
    note_log "拾い直し: 自分のログ ${seen} 本を見て、${got} 本を拾い直しました（${lower}〜${last}。UTC）"
    if [[ $failed -eq 1 ]]; then
        # その回の下限を残す（範囲の下限は毎回進むため、残さないと、失敗したログが次の回には範囲の外に出ることがある）
        state_set "$STATE_F" "LATE_FROM=${lower}" || true   # 意図的エラー無視: 書けなければ、次の回は「今から 30 分前」から
        LATE_WARN="${LATE_WARN:+${LATE_WARN}。}遅れて現れたログの拾い直しに失敗しました（次の回に、${lower}（UTC）からやり直します）"
        note_warn "拾い直し: ${LATE_WARN}"
        return 0
    fi
    state_set "$STATE_F" "LATE_FROM=" || true   # 意図的エラー無視: 残っても、次の回に拾い直すだけ
    if [[ $full -eq 1 ]]; then
        LATE_WARN="${LATE_WARN:+${LATE_WARN}。}拾い直しの範囲に自分のログが $((LATE_PAGE * LATE_MAX_PAGES)) 本を超えてあったため、${lower}〜${before_st}（UTC）に始まったログの一部は、拾い直していないかもしれません"
        note_warn "拾い直し: ${LATE_WARN}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 8. pull（4.4）
# ------------------------------------------------------------------------------
# 取得役に、取得を頼む（9.3）。依頼は ID つきのファイル（一時ファイルに書いてから mv）。自分の ID の応答だけを待つ
#   出力: ok / error / timeout
request_collector() {
    local id i res cpid
    id="$$_$(date +%s)_${RANDOM}"
    mkdir -p "$REQ_DIR" || { echo "timeout"; return 0; }
    printf 'AT=%s\n' "$(date +%s)" > "${REQ_DIR}/.pull.${id}.tmp" && mv -f "${REQ_DIR}/.pull.${id}.tmp" "${REQ_DIR}/pull.${id}"
    cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
    for ((i = 0; i < PULL_WAIT; i++)); do
        if [[ -f "${REQ_DIR}/done.${id}" ]]; then
            res=$(kv_get "${REQ_DIR}/done.${id}" RESULT)  # VAR=$(cmd) のため run 不使用
            rm -f "${REQ_DIR}/done.${id}"
            echo "${res:-error}"; return 0
        fi
        pid_alive "$cpid" || break
        sleep 1  # run 不使用: 応答を待つだけ
    done
    rm -f "${REQ_DIR}/pull.${id}"
    echo "timeout"
}

cmd_pull() {
    local rc=0 round since now notes=() tmp_list snap cnt omitted first_om last_om ts out_md hdr cpid corg res v mark
    local mode rl rid old at found base
    prepare_org full
    # しおりが別の組織・ユーザーのものなら、今から取り直す（別の組織の時刻・ID を使わない）
    if [[ "$(kv_get "$STATE_F" ORG)" != "$TARGET_ORG" || "$(kv_get "$STATE_F" USER_ID)" != "$USER_ID" ]]; then
        now=$(now_z)
        mark=$(index_mark_now)  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "LAST_FETCH=$(aj time add "$now" --sec -1800)" "LAST_FETCH_ID=" \
            "LATE_FROM=" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" "LAST_READ=" "LAST_READ_IDS=" || die "手元の状態を書けません。"
    fi

    cpid=$(collector_pid_local); corg=$(kv_get "$COLLECTOR_F" ORG)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$cpid"; then
        # 取得役が生きている → 自分では取らず、取得役に頼む（組織から取って、しおりを書くのは取得役だけ。9.3）
        [[ "$corg" == "$TARGET_ORG" ]] || die "取得役が、別の組織（${corg}）で動いています（PID ${cpid}）。"
        res=$(request_collector)  # VAR=$(cmd) のため run 不使用
        case "$res" in
            ok)    notes+=("取得役: 動作中（最後の取得 $(kv_get "$STATUS_F" LAST_FETCH)）")
                   v=$(kv_get "$STATUS_F" LATE_WARNING); [[ -n "$v" ]] && notes+=("$v") ;;  # VAR=$(cmd) のため run 不使用
            error) notes+=("取得役: 直前の取得に失敗しています（sf-tools/logs/sf-log.log を参照）。手元にある分で要約しました") ;;
            *)     log "WARNING" "取得役の取り込みが、${PULL_WAIT} 秒で終わりませんでした。手元にある分で要約します。"
                   notes+=("取り込みが終わっていません（残り約 $(kv_get "$STATUS_F" BACKLOG) 本）。手元にある分で要約しました。少し待って、もう一度 pull してください") ;;
        esac
    else
        # 取得役がいない → 自分で取る（取得のロックを持つ。最大 90 秒待つ）
        lock_take "$FETCH_LOCK" 450 || die "取得のロックを取れませんでした（${FETCH_LOCK}。ほかの取得が終わりません）。"
        for round in 1 2 3 4; do
            rc=0; fetch_round || rc=$?
            [[ $rc -eq 2 ]] || break
        done
        LATE_WARN=""
        [[ $rc -eq 0 ]] && late_recheck   # 追いついたときだけ（200 本の上限で止まったら、次の回に回す。8.3）
        lock_drop "$FETCH_LOCK"
        [[ -n "$LATE_WARN" ]] && notes+=("$LATE_WARN")
        [[ $rc -eq 1 ]] && die "ログを取得できませんでした（sf-tools/logs/sf-log.log を参照）。"
        [[ $rc -eq 2 ]] && notes+=("取り込みの残りがあります（200 本を超えました）。もう一度 sf-log.sh pull を実行すると、続きを取ります。")
        notes+=("取得役: 動いていません（この pull が、組織から直接取りました）")
    fi
    [[ -n "$(kv_get "$STATE_F" TRACE_FLAG_ID)" ]] || notes+=("sf-log.sh の TraceFlag がありません（新しいログは出ません）。人に sf-start か sf-log.sh start を頼んでください")
    v=$(kv_get "$STATUS_F" EXPIRES); [[ -n "$v" ]] && notes+=("TraceFlag の期限: ${v}（UTC）")  # VAR=$(cmd) のため run 不使用

    # 要約に入れるログを選ぶ（4.4 の 3）。要約のロックを取ってから、しおりを読む（同時に動く pull が、先にしおりを進めることがあるため）。
    #   開始時刻ではなく、目録に足された順で選ぶ（遅れて拾い直したログ（8.3）は、開始時刻が、前回の要約のログより前のことがある）
    now=$(now_z)
    tmp_list=$(mktemp "${TMPDIR:-/tmp}/sf-log-list.XXXXXX") || die "一時ファイルを作れません。"
    snap=$(mktemp "${TMPDIR:-/tmp}/sf-log-snap.XXXXXX") || { rm -f "$tmp_list"; die "一時ファイルを作れません。"; }
    READ_LOCK_HELD=0
    trap 'rm -f "$tmp_list" "$snap" "${snap}.t"; [[ ${READ_LOCK_HELD:-0} -eq 1 ]] && lock_drop "$READ_LOCK"' EXIT
    if lock_take "$READ_LOCK" "$READ_TRIES"; then
        READ_LOCK_HELD=1
    else
        log "WARNING" "要約のロックを取れませんでした（${READ_LOCK}）。しおりを読まず・進めずに要約します。"
        notes+=("要約のロックを取れませんでした（ほかの pull が動いています）。しおりを進めずに、直近 ${SINCE_MIN:-30} 分に始まったログで要約しました")
    fi
    index_snapshot "$snap" || die "目録（${INDEX_F}）を読めません。"
    mode="time"; since=""
    if [[ -n "$SINCE_MIN" ]]; then
        since=$(aj time add "$now" --sec "-$((SINCE_MIN * 60))")
    elif [[ $READ_LOCK_HELD -eq 1 ]]; then
        rl=$(kv_get "$STATE_F" LAST_READ_LINE); rid=$(kv_get "$STATE_F" LAST_READ_ID)  # VAR=$(cmd) のため run 不使用
        old=$(kv_get "$STATE_F" LAST_READ)  # VAR=$(cmd) のため run 不使用
        if [[ -z "$rl" && "$old" =~ $ISO_RE ]]; then
            # 古い .state からの移す（9.2）: 開始が LAST_READ より前の行と、同じ秒で LAST_READ_IDS にある行を「見た」とする
            rl=$(awk -F'\t' -v s="$old" -v ids=",$(kv_get "$STATE_F" LAST_READ_IDS)," \
                '!(($3 < s) || ($3 == s && index(ids, "," $2 ",") > 0)) { print NR - 1; f = 1; exit } END { if (!f) print NR }' "$snap")
            rid=""; [[ "$rl" -gt 0 ]] && rid=$(awk -F'\t' -v n="$rl" 'NR == n { print $2; exit }' "$snap")
            log "INFO" "要約のしおりを、新しい形（目録の ${rl} 行目）に移しました。"
        fi
        if [[ "$rl" == "0" && -z "$rid" ]]; then
            mode="line"; base=0
        elif [[ "$rl" =~ ^[0-9]+$ && "$rid" =~ $ID_RE ]]; then
            at=$(awk -F'\t' -v n="$rl" 'NR == n { print $2; exit }' "$snap")
            if [[ "$at" == "$rid" ]]; then
                mode="line"; base="$rl"
            else
                found=$(awk -F'\t' -v id="$rid" '$2 == id { print NR; exit }' "$snap")
                if [[ -n "$found" ]]; then
                    log "WARNING" "目録の行がずれていたため、要約のしおりの行を探し直しました（${rl} → ${found} 行目）。"
                    mode="line"; base="$found"
                fi
            fi
        fi
        if [[ "$mode" != "line" ]]; then
            [[ -n "${rl}${rid}" ]] && log "WARNING" "前回の要約のしおりが使えないため、直近 30 分に始まったログを対象にします。"
        fi
    fi
    if [[ "$mode" == "line" ]]; then
        awk -F'\t' -v b="$base" 'NR > b' "$snap" | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 > "$tmp_list"  # 選ぶだけ（失敗は、下の件数で分かる）
    else
        [[ -n "$since" ]] || since=$(aj time add "$now" --sec -1800)
        awk -F'\t' -v s="$since" '$3 >= s' "$snap" | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 > "$tmp_list"  # 選ぶだけ（同上）
    fi
    cnt=$(wc -l < "$tmp_list" | tr -d ' ')
    if [[ "$cnt" -gt "$MAX_LOGS" ]]; then
        omitted=$((cnt - MAX_LOGS))
        first_om=$(head -1 "$tmp_list" | cut -f3); last_om=$(sed -n "${omitted}p" "$tmp_list" | cut -f3)
        notes+=("入れなかった古いログ: ${omitted} 本（${first_om}〜${last_om}。UTC）。入れるには sf-log.sh pull --since <分> --max <本数>")
        tail -n "$MAX_LOGS" "$tmp_list" > "${tmp_list}.t" && mv -f "${tmp_list}.t" "$tmp_list"
    fi

    # 要約を作る（置き換えで書く）
    mkdir -p "${APEX_DIR}/summaries" || die "要約のフォルダを作れません。"
    ts=$(aj time local "$now"); ts="${ts/$'\t'/_}"
    out_md="${APEX_DIR}/summaries/${ts}.md"
    local nargs=() nt
    for nt in "${notes[@]}"; do nargs+=(--note "$nt"); done
    aj summarize --list "$tmp_list" --base . --now "$now" "${nargs[@]}" > "${out_md}.tmp" || { rm -f "${out_md}.tmp"; die "要約を作れませんでした。"; }
    mv -f "${out_md}.tmp" "$out_md" && cp "$out_md" "${APEX_DIR}/latest.md.tmp" && mv -f "${APEX_DIR}/latest.md.tmp" "${APEX_DIR}/latest.md" \
        || die "要約を書けませんでした。"

    # 要約のしおりを、読んだ目録の最後の行に進める（成功したときだけ。--since・ロックが取れないときは進めない。4.4 の 5）
    if [[ $READ_LOCK_HELD -eq 1 && -z "$SINCE_MIN" ]]; then
        mark=$(index_mark "$snap")  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" "LAST_READ=" "LAST_READ_IDS=" \
            || log "WARNING" "要約のしおりを書けませんでした。"
    fi
    if [[ $READ_LOCK_HELD -eq 1 ]]; then lock_drop "$READ_LOCK"; READ_LOCK_HELD=0; fi
    hdr=$(head -1 "${APEX_DIR}/latest.md")
    printf '%s\n%s\n' "${hdr#\# }" "${APEX_DIR}/latest.md"
    exit 0
}

# ------------------------------------------------------------------------------
# 9. stop（4.5）
# ------------------------------------------------------------------------------
cmd_stop() {
    local mark rc=0
    # 人の判断で止める: 持ち主の一覧にかかわらず止める（一覧も空にする）。後始末の最中は CLOSING を書く（5.2）
    mark="$$:$(date +%s):stop"
    if lock_take "$LOCK_DIR" 50; then
        printf 'CLOSING=%s\n' "$mark" > "$OWNERS_F"
        lock_drop "$LOCK_DIR"
    fi
    do_cleanup "sf-log.sh stop で止めました" || rc=$?
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: 一覧（と CLOSING）を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6。別の環境は、このあとで名乗れる）
    case "$rc" in
        1) die "取得役が止まらないため、TraceFlag を残しました。" ;;
        2) die "TraceFlag を消せませんでした（sf-tools/logs/sf-log.log を参照）。" ;;
    esac
    log "INFO" "手元のログ（${APEX_DIR}/）は残しました。"
    exit 0
}

# ------------------------------------------------------------------------------
# 9b. leave（5.2。sf-start の終了時）: 持ち主の一覧から自分を外し、誰もいなければ止める
# ------------------------------------------------------------------------------
cmd_leave() {
    local n rc=0
    lock_take "$LOCK_DIR" 50 || { log "WARNING" "手元の状態のロックを取れませんでした。"; exit 0; }
    if ! grep -qxF -- "$OWNER" "$OWNERS_F" 2>/dev/null; then  # 条件チェックのため run 不使用
        lock_drop "$LOCK_DIR"
        log "INFO" "持ち主の一覧に、この印はありません（何もしません）。"
        exit 0   # 登録していない sf-start の終了で、ほかの人・手動の start の TraceFlag を消さない
    fi
    n=$(owners_remove_locked "$OWNER")
    if [[ "$n" -gt 0 ]]; then
        lock_drop "$LOCK_DIR"
        log "INFO" "ほかの sf-start が起動中のため、デバッグログの取得は止めません。"
        exit 0
    fi
    printf 'CLOSING=%s\n' "$OWNER" >> "$OWNERS_F"   # 後始末の最中（新しい sf-start は、終わるまで登録を待つ）
    lock_drop "$LOCK_DIR"
    do_cleanup "すべての sf-start が終了したため" || rc=$?
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: CLOSING を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6。別の環境は、このあとで名乗れる）
    [[ $rc -eq 0 ]] || log "WARNING" "デバッグログの後始末が、最後まで終わりませんでした（sf-tools/logs/sf-log.log を参照）。"
    exit 0   # sf-start の終了を止めない（WARNING だけ）
}

# ------------------------------------------------------------------------------
# 9c. collect（4.3。裏の取得役）。sf-start.sh が、start --auto の成功のあとに裏で起動する。人は打たない
# ------------------------------------------------------------------------------
# 取得役が止まるべきか（停止の依頼・後始末の最中・印の入れ替わり）。止まるべき = 0
collector_should_quit() {
    if [[ -f "${REQ_DIR}/stop" ]]; then rm -f "${REQ_DIR}/stop"; note_log "取得役: 停止の依頼で止まります"; return 0; fi
    [[ -n "$(kv_get "$OWNERS_F" CLOSING)" ]] && { note_log "取得役: 後始末の最中のため止まります"; return 0; }
    [[ "$(kv_get "$COLLECTOR_F" PID)" == "$$" ]] || { note_log "取得役: 印が入れ替わったため止まります"; return 0; }
    return 1
}

# 取得役が自分で後始末をして止まる（持ち主がいなくなった・12 時間）。引数: 理由
collector_finish() {
    local reason="$1"
    lock_take "$LOCK_DIR" 50 || exit 1
    if [[ -n "$(kv_get "$OWNERS_F" CLOSING)" ]]; then lock_drop "$LOCK_DIR"; exit 0; fi   # ほかの人が後始末をしている
    printf 'CLOSING=%s\n' "$$:$(date +%s):collector" >> "$OWNERS_F"
    lock_drop "$LOCK_DIR"
    note_log "取得役: ${reason}"
    local rc=0
    do_cleanup "$reason" 1 || rc=$?   # 失敗は、取得役は表示先がない（.status と sf-log.log に書く）
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: CLOSING を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6）
    exit 0
}

# pull の依頼があるか（compgen -G は使わない。Bash 3.2 で確実に使えるとは限らないため）
has_pull_request() {
    local f
    for f in "${REQ_DIR}"/pull.*; do [[ -e "$f" ]] && return 0; done
    return 1
}

# 待っている pull に応答する（9.3）。引数: ok / error
respond_pulls() {
    local f id
    for f in "${REQ_DIR}"/pull.*; do
        [[ -e "$f" ]] || continue
        id="${f##*/pull.}"
        if [[ "$id" =~ ^[0-9]+_[0-9]+_[0-9]+$ ]]; then
            printf 'RESULT=%s\n' "$1" > "${REQ_DIR}/.done.${id}.tmp" && mv -f "${REQ_DIR}/.done.${id}.tmp" "${REQ_DIR}/done.${id}"
        fi
        rm -f "$f"
    done
}

# 自分の TraceFlag を延ばす（4.3 の 2d）。延ばす前に、ID・種類を確かめる（人が置き換えたものを延ばさない）
collector_extend() {
    local tf j tsv id type st ex state dl found=0 now newexp
    tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ "$tf" =~ $ID_RE ]] || { state_set "$STATUS_F" "WARNING=TraceFlag がないため、延ばせません" || true; return 1; }
    heartbeat
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") || return 1
    tsv=$(printf '%s' "$j" | aj tflist 2>/dev/null) || return 1
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ "$id" == "$tf" && "$type" == "USER_DEBUG" ]] && found=1
    done <<< "$tsv"
    if [[ $found -eq 0 ]]; then
        state_set "$STATUS_F" "WARNING=自分の TraceFlag が消えた・置き換わったため、延ばせません" || true   # 意図的エラー無視: 表示用
        return 1
    fi
    collector_should_quit && exit 0   # 書き込む直前にも確かめる（消された TraceFlag を延ばし直さない）
    now=$(now_z); newexp=$(aj time add "$now" --sec 7200)
    heartbeat
    run sf data update record --use-tooling-api --sobject TraceFlag --record-id "$tf" --target-org "$TARGET_ORG" --json \
        --values "StartDate=${now} ExpirationDate=${newexp}" >/dev/null || return 1
    state_set "$STATUS_F" "EXPIRES=${newexp}" "EXPIRES_AT=$(local_hm "$newexp")" "WARNING=" || true   # 意図的エラー無視: 表示用
    note_log "取得役: TraceFlag を延ばしました（期限 ${newexp}）"
    COLLECT_EXPIRES="$newexp"
}

cmd_collect() {
    local org user started pid corg i now next=0 backoff rc n first=1 today cnt soon
    trap '' INT   # Ctrl+C を無視する（止めるのは、持ち主の見張りと、stop・leave）
    org=$(kv_get "$STATE_F" ORG); user=$(kv_get "$STATE_F" USER_ID)  # VAR=$(cmd) のため run 不使用
    [[ -n "$org" && "$user" =~ $ID_RE ]] || { note_log "取得役: .state に組織・ユーザーがありません"; exit 1; }
    TARGET_ORG="$org"; USER_ID="$user"
    started=$(date +%s)
    mkdir -p "$REQ_DIR" || exit 1

    # 1. 取得役の印（二重に動かさない。別の組織の取得役なら、止めてもらって入れ替わる）
    lock_take "$LOCK_DIR" 50 || exit 1
    if other_runtime_active; then lock_drop "$LOCK_DIR"; refuse_other_runtime; fi   # 印を書くロックの中で、もう一度（5.6）
    pid=$(collector_pid_local); corg=$(kv_get "$COLLECTOR_F" ORG)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$pid" && [[ "$pid" != "$$" ]]; then
        if [[ "$corg" == "$org" ]]; then
            lock_drop "$LOCK_DIR"; note_log "取得役: すでに動いています（PID ${pid}）"; exit 0
        fi
        : > "${REQ_DIR}/stop"
        lock_drop "$LOCK_DIR"
        for ((i = 0; i < STOP_WAIT; i++)); do pid_alive "$pid" || break; sleep 1; done  # run 不使用: 止まるのを待つだけ
        pid_alive "$pid" && { note_log "取得役: 前の取得役（PID ${pid}）が止まりません"; exit 1; }
        lock_take "$LOCK_DIR" 50 || exit 1
        if other_runtime_active; then lock_drop "$LOCK_DIR"; refuse_other_runtime; fi
    fi
    rm -f "${REQ_DIR}/stop"
    # RUNTIME・HEARTBEAT: 別の環境から、扱っている環境と、生きているかが分かるように（5.6）
    kv_set "$COLLECTOR_F" "PID=$$" "STARTED=${started}" "ORG=${org}" "RUNTIME=${RUNTIME_SELF}" "HEARTBEAT=${started}"
    claim_refresh_locked "$started"
    lock_drop "$LOCK_DIR"
    IS_COLLECTOR=1; HB_LAST=$started
    state_set "$STATUS_F" "STATE=collecting" "ORG=${org}" "REASON=" "WARNING=" || true   # 意図的エラー無視: 表示用
    note_log "取得役: 起動しました（PID $$・組織 ${org}・間隔 ${INTERVAL} 秒）"
    COLLECT_EXPIRES=$(kv_get "$STATUS_F" EXPIRES)  # VAR=$(cmd) のため run 不使用
    backoff=$INTERVAL

    # 2. 繰り返す
    while true; do
        [[ $first -eq 1 ]] || sleep "$TICK"  # run 不使用: 目を覚ますまで待つだけ（sf は呼ばない）
        first=0
        heartbeat   # 生きている合図（5.6）
        now=$(date +%s)
        # a. 持ち主の見張り
        n=$(owners_prune)
        [[ "$n" == "-1" ]] && { note_log "取得役: 後始末の最中のため止まります"; exit 0; }
        [[ "$n" == "0" ]] && collector_finish "持ち主（sf-start）がいなくなったため、止まりました"
        [[ $((now - started)) -ge $MAX_RUN ]] && collector_finish "12 時間で止まりました。sf-start をやり直すと再開します"
        # b. 停止の依頼・後始末の最中・印の入れ替わり
        collector_should_quit && exit 0
        # c. 取得（間隔が来た・pull の依頼がある・前回の取り残しがある）
        # sf の更新（sf-update-cli.sh）が動いているあいだは、取らずに次に回す（sf の入れ替えの途中に、sf を呼ばない）
        if { [[ $now -ge $next ]] || has_pull_request; } && ! upgrade_running; then
            if lock_take "$FETCH_LOCK" 1; then
                rc=0; fetch_round || rc=$?
                LATE_WARN=""
                [[ $rc -eq 0 ]] && late_recheck   # 追いついた回だけ。目録に書き終えてから、下で pull に応える（9.3）
                lock_drop "$FETCH_LOCK"
                cnt=$(count_today)  # VAR=$(cmd) のため run 不使用
                case "$rc" in
                    0) respond_pulls ok; backoff=$INTERVAL; next=$(( $(date +%s) + INTERVAL ))
                       state_set "$STATUS_F" "STATE=collecting" "LAST_FETCH=$(date '+%H:%M')" "COUNT_TODAY=${cnt}" "BACKLOG=0" "WARNING=${LATE_WARN}" "LATE_WARNING=${LATE_WARN}" || true ;;
                    2) next=0
                       state_set "$STATUS_F" "LAST_FETCH=$(date '+%H:%M')" "COUNT_TODAY=${cnt}" "BACKLOG=50 本以上" || true ;;
                    *) respond_pulls error; backoff=$(( backoff * 2 > 600 ? 600 : backoff * 2 )); next=$(( $(date +%s) + backoff ))
                       state_set "$STATUS_F" "WARNING=取得に失敗しました（${backoff} 秒後にやり直します）" || true ;;
                esac
                # d. TraceFlag の残りが 60 分未満なら、今から 2 時間に延ばす（取得のあとに確かめる）
                if [[ "$COLLECT_EXPIRES" =~ $ISO_RE ]]; then
                    soon=$(aj time add "$(now_z)" --sec 3600)
                    if [[ "$(aj time cmp "$COLLECT_EXPIRES" "$soon")" == "-1" ]]; then
                        collector_extend || note_log "取得役: TraceFlag を延ばせませんでした"
                    fi
                fi
            fi
        fi
        # 5 分より古い依頼・応答を消す（pull が待つのをやめたあとの残り）
        find "$REQ_DIR" -type f -mmin +5 -exec rm -f {} + 2>/dev/null || true   # 意図的エラー無視: 掃除だけ
    done
}

# ------------------------------------------------------------------------------
# 10. status（4.6）・auto（4.7）
# ------------------------------------------------------------------------------
# 「N 秒前」の表示（分からなければ、そう書く）
ago_text() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s 秒前' "$1"; else printf '時刻が分からない'; fi; }

# status の取得役の行（5.6）。別の環境が扱っているか・記録が読めるかで、言い切らない
status_collector_line() {
    local cpid now hb crt
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    if other_runtime_active; then
        crt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
        if [[ "$OTHER_SRC" == "claim" && ( ! -f "$COLLECTOR_F" || "$crt" != "$(kv_get "$CLAIM_F" RUNTIME)" ) ]]; then
            echo "  取得役: 取得役の起動待ち（環境 ${OTHER_RT}・名乗りは $(ago_text "$OTHER_AGO")）"
        elif [[ "$OTHER_SRC" == "collector" && -z "$crt" ]]; then
            echo "  取得役: 状態不明（環境の記録のない、古い形の取得役の記録です。起動から 12 時間は、動いているものとみなします）"
        else
            hb=$(kv_get "$COLLECTOR_F" HEARTBEAT)  # VAR=$(cmd) のため run 不使用
            [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && hb=$((now - hb)) || hb=""
            echo "  取得役: 別の環境（${OTHER_RT}）で動作中（最後の合図は $(ago_text "$hb")・組織 $(kv_get "$COLLECTOR_F" ORG)）"
        fi
        return 0
    fi
    if [[ -f "$COLLECTOR_F" ]] && ! [[ "$(kv_get "$COLLECTOR_F" PID)" =~ ^[0-9]+$ && "$(kv_get "$COLLECTOR_F" STARTED)" =~ ^[0-9]+$ ]]; then
        echo "  取得役: 状態不明（${COLLECTOR_F} の形が正しくありません）"
        return 0
    fi
    cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$cpid"; then
        echo "  取得役: 動作中（PID ${cpid}・組織 $(kv_get "$COLLECTOR_F" ORG)・間隔 ${INTERVAL} 秒）"
    elif [[ -f "$CLAIM_F" ]] && same_rt "$(kv_get "$CLAIM_F" RUNTIME)"; then
        hb=$(kv_get "$CLAIM_F" AT)  # VAR=$(cmd) のため run 不使用
        [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && hb=$((now - hb)) || hb=""
        echo "  取得役: 取得役の起動待ち（この環境・名乗りは $(ago_text "$hb")）"
    else
        echo "  取得役: 動いていません"
    fi
}

cmd_status() {
    local k v j tsv id type st ex state dl mine n s
    echo "デバッグログ（sf-log.sh）の状態"
    status_collector_line
    # 表示の状態（.status）と、取得の記録（.state）。同じ名前のキーがあるため、どちらの値かを見出しで分ける
    for k in STATE ORG EXPIRES LAST_FETCH COUNT_TODAY BACKLOG REASON WARNING; do
        v=$(kv_get "$STATUS_F" "$k"); [[ -n "$v" ]] && echo "  表示の状態 ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    for k in ORG TRACE_FLAG_ID LAST_FETCH LATE_FROM LAST_READ_LINE; do
        v=$(kv_get "$STATE_F" "$k"); [[ -n "$v" ]] && echo "  取得の記録 ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    v=$(grep -c -v '^CLOSING=' "$OWNERS_F" 2>/dev/null || true); echo "  持ち主（起動中の sf-start）: ${v:-0}"   # VAR=$(cmd) のため run 不使用
    v=$(kv_get "$CONSENT_F" AUTO); echo "  自動（sf-start のとき）: ${v:-まだ答えていません}"
    if [[ -f "$INDEX_F" ]]; then echo "  手元のログ: $(wc -l < "$INDEX_F" | tr -d ' ') 本"; fi
    [[ -f "${APEX_DIR}/latest.md" ]] && echo "  最新の要約: ${APEX_DIR}/latest.md"
    prepare_org light
    # 表示の状態（.status）が、別の組織の古い記録なら、言い切らない（5.6）
    v=$(kv_get "$STATUS_F" ORG)  # VAR=$(cmd) のため run 不使用
    [[ -n "$v" && "$v" != "$TARGET_ORG" ]] && echo "  表示の状態: 状態不明（別の組織（${v}）の記録です。接続先は ${TARGET_ORG}）"
    mine=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    # 組織への問い合わせに失敗しても、止めずに、その旨を表示する（手元の状態は、上で表示済み）
    tsv=""
    if ! j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'"); then
        echo "  このユーザーの TraceFlag: 組織に問い合わせできませんでした（$(sf_err_name "$j")）"
    elif ! tsv=$(printf '%s' "$j" | aj tflist); then
        echo "  このユーザーの TraceFlag: 検索の応答の形が正しくありません"; tsv=""
    else
        echo "  このユーザーの TraceFlag（組織: ${TARGET_ORG}）:"
        [[ -n "$tsv" ]] || echo "    なし"
    fi
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ -n "$id" ]] || continue
        echo "    ${id}  ${type}  ${state}  期限 ${ex}  ${dl}$([[ "$id" == "$mine" ]] && echo '  （sf-log.sh が作ったもの）')"
    done <<< "$tsv"
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT COUNT(Id) n, SUM(LogLength) s FROM ApexLog WHERE LogUserId = '${USER_ID}'") || j=""
    n=$(json_get "$j" result.records.0.n 2>/dev/null) || n=""   # VAR=$(cmd) のため run 不使用
    s=$(json_get "$j" result.records.0.s 2>/dev/null) || s=""   # VAR=$(cmd) のため run 不使用
    [[ "$n" =~ ^[0-9]+$ ]] && echo "  組織にある自分のログ: ${n} 本・$(( ${s:-0} / 1024 ))KB"
    exit 0
}

cmd_auto() {
    prepare_org light
    state_set "$CONSENT_F" "AUTO=${AUTO_ARG}" "ORG=${TARGET_ORG}" "ORG_ID=${ORG_ID}" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" \
        || die "答えを書けませんでした。"
    if [[ "$AUTO_ARG" == "on" ]]; then
        log "SUCCESS" "このプロジェクトでは、sf-start のときにデバッグログを自動で取ります（組織: ${TARGET_ORG}）。"
    else
        log "SUCCESS" "このプロジェクトでは、sf-start のときにデバッグログを取りません（動いている取得は止めません。今止めるなら sf-log.sh stop）。"
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# 10b. begin（5.1。sf-start の前面）: sf を呼ばずに判定し、準備と取得役を裏で起動する
#   ランチャーを待たせないため（start --auto は sf を約 7 回呼び、実機で約 1 分かかった。2026-11-23。13.3）
# ------------------------------------------------------------------------------
cmd_begin() {
    AUTO=1   # 取らないときは、終了コード 10 で返す（sf-start を止めない）
    TARGET_ORG="$ORG_ARG"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        log "INFO" "GitHub Actions の上では、デバッグログを取りません。"
        exit 10
    fi
    is_reserved_org_alias "$TARGET_ORG" && finish_auto_or_die 10 "${TARGET_ORG} は共有環境（予約名）のため"
    consent_local || finish_auto_or_die 10 "このプロジェクトでは、自動で取らない設定のため"
    local rc=0
    register_owner "$OWNER" || rc=$?
    [[ $rc -eq 2 ]] && refuse_other_runtime   # 同じロックの中で、別の環境が名乗っていた（5.6）
    [[ $rc -eq 0 ]] || finish_auto_or_die 10 "前の後始末が終わらないため（${CLOSING_WAIT} 秒待ちました）"
    state_set "$STATUS_F" "STATE=starting" "ORG=${TARGET_ORG}" "REASON=" "WARNING=" "EXPIRES=" "EXPIRES_AT=" "BACKLOG=" || true   # 意図的エラー無視: 表示用
    # 裏で準備し、成功したらそのまま取得役になる（本番・種類の確認・組織 ID の照らし合わせは、start --auto が行う）
    # 裏での起動のため run 不使用。端末の入力・出力から切り離す。ふつうの出力は、取得役が log で同じログに書くため捨て、
    # エラー出力（bash のエラーなど、log を通らないもの）は、このスクリプトのログに追記する（捨てると、裏の失敗を追えない）
    #   --retry 1: 準備が失敗したら（「取らない」判断を除く）、持ち主が生きていれば、30 秒後に 1 回だけやり直す（retry_prepare）
    nohup bash "${SCRIPT_DIR}/sf-log.sh" start --auto --collect --retry 1 -o "$TARGET_ORG" --owner "$OWNER" </dev/null >/dev/null 2>>"$LOG_FILE" &
    disown
    log "INFO" "デバッグログの準備を、裏で始めました（組織: ${TARGET_ORG}）。状態は、ランチャーに表示します。"
    exit 0
}

# ------------------------------------------------------------------------------
# 11. 入口
# ------------------------------------------------------------------------------
# 環境の判断（4.1 の 1a・5.6）: 手元のファイル（.collector・.claim）だけを読む。別の環境が扱っていれば、status 以外は、ここで終える
if [[ "$CMD" != "status" ]] && other_runtime_active; then refuse_other_runtime; fi
case "$CMD" in
    begin)   cmd_begin ;;
    start)   cmd_start ;;
    pull)    cmd_pull ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    auto)    cmd_auto ;;
    collect) cmd_collect ;;
    leave)   cmd_leave ;;
esac
