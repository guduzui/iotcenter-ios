#!/usr/bin/env python3
"""IoTCenter iOS 工程预检（Linux / macOS 通用，只依赖 Python 3 标准库）。

作用：在没有 Xcode 的机器上，尽可能提前发现会导致 archive/export 失败的工程问题，
包括 pbxproj 引用缺失、Info.plist 缺键、AppIcon 尺寸或透明通道不合规、
www 入口或入口引用的资源缺失、Swift 源文件未加入编译目标、大括号不配对等。

用法：
    python3 scripts/preflight.py            # 全量检查
    python3 scripts/preflight.py --no-www   # 跳过 www 资源扫描（CI 构建前用）
    python3 scripts/preflight.py --json     # 机器可读输出

退出码：0 = 没有 FAIL（可能有 WARN），1 = 存在 FAIL，2 = 脚本自身异常。
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import struct
import sys

def _find_project_root() -> str:
    """从脚本所在目录向上查找包含 IoTCenter.xcodeproj 的目录。"""
    current = os.path.dirname(os.path.abspath(__file__))
    for _ in range(5):
        if os.path.isdir(os.path.join(current, "IoTCenter.xcodeproj")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    raise SystemExit("找不到 IoTCenter.xcodeproj，请在工程目录内运行")


ROOT = _find_project_root()
PROJECT_DIR = os.path.join(ROOT, "IoTCenter.xcodeproj")
PBXPROJ = os.path.join(PROJECT_DIR, "project.pbxproj")

results: list[tuple[str, str, str]] = []  # (level, title, detail)


def add(level: str, title: str, detail: str = "") -> None:
    results.append((level, title, detail))


def ok(title: str, detail: str = "") -> None:
    add("PASS", title, detail)


def warn(title: str, detail: str = "") -> None:
    add("WARN", title, detail)


def fail(title: str, detail: str = "") -> None:
    add("FAIL", title, detail)


# ---------------------------------------------------------------------------
# 极简 OpenStep plist（project.pbxproj）解析
# ---------------------------------------------------------------------------


class _Parser:
    def __init__(self, text: str) -> None:
        # pbxproj 用 /* ... */ 做注释，解析前先去掉，避免干扰
        self.s = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        self.i = 0

    def skip_ws(self) -> None:
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def parse_dict(self) -> dict:
        self.skip_ws()
        assert self.s[self.i] == "{", "dict 起始符不是 {"
        self.i += 1
        out: dict = {}
        while True:
            self.skip_ws()
            if self.i >= len(self.s):
                raise ValueError("dict 未闭合")
            if self.s[self.i] == "}":
                self.i += 1
                return out
            key = self.parse_scalar()
            self.skip_ws()
            if self.s[self.i] != "=":
                raise ValueError(f"缺少 = （位置 {self.i}）")
            self.i += 1
            value = self.parse_value()
            self.skip_ws()
            if self.i < len(self.s) and self.s[self.i] == ";":
                self.i += 1
            out[key] = value

    def parse_value(self):
        self.skip_ws()
        c = self.s[self.i]
        if c == "{":
            return self.parse_dict()
        if c == "(":
            return self.parse_list()
        if c == '"':
            return self.parse_quoted()
        return self.parse_scalar()

    def parse_list(self) -> list:
        self.i += 1  # (
        out = []
        while True:
            self.skip_ws()
            if self.s[self.i] == ")":
                self.i += 1
                return out
            out.append(self.parse_value())
            self.skip_ws()
            if self.s[self.i] == ",":
                self.i += 1

    def parse_quoted(self) -> str:
        self.i += 1  # "
        buf = []
        while True:
            c = self.s[self.i]
            if c == "\\":
                nxt = self.s[self.i + 1]
                buf.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                return "".join(buf)
            buf.append(c)
            self.i += 1

    def parse_scalar(self) -> str:
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in " \t\r\n=;,}()":
            self.i += 1
        return self.s[start:self.i]


def parse_pbxproj(text: str) -> dict:
    objects: dict = {}
    for m in re.finditer(r"\n\t\t([0-9A-Za-z]{24})(?: /\*.*?\*/)? = ", text):
        start = m.end()
        if text[start] != "{":
            continue
        depth = 0
        j = start
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        objects[m.group(1)] = _Parser(text[start:j + 1]).parse_dict()
    return objects


def project_root_object(objects: dict) -> dict:
    for obj in objects.values():
        if obj.get("isa") == "PBXProject":
            return obj
    raise ValueError("project.pbxproj 中找不到 PBXProject")


def target_object(objects: dict) -> dict:
    for obj in objects.values():
        if obj.get("isa") == "PBXNativeTarget":
            return obj
    raise ValueError("project.pbxproj 中找不到 PBXNativeTarget")


def resolve_group_paths(objects: dict, project: dict) -> dict:
    """返回 {group_id: 相对工程目录的路径}。"""
    paths: dict = {}

    def walk(group_id: str, parent: str) -> None:
        group = objects.get(group_id)
        if not group:
            return
        path = group.get("path")
        source_tree = group.get("sourceTree", "<group>")
        if path:
            base = parent if source_tree == "<group>" else ""
            current = os.path.normpath(os.path.join(base, path))
        else:
            current = parent
        paths[group_id] = current
        for child in group.get("children", []) or []:
            if objects.get(child, {}).get("isa") in ("PBXGroup", "PBXVariantGroup"):
                walk(child, current)

    walk(project["mainGroup"], "")
    return paths


def resolve_file_ref(objects: dict, group_paths: dict, file_id: str) -> str | None:
    ref = objects.get(file_id)
    if not ref:
        return None
    path = ref.get("path")
    if not path:
        return None
    tree = ref.get("sourceTree", "<group>")
    if tree == "<group>":
        # 找到包含该 fileRef 的组
        for gid, gpath in group_paths.items():
            if file_id in (objects.get(gid, {}).get("children") or []):
                return os.path.normpath(os.path.join(gpath, path))
        return os.path.normpath(path)
    if tree == "SOURCE_ROOT":
        return os.path.normpath(path)
    return None  # BUILT_PRODUCTS_DIR / SDKROOT 等，不校验


# ---------------------------------------------------------------------------
# 检查项
# ---------------------------------------------------------------------------


def check_pbxproj(no_www: bool) -> dict:
    if not os.path.isfile(PBXPROJ):
        fail("project.pbxproj 存在", PBXPROJ)
        return {}
    text = open(PBXPROJ, encoding="utf-8", errors="replace").read()
    try:
        objects = parse_pbxproj(text)
    except Exception as exc:  # noqa: BLE001 - 需要把解析错误报给用户
        fail("project.pbxproj 可解析", str(exc))
        return {}
    ok("project.pbxproj 可解析", f"{len(objects)} 个对象")

    project = project_root_object(objects)
    target = target_object(objects)
    group_paths = resolve_group_paths(objects, project)

    # 1) 所有被引用的文件都必须真实存在
    missing: list[str] = []
    checked = 0
    for fid, ref in objects.items():
        if ref.get("isa") != "PBXFileReference":
            continue
        rel = resolve_file_ref(objects, group_paths, fid)
        if rel is None:
            continue
        checked += 1
        if not os.path.exists(os.path.join(ROOT, rel)):
            missing.append(rel)
    if missing:
        fail("工程引用的文件都存在", "缺失：" + ", ".join(sorted(missing)))
    else:
        ok("工程引用的文件都存在", f"校验 {checked} 个文件引用")

    # 2) BuildFile -> FileRef 引用完整
    broken = [
        f"{bid}:{obj.get('fileRef')}"
        for bid, obj in objects.items()
        if obj.get("isa") == "PBXBuildFile" and obj.get("fileRef") not in objects
    ]
    if broken:
        fail("PBXBuildFile 指向有效 fileRef", ", ".join(broken))
    else:
        ok("PBXBuildFile 指向有效 fileRef")

    # 3) Sources 阶段包含所有 Swift 源文件
    source_refs: set[str] = set()
    resources_refs: set[str] = set()
    for phase_id in target.get("buildPhases", []) or []:
        phase = objects.get(phase_id, {})
        if phase.get("isa") == "PBXSourcesBuildPhase":
            for bf in phase.get("files", []) or []:
                source_refs.add(objects.get(bf, {}).get("fileRef", ""))
        if phase.get("isa") == "PBXResourcesBuildPhase":
            for bf in phase.get("files", []) or []:
                resources_refs.add(objects.get(bf, {}).get("fileRef", ""))

    src_files = {
        os.path.relpath(os.path.join(ROOT, rel), ROOT)
        for fid in source_refs
        if (rel := resolve_file_ref(objects, group_paths, fid))
    }
    on_disk = {
        os.path.relpath(os.path.join(dp, f), ROOT)
        for dp, _, files in os.walk(os.path.join(ROOT, "IoTCenter"))
        for f in files
        if f.endswith(".swift")
    }
    not_compiled = sorted(on_disk - src_files)
    if not_compiled:
        fail("所有 Swift 源文件都已加入 Sources", "未加入编译：" + ", ".join(not_compiled))
    else:
        ok("所有 Swift 源文件都已加入 Sources", f"{len(src_files)} 个文件")

    # 4) Resources 阶段必须包含 www 目录引用和 Assets.xcassets
    res_paths = {
        resolve_file_ref(objects, group_paths, fid) for fid in resources_refs
    }
    www_ref = next((p for p in res_paths if p == "www"), None)
    assets_ref = next((p for p in res_paths if p and p.endswith("Assets.xcassets")), None)
    if www_ref:
        ok("www 目录已作为文件夹引用加入 Resources", "打包后位于 IoTCenter.app/www")
    else:
        fail("www 目录已加入 Resources", "缺少 www 文件夹引用，App 内将没有前端资源")
    if assets_ref:
        ok("Assets.xcassets 已加入 Resources")
    else:
        warn("Assets.xcassets 已加入 Resources", "未找到资源目录引用")

    # 5) 关键构建设置
    config_list_id = target.get("buildConfigurationList")
    config_list = objects.get(config_list_id, {}) if isinstance(config_list_id, str) else {}
    configs: dict = {}
    for cid in config_list.get("buildConfigurations", []) or []:
        cfg = objects.get(cid, {})
        configs[cfg.get("name", cid)] = cfg.get("buildSettings", {}) or {}
    settings = configs.get("Release") or next(iter(configs.values()), {})

    required = {
        "PRODUCT_BUNDLE_IDENTIFIER": "Bundle Identifier",
        "IPHONEOS_DEPLOYMENT_TARGET": "最低系统版本",
        "SWIFT_VERSION": "Swift 语言版本",
        "MARKETING_VERSION": "版本号",
        "CURRENT_PROJECT_VERSION": "构建号",
    }
    missing_keys = [v for k, v in required.items() if not settings.get(k)]
    if missing_keys:
        fail("Release 配置关键设置齐全", "缺少：" + ", ".join(missing_keys))
    else:
        ok(
            "Release 配置关键设置齐全",
            "bundle={} 版本={} 构建号={} 部署目标={} swift={}".format(
                settings["PRODUCT_BUNDLE_IDENTIFIER"],
                settings["MARKETING_VERSION"],
                settings["CURRENT_PROJECT_VERSION"],
                settings["IPHONEOS_DEPLOYMENT_TARGET"],
                settings["SWIFT_VERSION"],
            ),
        )

    infoplist = settings.get("INFOPLIST_FILE", "")
    if settings.get("GENERATE_INFOPLIST_FILE") == "NO" and infoplist:
        if os.path.isfile(os.path.join(ROOT, infoplist)):
            ok("INFOPLIST_FILE 指向存在的 Info.plist", infoplist)
        else:
            fail("INFOPLIST_FILE 指向存在的 Info.plist", infoplist)
    elif not infoplist:
        fail("INFOPLIST_FILE 已配置", "未设置 INFOPLIST_FILE 且未开启自动生成")
    else:
        warn("INFOPLIST_FILE 由 Xcode 自动生成", "手工维护的 Info.plist 可能未生效")

    return settings


def check_info_plist(settings: dict) -> None:
    rel = settings.get("INFOPLIST_FILE", "IoTCenter/Info.plist")
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        return
    try:
        with open(path, "rb") as fh:
            plist = plistlib.load(fh)
    except Exception as exc:  # noqa: BLE001
        fail("Info.plist 是合法 plist", str(exc))
        return
    ok("Info.plist 是合法 plist")

    required = [
        "CFBundleIdentifier",
        "CFBundleExecutable",
        "CFBundlePackageType",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSRequiresIPhoneOS",
        "UILaunchScreen",
        "UISupportedInterfaceOrientations",
    ]
    missing = [k for k in required if k not in plist]
    if missing:
        fail("Info.plist 必需键齐全", "缺少：" + ", ".join(missing))
    else:
        ok("Info.plist 必需键齐全")

    ats = plist.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoadsInWebContent"):
        ok("ATS 允许 WKWebView 加载 http 内容")
    elif ats.get("NSExceptionDomains"):
        ok("ATS 配置了例外域名", ", ".join(ats["NSExceptionDomains"].keys()))
    else:
        warn("ATS 未放行 http", "远端更新地址若为 http，WKWebView 请求会被拦截")

    if not plist.get("CFBundleDisplayName"):
        warn("缺少 CFBundleDisplayName", "桌面图标下会显示 CFBundleName（即 IoTCenter）")


def check_icons(settings: dict) -> None:
    icon_set_name = settings.get("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon")
    base = os.path.join(ROOT, "IoTCenter", "Assets.xcassets", f"{icon_set_name}.appiconset")
    if not os.path.isdir(base):
        fail(f"存在 {icon_set_name}.appiconset", base)
        return
    try:
        contents = json.load(open(os.path.join(base, "Contents.json"), encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        fail("AppIcon Contents.json 可解析", str(exc))
        return

    problems: list[str] = []
    visited = 0
    for image in contents.get("images", []) or []:
        filename = image.get("filename")
        size = image.get("size", "")
        scale = image.get("scale", "1x")
        if not filename:
            problems.append(f"缺少 filename（{image.get('idiom')} {size} {scale}）")
            continue
        path = os.path.join(base, filename)
        if not os.path.isfile(path):
            problems.append(f"文件缺失：{filename}")
            continue
        visited += 1
        try:
            with open(path, "rb") as fh:
                head = fh.read(33)
            if head[:8] != b"\x89PNG\r\n\x1a\n":
                problems.append(f"不是 PNG：{filename}")
                continue
            width, height = struct.unpack(">II", head[16:24])
            color_type = head[25]
        except Exception as exc:  # noqa: BLE001
            problems.append(f"读取失败：{filename}（{exc}）")
            continue

        if "x" in size:
            try:
                expect_w = float(size.split("x")[0])
                factor = int(scale.rstrip("x") or 1)
            except ValueError:
                problems.append(f"{filename} 的 Contents.json size/scale 无法解析：{size} {scale}")
                continue
            expect = expect_w * factor
            if abs(width - expect) > 0.5 or abs(height - expect) > 0.5:
                problems.append(
                    f"{filename} 尺寸 {width}x{height}，应为 {expect:g}x{expect:g}"
                )
        if color_type in (4, 6):
            problems.append(f"{filename} 带透明通道，App Store 要求图标不透明")

    if problems:
        fail("AppIcon 资源符合要求", "；".join(problems))
    else:
        ok("AppIcon 资源符合要求", f"{visited} 张图标，尺寸与不透明性正常")


def check_www() -> None:
    www = os.path.join(ROOT, "www")
    index = os.path.join(www, "index.html")
    if not os.path.isfile(index):
        fail("www/index.html 存在", "缺失，App 启动会落到兜底页面")
        return

    total_files = 0
    total_bytes = 0
    for dp, _, files in os.walk(www):
        for name in files:
            total_files += 1
            try:
                total_bytes += os.path.getsize(os.path.join(dp, name))
            except OSError:
                pass
    ok("www/index.html 存在", f"{total_files} 个文件，{total_bytes / 1048576:.1f} MB")

    html = open(index, encoding="utf-8", errors="replace").read()
    refs = re.findall(r'(?:src|href)="([^"]+)"', html)
    missing = []
    for ref in refs:
        if ref.startswith(("http://", "https://", "//", "data:", "#")):
            continue
        clean = ref.split("?")[0].split("#")[0]
        if clean and not os.path.exists(os.path.join(www, clean)):
            missing.append(clean)
    if missing:
        fail("index.html 引用的本地资源都存在", "缺失：" + ", ".join(missing))
    else:
        ok("index.html 引用的本地资源都存在", f"{len(refs)} 个引用")

    ds_store = [
        os.path.relpath(os.path.join(dp, f), www)
        for dp, _, files in os.walk(www)
        for f in files
        if f == ".DS_Store"
    ]
    if ds_store:
        warn("www 中不应有 .DS_Store", "会被打进 App 包，建议清理")
    if total_bytes > 150 * 1048576:
        warn("www 体积偏大", f"{total_bytes / 1048576:.1f} MB，会影响首次启动和上传")


def check_swift() -> None:
    src_dir = os.path.join(ROOT, "IoTCenter")
    swift_files = sorted(f for f in os.listdir(src_dir) if f.endswith(".swift"))
    if not swift_files:
        fail("存在 Swift 源文件", src_dir)
        return

    unbalanced: list[str] = []
    for name in swift_files:
        source = open(os.path.join(src_dir, name), encoding="utf-8").read()
        stripped = _strip_swift_noise(source)
        for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
            if stripped.count(open_ch) != stripped.count(close_ch):
                unbalanced.append(
                    f"{name}: {open_ch}{close_ch} {stripped.count(open_ch)}/{stripped.count(close_ch)}"
                )
    if unbalanced:
        fail("Swift 源码括号配对", "；".join(unbalanced))
    else:
        ok("Swift 源码括号配对", f"{len(swift_files)} 个文件")

    # iOS 16.4 的 isInspectable 必须在可用性判断内使用，否则低版本会编译报错
    for name in swift_files:
        source = open(os.path.join(src_dir, name), encoding="utf-8").read()
        if "isInspectable" in source and "#available(iOS 16.4" not in source:
            warn("isInspectable 缺少可用性判断", name)


def _strip_swift_noise(source: str) -> str:
    """去掉字符串字面量和注释，避免括号统计被内容干扰。"""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        if c == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and source[i + 1] == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                i += 1
            i += 2
        elif c == '"':
            multi = source.startswith('"""', i)
            quote = '"""' if multi else '"'
            i += len(quote)
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source.startswith(quote, i):
                    i += len(quote)
                    break
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_versions(settings: dict) -> None:
    """提示 App Store 版本号与包内 www 的更新时间关系（信息性）。"""
    version = settings.get("MARKETING_VERSION", "?")
    build = settings.get("CURRENT_PROJECT_VERSION", "?")
    ok("当前版本", f"{version} ({build})")
    if version == "1.3.1" and build == "7":
        warn(
            "版本号与上一次上传相同",
            "App Store Connect 拒绝重复的 版本+构建号 组合，重新上传前请递增 CURRENT_PROJECT_VERSION",
        )


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="IoTCenter 工程预检")
    parser.add_argument("--no-www", action="store_true", help="跳过 www 资源扫描")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    args = parser.parse_args()

    try:
        settings = check_pbxproj(args.no_www)
        if settings:
            check_info_plist(settings)
            check_icons(settings)
            check_versions(settings)
        if not args.no_www:
            check_www()
        check_swift()
    except Exception as exc:  # noqa: BLE001
        import traceback

        traceback.print_exc()
        fail("预检脚本运行", str(exc))

    if args.json:
        print(json.dumps([{"level": l, "title": t, "detail": d} for l, t, d in results], ensure_ascii=False, indent=2))
    else:
        symbols = {"PASS": "✅", "WARN": "⚠️ ", "FAIL": "❌"}
        for level, title, detail in results:
            line = f"{symbols[level]} {title}"
            if detail:
                line += f" —— {detail}"
            print(line)
        fails = sum(1 for l, _, _ in results if l == "FAIL")
        warns = sum(1 for l, _, _ in results if l == "WARN")
        print()
        print(f"合计：{len(results)} 项检查，{fails} 项失败，{warns} 项警告")

    return 1 if any(l == "FAIL" for l, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
