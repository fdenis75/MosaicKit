#!/bin/bash

# MosaicKit Generator Comparison Test Runner
# Compares Metal vs Core Graphics performance on macOS

set -e

echo "🔬 MosaicKit Generator Comparison Test"
echo "========================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if video file exists
VIDEO_PATH="/Volumes/Ext-6TB-2/0002025/11/04/Kristy Black.mp4"
if [ ! -f "$VIDEO_PATH" ]; then
    echo "❌ Error: Video file not found at: $VIDEO_PATH"
    echo "Please update the video path in the test file."
    exit 1
fi

echo -e "${GREEN}✓${NC} Video file found"
echo ""

# Choose test to run
echo "Select test to run:"
echo "  1) Large Mosaic (10000px, High density) - ~5 min"
echo "  2) Extra Large Mosaic (15000px, XXL density) - ~15 min"
echo "  3) Multiple Density Comparison (Medium, High, XL) - ~20 min"
echo "  4) All tests - ~40 min"
echo ""
read -p "Enter choice (1-4): " choice

case $choice in
    1)
        TEST_NAME="GeneratorComparisonTests/testLargeMosaicComparison"
        echo -e "\n${BLUE}Running Large Mosaic Comparison...${NC}\n"
        ;;
    2)
        TEST_NAME="GeneratorComparisonTests/testExtraLargeMosaicComparison"
        echo -e "\n${BLUE}Running Extra Large Mosaic Comparison...${NC}\n"
        ;;
    3)
        TEST_NAME="GeneratorComparisonTests/testMultipleDensityComparison"
        echo -e "\n${BLUE}Running Multiple Density Comparison...${NC}\n"
        ;;
    4)
        TEST_NAME="GeneratorComparisonTests"
        echo -e "\n${BLUE}Running All Comparison Tests...${NC}\n"
        ;;
    *)
        echo "❌ Invalid choice"
        exit 1
        ;;
esac

# Run the test
swift test --filter $TEST_NAME 2>&1 | tee test_output.log

# Check if test passed
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ Tests completed successfully!${NC}"
    echo ""
    echo "📁 Output mosaics saved to separate directories:"
    echo "   Metal:         /tmp/MosaicKitTests/Metal/"
    echo "   Core Graphics: /tmp/MosaicKitTests/CoreGraphics/"
    echo "📄 Full log saved to: test_output.log"
    echo ""

    # Show where mosaics are
    METAL_DIR="/tmp/MosaicKitTests/Metal"
    CG_DIR="/tmp/MosaicKitTests/CoreGraphics"

    if [ -d "$METAL_DIR" ]; then
        echo "Metal mosaics:"
        ls -lh "$METAL_DIR"/*.heif 2>/dev/null | awk '{print "  • " $9 " - " $5}'
        echo ""
    fi

    if [ -d "$CG_DIR" ]; then
        echo "Core Graphics mosaics:"
        ls -lh "$CG_DIR"/*.heif 2>/dev/null | awk '{print "  • " $9 " - " $5}'
    fi
else
    echo ""
    echo -e "${YELLOW}⚠️  Tests encountered issues${NC}"
    echo "Check test_output.log for details"
    exit 1
fi

echo ""
echo "To view the mosaics:"
echo "  open /tmp/MosaicKitTests/Metal/"
echo "  open /tmp/MosaicKitTests/CoreGraphics/"
echo ""
echo "To compare side-by-side:"
echo "  open /tmp/MosaicKitTests/Metal/ /tmp/MosaicKitTests/CoreGraphics/"
echo ""
