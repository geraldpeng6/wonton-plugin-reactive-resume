# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 变量别叫 state：shellcheck 把这份文件连着 probes.sh 一起分析，probes.sh 自己也读一个 dev.sh 提供的 state；
# 子壳体函数（fn() ( … )）里给 state 赋值，SC2031 就报在 probes.sh 上，CI 红。
#
# 变量：SMOKE_WEB_URL 是应用的网页入口（套件已去尾斜杠，但可能带路径，比如 SSO 登录页）；
#       拼 API 路径用 SMOKE_WEB_ORIGIN（只有 scheme://host:port，入口的路径不掺进来），别直接接在 SMOKE_WEB_URL 后面。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 只证明身份：用应用自己的“当前用户”接口断言认出的是用户管理员，不碰应用里的数据。
#       数据断言（是否配置过、有几条、内容对不对）全部交给 data_write / data_check：冒烟第 1 项会先装升级
#       起点写数据，身份探针再断言“数据目录是空的”就会红。接口回字段时也只看类型（如 configured 是布尔、
#       nodes 是数字），值和条数留给 data_check。
#       没有用户体系时写 IDENTITY_NA=1，并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
#       SSO 登录跳转不用自己写表单逻辑：dweb --sso 会从清单 webui.path 的入口出发（没写就是 /），提交核心
#       登录页的 JS 自动表单并跟完重定向，返回的页面已带应用的登录态。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 通知房间：申请了 notify 的插件把通知交给核心，核心以核心账号发进和主人的“Wonton”私聊。
#       探针以主人身份读这个房间：probes_owner_room_wait <超时秒> <要找的文字> 等到开始之后发来的、包含这段文字的
#       消息就返回 0，超时列出看到的最新消息并返回非 0。要先把等待挂到后台再发通知，否则消息可能在等待开始前就到：
#         room_wait() {
#           local marker="probe-$RANDOM" url
#           url="$(docker exec "wonton-$SMOKE_INSTANCE--${SMOKE_PLUGIN_ID//./-}--web" printenv WONTON_NOTIFY_URL)"
#           probes_owner_room_wait 120 "$marker" & local pid=$!
#           docker exec "wonton-$SMOKE_INSTANCE--${SMOKE_PLUGIN_ID//./-}--web" wget -q -O /dev/null \
#             --header 'Content-Type: application/json' --post-data "{\"title\":\"$marker\"}" "$url"
#           wait "$pid"
#         }
#       上面的 web 换成插件里能发 HTTP 的服务；wget 换成那个服务里有的客户端。
# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：data_write 用随机标记写
#       一条数据并把标记原样存进 $SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
#       应用不存用户数据时写 DATA_NA=1（两项记 N/A）。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -q '你好'; }   # 示例页的标题

identity_check() { # 页面回显的就是网关注入的用户名；示例页不存数据，也不拿数据判断身份
  local page
  page="$(dweb /)" || { echo "页面失败：$page"; return 1; }
  grep -qF "你好，$SMOKE_OWNER" <<<"$page" || { echo "页面没回显用户 $SMOKE_OWNER：$(head -c 120 <<<"$page")"; return 1; }
}

# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：
#   data_write 用随机标记写一条数据，把标记原样覆盖写进 $SMOKE_STATE（一个已建好的空文件，不是目录）；data_check 读回标记、去应用里找，
#   找不到就打印看到了什么并返回非 0。
# 应用不存用户数据时写 DATA_NA=1（两项记 N/A）。模板的示例页不存数据，所以这里是不适用。
# 数据要写进插件容器时（Agent 插件的工作区标记等），容器名别自己拼：钩子契约里没有 SMOKE_SLUG，e2e 套件的
# data_write 又跑在实例名导出之前，拼出来的名字缺段（No such container）；Bot 服务（清单声明了 bots）每个 Bot
# 一组容器，名字还带 --<Bot 名> 后缀。按核心打的标签找，插件自带 smoke 和 e2e 套件两个运行环境都成立
# （实例名没导出时按 SMOKE_BASE 的主机名第一段推）：
#   _container() { # <插件 id> <服务名>：本实例里这个服务的容器
#     local inst="${SMOKE_INSTANCE:-}" args=(--filter "label=wonton.plugin=$1" --filter "label=wonton.service=$2")
#     if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
#       inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
#     fi
#     [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
#     docker ps --format '{{.Names}}' "${args[@]}" | head -1
#   }
export DATA_NA=1
