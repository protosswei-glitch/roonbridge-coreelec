#!/bin/sh
# =============================================================================
# install-roonbridge-coreelec.sh
#
# 在 CoreELEC (Kodi) 盒子上安装 Roon Bridge。适配 CoreELEC 的三个硬限制:
#   1) /opt /usr /etc 是 squashfs 只读   -> 部署到 /storage, 服务放 /storage/.config/system.d
#   2) /var 是 tmpfs, 重启清空          -> 数据目录用 /storage/var/roon (ROON_DATAROOT/ID_DIR)
#   3) 无 libicu                          -> DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
#
# 用法(在盒子上, root):
#   sh install-roonbridge-coreelec.sh                # 默认 armv8
#   sh install-roonbridge-coreelec.sh armv7hf        # 32位 ARM 盒子
#   sh install-roonbridge-coreelec.sh aarch64        # 若官方出 aarch64 包
#
# 从 macOS/本地推送并执行:
#   scp install-roonbridge-coreelec.sh root@<盒子IP>:/tmp/
#   ssh root@<盒子IP> 'sh /tmp/install-roonbridge-coreelec.sh armv8'
#
# 幂等: 重复运行安全; 卸载见文件末尾 UNINSTALL 注释。
# =============================================================================
set -u

ARCH="${1:-armv8}"
PKG="RoonBridge_linux${ARCH}.tar.bz2"
URL="https://download.roonlabs.net/builds/${PKG}"

INSTALL_DIR="/storage/RoonBridge"          # 程序目录 (只读根之外的可写盘)
DATA_ROOT="/storage/var/roon"              # 数据目录 (必须持久, 不能用 /var)
UNIT_DIR="/storage/.config/system.d"       # CoreELEC 可写的 systemd unit 目录
UNIT="${UNIT_DIR}/roonbridge.service"

log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0) 前置 ---------------------------------------------------------------
log "0. 前置检查"
[ "$(id -u)" = "0" ] || die "必须以 root 运行"
command -v systemctl >/dev/null 2>&1 || die "无 systemctl (非 systemd 系统, 本脚本不适用)"
[ -d /storage ] || die "无 /storage 分区 (CoreELEC 应有)"
touch /storage/.wtest 2>/dev/null && rm -f /storage/.wtest || die "/storage 不可写"
mkdir -p "$UNIT_DIR" 2>/dev/null || die "无法创建 ${UNIT_DIR}"
[ -w "$UNIT_DIR" ] || die "${UNIT_DIR} 不可写 (非 CoreELEC?)"

# ---- 1) 下载 (幂等: 已存在且非空则跳过) -----------------------------------
log "1. 下载 ${PKG}  -> /storage"
cd /storage
if [ -s "${PKG}" ]; then
  echo "已存在 ${PKG}, 跳过下载"
else
  command -v curl >/dev/null 2>&1 || die "无 curl, 无法下载"
  curl -fL --retry 2 --retry-delay 2 -o "${PKG}" "${URL}" \
    || die "下载失败: ${URL} (确认架构名 ${ARCH} 是否正确)"
fi
ls -la "${PKG}"

# ---- 2) 解压 (幂等: 覆盖式) -----------------------------------------------
log "2. 解压到 ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}"
tar xf "${PKG}" -C /storage || die "解压失败"
[ -x "${INSTALL_DIR}/Bridge/RoonBridge" ] || die "未找到 ${INSTALL_DIR}/Bridge/RoonBridge"
chmod +x "${INSTALL_DIR}/start.sh" "${INSTALL_DIR}/Bridge/RoonBridge" 2>/dev/null
cat "${INSTALL_DIR}/VERSION" 2>/dev/null && echo "(VERSION)"

# ---- 3) 依赖检查 (libicu 用 invariant 模式绕过) ----------------------------
log "3. 依赖检查 (check.sh)"
cd "${INSTALL_DIR}"
if [ -x ./check.sh ]; then
  DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 ./check.sh --preflight
  rc=$?
  [ "$rc" = "0" ] || die "preflight 未通过 (exit=${rc})。若为 libicu, 本脚本已用 invariant 模式; 其它缺失库需手动补。"
  echo "preflight OK"
else
  echo "无 check.sh, 跳过"
fi

# ---- 4) 数据目录 -----------------------------------------------------------
log "4. 建数据目录 ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/data" "${DATA_ROOT}/config"

# ---- 5) 写 systemd 服务 ----------------------------------------------------
log "5. 写服务文件 ${UNIT}"
systemctl stop roonbridge.service 2>/dev/null || true
pkill -f 'RoonBridge' 2>/dev/null || true
pkill -f 'RAATServer' 2>/dev/null || true
sleep 1

cat > "${UNIT}" <<EOF
[Unit]
Description=Roon Bridge
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=USER=root
Environment=ROON_DATAROOT=${DATA_ROOT}
Environment=ROON_ID_DIR=${DATA_ROOT}
Environment=XDG_DATA_HOME=${DATA_ROOT}/data
Environment=XDG_CONFIG_HOME=${DATA_ROOT}/config
Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF
echo "已写入:"; cat "${UNIT}"

# ---- 6) 加载并启动 ---------------------------------------------------------
log "6. daemon-reload + enable + start"
systemctl daemon-reload
systemctl enable roonbridge.service 2>&1 | tail -1
systemctl start roonbridge.service
sleep 12

# ---- 7) 验证 ---------------------------------------------------------------
log "7. 验证"
state="$(systemctl is-active roonbridge.service)"
echo "is-active:  ${state}"
echo "is-enabled: $(systemctl is-enabled roonbridge.service)"

# 注册成功的关键日志: "registered 1 devices"
journalctl -u roonbridge.service --no-pager -n 60 2>/dev/null | grep -E "registered|SOOD announce|discovery.roonlabs.net" | tail -5 || true

if [ "${state}" = "active" ]; then
  echo ""
  log "OK — Roon Bridge 已安装并运行 (架构 ${ARCH})"
  echo "  设备 unique_id: $(cat ${DATA_ROOT}/RoonBridge/Settings/unique_id 2>/dev/null)"
  echo "  下一步: 打开 Roon App → 添加设备, 应能看到这台盒子。"
  echo "  重启自动拉起: 已 enable。想验证可 reboot 后再查 'systemctl is-active roonbridge'。"
  # 清理安装包 (可选, 保留以离线重装; 如需删: 取消下行注释)
  # rm -f /storage/${PKG}
else
  die "服务未 active。查: journalctl -u roonbridge.service -n 40 ; tail ${DATA_ROOT}/RoonBridge/Logs/RoonBridge_log.txt"
fi

# =============================================================================
# UNINSTALL  (手动执行, 脚本不含自动卸载以免误删):
#   systemctl disable --now roonbridge
#   rm -f /storage/.config/system.d/roonbridge.service
#   systemctl daemon-reload
#   rm -rf /storage/RoonBridge /storage/var/roon
#   rm -f /storage/RoonBridge_linux*.tar.bz2
# =============================================================================
