#!/usr/bin/env bash
set -euo pipefail
# 稳定端口转发：把 service 固定映射到本地端口，pod 重启/滚动发布换新 pod 时自动重连。
#
# 为什么需要它：`kubectl port-forward svc/<name>` 会在启动时把 service 解析并钉死到一个 pod，
# 该 pod 一旦重启/被替换，转发就断连退出、不会自动恢复。本脚本用重试循环在退出后立即重跑，
# 每次重跑都会重新解析到当前健康的 pod。
#
# 用法:
#   NAMESPACE=order ./port-forward.sh order-service 18080 8080
#   ./port-forward.sh <service> <local_port> [remote_port=8080]

NAMESPACE="${NAMESPACE:-order}"
SVC="$1"
LOCAL_PORT="$2"
REMOTE_PORT="${3:-8080}"

if [[ -z "${SVC}" || -z "${LOCAL_PORT}" ]]; then
  echo "用法: $0 <service> <local_port> [remote_port]" >&2
  echo "示例: $0 order-service 18080 8080" >&2
  exit 2
fi

# 优雅退出：Ctrl+C / kill 时不再重连
terminate() {
  echo "[$(date +%T)] ${SVC} 端口转发停止（收到终止信号）" >&2
  exit 0
}
trap terminate SIGINT SIGTERM

echo "[$(date +%T)] 端口转发 ${SVC} -> localhost:${LOCAL_PORT}:${REMOTE_PORT}（自动重连中）"
until kubectl -n "${NAMESPACE}" port-forward "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}"; do
  echo "[$(date +%T)] ${SVC} 转发断开（pod 重启/换新？），2 秒后重连..." >&2
  sleep 2
done
