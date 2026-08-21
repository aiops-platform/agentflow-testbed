#!/usr/bin/env bash
set -euo pipefail
# 场景1 恢复：重启 pod（清空 tmpfs 磁盘 + 杀掉 CPU 忙循环）
# 用法：./scenario1-recover.sh

echo "重启 order-service（清磁盘 + 停 CPU 忙循环）"
kubectl -n order rollout restart deploy/order-service
kubectl -n order wait --for=condition=available deploy/order-service --timeout=120s

echo ""
echo "✅ 场景1 已恢复：磁盘清空（tmpfs 重建）+ CPU 回落"
echo "   验证：Grafana 磁盘利用率% 应回到 ~0%，CPU 利用率% 应回落到个位数"
echo "   验证：curl http://localhost:18080/quotation?orderId=XXX → 应恢复 200"
