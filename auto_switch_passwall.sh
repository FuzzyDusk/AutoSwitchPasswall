#!/bin/bash
# 清空历史记录（不要空行）
echo -n "" > /root/latency.txt

# 先登录获取cookie存入/root/cookie.txt
echo "正在获取cookie..."
curl -X POST -F "luci_username=root" -F "luci_password=password" "http://localhost/cgi-bin/luci/" -c /root/cookie.txt

# 获取所有节点的id
echo "正在获取所有节点id..."
id_lines=$(curl -s "http://localhost/cgi-bin/luci/admin/services/passwall/node_list" -b /root/cookie.txt | \
grep "input type=\"button\" class=\"cbi-button\" value=\"可用性测试\"" | \
sed -e "s/<input type=\"button\" class=\"cbi-button\" value=\"可用性测试\" onclick=\"javascript:urltest_node('//g" -e "s/',this)\"//g")

# echo "${id_lines}"

# # 串行执行，但是OpenWrt的xargs没有-I选项
# echo "${ids}" | xargs -n1 -I{} curl "http://localhost/cgi-bin/luci/admin/services/passwall/urltest_node?id={}" -b /root/cookie.txt

# 不存在则创建命名管道
[ -e /tmp/$$.fifo ] || mkfifo /tmp/$$.fifo
# 将文件描述符3与管道关联，且可读可写
exec 3<>/tmp/$$.fifo
# 文件描述符已经具有管道特性，可以删除管道
rm -rf /tmp/$$.fifo

# 往管道中写入8行，表明并发数为8
for ((i=1;i<=8;i++))
do
    echo >&3
done

echo "正在获取测试节点可用性..."
for id_line in ${id_lines}
do
# 从管道中读一行
read -r -u3
{
    latency=$(curl -s "http://localhost/cgi-bin/luci/admin/services/passwall/urltest_node?id=${id_line}" -b /root/cookie.txt)
    if [[ "${latency}" =~ "use_time" ]]; then
        latency=$(echo "${latency}" | jq .use_time | sed 's/\"//g' | awk '{printf "%.2f",$0}')
    else
        # 给一个很大的值表示超时，方面后面排序
        latency=1000000000
    fi
    echo "${id_line} ${latency}"
    # 注意OpenWrt里面的sort命令没有-k选项，只支持按第一列排序，当然也可以自己编译OpenWrt源码让命令选项更全
    echo "${latency} ${id_line}" >> /root/latency.txt
    echo >&3
}&
done
wait

exec 3<&-   # 关闭文件描述符的读
exec 3>&-   # 关闭文件描述符的写

# 先grep得到token所在的行再用sed得到token然后用awk去除空格（这里很奇怪的是token写在一个hidden的input标签里）
echo "正在获取token..."
token=$(curl -s "http://localhost/cgi-bin/luci/admin/services/passwall/settings" -b /root/cookie.txt | \
grep -E 'input type="hidden" name="token" value=(.+)/' | \
sed -e 's/<input type=\"hidden" name=\"token" value=\"//g' -e 's/" \/>//g' | \
awk '{gsub(/ /,"")}1')

id_lines=$(sort -n /root/latency.txt | awk '{print $2}')
i=0
id_selected=()
for id_line in ${id_lines}
do
    id_selected[i]=${id_line}
    # 只选5个节点
    if [ $i -ge 5 ]; then
        break
    fi
    i=$((i + 1))
done

# 第一个作为主节点，其余四个作为备用节点以后自动切换
echo "正在设置主节点..."
curl -s -X POST \
-F "token=${token}" \
-F "cbi.submit=1" \
-F "tab.passwall.cfg013fd6=Main" \
-F "cbid.passwall.cfg013fd6.tcp_proxy_mode=chnroute" \
-F "cbid.passwall.cfg013fd6.udp_proxy_mode=chnroute" \
-F "cbid.passwall.cfg013fd6.localhost_tcp_proxy_mode=default" \
-F "cbid.passwall.cfg013fd6.localhost_udp_proxy_mode=default" \
-F "cbi.cbe.passwall.cfg013fd6.close_log_tcp=1" \
-F "cbi.cbe.passwall.cfg013fd6.close_log_udp=1" \
-F "cbid.passwall.cfg013fd6.loglevel=error" \
-F "cbid.passwall.cfg013fd6.trojan_loglevel=4" \
-F "cbi.cbe.passwall.cfg013fd6.enabled=1" \
-F "cbid.passwall.cfg013fd6.enabled=1" \
-F "cbid.passwall.cfg013fd6.tcp_node=${id_selected[0]}" \
-F "cbid.passwall.cfg013fd6.udp_node=${id_selected[0]}" \
-F "cbid.passwall.cfg013fd6.dns_shunt=dnsmasq" \
-F "cbi.cbe.passwall.cfg013fd6.filter_proxy_ipv6=1" \
-F "cbid.passwall.cfg013fd6.dns_mode=dns2tcp" \
-F "cbid.passwall.cfg013fd6.remote_dns=1.1.1.1" \
-F "cbi.cbe.passwall.cfg013fd6.chinadns_ng=1" \
-F "cbi.cbe.passwall.cfg013fd6.socks_enabled=1" \
-F "cbi.apply=保存&应用" \
"http://localhost/cgi-bin/luci/admin/services/passwall/settings" \
-b /root/cookie.txt >/dev/null

echo "正在设置备用节点..."
curl -s -X POST \
-F "token=${token}" \
-F "cbi.submit=1" \
-F "cbi.cbe.passwall.cfg0909ef.enable=1" \
-F "cbid.passwall.cfg0909ef.enable=1" \
-F "cbid.passwall.cfg0909ef.testing_time=1" \
-F "cbid.passwall.cfg0909ef.connect_timeout=3" \
-F "cbid.passwall.cfg0909ef.retry_num=3" \
-F "cbid.passwall.cfg0909ef.tcp_node=${id_selected[1]}" \
-F "cbid.passwall.cfg0909ef.tcp_node=${id_selected[2]}" \
-F "cbid.passwall.cfg0909ef.tcp_node=${id_selected[3]}" \
-F "cbid.passwall.cfg0909ef.tcp_node=${id_selected[4]}" \
-F "cbi.cbe.passwall.cfg0909ef.restore_switch=1" \
-F "cbid.passwall.cfg0909ef.restore_switch=1" \
-F "cbid.passwall.cfg0909ef.shunt_logic=1" \
-F "cbi.apply=保存&应用" \
"http://localhost/cgi-bin/luci/admin/services/passwall/auto_switch" \
-b /root/cookie.txt >/dev/null
echo "更新完成！"