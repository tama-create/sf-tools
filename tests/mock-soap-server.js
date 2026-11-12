'use strict';
// ==============================================================================
// mock-soap-server.js - テスト用の Metadata API（SOAP の listMetadata）のモックサーバー（lib/metasync.js fingerprint のテストで使う）
// ==============================================================================
// 使い方: node tests/mock-soap-server.js <データの JSON> <ポート番号を書くファイル> <リクエストの記録ファイル>
//   listen したあと（ランダムなポート。127.0.0.1 だけ）、ポート番号を 2 番目のファイルに書く。テストは、サーバーを止めずに、
//   データの JSON を書き換えて、挙動を変えられる（リクエストのたびに読み直す）。
// データの形（JSON）:
//   { "validToken": "TOKEN",                         // 省略可。指定すると、このトークン以外のリクエストは INVALID_SESSION_ID の Fault（セッション切れの再現）
//     "nonSoap": true,                               // 省略可。HTTP 200 で、SOAP ではない本文（HTML）を返す（メンテナンス画面・プロキシの再現）
//     "redirect": "http://127.0.0.1:1/x",            // 省略可。307 で、別の場所へ転送させる（トークンが転送先へ漏れないことの確認用）
//     "delay": 3000,                                 // 省略可。すべての応答を、この ms だけ遅らせる（時間切れの再現）
//     "lists": { "<種類>": [ { "fullName": "...", "lastModifiedDate": "...", "manageableState": "unmanaged" } ],
//                "<種類>|<フォルダ>": [ ... ],      // フォルダ指定の一覧
//                "<種類>": { "fault": "INVALID_TYPE: ..." },   // 一覧の代わりに Fault を返す（500）
//                "<種類>": { "http": 503 },        // HTTP のエラーだけ返す
//                "<種類>": { "delay": 3000 } } }   // その種類だけ、空の一覧を ms 遅れて返す
//   ない種類は、空の一覧。1 回の呼び出しに問い合わせ（queries）が複数あるときは、結果をまとめて返す（Fault が 1 つでもあれば、Fault）。
// 記録: 問い合わせ 1 つにつき 1 行「種類|フォルダ|トークン|API バージョン」を、3 番目のファイルに追記する。
//   呼び出し（HTTP リクエスト）1 回につき 1 行「問い合わせの数」を、<3 番目のファイル>.calls に追記する（まとめて問い合わせた回数の確認用）。
// ==============================================================================
const http = require('http');
const fs = require('fs');

const [dataFile, portFile, logFile] = process.argv.slice(2);
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const tag = (b, n) => { const m = new RegExp('<' + n + '>([^<]*)</' + n + '>').exec(b); return m ? m[1] : ''; };

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', d => { body += d; });
  req.on('end', () => {
    const token = tag(body, 'met:sessionId'), api = tag(body, 'met:asOfVersion');
    const queries = (body.match(/<met:queries>[\s\S]*?<\/met:queries>/g) || []).map(q => ({ type: tag(q, 'met:type'), folder: tag(q, 'met:folder') }));
    for (const q of queries) fs.appendFileSync(logFile, `${q.type}|${q.folder}|${token}|${api}\n`);
    fs.appendFileSync(logFile + '.calls', `${queries.length}\n`);
    let data = {};
    try { data = JSON.parse(fs.readFileSync(dataFile, 'utf8')); } catch (e) { /* 空のデータ */ }
    const reply = () => {
      const fault = (msg) => {
        res.writeHead(500, { 'Content-Type': 'text/xml; charset=utf-8' });
        res.end(`<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><soapenv:Fault><faultcode>sf:ERR</faultcode><faultstring>${esc(msg)}</faultstring></soapenv:Fault></soapenv:Body></soapenv:Envelope>`);
      };
      if (data.redirect) { res.writeHead(307, { Location: data.redirect }); return res.end(); }
      if (data.nonSoap) { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end('<html><body>Service is under maintenance</body></html>'); }
      if (data.validToken && token !== data.validToken) return fault('INVALID_SESSION_ID: Invalid Session ID found in SessionHeader: Illegal Session');
      let items = '';
      for (const q of queries) {
        const v = (data.lists || {})[q.folder ? q.type + '|' + q.folder : q.type];
        if (v && !Array.isArray(v)) {
          if (v.fault) return fault(v.fault);
          if (v.http) { res.writeHead(v.http); return res.end('error'); }
          if (v.delay) continue;   // 種類ごとの遅延は、返す前に待つ（下）。中身は空の一覧
        }
        items += (Array.isArray(v) ? v : []).map(e => `<result><createdDate>${esc(e.lastModifiedDate || '')}</createdDate><fullName>${esc(e.fullName)}</fullName><lastModifiedDate>${esc(e.lastModifiedDate || '')}</lastModifiedDate><manageableState>${esc(e.manageableState || 'unmanaged')}</manageableState><type>${esc(q.type)}</type></result>`).join('');
      }
      res.writeHead(200, { 'Content-Type': 'text/xml; charset=utf-8' });
      // 0 件のときは、実機と同じ形（既定の名前空間は Envelope に付き、本体は自己終了タグ <listMetadataResponse/>）で返す
      const resp = items ? `<listMetadataResponse>${items}</listMetadataResponse>` : '<listMetadataResponse/>';
      res.end(`<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns="http://soap.sforce.com/2006/04/metadata"><soapenv:Body>${resp}</soapenv:Body></soapenv:Envelope>`);
    };
    // 全体の遅延（data.delay）と、問い合わせに含まれる種類ごとの遅延（lists[...].delay）の、長いほうだけ待ってから返す
    const perType = Math.max(0, ...queries.map(q => { const v = (data.lists || {})[q.folder ? q.type + '|' + q.folder : q.type]; return v && !Array.isArray(v) && v.delay ? Number(v.delay) : 0; }));
    const wait = Math.max(Number(data.delay) || 0, perType);
    if (wait) setTimeout(reply, wait); else reply();
  });
});
server.listen(0, '127.0.0.1', () => { fs.writeFileSync(portFile, String(server.address().port)); });
