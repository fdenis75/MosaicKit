#include <metal_stdlib>
using namespace metal;

// Kernel for scaling images with high-quality filtering
// Uses bicubic-like interpolation for better downscaling quality
kernel void scaleTexture(texture2d<float, access::sample> inputTexture [[texture(0)]],
                         texture2d<float, access::write> outputTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    // Check if we're within the output texture bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Use Metal's built-in sampler with high-quality filtering
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     mip_filter::linear,
                                     address::clamp_to_edge,
                                     coord::normalized);

    // Calculate normalized coordinates (centered on pixel)
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 normalizedCoord = (float2(gid) + 0.5) / outputSize;

    // Sample with hardware-accelerated filtering
    float4 finalColor = inputTexture.sample(textureSampler, normalizedCoord);

    outputTexture.write(finalColor, gid);
}

// Kernel for compositing images onto a canvas
kernel void compositeTextures(texture2d<float, access::read> sourceTexture [[texture(0)]],
                              texture2d<float, access::read_write> destinationTexture [[texture(1)]],
                              constant uint2 *position [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    // Check if we're within the source texture bounds
    if (gid.x >= sourceTexture.get_width() || gid.y >= sourceTexture.get_height()) {
        return;
    }
    
    // Calculate destination position
    uint2 destPos = gid + *position;
    
    // Check if we're within the destination texture bounds
    if (destPos.x >= destinationTexture.get_width() || destPos.y >= destinationTexture.get_height()) {
        return;
    }
    
    // Read source and destination pixels
    float4 sourceColor = sourceTexture.read(gid);
    float4 destColor = destinationTexture.read(destPos);

    // Perform premultiplied alpha blending
    // Since textures use premultipliedFirst/Last format, colors are already premultiplied
    // Correct blending: result = source + dest * (1 - source.alpha)
    float4 blendedColor = sourceColor + destColor * (1.0 - sourceColor.a);

    // Write blended color to destination
    destinationTexture.write(blendedColor, destPos);
}

// Timestamp functionality is now handled directly in ThumbnailProcessor using CoreGraphics

// Kernel for filling a texture with a solid color
kernel void fillTexture(texture2d<float, access::write> texture [[texture(0)]],
                        constant float4 *color [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    // Check if we're within the texture bounds
    if (gid.x >= texture.get_width() || gid.y >= texture.get_height()) {
        return;
    }
    
    // Fill with color
    texture.write(*color, gid);
}

// Kernel for adding border to an image
kernel void addBorder(texture2d<float, access::read_write> texture [[texture(0)]],
                      constant uint2 *position [[buffer(0)]],
                      constant uint2 *size [[buffer(1)]],
                      constant float4 *borderColor [[buffer(2)]],
                      constant float *borderWidth [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // Check if we're within the texture bounds
    if (gid.x >= texture.get_width() || gid.y >= texture.get_height()) {
        return;
    }
    
    uint2 pos = *position;
    uint2 sz = *size;
    float width = *borderWidth;
    
    // Check if the pixel is on the border
    bool isBorder = false;
    
    if (gid.x >= pos.x && gid.x < (pos.x + sz.x) &&
        gid.y >= pos.y && gid.y < (pos.y + sz.y)) {
        
        float distanceFromLeft = float(gid.x - pos.x);
        float distanceFromRight = float(pos.x + sz.x - 1 - gid.x);
        float distanceFromTop = float(gid.y - pos.y);
        float distanceFromBottom = float(pos.y + sz.y - 1 - gid.y);
        
        isBorder = (distanceFromLeft < width || 
                   distanceFromRight < width || 
                   distanceFromTop < width || 
                   distanceFromBottom < width);
    }
    
    if (isBorder) {
        texture.write(*borderColor, gid);
    }
}

// Kernel for adding shadow effect
kernel void addShadow(texture2d<float, access::read> sourceTexture [[texture(0)]],
                      texture2d<float, access::write> outputTexture [[texture(1)]],
                      constant uint2 *position [[buffer(0)]],
                      constant uint2 *size [[buffer(1)]],
                      constant float4 *shadowColor [[buffer(2)]],
                      constant float2 *shadowOffset [[buffer(3)]],
                      constant float *shadowRadius [[buffer(4)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // Check if we're within the output texture bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    uint2 pos = *position;
    uint2 sz = *size;
    float2 offset = *shadowOffset;
    float radius = *shadowRadius;
    
    // Calculate shadow position
    uint2 shadowPos = uint2(pos.x + uint(offset.x), pos.y + uint(offset.y));
    
    // Check if the pixel is within the shadow area
    if (gid.x >= shadowPos.x && gid.x < (shadowPos.x + sz.x) &&
        gid.y >= shadowPos.y && gid.y < (shadowPos.y + sz.y)) {
        
        // Simple shadow implementation (without blur for now)
        outputTexture.write(*shadowColor, gid);
    }
    
    // Copy the source image on top of the shadow
    if (gid.x >= pos.x && gid.x < (pos.x + sz.x) &&
        gid.y >= pos.y && gid.y < (pos.y + sz.y)) {
        
        uint2 sourcePos = uint2(gid.x - pos.x, gid.y - pos.y);
        
        // Check if we're within the source texture bounds
        if (sourcePos.x < sourceTexture.get_width() && sourcePos.y < sourceTexture.get_height()) {
            float4 color = sourceTexture.read(sourcePos);
            outputTexture.write(color, gid);
        }
    }
} 
