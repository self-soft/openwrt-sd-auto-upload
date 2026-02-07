#!/bin/sh
set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOSCRIPT="$BASE_DIR/autoupload.sh"
AUTOCONF="$BASE_DIR/autoupload.conf"
INIT_NAME="openwrt-sd-auto-upload"
INIT_PATH="/etc/init.d/$INIT_NAME"

if [ ! -f "$AUTOSCRIPT" ]; then
  echo "Missing $AUTOSCRIPT"
  exit 1
fi
if [ ! -f "$AUTOCONF" ]; then
  echo "Missing $AUTOCONF"
  exit 1
fi

cat > "$INIT_PATH" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

PROG="$AUTOSCRIPT"

start_service() {
  procd_open_instance
  procd_set_param command "\$PROG"
  procd_close_instance
}
EOF

chmod +x "$INIT_PATH"
"$INIT_PATH" enable

echo "Installed and enabled $INIT_PATH"
