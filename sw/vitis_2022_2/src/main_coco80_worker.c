#include "coco80_multicore.h"

#include "xil_cache.h"

#ifndef C8_WORKER_ID
#error C8_WORKER_ID must select A53 worker 1, 2, or 3
#endif

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    coco80_mc_worker_loop(C8_WORKER_ID);
    return 0;
}
