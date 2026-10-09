#pragma once
#include <TargetConditionals.h>
#if TARGET_OS_WATCH
// watchOS SDK sysctl headers refer to these hidden BSD aliases.
typedef unsigned int u_int;
typedef unsigned char u_char;
typedef unsigned short u_short;
#endif
