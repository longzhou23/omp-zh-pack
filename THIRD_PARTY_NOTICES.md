# 第三方归属与再分发声明

本项目是 OMP 的非官方简体中文终端界面汉化包，不代表或替代上游项目。

- OMP / Oh My Pi：<https://github.com/can1357/oh-my-pi>，上游 `v18.8.6`，提交 `f068751e2f1dbdbc195977776d47a26db8697495`。
- OMP 顶层许可证为 MIT，版权声明见本仓库 `LICENSE`。
- 独立程序使用 Bun 运行时：<https://github.com/oven-sh/bun>；初始发布构建使用 Bun `1.3.14`。
- Bun `1.3.14` 的原始授权说明见 `BUN-LICENSE.md`，来自 <https://github.com/oven-sh/bun/blob/bun-v1.3.14/LICENSE.md>。Bun 自身使用 MIT，但静态链接的 JavaScriptCore/WebKit 等依赖另有 LGPL 等许可证，不因本项目的 MIT 许可证而改变。
- 原生模块、内嵌资源及依赖的完整授权声明保留在 `THIRD-PARTY-NOTICES.txt`，原样来自该上游提交，随二进制发布包一并分发。该文件并不替代各依赖的许可证。

可从锁定的公开上游源码与本仓库补丁获得对应源码。汉化修改不授予 OMP、Bun、字体、模型、提供商品牌或其他第三方标识的商标使用权。

## 对应源码和重新链接

OMP 的对应源码为上述锁定提交加本仓库补丁；Bun 的对应源码为 <https://github.com/oven-sh/bun/tree/bun-v1.3.14>，其补丁版 WebKit 位于 <https://github.com/oven-sh/webkit>，具体构建依赖版本由该 Bun 标签的构建配置确定。请按 Bun 的授权说明和构建文档生成修改后的运行时，再使用 `BUN_COMPILE_EXECUTABLE_PATH=/绝对路径/修改后的/bun bash build.sh` 重新生成本应用的独立程序。应用源码和锁定依赖公开提供，不要求使用此仓库发布的原始运行时二进制。

