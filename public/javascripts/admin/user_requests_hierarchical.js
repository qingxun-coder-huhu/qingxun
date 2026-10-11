// 主控制器
console.log('UserRequestsHierarchical script loaded from public directory');
class UserRequestsHierarchical {
  constructor() {
    this.currentUserId = null;
    this.currentRequestId = null;
    this.currentInteractionId = null;
    this.users = [];
    this.filteredUsers = [];

    this.init();
  }

  init() {
    console.log('UserRequestsHierarchical init started');
    try {
      this.loadUserList();
      this.setupEventListeners();
      this.setupNavigation();
      console.log('UserRequestsHierarchical init completed');
    } catch (error) {
      console.error('UserRequestsHierarchical init error:', error);
    }
  }

  async loadUserList() {
    console.log('loadUserList called');
    this.showLoading('#user-list', true);

    try {
      console.log('Fetching user list from API...');
      const response = await fetch('/admin/user_requests/user_list');
      console.log('API response status:', response.status);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const data = await response.json();
      console.log('API data received, user count:', data.users.length);
      this.users = data.users;
      this.filteredUsers = [...this.users];
      this.renderUserList();
    } catch (error) {
      console.error('loadUserList error:', error);
      this.showError('加载用户列表失败: ' + error.message);
    } finally {
      this.showLoading('#user-list', false);
    }
  }

  renderUserList() {
    const container = document.getElementById('user-list');
    if (!container) return;

    if (this.filteredUsers.length === 0) {
      container.innerHTML = `
        <div class="text-center text-muted py-3">
          <i class="bi bi-search"></i>
          <p class="mb-0">没有匹配的用户</p>
        </div>
      `;
      return;
    }

    container.innerHTML = this.filteredUsers.map(user => `
      <a href="#" class="list-group-item list-group-item-action user-item ${this.currentUserId === user.id ? 'active' : ''}"
         data-user-id="${user.id}" data-user-email="${user.email}">
        <div class="d-flex w-100 justify-content-between">
          <h6 class="mb-1">${user.email}</h6>
          <small class="text-muted">ID: ${user.id}</small>
        </div>
        <small class="text-muted">注册时间: ${new Date(user.created_at).toLocaleDateString()}</small>
      </a>
    `).join('');

    // 重新绑定点击事件
    container.querySelectorAll('.user-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const userId = item.dataset.userId;
        const userEmail = item.dataset.userEmail;
        this.selectUser(userId, userEmail);
      });
    });
  }

  filterUserList(searchTerm) {
    if (!searchTerm) {
      this.filteredUsers = [...this.users];
    } else {
      const term = searchTerm.toLowerCase();
      this.filteredUsers = this.users.filter(user =>
        user.email.toLowerCase().includes(term) ||
        user.id.toString().includes(term)
      );
    }
    this.renderUserList();
  }

  async selectUser(userId, userEmail) {
    this.currentUserId = userId;
    this.currentRequestId = null;
    this.currentInteractionId = null;

    // 更新UI状态
    document.querySelectorAll('.user-item').forEach(item => {
      item.classList.toggle('active', item.dataset.userId === userId);
    });

    // 更新标题
    document.getElementById('content-title').textContent = `${userEmail} 的请求`;

    // 显示加载状态
    this.showContentLoading();

    try {
      const response = await fetch(`/admin/user_requests/user_requests?user_id=${userId}`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const data = await response.json();
      this.renderUserRequests(data.user, data.requests);
    } catch (error) {
      this.showError('加载用户请求失败: ' + error.message);
    }
  }

  renderUserRequests(user, requests) {
    const container = document.getElementById('content-area');
    if (!container) return;

    if (requests.length === 0) {
      container.innerHTML = `
        <div class="text-center text-muted py-5">
          <i class="bi bi-inbox fs-1 mb-3"></i>
          <p class="lead">该用户还没有请求记录</p>
        </div>
      `;
      return;
    }

    container.innerHTML = `
      <div class="table-responsive">
        <table class="table table-hover">
          <thead>
            <tr>
              <th>请求ID</th>
              <th>类型</th>
              <th>状态</th>
              <th>原始输入</th>
              <th>创建时间</th>
              <th>LLM交互</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            ${requests.map(request => `
              <tr>
                <td><code class="small">${request.request_id.substring(0, 8)}...</code></td>
                <td><span class="badge bg-secondary">${request.request_type}</span></td>
                <td>
                  <span class="badge bg-${this.getStatusBadgeClass(request.status)}">
                    ${request.status}
                  </span>
                </td>
                <td>${this.truncateText(request.original_input, 50)}</td>
                <td>${new Date(request.created_at).toLocaleString()}</td>
                <td>${request.llm_interactions_count} 次</td>
                <td>
                  <button class="btn btn-sm btn-outline-primary view-request"
                          data-request-id="${request.request_id}">
                    查看详情
                  </button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    `;

    // 绑定请求查看事件
    container.querySelectorAll('.view-request').forEach(button => {
      button.addEventListener('click', (e) => {
        e.preventDefault();
        const requestId = button.dataset.requestId;
        this.selectRequest(requestId);
      });
    });
  }

  async selectRequest(requestId) {
    this.currentRequestId = requestId;

    // 更新标题
    const title = document.getElementById('content-title');
    title.textContent = `请求详情: ${requestId.substring(0, 8)}...`;

    // 显示加载状态
    this.showContentLoading();

    // 显示返回按钮
    document.getElementById('content-actions').style.display = 'flex';
    document.getElementById('back-to-requests').style.display = 'inline-block';
    document.getElementById('back-to-interactions').style.display = 'none';

    try {
      const response = await fetch(`/admin/user_requests/request_with_interactions?request_id=${requestId}`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const data = await response.json();
      this.renderRequestDetails(data.request, data.interactions);
    } catch (error) {
      this.showError('加载请求详情失败: ' + error.message);
    }
  }

  renderRequestDetails(request, interactions) {
    const container = document.getElementById('content-area');
    if (!container) return;

    // 请求基本信息
    const basicInfo = `
      <div class="row mb-4">
        <div class="col-md-6">
          <div class="card">
            <div class="card-header">
              <h6 class="card-title mb-0">请求基本信息</h6>
            </div>
            <div class="card-body">
              <dl class="row mb-0">
                <dt class="col-sm-4">请求ID:</dt>
                <dd class="col-sm-8"><code>${request.request_id}</code></dd>

                <dt class="col-sm-4">用户:</dt>
                <dd class="col-sm-8">${request.user.email} (ID: ${request.user.id})</dd>

                <dt class="col-sm-4">类型:</dt>
                <dd class="col-sm-8"><span class="badge bg-secondary">${request.request_type}</span></dd>

                <dt class="col-sm-4">状态:</dt>
                <dd class="col-sm-8">
                  <span class="badge bg-${this.getStatusBadgeClass(request.status)}">
                    ${request.status}
                  </span>
                </dd>

                <dt class="col-sm-4">创建时间:</dt>
                <dd class="col-sm-8">${new Date(request.created_at).toLocaleString()}</dd>

                ${request.started_at ? `
                <dt class="col-sm-4">开始时间:</dt>
                <dd class="col-sm-8">${new Date(request.started_at).toLocaleString()}</dd>
                ` : ''}

                ${request.completed_at ? `
                <dt class="col-sm-4">完成时间:</dt>
                <dd class="col-sm-8">${new Date(request.completed_at).toLocaleString()}</dd>
                ` : ''}
              </dl>
            </div>
          </div>
        </div>

        <div class="col-md-6">
          <div class="card">
            <div class="card-header">
              <h6 class="card-title mb-0">原始输入</h6>
            </div>
            <div class="card-body">
              <div class="alert alert-light" style="white-space: pre-wrap; max-height: 200px; overflow-y: auto;">
                ${request.original_input}
              </div>
            </div>
          </div>
        </div>
      </div>
    `;

    // LLM交互列表
    let interactionsHtml = '';
    if (interactions.length > 0) {
      interactionsHtml = `
        <div class="card">
          <div class="card-header">
            <h6 class="card-title mb-0">LLM交互记录 (${interactions.length} 次)</h6>
          </div>
          <div class="card-body">
            <div class="accordion" id="llm-interactions-accordion">
              ${interactions.map((interaction, index) => `
                <div class="accordion-item">
                  <h2 class="accordion-header">
                    <button class="accordion-button ${index === 0 ? '' : 'collapsed'}"
                            type="button" data-bs-toggle="collapse"
                            data-bs-target="#interaction-${index}">
                      <div class="d-flex w-100 justify-content-between align-items-center">
                        <div>
                          <span class="badge bg-${interaction.success ? 'success' : 'danger'} me-2">
                            ${interaction.success ? '成功' : '失败'}
                          </span>
                          ${interaction.service_name}
                          ${interaction.step_name ? `- ${interaction.step_name}` : ''}
                        </div>
                        <div class="text-muted small">
                          ${new Date(interaction.created_at).toLocaleTimeString()}
                          ${interaction.response_time_ms ? `· ${interaction.response_time_ms.toFixed(0)}ms` : ''}
                        </div>
                      </div>
                    </button>
                  </h2>
                  <div id="interaction-${index}"
                       class="accordion-collapse collapse ${index === 0 ? 'show' : ''}"
                       data-bs-parent="#llm-interactions-accordion">
                    <div class="accordion-body">
                      <div class="row">
                        <div class="col-md-12 mb-4">
                          <h6>请求数据:</h6>
                          <pre class="bg-light p-3 rounded" style="max-height: 400px; overflow-y: auto;">${this.formatInteractionData(interaction.request_data)}</pre>
                        </div>
                        <div class="col-md-12">
                          <h6>响应数据:</h6>
                          <pre class="bg-light p-3 rounded" style="max-height: 400px; overflow-y: auto;">${this.formatInteractionData(interaction.response_data)}</pre>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              `).join('')}
            </div>
          </div>
        </div>
      `;
    } else {
      interactionsHtml = `
        <div class="alert alert-info">
          <i class="bi bi-info-circle"></i> 该请求没有LLM交互记录
        </div>
      `;
    }

    container.innerHTML = basicInfo + interactionsHtml;
  }

  // 工具方法
  showLoading(selector, show) {
    const loadingEl = document.getElementById('user-loading');
    if (loadingEl) loadingEl.style.display = show ? 'block' : 'none';
  }

  showContentLoading() {
    const container = document.getElementById('content-area');
    if (!container) return;

    container.innerHTML = `
      <div class="text-center py-5">
        <div class="spinner-border text-primary" role="status">
          <span class="visually-hidden">加载中...</span>
        </div>
        <p class="mt-3">加载中...</p>
      </div>
    `;
  }

  showError(message) {
    const container = document.getElementById('content-area');
    if (!container) return;

    container.innerHTML = `
      <div class="alert alert-danger">
        <i class="bi bi-exclamation-triangle"></i> ${message}
      </div>
    `;
  }

  getStatusBadgeClass(status) {
    const classes = {
      'pending': 'warning',
      'processing': 'info',
      'completed': 'success',
      'failed': 'danger'
    };
    return classes[status] || 'secondary';
  }

  truncateText(text, maxLength) {
    if (!text) return '';
    if (text.length <= maxLength) return text;
    return text.substring(0, maxLength) + '...';
  }

  formatInteractionData(data) {
    if (data === null || data === undefined) {
      return '无数据';
    }

    // 先转成JSON字符串
    let jsonString;
    if (typeof data === 'string') {
      jsonString = data;
    } else {
      jsonString = JSON.stringify(data, null, 2);
    }

    // 替换所有转义字符
    return jsonString
      .replace(/\\n/g, '\n')
      .replace(/\\"/g, '"')
      .replace(/\\r/g, '\r')
      .replace(/\\t/g, '\t')
      .replace(/\\\\/g, '\\');
  }

  setupEventListeners() {
    // 用户搜索框
    const searchInput = document.getElementById('user-search');
    if (searchInput) {
      searchInput.addEventListener('input', (e) => {
        this.filterUserList(e.target.value);
      });
    }
  }

  setupNavigation() {
    // 返回请求列表按钮
    const backToRequestsBtn = document.getElementById('back-to-requests');
    if (backToRequestsBtn) {
      backToRequestsBtn.addEventListener('click', () => {
        if (this.currentUserId) {
          this.selectUser(this.currentUserId, '');
        }
      });
    }
  }
}

// 页面加载完成后初始化
const initUserRequestsApp = () => {
  // 防止重复初始化
  if (window.userRequestsApp) {
    console.log('UserRequestsHierarchical already initialized, skipping');
    return;
  }
  console.log('Initializing UserRequestsHierarchical...');
  try {
    window.userRequestsApp = new UserRequestsHierarchical();
    console.log('UserRequestsHierarchical initialization successful');
  } catch (error) {
    console.error('Failed to initialize UserRequestsHierarchical:', error);
  }
};

// 支持标准页面加载和Turbo驱动页面
document.addEventListener('DOMContentLoaded', initUserRequestsApp);
document.addEventListener('turbo:load', initUserRequestsApp);
document.addEventListener('turbo:render', initUserRequestsApp);

// 如果页面已经加载，立即初始化
if (document.readyState === 'loading') {
  // 等待DOMContentLoaded
} else {
  // DOM已经就绪，立即初始化
  setTimeout(initUserRequestsApp, 0);
}