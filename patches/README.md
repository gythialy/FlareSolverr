# FlareSolverr JSON-POST 支持（`contentType: "json"`）

给 FlareSolverr 增加 `contentType: "json"` 模式：`request.post` 在浏览器内用 `fetch()` 发请求，
带真实浏览器 TLS 指纹 + 自定义头，同源 POST 到 JSON / GraphQL 端点。

> 这份改动**已经直接提交在 `src/` 里**，Dockerfile 构建时不再打补丁。
> 本目录只保留「把同一份改动热补到上游官方镜像」的派生方法，不再提交 `.patch` 文件。

## 背景

Jellyfin 插件（NetworkStrike3 网络）的 GraphQL API `https://<site>.com/graphql` 使用 Cloudflare 反爬。

实测结论：

- 普通 HTTP 客户端（curl / .NET HttpClient）会被 Cloudflare 直接拦截（"Just a moment..." 403），因为拦截依据是 TLS 指纹 + 无浏览器 JS 环境，而不是 cookie。**因此 FlareSolverrSharp 的 ClearanceHandler（拿 cookie 后重放）对本站无效** —— 浏览器会话根本不会被发挑战，也就不会产生 `cf_clearance`。
- 只有真实浏览器指纹才能通过。FlareSolverr 的浏览器可以过，但 FlareSolverr 原生 `request.post` 会把 postData 拼成 HTML 表单以 `application/x-www-form-urlencoded` 提交，且不携带自定义头 —— GraphQL/Apollo 后端直接以 CSRF 拦截拒绝（`apollo-require-preflight` / `x-apollo-operation-name` 头也无法发送）。

## 代码位置

- `src/dtos.py`：`V1RequestBase` 新增 `contentType: str`；`headers` 由废弃的 `list` 改为实际使用的 `dict`。
- `src/flaresolverr_service.py`：`request.post` 在 `contentType == "json"` 时走新的 `_post_request_json()`（先导航到目标 origin 拿 Cloudflare clearance，再用 `fetch()` 同源发请求），并把真实 HTTP 状态码 / 响应体回填到 `solution.status` / `solution.response`。

改动就在树上，所以 `grep contentType src/`、IDE 跳转、`git blame`、`py_compile` 都能直接看到它；
上游同步按常规 `git fetch upstream && git rebase upstream/master` 处理，命中同一区域时解冲突即可。

## 热补丁上游官方镜像（按需生成）

目标：不重建镜像，直接给官方 `flaresolverr/flaresolverr` 容器打上同一份改动。

```bash
# 1) 从 fork 与上游的差异生成 p0 补丁（剥掉 src/ 前缀，配合作业目录 /app）
cd /path/to/FlareSolverr
git diff --no-prefix upstream/master -- src/ \
  | sed -E 's#^(---|\+\+\+) src/#\1 #' > /tmp/flaresolverr-json-post.patch

# 2) 打进容器并校验（--fuzz=0：上下文漂移时明确失败，而不是静默错位）
docker cp /tmp/flaresolverr-json-post.patch flaresolverr:/tmp/fs.patch
docker exec flaresolverr sh -c '
  cd /app &&
  patch -p0 --batch --fuzz=0 < /tmp/fs.patch &&
  test ! -e dtos.py.rej && test ! -e flaresolverr_service.py.rej &&
  python3 -m py_compile dtos.py flaresolverr_service.py'
docker restart flaresolverr
```

注意：

- 容器里的 `/app` 就是仓库 `src/` 的内容，所以补丁必须按裸文件名应用（`-p0`）。生成步骤已经用 `sed` 剥掉了 `src/`。
- 必须带 `--fuzz=0`：GNU patch 默认允许 2 行上下文模糊匹配，上游改了补丁附近的代码时照样 "成功"，可能改动落到错误位置且没有 `.rej`。关掉 fuzz 后同类漂移会直接非 0 退出。
- 目标容器版本要与本 fork 的 `upstream/master` 基线一致（当前 FlareSolverr v3.5.2 线）。版本不一致时补丁会被拒绝，此时以官方镜像版本为准，用本仓库同名函数对照改一版再生成。
- 补丁建议只用于应急/临时验证；正式部署仍用本仓库 CI 构建的镜像（`release-docker.yml` 在 master push 时构建并入 GHCR）。

## 请求示例

```json
POST http://localhost:8191/v1
{
  "cmd": "request.post",
  "url": "https://www.deeper.com/graphql",
  "postData": "{\"operationName\":\"getSearchResults\",\"query\":\"...\",\"variables\":{...}}",
  "contentType": "json",
  "headers": {
    "Accept": "application/json",
    "apollo-require-preflight": "true",
    "x-apollo-operation-name": "getSearchResults"
  },
  "session": "phoenix-adult-strike3",
  "maxTimeout": 120000
}
```

响应中 `solution.status` 为真实 HTTP 状态码，`solution.response` 为原始响应体（纯 JSON，直接 `JObject.Parse` 即可）。

## 插件侧依赖

插件（`NetworkStrike3.cs`）已实现对应调用：优先走 FlareSolverr JSON-POST（需用户配置 `FlareSolverrURL`，默认 `http://localhost:8191/`），FlareSolverr 不可用时回退直连（保留旧行为）。
