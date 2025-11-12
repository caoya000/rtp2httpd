require ("nixio.fs")
require ("luci.sys")
require ("luci.http")
require ("luci.dispatcher")
require "luci.model.uci".cursor()

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local port = uci:get("rtp2httpd", "@rtp2httpd[0]", "port") or "5140"
local status_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "status_page_path") or "/status"
local player_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "player_page_path") or "/player"
local router_ip = http.getenv("SERVER_NAME")
local button_staus_url = string.format("http://%s:%s%s", router_ip, port, status_page_path)
local button_player_url = string.format("http://%s:%s%s", router_ip, port, player_page_path)
local button_staus_text = translate("Open Status Dashboard")
local button_player_text = translate("Open Player Page")
local s_log_title      = translate("Log")
local s_view_log       = translate("View Log")
local s_refresh        = translate("Refresh")
local s_close          = translate("Close")
local s_viewer_title   = translate("rtp2httpd Log Viewer")
local s_loading_msg    = translate("Loading...")
local s_load_failed_msg = translate("Failed to load log data. Please check if the service is running.")
local s_no_entries_msg = translate("No rtp2httpd log entries found.")

m = Map("rtp2httpd")
m.title = translate("Rtp2httpd")
m.description = translate("rtp2httpd converts RTP/UDP/RTSP media into http stream.")

m:section(SimpleSection).template  = "rtp2httpd/rtp2httpd_status"

s = m:section(TypedSection, "rtp2httpd")
s.addremove = true
s.anonymous = false
s.addbtntitle = translate("Add instance")

o = s:option(Flag, "disabled", translate("Enable"))
o.enabled = "0"
o.disabled = "1"
o.default = o.disabled
o.rmempty = false

o = s:option(Flag, "respawn", translate("Respawn"))
o.enabled = "1"
o.disabled = "0"
o.default = o.enabled
o.rmempty = false
o.description = translate("Auto restart after crash")

o = s:option(DummyValue, "status_page_dummy", translate("Status Dashboard"))
o.value = string.format(
    '<a href="%s" target="_blank" rel="noopener noreferrer" class="cbi-button cbi-button-action">%s</a>',
    button_staus_url,
    button_staus_text
)
o.rawhtml = true

o = s:option(DummyValue, "status_player_dummy", translate("Player Page"))
o.value = string.format(
    '<a href="%s" target="_blank" rel="noopener noreferrer" class="cbi-button cbi-button-action">%s</a>',
    button_player_url,
    button_player_text
)
o.rawhtml = true

o = s:option(DummyValue, "log_page_dummy", s_log_title)
local log_url = dispatcher.build_url("admin", "services", "rtp2httpd", "realtime_log")
o.rawhtml = true
o.value = string.format([[
    <!-- 1. 触发按钮 -->
    <input type="button" class="cbi-button cbi-button-action" value="%s" onclick="showRtpLogPopup('%s')" />

    <!-- 2. 悬浮窗的HTML结构 (默认隐藏) -->
    <div id="rtp2httpd-log-modal" class="rtp2httpd-modal-overlay">
        <div class="rtp2httpd-modal-content">
            <span class="rtp2httpd-modal-close" onclick="hideRtpLogPopup()">&times;</span>
            <h3>%s</h3>
            <textarea id="rtp2httpd-log-view" class="cbi-input-textarea" style="width: 100%%; min-height: 400px;" readonly="readonly"></textarea>
            <div style="text-align: right; padding-top: 10px;">
                <input type="button" class="cbi-button cbi-button-apply" value="%s" onclick="showRtpLogPopup('%s')" />
                <input type="button" class="cbi-button cbi-button-reset" value="%s" onclick="hideRtpLogPopup()" />
            </div>
        </div>
    </div>

    <!-- 3. 悬浮窗的CSS样式 -->
    <style>
        .rtp2httpd-modal-overlay {
            display: none; position: fixed; z-index: 1000;
            left: 0; top: 0; width: 100%%; height: 100%%;
            overflow: auto; background-color: rgba(0,0,0,0.5);
        }
        .rtp2httpd-modal-content {
            background-color: #fefefe; margin: 10%% auto; padding: 20px;
            border: 1px solid #888; width: 80%%; max-width: 900px;
            border-radius: 5px; position: relative;
        }
        .rtp2httpd-modal-close {
            color: #aaa; position: absolute; top: 5px; right: 15px;
            font-size: 28px; font-weight: bold; cursor: pointer;
        }
        .rtp2httpd-modal-close:hover,
        .rtp2httpd-modal-close:focus { color: black; }
    </style>

    <!-- 4. 控制逻辑的JavaScript -->
    <script type="text/javascript">
        var modal = document.getElementById('rtp2httpd-log-modal');
        var logView = document.getElementById('rtp2httpd-log-view');

        // 显示悬浮窗并加载日志
        function showRtpLogPopup(url) {
            logView.value = '%s';
            modal.style.display = 'block';

            // 使用LuCI内置的XHR.get发起一次性请求
            XHR.get(url, null, function(x, data) {
                if (!x || !data) {
                    logView.value = '%s';
                    return;
                }
                
                logView.value = data.log || '%s';
                // 滚动到文本框底部
                logView.scrollTop = logView.scrollHeight;
            });
        }

        // 隐藏悬浮窗
        function hideRtpLogPopup() {
            modal.style.display = 'none';
        }

        // 点击悬浮窗外部区域时关闭它
        window.addEventListener('click', function(event) {
            if (event.target == modal) {
                hideRtpLogPopup();
            }
        });
    </script>
]],
    s_view_log, log_url,
    s_viewer_title,
    s_refresh, log_url,
    s_close,
    s_loading_msg:gsub("'", "\\'"),
    s_load_failed_msg:gsub("'", "\\'"),
    s_no_entries_msg:gsub("'", "\\'")
)

o = s:option(Flag, "use_config_file", translate("Use Config File"))
o.enabled = "1"
o.disabled = "0"
o.default = o.disabled
o.rmempty = false
o.description = translate("Use config file instead of individual options")

o = s:option(Flag, "zerocopy_on_send", translate("Enable zero-copy"))
o.enabled = "1"
o.disabled = "0"
o.default = o.disabled
o.rmempty = false
o.description = translate("Enable zero-copy send with MSG_ZEROCOPY for better performance. Requires kernel 4.14+ (MSG_ZEROCOPY support).")

o = s:option(Value, "port", translate("Port"))
o.datatype = "uinteger"
o.default = "5140"
o.rmempty = false

o = s:option(ListValue, "verbose", translate("Logging level"))
o:value("0", "FATAL")
o:value("1", "ERROR")
o:value("2", "WARN")
o:value("3", "INFO")
o:value("4", "DEBUG")
o.default = "3"

o = s:option(ListValue, "upstream_interface", translate("Source interface"))
local upstream_interface = luci.sys.exec("ls -l /sys/class/net/ 2>/dev/null |awk '{print $9}' 2>/dev/null")
for upstream_interface in string.gmatch(upstream_interface, "%S+") do
   o:value(upstream_interface)
end
o:value("", translate("Disable"))
o.default = ""
o.description = translate("Default interface for all upstream traffic (multicast, FCC and RTSP).")

o = s:option(Value, "workers", translate("Workers"))
o.datatype = "uinteger"
o.default = "1"
o.description = translate("Number of worker processes. Set to 1 for resource-constrained devices, or CPU cores for best performance.")

o = s:option(Value, "maxclients", translate("Max clients allowed"))
o.datatype = "uinteger"
o.default = "10"

o = s:option(Value, "buffer_pool_max_size", translate("Buffer Pool Max Size"))
o.datatype = "uinteger"
o.default = "65536"
o.description = translate("Maximum number of buffers in zero-copy pool. Default is 16384 (~24MB). Not recommended when running behind reverse proxies.")

o = s:option(Value, "external_m3u", translate("External M3U URL"))
o.default = "file:///www/iptv/tv.m3u"
o.description = translate("Fetch M3U playlist from a URL (file://, http://, https:// supported)")

o = s:option(Value, "external_m3u_update_interval", translate("External M3U update interval"))
o.datatype = "uinteger"
o.default = "86400"
o.description = translate("External M3U automatic update interval in seconds (default: 7200 = 2 hours). Set to 0 to disable automatic updates.")

o = s:option(Value, "mcast_rejoin_interval", translate("Multicast Rejoin Interval"))
o.datatype = "uinteger"
o.default = "0"
o.description = translate("Multicast rejoin interval in seconds (default 0, disabled). Set to a positive value (e.g., 60) to periodically rejoin multicast groups. Recommended value: 30-120 seconds (less than typical switch timeout of 260s). Only enable if you experience multicast stream interruptions.")

o = s:option(Value, "fcc_listen_port_range", translate("FCC Listen Port Range"))
o.default = "40000-40100"
o.description = translate("Local UDP port range for FCC client sockets (format: start-end, e.g., 40000-40100). Leave empty to use random ports.")

return m