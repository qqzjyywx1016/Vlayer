#!/bin/bash

set -e

# ===== 配置部分 =====
CONTAINER_NAME="ubuntu-vlayer"
IMAGE_NAME="ubuntu:24.04"
PROJECT_NAME="vlayer-project"  # 可自定义项目名
VOLUME_NAME="vlayer-data"     # 用于持久化数据的Docker卷
LOG_FILE="/root/prove.log"    # 宿主机日志文件位置
INTERVAL=3600                # 执行间隔(秒)，默认1小时

# ===== 横幅显示 =====
clear
echo "=============================================="
echo "🚀 Vlayer 自动化安装与部署脚本"
echo "=============================================="
echo ""

# ===== 函数定义 =====

# 检查并获取环境变量
check_env_vars() {
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker 未安装！请先安装 Docker。"
        exit 1
    fi

    # 检查并获取VLAYER_API_TOKEN
    if [ -z "$VLAYER_API_TOKEN" ]; then
        echo "请输入 VLAYER_API_TOKEN："
        read -r VLAYER_API_TOKEN
        if [ -z "$VLAYER_API_TOKEN" ]; then
            echo "错误：VLAYER_API_TOKEN 不能为空！"
            exit 1
        fi
    fi

    # 检查并获取EXAMPLES_TEST_PRIVATE_KEY
    if [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
        echo "请输入 EXAMPLES_TEST_PRIVATE_KEY："
        read -r EXAMPLES_TEST_PRIVATE_KEY
        if [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
            echo "错误：EXAMPLES_TEST_PRIVATE_KEY 不能为空！"
            exit 1
        fi
    fi
}

# 准备日志文件
prepare_log_file() {
    echo "📝 准备日志文件..."
    
    # 如果是目录则删除
    if [ -d "$LOG_FILE" ]; then
        echo "警告：$LOG_FILE 是一个目录，正在删除..."
        sudo rm -rf "$LOG_FILE"
    fi
    
    # 如果不存在则创建
    if [ ! -f "$LOG_FILE" ]; then
        echo "创建日志文件 $LOG_FILE ..."
        sudo touch "$LOG_FILE"
        sudo chmod 666 "$LOG_FILE"
    fi
}

# 安装Docker容器
setup_container() {
    echo "🐳 设置Docker容器..."
    
    # 拉取镜像
    echo "拉取Ubuntu 24.04镜像..."
    sudo docker pull $IMAGE_NAME

    # 停止并删除已有容器
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        echo "停止并删除现有容器..."
        docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
        docker rm $CONTAINER_NAME >/dev/null 2>&1 || true
    fi

    # 创建数据卷（如果不存在）
    if ! docker volume inspect $VOLUME_NAME >/dev/null 2>&1; then
        echo "创建数据卷 $VOLUME_NAME ..."
        docker volume create $VOLUME_NAME
    fi

    # 运行新容器
    echo "启动新容器..."
    docker run -d \
        --name $CONTAINER_NAME \
        -v $VOLUME_NAME:/root/data \
        -v $LOG_FILE:/root/prove.log \
        $IMAGE_NAME \
        sleep infinity
        
    # 等待容器完全启动
    sleep 5
}

# 在容器内安装依赖
install_dependencies() {
    echo "🛠️ 在容器内安装依赖..."
    
    docker exec $CONTAINER_NAME /bin/bash -c "
        set -e
        echo '更新系统...'
        proxychains4 apt update && proxychains4 apt upgrade -y
        
        echo '安装基础工具...'
        proxychains4 apt install -y curl git unzip build-essential jq sudo
        
        echo '安装并配置proxychains4...'
        proxychains4 apt install -y proxychains4
        sudo tee /etc/proxychains4.conf <<EOF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 192.168.1.100 1080  # 替换为实际代理地址
EOF
        
        echo '设置环境变量...'
        echo 'export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"' >> ~/.bashrc
        
        # 安装Rust
        echo '安装Rust...'
        proxychains4 -q curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source \$HOME/.cargo/env
        
        # 验证Rust安装
        if ! command -v rustc > /dev/null; then
            echo '❌ Rust安装失败！'
            exit 1
        fi
        echo 'Rust版本：' \$(rustc --version)
        
        # 安装Foundry
        echo '安装Foundry...'
        proxychains4 -q curl -L https://foundry.paradigm.xyz | bash
        source ~/.bashrc
        proxychains4 \$HOME/.foundry/bin/foundryup
        
        # 验证Foundry安装
        if ! command -v forge > /dev/null; then
            echo '错误：forge命令不可用！尝试手动修复...'
            if [ -f \"\$HOME/.foundry/bin/forge\" ]; then
                echo '检测到forge的绝对路径，将手动添加到PATH'
                export PATH=\"\$HOME/.foundry/bin:\$PATH\"
                echo 'export PATH=\"\$HOME/.foundry/bin:\$PATH\"' >> ~/.bashrc
            else
                echo '❌ Foundry安装失败：未找到forge可执行文件'
                exit 1
            fi
        fi
        echo 'Foundry版本：' \$(forge --version)
        
        # 安装Bun
        echo '安装Bun...'
        BUN_INSTALL_DIR=\"\$HOME/.bun\"
        proxychains4 -q curl -fsSL https://bun.sh/install | bash || { 
            echo 'Bun安装失败！尝试备用安装方法...'
            sudo apt install -y unzip
            proxychains4 -q curl -fsSL https://bun.sh/install | bash
        }
        export BUN_INSTALL=\"\$BUN_INSTALL_DIR\"
        export PATH=\"\$BUN_INSTALL/bin:\$PATH\"
        echo 'export PATH=\"\$BUN_INSTALL/bin:\$PATH\"' >> ~/.bashrc
        
        # 验证Bun安装
        if ! command -v bun > /dev/null; then
            echo '错误：Bun未正确安装！尝试使用绝对路径...'
            if [ -f \"\$BUN_INSTALL/bin/bun\" ]; then
                echo '检测到Bun的绝对路径，将手动添加到PATH'
                export PATH=\"\$BUN_INSTALL/bin:\$PATH\"
            else
                echo '❌ Bun安装失败：未找到可执行文件'
                exit 1
            fi
        fi
        echo 'Bun版本：' \$(bun --version)
        
        # 安装Vlayer
        echo '安装Vlayer...'
        proxychains4 -q curl -SL https://install.vlayer.xyz | bash
        source ~/.bashrc
        proxychains4 \$HOME/.vlayer/bin/vlayerup
        
        # 验证Vlayer安装
        if ! command -v vlayer > /dev/null; then
            echo '错误：Vlayer未正确安装！尝试手动修复...'
            if [ -f \"\$HOME/.vlayer/bin/vlayer\" ]; then
                echo '检测到Vlayer的绝对路径，将手动添加到PATH'
                export PATH=\"\$HOME/.vlayer/bin:\$PATH\"
                echo 'export PATH=\"\$HOME/.vlayer/bin:\$PATH\"' >> ~/.bashrc
            else
                echo '❌ Vlayer安装失败：未找到vlayer可执行文件'
                exit 1
            fi
        fi
        echo 'Vlayer版本：' \$(vlayer --version || echo '未知')
        
        # 设置Git配置
        git config --global user.name 'vlayer-user'
        git config --global user.email 'vlayer@local.com'
        
        echo '✅ 所有依赖安装完成！'
    " || {
        echo "❌ 依赖安装失败！"
        exit 1
    }
}

# 初始化项目
setup_project() {
    echo "📁 初始化Vlayer项目..."
    
    docker exec -e VLAYER_API_TOKEN="$VLAYER_API_TOKEN" \
               -e EXAMPLES_TEST_PRIVATE_KEY="$EXAMPLES_TEST_PRIVATE_KEY" \
               $CONTAINER_NAME /bin/bash -c "
        set -e
        cd /root/data
        
        # 确保环境变量已加载
        source ~/.bashrc
        export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"
        
        # 验证vlayer命令可用
        if ! command -v vlayer > /dev/null; then
            echo '错误：vlayer命令不可用！'
            echo '当前PATH: \$PATH'
            exit 1
        fi
        
        # 初始化项目
        if [ -d \"$PROJECT_NAME\" ]; then
            echo '项目已存在，跳过初始化...'
        else
            echo '初始化新项目...'
            proxychains4 vlayer init \"$PROJECT_NAME\" --template simple-email-proof || {
                echo '❌ vlayer init失败！可能原因：'
                echo '1. 网络问题'
                echo '2. VLAYER_API_TOKEN无效'
                echo '3. Vlayer安装不完整'
                exit 1
            }
        fi
        
        cd \"$PROJECT_NAME\" || exit 1
        
        # 构建Solidity项目
        echo '构建Solidity合约...'
        proxychains4 forge build || {
            echo '❌ forge build失败！可能原因：'
            echo '1. Foundry安装问题'
            echo '2. 合约代码错误'
            exit 1
        }
        
        # 设置前端环境
        cd vlayer || exit 1
        echo '安装前端依赖...'
        proxychains4 bun install || {
            echo '❌ bun install失败！可能原因：'
            echo '1. 网络问题'
            echo '2. Bun安装不完整'
            exit 1
        }
        
        # 创建环境文件
        echo '创建环境配置文件...'
        cat > .env.testnet.local <<ENVVARS
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
ENVVARS
        
        # 确保package.json有prove脚本
        if ! grep -q '\"prove:testnet\"' package.json; then
            echo '添加prove:testnet脚本到package.json...'
            if ! command -v jq > /dev/null; then
                sudo apt install -y jq
            fi
            jq '.scripts += {\"prove:testnet\": \"VLAYER_ENV=testnet bun run prove.ts\"}' package.json > package.json.tmp
            mv package.json.tmp package.json
        fi
        
        echo '✅ 项目初始化完成！'
    " || {
        echo "❌ 项目初始化失败！"
        exit 1
    }
}

# 设置定时任务
setup_cron_job() {
    echo "⏰ 设置定时任务..."
    
    docker exec $CONTAINER_NAME /bin/bash -c "
        set -e
        echo '创建运行脚本...'
        cat > /root/run_prove.sh <<'EOF'
#!/bin/bash
cd /root/data/$PROJECT_NAME/vlayer

# 加载环境
source ~/.bashrc
export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"

# 日志函数
log() {
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$1\" >> /root/prove.log
}

# 主循环
while true; do
    log '开始执行证明...'
    
    # 明确设置VLAYER_ENV环境变量
    if proxychains4 VLAYER_ENV=testnet bun run prove.ts >> /root/prove.log 2>&1; then
        log '证明执行成功'
    else
        log '证明执行失败'
    fi
    
    log \"等待 $INTERVAL 秒后再次执行...\"
    sleep $INTERVAL
done
EOF
        
        chmod +x /root/run_prove.sh
        
        echo '启动后台任务...'
        nohup /root/run_prove.sh > /dev/null 2>&1 &
        
        echo '✅ 定时任务设置完成！'
    " || {
        echo "❌ 定时任务设置失败！"
        exit 1
    }
}

# ===== 主执行流程 =====
check_env_vars
prepare_log_file
setup_container
install_dependencies
setup_project
setup_cron_job

# ===== 完成信息 =====
echo ""
echo "✅✅✅ 安装和部署完成！ ✅✅✅"
echo ""
echo "📌 项目信息:"
echo "  项目名称: $PROJECT_NAME"
echo "  容器名称: $CONTAINER_NAME"
echo "  数据卷: $VOLUME_NAME"
echo "  日志文件: $LOG_FILE"
echo "  执行间隔: $INTERVAL 秒"
echo ""
echo "🔍 查看实时日志:"
echo "  tail -f $LOG_FILE"
echo ""
echo "🛠️ 进入容器检查:"
echo "  docker exec -it $CONTAINER_NAME /bin/bash"
echo ""
echo "⏹️ 停止后台任务:"
echo "  1. docker exec -it $CONTAINER_NAME /bin/bash"
echo "  2. pkill -f run_prove.sh"
echo ""
echo "🔄 'bun run prove.ts' 将每 $INTERVAL 秒运行一次"
echo "📌 注意: 确保使用正确的 VLAYER_API_TOKEN 和 EXAMPLES_TEST_PRIVATE_KEY"
echo ""
echo "💡 提示: 如需修改配置，可以编辑容器内的/root/data/$PROJECT_NAME/vlayer/.env.testnet.local文件"
