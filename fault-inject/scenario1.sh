#!/usr/bin/env bash
set -euo pipefail
# 场景1 故障注入：磁盘 100% + CPU 100%
# 用法：./scenario1.sh

POD=$(kubectl -n order get pod -l app=order-service -o jsonpath='{.items[0].metadata.name}')

echo "① 填满磁盘（512Mi tmpfs）"
kubectl -n order exec "$POD" -- sh -c 'mkdir -p /data/tmp && dd if=/dev/zero of=/data/tmp/fill bs=1M count=512 2>/dev/null || true'
echo "   磁盘已写满（df 应显示 ~100%）"

echo "② 压满 CPU（500m limit，起 2 个忙循环，setsid 脱离会话）"
kubectl -n order exec "$POD" -- sh -c 'setsid sh -c "while true; do :; done" >/dev/null 2>&1 & setsid sh -c "while true; do :; done" >/dev/null 2>&1 & echo ok'

echo ""
echo "✅ 场景1 已注入：磁盘 100% + CPU 打满"
echo "   验证：Grafana http://localhost:3000 → 看 CPU 利用率% 和磁盘利用率% 两个 gauge"
echo "   验证：curl http://localhost:18080/quotation?orderId=XXX → 应返回 500（No space left on device）"
echo "   恢复：./scenario1-recover.sh"
