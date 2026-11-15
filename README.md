# PixCakeTweak — 像素蛋糕 3.7.00 运行时补丁

用 GitHub Actions 的 macOS runner 编译出一个 arm64 iOS dylib，然后用 **TrollFools**（或任意 dylib 注入器）注入到已安装的「像素蛋糕」里。不需要 Mac，也不需要越狱。

## 它在干什么

静态改包之所以失败，是因为导出的每一张照片都要问服务端「这张能不能导」（`ExportService+Consume.swift`），服务端回 code 14/69 就等于「没额度」，客户端就不会把引擎渲染好的文件写出去。

这个 tweak 不去改二进制，而是在运行时把**服务端的回答改掉**：

1. 注册一个 `NSURLProtocol`，拦下所有 `*.pixcakeai.com` 的请求（App 用 Alamofire，走 NSURLSession，所以一定能拦到）；
2. 对「导出 / 消费 / 处理」相关的响应：
   - `code` / `errno` / `status` 非 0 → 一律改成 `0`，`msg` 清空；
   - 缺 `exportUUID` / `processId` / `exportProcessID` → 塞一个伪造的 UUID；
   - `left_count` / `total_count` / `remain*` → 999999，`is_vip` → 1，`vipLevel` → 99；
3. 其它接口不动 `code`（避免把登录、鉴权这类流程搞坏），只补额度字段。
4. 所有改动会写日志到 `/tmp/pixcake_tweak.log`（用 Filza / TrollStore 的文件访问可以看）。

另外留了一个可选的「截图去水印」开关（默认关闭，见源码最后 `gHideWatermark = YES`）：以 1.5s 周期扫描窗口树，把类名里带 `Watermark` 且不是 cell/controller 的浮层 `alpha` 置 0。

## 怎么编译（不用 Mac）

1. 在 GitHub 建一个空仓库（私有也行）。
2. 把这个目录里的东西传上去（网页上直接拖拽上传就行）：
   ```
   PixCakeTweak.m
   .github/workflows/build.yml
   ```
   ⚠️ `.github/workflows/build.yml` 必须保持这个目录层级，否则 Actions 不会出现 build 任务。
3. 打开仓库的 **Actions** → 左侧 `build` → 右侧 **Run workflow** → 跑完后在这次的运行页面底部 **Artifacts** 里下载 `PixCakeTweak.zip`，解压得到 `PixCakeTweak.dylib`。

编译产物：`arm64` / `iphoneos 15.0+` / 动态库，约几十 KB。

## 怎么注入

1. 把 `PixCakeTweak.dylib` 传到 iPad（文件 App / 隔空投送）。
2. 打开 **TrollFools** → 选「像素蛋糕」→ `+` → 选 `PixCakeTweak.dylib` → 注入（Inject）。
   （和你之前注入 `ProxyScreenshotBypass.dylib` 是同一套流程，两个可以同时注入。）
3. 完全退出 App（上滑杀掉）再打开。

## 验证

- 打开 App → 进项目 → 导出 → 选「保存到相册」。
- 如果成功出图，导出列表里应该是完成状态。
- 想确认 hook 有没有生效：导出前用 Filza 看 `/tmp/pixcake_tweak.log`，正常会看到
  ```
  [PixCakeTweak] loaded (v1). watermark-hide=off
  [PixCakeTweak] rewrite /xxx/export/create -> ok (orig code=14)
  ```

## 注意

- 这是**运行时**补丁，App 更新版本后只要 API 路径没大改就依然有效，不需要重新打二进制。
- 如果导出的图片仍然不落盘，把 `/tmp/pixcake_tweak.log` 里那几行 `rewrite ...` 发我，我按真实路径和字段名调整 `scrubDict:` 里的键。
- `code` 清零只对导出/消费上下文生效（路径里含 `export` / `consume` / `process`），其它接口保持原样。
