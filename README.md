
# NAS Reader — 私有云电子书阅读与同步系统

面向 NAS / 私有服务器用户的电子书阅读方案。前后端分离：移动端 Flutter，后端 Go (Gin) + SQLite。

直接浏览 NAS 挂载目录，流式读取并缓存 **TXT** / **EPUB** / **MOBI** / **PDF** 书籍，跨设备同步阅读进度与书签，支持局域网直连、多套排版与阅读主题，以及内置网络诊断浮窗。

---

## ✨ 核心特性

### 阅读体验

* **TXT 全文排版引擎**：预分页 + 流式加载，大文件低内存占用。
* **EPUB 原生重排**：基于本地化的 `epub.js` + `jszip`（打包进 assets，离线可用且规避 CDN 供应链风险），保留章节结构与插图。
* **MOBI / AZW / AZW3 / KF8 支持**：打开时经 `kindle_unpack` 解包并转换为 EPUB（后台 isolate 执行，结果按书籍指纹缓存），复用 EPUB 渲染管线；加密 DRM 文件无法解析。
* **PDF 原生渲染**：基于 `flutter_pdfview`（Android `PdfRenderer` / iOS `PDFKit`），保留原始版式。
* **跟手翻页动效**：自研 `PageTurnView`，拖拽跟手、松手回弹。
* **手势热区定制**：常规手势 / 单手模式，九宫格热区可配置。
* **排版设置**：字号、行高、字间距、段首缩进（中文全角双空格）、自定义字体导入。
* **四套阅读主题**：羊皮纸 / 护眼 / 暗黑 / 纯白。
* **应用主题**：Material 3，浅色 / 深色 / 跟随系统。

### 书库与同步

* **本地文件系统存储**：书库直接读取服务端挂载的本地目录（如 NAS 挂载点）。
* **NAS 目录直连**：递归浏览目录树，隐藏文件自动过滤，按扩展名识别 TXT / EPUB / MOBI / PDF。
* **文件指纹识别**：服务端为每个文件生成稳定 `book_id`，跨设备定位同一本书，不依赖文件路径，使用首尾哈希 + 体积计算。
* **进度同步**：百分比 + 定位符（TXT 字节偏移 / EPUB CFI），并记录来源设备。
* **书签双向同步**：LWW（Last-Write-Wins）合并策略 + 软删除标记，避免多端互相覆盖。
* **收藏夹云同步**：书架与 NAS 书库均可一键收藏，按账号绑定并跨设备同步；同样采用 LWW + 墓碑软删除（保留 30 天），离线可用、登录后自动合并，登出即清除本机副本。
* **云端记录批量清理**：删除本地书籍时可一并清除服务端进度、书签与收藏。
* **EPUB 封面提取**：本地解析并缓存封面用于书架展示。
* **本地缓存管理**：查看占用容量并一键清理。

### 安全与运维

* **JWT 鉴权**：`JWT_SECRET` 未设置或短于 32 字节时服务拒绝启动。
* **邀请码注册**：`REGISTRATION_INVITE_CODE` 留空即完全关闭注册接口；常量时间比对。
* **登录限流**：内存计数器，15 分钟内失败 5 次锁定 15 分钟；用户不存在时执行等时哈希比对，抵御用户名枚举。
* **路径穿越防护**：所有文件访问经 `SafeResolvePath` 校验，越界请求返回 403。
* **CORS 白名单**：默认拒绝全部浏览器跨域请求，仅放行 `CORS_ALLOWED_ORIGINS` 显式配置的来源（原生客户端不受影响）。
* **凭据安全存储**：Token 与服务器密码存于 `flutter_secure_storage`（Android 启用 EncryptedSharedPreferences），「记住密码」可关闭。
* **局域网直连与 Tailnet 配置**：服务器配置保存局域网 HTTP 地址，以及可选的 Tailnet `host:port` 目标；普通备用 HTTP 服务器地址不再支持。
* **网络诊断浮窗**：内存态 HTTP 抓包，真机无控制台时也能排查 4xx / 5xx。
* **自动化 CI/CD**：Git Tag 推送后自动构建签名 APK 与多架构 Docker 镜像。

---

## 🏗 技术栈

| 模块 | 技术选型 | 说明 |
| --- | --- | --- |
| 移动端 | Flutter 3.x / Dart 3 | 以 Android 为主，代码跨平台 |
| 网络 | Dio 5 | 拦截器、Token 自动附加、Range 断点下载 |
| 本地存储 | `shared_preferences` / `path_provider` | 书架数据、配置项、书籍沙盒 |
| 安全存储 | `flutter_secure_storage` | Token 与服务器密码 |
| EPUB 渲染 | `webview_flutter` + `shelf_static` + `archive` + `xml` | 本地静态服务托管解包后的 EPUB |
| MOBI 解包 | `kindle_unpack`（GPL-3.0） | MOBI/AZW/AZW3/KF8 → EPUB 纯 Dart 转换 |
| PDF 渲染 | `flutter_pdfview` | Android `PdfRenderer` / iOS `PDFKit` 原生视图 |
| 后端 | Go 1.22 / Gin 1.9 | 轻量 RESTful API |
| 存储后端 | 本地文件系统 | 读取服务端挂载的书库目录 |
| 数据库 | SQLite（`glebarez/sqlite`）/ GORM | 纯 Go 驱动无 CGO，WAL 模式 |
| 鉴权 | `golang-jwt/v5` + `bcrypt` | — |
| CI/CD | GitHub Actions | APK 签名构建 + `linux/amd64,linux/arm64` 镜像推送 ghcr.io |

---

## 🔌 API

统一前缀 `/api/v1`。除 `/health`、`/auth/register`、`/auth/login` 外均需 `Authorization: Bearer <token>`。

```text
/api/v1
├── GET  /health                    # 健康探针
├── /auth
│   ├── POST /register              # 注册，需邀请码；限流
│   ├── POST /login                 # 登录获取 JWT；限流
│   └── POST /password              # 修改密码（需登录态）
├── /files
│   ├── GET  /browse?path=/         # 浏览 NAS 目录，返回带 book_id 的节点
│   └── GET  /download?path=...     # 支持 Range 的文件下载
└── /sync
    ├── GET  /progress              # 全部书籍进度
    ├── GET  /progress/:book_id     # 单本进度
    ├── POST /progress              # 上报进度
    ├── GET  /bookmarks/:book_id    # 拉取书签
    ├── POST /bookmarks             # 书签双向合并（LWW）
    ├── GET  /favorites             # 拉取收藏夹
    ├── POST /favorites             # 收藏夹双向合并（LWW）
    └── POST /delete                # 批量清除书籍的进度、书签与收藏
```

---

## 📂 项目结构

```text
NasReader/
├── .github/workflows/
│   ├── build-frontend-apk.yml       # Tag 触发：签名 APK 构建 + Release 发布
│   └── build-backend-docker.yml     # Tag 触发：多架构镜像推送 ghcr.io
├── backend/
│   ├── config/database.go           # SQLite 连接、历史数据去重、AutoMigrate
│   ├── handlers/                    # auth / storage / progress / bookmark / favorite / delete
│   ├── middleware/                  # auth.go（JWT）、ratelimit.go（登录限流）
│   ├── models/                      # user / progress / bookmark / favorite
│   ├── storage/                     # 存储抽象层：backend 接口 / local / fingerprint
│   ├── utils/safe_path.go           # 路径穿越防护
│   ├── Dockerfile                   # 多阶段静态编译 → alpine
│   ├── docker-compose.yml
│   └── main.go                      # 路由注册与 CORS
└── frontend/
    ├── assets/js/                   # epub.min.js / jszip.min.js（本地化）
    ├── lib/
    │   ├── config/                  # api_config / theme_manager
    │   ├── core/                    # 排版引擎、翻页视图、字体、指纹、网络客户端、阅读主题、手势模式
│   │   ├── models/                  # bookmark_model / favorite_book
│   │   ├── pages/                   # 登录 / 本地书架 / NAS 浏览器 / 收藏夹 / 设置
│   │   ├── readers/                 # stream_txt_reader / epub_reader / pdf_reader
│   │   ├── services/                # 鉴权、进度同步、书签同步、收藏同步、服务器端点与档案、封面提取、MOBI 转换、日志
│   │   ├── widgets/                 # 阅读器抽屉、排版设置、手势热区、收藏按钮
    │   ├── main_navigation_container.dart
    │   └── main.dart
    ├── test/                        # 指纹、书签、收藏、服务器档案等单元测试
    └── pubspec.yaml
```

---

## 🚀 部署

### 后端

#### 环境变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `JWT_SECRET` | ✅ | JWT 签名密钥，至少 32 字节；缺失或过短时服务拒绝启动。生成：`openssl rand -base64 48` |
| `NAS_BOOKS_DIR` | 建议 | 书库物理根目录，默认 `/nas/books`；所有文件访问被限制在此目录内 |
| `UPLOADS_DIR` | — | 用户上传书籍目录，默认 `/app/uploads`（需可写） |
| `REGISTRATION_INVITE_CODE` | — | 注册邀请码。**留空则完全关闭注册接口**，建议长度 ≥ 8 |
| `CORS_ALLOWED_ORIGINS` | — | 逗号分隔的浏览器来源白名单；留空则拒绝所有跨域请求 |
| `GIN_MODE` | — | 生产环境设为 `release` |

数据库文件固定生成在工作目录下的 `data/reader.db`，容器部署需挂载该目录以持久化。

#### Docker Compose（推荐）

```bash
cd backend

cat > .env <<EOF
JWT_SECRET=$(openssl rand -base64 48)
REGISTRATION_INVITE_CODE=$(openssl rand -hex 12)
EOF

docker compose up -d
```

`docker-compose.yml` 默认将 `/volume1/Books` 只读挂载到容器内 `/nas/books`，按自己的 NAS 路径调整。也可直接使用 CI 推送的镜像：

```yaml
image: ghcr.io/<owner>/<repo>/reader-sync:latest
```

#### 本地运行

```bash
cd backend
export JWT_SECRET="$(openssl rand -base64 48)"
export NAS_BOOKS_DIR="/your/nas/books"
export REGISTRATION_INVITE_CODE="your-invite-code"
go mod download
go run main.go        # 监听 :8080
```

#### 测试

```bash
cd backend && go test ./...
```

### 前端

```bash
cd frontend
flutter pub get
flutter run                  # 调试
flutter test                 # 单元测试
flutter build apk --release --split-per-abi  # 本地打包（按 ABI 拆分）
```

拆分构建会在 `build/app/outputs/flutter-apk/` 下产出三个 APK：`app-arm64-v8a-release.apk`（现代手机，约 51MB）、`app-armeabi-v7a-release.apk`（32 位旧设备）、`app-x86_64-release.apk`（模拟器）。注意 Tailnet（tailscale）原生库仅提供 arm64-v8a，故仅该架构支持外网访问。

首次启动在登录页填写局域网服务器地址（如 `http://192.168.1.10:6088`）。如需为外网访问预先配置 Tailnet，可填写目标的 `host:port`（如 `nas.example.ts.net:6088`）；当前 Android 原生 `libtailscale` 转发层尚未接入，因此该字段暂不会提供外网访问。注册需要服务端配置的邀请码。

#### 自动发布

APK 签名依赖以下 GitHub Secrets：`KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`。

```bash
git tag v1.0.0
git push origin v1.0.0
```

Tag 推送后自动产出 `NasReader-<Tag>-<ABI>.apk`（按 ABI 拆分）并发布至 GitHub Releases，同时构建并推送后端多架构镜像。

---

## 📝 开源协议

本项目自有代码基于 [MIT License](LICENSE) 开源。

> ⚠️ 前端 MOBI 支持依赖 `kindle_unpack`（**GPL-3.0**）。该依赖的传染性会及于与其链接的前端构建产物，因此分发前端 APK 时须遵守 GPL-3.0 条款（提供对应源码等）。后端 Go 服务不引用该库，仍为纯 MIT。
