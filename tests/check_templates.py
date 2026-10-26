#!/usr/bin/env python3
"""校验 config/ 参考模板与脚本内嵌模板的渲染结果语义一致（防漂移）。

config/*.template 是给用户读的参考模板，脚本里内嵌的才是实际部署用的；
两者一旦漂移（历史上发生过 log.* 位置类问题），参考文档就会误导用户。
本脚本在 CI 中于两份模板都渲染成 TOML 后逐键比对，任何不一致直接失败。
"""

import pathlib
import tomllib

FAILS = []
ROOT = pathlib.Path(__file__).resolve().parent.parent
ART = pathlib.Path("/tmp/ci-artifacts")
TEST = {
    "__VPS_IP__": "203.0.113.7",
    "__FRP_TOKEN__": "ci-test-token-0123456789abcdef",
    "__DASH_USER__": "ciadmin",
    "__DASH_PASSWORD__": "ci-dash-pass-123",
}


def load(path: pathlib.Path) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def flatten(d: dict, prefix: str = "") -> dict:
    out = {}
    for k, v in d.items():
        key = f"{prefix}.{k}" if prefix else k
        out.update(flatten(v, key)) if isinstance(v, dict) else out.update({key: v})
    return out


def compare(kind: str, cfg: dict, embedded: dict) -> None:
    for key in sorted(set(cfg) | set(embedded)):
        if cfg.get(key) != embedded.get(key):
            FAILS.append(
                f"{kind} 模板漂移: {key}: config/={cfg.get(key)!r} vs 内嵌={embedded.get(key)!r}"
            )


def sub(text: str) -> str:
    for k, v in TEST.items():
        text = text.replace(k, v)
    return text


# ---- frpc：config/frpc.toml.template vs 内嵌模板渲染产物 ----
tpl_frpc = sub((ROOT / "config/frpc.toml.template").read_text(encoding="utf-8-sig"))
rendered_frpc = (ART / "frpc.toml").read_text(encoding="utf-8")
compare("frpc", flatten(tomllib.loads(tpl_frpc)), flatten(tomllib.loads(rendered_frpc)))

# ---- frps：config/frps.toml.template vs 内嵌模板渲染产物 ----
tpl_frps = sub((ROOT / "config/frps.toml.template").read_text(encoding="utf-8-sig"))
rendered_frps = (ART / "frps.toml").read_text(encoding="utf-8")
compare("frps", flatten(tomllib.loads(tpl_frps)), flatten(tomllib.loads(rendered_frps)))

if FAILS:
    print("\n".join(FAILS))
    sys_exit_code = 1
else:
    print("TEMPLATE_CONSISTENCY_OK")
    sys_exit_code = 0

# walrus 兼容性兜底（避免老解释器问题），显式退出
raise SystemExit(sys_exit_code)
