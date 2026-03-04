#!/usr/bin/env python3
import struct
import sys
import re

def sfh_hash(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    length = len(data)
    if length == 0: return 0

    h = length & 0xFFFFFFFF
    rem = length & 3
    idx = 0

    for _ in range(length >> 2):
        h = (h + (data[idx] | (data[idx + 1] << 8))) & 0xFFFFFFFF
        tmp = (((data[idx + 2] | (data[idx + 3] << 8)) << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        idx += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF

    if rem == 3:
        h = (h + (data[idx] | (data[idx + 1] << 8))) & 0xFFFFFFFF
        h = (h ^ (h << 16)) & 0xFFFFFFFF
        h = (h ^ (data[idx + 2] << 18)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + (data[idx] | (data[idx + 1] << 8))) & 0xFFFFFFFF
        h = (h ^ (h << 11)) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        h = (h + data[idx]) & 0xFFFFFFFF
        h = (h ^ (h << 10)) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF

    h = (h ^ (h << 3)) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h = (h ^ (h << 4)) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h = (h ^ (h << 25)) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h & 0xFFFFFFFF

def unescape_po(s):
    # 强制处理换行符，确保只有 \n
    s = s.replace("\\n", "\n")
    s = s.replace('\\"', '"')
    s = s.replace("\\\\", "\\")
    return s

def parse_po(path):
    entries = []
    # 使用 newline='' 配合 utf-8 处理跨平台换行符
    with open(path, "r", encoding="utf-8", newline='') as f:
        content = f.read()

    # 改进的正则匹配，更稳健地处理多行
    blocks = re.findall(r'msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)\nmsgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', content)
    
    for m_id, m_str in blocks:
        # 合并多行字符串并去引号
        clean_id = "".join(re.findall(r'"(.*)"', m_id))
        clean_str = "".join(re.findall(r'"(.*)"', m_str))
        
        final_id = unescape_po(clean_id)
        final_str = unescape_po(clean_str)
        
        if final_id: # 排除空的 msgid (header)
            entries.append((final_id, final_str))
    return entries

def po2lmo(po_path, lmo_path):
    entries = parse_po(po_path)
    body = b""
    index = []

    for msgid, msgstr in entries:
        key_bytes = msgid.encode("utf-8")
        val_bytes = msgstr.encode("utf-8")

        key_id = sfh_hash(key_bytes)
        val_id = sfh_hash(val_bytes)
        offset = len(body)
        length = len(val_bytes)

        body += val_bytes
        index.append((key_id, val_id, offset, length))

    # 关键：LuCI 要求索引必须按 key_id 升序排列
    index.sort(key=lambda x: x[0])

    with open(lmo_path, "wb") as f:
        f.write(body)
        for entry in index:
            f.write(struct.pack(">IIII", *entry))
        # trailer = index 起始偏移量 (即 body 大小)，不是 index 区段大小
        f.write(struct.pack(">I", len(body)))

    print(f"成功: 转换了 {len(entries)} 条记录 -> {lmo_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"用法: {sys.argv[0]} <输入.po> <输出.lmo>")
        sys.exit(1)
    po2lmo(sys.argv[1], sys.argv[2])