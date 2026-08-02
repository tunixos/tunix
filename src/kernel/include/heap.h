#ifndef HEAP_H
#define HEAP_H

#include <stdint.h>
#include <stddef.h>

void heap_init(void);
void* kmalloc(size_t size);
void kfree(void* ptr);

/* True once the heap is close enough to its ceiling that the next large
   allocation is likely to fail. The heap never hands pages back to the PMM, so
   this is the only warning anything gets before kmalloc starts returning NULL
   and processes stop being able to start. */
int heap_under_pressure(void);

#endif
