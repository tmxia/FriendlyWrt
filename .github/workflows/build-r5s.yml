name: Build OpenWrt for NanoPi R5S

on:
  watch:
    types: started
  workflow_dispatch:
    inputs:
      replace_existing:
        description: 'Replace existing release tag (overwrite)'
        required: false
        default: 'true'
        type: choice
        options:
          - 'false'
          - 'true'

env:
  AUTO_REPLACE_TAG: 'false'
  OPENWRT_BRANCH: 'openwrt-25.12'
  FLAVOR: 'r5s'

jobs:
  prepare_release:
    runs-on: ubuntu-22.04
    if: github.event.repository.owner.id == github.event.sender.id
    outputs:
      release_tag: ${{ steps.release_tag.outputs.tag }}
      upload_url: ${{ steps.release.outputs.upload_url }}
    steps:
      - name: Generate unique release tag
        id: release_tag
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          BASE_TAG="OpenWrt-R5S-$(date +%Y-%m-%d)"
          FORCE_BASE=false
          if [ "${{ github.event_name }}" == "workflow_dispatch" ] && [ "${{ github.event.inputs.replace_existing }}" == "true" ]; then
            FORCE_BASE=true
          elif [ "${{ github.event_name }}" == "watch" ] && [ "${{ env.AUTO_REPLACE_TAG }}" == "true" ]; then
            FORCE_BASE=true
          fi

          if [ "$FORCE_BASE" = "true" ]; then
            EXISTING_TAGS=$(gh release list --limit 100 --repo "$GITHUB_REPOSITORY" --json tagName --jq '.[].tagName' | grep -E "^${BASE_TAG}(-[0-9]+)?$" || true)
            for tag in $EXISTING_TAGS; do
              gh release delete "$tag" --yes --repo "$GITHUB_REPOSITORY" || true
              git push origin --delete "refs/tags/$tag" || true
            done
            TAG="$BASE_TAG"
          else
            EXISTING_TAGS=$(gh release list --limit 100 --repo "$GITHUB_REPOSITORY" --json tagName --jq '.[].tagName' | grep -E "^${BASE_TAG}(-[0-9]+)?$" || true)
            if [ -z "$EXISTING_TAGS" ]; then
              TAG="$BASE_TAG"
            else
              MAX_NUM=0
              for t in $EXISTING_TAGS; do
                if [[ $t =~ ^${BASE_TAG}-([0-9]+)$ ]]; then
                  NUM=${BASH_REMATCH[1]}
                  [ $NUM -gt $MAX_NUM ] && MAX_NUM=$NUM
                fi
              done
              TAG="${BASE_TAG}-$((MAX_NUM + 1))"
            fi
          fi
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "Release tag: $TAG"

      - name: Create or update release
        id: release
        uses: softprops/action-gh-release@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tag_name: ${{ steps.release_tag.outputs.tag }}
          draft: false
          prerelease: false
          allow_updates: true
          overwrite: true

  build:
    needs: prepare_release
    runs-on: ubuntu-22.04
    if: github.event.repository.owner.id == github.event.sender.id
    steps:
    - name: Checkout
      uses: actions/checkout@v4

    - name: Initialization environment
      env:
        DEBIAN_FRONTEND: noninteractive
      run: |
        sudo apt-get update -qq
        sudo apt-get install -y -qq build-essential clang flex bison g++ gawk \
          gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
          python3 python3-distutils python3-setuptools rsync unzip zlib1g-dev \
          file wget subversion libelf-dev ecj fastjar swig time xsltproc zip
        sudo update-alternatives --install /usr/bin/python python /usr/bin/python3 1 || true
        mkdir -p ./artifact
        echo "CPU cores: $(nproc)"

    - name: Prepare FriendlyWrt-style workspace using OpenWrt official source
      run: |
        mkdir -p project
        cd project
        git clone --depth 1 -b ${{ env.OPENWRT_BRANCH }} \
          https://github.com/openwrt/openwrt.git friendlywrt > /dev/null 2>&1
        # 让 OpenWrt 使用 FriendlyWrt 风格的配置文件
        cd friendlywrt
        cp feeds.conf.default feeds.conf
        ./scripts/feeds update -a > /dev/null 2>&1
        ./scripts/feeds install -a > /dev/null 2>&1
        cd ..
        # 创建 FriendlyWrt 风格的 configs 目录（脚本会向其追加内容）
        mkdir -p configs/rockchip
        touch configs/rockchip/01-nanopi
        echo "Workspace prepared with OpenWrt ${{ env.OPENWRT_BRANCH }}"

    - name: Initialize .config with R5S target
      run: |
        cd project/friendlywrt
        cat > .config <<'EOF'
        CONFIG_TARGET_rockchip=y
        CONFIG_TARGET_rockchip_armv8=y
        CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
        CONFIG_LUCI_LANG_zh_Hans=y
        EOF
        make defconfig > /dev/null 2>&1
        echo "Initial .config created"

    - name: Verify upstream kernel version (must be 6.12)
      run: |
        cd project/friendlywrt
        KV=$(grep '^KERNEL_PATCHVER' target/linux/rockchip/Makefile | awk '{print $3}')
        echo "OpenWrt Rockchip target KERNEL_PATCHVER = $KV"
        if [ "$KV" != "6.12" ]; then
          echo "ERROR: expected 6.12 kernel, got $KV"
          exit 1
        fi
        test -f target/linux/rockchip/config-6.12 && echo "config-6.12 present"

    - name: Apply customizations (original script, unmodified)
      run: |
        cd project
        bash ../scripts/add_packages.sh

    - name: Final config check
      run: |
        cd project/friendlywrt
        echo "--- Clashoo packages ---"
        grep -E "CONFIG_PACKAGE_(clashoo|luci-app-clashoo|luci-i18n-clashoo-zh-cn|kmod-inet-diag)=y" .config || true
        echo "--- Kernel INET_DIAG ---"
        grep -E "CONFIG_INET_DIAG|CONFIG_INET_TCP_DIAG|CONFIG_INET_UDP_DIAG|CONFIG_INET_RAW_DIAG" target/linux/rockchip/config-6.12 || true

    - name: Download packages
      run: |
        cd project/friendlywrt
        make download -j$(nproc) > /dev/null 2>&1
        echo "Package download completed"

    - name: Compile OpenWrt
      run: |
        cd project/friendlywrt
        make -j$(nproc) > /dev/null 2>&1
        echo "Compile finished"

    - name: Collect artifacts
      run: |
        cd project/friendlywrt
        ls -lh bin/targets/rockchip/armv8/ | head -30
        find bin/targets/rockchip/armv8/ -maxdepth 1 -type f \
          \( -name "*nanopi-r5s*.img.gz" -o -name "*nanopi-r5s*.manifest" \
             -o -name "*nanopi-r5s*.tar.gz" \) \
          -exec cp {} ../../artifact/ \;
        echo "--- Collected artifacts ---"
        ls -lh ../../artifact/

    - name: Upload artifacts to release
      uses: svenstaro/upload-release-action@v2
      with:
        repo_token: ${{ secrets.GITHUB_TOKEN }}
        file: ./artifact/*
        tag: ${{ needs.prepare_release.outputs.release_tag }}
        overwrite: true
        file_glob: true

  cleanup_self:
    name: Cleanup Self Workflow History
    runs-on: ubuntu-latest
    needs: [prepare_release, build]
    if: ${{ always() }}
    permissions:
      actions: write
      contents: read
    steps:
      - name: Delete old workflow runs
        uses: Mattraks/delete-workflow-runs@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          keep_minimum_runs: 0
          retain_days: 0
          delete_workflow_pattern: "Build OpenWrt for NanoPi R5S"
          repository: ${{ github.repository }}