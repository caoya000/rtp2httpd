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

local function trim_value(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_listen_values(value)
    local values = {}
    local input = {}

    if type(value) == "table" then
        input = value
    elseif value ~= nil and value ~= "" then
        input = { value }
    end

    for _, item in ipairs(input) do
        local listen = trim_value(item)
        if listen ~= "" then
            table.insert(values, listen)
        end
    end

    return values
end

local function get_listen_values(map, section)
    return normalize_listen_values(map:get(section, "listen"))
end

local function parse_listen_value(value)
    local listen = trim_value(value)
    local host = nil
    local port = nil

    if listen == "" then
        return nil
    end

    if listen:sub(1, 1) == "/" then
        if listen:match("%s") then
            return nil
        end

        return {
            host = nil,
            port = nil,
            socket_path = listen
        }
    end

    if listen:match("^%d+$") then
        port = listen
    elseif listen:sub(1, 1) == "[" then
        local ipv6_host, ipv6_port = listen:match("^%[([^%]]+)%]:(%d+)$")
        if not ipv6_host then
            return nil
        end

        host = "[" .. ipv6_host .. "]"
        port = ipv6_port
    else
        local first_colon = listen:find(":", 1, true)
        local last_colon = listen:match("^.*():")

        if not first_colon or first_colon <= 1 or first_colon ~= last_colon then
            return nil
        end

        host = listen:sub(1, first_colon - 1)
        port = listen:sub(first_colon + 1)
    end

    if not port or not port:match("^%d+$") then
        return nil
    end

    local port_number = tonumber(port)
    if not port_number or port_number < 1 or port_number > 65535 then
        return nil
    end

    if host ~= nil and (host == "*" or host:find("/", 1, true) or host:match("%s")) then
        return nil
    end

    return {
        host = host,
        port = port,
        socket_path = nil
    }
end

local function get_primary_listen_target(map, section)
    for _, listen in ipairs(get_listen_values(map, section)) do
        local target = parse_listen_value(listen)
        if target and target.port then
            return target
        end
    end

    local port = map:get(section, "port") or "5140"
    return parse_listen_value(port) or { host = nil, port = "5140", socket_path = nil }
end

local function get_primary_listen_port(map, section)
    return get_primary_listen_target(map, section).port or "5140"
end

local function count_char(value, char)
    local _, count = tostring(value or ""):gsub(char, "")
    return count
end

local function get_config_value(config_content, key)
    local pattern = "^%s*" .. key .. "%s*=?%s*(.-)%s*$"

    for line in tostring(config_content or ""):gmatch("[^\r\n]+") do
        local value = line:match(pattern)
        if value and value ~= "" then
            return trim_value(value)
        end
    end

    return nil
end

local function get_config_listen_port(config_content)
    for line in tostring(config_content or ""):gmatch("[^\r\n]+") do
        local port = line:match("^%s*%*%s+(%d+)%s*$")
        if port then
            return port
        end
    end

    for line in tostring(config_content or ""):gmatch("[^\r\n]+") do
        local host, port = line:match("^%s*([^%s=]+)%s+(%d+)%s*$")
        if host and port and host ~= "*" then
            return port
        end
    end

    return nil
end

local function get_request_host()
    local host = trim_value(http.getenv("HTTP_HOST"))

    if host == "" then
        return "127.0.0.1"
    end

    if host:sub(1, 1) == "[" then
        return host:match("^(%b[])") or host
    end

    if count_char(host, ":") == 1 then
        return host:match("^([^:]+)") or host
    end

    return host
end

local function normalize_path(value, default_value)
    local path = trim_value(value)

    if path == "" then
        path = default_value or ""
    end

    if path ~= "" and path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return path
end

local function normalize_app_path_prefix(value)
    local path = trim_value(value)

    path = path:gsub("^/+", ""):gsub("/+$", "")
    if path == "" then
        return ""
    end

    return "/" .. path
end

local function parse_target_hostname(value)
    local target = trim_value(value)
    local protocol, authority = target:match("^(https?)://(.+)$")
    local has_protocol = protocol ~= nil
    local base_path = ""

    if not has_protocol then
        protocol = "http"
        authority = target
    end

    if not authority or authority == "" then
        return nil
    end

    local slash_index = authority:find("/", 1, true)
    if slash_index then
        base_path = authority:sub(slash_index)
        authority = authority:sub(1, slash_index - 1)
    end

    if authority:find("[", 1, true) == nil and count_char(authority, ":") > 1 then
        authority = "[" .. authority .. "]"
    end

    local host = nil
    local port = ""

    if authority:sub(1, 1) == "[" then
        host = authority:match("^(%b[])")
        port = authority:match("^%b[]:(%d+)$") or ""
    else
        if count_char(authority, ":") == 1 then
            host, port = authority:match("^([^:]+):(%d+)$")
        end

        if not host then
            host = authority
            port = ""
        end
    end

    if not host or host == "" then
        return nil
    end

    return {
        has_protocol = has_protocol,
        protocol = protocol,
        host = host,
        port = port,
        base_path = base_path
    }
end

local function append_query_param(url, key, value)
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. key .. "=" .. http.urlencode(value)
end

local function build_page_url(map, section, pathKey)
    local defaultPath = (pathKey == "status_page_path") and "/status" or "/player"
    local configPathKey = (pathKey == "status_page_path") and "status-page-path" or "player-page-path"
    local use_config_file = map:get(section, "use_config_file")
    local port = "5140"
    local token = nil
    local pagePath = defaultPath
    local appPathPrefix = ""
    local hostname = nil
    local listenTarget = nil

    if use_config_file == "1" then
        local configContent = fs.readfile("/etc/rtp2httpd.conf") or ""
        port = get_config_listen_port(configContent) or port
        hostname = get_config_value(configContent, "hostname")
        token = get_config_value(configContent, "r2h%-token")
        pagePath = get_config_value(configContent, configPathKey) or pagePath
        appPathPrefix = get_config_value(configContent, "app%-path%-prefix") or ""
    else
        listenTarget = get_primary_listen_target(map, section)
        port = listenTarget.port or port
        token = map:get(section, "r2h_token")
        hostname = map:get(section, "hostname")
        pagePath = map:get(section, pathKey) or pagePath
        appPathPrefix = map:get(section, "app_path_prefix") or ""
    end

    pagePath = normalize_path(pagePath, defaultPath)
    appPathPrefix = normalize_app_path_prefix(appPathPrefix)

    local targetHostname = trim_value(hostname)
    if targetHostname == "" then
        targetHostname = (listenTarget and listenTarget.host) or get_request_host()
    end

    local parsedTarget = parse_target_hostname(targetHostname)
    if not parsedTarget then
        local fallbackUrl = "http://" .. get_request_host() .. ":" .. port .. pagePath
        if token and token ~= "" then
            fallbackUrl = append_query_param(fallbackUrl, "r2h-token", token)
        end
        return fallbackUrl
    end

    local finalPort = ""
    if not parsedTarget.has_protocol then
        finalPort = (parsedTarget.port ~= "" and parsedTarget.port) or port
    else
        finalPort = parsedTarget.port or ""
    end

    local pageUrl = parsedTarget.protocol .. "://" .. parsedTarget.host
    if finalPort ~= "" and not ((parsedTarget.protocol == "http" and finalPort == "80") or (parsedTarget.protocol == "https" and finalPort == "443")) then
        pageUrl = pageUrl .. ":" .. finalPort
    end

    if appPathPrefix == "" and parsedTarget.base_path ~= "" and parsedTarget.base_path ~= "/" then
        if parsedTarget.base_path:sub(-1) ~= "/" then
            pageUrl = pageUrl .. parsedTarget.base_path .. "/"
        else
            pageUrl = pageUrl .. parsedTarget.base_path
        end

        if pagePath:sub(1, 1) == "/" then
            pagePath = pagePath:sub(2)
        end
    end

    if appPathPrefix ~= "" then
        if pageUrl:sub(-1) == "/" then
            pageUrl = pageUrl .. appPathPrefix:sub(2)
        else
            pageUrl = pageUrl .. appPathPrefix
        end

        if pagePath:sub(1, 1) == "/" then
            pagePath = pagePath:sub(2)
        end

        if pageUrl:sub(-1) ~= "/" then
            pageUrl = pageUrl .. "/"
        end
    end

    pageUrl = pageUrl .. pagePath
    if token and token ~= "" then
        pageUrl = append_query_param(pageUrl, "r2h-token", token)
    end

    return pageUrl
end

local function escape_js_string(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\r", "\\r"):gsub("\n", "\\n")
end

local function with_use_config_file_value(values, use_config_value)
    local merged = {}

    for key, value in pairs(values) do
        merged[key] = value
    end

    merged.use_config_file = use_config_value
    return merged
end

local function depends_on_uci_mode(opt)
    opt:depends("use_config_file", "")
    opt:depends("use_config_file", "0")
end

local function depends_on_uci_mode_with_values(opt, values)
    opt:depends(with_use_config_file_value(values, ""))
    opt:depends(with_use_config_file_value(values, "0"))
end

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

o = s:taboption("basic", Flag, "use_config_file", i18n.translate("Use Config File"), i18n.translate("Use config file instead of individual options"))
o.default = "0"

o = s:taboption("basic", TextValue, "config_file_content", i18n.translate("Config File Content"), i18n.translate("Edit the content of /etc/rtp2httpd.conf"))
o.rows = 40
o.cols = 80
o.monospace = true
o:depends("use_config_file", "1")
function o.cfgvalue(self, section)
    return fs.readfile("/etc/rtp2httpd.conf") or ""
end

function o.write(self, section, value)
    fs.writefile("/etc/rtp2httpd.conf", value or "")

    local cursor = (self.map and self.map.uci) or uci
    cursor:set("rtp2httpd", section, "config_update_time", tostring(os.time()))
end

o = s:taboption("basic", DynamicList, "listen", i18n.translate("Listen Addresses"), i18n.translate("HTTP listen addresses. Use a bare port for all addresses (e.g., 5140), address:port for IPv4/hostnames, [IPv6]:port, or an absolute Unix socket path."))
o.default = "5140"
o.rmempty = true
depends_on_uci_mode(o)
function o.cfgvalue(self, section)
    local values = get_listen_values(self.map, section)

    if #values > 0 then
        return values
    end

    local port = self.map:get(section, "port")
    return port and { port } or {}
end

function o.write(self, section, value)
    local values = normalize_listen_values(value)
    local cursor = (self.map and self.map.uci) or uci

    if #values > 0 then
        cursor:set_list("rtp2httpd", section, self.option, values)
    else
        cursor:delete("rtp2httpd", section, self.option)
    end

    cursor:delete("rtp2httpd", section, "port")
end

function o.remove(self, section)
    local cursor = (self.map and self.map.uci) or uci

    cursor:delete("rtp2httpd", section, self.option)
    cursor:delete("rtp2httpd", section, "port")
end

function o.validate(self, value, section)
    local values = normalize_listen_values(value)

    for _, listen in ipairs(values) do
        if listen:match("^%*:") then
            return nil, i18n.translate("Use a bare port such as 5140 to listen on all addresses; *:5140 is not supported here.")
        end

        if not parse_listen_value(listen) then
            return nil, i18n.translate("Use port, address:port, hostname:port, [IPv6]:port, or an absolute Unix socket path, for example 5140, 192.168.1.1:8081, or /var/run/rtp2httpd.sock.")
        end
    end

    if type(value) == "table" then
        return values
    end

    return values[1] or ""
end

o = s:taboption("basic", ListValue, "verbose", i18n.translate("Logging level"))
o:value("0","Fatal")
o:value("1","Error")
o:value("2","Warn")
o:value("3","Info")
o:value("4","Debug")
o.default = "1"
depends_on_uci_mode(o)

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
depends_on_uci_mode(o)

o = s:taboption("network", ListValue, "upstream_interface", i18n.translate("Upstream Interface"), i18n.translate("Default interface for all upstream traffic (multicast, FCC and RTSP). Leave empty to use routing table."))
o:value("", i18n.translate("Auto Select"))
for _, dev in ipairs(net_devices) do o:value(dev) end
depends_on_uci_mode_with_values(o, { advanced_interface_settings = "" })
depends_on_uci_mode_with_values(o, { advanced_interface_settings = "0" })

local function add_interface_list(opt, depends_val, description)
    opt.description = description
    opt:value("", i18n.translate("Auto Select"))
    for _, dev in ipairs(net_devices) do
        opt:value(dev)
    end
    depends_on_uci_mode_with_values(opt, { advanced_interface_settings = depends_val })
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
depends_on_uci_mode(o)

o = s:taboption("network", Value, "workers", i18n.translate("Workers"), i18n.translate("Number of worker processes. Set to 1 for resource-constrained devices, or CPU cores for best performance."))
o.datatype = "range(1,64)"
o.placeholder = "1"
o.default = "1"
depends_on_uci_mode(o)

o = s:taboption("network", Value, "buffer_pool_max_size", i18n.translate("Buffer Pool Max Size"), i18n.translate("Maximum number of buffers in zero-copy pool. Each buffer is 1536 bytes. Default is 16384 (~24MB). Increase to improve throughput for multi-client concurrency."))
o.datatype = "range(1024,1048576)"
o.placeholder = "65536"
o.default = "65536"
depends_on_uci_mode(o)

o = s:taboption("network", Value, "udp_rcvbuf_size", i18n.translate("UDP Receive Buffer Size"), i18n.translate("UDP socket receive buffer size in bytes. Applies to multicast, FCC, and RTSP sockets. Default is 524288 (512KB). For 4K IPTV streams at ~30 Mbps, 512KB provides ~140ms of buffering. Increase to reduce packet loss. Note: actual size may be limited by kernel parameter net.core.rmem_max."))
o.datatype = "range(65536, 16777216)"
o.placeholder = "3145728"
o.default = "3145728"
depends_on_uci_mode(o)

o = s:taboption("network", Value, "mcast_rejoin_interval", i18n.translate("Multicast Rejoin Interval"), i18n.translate("Periodic multicast rejoin interval in seconds (0=disabled, default 0). Enable this (e.g., 30-120 seconds) if your network switches timeout multicast memberships due to missing IGMP Query messages. Only use when experiencing multicast stream interruptions."))
o.datatype = "range(0,86400)"
o.placeholder = "0"
o.default = "0"
depends_on_uci_mode(o)

o = s:taboption("network", Value, "fcc_listen_port_range", i18n.translate("FCC Listen Port Range"), i18n.translate("Local UDP port range for FCC client sockets (format: start-end, e.g., 40000-40100). Leave empty to use random ports."))
o.placeholder = ""
depends_on_uci_mode(o)

o = s:taboption("network", Flag, "zerocopy_on_send", i18n.translate("Zero-Copy on Send"), i18n.translate("Enable zero-copy send with MSG_ZEROCOPY for better performance. On supported devices, this can improve throughput and reduce CPU usage, especially under high concurrent load. Recommended only when experiencing performance bottlenecks."))
o.default = "0"
depends_on_uci_mode(o)

o = s:taboption("network", Value, "rtsp_stun_server", i18n.translate("RTSP STUN Server"), i18n.translate("When RTSP server only supports UDP transport and client is behind NAT, try using STUN for NAT traversal (may not always succeed). Format: host:port or host (default port 3478). Example: stun.miwifi.com"))
o.placeholder = "stun.miwifi.com"
depends_on_uci_mode(o)

--------------------------------------------------------
-- 播放器
--------------------------------------------------------
o = s:taboption("player", Value, "external_m3u", i18n.translate("External M3U"), i18n.translate("Fetch M3U playlist from a URL (file://, http://, https:// supported). Example: https://example.com/playlist.m3u or file:///path/to/playlist.m3u"))
o.placeholder = "file:///www/iptv/tv.m3u"
o.default = "file:///www/iptv/tv.m3u"
depends_on_uci_mode(o)

o = s:taboption("player", Value, "external_m3u_update_interval", i18n.translate("External M3U Update Interval"), i18n.translate("External M3U automatic update interval in seconds (default: 7200 = 2 hours). Set to 0 to disable automatic updates."))
o.datatype = "uinteger"
o.placeholder = "7200"
depends_on_uci_mode(o)

o = s:taboption("player", Value, "player_page_path", i18n.translate("Player Page Path"), i18n.translate("URL path for the player page (default: /player)"))
o.placeholder = "/player"
o.default = "/player"
depends_on_uci_mode(o)

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
    local port = tonumber(get_primary_listen_port(map, section)) or 5140

    -- token 参数
    local token = map:get(section, "r2h_token")
    local token_param = (token and token ~= "") and ("?r2h-token=" .. http.urlencode(token)) or ""

    -- 使用浏览器访问 LuCI 时的 host
    local host = http.getenv("HTTP_HOST") or "127.0.0.1"
    host = host:match("([^:]+)") or host  -- 去掉可能的端口

    return string.format("http://%s:%s%s%s", host, port, pagePath, token_param)
end

make_popup_link = function(map, section, pathKey)
    return build_page_url(map, section, pathKey)
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

function o.cfgvalue(self, section)
    local url = make_popup_link(self.map, section, "player_page_path")
    local use_config_file = self.map:get(section, "use_config_file")
    local external_m3u = trim_value(self.map:get(section, "external_m3u"))

    if use_config_file ~= "1" and external_m3u == "" then
        return string.format(
            '<a class="cbi-button cbi-button-apply" href="#" onclick="alert(\'%s\'); return false;">%s</a>',
            escape_js_string(i18n.translate("Please configure External M3U URL first")),
            i18n.translate("Open Player Page")
        )
    end

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
depends_on_uci_mode_with_values(o, { external_m3u = "" })
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
depends_on_uci_mode(o)

-- 新增：App Path Prefix
o = s:taboption("advanced", Value, "app_path_prefix", i18n.translate("App Path Prefix"), i18n.translate("Public mount path prefix for all rtp2httpd HTTP resources, for example /app/rtp2httpd."))
o.placeholder = "/app/rtp2httpd"
depends_on_uci_mode(o)

-- 新增：Use Relative Paths in M3U
o = s:taboption("advanced", Flag, "use_relative_path_in_m3u", i18n.translate("Use Relative Paths in M3U"), i18n.translate("When enabled, generated and rewritten M3U playlists omit the http://host prefix and use root-relative paths."))
o.default = "0"
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "hostname", i18n.translate("Hostname"), i18n.translate("When configured, HTTP Host header will be checked and must match this value to allow access."))
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "r2h_token", i18n.translate("R2H Token"), i18n.translate("If set, all HTTP requests must include r2h-token query parameter with matching value (e.g., http://server:port/rtp/ip:port?fcc=ip:port&r2h-token=your-token)"))
o.password = true
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "cors_allow_origin", i18n.translate("CORS Allow Origin"), i18n.translate("Set Access-Control-Allow-Origin header to enable CORS. Use * to allow all origins, or specify a domain (e.g., https://example.com). Leave empty to disable CORS."))
o.placeholder = "*"
depends_on_uci_mode(o)

o = s:taboption("advanced", Flag, "xff", i18n.translate("X-Forwarded-For"), i18n.translate("When enabled, uses HTTP X-Forwarded-For header as client address for status page display. Also accepts X-Forwarded-Host / X-Forwarded-Proto headers as the base URL for M3U playlist conversion. Only enable when running behind a reverse proxy."))
o.default = "0"
depends_on_uci_mode(o)

-- 新增：Access Log Path
o = s:taboption("advanced", Value, "access_log", i18n.translate("Access Log Path"), i18n.translate("Write one access log line for each media request. Leave empty to disable access logging."))
o.placeholder = "/tmp/rtp2httpd-access.log"
depends_on_uci_mode(o)

-- 新增：Access Log Format
o = s:taboption("advanced", Value, "log_format", i18n.translate("Access Log Format"), i18n.translate("Nginx-style access log format. Empty uses the default format. Supported variables include $client_addr, $time_iso8601, $service_url, $service_type and $upstream_url."))
o.placeholder = '$client_addr [$time_iso8601] "$service_url" $service_type "$upstream_url"'
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "http_proxy_user_agent", i18n.translate("HTTP Proxy User-Agent"), i18n.translate("Override the User-Agent header sent to upstream HTTP proxy requests. Leave empty to forward the client User-Agent as-is."))
o.placeholder = ""
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "rtsp_user_agent", i18n.translate("RTSP User-Agent"), i18n.translate("User-Agent header used for upstream RTSP requests. Leave empty to use the default rtp2httpd/{version}."))
o.placeholder = ""
depends_on_uci_mode(o)

o = s:taboption("advanced", Flag, "video_snapshot", i18n.translate("Video Snapshot"), i18n.translate("Enable video snapshot feature. When enabled, clients can request snapshots with snapshot=1 query parameter"))
o.default = "0"
depends_on_uci_mode(o)

o = s:taboption("advanced", Value, "ffmpeg_path", i18n.translate("FFmpeg Path"), i18n.translate("Path to FFmpeg executable. Leave empty to use system PATH (default: ffmpeg)"))
o.placeholder = "ffmpeg"
depends_on_uci_mode_with_values(o, { video_snapshot = "1" })

o = s:taboption("advanced", Value, "ffmpeg_args", i18n.translate("FFmpeg Arguments"), i18n.translate("Additional FFmpeg arguments for snapshot generation. Common options: -hwaccel none, -hwaccel auto, -hwaccel vaapi (for Intel GPU)"))
o.placeholder = "-hwaccel none"
depends_on_uci_mode_with_values(o, { video_snapshot = "1" })

--------------------------------------------------------
-- on_after_commit 处理接口动态显示
--------------------------------------------------------
m.on_after_commit = function(self)
    http.write([[
<script>
document.addEventListener('DOMContentLoaded', function() {
    function update() {
        var useConfig = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.use_config_file"]');
        var adv = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.advanced_interface_settings"]');
        var isConfigFile = useConfig && useConfig.checked;
        var isAdv = adv && adv.checked;

        function toggle(name, show) {
            var el = document.querySelector(name);
            if (el) {
                var row = el.closest('.cbi-value');
                if (row) row.style.display = show ? '' : 'none';
            }
        }

        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface"]', !isConfigFile && !isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_multicast"]', !isConfigFile && isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_fcc"]', !isConfigFile && isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_rtsp"]', !isConfigFile && isAdv);
        toggle('select[name="cbid.rtp2httpd.rtp2httpd.upstream_interface_http"]', !isConfigFile && isAdv);
    }

    update();
    var useConfig = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.use_config_file"]');
    var adv = document.querySelector('input[name="cbid.rtp2httpd.rtp2httpd.advanced_interface_settings"]');
    if (useConfig) useConfig.addEventListener('change', update);
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
    uci:commit("rtp2httpd")
    uci:load("rtp2httpd")

    local file = io.open("/etc/config/rtp2httpd", "r")
    local disabled = "1"

    if file then
        for line in file:lines() do
            local v = line:match("option%s+disabled%s+['\"]?([01])['\"]?")
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
