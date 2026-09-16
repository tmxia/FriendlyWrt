#!/bin/bash
set -e

source_code_platforms=(openwrt)

openwrt_value='{
  "REPO_URL": "https://github.com/openwrt/openwrt.git",
  "REPO_BRANCH": "openwrt-25.12",
  "CONFIG_FILE": "scripts/r5s.config",
  "DIY_SH": "scripts/diy.sh",
  "OS": "ubuntu-latest"
}'

openwrt_platforms=(r5s)

matrix_json="["
for source_platform in "${source_code_platforms[@]}"; do
  platforms_var="${source_platform}_platforms[@]"
  platforms=("${!platforms_var}")
  value_var="${source_platform}_value"
  value="${!value_var}"

  for platform in "${platforms[@]}"; do
    matrix_json+="{\"source_code_platform\":\"${source_platform}\",\"platform\":\"${platform}\",\"value\":${value}},"
  done
done

matrix_json="${matrix_json%,}]"
echo "matrix=$matrix_json" >> "$GITHUB_OUTPUT"