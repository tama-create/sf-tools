'use strict';
// ==============================================================================
// mock-org-lock.js - 偽の組織（org.json）の読み書きのロック
// ==============================================================================
// tests/mock-sf-log.js（偽の sf）と、tests/test_sf-log.sh の _org_set が使う。
// ロックがないと、偽の sf が起動時に読んだ古い状態を、終わるときに書き戻し、そのあいだにテストが足したログを消すことがあった
// （2026-11-24。テストを並べて走らせて重いときに、取得役のテストが 1 回落ちた。取得役のコードの不具合ではない）。
//   lock(file)            : file + '.lock' のフォルダを作れるまで待つ（最大 約 30 秒）。プロセスの終了時に消す。
//                           強制終了で残ったロック（10 秒より古い）は、消してから取り直す（中の処理は数ミリ秒で終わる）
//   writeAtomic(file, s)  : 一時ファイルに書いてから置き換える（ロックを持たずに読む _org が、書きかけを読まないため）
// ==============================================================================
const fs = require('fs');

const sleepMs = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const STALE_MS = 10000;

function lock(file) {
    const d = file + '.lock';
    let got = false;
    for (let i = 0; i < 1500 && !got; i++) {
        try {
            fs.mkdirSync(d);
            got = true;
        } catch (e) {
            if (e.code !== 'EEXIST') throw e;
            try {
                if (Date.now() - fs.statSync(d).mtimeMs > STALE_MS) { fs.rmdirSync(d); continue; }
            } catch (_) { /* ほかのプロセスが、ちょうど消した */ }
            sleepMs(20);
        }
    }
    if (!got) throw new Error('org.json のロックが取れません: ' + d);
    let released = false;
    const release = () => {
        if (released) return;
        released = true;
        try { fs.rmdirSync(d); } catch (_) { /* すでにない */ }
    };
    process.on('exit', release);
    for (const s of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(s, () => { release(); process.exit(1); });
    return release;
}

function writeAtomic(file, text) {
    const t = `${file}.tmp.${process.pid}`;
    fs.writeFileSync(t, text);
    // Windows では、ほかのプロセスが読んでいる瞬間に置き換えが EPERM・EBUSY になることがあるため、少し待って繰り返す
    for (let i = 0; ; i++) {
        try { fs.renameSync(t, file); return; } catch (e) {
            if (!['EPERM', 'EBUSY', 'EACCES'].includes(e.code) || i >= 50) throw e;
            sleepMs(20);
        }
    }
}

module.exports = { lock, writeAtomic };
