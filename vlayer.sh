#!/bin/bash

set -e

# ===== 配置部分 =====
CONTAINER_NAME="ubuntu-vlayer"
IMAGE_NAME="ubuntu:24.04"
PROJECT_NAME="vlayer-project"
VOLUME_NAME="vlayer-data"
LOG_FILE="$HOME/vlayer/prove.log"  # 修改1：Mac用户目录路径
INTERVAL=3600

# ===== 横幅显示 =====
clear
echo "=============================================="
echo "🚀 Vlayer 自动化安装与部署脚本（Mac版）"
echo "=============================================="
echo ""

# ===== 函数定义 =====

check_env_vars() {
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker 未安装！推荐使用Orbstack替代Docker Desktop[1](@ref)"
        echo "安装命令：brew install orbstack"
        exit 1
    fi

    if [ -z "$VLAYER_API_TOKEN" ]; then
        echo "请输入 VLAYER_API_TOKEN："
        read -r VLAYER_API_TOKEN
        [ -z "$VLAYER_API_TOKEN" ] && { echo "错误：VLAYER_API_TOKEN 不能为空！"; exit 1; }
        export VLAYER_API_TOKEN
    fi

    if [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
        echo "请输入 EXAMPLES_TEST_PRIVATE_KEY："
        read -r EXAMPLES_TEST_PRIVATE_KEY
        [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ] && { echo "错误：EXAMPLES_TEST_PRIVATE_KEY 不能为空！"; exit 1; }
        export EXAMPLES_TEST_PRIVATE_KEY
    fi
}

prepare_log_file() {
    echo "📝 准备日志文件..."
    mkdir -p "$(dirname "$LOG_FILE")"
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"  # 修改2：移除sudo，适应Mac权限
}

setup_container() {
    echo "🐳 设置Docker容器..."
    docker pull $IMAGE_NAME

    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        echo "停止并删除现有容器..."
        docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
        docker rm $CONTAINER_NAME >/dev/null 2>&1 || true
    fi

    if ! docker volume inspect $VOLUME_NAME >/dev/null 2>&1; then
        echo "创建数据卷 $VOLUME_NAME ..."
        docker volume create $VOLUME_NAME
    fi

    echo "启动新容器（适配Mac文件系统）..."
    docker run -d \
        --name $CONTAINER_NAME \
        -v $VOLUME_NAME:/data \  # 修改3：统一数据目录
        -v "$LOG_FILE":/prove.log \  # 修改4：简化日志路径
        --platform linux/amd64 \  # 修改5：确保架构兼容
        $IMAGE_NAME \
        sleep infinity
        
    sleep 5
}

install_dependencies() {
    echo "🛠️ 在容器内安装依赖..."
    
    docker exec $CONTAINER_NAME /bin/bash -c "
        set -e
        echo '更新系统...'
        apt update && apt upgrade -y

        # 修改6：代理配置适配Mac网络
        echo '安装代理工具...'
        apt install -y proxychains4
        tee /etc/proxychains4.conf <<'EOF'
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 host.docker.internal 7897  # 保持使用Docker内置DNS
EOF

        echo '安装基础工具...'
        apt install -y curl git unzip build-essential jq sudo
        
        echo '设置环境变量...'
        echo 'export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"' >> ~/.bashrc
        
        # 安装Rust（通过代理）
        echo '安装Rust...'
        proxychains4 -q curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source \$HOME/.cargo/env
        
        # 验证Rust安装
        if ! command -v rustc > /dev/null; then
            echo '❌ Rust安装失败！'; exit 1
        fi
        
        # 安装Foundry（通过代理）
        echo '安装Foundry...'
        proxychains4 -q curl -L https://foundry.paradigm.xyz | bash
        source ~/.bashrc
        foundryup
        
        # 安装Bun（通过代理）
        echo '安装Bun...'
        proxychains4 -q curl -fsSL https://bun.sh/install | bash
        export PATH=\"\$HOME/.bun/bin:\$PATH\"
        
        # 安装Vlayer（通过代理）
        echo '安装Vlayer...'
        proxychains4 -q curl -SL https://install.vlayer.xyz | bash
        source ~/.bashrc
        vlayerup
        
        # 设置Git配置
        git config --global user.name 'vlayer-user'
        git config --global user.email 'vlayer@local.com'
    " || { echo "❌ 依赖安装失败！"; exit 1; }
}

setup_project() {
    echo "📁 初始化Vlayer项目..."
    
    docker exec -e VLAYER_API_TOKEN="$VLAYER_API_TOKEN" \
               -e EXAMPLES_TEST_PRIVATE_KEY="$EXAMPLES_TEST_PRIVATE_KEY" \
               $CONTAINER_NAME /bin/bash -c "
        set -e
        cd /data
        
        source ~/.bashrc
        export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"
        
        if [ -d \"$PROJECT_NAME\" ]; then
            echo '项目已存在，跳过初始化...'
        else
            vlayer init \"$PROJECT_NAME\" --template simple-email-proof
        fi
        
        cd \"$PROJECT_NAME\"
        forge build
        cd vlayer
        bun install
        
        tee .env.testnet.local <<ENVVARS
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
ENVVARS
        
        jq '.scripts += {\"prove:testnet\": \"VLAYER_ENV=testnet bun run prove.ts\"}' package.json > tmp.json
        mv tmp.json package.json
    " || { echo "❌ 项目初始化失败！"; exit 1; }
}

setup_cron_job() {
    echo "⏰ 设置定时任务..."
    
    docker exec $CONTAINER_NAME /bin/bash -c "
        cat > /run_prove.sh <<'EOF'
#!/bin/bash
cd /data/$PROJECT_NAME/vlayer
source ~/.bashrc

log() {
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$1\" >> /prove.log
}

while true; do
    log '开始执行证明...'
    VLAYER_ENV=testnet bun run prove.ts >> /prove.log 2>&1
    sleep $INTERVAL
done
EOF
        
        chmod +x /run_prove.sh
        nohup /run_prove.sh > /dev/null 2>&1 &
    "
}

# ===== 主执行流程 =====
check_env_vars
prepare_log_file
setup_container
install_dependencies
setup_project
setup_cron_job

echo ""
echo "✅✅✅ Mac版部署完成！ ✅✅✅"
echo "🔍 查看日志：open -a Console $LOG_FILE"
echo "🛠️ 进入容器：docker exec -it $CONTAINER_NAME bash"
