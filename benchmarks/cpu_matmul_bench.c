#define _POSIX_C_SOURCE 199309L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_N 256

static uint8_t A[MAX_N][MAX_N];
static uint8_t B[MAX_N][MAX_N];
static uint32_t C[MAX_N][MAX_N];

static uint8_t dense_a(int r, int c) {
    return (uint8_t)(((r * 13 + c * 7 + 1) % 15) + 1);
}

static uint8_t dense_b(int r, int c) {
    return (uint8_t)(((r * 5 + c * 11 + 3) % 15) + 1);
}

static int make_sparse_zero(int r, int c, int pct) {
    int hash = (r * 131 + c * 17 + r * c * 7) % 100;
    return hash < pct;
}

static int parse_sparse_percent(const char *mode) {
    if (strcmp(mode, "dense") == 0) return 0;
    if (strcmp(mode, "sparse50") == 0) return 50;
    if (strcmp(mode, "sparse75") == 0) return 75;
    if (strcmp(mode, "sparse90") == 0) return 90;
    fprintf(stderr, "unsupported mode: %s\n", mode);
    exit(2);
}

static void init_matrices(int n, int sparse_percent) {
    for (int r = 0; r < n; r++) {
        for (int c = 0; c < n; c++) {
            A[r][c] = make_sparse_zero(r, c, sparse_percent) ? 0 : dense_a(r, c);
            B[r][c] = dense_b(r, c);
            C[r][c] = 0;
        }
    }
}

static void matmul_cpu(int n) {
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            uint32_t sum = 0;
            for (int k = 0; k < n; k++) {
                sum += (uint32_t)A[i][k] * (uint32_t)B[k][j];
            }
            C[i][j] = sum;
        }
    }
}

static uint64_t checksum(int n) {
    uint64_t s = 0;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            s += C[i][j];
        }
    }
    return s;
}

static double elapsed_seconds(struct timespec a, struct timespec b) {
    return (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) * 1.0e-9;
}

int main(int argc, char **argv) {
    int n = 64;
    int reps = 1;
    const char *mode = "dense";

    if (argc > 1) n = atoi(argv[1]);
    if (argc > 2) mode = argv[2];
    if (argc > 3) reps = atoi(argv[3]);

    if (n != 64 && n != 128 && n != 256) {
        fprintf(stderr, "N must be one of 64, 128, or 256\n");
        return 2;
    }
    if (reps < 1) {
        fprintf(stderr, "reps must be >= 1\n");
        return 2;
    }

    int sparse_percent = parse_sparse_percent(mode);
    init_matrices(n, sparse_percent);

    struct timespec t0;
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < reps; r++) {
        matmul_cpu(n);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double total_s = elapsed_seconds(t0, t1);
    double per_run_s = total_s / (double)reps;
    uint64_t macs = (uint64_t)n * (uint64_t)n * (uint64_t)n;
    uint64_t ops = 2 * macs;

    printf("CPU_RESULT status=PASS\n");
    printf("CPU_RESULT n=%d mode=%s reps=%d\n", n, mode, reps);
    printf("CPU_RESULT total_time_s=%.9f\n", total_s);
    printf("CPU_RESULT time_per_matmul_s=%.9f\n", per_run_s);
    printf("CPU_RESULT macs=%llu ops=%llu\n",
           (unsigned long long)macs, (unsigned long long)ops);
    printf("CPU_RESULT gmac_s=%.6f\n", (double)macs / per_run_s / 1.0e9);
    printf("CPU_RESULT gops_s=%.6f\n", (double)ops / per_run_s / 1.0e9);
    printf("CPU_RESULT checksum=%llu\n", (unsigned long long)checksum(n));

    return 0;
}
