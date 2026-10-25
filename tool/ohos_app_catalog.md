# 鸿蒙应用包名目录

主数据是 `assets/data/ohos_app_catalog.json`，仅包含 `bundleName`（鸿蒙包名）和
`label`（应用名称），按包名排序。初始数据来自已连接设备的 HDC 实际查询。
目录不是目标设备的已安装清单；不同设备可能只安装了其中一部分应用。
Android 版本、应用分身及其他渠道版本的包名需要分别核实。

目前在当前仓库维护即可，数据修改可以和相关功能一起审查、发布。
以后有多个独立项目共同维护、需要独立发布数据版本时，再迁移到单独的数据仓库。

## Windows 和 macOS 更新

需要 Python 3.9+、DevEco SDK 中的 HDC，以及已开启 USB 调试并授权本机的鸿蒙手机或平板。
脚本只使用 Python 标准库，不需要安装第三方 Python 包。
电脑运行 Windows 或 macOS，采集对象均为连接的鸿蒙设备。

Windows PowerShell，在项目根目录执行：

```powershell
python tool/update_ohos_app_catalog.py --hdc "D:\Java\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
```

macOS Terminal，在项目根目录执行，HDC 路径以实际 SDK 安装位置为准：

```sh
python3 tool/update_ohos_app_catalog.py --hdc "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
```

如果 `hdc` 已在 `PATH` 中，两者都可以省略 `--hdc`：

```sh
python3 tool/update_ohos_app_catalog.py
```

脚本也支持 `HDC_PATH` 指定可执行文件，或者从 `DEVECO_SDK_HOME`、
`HARMONYOS_SDK_HOME`、`OHOS_SDK_HOME` 指定的 SDK 目录寻找 HDC。
连接多台设备时，使用 `--device <设备ID>` 选择目标，设备ID可通过 `hdc list targets` 查询。

## 更新行为

- 使用官方命令 `hdc -t <设备ID> shell bm dump -a -l` 批量查询名称和包名，
  再用 `bm dump -a` 补齐未返回名称的条目，需要 API 20+。
- 默认按包名合并：加入新应用，更新已知名称，保留其他设备曾采集的应用。
- 查询不到名称时使用包名；已有可读名称不会被这个回退值覆盖。
- 不采集 UID、设备ID、账号、签名、安装路径或采集时间。
- 数据未变化时不重写文件；无设备、多设备未选择、超时、空数据或无效数据时返回错误。
- 目录先完整解析，再通过临时文件替换；失败的查询不会覆盖现有目录。
- 删除过期条目需人工确认后编辑 JSON，某一台设备没有安装不代表应从公共目录删除。

可选生成 CSV 便于查看：

```sh
python3 tool/update_ohos_app_catalog.py --csv .dart_tool/ohos-apps.csv
```

默认只维护一份 JSON 主数据，CSV 保留为本地导出，避免两份数据不同步。
也可以导入以前保存的 HDC JSON，不需要连接设备：

```sh
python3 tool/update_ohos_app_catalog.py --input /path/to/hdc-apps.json
```

更新后检查 `git diff -- assets/data/ohos_app_catalog.json`，再提交数据变化。
脚本不会执行 git 提交或推送，也不会安装、卸载应用或修改 VPN 配置。
目录被 `pubspec.yaml` 的 `assets/data/` 资产声明覆盖；应用如何展示和选择目录项由应用代码负责。

## 验证

```sh
python3 -m unittest discover -s tool -p test_update_ohos_app_catalog.py -v
```

官方命令参考：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/bm-tool>
