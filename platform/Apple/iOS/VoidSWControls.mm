#import <UIKit/UIKit.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

extern "C" void EDuke32_IOS_GetRenderSize(int32_t *width, int32_t *height)
{
    CGRect const nativeBounds = UIScreen.mainScreen.nativeBounds;
    CGFloat const longEdge = fmax(CGRectGetWidth(nativeBounds), CGRectGetHeight(nativeBounds));
    CGFloat const shortEdge = fmin(CGRectGetWidth(nativeBounds), CGRectGetHeight(nativeBounds));
    CGFloat const scale = UIScreen.mainScreen.scale;

    // Preserve the exact device aspect ratio while keeping the 8-bit software
    // renderer at a practical resolution on larger iPads.
    // We use nativeBounds to get pixel dimensions, and scale the threshold accordingly.
    CGFloat const shortEdgeThreshold = 600.0 * scale;
    CGFloat const renderScale = shortEdge > shortEdgeThreshold ? shortEdgeThreshold / shortEdge : 1.0;
    *width = static_cast<int32_t>(floor(longEdge * renderScale)) & ~1;
    *height = static_cast<int32_t>(floor(shortEdge * renderScale)) & ~1;
}

extern "C" char *EDuke32_IOS_SelectGame(void)
{
    return strdup("SW.GRP");
}


#include "../../../source/mact/include/control.h"

void CONTROL_Android_ClearButton(int32_t button)
{
    (void)button;
}

void CONTROL_Android_PollDevices(ControlInfo *info)
{
    (void)info;
}

void CONTROL_Android_SetLastWeapon(int weapon)
{
    (void)weapon;
}

void CONTROL_Android_ScrollMap(int32_t *angle, int32_t *x, int32_t *y, uint16_t *zoom)
{
    (void)angle;
    (void)x;
    (void)y;
    (void)zoom;
}
