# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Act like Chrome talking to a native-messaging host.

usage: native_client.py <kai> <origin> <message> [<message>...]
Starts `kai <origin>`, sends each message (raw text, so invalid JSON can be
tested too) framed as a 32-bit native-order length plus bytes, then prints
each reply on its own line.
"""
import struct
import subprocess
import sys

kai, origin, messages = sys.argv[1], sys.argv[2], sys.argv[3:]
p = subprocess.Popen([kai, origin], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
for m in messages:
    data = m.encode()
    p.stdin.write(struct.pack("=I", len(data)) + data)
    p.stdin.flush()
    head = p.stdout.read(4)
    if len(head) < 4:
        print("(host closed the connection)")
        break
    (n,) = struct.unpack("=I", head)
    print(p.stdout.read(n).decode())
p.stdin.close()
p.wait(timeout=10)
