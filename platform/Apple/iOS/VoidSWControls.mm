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

extern "C" char *EDuke32_IOS_SelectGame(void)
{
    return strdup("SW.GRP");
}
