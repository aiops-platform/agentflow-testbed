#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# AIOps 测试床：一键打包 jar → 打镜像 → 发布到 minikube
# 用法：
#   ./build-and-deploy.sh                     # 全部三个服务
#   ./build-and-deploy.sh --service order-service   # 只做单个服务
#   ./build-and-deploy.sh --skip-build        # 跳过 gradle 打包（jar 已存在）
# ============================================================

cd "$(dirname "$0")"

# docker CLI 走 podman socket
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

SERVICES=(order-service warranty-service gateway-service)
SKIP_BUILD=false
ONLY_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --service) ONLY_SERVICE="$2"; shift 2 ;;
    *) echo "未知参数: $1"; echo "用法: $0 [--skip-build] [--service <name>]"; exit 1 ;;
  esac
done

# 1. 检查前置
if ! minikube status >/dev/null 2>&1; then
  echo "❌ minikube 未运行。请先启动："
  echo "   minikube start --driver=docker --force --cpus=4 --memory=5120"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "❌ docker CLI 连不上 podman socket（DOCKER_HOST=$DOCKER_HOST）"
  exit 1
fi
echo "✅ minikube 运行中，docker 走 podman socket"

# 2. 构建 + 打镜像 + 加载 + 发布（每个服务用时间戳 tag，避免 minikube 同 tag 不覆盖的问题）
TAG="$(date +%Y%m%d%H%M%S)"
kubectl create namespace order >/dev/null 2>&1 || true

for svc in "${SERVICES[@]}"; do
  [[ -n "$ONLY_SERVICE" && "$svc" != "$ONLY_SERVICE" ]] && continue
  echo ""
  echo "===================== $svc ====================="
  cd "services/aiops-test-$svc"

  if [[ "$SKIP_BUILD" == "false" ]]; then
    echo "① 打包 jar ..."
    ./gradlew clean build --no-daemon -q
  else
    echo "① 跳过打包（--skip-build）"
  fi

  echo "② 打镜像 $svc:$TAG ..."
  docker build -q -t "$svc:$TAG" .

  echo "③ 加载到 minikube ..."
  minikube image load "$svc:$TAG" >/dev/null

  echo "④ 发布（kubectl set image）..."
  kubectl -n order set image "deploy/$svc" "$svc=$svc:$TAG"

  cd ../..
  echo "✅ $svc 完成"
done

echo ""
echo "===================== 等待就绪 ====================="
kubectl -n order wait --for=condition=available \
  deploy/order-service deploy/warranty-service deploy/gateway-service \
  --timeout=300s

echo ""
echo "✅ 全部完成！当前 pods："
kubectl -n order get pods
