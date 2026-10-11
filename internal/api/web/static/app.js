// notes 管理界面前端逻辑：调用 /api/search 全文检索并渲染结果。
// 页面本身为公开资源（浏览器导航无法携带 Authorization 头），故访问令牌从
// localStorage 读取后附在 fetch 请求头上（见下方 token()）。
(function () {
  "use strict";

  // TOKEN_KEY 是 localStorage 中访问令牌的键名。
  var TOKEN_KEY = "notes.token";

  var form = document.getElementById("search-form");
  var input = document.getElementById("q");
  var status = document.getElementById("status");
  var list = document.getElementById("results");

  function token() {
    try {
      return localStorage.getItem(TOKEN_KEY) || "";
    } catch (err) {
      return "";
    }
  }

  function setStatus(text) {
    status.textContent = text || "";
  }

  function clearResults() {
    while (list.firstChild) {
      list.removeChild(list.firstChild);
    }
  }

  function render(paths) {
    clearResults();
    if (!paths || paths.length === 0) {
      setStatus("没有匹配的笔记");
      return;
    }
    setStatus("命中 " + paths.length + " 条");

    paths.forEach(function (path) {
      var li = document.createElement("li");
      var button = document.createElement("button");
      button.type = "button";
      button.className = "result-path";
      button.textContent = path;
      button.addEventListener("click", function () {
        setStatus("文件路径：" + path);
      });
      li.appendChild(button);
      list.appendChild(li);
    });
  }

  function search(query) {
    setStatus("搜索中…");
    fetch("/api/search?q=" + encodeURIComponent(query), {
      headers: { Authorization: "Bearer " + token() },
    })
      .then(function (res) {
        if (!res.ok) {
          return res
            .json()
            .catch(function () {
              return {};
            })
            .then(function (body) {
              var msg =
                body && body.error && body.error.message
                  ? body.error.message
                  : "HTTP " + res.status;
              throw new Error("搜索失败：" + msg);
            });
        }
        return res.json();
      })
      .then(function (data) {
        render(data && data.results);
      })
      .catch(function (err) {
        clearResults();
        setStatus(err.message);
      });
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var query = input.value.trim();
    if (query === "") {
      setStatus("请输入搜索关键词");
      return;
    }
    search(query);
  });
})();
