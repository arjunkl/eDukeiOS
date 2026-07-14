#ifndef EDUKE32_IOS_GL4ES_GLAD_SHIM_H
#define EDUKE32_IOS_GL4ES_GLAD_SHIM_H

// EDuke32 normally reaches desktop OpenGL through GLAD. For the iOS target,
// GL4ES exports that API and translates it to the SDL-created GLES2 context.
#include <GL/gl.h>

#endif
