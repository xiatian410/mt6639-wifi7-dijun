# WebUI 四页布局（实现草稿）

继续使用 Miuix / Compose Wasm，不引入 HTML 仿制组件。未取得 OMK 截图或源码，因此这是独立布局，不宣称复刻 OMK。

## 信息结构
- 首页：无线概览、运行条件入口、热点开关、6GHz 开关和重新注册入口。
- 配置：SSID、带宽、密码；沿用 Presentation 的禁用条件。
- 诊断：运行条件、日志。
- 关于：模块版本、界面技术、仓库地址和许可说明；无设备状态也可进入。
- 底部四个文字标签带选中标记和 Tab 无障碍语义，内容区域预留底栏高度。
- 非首页显示全局执行进度；确认弹窗、错误提示、密码弹窗、日志弹层仍由根页面管理。

## 本轮范围
仅 ConsoleScreen.kt 和新增 Dashboard.kt；未改变 Controller、Presentation、Commands、bridge 或 shell。没有更新手机 webroot，没有发布到远端。

## 验证状态
- git diff --check 已通过。
- 当前执行环境 PATH 没有 Java / Gradle，尚未编译、运行 Compose 或截图验证。
- 现有 browser_check.mjs 仍基于原单页布局，需在完整构建环境更新导航步骤后再运行，不能视为新版回归通过。

## 发布前检查
1. 编译 Wasm production distribution，验证当前 Miuix 版本 Scaffold.bottomBar 接口。
2. 运行 commonTest，更新 browser_check.mjs：SSID、密码、带宽进入配置页，日志进入诊断页。
3. 360/393/720px、深浅色下检查底栏、键盘和弹窗遮挡。
4. 导航不发起控制命令；执行中跨页仍禁用写入控件并显示阶段。
5. 未加载、状态错误、demo、迁移阻塞、6GHz 恢复异常都不显示虚假的成功状态。
6. 验证切页返回、滚动归顶、无障碍 Tab 选中态和日志可达性。
