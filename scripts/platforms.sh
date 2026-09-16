#!/bin/bash
# R5S 专用构建矩阵 - 仅保留 openwrt 平台和 R5S 设备

source_code_platforms=(openwrt)

openwrt_value='{
  "REPO_URL": "https://github.com/openwrt/openwrt.git",
  "REPO_BRANCH": "openwrt-25.12",
  "CONFIGS": "config/openwrt_config",
  "DIY_P1_SH": "diy_script/openwrt_diy/diy-part1.sh",
  "DIY_P2_SH": "diy_script/openwrt_diy/diy-part2.sh",
  "OS": "ubuntu-latest"
}'

openwrt_platforms=(R5S)

matrix_json="["
source_matrix_json="["

for source_platform in "${source_code_platforms[@]}"; do
  platforms_var="${source_platform}_platforms[@]"
  platforms=("${!platforms_var}")
  value_var="${source_platform}_value"
  value="${!value_var}"

  source_matrix_json+="{\"source_code_platform\":\"${source_platform}\",\"value\":${value}},"
  for platform in "${platforms[@]}"; do
    matrix_json+="{\"source_code_platform\":\"${source_platform}\",\"platform\":\"${platform}\",\"value\":${value}},"
  done
done

matrix_json="${matrix_json%,}]"
source_matrix_json="${source_matrix_json%,}]"

COMPRESSED_MATRIX=$(echo "$matrix_json" | jq -c .)
COMPRESSED_SOURCE=$(echo "$source_matrix_json" | jq -c .)

echo "=== Matrix JSON ==="
echo "$COMPRESSED_MATRIX" | jq .
echo "=== Source Matrix JSON ==="
echo "$COMPRESSED_SOURCE" | jq .

echo "matrix=$COMPRESSED_MATRIX" >> $GITHUB_OUTPUT
echo "source_matrix_json=$COMPRESSED_SOURCE" >> $GITHUB_OUTPUT