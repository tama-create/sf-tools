#!/bin/bash
# ==============================================================================
# sf-metasync.sh - Salesforce メタデータ Git 自動同期スクリプト
# ==============================================================================
# main の組織（sf-project で 1 番目に登録した組織。本番・Sandbox・Developer Edition のどれでもよい）から、メタデータを取得し、
# main ブランチの「同期の対象のフォルダ」（【補足】）を、取得した内容と同じにして（追加・変更・削除）、コミットして push する。
# staging・develop のブランチへは、伝播しない（2026-11-26 にやめた。doc/one-way-promotion-design.md 3.7。開発のブランチが、sf-push.sh で main を取り込む）。
# Salesforce 組織の内容を正とする。どのブランチから実行しても、main に切り替えて処理し、終了時に元のブランチへ戻る。
# 設計: doc/sf-metasync-redesign.md
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-metasync.sh [オプション]     # force-* ディレクトリで実行する（管理者向け）
#
# 【オプション】
#   -n, --dry-run         : 手順 9 の計画の表示までで終了する（作業ツリーの変更・コミット・push は行わない）。
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
#                gh variable get SF_ORG_ID_PROD（sf-project が記録した、1 番目の組織の ID）を読み、sf org list --json の
#                ログイン済みの組織から、ID（上位 15 文字）が一致するものを探して、そのユーザー名を接続先にする。
#                次のどれかなら、何も変更せずに中断する（推測して別の組織に進まない。prod エイリアスには、フォールバックしない）:
#                origin から特定できない／ SF_ORG_ID_PROD を読み取れない／ 一致する組織が、この PC の sf にない
#          GitHub Actions 上: ワークフローが JWT で作る prod エイリアスを使う（接続先の決定には、gh を使わない）
#      - sf org display --target-org <接続先> --json の終了コードが 0 であること。
#        出力は、表示もログへの記録もしない（アクセストークンを含むため）
#      - 現在の HEAD がブランチを指していること（git symbolic-ref -q HEAD の終了コードが 0。detached HEAD では中断する）
#      - ./sf-tools/config/metadata.txt が存在すること（コメント行・空行を除いた各行を、取得するメタデータの種類とする。
#        行末の CR は除く）
#   3. 管理者向けの警告を表示し、続行の確認（Y/N）を取る。N・q なら中断する（GitHub Actions 上では、表示・確認しない）
#   4. リポジトリが公開でないことを確認する（手順 3 のあと、切り替えの前。gh api repos/<owner>/<repo> --jq .visibility が private か
#      internal。常に確認する。切り替えはない。失敗時は 3 回まで試す）。公開（public）、または確認できない（gh の失敗・権限不足・
#      GitHub Actions 上で GH_TOKEN がない）ときは、何も取得せず、Slack に通知して、終了コード 5 で止める（--dry-run のときは、通知しない）。
#      Salesforce 組織の開発物を、外部にさらさないため
#      main ブランチへ切り替える（実行時のブランチが main 以外のとき）→ リモートの最新を取り込む
#      - 追跡中のファイルに未コミットの変更があれば、git stash で退避してから git checkout main する
#      - main で、追跡中のファイルに未コミットの変更があれば、中断する（ローカルの変更は、同期に含めない）
#      - 手元で実行したときは、追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）があっても、中断する（【補足】）
#      - git fetch origin（失敗しても WARNING を表示して続行）→ git pull origin main --rebase
#        （失敗したら git rebase --abort して中断する）
#   5. 一時プロジェクトの準備: sfdx-project.json の packageDirectories が 1 つでなければ、中断する（S8）。
#      一時フォルダ（${TMPDIR:-/tmp}/sf-metasync-XXXXXX）に、sfdx-project.json と .forceignore（あれば）を写す。
#      作業ツリーには、まだ何も書かない。
#      続けて、環境変数 SF_METASYNC_DETECT が shadow または on のとき、変更の検知を行う（node lib/metasync.js detect。読み取りのみ。
#      設定変更の履歴と、更新日時の一覧で、組織に変更があるかを、全件取得の前に調べる）。on で、結果が「変更なし」のときは、取得を
#      省く（下の「取得を省くのは」の条件。指紋も on なら、指紋も変更なしのときだけ）。
#      検知の失敗・不明・変更ありは、すべて、手順 6 の全件取得に進む（検知は、取得を省くための手がかりで、失敗が取りこぼしにならない）。
#      続けて、環境変数 SF_METASYNC_FINGERPRINT が shadow または on のとき、一覧の指紋を作る（node lib/metasync.js fingerprint。読み取りのみ。
#      config/metasync-fingerprint.txt の種類ごとに、組織の一覧を Node 直接の SOAP（listMetadata）で取り、件数・最新の更新日時・
#      名前と更新日時のハッシュを、前回（./sf-tools/metasync/fingerprint.json）と比べる。管理パッケージ本体の部品は除く）。
#      取得の範囲（metadata.txt の種類と、SF_METASYNC_EXTRA が on のときの config/metasync-extra.txt）が前回と変わった回は、不明にする
#      （組織が同じでも、ファイルが増減するため。影の比較で、見逃しに数えない）。
#      shadow は、取得を省かない（影の比較）。指紋の失敗・不明は、取得を止めない（WARNING を出して、全件取得に進む）。
#      取得を省くのは、検知・指紋のうち on のものが 1 つ以上あり、on のものが「すべて」変更なしのときだけ（--full・--dry-run でなく、
#      未プッシュのコミットがないとき）。このときは、手順 6 以降を行わず、終了する（コミット・push はしない）。
#      on のものが 1 つでも、変更あり・不明・行わなかった（表がない）なら、全件取得する（検知と指紋が両方 on で、結果が分かれたときも）。
#      shadow のものは、判定に使わない。shadow のものが「変更あり」なのに、on のものが「変更なし」で省くときは、食い違いの WARNING を出す
#      （on のものの見逃しの可能性。毎日の --full で反映される）
#   6. 組織からメタデータを取得する: 一時フォルダで sf project retrieve start --target-org prod --ignore-conflicts --json に、
#      metadata.txt の全種類を --metadata で指定して実行する。取得先は一時フォルダのため、失敗しても作業ツリーは変わらない。
#      終了コードが 0 以外で、応答が一時的なエラー（MetadataTransferError・ERROR_HTTP_404・接続の切断・503 など）なら、60 秒待って
#      1 回だけやり直す（環境変数 SF_METASYNC_RETRY_WAIT で秒数を変えられる）。それでも失敗したら、中断する
#      続けて、環境変数 SF_METASYNC_EXTRA が on のとき、追加の取得（設計 16 章の P2）を行う: 現行の取得で取れていないもの（レポート・ダッシュボード・
#      メールテンプレートとそのフォルダ、StandardValueSet、標準オブジェクト上の項目・入力規則・リストビュー・レコードタイプなど。config/metasync-extra.txt）の
#      名前を、組織の一覧から集め（node lib/metasync.js manifest。管理パッケージ本体は除く）、package.xml で、同じ一時フォルダへ取る
#      （sf project retrieve start --manifest。一時的なエラーは 1 回やり直す）。失敗しても、同期は止めない: 手順 8 の plan が、その種類のフォルダと
#      標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除を、すべて保留する（取れなかったものを、削除と取り違えない）。
#      取れたかどうかは、応答の文言ではなく、ディスクで確かめる: 指定した名前（package.xml）のうち、取得結果にファイルがない名前は、そのファイルの削除だけ
#      保留する。既定は off（off のときも、手順 8 の plan は、標準オブジェクトの部品の削除を保留する。on で取ったファイルを、off に戻した回に消さないため）
#   7. 直近にマージされたファイルの一覧を作る（S5 用）: 直近 24 時間に、同期以外のコミットで変わった、同期の対象のパス
#      （git log --first-parent -m --since="24 hours ago" --invert-grep --grep=<同期のコミットの件名> --name-only）
#   8. 計画を作る（node lib/metasync.js plan）: 同期の対象のフォルダごとに、手元と取得結果を比べる。追加・変更・削除と、
#      削除の守りで保留にした分（ファイルは残す）を決める。保留の条件（lib/metasync.js の冒頭に詳細）:
#        S2 取得の応答に、問題の報告がある ／ S3 手元に 1 件以上あったフォルダが、取得結果で 0 件 ／
#        S4 削除の件数が max(100, 手元の同期の対象のファイルの 10%) を超える ／ S5 手順 7 の一覧にあるファイル ／ S9 追加の取得を行わない設定（off）のときの、標準オブジェクトの部品
#        （S5・S9 は、終了コードを 3 にしない）
#      取得の応答の status が 0 以外（S1）のときは、中断する。
#      続けて、指紋を作っていれば、影の比較を表示する（node lib/metasync.js fpcompare。指紋の結果と、計画の追加・変更・削除を、
#      フォルダ（objects は子の種類）ごとに突き合わせ、「検知できた」「見逃し」「日時では検知できない種類」「指紋の対象外」を数える。
#      見逃しだけが WARNING（Profile など、更新日時が動かない種類は、見逃しと分ける）。
#      指紋が変わったのに変更がなかった種類（空振り）も出す（S3・S4 で削除を保留した種類は、空振りにせず、別に出す）。指紋が不明のときは、比べない。情報のみで、同期には影響しない）
#      続けて、秘密情報の検査（SF_METASYNC_SECRET_SCAN が off 以外。node lib/metasync.js scan）: これから書く内容（計画の追加・変更。
#      取得結果と手元を比べ、今回新しく入る分だけ）に、秘密の疑い（秘密らしい要素・項目への値、秘密鍵、既知のトークンの形、コードへの直書き）が
#      ないか調べる。作業ツリーは、まだ触らない。値は、ログにも通知にも出さない（規則名とパスだけ）。許可の一覧: ./sf-tools/config/metasync-secret-allow.txt
#      （1 行に「規則 パス [キー]」。キーは、疑いの表示の「キー: …」= 項目名・ラベル名・要素名・変数名。省略すると、そのパスの規則すべて）。
#      バイナリは、秘密鍵・既知のトークンだけ探し、20 MB 超は検査しない（どちらも、検査に制限があったファイルとして、名前を出す）。
#      数 MB の連続した文字列などで規則が失敗したファイルは、疑い（規則 scan-error）として扱う（on では止まる。確かめたら許可の一覧で外す）。
#      shadow は、WARNING で出すだけで止めない。on は、疑いがあれば、何もコミット・push せず、Slack に通知して、終了コード 4 で止める
#      （検査そのものが失敗したとき（許可の一覧の書式の誤りなど）も、on なら、同じく通知して終了コード 4。--dry-run のときは、通知しない）
#   9. 計画の要約（件数・削除の一覧の先頭 30 件・保留とその理由）を表示する。手元で、変更があるときは、続行の確認
#      （Y/N。N・q なら中断する）を取る（GitHub Actions 上では、表示のみ）。--dry-run は、ここで終了する
#   10. 計画を作業ツリーに反映する（node lib/metasync.js apply。保留の削除は、行わない）
#   11. （手順 5 の検知が、変更あり・不明のとき）検知の状態を ./sf-tools/metasync/state.json に書く。
#      （手順 5 の指紋が、変更あり・不明のとき）指紋の状態を ./sf-tools/metasync/fingerprint.json に書く（検知の状態とは別のファイル）。
#      git add -A -- <パッケージのフォルダ>（と、書いたときは状態ファイル。sf-tools/release/ は含めない）でステージし、HEAD との差分で分岐する
#      - 差分あり: 「定期更新: Salesforce変更の自動反映 (YYYY-MM-DD)」でコミットし（本文に件数）、git push --no-verify origin main する
#      - 差分なし・origin/main より先のコミットあり（前回の同期の push の失敗など）: そのコミットの一覧（git log --oneline）を
#        表示して確認を取り、git push --no-verify origin main だけ行う（GitHub Actions 上では、確認しない）
#      - 差分なし・先のコミットなし: 「完了: Salesforce 組織側に変更はありませんでした。」と表示して終了する
#      コミット・push の失敗は、中断する
#   12. （なし。以前は、main の変更を、staging・develop のブランチへ伝播（マージして push）していた。2026-11-26 にやめた。
#      一方通行の原則（開発物は develop → staging → main の上りだけ。doc/one-way-promotion-design.md 3.7）。main の最新は、
#      開発者の PC で sf-push.sh が取り込む）。手順 11 で push したら、その旨を INFO で表示する
#   13. 終了時（手順 2 の HEAD の確認より後に、中断したときも）: 手順 10 のあと、コミットの前に中断したときは、
#       同期の対象のパッケージのフォルダを HEAD に戻す（git reset -q HEAD -- ・git checkout HEAD -- ・git clean -fdq --）。
#       元のブランチへ git checkout し、手順 4 で退避していれば git stash pop する。一時フォルダを削除する
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する（終了コード 1）
#   - 手元で実行するとき: main の組織（sf-project で 1 番目に登録した組織）が、この PC の sf にログイン済みであること
#     （エイリアスの名前は、何でもよい。sf-project は、この PC の sf にエイリアスを残さない。sf org login web --alias <名前> などでログインする）。
#     gh が使え、リポジトリの Variable（SF_ORG_ID_PROD）を読めること
#   - Salesforce CLI（sf）は npm 版であること。手順 1 の確認は、成功したら 24 時間は省略する（GitHub Actions 上では、確認しない）
#   - node があること（sf が npm 版のため、通常はある）。sf のプラグインは不要（以前使っていた sfdx-git-delta は、使わない）
#   - 変更の検知（SF_METASYNC_DETECT が shadow・on）を使うときは、接続ユーザーに「設定・定義の参照」の権限があること
#     （ないと、履歴の問い合わせが失敗し、毎回、全件取得になる）
#
# 【補足】
#   - 一覧の指紋（設計: doc/sf-metasync-redesign.md 16 章の P1・P4）: 環境変数 SF_METASYNC_FINGERPRINT（既定 off）。off = 行わない ／
#     shadow = 指紋を作って前回と比べ、実際の変更との食い違い（見逃し）を、ログに記録する。取得は、常に行う ／
#     on = shadow と同じことに加え、指紋が「変更なし」のとき、取得を省く（手順 5）。指紋の表（config/metasync-fingerprint.txt）にない種類
#     （Settings・SharingRules・ConnectedApp・StandardValueSet・AssignmentRules など）だけの変更は、毎日の --full の回まで反映されない
#     （GitHub Actions では、平日の日本時間 9:00。金曜の夕方の変更は、月曜の朝）。設定変更の履歴で補うなら、SF_METASYNC_DETECT も on にする。
#     状態は ./sf-tools/metasync/fingerprint.json（変更あり・不明の回にだけ更新する）。
#     接続: sf org display のアクセストークンで、Node から SOAP を直接呼ぶ（現行の sf は、org display のトークンを伏せ字で返すため、
#     そのときは、最初から sf org auth show-access-token で取る。本物が返る古い sf では、期限切れのときだけ取り直す。
#     トークンは、ログに出さない。https のインスタンス URL にだけ送り、転送は追わない）。Node 18 以上が必要（fetch を使う）。
#     応答が SOAP でない・待ちの期限切れ（1 回 30 秒・全体 180 秒。sf の呼び出しを含む）・フォルダが 900 個超は、失敗として扱う
#     （不明。取得は止めない）。Node の fetch は HTTPS_PROXY を使わないため、プロキシ越しでは指紋は常に不明になる（取得は行う）。
#     影の比較の「見逃し」は、指紋を取ったあとに組織が変わった回にも出る（次の回の「空振り」と対で見る）。
#   - 変更の検知: 環境変数 SF_METASYNC_DETECT（既定 off）。off = 行わない（従来どおり、毎回、全件取得）／
#     shadow = 検知の結果をログに出すが、取得は常に行う（検知が「変更なし」なのに、実際は変更があったときは、WARNING で
#     その一覧を出す。運用の前の確かめ用）／ on = 「変更なし」のとき、取得を省く（指紋も on なら、両方が変更なしのときだけ）。種類ごとの区分は config/metasync-detect.txt
#     （A 履歴・B 更新日時の一覧。表にない種類は C = 毎日の全件取得でだけ反映される。最大約 1 日の遅れ）。
#     off 以外では、状態を ./sf-tools/metasync/state.json に持つ（最後に全件取得した時刻と、区分 B の記録。変更あり・不明の
#     全件取得のあとにだけ更新するため、変更のない回は、コミットを作らない。ファイルが変わらず、状態だけが変わるときは、
#     状態だけのコミットになる）。状態は、速くするための手がかりで、壊れていても全件取得になる。設計: doc/sf-metasync-redesign.md 15 章
#   - 終了コード: 0（同期した・変更がなかった）／ 1（中断した）／ 3（同期した（追加・変更の push まで行った）が、
#     削除の保留（S2・S3・S4）がある。GitHub Actions では、ジョブが失敗として表示される）。S5・S9 の保留だけのときは 0 ／
#     4（秘密の疑いで止めた。何もコミット・push していない）／ 5（公開リポジトリ、または公開・非公開を確認できず、取得せずに止めた）
#   - 追加の取得（設計: doc/sf-metasync-redesign.md 16 章の P2）: 環境変数 SF_METASYNC_EXTRA（off / on。既定 off）。対象の種類は、各プロジェクトの metadata.txt ではなく、
#     sf-tools の config/metasync-extra.txt で決める（sf-tools の更新だけで、既存の force-* に届く）。Document・ContentAsset は取らない。
#     on にすると、初回は、レポートなどが大量に追加される。on から off に戻した回は、標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除を保留し、
#     取得結果に現れない追加の取得のフォルダ（reports など）は、同期の対象にしない（on で取ったファイルを消さない）。取得したものは、手順 8 の秘密情報の検査の対象になる
#   - 秘密情報の検査・公開リポジトリの拒否・Slack 通知（設計: doc/sf-metasync-redesign.md 16.7）: 環境変数 SF_METASYNC_SECRET_SCAN
#     （off / shadow / on。既定 shadow = 検査して WARNING を出すが、止めない。誤検知を測ってから on にする）。Slack に通知するのは、
#     on で秘密の疑いにより止めたとき（終了コード 4）と、公開リポジトリで止めたとき（終了コード 5）だけ。SLACK_BOT_TOKEN・SLACK_CHANNEL_ID
#     （wf-release.yml と同じもの）が未設定でも、止める（通知できない旨の WARNING のみ）。公開・非公開の確認に、GitHub Actions 上では GH_TOKEN が要る
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
#   - main への push（手順 11）は、--no-verify（pre-push フックを通さない）。pre-push フック
#     （sf-prepush.sh）は、branches.txt のブランチ（保護ブランチ）の上からの push・保護ブランチへの push を、必ず拒否するため
#     （手元で実行したとき、--no-verify がないと、main への push が失敗する）。サーバー側の保護（Ruleset）は、そのまま効く

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

# 一覧の指紋のモード（設計 16 章の P1・P4。off = 行わない（既定）／ shadow = 指紋を作って前回と比べ、実際の変更との食い違いを記録する。
#   取得は常に行う／ on = shadow と同じことに加え、指紋が「変更なし」なら取得を省く（P4））
readonly FP_MODE="${SF_METASYNC_FINGERPRINT:-off}"
[[ "$FP_MODE" == "off" || "$FP_MODE" == "shadow" || "$FP_MODE" == "on" ]] \
    || die "SF_METASYNC_FINGERPRINT は off / shadow / on のどれかにしてください: ${FP_MODE}"

# 秘密情報の検査のモード（設計 16.7。off = 行わない／ shadow = 検査して、疑いを WARNING で出すが、止めない（既定。誤検知を測る期間）／
#   on = 疑いがあれば、何もコミット・push せず、全体を止める（終了コード 4）。止めたら Slack に通知する）
readonly SCAN_MODE="${SF_METASYNC_SECRET_SCAN:-shadow}"
[[ "$SCAN_MODE" == "off" || "$SCAN_MODE" == "shadow" || "$SCAN_MODE" == "on" ]] \
    || die "SF_METASYNC_SECRET_SCAN は off / shadow / on のどれかにしてください: ${SCAN_MODE}"
# 追加の取得のモード（設計 16 章の P2。off = 行わない（既定）／ on = 現行の取得のあと、もう 1 回、名前を指定して取得する:
#   レポート・ダッシュボード・メールテンプレート（とフォルダ）・StandardValueSet・標準オブジェクト上の項目や入力規則など。config/metasync-extra.txt）
readonly EXTRA_MODE="${SF_METASYNC_EXTRA:-off}"
[[ "$EXTRA_MODE" == "off" || "$EXTRA_MODE" == "on" ]] \
    || die "SF_METASYNC_EXTRA は off / on のどちらかにしてください: ${EXTRA_MODE}"
# 止めたときの終了コード（4 = 秘密の疑いで止めた／ 5 = 公開リポジトリ（または公開・非公開を確認できない）で止めた）
readonly EXIT_SECRET=4
readonly EXIT_PUBLIC=5

# ------------------------------------------------------------------------------
# 5. 固有設定
# ------------------------------------------------------------------------------
# 接続先の組織（main の組織。本番・Sandbox・Developer Edition のどれでもよい）
#   ・GitHub Actions 上: ワークフローが JWT で作る prod エイリアスを使う（接続先の決定には、gh を使わない）
#   ・手元: エイリアスの名前には頼らず、組織 ID で決める。sf-project が GitHub の Variable SF_ORG_ID_PROD に記録した、1 番目（main）の
#     組織の ID と、この PC の sf にログイン済みの組織の ID を突き合わせ、一致した組織のユーザー名を接続先にする。
#     名前は付け替えられ、同じ PC の別のプロジェクトと衝突する。ID で決めれば、取り違え（別のプロジェクトの組織で main を書き換える）を防げる。
#     見つからなければ、何も変えずに中断する（推測して、別の組織に進まない。prod エイリアスには、フォールバックしない）
# run 不使用: 終了コードで判定するため（run は、失敗しても、エラーの文言を標準出力に返すため、出力が空かでは判定できない）。
#   出力は捨てる（--json の出力には、アクセストークンが含まれる。run は、出力をログに記録する）
REPO_FULL=""   # このリポジトリの owner/repo（公開・非公開の確認と、Slack の通知に使う）
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    REPO_FULL="${GITHUB_REPOSITORY:-}"
    TARGET_ORG="prod"
    if ! sf org display --target-org "$TARGET_ORG" --json > /dev/null 2>&1; then
        die "prod エイリアスの組織情報を取得できませんでした（sf org display --target-org ${TARGET_ORG} が失敗しました）。"
    fi
    log "INFO" "接続先組織: ${TARGET_ORG}"
else
    require_origin_repo _repo_full   # origin から「owner/repo」（lib/project.sh。取れなければ die。URL は伏せて出す）
    REPO_FULL="$_repo_full"
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
readonly FP_STATE_FILE="sf-tools/metasync/fingerprint.json"   # 一覧の指紋の状態（main にコミットする。手順 11。検知の状態とは別のファイル）
FP_WRITTEN=0      # 1 = 指紋の状態ファイルを書いた（コミットする前に中断したら、戻す）

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
    # 指紋の状態ファイルも、同じように戻す
    if [[ "$FP_WRITTEN" -eq 1 && "$COMMITTED" -eq 0 ]]; then
        run git reset -q HEAD -- "$FP_STATE_FILE" 2>/dev/null
        run git checkout HEAD -- "$FP_STATE_FILE" 2>/dev/null || rm -f "$FP_STATE_FILE" 2>/dev/null   # rm は run 不使用: 終了時の後始末（失敗しても止めない）
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
            "[ERROR] "*)   log "ERROR" "${line#"[ERROR] "}" ;;
            *)             log "INFO" "$line" ;;
        esac
    done <<< "$text"
}

# Slack に通知する（chat.postMessage。wf-release.yml と同じ SLACK_BOT_TOKEN・SLACK_CHANNEL_ID）。引数: 見出し 行…
#   通知するのは、秘密の疑いで止めたとき・公開リポジトリで止めたときだけ（呼び出し側）。値（秘密）は、通知に入れない（パスと規則名だけ）。
#   未設定・失敗は、WARNING にとどめる（止める判断は、すでに済んでいる）。
#   run 不使用: トークンを含む引数を、ログに記録しないため。応答の本文は、ログに出さない（ok の可否と error の文言だけ）
notify_slack() {
    local token="${SLACK_BOT_TOKEN:-}" channel="${SLACK_CHANNEL_ID:-}"
    if [[ -z "$token" || -z "$channel" ]]; then
        log "WARNING" "Slack に通知できません（SLACK_BOT_TOKEN・SLACK_CHANNEL_ID が未設定です）。"
        return 0
    fi
    if ! command -v curl > /dev/null 2>&1; then  # 存在確認のため run 不使用
        log "WARNING" "Slack に通知できません（curl が見つかりません）。"
        return 0
    fi
    local text="$1" l resp _curl_ok
    shift
    for l in "$@"; do text+=$'\n'"$l"; done
    if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
        text+=$'\n'"実行: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    # JSON の文字列として安全にする（制御文字の除去（改行・タブ以外）・\ と " のエスケープ・改行の \n 化・タブの空白化・
    #   Slack の特殊文字 & < > の置き換え）。置き換えの文字列は、引用符で囲む（Bash 5.2 以降は、囲まないと、& が「一致した文字」に展開される）
    text=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')  # VAR=$(cmd) のため run 不使用
    text="${text//\\/\\\\}"; text="${text//\"/\\\"}"; text="${text//$'\r'/}"; text="${text//$'\n'/\\n}"; text="${text//$'\t'/ }"
    text=${text//&/"&amp;"}; text=${text//</"&lt;"}; text=${text//>/"&gt;"}
    channel="${channel//\"/}"; channel="${channel//\\/}"
    # トークンは、コマンドラインの引数に出さない（ps で見えるため）。curl の設定を標準入力（-K -）から渡す。printf は組み込みコマンド
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS --max-time 20 -K - -X POST "https://slack.com/api/chat.postMessage" \
        -H "Content-Type: application/json; charset=utf-8" \
        --data "{\"channel\":\"${channel}\",\"text\":\"${text}\"}" 2>&1) && _curl_ok=1 || _curl_ok=0
    if [[ "$resp" == *'"ok":true'* ]]; then
        log "INFO" "Slack に通知しました。"
    elif [[ "$resp" == *'"error":"'* ]]; then
        local err="${resp#*\"error\":\"}"; err="${err%%\"*}"
        log "WARNING" "Slack への通知に失敗しました（${err:0:60}）。SLACK_BOT_TOKEN・SLACK_CHANNEL_ID を確認してください。"
    else
        log "WARNING" "Slack への通知に失敗しました（接続または応答の異常。curl の終了: $([[ "$_curl_ok" -eq 1 ]] && echo 正常 || echo 失敗)）。"
    fi
    return 0
}

# 【VISIBILITY】リポジトリが公開でないことを確認する（設計 16.7.3。取得の前。切り替えはなく、常に行う）
#   private・internal だけ通す。公開、または確認できない（gh の失敗・権限不足・未知の値）ときは、何も取得せずに止める（終了コード 5）
#   公開リポジトリに、組織の開発物（Apex・設定など）を置くと、外部にさらすため
phase_check_visibility() {
    local vis="" try why
    # GitHub Actions 上で GH_TOKEN・GITHUB_TOKEN がどちらもないのは、wf-metasync.yml が古いとき（sf-tools は先に届く）。理由を分かるようにする
    local no_token=0
    [[ "${GITHUB_ACTIONS:-false}" == "true" && -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] && no_token=1
    if [[ -n "$REPO_FULL" && "$no_token" -eq 0 ]]; then
        # 一時的な API の失敗で止めないよう、3 回まで試す（失敗時、gh は標準出力にエラーの JSON を出すため、private・internal・public 以外は、確認できない扱い）
        for try in 1 2 3; do
            vis=$(gh api "repos/${REPO_FULL}" --jq .visibility 2>/dev/null) || vis=""  # VAR=$(cmd) のため run 不使用
            vis="${vis//$'\r'/}"
            case "$vis" in private|internal|public) break ;; esac
            vis=""
            [[ "$try" -lt 3 ]] && sleep "${SF_METASYNC_VIS_RETRY_WAIT:-3}"
        done
    fi
    case "$vis" in
        private|internal)
            log "INFO" "リポジトリの公開範囲: ${vis}（${REPO_FULL}）"
            return 0 ;;
    esac
    if [[ "$vis" == "public" ]]; then why="リポジトリが公開（public）です"
    elif [[ "$no_token" -eq 1 ]]; then why="リポジトリの公開・非公開を確認できませんでした（GH_TOKEN が渡されていません。wf-metasync.yml が古い可能性があります。sf-update-workflows.sh で更新してください）"
    else why="リポジトリの公開・非公開を確認できませんでした（${REPO_FULL:-不明}）"; fi
    log "ERROR" "${why}。Salesforce 組織の開発物を外部にさらさないため、取得せずに止めます。非公開（private）のリポジトリで実行してください。"
    [[ "$DRY_RUN" -eq 1 ]] || notify_slack ":no_entry: [metasync] 同期を止めました: ${REPO_FULL:-不明}" "理由: ${why}（取得は行っていません）"
    exit $EXIT_PUBLIC
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
    #   sf-tools/release/ は、作業ブランチの日常的な作業用ファイル（sf-refresh.sh が作る）のため、対象外（ステージもしない）。
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

# 【FINGERPRINT】一覧の指紋を作り、前回と比べる（手順 5。SF_METASYNC_FINGERPRINT が shadow・on のとき。読み取りのみ）
#   結果は FP_RC に入る: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明 ／ -1 = 行わなかった（off・表がない）。
#   取得を省くかは、呼び出し側（手順 5 の判定）が決める（on で 0 のときだけ省く。shadow は、取得を省かない影の比較）。
#   失敗は、取得を止めない（WARNING を出して、不明として全件取得に進む）
FP_RC=-1
FP_STATE_NEW=""
FP_REPORT=""
phase_fingerprint() {
    [[ "$FP_MODE" == "off" ]] && return $RET_OK
    local table="${SCRIPT_DIR}/../config/metasync-fingerprint.txt" out
    if [[ ! -f "$table" ]]; then
        log "WARNING" "指紋の種類の表が見つかりません（${table}）。指紋は作りません。"
        return $RET_OK
    fi
    FP_STATE_NEW="$WORK_DIR/fp.new.json"
    FP_REPORT="$WORK_DIR/fp.report.json"
    log "INFO" "一覧の指紋を作ります（SF_METASYNC_FINGERPRINT=${FP_MODE}。読み取りのみ）..."
    # 取得の範囲（metadata.txt の種類と、追加の取得の表。off のときは渡さない）も渡す。範囲が前回と変わった回は、指紋を不明（11）にする
    #   （組織が同じでも、取得の範囲の変更でファイルが増減するため。影の比較で、見逃しに数えない）
    local scope=(--types-file "$METADATA_CONFIG")
    [[ "$EXTRA_MODE" != "off" && -f "$EXTRA_TABLE" ]] && scope+=(--extra-config "$EXTRA_TABLE")
    # run 不使用: 戻り値（0 / 10 / 11）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" fingerprint --org "$TARGET_ORG" --fp-config "$table" --repo . "${scope[@]}" \
        --state "$FP_STATE_FILE" --out-state "$FP_STATE_NEW" --out-report "$FP_REPORT" 2>&1)
    FP_RC=$?
    _log_node_lines "$out"
    if [[ $FP_RC -ne 0 && $FP_RC -ne 10 ]]; then
        [[ $FP_RC -eq 11 ]] || log "WARNING" "指紋の作成が異常終了しました（終了コード ${FP_RC}）。不明として扱います（取得は、省かずに行います）。"
        FP_RC=11
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

# 【RETRIEVE-EXTRA】追加の取得（設計 16 章の P2。SF_METASYNC_EXTRA が on のとき。手順 6 のあと）
#   現行の取得で取れていないもの（フォルダ型・StandardValueSet・標準オブジェクト上の部品）の名前を、組織の一覧から集めて（node lib/metasync.js
#   manifest）、package.xml で取る（同じ一時プロジェクトへ）。結果は EXTRA_STATE に入る: ok = 取れた（取る部品がない場合を含む）／ failed = 失敗。
#   失敗しても、同期は止めない: plan が、その種類のフォルダと標準オブジェクトの部品の削除を、すべて保留する（取れなかったものを、削除と取り違えない）
#   run 不使用: 応答（JSON）を判定に使うため、ファイルへ受ける（phase_retrieve_metadata と同じ）
EXTRA_STATE="off"
EXTRA_JSON=""
EXTRA_TABLE="${SCRIPT_DIR}/../config/metasync-extra.txt"
phase_retrieve_extra() {
    [[ "$EXTRA_MODE" == "off" ]] && return $RET_OK
    EXTRA_STATE="failed"
    local manifest="$WORK_DIR/extra.package.xml" err="$WORK_DIR/extra.retrieve.err" out rc attempt
    EXTRA_JSON="$WORK_DIR/extra.retrieve.json"
    if [[ ! -f "$EXTRA_TABLE" ]]; then
        log "WARNING" "追加の取得の表が見つかりません（${EXTRA_TABLE}）。追加の取得は行いません（その種類の削除は保留します）。"
        return $RET_OK
    fi
    log "INFO" "追加の取得: 名前を集めます（SF_METASYNC_EXTRA=${EXTRA_MODE}。読み取りのみ）..."
    out=$("$NODE_BIN" "$METASYNC_JS" manifest --org "$TARGET_ORG" --extra-config "$EXTRA_TABLE" --repo . --out "$manifest" 2>&1)
    rc=$?
    _log_node_lines "$out"
    if [[ $rc -eq 12 ]]; then
        EXTRA_STATE="ok"
        log "INFO" "追加の取得: 取る部品がありません。"
        return $RET_OK
    fi
    if [[ $rc -ne 0 ]]; then
        log "WARNING" "追加の取得: 名前を集められませんでした。今回は取りません（その種類と標準オブジェクトの部品の削除は保留します）。"
        return $RET_OK
    fi
    for attempt in 1 2; do
        log "INFO" "追加の取得: 組織から取得します（package.xml。試行 ${attempt}/2）..."
        ( cd "$WORK_DIR" && sf project retrieve start --target-org "$TARGET_ORG" --ignore-conflicts --json --manifest "$manifest" ) > "$EXTRA_JSON" 2> "$err"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            EXTRA_STATE="ok"
            log "SUCCESS" "追加の取得: 完了"
            return $RET_OK
        fi
        log "WARNING" "追加の取得が失敗しました（終了コード ${rc}）: $(_mask_secrets "$(head -c 600 "$err"; head -c 600 "$EXTRA_JSON")" | tr '\n' ' ')"
        if [[ $attempt -eq 1 ]] && grep -qE 'MetadataTransferError|UNKNOWN_EXCEPTION|ERROR_HTTP_404|ECONNRESET|ETIMEDOUT|socket hang up|fetch failed|503|Service Unavailable' "$EXTRA_JSON" "$err" 2>/dev/null; then
            log "WARNING" "一時的なエラーの可能性があるため、${SF_METASYNC_RETRY_WAIT:-60} 秒待って 1 回だけやり直します。"
            sleep "${SF_METASYNC_RETRY_WAIT:-60}"  # run 不使用: 待機
            continue
        fi
        break
    done
    log "WARNING" "追加の取得は行えませんでした。その種類と標準オブジェクトの部品の削除は保留します。"
    return $RET_OK
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
    # 追加の取得の扱い: off でも表と状態（off）を渡す（on で入れた標準オブジェクトの部品を、off に戻した回に消さないため）。on は、結果（ok / failed）と、
    #   取るのに使った package.xml（取れたかを、ディスクで確かめる）も渡す
    if [[ "$EXTRA_MODE" == "on" && ! -f "$EXTRA_TABLE" ]]; then
        log "ERROR" "追加の取得の表が見つかりません（${EXTRA_TABLE}）。標準オブジェクトの部品を守れないため、計画を作りません（sf-tools の更新を確認してください）。"
        return $RET_NG
    fi
    if [[ -f "$EXTRA_TABLE" ]]; then
        if [[ "$EXTRA_MODE" == "on" ]]; then
            args+=(--extra-config "$EXTRA_TABLE" --extra-json "$EXTRA_JSON" --extra-state "$EXTRA_STATE")
            [[ "$EXTRA_STATE" == "ok" && -f "$WORK_DIR/extra.package.xml" ]] && args+=(--extra-manifest "$WORK_DIR/extra.package.xml")
        else
            args+=(--extra-config "$EXTRA_TABLE" --extra-state off)
        fi
    fi
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
    # 一覧の指紋の影の比較（実際の変更と、指紋の変化を突き合わせて、見逃しを記録する。情報のみ。失敗しても、同期は続ける）
    if [[ "$FP_MODE" != "off" && "$FP_RC" -ge 0 && -f "$FP_REPORT" ]]; then
        local cmp
        cmp=$("$NODE_BIN" "$METASYNC_JS" fpcompare --report "$FP_REPORT" --plan "$PLAN_FILE" \
            --fp-config "${SCRIPT_DIR}/../config/metasync-fingerprint.txt" --dirs-table "${SCRIPT_DIR}/../config/metadata-dirs.txt" 2>&1) \
            || log "WARNING" "指紋の影の比較に失敗しました（同期には影響しません）。"  # run 不使用: 出力を変数に受ける
        [[ -n "$cmp" ]] && _log_node_lines "$cmp"
    fi
    return $RET_OK
}

# 【SCAN】これから書く内容（計画の追加・変更）に、秘密情報の疑いがないか検査する（設計 16.7。反映の前・コミットの前。読み取りのみ）
#   取得結果（一時フォルダ）と、手元のファイルを比べて、今回新しく入る疑わしい文字列だけを調べる。作業ツリーは、まだ触らない
#   （止めても、戻すものがない）。値は、ログにも通知にも出さない（規則名とパスだけ）。許可の一覧: ./sf-tools/config/metasync-secret-allow.txt
#   on で疑いがあれば、Slack に通知して、終了コード 4 で止める。検査そのものが失敗したときも、on なら止める（検査していないものを
#   コミットしない）。shadow は、WARNING を出すだけで、止めない
SCAN_REPORT=""
phase_secret_scan() {
    [[ "$SCAN_MODE" == "off" ]] && return $RET_OK
    SCAN_REPORT="$WORK_DIR/scan.report.tsv"
    local allow="./sf-tools/config/metasync-secret-allow.txt" args out rc
    args=(scan --plan "$PLAN_FILE" --repo . --fetched "$WORK_DIR" --out-report "$SCAN_REPORT")
    [[ -f "$allow" ]] && args+=(--allow "$allow")
    # run 不使用: 戻り値（0 / 10 / 1）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" "${args[@]}" 2>&1)
    rc=$?
    _log_node_lines "$out"
    if [[ $rc -eq 0 ]]; then
        return $RET_OK
    fi
    if [[ $rc -ne 10 ]]; then
        if [[ "$SCAN_MODE" == "on" ]]; then
            # 検査していない内容はコミットしない。疑いで止めたときと同じく、Slack に通知して、終了コード 4 で止める
            #   （許可の一覧の書式の誤りなどで、以後の同期が、通知なしで止まり続けないように）
            log "ERROR" "秘密情報の検査に失敗しました（終了コード ${rc}）。検査していない内容はコミットしないため、何もコミット・push せずに止めます。"
            [[ "$DRY_RUN" -eq 1 ]] || notify_slack ":rotating_light: [metasync] 秘密情報の検査に失敗したため、同期を止めました: ${REPO_FULL:-不明}" \
                "理由: 検査そのものが失敗しました（許可の一覧 sf-tools/config/metasync-secret-allow.txt の書式の誤りなど）。コミット・push は行っていません。" \
                "確認: 実行のログを見て、原因を直してください。"
            exit $EXIT_SECRET
        fi
        log "WARNING" "秘密情報の検査に失敗しました（終了コード ${rc}）。shadow のため、止めません。"
        return $RET_OK
    fi
    if [[ "$SCAN_MODE" == "shadow" ]]; then
        log "WARNING" "秘密の疑いがあります（shadow のため、止めません）。誤検知なら ${allow} に「規則 パス [キー]」を足し（パスに空白があるときは * で書く）、本物なら組織側で取り除いてください（規則が scan-error のものは、検査できなかったファイル。上の行の案内を参照）。"
        return $RET_OK
    fi
    log "ERROR" "秘密の疑いがあるため、何もコミット・push せずに止めます。本物なら組織側で取り除き、誤検知なら ${allow} に「規則 パス [キー]」を足し（パスに空白があるときは * で書く）てください（値は表示しません。規則が scan-error のものは、検査できなかったファイル。上の行の案内を参照）。"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local lines=() r f c k
        while IFS=$'\t' read -r r f c k; do
            # 4 列目 = キー（項目名・ラベル名など。scan-error では、検査できなかった規則名）
            [[ -n "$r" ]] && lines+=("・${r}  ${f}${k:+（${k}）}")
            [[ ${#lines[@]} -ge 10 ]] && break
        done < "$SCAN_REPORT"
        notify_slack ":rotating_light: [metasync] 秘密の疑いのため、同期を止めました: ${REPO_FULL:-不明}" \
            "理由: 組織から取得した内容に、秘密情報の疑いがあります（コミット・push は行っていません）。" "${lines[@]}" \
            "確認: 本物なら組織側で取り除く。誤検知なら sf-tools/config/metasync-secret-allow.txt に「規則 パス [キー]」を足す（パスの空白は * で書く）。規則が scan-error のものは、検査できなかった規則（キー）があるファイルで、中身を確かめ、問題なければ「scan-error パス キー」を足す。"
    fi
    exit $EXIT_SECRET
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
    # 指紋の状態を書く（指紋が、変更あり・不明のとき。取得と反映が成功したあとにだけ書く。変更なしのときは、書かない）
    if [[ "$FP_MODE" != "off" && ( "$FP_RC" -eq 10 || "$FP_RC" -eq 11 ) && -f "$FP_STATE_NEW" ]]; then
        FP_WRITTEN=1   # 途中で失敗しても、終了時に戻せるように、先に立てる
        run mkdir -p "${FP_STATE_FILE%/*}" || return $RET_NG
        run cp "$FP_STATE_NEW" "$FP_STATE_FILE" || return $RET_NG
        log "INFO" "指紋の状態を更新しました: ${FP_STATE_FILE}"
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
    [[ "$FP_WRITTEN" -eq 1 ]] && add_paths+=("$FP_STATE_FILE")
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

    # コミットの本文に、計画の件数を書く（確認は、手順 9 で済んでいる）。検知・指紋の状態を更新したときは、その旨も書く
    local body="$PLAN_COUNTS"
    if [[ "$STATE_WRITTEN" -eq 1 || "$FP_WRITTEN" -eq 1 ]]; then
        local _label="検知の状態"   # 検知だけのときは、従来の文言のまま。指紋の状態が加わるときだけ変える
        if [[ "$FP_WRITTEN" -eq 1 ]]; then _label=$([[ "$STATE_WRITTEN" -eq 1 ]] && echo "検知・指紋の状態" || echo "指紋の状態"); fi  # VAR=$(cmd) のため run 不使用
        if [[ "$PLAN_CHANGES" -eq 0 ]]; then body="${body}（${_label}の更新のみ）"; else body="${body}（${_label}も更新）"; fi
    fi
    run git commit -m "$COMMIT_MSG" -m "$body" || return $RET_NG
    COMMITTED=1
    # --no-verify: このコマンドは、main への同期の専用（管理者が、確認して実行する。GitHub Actions では、フックがない）。
    #   pre-push フック（開発者の main への直接 push を止める）を、ここでだけ通さない。サーバー側の保護（Ruleset）は、そのまま効く
    run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
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

# 公開リポジトリでは実行しない（取得の前。切り替えなし）
phase_check_visibility

phase_switch_to_main    || die "main ブランチへの切替に失敗しました。"
log "SUCCESS" "main ブランチへの切替完了"

phase_git_update        || die "Git 更新に失敗しました。"
log "SUCCESS" "Git 更新完了"

phase_prepare_work      || die "取得先の一時プロジェクトの準備に失敗しました。"
log "SUCCESS" "一時プロジェクトの準備完了（パッケージのフォルダ: ${PKG_PATH}）"

# 変更の検知と一覧の指紋（手順 5）。取得を省くのは、on の仕組み（検知・指紋）が 1 つ以上あり、on の仕組みが「すべて」変更なし（0）のときだけ
#   （どちらかが on で、変更あり・不明・行わなかったなら、全件取得する。shadow の仕組みは、記録だけで、判定に使わない）。
#   --full・--dry-run のとき、および未プッシュのコミットがあるとき（前回の push の失敗。phase_git_sync が push だけ行う）は、省かない
phase_detect_changes
phase_fingerprint
SKIP_OK=0      # 1 = on の仕組みが、すべて「変更なし」
SKIP_BY=""     # 省く根拠の表示（検知 ／ 一覧の指紋 ／ 検知と一覧の指紋）
if [[ "$DETECT_MODE" == "on" || "$FP_MODE" == "on" ]]; then
    SKIP_OK=1
    [[ "$DETECT_MODE" == "on" && "$DETECT_RC" -ne 0 ]] && SKIP_OK=0
    [[ "$FP_MODE" == "on" && "$FP_RC" -ne 0 ]] && SKIP_OK=0
    if [[ "$DETECT_MODE" == "on" && "$FP_MODE" == "on" ]]; then SKIP_BY="検知と一覧の指紋"
    elif [[ "$DETECT_MODE" == "on" ]]; then SKIP_BY="検知"
    else SKIP_BY="一覧の指紋"
    fi
    # 片方が on で「変更なし」、もう片方が on で「変更あり」・不明: 全件取得する（どちらかの見逃しを、取得で補う）
    if [[ "$SKIP_OK" -eq 0 && "$DETECT_MODE" == "on" && "$FP_MODE" == "on" && ( "$DETECT_RC" -eq 0 || "$FP_RC" -eq 0 ) ]]; then
        log "INFO" "検知と一覧の指紋の結果が分かれたため（検知: ${DETECT_RC} ／ 指紋: ${FP_RC}。0 = 変更なし）、全件取得します。"
    fi
fi
if [[ "$SKIP_OK" -eq 1 ]]; then
    UNPUSHED=$(git rev-list --count "origin/${BRANCH_NAME}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    if [[ "$FULL" -eq 1 ]]; then
        log "INFO" "--full が指定されているため、${SKIP_BY}の結果にかかわらず、全件取得します。"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        log "INFO" "--dry-run のため、${SKIP_BY}の結果にかかわらず、全件取得して計画を作ります（本番の実行では、取得を省きます）。"
    elif [[ "$UNPUSHED" =~ ^[0-9]+$ && "$UNPUSHED" -gt 0 ]]; then
        log "INFO" "未プッシュのコミットがあるため、${SKIP_BY}の結果にかかわらず、全件取得します。"
    else
        # shadow の仕組みが「変更あり」なのに、on の仕組みが「変更なし」: 食い違い。on の仕組みの見逃しの可能性があるため、記録に残す
        #   （取得は省く。shadow の仕組みの状態は書かない。毎日の --full で反映される）
        if [[ "$FP_MODE" == "shadow" && "$FP_RC" -eq 10 ]]; then
            log "WARNING" "指紋は『変更あり』ですが、検知は『変更なし』でした。検知の見逃しの可能性があります（今回は取得を省きます。毎日の --full で反映されます）。"
        fi
        if [[ "$DETECT_MODE" == "shadow" && "$DETECT_RC" -eq 10 ]]; then
            log "WARNING" "検知は『変更あり』ですが、指紋は『変更なし』でした。指紋の見逃しの可能性があります（今回は取得を省きます。毎日の --full で反映されます）。"
        fi
        log "SUCCESS" "完了: ${SKIP_BY}の結果、Salesforce 組織側に変更はありませんでした（全件取得を省きました）。"
        exit $RET_OK
    fi
fi

phase_retrieve_metadata || die "メタデータの取得に失敗しました。"
log "SUCCESS" "メタデータ取得完了"

phase_retrieve_extra    # 失敗しても止めない（plan が、その種類の削除を保留する）

phase_recent_files
phase_plan              || die "計画の作成に失敗しました。"
log "SUCCESS" "計画の作成完了（${PLAN_COUNTS}）"

phase_secret_scan       # on で疑いがあれば、ここで止まる（終了コード 4）

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "SUCCESS" "完了: --dry-run のため、計画の表示までで終了します（作業ツリー・コミット・push は行いません）。"
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
    # main の変更を、staging・develop のブランチへは流さない（一方通行の原則。doc/one-way-promotion-design.md 3.7）。
    #   main の最新は、開発者の PC で sf-push.sh が取り込み、開発のブランチ経由で上がる
    log "INFO" "main の変更は、staging・develop のブランチへは伝播しません（開発のブランチが、sf-push.sh で main を取り込みます）。"
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
