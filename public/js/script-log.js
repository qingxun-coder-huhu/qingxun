// 脚本日志的公共渲染/刷新模块（任务详情页与报告页共用）。
//
// 语义对齐本地客户端 views/task_detail.erb、views/task_report.erb 里的内联日志逻辑：
//   - 日志是纯文本，换行要自己转成 <br>（日志区用 white-space: normal）；同时做 HTML 转义，
//     否则设备回显里的 < > 会被当成标签吃掉；
//   - 脚本运行中时，日志区每 2 秒自动刷新，跑完即停。
//
// 用法：
//   QingxunScriptLog.renderLog(log)            -> 可直接交给 v-html 的字符串
//   QingxunScriptLog.createLogRefresher({...}) -> { start(), stop() }
(function () {
  function escapeLogHtml(text) {
    return String(text === null || text === undefined ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;')
      .replace(/\r\n/g, '<br>')
      .replace(/\n/g, '<br>');
  }

  // 日志文本 -> 可安全放进 v-html 的 HTML（空日志给占位文案）
  function renderLog(log) {
    if (log === null || log === undefined || String(log).trim() === '') {
      return '暂无日志';
    }
    return escapeLogHtml(log);
  }

  // 运行中脚本的日志自动刷新；getter/isRunning 由调用方提供（不同页面数据源不同）
  function createLogRefresher(options) {
    const opts = options || {};
    const intervalMs = opts.intervalMs || 2000;
    let timer = null;

    async function tick() {
      try {
        const log = await opts.getter();
        if (typeof opts.onUpdate === 'function') { opts.onUpdate(log); }
      } catch (e) {
        // 网络抖动忽略，下一轮继续
      }
      if (typeof opts.isRunning === 'function' && opts.isRunning()) {
        timer = setTimeout(tick, intervalMs);
      } else {
        stop();
      }
    }

    function start() {
      stop();
      timer = setTimeout(tick, intervalMs);
    }

    function stop() {
      if (timer) { clearTimeout(timer); timer = null; }
    }

    return { start: start, stop: stop };
  }

  window.QingxunScriptLog = {
    escapeLogHtml: escapeLogHtml,
    renderLog: renderLog,
    createLogRefresher: createLogRefresher
  };
})();
