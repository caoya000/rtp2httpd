local i18n = require "luci.i18n"
local fs = require "nixio.fs"
local util = require "luci.util"

-- 定义配置文件的路径
local conf_path = "/etc/rtp2httpd.conf"

-- 1. 在渲染页面前，预先读取文件内容
local file_content = util.trim(fs.readfile(conf_path) or "")

-- 创建一个CBI Map
m = Map("rtp2httpd", i18n.translate("Config File"))
m.description = i18n.translate("Direct editor for the configuration file located at /etc/rtp2httpd.conf.")

if not fs.access(conf_path) then
    m.description = m.description .. "<br/><b>" .. i18n.translate("Note: The configuration file does not currently exist. It will be created upon saving.") .. "</b>"
end

-- 创建一个简单的节
s = m:section(SimpleSection)
s.anonymous = true

-- 使用 DummyValue 来手动创建整个编辑器
o = s:option(DummyValue, "_editor_area")
o.rawhtml = true
o.value = string.format(
    '<textarea class="cbi-input-textarea" name="_file_content" id="_file_content" rows="50" wrap="off" style="width:100%%; font-family:monospace;">%s</textarea>',
    file_content
)

-- 在 on_after_commit 中处理保存逻辑
function m.on_after_commit(self)
    local value = self:formvalue("_file_content")

    if value then
        local content = value:gsub("\r\n", "\n")
        fs.writefile(conf_path, content)
    end
    
    -- 在后台重启服务
    luci.sys.exec("/etc/init.d/rtp2httpd restart >/dev/null 2>&1 &")
end

return m