#!/usr/bin/env python3
"""MailHub 一次性垃圾邮件训练器。

从上游邮箱（Gmail / QQ / 163 / 其他 IMAP）只读地抽取历史邮件：
  - Spam/Junk 文件夹  -> spam 样本
  - Sent 文件夹（可选再加 INBOX） -> ham 样本
然后通过 Stalwart JMAP 上传为 SpamTrainingSample，并触发一次训练。

上游邮件只用 EXAMINE + BODY.PEEK 读取，不会改变已读状态，也不会删除或移动。
"""
import argparse
import base64
import hashlib
import imaplib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from email.parser import BytesHeaderParser
from pathlib import Path

ACCOUNTS_DIR = Path(os.getenv("ACCOUNTS_DIR", "/accounts"))
STATE_FILE = Path(os.getenv("STATE_FILE", "/state/trained.json"))
STALWART_URL = os.getenv("STALWART_URL", "http://stalwart:8080").rstrip("/")
API_KEY_FILE = os.getenv("MAILHUB_API_KEY_FILE", "/run/mailhub/automation-key")

DEFAULT_SPAM_LIMIT = int(os.getenv("TRAIN_SPAM_LIMIT", "200"))
DEFAULT_HAM_LIMIT = int(os.getenv("TRAIN_HAM_LIMIT", "300"))
DEFAULT_HAM_INCLUDE_INBOX = os.getenv("TRAIN_HAM_INCLUDE_INBOX", "false")
MAX_MESSAGE_BYTES = int(os.getenv("TRAIN_MAX_MESSAGE_BYTES", str(5 * 1024 * 1024)))
CREATE_BATCH = 50

# 服务器不支持 RFC 6154 SPECIAL-USE 时按名称兜底（大小写不敏感，已做 IMAP UTF-7 解码）。
SPAM_NAMES = ["[Gmail]/Spam", "[Google Mail]/Spam", "Junk", "Spam", "Junk E-mail", "Junk Email", "Bulk Mail", "垃圾邮件", "垃圾箱"]
SENT_NAMES = ["[Gmail]/Sent Mail", "[Google Mail]/Sent Mail", "Sent Messages", "Sent", "Sent Items", "Sent Mail", "已发送", "已发送邮件"]

imaplib.Commands.setdefault("ID", ("AUTH", "SELECTED"))


def log(msg: str) -> None:
    print(msg, flush=True)


def truthy(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


# ---------------------------------------------------------------- 账号配置

def parse_env_file(path: Path) -> dict:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def load_accounts(only: str | None) -> list[dict]:
    accounts = []
    for path in sorted(ACCOUNTS_DIR.glob("*.env")):
        if path.name.endswith((".example.env", ".disabled.env")):
            continue
        cfg = parse_env_file(path)
        name = cfg.get("ACCOUNT_NAME") or path.stem
        if only and name != only:
            continue
        if not truthy(cfg.get("TRAIN_ENABLED", "true")):
            log(f"[{name}] TRAIN_ENABLED=false，跳过")
            continue
        missing = [k for k in ("IMAP_HOST", "IMAP_USER", "IMAP_PASSWORD") if not cfg.get(k)]
        if missing:
            log(f"[{name}] 缺少 {', '.join(missing)}，跳过")
            continue
        if imap_endpoint(cfg) is None:
            log(f"[{name}] Collector 使用 POP3，需在账号文件设置 TRAIN_IMAP_HOST（如 imap.163.com），跳过")
            continue
        cfg["ACCOUNT_NAME"] = name
        accounts.append(cfg)
    return accounts


# ---------------------------------------------------------------- IMAP

def imap_utf7_decode(name: str) -> str:
    out, i = [], 0
    while i < len(name):
        if name[i] == "&":
            j = name.find("-", i)
            if j < 0:
                return name
            if j == i + 1:
                out.append("&")
            else:
                chunk = name[i + 1:j].replace(",", "/")
                chunk += "=" * (-len(chunk) % 4)
                try:
                    out.append(base64.b64decode(chunk).decode("utf-16-be"))
                except Exception:
                    return name
            i = j + 1
        else:
            out.append(name[i])
            i += 1
    return "".join(out)


LIST_RE = re.compile(rb'^\((?P<flags>[^)]*)\)\s+(?:NIL|"(?:[^"\\]|\\.)*")\s+(?P<name>.*)$')


def list_folders(conn: imaplib.IMAP4_SSL) -> list[tuple[str, set[str]]]:
    typ, data = conn.list()
    if typ != "OK":
        return []
    folders = []
    for item in data:
        if isinstance(item, tuple):  # 名称以 literal 形式返回
            head, raw_name = item[0], item[1]
            m = LIST_RE.match(head.rsplit(b" {", 1)[0] + b' ""')
            name = raw_name
        else:
            m = LIST_RE.match(item or b"")
            name = m.group("name") if m else b""
        if not m:
            continue
        name = name.strip()
        if name.startswith(b'"') and name.endswith(b'"'):
            name = name[1:-1].replace(b'\\"', b'"').replace(b"\\\\", b"\\")
        flags = {f.lower() for f in m.group("flags").decode("ascii", "replace").split()}
        folders.append((name.decode("utf-8", "replace"), flags))
    return folders


def pick_folders(folders, override: str, flag: str, names: list[str]) -> list[str]:
    """返回服务器上的原始（未解码）文件夹名。"""
    if override:
        wanted = [x.strip() for x in override.split(",") if x.strip()]
        by_decoded = {imap_utf7_decode(raw): raw for raw, _ in folders}
        return [by_decoded.get(w, w) for w in wanted]
    special = [raw for raw, flags in folders if flag in flags]
    if special:
        return special[:1]
    lowered = {imap_utf7_decode(raw).lower(): raw for raw, _ in folders}
    for candidate in names:
        raw = lowered.get(candidate.lower())
        if raw:
            return [raw]
    return []


def quote_mailbox(raw: str) -> str:
    return '"' + raw.replace("\\", "\\\\").replace('"', '\\"') + '"'


def imap_endpoint(cfg: dict) -> tuple[str, int] | None:
    """trainer 总是用 IMAP。Collector 走 POP3 的账号需要 TRAIN_IMAP_HOST 指定 IMAP 服务器。"""
    if cfg.get("TRAIN_IMAP_HOST"):
        return cfg["TRAIN_IMAP_HOST"], int(cfg.get("TRAIN_IMAP_PORT") or 993)
    if (cfg.get("PROTOCOL") or "IMAP").upper() == "POP3":
        return None
    return cfg["IMAP_HOST"], int(cfg.get("IMAP_PORT") or 993)


def send_imap_id(conn: imaplib.IMAP4_SSL) -> None:
    """163/126 等网易邮箱要求客户端发送 RFC 2971 ID，否则 SELECT 返回 “Unsafe Login”。"""
    if "ID" not in conn.capabilities:
        return
    try:
        conn._simple_command("ID", '("name" "mailhub-trainer" "version" "1.4.0" "vendor" "mailhub")')
        conn._untagged_response("OK", [None], "ID")
    except Exception:
        pass


def connect(cfg: dict) -> imaplib.IMAP4_SSL:
    ctx = ssl.create_default_context()
    host, port = imap_endpoint(cfg)
    conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=60)
    # 部分服务商在登录前后都可能要求 ID，两处都发送，失败忽略。
    send_imap_id(conn)
    conn.login(cfg["IMAP_USER"], cfg["IMAP_PASSWORD"])
    send_imap_id(conn)
    return conn


def fetch_recent(conn, raw_folder: str, limit: int):
    """只读打开文件夹，按 UID 取最近 limit 封。逐封产出原始字节。"""
    typ, _ = conn.select(quote_mailbox(raw_folder), readonly=True)
    if typ != "OK":
        log(f"    无法打开文件夹 {imap_utf7_decode(raw_folder)}")
        return
    typ, data = conn.uid("search", None, "ALL")
    if typ != "OK" or not data or not data[0]:
        return
    uids = data[0].split()[-limit:] if limit > 0 else []
    for uid in reversed(uids):
        typ, data = conn.uid("fetch", uid, "(RFC822.SIZE)")
        size_match = re.search(rb"RFC822\.SIZE (\d+)", data[0] if data and isinstance(data[0], bytes) else b"")
        if size_match and int(size_match.group(1)) > MAX_MESSAGE_BYTES:
            continue
        typ, data = conn.uid("fetch", uid, "(BODY.PEEK[])")
        if typ != "OK":
            continue
        for part in data:
            if isinstance(part, tuple) and isinstance(part[1], (bytes, bytearray)):
                yield bytes(part[1])
                break


# ---------------------------------------------------------------- Stalwart JMAP

class Stalwart:
    def __init__(self, base: str, token: str):
        self.base = base
        self.token = token
        session = self._request("GET", "/jmap/session")
        self.account_id = session["primaryAccounts"]["urn:ietf:params:jmap:mail"]

    def _request(self, method: str, path: str, body: bytes | None = None, content_type: str = "application/json"):
        req = urllib.request.Request(self.base + path, data=body, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            detail = exc.read()[:300].decode("utf-8", "replace")
            raise RuntimeError(f"Stalwart HTTP {exc.code} {path}: {detail}") from None

    def call(self, calls: list) -> list:
        body = json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": calls}).encode()
        return self._request("POST", "/jmap/", body)["methodResponses"]

    def upload(self, raw: bytes) -> str:
        return self._request("POST", f"/jmap/upload/{self.account_id}/", raw, "message/rfc822")["blobId"]

    def create_samples(self, items: list[tuple[str, bool]]) -> int:
        create = {f"s{i}": {"blobId": blob, "isSpam": is_spam, "accountId": self.account_id} for i, (blob, is_spam) in enumerate(items)}
        _, result, _ = self.call([["x:SpamTrainingSample/set", {"create": create}, "c"]])[0]
        for key, err in (result.get("notCreated") or {}).items():
            log(f"    样本创建失败 {key}: {err}")
        return len(result.get("created") or {})

    def sample_counts(self) -> tuple[int, int]:
        responses = self.call([
            ["x:SpamTrainingSample/query", {}, "q"],
            ["x:SpamTrainingSample/get", {"#ids": {"resultOf": "q", "name": "x:SpamTrainingSample/query", "path": "/ids"}, "properties": ["isSpam"]}, "g"],
        ])
        spam = ham = 0
        for name, result, _ in responses:
            if name.endswith("/get"):
                for sample in result.get("list", []):
                    spam, ham = (spam + 1, ham) if sample.get("isSpam") else (spam, ham + 1)
        return spam, ham

    def trigger_training(self) -> None:
        _, result, _ = self.call([["x:Task/set", {"create": {"t": {"@type": "SpamFilterMaintenance", "maintenanceType": "train"}}}, "t"]])[0]
        if result.get("notCreated"):
            raise RuntimeError(f"训练任务创建失败: {result['notCreated']}")


# ---------------------------------------------------------------- 主流程

def message_key(raw: bytes) -> str:
    headers = BytesHeaderParser().parsebytes(raw)
    mid = (headers.get("Message-ID") or "").strip()
    return hashlib.sha256(mid.encode() if mid else raw).hexdigest()


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state), encoding="utf-8")
    tmp.replace(STATE_FILE)


def main() -> int:
    parser = argparse.ArgumentParser(description="MailHub 垃圾邮件分类器一次性训练")
    parser.add_argument("--dry-run", action="store_true", help="只列出将要抽取的文件夹和数量，不上传")
    parser.add_argument("--account", help="只处理指定 ACCOUNT_NAME")
    parser.add_argument("--no-train", action="store_true", help="只导入样本，不立即触发训练")
    args = parser.parse_args()

    accounts = load_accounts(args.account)
    if not accounts:
        log("没有可用的 accounts/*.env")
        return 1

    stalwart = None
    if not args.dry_run:
        token = os.getenv("MAILHUB_API_KEY") or Path(API_KEY_FILE).read_text(encoding="utf-8").strip()
        stalwart = Stalwart(STALWART_URL, token)

    state = load_state()
    total_new = 0
    for cfg in accounts:
        name = cfg["ACCOUNT_NAME"]
        try:
            conn = connect(cfg)
        except Exception as exc:
            host, port = imap_endpoint(cfg)
            detail = str(exc).strip() or repr(exc)
            log(f"[{name}] IMAP 登录失败（{host}:{port}，用户 {cfg['IMAP_USER']}）：{type(exc).__name__}: {detail}")
            if host and "163" in str(host):
                log(f"[{name}] 提示：163 需要在网页端单独开启 “IMAP/SMTP 服务”，POP3 的开关不代管 IMAP")
            continue
        try:
            folders = list_folders(conn)
            include_inbox = truthy(cfg.get("TRAIN_HAM_INCLUDE_INBOX", DEFAULT_HAM_INCLUDE_INBOX))
            spam_folders = pick_folders(folders, cfg.get("TRAIN_SPAM_FOLDERS", ""), "\\junk", SPAM_NAMES)
            ham_folders = pick_folders(folders, cfg.get("TRAIN_HAM_FOLDERS", ""), "\\sent", SENT_NAMES)
            if include_inbox and not cfg.get("TRAIN_HAM_FOLDERS"):
                ham_folders.append("INBOX")
            plan = [(f, True, int(cfg.get("TRAIN_SPAM_LIMIT") or DEFAULT_SPAM_LIMIT)) for f in spam_folders]
            plan += [(f, False, int(cfg.get("TRAIN_HAM_LIMIT") or DEFAULT_HAM_LIMIT)) for f in ham_folders]
            if not spam_folders:
                log(f"[{name}] 未识别到垃圾邮件文件夹，可在账号文件设置 TRAIN_SPAM_FOLDERS")
            if not ham_folders:
                log(f"[{name}] 未识别到已发送文件夹，可在账号文件设置 TRAIN_HAM_FOLDERS")

            for folder, is_spam, limit in plan:
                label = "spam" if is_spam else "ham"
                log(f"[{name}] {imap_utf7_decode(folder)} -> {label}，最多 {limit} 封")
                if args.dry_run:
                    continue
                pending, uploaded, skipped = [], 0, 0
                for raw in fetch_recent(conn, folder, limit):
                    key = message_key(raw)
                    if key in state:
                        skipped += 1
                        continue
                    pending.append((stalwart.upload(raw), is_spam))
                    state[key] = label
                    if len(pending) >= CREATE_BATCH:
                        uploaded += stalwart.create_samples(pending)
                        pending.clear()
                        save_state(state)
                if pending:
                    uploaded += stalwart.create_samples(pending)
                save_state(state)
                total_new += uploaded
                log(f"    新增 {uploaded} 个样本，跳过已导入 {skipped} 封")
        finally:
            try:
                conn.logout()
            except Exception:
                pass

    if args.dry_run:
        log("dry-run 完成，未上传任何样本")
        return 0

    spam, ham = stalwart.sample_counts()
    log(f"本次新增 {total_new} 个样本；Stalwart 当前样本：spam={spam}，ham={ham}（默认各需 ≥100 才启用统计分类器）")
    if total_new and not args.no_train:
        stalwart.trigger_training()
        log("已提交一次训练任务（SpamFilterMaintenance/train），结果见 Stalwart 日志")
    return 0


if __name__ == "__main__":
    sys.exit(main())
