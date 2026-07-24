# cc-switch（二开品牌层）

基于 [cc-switch](https://github.com/farion1231/cc-switch) 上游的品牌定制层。设计与 open-code
二开同构：submodule 锁干净上游 tag，定制全在 `brand/patches/*.patch`，CI 出包时按 NN 序
strict 重放补丁后 `pnpm tauri build`（minisign 签名产 `.sig`）。

## 分发托管（Cloudflare R2）

产物 + 组装后的 `latest.json` 双写到 Cloudflare R2 `dl.dokng.com/cc-switch/`。补丁 01 已把
Tauri updater endpoint 指到 `https://dl.dokng.com/cc-switch/latest.json`，故 R2 是唯一自更新源
（GitHub Release 仅作存档 / 手动下载回退）。

**渐进增强**：未配置 R2 Secret（`R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`
/ `R2_BUCKET`）时，CI 的 R2 上传步骤自动跳过，GitHub Release 发布不受影响。

### R2 目录布局

产物按「产品名 / 版本子目录」组织，元数据留在产品根（固定 URL、供 updater 轮询），
安装包下沉到 `<version>/` 子目录（URL 每版唯一）。与 open-code 同构：

```
dl.dokng.com/
└── cc-switch/                      ← 产品根（updater endpoint 指向此处）
    ├── latest.json                 ← Tauri 更新元数据，固定 URL、每版覆盖
    │                                 → no-cache（禁 CDN 缓存，否则客户端拉不到新版）
    └── <version>/                  ← 版本子目录，形如 3.17.0-ccs.4（去 v 前缀的 tag）
        ├── *.dmg / *.msi / *.AppImage / *.tar.gz   ┐ 文件名带版本、URL 唯一
        └── *.sig                                   ┘ → immutable（长缓存）
```

要点：

- `latest.json` 里的产物 `url` 是**绝对地址**，组装时前缀为 `<base_url>/<version>/`
  （`release.yml` 的组装步骤：`url="$base_url/$REL_VERSION/$fname"`）。
- 版本子目录名 = 去 v 前缀的 tag（品牌发布号 `3.17.0-ccs.N`），与 R2 清理逻辑抽取的
  `-ccs.N` token 一致。注意这**不同于**安装包文件名内嵌的 `APP_VERSION`（纯数字
  `3.17.0-N`，因 MSI 第 4 段不接受字母），两者独立、互不影响。
- 元数据禁缓存、安装包/`.sig` immutable 长缓存，由 `release.yml` 的 R2 双写步骤分别设置
  `cache-control`。
- CI 只保留最近 3 个版本子目录（按 `-ccs.N` token 排序清理），根下 `latest.json` 永远保留。

## 平台范围（本期）

Windows x64 / Linux x64 / macOS universal。不含 Win ARM64 / Linux ARM64（ARM runner 有额外
成本）；不做 Apple 公证 / Windows 代码签名（需付费证书）——用户首次安装会有系统安全警告，
但 minisign 更新签名照做，自更新链路完整。

`TAURI_SIGNING_PRIVATE_KEY`（minisign 私钥，与补丁 01 的 pubkey 配对）为必需 Secret；缺失则
产物无 `.sig`、客户端验签失败、自更新废掉，故设为硬失败。
