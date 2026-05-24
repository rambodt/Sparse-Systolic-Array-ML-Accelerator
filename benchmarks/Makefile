CC ?= gcc
CFLAGS ?= -O3 -Wall -Wextra -std=c11

.PHONY: all clean

all: cpu_matmul_bench cpu_rect_matmul_bench

cpu_matmul_bench: cpu_matmul_bench.c
	$(CC) $(CFLAGS) -o $@ $<

cpu_rect_matmul_bench: cpu_rect_matmul_bench.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f cpu_matmul_bench cpu_rect_matmul_bench
