#!/bin/sh
# Read-only: no bootstrap/bootout/kickstart, no memory SET, no wallpaper work.
set -u
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo sh /var/jb/usr/libexec/posterforge-diagnose-service" >&2
    exit 1
fi
label=com.posterforge.daemon
echo "=== Actual system service registration ==="
system_state=$(launchctl print "system/$label" 2>&1)
system_rc=$?
printf '%s\n' "$system_state"
echo "=== Other domains (missing service is normal; a second PID requires investigation) ==="
for domain in user/0 user/501 gui/501; do
    echo "--- $domain/$label ---"
    launchctl print "$domain/$label" 2>&1 || true
done
if [ "$system_rc" -ne 0 ]; then
    echo "No system service was found. No service registration was changed." >&2
    exit 1
fi
daemon_pid=$(printf '%s\n' "$system_state" | awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')
case "$daemon_pid" in
    ''|*[!0-9]*) echo "System service has no running PID." >&2; exit 1 ;;
esac
echo "=== Kernel memory readback for system service PID $daemon_pid ==="
/var/jb/usr/libexec/posterforged --diagnose-runtime "$daemon_pid"
memory_rc=$?
echo "=== launchctl procinfo for that same PID ==="
launchctl procinfo "$daemon_pid" 2>&1 || true
echo "=== Bootstrap context for that same PID ==="
launchctl print "pid/$daemon_pid" 2>&1 || true
exit "$memory_rc"
