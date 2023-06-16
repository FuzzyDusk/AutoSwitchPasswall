local api = require "luci.model.cbi.passwall.api.api"
local appname = api.appname
local ucic = luci.model.uci.cursor()

local latency={}

-- 清空文件
luci.sys.exec('echo -n "" >/root/latency.txt')
luci.sys.exec('echo -n "" >/root/latency.bck')

function urltest_node(id)
	local result = luci.sys.exec(string.format("/usr/share/passwall/test.sh url_test_node %s %s", id, "urltest_node"))
	local code = tonumber(luci.sys.exec("echo -n '" .. result .. "' | awk -F ':' '{print $1}'") or "0")
	if code ~= 0 then
		local latency = luci.sys.exec("echo -n '" .. result .. "' | awk -F ':' '{print $2}'")
		if latency:find("%.") then
			latency = string.format("%.2f", latency * 1000)
		else
			latency = string.format("%.2f", latency / 1000)
		end
		print("latency-->" .. latency)
		luci.sys.exec("echo "..latency.." "..id.." >>/root/latency.txt")
	else
		print("连接超时")
	end
	print("-------------------------------------------")
end

function set_node(protocol, id)
	ucic:set(appname, "@global[0]", protocol .. "_node", id)
	ucic:commit(appname)
	luci.sys.call("/etc/init.d/passwall restart > /dev/null 2>&1 &")
end

print("正在获取测试节点可用性...")
for k, e in ipairs(api.get_valid_nodes()) do
	if e.node_type == "normal" then
		print("id-->" .. e[".name"])
		print("remarks-->" .. e["remark"])
		urltest_node(e[".name"])
	end
end

-- 貌似协程也没快到哪里去
-- local coroutine_list={}

-- local index=1
-- for k, e in ipairs(api.get_valid_nodes()) do
-- 	if e.node_type == "normal" then
-- 		print("id-->" .. e[".name"])
-- 		print("remarks-->" .. e["remark"])
-- 		coroutine_list[index]={}
-- 		coroutine_list[index].co=coroutine.create(urltest_node)
-- 		coroutine_list[index].id=e[".name"]
-- 		index=index+1
-- 	end
-- end

-- print("正在获取测试节点可用性...")
-- for _, coroutine_item in pairs(coroutine_list) do
-- 	coroutine.resume(coroutine_item.co, coroutine_item.id)
-- end

luci.sys.call("sort -n /root/latency.txt | awk '{print $2}' >/root/latency.bck")
local id_file=io.open('/root/latency.bck','r')
index=1
for id in id_file:lines() do
	if(index==1) then
		print("正在设置主节点...")
		set_node('tcp',id)
		set_node('udp',id)
	elseif(index<=5) then
		print("正在设置备用节点...")
		luci.sys.call(string.format("uci -q del_list passwall.@auto_switch[0].tcp_node='%s' && uci -q add_list passwall.@auto_switch[0].tcp_node='%s'", id, id))
	else
		break
	end
end
print("更新完成！")