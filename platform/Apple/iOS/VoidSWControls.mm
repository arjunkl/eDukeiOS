#import <UIKit/UIKit.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

extern "C" void EDuke32_IOS_GetRenderSize(int32_t *width, int32_t *height)
{
    CGRect const bounds = UIScreen.mainScreen.bounds;
    CGFloat const longEdge = fmax(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat const shortEdge = fmin(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat const renderScale = shortEdge > 600.0 ? 600.0 / shortEdge : 1.0;
    *width = static_cast<int32_t>(floor(longEdge * renderScale)) & ~1;
    *height = static_cast<int32_t>(floor(shortEdge * renderScale)) & ~1;
}

extern "C" int EDuke32_IOS_WantsPolymost(void)
{
    return 0;
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
