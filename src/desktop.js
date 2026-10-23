(() => {
  'use strict';

  const frame = document.getElementById('desktop-frame');
  const status = document.getElementById('connection-status');
  const toast = document.getElementById('toast');
  const reconnectButton = document.getElementById('reconnect');
  const logoutButton = document.getElementById('logout');
  let expiryTimer = 0;
  let toastTimer = 0;
  let csrfToken = '';
  let sessionPromise = null;

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 3200);
  }

  function vncUrl() {
    const url = new URL('/vnc.html', location.origin);
    url.searchParams.set('autoconnect', '1');
    url.searchParams.set('resize', 'scale');
    url.searchParams.set('reconnect', '1');
    url.searchParams.set('reconnect_delay', '1000');
    url.searchParams.set('show_dot', '1');
    url.searchParams.set('t', String(Date.now()));
    return url.toString();
  }

  function reconnect(message) {
    status.textContent = message || '正在重新连接';
    frame.src = vncUrl();
  }

  async function loadSession() {
    let response;
    try {
      response = await fetch('/session', { cache: 'no-store', credentials: 'same-origin' });
    } catch (_error) {
      status.textContent = '无法检查登录状态';
      return false;
    }
    if (!response.ok) {
      location.replace('/login');
      return false;
    }
    let data;
    try {
      data = await response.json();
    } catch (_error) {
      location.replace('/login');
      return false;
    }
    const remaining = Number(data.expires_at) * 1000 - Date.now();
    if (!Number.isFinite(remaining) || remaining <= 0) {
      location.replace('/login');
      return false;
    }
    csrfToken = typeof data.csrf === 'string' ? data.csrf : '';
    if (!csrfToken) {
      status.textContent = '登录校验信息缺失，请刷新页面';
      return false;
    }
    clearTimeout(expiryTimer);
    expiryTimer = setTimeout(() => location.replace('/login'), Math.min(remaining, 2147483647));
    return true;
  }

  function ensureSession() {
    if (csrfToken) return Promise.resolve(true);
    if (!sessionPromise) {
      sessionPromise = loadSession().finally(() => { sessionPromise = null; });
    }
    return sessionPromise;
  }

  async function sendAction(action) {
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await fetch('/desktop/action', {
          method: 'POST',
          cache: 'no-store',
          credentials: 'same-origin',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-CSRF-Token': csrfToken
          },
          body: JSON.stringify({ action })
        });
        let data = {};
        try {
          data = await response.json();
        } catch (_error) {
          data = {};
        }
        return { response, data };
      } catch (error) {
        lastError = error;
        if (attempt === 0) {
          await new Promise((resolve) => setTimeout(resolve, 400));
        }
      }
    }
    throw lastError || new Error('Network request failed');
  }

  async function runAction(action, button) {
    if (button.disabled) return;
    button.disabled = true;
    try {
      if (!(await ensureSession())) {
        showToast('登录状态已失效，请重新登录');
        return;
      }
      let result = await sendAction(action);
      if (result.response.status === 403) {
        csrfToken = '';
        if (!(await ensureSession())) {
          showToast('登录状态已失效，请重新登录');
          return;
        }
        result = await sendAction(action);
      }
      const { response, data } = result;
      if (response.status === 401 || (response.redirected && response.url.endsWith('/login'))) {
        location.replace('/login');
        return;
      }
      if (!response.ok || !data.ok) {
        const detail = typeof data.detail === 'string' ? data.detail.trim() : '';
        if (detail) {
          showToast(detail.slice(0, 120));
        } else if (response.status === 403) {
          showToast('请求被拒绝，请刷新页面后重试');
        } else {
          showToast('桌面操作失败，请稍后重试');
        }
        return;
      }
      if (action === 'terminal') showToast('已切换到终端');
      else if (action === 'browser') showToast('正在打开浏览器');
      else showToast('已切换窗口');
    } catch (_error) {
      showToast('网络连接失败，请检查连接后重试');
    } finally {
      button.disabled = false;
    }
  }

  function updateStatus() {
    try {
      const doc = frame.contentWindow && frame.contentWindow.document;
      const element = doc && doc.getElementById('noVNC_status');
      if (element && element.textContent.trim()) {
        status.textContent = element.textContent.trim();
      }
    } catch (_error) {
      // The iframe can be between documents while reconnecting.
    }
  }

  frame.addEventListener('load', () => {
    status.textContent = '远程桌面已载入';
    updateStatus();
  });

  reconnectButton.addEventListener('click', () => reconnect('正在重新连接'));
  logoutButton.addEventListener('click', async () => {
    try {
      if (await ensureSession()) {
        await fetch('/logout', {
          method: 'POST',
          credentials: 'same-origin',
          headers: { 'X-CSRF-Token': csrfToken }
        });
      }
    } finally {
      location.replace('/login');
    }
  });

  document.querySelectorAll('[data-action]').forEach((button) => {
    button.addEventListener('click', () => runAction(button.dataset.action, button));
  });

  window.addEventListener('online', () => reconnect('网络已恢复，正在重连'));
  setInterval(updateStatus, 2000);
  loadSession();
})();
