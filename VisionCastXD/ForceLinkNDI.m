#import "Processing.NDI.Lib.h"

void callNDISendCreate(void) {
    NDIlib_send_create_t settings = {0};
    NDIlib_send_create(&settings);
}

#import "Processing.NDI.Lib.h"

__attribute__((used))
static void force_link_ndi(void) {
    NDIlib_send_create(NULL);
}
