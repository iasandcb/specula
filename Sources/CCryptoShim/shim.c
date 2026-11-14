#include "CCryptoShim.h"

#if !defined(__APPLE__)
#include <openssl/evp.h>
#include <openssl/provider.h>
#include <string.h>

static void load_legacy_ciphers(void) {
    static int loaded = 0;
    if (loaded) return;
    loaded = 1;
    // OpenSSL 3 keeps single-DES in the legacy provider.
    OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER_load(NULL, "legacy");
}

CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                        const void *key, size_t keyLength, const void *iv,
                        const void *dataIn, size_t dataInLength,
                        void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved) {
    load_legacy_ciphers();
    const EVP_CIPHER *cipher = NULL;
    if (alg == kCCAlgorithmAES && keyLength == 16) cipher = EVP_aes_128_ecb();
    else if (alg == kCCAlgorithmDES && keyLength == 8) cipher = EVP_des_ecb();
    else return -1;
    if (dataIn == NULL || dataOut == NULL || dataInLength > dataOutAvailable) return -1;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -1;
    const unsigned char *ivec = (options & kCCOptionECBMode) ? NULL : iv;
    int ok = op == kCCDecrypt
        ? EVP_DecryptInit_ex(ctx, cipher, NULL, key, ivec)
        : EVP_EncryptInit_ex(ctx, cipher, NULL, key, ivec);
    if (ok) EVP_CIPHER_CTX_set_padding(ctx, (options & kCCOptionPKCS7Padding) ? 1 : 0);
    int outLen = 0, finalLen = 0;
    if (ok) {
        ok = op == kCCDecrypt
            ? EVP_DecryptUpdate(ctx, dataOut, &outLen, dataIn, (int)dataInLength)
            : EVP_EncryptUpdate(ctx, dataOut, &outLen, dataIn, (int)dataInLength);
    }
    if (ok) {
        unsigned char *finalOut = (unsigned char *)dataOut + outLen;
        ok = op == kCCDecrypt
            ? EVP_DecryptFinal_ex(ctx, finalOut, &finalLen)
            : EVP_EncryptFinal_ex(ctx, finalOut, &finalLen);
    }
    EVP_CIPHER_CTX_free(ctx);
    if (!ok || (size_t)(outLen + finalLen) > dataOutAvailable) return -1;
    if (dataOutMoved) *dataOutMoved = (size_t)(outLen + finalLen);
    return kCCSuccess;
}
#else
int c_crypto_shim_unused = 0;
#endif
