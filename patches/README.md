# FlareSolverr JSON-POST Patch

## 背景

Jellyfin 插件中的 NetworkStrike3 网络）的 GraphQL API `https://<site>.com/graphql` 使用 Cloudflare 反爬。

实测结论：

- 普通 HTTP 客户端（curl / .NET HttpClient）会被 Cloudflare 直接拦截（"Just a moment..." 403），因为拦截依据是 TLS 指纹 + 无浏览器 JS 环境，而不是 cookie。**因此 FlareSolverrSharp 的 ClearanceHandler（拿 cookie 后重放）对本站无效** —— 浏览器会话根本不会被发挑战，也就不会产生 `cf_clearance`。
- 只有真实浏览器指纹才能通过。FlareSolverr 的浏览器可以过，但 FlareSolverr 原生 `request.post` 会把 postData 拼成 HTML 表单以 `application/x-www-form-urlencoded` 提交，且不携带自定义头 —— GraphQL/Apollo 后端直接以 CSRF 拦截拒绝（`apollo-require-preflight` / `x-apollo-operation-name` 头也无法发送）。

## 解决方式

给 FlareSolverr 增加 `contentType: "json"` 模式：请求经浏览器内 `fetch()` 发出，走真实浏览器指纹 + 自定义头，同源 POST 到 GraphQL 端点。

## 用法

对 FlareSolverr v3.5.0（docker 镜像 `flaresolverr/flaresolverr:latest`）：

```bash
docker cp patches/flaresolverr-v3.5.0-json-post.patch flaresolverr:/tmp/fs.patch
docker exec flaresolverr sh -c "cd /app && patch -p1 < /tmp/fs.patch && python3 -m py_compile flaresolverr_service.py dtos.py"
docker restart flaresolverr
```

或构建镜像时应用：

```dockerfile
COPY patches/flaresolverr-v3.5.0-json-post.patch /tmp/fs.patch
RUN cd /app && patch -p1 < /tmp/fs.patch
```

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
