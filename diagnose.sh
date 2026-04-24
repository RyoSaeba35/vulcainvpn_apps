#!/bin/bash

echo "🔍 VPN Changes Diagnostic Report"
echo "================================="
echo ""

echo "📋 Summary of Changes:"
echo "---------------------"
git diff --stat

echo ""
echo "🔍 Critical Areas:"
echo "---------------------------"

echo ""
echo "1️⃣ PACKAGE STRUCTURE"
if [ -d "android/app/src/main/kotlin/com/example/cross_platform_vpn" ]; then
    echo "   ⚠️  Files still in OLD location: com/example/cross_platform_vpn"
fi
if [ -d "android/app/src/main/kotlin/com/vulcainvpn/app" ]; then
    echo "   ✅ Files in NEW location: com/vulcainvpn/app"
fi

echo ""
echo "2️⃣ METHODCHANNEL - Checking for broken syntax"
echo "Flutter files:"
grep -rn "MethodChannel(com\.vulcainvpn\.app" lib/ 2>/dev/null | head -3 || echo "   ✅ No broken MethodChannel found"

echo ""
echo "3️⃣ PACKAGE NAMES in build.gradle.kts"
grep -E "namespace|applicationId" android/app/build.gradle.kts

echo ""
echo "4️⃣ Show actual changes in critical files:"
echo ""
echo "=== AndroidManifest.xml changes ==="
git diff android/app/src/main/AndroidManifest.xml | head -30

echo ""
echo "=== vpn_home_page.dart changes ==="
git diff lib/screens/vpn_home_page.dart | grep -A2 -B2 "MethodChannel" | head -20

