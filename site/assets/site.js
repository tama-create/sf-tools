/* sf-tools 文書サイトの共通部分。
 * 目次（NAV）は、ここ 1 か所だけで管理する。各ページは本文だけを書き、上のバー・左の目次・右の見出し・前後のリンクは、ここが作る。
 * 新しいページを足すときは、NAV に 1 行足す（href は、サイトの最上位からの相対パス）。 */
(function () {
  "use strict";

  var NAV = [
    { title: "はじめに", items: [
      { t: "ホーム", h: "index.html" }
    ]},
    { title: "使い方ガイド（開発者向け）", items: [
      { t: "前提条件とインストール", h: "guide/install.html" },
      { t: "基本の使い方", h: "guide/basics.html" },
      { t: "日々の開発の流れ", h: "guide/daily.html" }
    ]},
    { title: "管理者ガイド", items: [
      { t: "新規プロジェクトの作成（sf-init）" },
      { t: "秘密鍵・ワークフローの更新" },
      { t: "動作の確認（--verify）" }
    ]},
    { title: "リファレンス", items: [
      { t: "コマンド一覧" },
      { t: "ターゲットファイルの書き方" },
      { t: "ログとリポジトリ構成" }
    ]},
    { title: "設計と背景", items: [
      { t: "設計の考え方" },
      { t: "CI/CD の全体像" },
      { t: "JWT 認証" }
    ]}
  ];

  var body = document.body;
  var root = body.getAttribute("data-root") || "";
  var REPO = "https://github.com/tama-create/sf-tools";

  function el(tag, attrs, html) {
    var e = document.createElement(tag);
    if (attrs) { for (var k in attrs) { if (attrs.hasOwnProperty(k)) { e.setAttribute(k, attrs[k]); } } }
    if (html != null) { e.innerHTML = html; }
    return e;
  }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function samePage(href) {
    var u = new URL(root + href, location.href).pathname;
    var here = location.pathname;
    if (here.charAt(here.length - 1) === "/") { here += "index.html"; }
    return u === here;
  }

  /* ---- 上のバー ---- */
  var top = document.getElementById("top");
  if (top) {
    top.className = "top";
    top.innerHTML =
      '<button class="menu-btn" type="button" aria-label="メニュー">メニュー</button>' +
      '<a class="brand" href="' + root + 'index.html">sf-tools<small>ドキュメント</small></a>' +
      '<span class="spacer"></span>' +
      '<button class="theme" type="button" aria-label="表示の切り替え">表示切替</button>' +
      '<a class="link" href="' + REPO + '">GitHub</a>';
    top.querySelector(".menu-btn").addEventListener("click", function () { body.classList.toggle("menu-open"); });
    top.querySelector(".theme").addEventListener("click", function () {
      var cur = document.documentElement.getAttribute("data-theme");
      var dark = cur ? cur === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
      var next = dark ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", next);
      try { localStorage.setItem("sf-tools-theme", next); } catch (e) { /* 保存できなくても、表示は切り替わる */ }
    });
  }
  try {
    var saved = localStorage.getItem("sf-tools-theme");
    if (saved) { document.documentElement.setAttribute("data-theme", saved); }
  } catch (e) { /* 保存された設定がなくてもよい */ }

  /* ---- 左の目次 ---- */
  var pages = [];   /* リンクのあるページを順に集める（前へ・次へ用）*/
  var side = document.getElementById("side");
  if (side) {
    side.className = "side";
    var html = "";
    NAV.forEach(function (g) {
      html += "<h2>" + esc(g.title) + "</h2><ul>";
      g.items.forEach(function (it) {
        if (it.h) {
          pages.push(it);
          html += '<li><a href="' + root + it.h + '"' + (samePage(it.h) ? ' class="current" aria-current="page"' : "") + ">" + esc(it.t) + "</a></li>";
        } else {
          html += '<li><span class="soon">' + esc(it.t) + "</span></li>";
        }
      });
      html += "</ul>";
    });
    side.innerHTML = html;
    side.addEventListener("click", function (e) { if (e.target.tagName === "A") { body.classList.remove("menu-open"); } });
  }

  /* ---- 本文: コードのコピーボタン ---- */
  var doc = document.getElementById("doc");
  if (doc) {
    Array.prototype.forEach.call(doc.querySelectorAll("pre"), function (pre) {
      var b = el("button", { "class": "copy", type: "button" }, "コピー");
      b.addEventListener("click", function () {
        var text = pre.querySelector("code") ? pre.querySelector("code").innerText : pre.innerText;
        var done = function () { b.textContent = "コピーしました"; setTimeout(function () { b.textContent = "コピー"; }, 1500); };
        if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text).then(done); } else { done(); }
      });
      pre.appendChild(b);
    });

    /* ---- 右の見出し（このページの目次）---- */
    var toc = document.getElementById("toc");
    var heads = doc.querySelectorAll("h2, h3");
    if (toc && heads.length > 2) {
      toc.className = "toc";
      var t = "<h2>このページの内容</h2><ul>";
      Array.prototype.forEach.call(heads, function (h, i) {
        if (!h.id) { h.id = "s" + (i + 1); }
        t += '<li class="' + (h.tagName === "H3" ? "sub" : "") + '"><a href="#' + h.id + '">' + esc(h.textContent) + "</a></li>";
      });
      toc.innerHTML = t + "</ul>";
    }

    /* ---- 前へ・次へ ---- */
    var idx = -1;
    pages.forEach(function (p, i) { if (samePage(p.h)) { idx = i; } });
    if (idx >= 0) {
      var pager = el("div", { "class": "pager" });
      if (idx > 0) { pager.appendChild(el("a", { "class": "prev", href: root + pages[idx - 1].h }, "<small>前のページ</small>" + esc(pages[idx - 1].t))); }
      else { pager.appendChild(el("span")); }
      if (idx < pages.length - 1) { pager.appendChild(el("a", { "class": "next", href: root + pages[idx + 1].h }, "<small>次のページ</small>" + esc(pages[idx + 1].t))); }
      if (pager.children.length && (idx > 0 || idx < pages.length - 1)) { doc.appendChild(pager); }
    }
  }

  /* ---- 下の帯 ---- */
  var foot = document.getElementById("foot");
  if (foot) {
    foot.className = "site";
    foot.innerHTML = 'sf-tools — <a href="' + REPO + '">GitHub のリポジトリ</a>';
  }
})();
