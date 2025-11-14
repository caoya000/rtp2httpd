local dispatcher = require "luci.dispatcher"
local i18n = require "luci.i18n"

-- 获取后端的日志API URL
local log_url = dispatcher.build_url("admin", "services", "rtp2httpd", "realtime_log")

local s_refresh = i18n.translate("Refresh")
local s_loading_msg = i18n.translate("Loading...")
local s_load_failed_msg = i18n.translate("Failed to load log data. Please check if the service is running.")
local s_no_entries_msg = i18n.translate("No rtp2httpd log entries found.")

-- 创建一个映射，它会自动应用主题样式
m = Map("rtp2httpd", i18n.translate("Log Viewer"))
m.description = i18n.translate("This page displays the real-time log for rtp2httpd.")

-- 创建一个简单的区域来放置我们的日志查看器
s = m:section(SimpleSection)
s.anonymous = true

-- 使用DummyValue来嵌入自定义的HTML和JavaScript
o = s:option(DummyValue, "_logviewer")
o.rawhtml = true
o.value = string.format([[
    <textarea id="rtp2httpd-log-view" class="cbi-input-textarea" style="width: 100%%; min-height: 500px; font-family: monospace; resize: vertical;" readonly="readonly"></textarea>
    
    <div style="text-align: center; padding-top: 10px;">
        <input type="button" class="cbi-button cbi-button-action" value="%s" onclick="loadLogData()" />
    </div>

    <script type="text/javascript">
        // 在CBI环境中，XHR对象是默认可用的
        var logView = document.getElementById('rtp2httpd-log-view');

        function loadLogData() {
            logView.value = '%s';
            XHR.get('%s', null, function(x, data) {
                if (!x || !data) {
                    logView.value = '%s';
                    return;
                }
                logView.value = data.log || '%s';
                logView.scrollTop = logView.scrollHeight;
            });
        }
        
        // 页面加载时自动获取日志
        loadLogData();
    </script>
]], s_refresh, s_loading_msg, log_url, s_load_failed_msg, s_no_entries_msg)

return m