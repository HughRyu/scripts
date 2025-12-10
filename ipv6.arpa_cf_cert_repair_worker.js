export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // -----------------------
    // 1️⃣ API 请求处理 (后端逻辑)
    // -----------------------
    if (url.pathname === '/ssl' && request.method === 'POST') {
      return handleSSLApi(request);
    }

    // -----------------------
    // 2️⃣ 返回 HTML 页面 (前端界面)
    // -----------------------
    return new Response(renderPage(), {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  },
};

/**
 * 处理前端发来的 API 请求，调用 Cloudflare 修改 SSL 设置
 */
async function handleSSLApi(request) {
  const jsonHeaders = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  try {
    const body = await request.json();
    // 获取前端传来的参数：邮箱、ZoneID、API Key、是否启用、CA机构
    const { email, zoneId: zone_id, apikey: api_key, enabled, ca: certificate_authority } = body;

    // 简单验证
    if (!email || !zone_id || !api_key) {
      return createJSONResponse({ success: false, errors: ['❌ 错误：邮箱、Zone ID、API Key 不能为空'] }, 400);
    }
    if (!validateEmail(email)) {
      return createJSONResponse({ success: false, errors: ['❌ 错误：邮箱格式不正确'] }, 400);
    }

    // 构造发送给 Cloudflare 的数据
    // 注意：如果是禁用(enabled=false)，CF API 其实不需要 certificate_authority，但带上也不影响
    const payload = { 
        enabled: enabled, 
        certificate_authority: certificate_authority 
    };

    // 调用 Cloudflare 官方 API
    const cfRes = await fetch(`https://api.cloudflare.com/client/v4/zones/${zone_id}/ssl/universal/settings`, {
      method: 'PATCH',
      headers: {
        'X-Auth-Email': email,
        'X-Auth-Key': api_key,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    const result = await cfRes.json();

    if (!cfRes.ok || !result.success) {
      // 提取 Cloudflare 返回的具体错误信息
      const errorMsg = result.errors ? result.errors.map(e => e.message).join(', ') : 'Cloudflare API 未知错误';
      return createJSONResponse({ success: false, errors: [{ message: errorMsg }] }, cfRes.status);
    }

    return createJSONResponse(result);

  } catch (error) {
    return createJSONResponse({ success: false, errors: [{ message: `请求失败: ${error.message || '未知错误'}` }] }, 500);
  }

  function createJSONResponse(data, status = 200) {
    return new Response(JSON.stringify(data), { status, headers: jsonHeaders });
  }

  function validateEmail(email) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
  }
}

/**
 * 生成前端 HTML 页面
 */
function renderPage() {
  // 使用模板字符串返回完整的 HTML
  return `<!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cloudflare SSL 证书修复工具</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
      .container { max-width: 480px; margin: 40px auto; background: #fff; padding: 30px; border-radius: 16px; box-shadow: 0 10px 25px rgba(0,0,0,0.05); }
      h2 { text-align: center; margin-bottom: 25px; color: #1a202c; font-weight: 700; }
      label { display: block; margin-bottom: 8px; font-weight: 600; color: #4a5568; font-size: 14px; }
      input, select, button { width: 100%; padding: 12px; margin-bottom: 20px; border-radius: 8px; border: 1px solid #e2e8f0; font-size: 14px; box-sizing: border-box; transition: all 0.2s; }
      input:focus, select:focus { outline: none; border-color: #3182ce; box-shadow: 0 0 0 3px rgba(66,153,225,0.15); }
      button { background: #3182ce; color: #fff; border: none; cursor: pointer; font-weight: 600; margin-top: 10px; font-size: 16px; padding: 14px; }
      button:hover { background: #2b6cb0; transform: translateY(-1px); }
      button:disabled { background: #cbd5e0; cursor: not-allowed; transform: none; }
      .result { padding: 15px; border-radius: 8px; display: none; margin-top: 20px; font-size: 14px; line-height: 1.6; white-space: pre-wrap; }
      .success { background: #c6f6d5; color: #276749; border: 1px solid #9ae6b4; }
      .error { background: #fed7d7; color: #9b2c2c; border: 1px solid #feb2b2; }
      .tips { font-size: 13px; color: #2d3748; margin-bottom: 25px; background: #edf2f7; padding: 15px; border-radius: 8px; border-left: 4px solid #3182ce; }
    </style>
    </head>
    <body>
    <div class="container">
      <h2>🛠️ SSL 证书修复工具</h2>
      
      <div class="tips">
        <strong>💡 证书卡死/超时修复步骤：</strong><br>
        1. 尝试 <strong>更换 CA 机构</strong> (推荐 Google 或 Let's Encrypt)，直接提交。<br>
        2. 如果不行，先选择 <strong>🔴 禁用 Universal SSL</strong>，提交后等待 2 分钟。<br>
        3. 刷新 Cloudflare 后台确认关闭后，再回来选择 <strong>🟢 启用</strong> 并更换 CA。
      </div>

      <form id="sslform">
        <label>📧 Cloudflare 登录邮箱</label>
        <input type="email" id="email" placeholder="例如：user@example.com" required>
        
        <label>🌐 Zone ID (区域 ID)</label>
        <input type="text" id="zoneid" placeholder="在域名概述页右下角查找" required>
        
        <label>🔑 Global API Key</label>
        <input type="password" id="apikey" placeholder="我的个人资料 -> API 令牌 -> Global API Key" required>

        <label>⚙️ 操作类型</label>
        <select id="enabledState">
            <option value="true" selected>🟢 启用 Universal SSL (修复/开启)</option>
            <option value="false">🔴 禁用 Universal SSL (重置用)</option>
        </select>

        <label>🏢 证书颁发机构 (CA)</label>
        <select id="caSelect">
            <option value="google">Google Trust Services (推荐/速度快)</option>
            <option value="lets_encrypt">Let's Encrypt (兼容性好)</option>
            <option value="ssl_com">SSL.com (默认/容易卡)</option>
        </select>
        
        <button type="submit" id="submitBtn">🚀 执行操作</button>
      </form>
      <div class="result" id="resultMsg"></div>
    </div>
    
    <script>
    const sslform = document.getElementById('sslform');
    const resultMsg = document.getElementById('resultMsg');
    const submitBtn = document.getElementById('submitBtn');

    // 自动填充上次输入的值（如果浏览器支持）
    if(localStorage.getItem('cf_email')) document.getElementById('email').value = localStorage.getItem('cf_email');
    if(localStorage.getItem('cf_zoneid')) document.getElementById('zoneid').value = localStorage.getItem('cf_zoneid');
    if(localStorage.getItem('cf_apikey')) document.getElementById('apikey').value = localStorage.getItem('cf_apikey');
    
    sslform.addEventListener('submit', async e => {
      e.preventDefault();
      resultMsg.style.display='none';
      
      const email = document.getElementById('email').value.trim();
      const zoneId = document.getElementById('zoneid').value.trim();
      const apikey = document.getElementById('apikey').value.trim();
      // 获取用户选择的开启状态 (字符串转布尔值)
      const enabled = document.getElementById('enabledState').value === 'true';
      const ca = document.getElementById('caSelect').value;
    
      if(!email || !zoneId || !apikey){ 
        alert('请填写完整信息'); 
        return; 
      }

      // 保存到本地缓存方便下次使用
      localStorage.setItem('cf_email', email);
      localStorage.setItem('cf_zoneid', zoneId);
      localStorage.setItem('cf_apikey', apikey);
    
      submitBtn.disabled = true;
      submitBtn.textContent = '⏳ 正在请求 Cloudflare API...';
    
      try {
        const res = await fetch('/ssl',{
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body: JSON.stringify({email, zoneId, apikey, enabled, ca})
        });
        
        const data = await res.json();
        
        if(data.success){
          let actionText = enabled ? "启用" : "禁用";
          showResult('✅ 成功！Cloudflare 已接收指令。\\n\\n' + 
                     '操作：' + actionText + ' Universal SSL\\n' +
                     'CA 机构：' + ca + '\\n\\n' +
                     '请等待 2-5 分钟后在 Cloudflare 后台查看证书状态。\\n' +
                     '如果依然显示“验证中”或“超时”，请尝试先禁用，过几分钟再启用。', true);
        } else {
          // 格式化错误信息
          let errorStr = '❌ 失败：';
          if(Array.isArray(data.errors)) {
             errorStr += data.errors.map(e => e.message || JSON.stringify(e)).join(', ');
          } else {
             errorStr += JSON.stringify(data);
          }
          showResult(errorStr, false);
        }
      } catch(err){
        showResult('❌ 网络或脚本错误: ' + err, false);
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = '🚀 执行操作';
      }
    });
    
    function showResult(msg, success){
      resultMsg.innerText = msg; 
      resultMsg.className = 'result ' + (success ? 'success' : 'error');
      resultMsg.style.display = 'block';
      resultMsg.scrollIntoView({behavior:'smooth'});
    }
    </script>
    </body>
    </html>`;
}
