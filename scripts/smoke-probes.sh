# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# Reactive Resume：sso=oidc（Better Auth custom provider），应用自己管会话，网关的登录跳转在
# 登录页的按钮那里停住（要人点），所以探针自己把 OIDC 链走完：
#   核心会话 → 应用 POST /api/auth/sign-in/social 拿 authorize 地址 → 带着核心会话跟完
#   Hydra → 应用回调（code 换会话，Cookie 落在 $SMOKE_JAR）→ get-session 断言账号。
# 工具接口（mcp）没声明：应用的 API 密钥只能由登录后的浏览器生成，核心的 MCP 头引用不了
# input 密钥（安装时就报错），见 PR 的「底座的问题」。
#
# 变量：SMOKE_WEB_URL 是应用的网页入口（套件已去尾斜杠，带 webui.path=/auth）；
#       拼 API 路径用 SMOKE_WEB_ORIGIN（只有 scheme://host:port），别直接接在 SMOKE_WEB_URL 后面。

web_assert() { grep -qi 'reactive resume'; }   # 登录页和登录后的页面都带着应用名

_rr_curl() { # <方法> <完整地址> [curl 参数…]：带会话 jar 请求插件网页，输出响应体
  local method="$1" url="$2"
  shift 2
  curl -sS --noproxy '*' -m "${SMOKE_WEB_MAX_TIME:-120}" -X "$method" -b "${SMOKE_JAR:?}" -c "${SMOKE_JAR:?}" "$@" "$url"
}

_rr_app_login() { # 建核心会话，再把 OIDC 链走完，$SMOKE_JAR 里落上应用自己的会话
  local base="${SMOKE_BASE:?}" resp url final code
  base="${base%/}"
  # 核心会话：先在核心地址上换令牌，再走一次插件入口，让网关的会话 Cookie 落到插件主机上。
  curl -sS --noproxy '*' -m "${SMOKE_WEB_MAX_TIME:-120}" -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$base/_wonton/login" || { echo "核心登录失败"; return 1; }
  curl -sS --noproxy '*' -m "${SMOKE_WEB_MAX_TIME:-120}" -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "${SMOKE_WEB_URL%/}/" || { echo "插件入口跳转失败"; return 1; }
  # 应用的登录页要人点按钮，探针替它点：POST sign-in/social 拿 authorize 地址。
  resp="$(_rr_curl POST "$SMOKE_WEB_ORIGIN/api/auth/sign-in/social" \
    -H 'Content-Type: application/json' --data '{"provider":"custom","callbackURL":"/dashboard"}')" ||
    { echo "sign-in/social 失败"; return 1; }
  url="$(jq -r '.url // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$url" && "$url" != null ]] || { echo "sign-in/social 没给跳转地址：$(head -c 200 <<<"$resp")"; return 1; }
  [[ "$url" == /* ]] && url="$SMOKE_WEB_ORIGIN$url"
  # 带核心会话跟 Hydra 和应用回调，最后落在应用里（或登录错误页）。
  final="$(_rr_curl GET "$url" -H 'Accept: text/html' -L -o /dev/null -w '%{url_effective}')" ||
    { echo "OIDC 链走不通：$url"; return 1; }
  case "$final" in
    */auth/error* | */auth/login*) echo "OIDC 回调后停在 $final"; return 1 ;;
  esac
  code="$(curl -sS --noproxy '*' -m "${SMOKE_WEB_MAX_TIME:-120}" -o /dev/null -w '%{http_code}' -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    "$SMOKE_WEB_ORIGIN/api/auth/get-session")"
  [[ "$code" == 200 ]] || { echo "get-session 返回 $code：应用的会话没建立"; return 1; }
}

identity_check() { # OIDC 建的账号要用主人的用户名和邮箱，说明网关注入的身份在应用里生效
  local me
  _rr_app_login || return 1
  me="$(_rr_curl GET "$SMOKE_WEB_ORIGIN/api/auth/get-session")" || { echo "get-session 失败"; return 1; }
  jq -e --arg u "${SMOKE_OWNER:-}" --arg e "${SMOKE_OWNER_EMAIL:-}" \
    '.user.username == $u and .user.email == $e' <<<"$me" >/dev/null 2>&1 ||
    { echo "应用的账号不是主人（$SMOKE_OWNER / $SMOKE_OWNER_EMAIL）：$(head -c 300 <<<"$me")"; return 1; }
}

# ---------- 数据钩子（e2e 六项冒烟用）----------
# 简历存 PostgreSQL，随数据目录保留：data_write 建一份带随机标记的简历，data_check 读回名字。
# OIDC 的会话 Cookie 在重装后还在（库没动），但每次现登录更省心：_rr_app_login 幂等。

marker_file() { # SMOKE_STATE 是文件不是目录，标记放同名的 .d 目录里
  local d="${SMOKE_STATE:-${TMPDIR:-/tmp}}.d"
  mkdir -p "$d" && printf '%s' "$d/resume"
}

_rr_create_resume() { # <名字>：经应用自己的 REST 建一份简历，输出 id
  local resp id
  resp="$(_rr_curl POST "$SMOKE_WEB_ORIGIN/api/openapi/resumes" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg n "$1" '{name:$n}')")" || { echo "建简历失败"; return 1; }
  id="$(jq -r 'if type == "string" then . else (.id // .output // empty) end' <<<"$resp" 2>/dev/null)"
  [[ -n "$id" && "$id" != null ]] || { echo "建简历没返回 id：$(head -c 300 <<<"$resp")"; return 1; }
  printf '%s' "$id"
}

_rr_list_resumes() { _rr_curl GET "$SMOKE_WEB_ORIGIN/api/openapi/resumes"; }

data_write() {
  local marker id
  _rr_app_login || { echo "登录不了应用"; return 1; }
  marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  id="$(_rr_create_resume "$marker")" || return 1
  { printf '%s\n' "$id"; printf '%s\n' "$marker"; } >"$(marker_file)"
}

data_check() {
  local id marker list
  {
    read -r id
    read -r marker
  } <"$(marker_file)" 2>/dev/null
  [[ -n "${id:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  _rr_app_login || { echo "登录不了应用"; return 1; }
  list="$(_rr_list_resumes)" || { echo "列不出简历：$list"; return 1; }
  jq -e --arg id "$id" --arg n "$marker" \
    'any(.[]?; .id == $id and .name == $n)' <<<"$list" >/dev/null 2>&1 ||
    { echo "找不到 $marker（$id），看到的是：$(head -c 300 <<<"$list")"; return 1; }
}
