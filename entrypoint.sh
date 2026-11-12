#!/bin/sh
# set -x
set -e

# GitHub Docker Action 把 with: 参数注入为 INPUT_*；
# CNB 流水线与直接 docker run 使用 PLUGIN_*。已有值优先，保持向后兼容。
: "${PLUGIN_TARGET_URL:=${INPUT_TARGET_URL:-}}"
: "${PLUGIN_AUTH_TYPE:=${INPUT_AUTH_TYPE:-}}"
: "${PLUGIN_USERNAME:=${INPUT_USERNAME:-}}"
: "${PLUGIN_PASSWORD:=${INPUT_PASSWORD:-}}"
: "${PLUGIN_SSH_KEY:=${INPUT_SSH_KEY:-}}"
: "${PLUGIN_BRANCH:=${INPUT_BRANCH:-}}"
: "${PLUGIN_FORCE:=${INPUT_FORCE:-}}"
: "${PLUGIN_PUSH_TAGS:=${INPUT_PUSH_TAGS:-}}"
: "${PLUGIN_GIT_USER:=${INPUT_GIT_USER:-}}"
: "${PLUGIN_GIT_EMAIL:=${INPUT_GIT_EMAIL:-}}"
: "${PLUGIN_GIT_HOST:=${INPUT_GIT_HOST:-}}"
: "${PLUGIN_SYNC_MODE:=${INPUT_SYNC_MODE:-}}"
: "${PLUGIN_FETCH_OPTIONS:=${INPUT_FETCH_OPTIONS:-}}"

# 检查必要的参数
if [ -z "$PLUGIN_TARGET_URL" ]; then
  echo "Error: TARGET_URL is required"
  exit 1
fi

if [ -z "$PLUGIN_AUTH_TYPE" ]; then
  PLUGIN_AUTH_TYPE="https"
fi

# 未知模式直接失败，避免静默退化成 push；布尔值只接受 true/false
case "${PLUGIN_SYNC_MODE:-push}" in
  push|rebase|pull) ;;
  *)
    echo "Error: Invalid sync_mode '$PLUGIN_SYNC_MODE'. Must be 'push', 'rebase' or 'pull'"
    exit 1
    ;;
esac
PLUGIN_SYNC_MODE="${PLUGIN_SYNC_MODE:-push}"

case "${PLUGIN_FORCE:-false}" in
  true|1)     FORCE_FLAG="--force" ;;
  false|0|'') FORCE_FLAG="" ;;
  *)
    echo "Error: Invalid force '$PLUGIN_FORCE'. Must be 'true' or 'false'"
    exit 1
    ;;
esac

case "${PLUGIN_PUSH_TAGS:-false}" in
  true|1)     PLUGIN_PUSH_TAGS="true" ;;
  false|0|'') PLUGIN_PUSH_TAGS="false" ;;
  *)
    echo "Error: Invalid push_tags '$PLUGIN_PUSH_TAGS'. Must be 'true' or 'false'"
    exit 1
    ;;
esac

setup_ssh() {
  echo "Creating .ssh directory..."
  # 确保 .ssh 目录存在
  mkdir -p $HOME/.ssh
  chmod 700 $HOME/.ssh

  # 如果提供了 SSH KEY，则配置它
  if [ ! -z "$PLUGIN_SSH_KEY" ]; then
    echo "Installing SSH key..."
    echo "$PLUGIN_SSH_KEY" > $HOME/.ssh/id_rsa
    chmod 600 $HOME/.ssh/id_rsa
  else
    echo "No SSH key provided!"
    exit 1
  fi

  echo "Adding known hosts..."
  if ssh-keyscan -H github.com >> $HOME/.ssh/known_hosts 2>/dev/null; then
    echo "Successfully added github.com to known_hosts"
  else
    echo "Warning: Failed to add github.com to known_hosts using ssh-keyscan"
  fi

  if ssh-keyscan -H gitlab.com >> $HOME/.ssh/known_hosts 2>/dev/null; then
    echo "Successfully added gitlab.com to known_hosts"
  else
    echo "Warning: Failed to add gitlab.com to known_hosts using ssh-keyscan"
  fi

  if ssh-keyscan -H cnb.cool >> $HOME/.ssh/known_hosts 2>/dev/null; then
    echo "Successfully added cnb.cool to known_hosts"
  else
    echo "Warning: Failed to add cnb.cool to known_hosts using ssh-keyscan"
  fi

  # 如果提供了自定义域名，也添加到 known_hosts
  if [ ! -z "$PLUGIN_GIT_HOST" ]; then
    echo "Adding custom git host: $PLUGIN_GIT_HOST"
    ssh-keyscan -H $PLUGIN_GIT_HOST >> $HOME/.ssh/known_hosts 2>/dev/null || echo "Failed to add $PLUGIN_GIT_HOST to known_hosts"
  fi
  chmod 600 $HOME/.ssh/known_hosts 2>/dev/null || true

  echo "SSH setup completed successfully"
}

setup_https() {
  if [ ! -z "$PLUGIN_USERNAME" ] && [ ! -z "$PLUGIN_PASSWORD" ]; then
    # 从 URL 中提取域名
    DOMAIN=$(echo "$PLUGIN_TARGET_URL" | sed -E 's/https?:\/\///' | cut -d'/' -f1)
    git config --global credential.helper store
    echo "https://$PLUGIN_USERNAME:$PLUGIN_PASSWORD@$DOMAIN" > $HOME/.git-credentials
    chmod 600 $HOME/.git-credentials
  fi
}

# 配置 Git
echo "Configuring Git..."
git config --global user.name "${PLUGIN_GIT_USER:-Git Sync}"
git config --global user.email "${PLUGIN_GIT_EMAIL:-git-sync@users.noreply.github.com}"

# 确保 Git LFS 被正确初始化
echo "Initializing Git LFS..."
git lfs install

# 添加工作目录到安全目录列表
git config --global --add safe.directory "$(pwd)"


# 检查是否使用了 Git LFS
HAS_LFS_FILES=$(git lfs ls-files 2>/dev/null | wc -l || echo "0")
if [ "$HAS_LFS_FILES" -gt 0 ]; then
  # 输出 LFS 文件列表
  echo "Git LFS files found:" $HAS_LFS_FILES
else
  echo "No Git LFS files found, skipping LFS operations"
fi

# 根据认证类型设置
echo "Setting up authentication type: $PLUGIN_AUTH_TYPE"
case "$PLUGIN_AUTH_TYPE" in
"ssh")
  echo "Setting up SSH authentication..."
  setup_ssh
  echo "SSH setup completed"
  ;;
"https")
  setup_https
  echo "HTTPS setup completed"
  ;;
*)
  echo "Error: Invalid auth type. Must be 'ssh' or 'https'"
  exit 1
  ;;
esac

# 添加远程仓库
echo "Setting up target remote repository..."
git remote add target "$PLUGIN_TARGET_URL" || true
git remote set-url target "$PLUGIN_TARGET_URL" || true
echo "Remote repositories:"
git remote -v

# GitHub Actions 的 checkout 默认只取触发分支，git push --all 推不出全部分支。
# 仅在 GitHub Actions 的全分支推送模式下补齐 origin 的远程引用。
PUSH_REFSPEC=""
if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$PLUGIN_SYNC_MODE" = "push" ] && [ -z "${PLUGIN_BRANCH:-}" ]; then
  echo "GitHub Actions detected: fetching all branches from origin..."
  if ! git fetch origin --prune ${PLUGIN_FETCH_OPTIONS:-} '+refs/heads/*:refs/remotes/origin/*'; then
    echo "Error: Failed to fetch all branches from origin"
    exit 1
  fi
  git update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
  PUSH_REFSPEC="refs/remotes/origin/*:refs/heads/*"
fi

if [ "$PLUGIN_PUSH_TAGS" = "true" ]; then
  echo "Fetching tags from origin to ensure local tags are available..."
  git fetch origin --tags --force ${PLUGIN_FETCH_OPTIONS:-} || echo "Warning: Failed to fetch tags from origin"
  echo "Local tags count: $(git tag -l | wc -l)"
fi

# 同步代码
if [ "$PLUGIN_SYNC_MODE" = "rebase" ]; then
  echo "Performing rebase sync with local staging..."

  # 保存当前目录
  SOURCE_DIR=$(pwd)
  SOURCE_GIT_DIR="$SOURCE_DIR/.git"

  # 添加源目录到安全目录列表
  git config --global --add safe.directory "$SOURCE_DIR"
  git config --global --add safe.directory "$SOURCE_GIT_DIR"

  # 创建临时目录作为工作区
  WORK_DIR=$(mktemp -d)
  echo "Created work directory: $WORK_DIR"

  # 创建临时裸仓库作为中转
  BARE_DIR=$(mktemp -d)
  echo "Created bare repository: $BARE_DIR"
  git init --bare $BARE_DIR

  # 设置目标仓库认证
  TARGET_REPO_URL="$PLUGIN_TARGET_URL"
  if [ "$PLUGIN_AUTH_TYPE" = "https" ] && [ ! -z "$PLUGIN_USERNAME" ] && [ ! -z "$PLUGIN_PASSWORD" ]; then
    # 提取域名并重构带认证的URL
    DOMAIN=$(echo "$PLUGIN_TARGET_URL" | sed -E 's/https?:\/\///' | cut -d'/' -f1)
    PATH_PART=$(echo "$PLUGIN_TARGET_URL" | sed -E 's/https?:\/\/[^\/]+//')
    TARGET_REPO_URL="https://$PLUGIN_USERNAME:$PLUGIN_PASSWORD@$DOMAIN$PATH_PART"
  fi

  # 克隆目标仓库到工作区
  echo "Cloning target repo..."
  cd $WORK_DIR
  if ! git clone "$TARGET_REPO_URL" .; then
    echo "Error: Failed to clone target repository"
    cd $SOURCE_DIR
    rm -rf $WORK_DIR $BARE_DIR
    exit 1
  fi

  # 添加工作目录到安全目录
  git config --global --add safe.directory "$WORK_DIR"

  # 添加源仓库和裸仓库作为远程仓库
  git remote add source "$SOURCE_DIR"
  git remote add staging "$BARE_DIR"

  # 确保 Git 配置在工作目录中也生效
  git config user.name "${PLUGIN_GIT_USER:-Git Sync}"
  git config user.email "${PLUGIN_GIT_EMAIL:-git-sync@users.noreply.github.com}"

  # 获取源仓库的更新（包含 tag）
  if ! git fetch source --tags ${PLUGIN_FETCH_OPTIONS:-}; then
    echo "Error: Failed to fetch from source repository"
    cd $SOURCE_DIR
    rm -rf $WORK_DIR $BARE_DIR
    exit 1
  fi

  # 获取所有分支并处理
  BRANCHES=$(git branch -r | grep "source/" | sed 's/source\///')

  # 检查是否有指定分支
  if [ ! -z "$PLUGIN_BRANCH" ]; then
    BRANCHES="$PLUGIN_BRANCH"
  fi

  # 在处理分支前添加一个变量跟踪成功的分支
  SUCCESSFUL_BRANCHES=""

  # 修改处理分支的部分
  for branch in $BRANCHES; do
    echo "Processing branch: $branch"
    git checkout $branch 2>/dev/null || git checkout -b $branch

    # 执行rebase
    if git rebase source/$branch; then
      # 推送到临时裸仓库
      git push staging $branch --force
      # 记录成功的分支
      SUCCESSFUL_BRANCHES="$SUCCESSFUL_BRANCHES $branch"
    else
      echo "Warning: Rebase failed for branch $branch, skipping"
      # 检查是否有rebase正在进行中，再尝试中止它
      git rebase --abort 2>/dev/null || true
    fi
  done

  # 处理LFS文件
  if [ "$HAS_LFS_FILES" -gt 0 ]; then
    echo "Handling LFS objects..."
    git lfs fetch source
    git lfs push staging --all || echo "Warning: Failed to push LFS objects to staging"
  fi

  # 处理标签
  if [ "$PLUGIN_PUSH_TAGS" = "true" ]; then
    echo "Pushing tags to staging"
    git push staging --tags --force
  fi

  # 修改推送部分
  echo "Pushing all changes from staging to target repository"
  cd $BARE_DIR

  # 添加目标仓库作为远程仓库
  git remote add target "$PLUGIN_TARGET_URL"

  # 只有当有成功rebase的分支时才推送
  if [ -n "$SUCCESSFUL_BRANCHES" ]; then
    # 推送所有成功的分支到目标仓库
    if [ -n "$PLUGIN_BRANCH" ]; then
      # 检查指定的分支是否在成功列表中
      if echo "$SUCCESSFUL_BRANCHES" | grep -q "$PLUGIN_BRANCH"; then
        git push target $PLUGIN_BRANCH --force
      else
        echo "Specified branch $PLUGIN_BRANCH was not successfully rebased, nothing to push"
      fi
    else
      # 逐个推送成功的分支
      for branch in $SUCCESSFUL_BRANCHES; do
        echo "Pushing successfully rebased branch: $branch"
        git push target $branch --force
      done

      if [ "$PLUGIN_PUSH_TAGS" = "true" ]; then
        git push target --tags --force
      fi
    fi
  else
    echo "Error: No branches were successfully rebased"
    REBASE_FAILED=1
  fi

  # 清理
  cd $SOURCE_DIR
  rm -rf $WORK_DIR $BARE_DIR
  if [ "${REBASE_FAILED:-0}" = "1" ]; then
    exit 1
  fi
  echo "Rebase sync completed successfully"
elif [ "$PLUGIN_SYNC_MODE" = "pull" ]; then
  echo "Performing pull sync from remote repository..."
  
  # 获取远程仓库的最新信息
  echo "Fetching from target repository..."
  if ! git fetch target ${PLUGIN_FETCH_OPTIONS:-}; then
    echo "Error: Failed to fetch from target repository"
    exit 1
  fi
  
  export GIT_LFS_SKIP_SMUDGE=1
  # 检查是否指定了特定分支
  if [ ! -z "$PLUGIN_BRANCH" ]; then
    echo "Processing specified branch: $PLUGIN_BRANCH"
    
    # 检查远程分支是否存在
    if ! git ls-remote --heads target "$PLUGIN_BRANCH" | grep -q "$PLUGIN_BRANCH"; then
      echo "Error: Branch $PLUGIN_BRANCH does not exist on remote repository"
      exit 1
    fi
    
    # 检查本地分支是否存在
    if git rev-parse --verify "$PLUGIN_BRANCH" >/dev/null 2>&1; then
      echo "Local branch $PLUGIN_BRANCH exists, switching to it..."
      git checkout "$PLUGIN_BRANCH"
    else
      echo "Creating and checking out new local branch $PLUGIN_BRANCH..."
      git checkout -b "$PLUGIN_BRANCH" "target/$PLUGIN_BRANCH"
    fi

    # 拉取并rebase远程分支
    echo "Pulling changes from target/$PLUGIN_BRANCH with rebase..."
    if ! git pull --rebase target "$PLUGIN_BRANCH"; then
      echo "Error: Failed to pull changes from target/$PLUGIN_BRANCH"
      echo "Rebase conflicts detected. You may need to resolve conflicts manually"
      echo "After resolving conflicts, run: git rebase --continue"
      exit 1
    fi
    
    if ! git lfs pull target; then
      echo "Warning: Failed to pull LFS objects"
    fi

    # 推送到 origin
    echo "Pushing changes to origin/$PLUGIN_BRANCH..."
    if ! git push origin "$PLUGIN_BRANCH" --force; then
      echo "Warning: Failed to push changes to origin/$PLUGIN_BRANCH"
      echo "This might be due to permission issues or network problems"
    fi
    
  else
    echo "Processing all branches from remote repository..."
    
    # 获取所有远程分支
    REMOTE_BRANCHES=$(git branch -r | grep "target/" | sed 's/target\///' | grep -v "HEAD")
    
    if [ -z "$REMOTE_BRANCHES" ]; then
      echo "No remote branches found"
      exit 1
    fi
    
    # 记录当前分支
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    
    # 处理每个远程分支
    for branch in $REMOTE_BRANCHES; do
      echo "Processing branch: $branch"
      
      # 检查本地分支是否存在
      if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo "Local branch $branch exists, switching and pulling with rebase..."
        git checkout "$branch"

        if ! git pull --rebase target "$branch"; then
          echo "Warning: Failed to pull changes for branch $branch with rebase, skipping..."
          echo "Branch $branch may have rebase conflicts that need manual resolution"
          continue
        fi

        if ! git lfs pull target; then
          echo "Warning: Failed to pull LFS objects"
        fi
        # 推送到 origin
        echo "Pushing changes to origin/$branch..."
        if ! git push origin "$branch" --force; then
          echo "Warning: Failed to push changes to origin/$branch"
        fi
      else
        echo "Creating new local branch $branch from target/$branch..."
        if ! git checkout -b "$branch" "target/$branch"; then
          echo "Warning: Failed to create branch $branch, skipping..."
          continue
        fi
        
        if ! git lfs pull target; then
          echo "Warning: Failed to pull LFS objects"
        fi
        # 推送新分支到 origin
        echo "Pushing new branch $branch to origin..."
        if ! git push origin "$branch" --force; then
          echo "Warning: Failed to push new branch $branch to origin"
        fi
      fi
    done
    
    # 回到原来的分支（如果它仍然存在）
    if git rev-parse --verify "$CURRENT_BRANCH" >/dev/null 2>&1; then
      echo "Returning to original branch: $CURRENT_BRANCH"
      git checkout "$CURRENT_BRANCH"
    fi
  fi
  
  # 处理标签（拉取并推送）
  if [ "$PLUGIN_PUSH_TAGS" = "true" ]; then
    echo "Fetching tags from target repository..."
    if ! git fetch target --tags ${PLUGIN_FETCH_OPTIONS:-}; then
        echo "Warning: Failed to fetch tags from target"
    fi
    echo "Pushing tags to origin..."
    if ! git push origin --tags --force; then
        echo "Warning: Failed to push tags to origin"
    fi
  fi
  
  echo "Pull from target and push to origin completed successfully"
else
  # 检查是否指定了特定分支
  if [ ! -z "$PLUGIN_BRANCH" ]; then
    echo "Checking if branch $PLUGIN_BRANCH exists locally..."
    SOURCE_REF="$PLUGIN_BRANCH"
    if ! git rev-parse --verify "$PLUGIN_BRANCH" >/dev/null 2>&1; then
      if ! git rev-parse --verify "refs/remotes/origin/$PLUGIN_BRANCH" >/dev/null 2>&1; then
        echo "Fetching branch $PLUGIN_BRANCH from origin..."
        git fetch origin "+refs/heads/$PLUGIN_BRANCH:refs/remotes/origin/$PLUGIN_BRANCH" || true
      fi
      if git rev-parse --verify "refs/remotes/origin/$PLUGIN_BRANCH" >/dev/null 2>&1; then
        SOURCE_REF="refs/remotes/origin/$PLUGIN_BRANCH:refs/heads/$PLUGIN_BRANCH"
      else
        echo "Error: Branch $PLUGIN_BRANCH does not exist locally or on origin"
        exit 1
      fi
    fi
    echo "Pushing specified branch: $PLUGIN_BRANCH"

    # 只在有 LFS 文件时推送 LFS 对象
    if [ "$HAS_LFS_FILES" -gt 0 ]; then
      echo "Pushing LFS objects for branch $PLUGIN_BRANCH..."
      if ! git lfs push target "$PLUGIN_BRANCH"; then
        echo "Warning: Failed to push LFS objects, continuing with regular push..."
      fi
    fi

    # 推送指定分支
    if ! git push target "$SOURCE_REF" $FORCE_FLAG; then
      echo "Error: Failed to push branch $PLUGIN_BRANCH"
      exit 1
    fi
  else
    echo "Pushing all branches"

    # 只在有 LFS 文件时推送 LFS 对象
    if [ "$HAS_LFS_FILES" -gt 0 ]; then
      echo "Pushing LFS objects..."
      if ! git lfs push target --all; then
        echo "Warning: Failed to push LFS objects, continuing with regular push..."
      fi
    fi

    if [ -n "$PUSH_REFSPEC" ]; then
      PUSH_TARGET="$PUSH_REFSPEC"
    else
      PUSH_TARGET="--all"
    fi
    if ! git push target "$PUSH_TARGET" $FORCE_FLAG; then
      echo "Error: Failed to push all branches"
      exit 1
    fi
  fi

  if [ "$PLUGIN_PUSH_TAGS" = "true" ]; then
    echo "Pushing tags"
    if ! git push target --tags $FORCE_FLAG; then
      echo "Error: Failed to push tags"
      exit 1
    fi
  fi
fi
