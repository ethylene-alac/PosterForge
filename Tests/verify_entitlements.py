import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    actual = plistlib.load(stream)
for key in ("platform-application", "com.apple.private.security.no-container",
            "com.apple.private.security.no-sandbox", "com.apple.private.security.storage.AppDataContainers"):
    assert actual.get(key) is True, f"Missing signed entitlement: {key}"
print(f"Signed daemon entitlements verified: {sys.argv[1]}")
