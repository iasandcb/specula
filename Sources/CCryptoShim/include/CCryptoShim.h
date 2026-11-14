#pragma once
#include <stddef.h>
#include <stdint.h>

// Enough of CommonCrypto for the VNC and ARD tests on Linux.
// The iOS app imports the system CommonCrypto module instead.
typedef uint32_t CCOperation;
typedef uint32_t CCAlgorithm;
typedef uint32_t CCOptions;
typedef int32_t CCCryptorStatus;

#define kCCEncrypt 0u
#define kCCDecrypt 1u
#define kCCAlgorithmAES 0u
#define kCCAlgorithmDES 1u
#define kCCOptionPKCS7Padding 1u
#define kCCOptionECBMode 2u
#define kCCSuccess 0

CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                        const void *key, size_t keyLength, const void *iv,
                        const void *dataIn, size_t dataInLength,
                        void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved);
