"""Check a thin packaged Mach-O's CPU and actual iOS deployment load command."""
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
architecture = sys.argv[2]
data = path.read_bytes()
magic, cpu, subtype, filetype, commands, command_bytes, flags, reserved = struct.unpack_from("<8I", data)
assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected little-endian 64-bit ARM Mach-O"
assert subtype & 0xFFFFFF == {"arm64": 0, "arm64e": 2}[architecture], "Wrong ARM subtype"
offset = 32
versions = []
for _ in range(commands):
    command, size = struct.unpack_from("<2I", data, offset)
    assert size >= 8 and offset + size <= 32 + command_bytes
    if command == 0x32:  # LC_BUILD_VERSION
        platform, minimum = struct.unpack_from("<2I", data, offset + 8)
        assert platform == 2, "Expected device iOS platform"
        versions.append(minimum)
    elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
        versions.append(struct.unpack_from("<I", data, offset + 8)[0])
    offset += size
assert versions and all(version == 16 << 16 for version in versions), "Expected actual iOS 16.0 deployment target"
print(f"Mach-O {architecture}, device iOS 16.0 verified: {path}")
