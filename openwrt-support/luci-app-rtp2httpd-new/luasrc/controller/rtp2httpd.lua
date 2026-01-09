module("luci.controller.rtp2httpd", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/rtp2httpd") then
		return
	end
	
	-- 主入口，默认指向“Settings”标签页
	entry({"admin", "services", "rtp2httpd"}, alias("admin", "services", "rtp2httpd", "settings"), _("Rtp2httpd"), 60).dependent = true

	-- “Settings”标签页 (序号 1)
	entry({"admin", "services", "rtp2httpd", "settings"}, cbi("rtp2httpd"), _("Settings"), 1).leaf = true

	-- “Config File”标签页 (序号 2)
	entry({"admin", "services", "rtp2httpd", "config"}, cbi("rtp2httpd-config"), _("Config File"), 2).leaf = true

	-- “Log”标签页 (序号 3)
	entry({"admin", "services", "rtp2httpd", "log"}, cbi("rtp2httpd-log"), _("Log"), 3).leaf = true

	-- 后端API接口
	entry({"admin", "services", "rtp2httpd", "status"}, call("act_status")).leaf = true
	entry({'admin', 'services', 'rtp2httpd', 'realtime_log'}, call('get_log')).json = true
end


local function is_running()
	return luci.sys.call("pidof rtp2httpd >/dev/null") == 0
end

function act_status()
	local e = {}
	e.running = is_running()
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function get_log()
    local util = require "luci.util"
    local log_output = util.trim(util.exec("logread | grep rtp2httpd"))
	luci.http.prepare_content("application/json")
	luci.http.write_json({ log = log_output })
end