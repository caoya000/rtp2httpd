-- rtp2httpd luci CBI for OpenWrt
local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"
local uci = require "luci.model.uci".cursor()
local i18n = require "luci.i18n"

m = Map("rtp2httpd", "rtp2httpd", i18n.translate("Rtp2httpd converts RTP/UDP/RTSP media into http stream. Here you can configure the settings."))

m:section(SimpleSection).template="rtp2httpd/rtp2httpd_status"
s = m:section(TypedSection, "rtp2httpd", "")
s.anonymous = true
s.addremove = false

--------------------------------------------------------
-- Tabs
--------------------------------------------------------
s:tab("basic", i18n.translate("Basic Settings"))
s:tab("network", i18n.translate("Network & Performance"))
s:tab("player", i18n.translate("Player & M3U"))
s:tab("advanced", i18n.translate("Monitoring & Advanced"))

--------------------------------------------------------
-- 基础设置
--------------------------------------------------------
o = s:taboption("basic", Flag, "disabled", i18n.translate("Enabled"), i18n.translate("Enable rtp2httpd Service"))
o.default = "0"
o.enabled = "0"
o.disabled = "1"
o.rmempty = false

o = s:taboption("basic", Flag, "respawn", i18n.translate("Respawn"), i18n.translate("Auto restart after crash"))
o.default = "1"

o = s:taboption("basic", Value, "port", i18n.translate("Port"))
o.datatype = "port"
o.placeholder = "5140"
o.default = "5140"

o = s:taboption("basic", ListValue, "verbose", i18n.translate("Logging level"))
o:value("0","Fatal")
o:value("1","Error")
o:value("2","Warn")
o:value("3","Info")
o:value("4","Debug")
o.default = "1"

o = s:taboption("basic", Value, "hostname", i18n.translate("Hostname"),
    i18n.translate("When configured, HTTP Host header will be checked and must match this value to allow access. M3U conversion will also use this value as the domain for the converted program address. When using reverse proxy, it needs to be configured as the access address after the reverse proxy (including http(s):// and path prefix), for example https://my-domain.com/rtp2httpd, and the reverse proxy needs to pass the Host header."))

--------------------------------------------------------
-- 获取物理接口
--------------------------------------------------------
local function get_upstream_interfaces()
    local interfaces = {}
    local all = sys.net.devices() or {}

    for _, dev in ipairs(all) do
        -- 排除常见虚拟和隧道接口
        if not dev:match("^(lo)$") and
           not dev:match("^ifb%d*$") and
           not dev:match("^gre%d*$") and
           not dev:match("^gretap%d*$") and
           not dev:match("^miireg%d*$") and               
           not dev:match("^ip6gre%d*$") and                    
           not dev:match("^ip6tnl%d*$") and
           not dev:match("^docker%d*$") and
           not dev:match("^sit%d*$") and             
           not dev:match("^bond%d*$") and
           not dev:match("^erspan%d*$") and
           not dev:match("^tun%d*$") then
            table.insert(interfaces, dev)
        end
    end

    -- 排序：物理接口优先，其余按名称排序
    table.sort(interfaces, function(a,b)
        local pa = a:match("^eth%d+") and 0 or 1
        local pb = b:match("^eth%d+") and 0 or 1
        if pa == pb then return a < b else return pa < pb end
    end)

    return interfaces
end

local net_devices = get_upstream_interfaces()

--------------------------------------------------------
-- 网络与接口设置
--------------------------------------------------------
o = s:taboption("network", Flag, "advanced_interface_settings", i18n.translate("Advanced Interface Settings"), i18n.translate("Configure separate interfaces for multicast, FCC and RTSP"))
o.default = "0"

o = s:taboption("network", ListValue, "upstream_interface", i18n.translate("Upstream Interface"), i18n.translate("Default interface for all upstream traffic (multicast, FCC and RTSP). Leave empty to use routing table."))
o:value("", i18n.translate("Auto Select"))
for _, dev in ipairs(net_devices) do o:value(dev) end
o:depends("advanced_interface_settings", "")
o:depends("advanced_interface_settings", "0")

local function add_interface_list(opt, depends_val, description)
    opt.description = description
    opt:value("", i18n.translate("Auto Select"))
    for _, dev in ipairs(net_devices) do
        opt:value(dev)
    end
    opt:depends("advanced_interface_settings", depends_val)
end

o = s:taboption("network", ListValue, "upstream_interface_multicast", i18n.translate("Upstream Multicast Interface"))
add_interface_list(o, "1", i18n.translate("Interface to use for multicast (RTP/UDP) upstream media stream (default: use routing table)"))

o = s:taboption("network", ListValue, "upstream_interface_fcc", i18n.translate("Upstream FCC Interface"))
add_interface_list(o, "1", i18n.translate("Interface to use for FCC unicast upstream media stream (default: use routing table)"))

o = s:taboption("network", ListValue, "upstream_interface_rtsp", i18n.translate("Upstream RTSP Interface"))
add_interface_list(o, "1", i18n.translate("Interface to use for RTSP unicast upstream media stream (default: use routing table)"))

o = s:taboption("network", ListValue, "upstream_interface_http", i18n.translate("Upstream HTTP Proxy Interface"))
add_interface_list(o, "1", i18n.translate("Interface to use for HTTP proxy upstream requests (default: use routing table)"))

o = s:taboption("network", Value, "maxclients", i18n.translate("Max clients allowed"))
o.datatype = "range(1,5000)"
o.placeholder = "10"
o.default = "10"

o = s:taboption("network", Value, "workers", i18n.translate("Workers"), i18n.translate("Number of worker processes. Set to 1 for resource-constrained devices, or CPU cores for best performance."))
o.datatype = "range(1,64)"
o.placeholder = "1"
o.default = "1"

o = s:taboption("network", Value, "buffer_pool_max_size", i18n.translate("Buffer Pool Max Size"), i18n.translate("Maximum number of buffers in zero-copy pool. Each buffer is 1536 bytes. Default is 16384 (~24MB). Increase to improve throughput for multi-client concurrency."))
o.datatype = "range(1024,1048576)"
o.placeholder = "65536"
o.default = "65536"

o = s:taboption("network", Value, "udp_rcvbuf_size", i18n.translate("UDP Receive Buffer Size"), i18n.translate("UDP socket receive buffer size in bytes. Applies to multicast, FCC, and RTSP sockets. Default is 524288 (512KB). For 4K IPTV streams at ~30 Mbps, 512KB provides ~140ms of buffering. Increase to reduce packet loss. Note: actual size may be limited by kernel parameter net.core.rmem_max."))
o.datatype = "range(65536, 16777216)"
o.placeholder = "3145728"
o.default = "3145728"

o = s:taboption("network", Flag, "zerocopy_on_send", i18n.translate("Zero-Copy on Send"), i18n.translate("Enable zero-copy send with MSG_ZEROCOPY for better performance. On supported devices, this can improve throughput and reduce CPU usage, especially under high concurrent load. Recommended only when experiencing performance bottlenecks."))
o.default = "0"

o = s:taboption("network", Value, "rtsp_stun_server", i18n.translate("RTSP STUN Server"), i18n.translate("When RTSP server only supports UDP transport and client is behind NAT, try using STUN for NAT traversal (may not always succeed). Format: host:port or host (default port 3478). Example: stun.miwifi.com"))
o.placeholder = "stun.miwifi.com"

o = s:taboption("network", Value, "mcast_rejoin_interval", i18n.translate("Multicast Rejoin Interval"), i18n.translate("Periodic multicast rejoin interval in seconds (0=disabled, default 0). Enable this (e.g., 30-120 seconds) if your network switches timeout multicast memberships due to missing IGMP Query messages. Only use when experiencing multicast stream interruptions."))
o.datatype = "range(0,86400)"
o.placeholder = "0"
o.default = "0"

o = s:taboption("network", Value, "fcc_listen_port_range", i18n.translate("FCC Listen Port Range"), i18n.translate("Local UDP port range for FCC client sockets (format: start-end, e.g., 40000-40100). Leave empty to use random ports."))
o.placeholder = ""

--------------------------------------------------------
-- 播放器
--------------------------------------------------------
o = s:taboption("player", Value, "external_m3u", i18n.translate("External M3U"), i18n.translate("Fetch M3U playlist from a URL (file://, http://, https:// supported). Example: https://example.com/playlist.m3u or file:///path/to/playlist.m3u"))
o.placeholder = "file:///www/iptv/tv.m3u"
o.default = "file:///www/iptv/tv.m3u"

o = s:taboption("player", Value, "external_m3u_update_interval", i18n.translate("External M3U Update Interval"), i18n.translate("External M3U automatic update interval in seconds (default: 7200 = 2 hours). Set to 0 to disable automatic updates."))
o.datatype = "uinteger"
o.placeholder = "7200"

o = s:taboption("player", Value, "player_page_path", i18n.translate("Player Page Path"), i18n.translate("URL path for the player page (default: /player)"))
o.placeholder = "/player"
o.default = "/player"

--------------------------------------------------------
--新窗口打开
--------------------------------------------------------
local function make_popup_link(map, section, pathKey)
    local defaultPath = (pathKey == "status_page_path") and "/status" or "/player"
    local pagePath = map:get(section, pathKey) or defaultPath
    if pagePath:sub(1,1) ~= "/" then
        pagePath = "/" .. pagePath
    end

    -- 读取端口
    local port = tonumber(map:get(section, "port")) or 5140

    -- token 参数
    local token = map:get(section, "r2h_token")
    local token_param = (token and token ~= "") and ("?r2h-token=" .. http.urlencode(token)) or ""

    -- 使用浏览器访问 LuCI 时的 host
    local host = http.getenv("HTTP_HOST") or "127.0.0.1"
    host = host:match("([^:]+)") or host  -- 去掉可能的端口

    return string.format("http://%s:%s%s%s", host, port, pagePath, token_param)
end

--------------------------------------------------------
-- 播放器按钮
--------------------------------------------------------
o = s:taboption("player", DummyValue, "_player_page_link", i18n.translate("Player Page"))
o.rawhtml = true
function o.cfgvalue(self, section)
    local url = make_popup_link(self.map, section, "player_page_path")
    return string.format(
        '<a class="cbi-button cbi-button-apply" href="%s" target="_blank">%s</a>',
        url, i18n.translate("Open Player Page")
    )
end

--------------------------------------------------------
-- 播放器警告
--------------------------------------------------------
o = s:taboption("player", DummyValue, "_player_warning", "")
o.rawhtml = true
function o.cfgvalue(self, section)
    local m3u = m:get(section, "external_m3u") or ""
    if m3u == "" then
        return '<div class="alert-message warning" style="margin-top: 10px;">' .. i18n.translate("Please configure External M3U URL first") .. '</div>'
    end
    return ""
end

--------------------------------------------------------
-- 状态面板
--------------------------------------------------------
o = s:taboption("advanced", DummyValue, "_status_dashboard_link", i18n.translate("Status Dashboard"))
o.rawhtml = true
function o.cfgvalue(self, section)
    local url = make_popup_link(self.map, section, "status_page_path")
    return string.format(
        '<a class="cbi-button cbi-button-apply" href="%s" target="_blank">%s</a>',
        url, i18n.translate("Open Status Dashboard")
    )
end

o = s:taboption("advanced", Value, "status_page_path", i18n.translate("Status Page Path"), i18n.translate("URL path for the status page (default: /status)"))
o.placeholder = "/status"
o.default = "/status"

o = s:taboption("advanced", Value, "r2h_token", i18n.translate("R2H Token"), i18n.translate("If set, all HTTP requests must include r2h-token query parameter with matching value (e.g., http://server:port/rtp/ip:port?fcc=ip:port&r2h-token=your-token)"))
o.password = true

o = s:taboption("advanced", Flag, "xff", "X-Forwarded-For", i18n.translate("When enabled, uses HTTP X-Forwarded-For header as client address for status page display. Also accepts X-Forwarded-Host / X-Forwarded-Proto headers as the base URL for M3U playlist conversion. Only enable when running behind a reverse proxy."))
o.default = "0"

o = s:taboption("advanced", Flag, "video_snapshot", i18n.translate("Video Snapshot"), i18n.translate("Enable video snapshot feature. When enabled, clients can request snapshots with snapshot=1 query parameter"))
o.default = "0"

o = s:taboption("advanced", Value, "ffmpeg_path", i18n.translate("FFmpeg Path"), i18n.translate("Path to FFmpeg executable. Leave empty to use system PATH (default: ffmpeg)"))
o.placeholder = "ffmpeg"
o:depends("video_snapshot", "1")

o = s:taboption("advanced", Value, "ffmpeg_args", i18n.translate("FFmpeg Arguments"), i18n.translate("Additional FFmpeg arguments for snapshot generation. Common options: -hwaccel none, -hwaccel auto, -hwaccel vaapi (for Intel GPU)"))
o.placeholder = "-hwaccel none"
o:depends("video_snapshot", "1")

--------------------------------------------------------
-- on_after_commit 处理接口动态显示
--------------------------------------------------------
m.on_after_commit = function(self)
    http.write([[
<script>
document.addEventListener('DOMContentLoaded', function() {
    function update() {
        var adv = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.advanced_interface_settings"]');
        var isAdv = adv && adv.checked;

        function toggle(name, show) {
            var el = document.querySelector(name);
            if (el) {
                var row = el.closest('.cbi-value');
                if (row) row.style.display = show ? '' : 'none';
            }
        }

        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface"]', !isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_multicast"]', isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_fcc"]', isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_rtsp"]', isAdv);
    }

    update();
    var adv = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.advanced_interface_settings"]');
    if (adv) adv.addEventListener('change', update);
});
</script>
    ]])
end

--------------------------------------------------------
-- 服务自动启停
--------------------------------------------------------
m.apply_on_parse = true
m.on_after_apply = function()
    os.execute("sed -i 's/option use_config_file .*/option use_config_file '\\''0'\\''/' /etc/config/rtp2httpd")
    uci:commit("rtp2httpd")
    uci:load("rtp2httpd")

    local file = io.open("/etc/config/rtp2httpd", "r")
    local disabled = "1"

    if file then
        for line in file:lines() do
            local v = line:match("option%s+disabled%s+'([01])'")
            if v then disabled = v end
        end
        file:close()
    end

    if disabled == "0" then
        os.execute("/etc/init.d/rtp2httpd enable")
        os.execute("/etc/init.d/rtp2httpd restart")
    else
        os.execute("/etc/init.d/rtp2httpd disable")
        os.execute("/etc/init.d/rtp2httpd stop")
    end
end

return m
