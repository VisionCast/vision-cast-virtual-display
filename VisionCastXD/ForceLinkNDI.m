#import <Foundation/Foundation.h>
#include "Processing.NDI.Lib.h"

__attribute__((used)) static void *ndi_link_refs[] = {
    (void *)&NDIlib_initialize,
    (void *)&NDIlib_send_create,
    (void *)&NDIlib_send_destroy,
};
