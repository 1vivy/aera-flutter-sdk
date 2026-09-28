# Sourced by the root manager's installer (KernelSU, APatch, Magisk).
# Keeps the ops worker built for this phone's CPU and drops the others.
worker=@WORKER@
case "$ARCH" in
  arm64) abi=arm64-v8a ;;
  x64) abi=x86_64 ;;
  *) abi= ;;
esac
if [ -n "$abi" ] && [ -f "$MODPATH/bin/$abi/$worker" ]; then
  mv -f "$MODPATH/bin/$abi/$worker" "$MODPATH/bin/$worker"
  set_perm "$MODPATH/bin/$worker" 0 0 0755
else
  ui_print "! No ops worker for $ARCH; root features stay off"
fi
rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/x86_64"
ui_print "- Open @NAME@ from the root manager's module list (WebUI)"
