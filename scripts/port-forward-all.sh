#!/usr/bin/env bash
set -euo pipefail
# 一键启动全部端口转发（3 个服务 + 4 个数据源/监控 UI），每个都用 port-forward.sh 自动重连。
# 启动前会检测本地端口是否已被占用：已占用则跳过（不会反复重试刷日志），空闲才起。
#
# 每个转发的日志落到 /tmp/aiops-port-forward/<service>.log，方便排障。
#
# 停止全部: pkill -f 'kubectl.*port-forward'
# 查看监听: lsof -nP -iTCP -sTCP:LISTEN | grep -E '1808[0-2]|3000|5601|19090|19200'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="${SCRIPT_DIR}/port-forward.sh"
LOGDIR="/tmp/aiops-port-forward"
mkdir -p "${LOGDIR}"

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

forward() {
  local svc="$1" local_port="$2" remote_port="$3"
  if port_in_use "${local_port}"; then
    echo "  ${svc} -> localhost:${local_port}:${remote_port}  已占用，跳过"
    return 0
  fi
  "${PF}" "${svc}" "${local_port}" "${remote_port}" >"${LOGDIR}/${svc}.log" 2>&1 &
  echo "  ${svc} -> localhost:${local_port}:${remote_port}  (日志: ${LOGDIR}/${svc}.log)"
}

echo "启动端口转发（均自动重连）："
forward order-service    18080 8080
forward warranty-service 18081 8080
forward gateway-service  18082 8080
forward grafana          3000  3000
forward kibana           5601  5601
forward prometheus       19090 9090
forward elasticsearch    19200 9200

echo ""
echo "全部已启动。"
echo "  停止全部: pkill -f 'kubectl.*port-forward'"
echo "  查看监听: lsof -nP -iTCP -sTCP:LISTEN | grep -E '1808[0-2]|3000|5601|19090|19200'"
