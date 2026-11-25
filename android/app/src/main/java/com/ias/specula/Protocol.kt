package com.ias.specula

import java.io.*
import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.zip.Inflater
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

fun requireProtocol(ok: Boolean, message: String = "화면 데이터가 잘못되었습니다.") {
    if (!ok) throw IOException(message)
}

object Wire {
    fun packet(block: DataOutputStream.() -> Unit): ByteArray =
        ByteArrayOutputStream().also { DataOutputStream(it).block() }.toByteArray()

    fun key(symbol: Int, down: Boolean) = packet {
        writeByte(4)
        writeByte(if (down) 1 else 0)
        writeShort(0)
        writeInt(symbol)
    }

    fun pointer(x: Int, y: Int, buttons: Int) = packet {
        writeByte(5)
        writeByte(buttons)
        writeShort(x)
        writeShort(y)
    }

    val format = byteArrayOf(32, 24, 0, 1, 0, -1, 0, -1, 0, -1, 0, 8, 16, 0, 0, 0)
    val encodings = packet {
        writeByte(2)
        writeByte(0)
        writeShort(5)
        listOf(16, 1, 0, -223, -224).forEach { writeInt(it) }
    }

    fun challenge(challenge: ByteArray, password: String): ByteArray {
        val pass = password.toByteArray(Charsets.UTF_8)
        requireProtocol(
            challenge.size == 16 && pass.size in 1..8 && pass.all { it >= 0 },
            "VNC 암호는 영문·숫자·기호 1~8자로 입력해 주세요.",
        )
        val key =
            pass
                .copyOf(8)
                .map { Integer.reverse(it.toInt() and 255).ushr(24).toByte() }
                .toByteArray()
        return Cipher.getInstance("DES/ECB/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "DES"))
            doFinal(challenge)
        }
    }
}

object ARD {
    private val random = SecureRandom()

    fun padded(value: BigInteger, length: Int): ByteArray {
        val bytes = value.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
        requireProtocol(bytes.size <= length, "인증 키의 크기가 잘못되었습니다.")
        return ByteArray(length - bytes.size) + bytes
    }

    fun credentials(username: String, password: String, padding: ByteArray): ByteArray {
        val user = username.toByteArray()
        val pass = password.toByteArray()
        requireProtocol(
            user.size in 1..63 &&
                pass.size in 1..63 &&
                0.toByte() !in user &&
                0.toByte() !in pass &&
                padding.size == 128,
            "맥 사용자 이름과 암호는 각각 UTF-8 63바이트 이내로 입력해 주세요.",
        )
        return padding.copyOf().also {
            user.copyInto(it)
            it[user.size] = 0
            pass.copyInto(it, 64)
            it[64 + pass.size] = 0
        }
    }

    fun response(
        generator: Int,
        modulus: ByteArray,
        peer: ByteArray,
        username: String,
        password: String,
        entropy: ByteArray = ByteArray(32).also(random::nextBytes),
        padding: ByteArray = ByteArray(128).also(random::nextBytes),
    ): ByteArray {
        val block = credentials(username, password, padding)
        val p = BigInteger(1, modulus)
        val g = BigInteger.valueOf(generator.toLong())
        val server = BigInteger(1, peer)
        requireProtocol(
            modulus.size in 128..512 &&
                peer.size == modulus.size &&
                p.bitLength() >= 1024 &&
                p.testBit(0) &&
                g > BigInteger.ONE &&
                g < p - BigInteger.ONE &&
                server > BigInteger.ONE &&
                server < p - BigInteger.ONE,
            "맥이 보낸 계정 인증 키가 올바르지 않습니다.",
        )
        val hash =
            MessageDigest.getInstance("SHA-256").digest(modulus).joinToString("") {
                "%02x".format(it)
            }
        requireProtocol(
            hash == "4ee95187682bcb230ad26a95205f6920e84708f6251b3894329b09ec23919e33" ||
                p.isProbablePrime(16),
            "맥이 보낸 인증 소수가 올바르지 않습니다.",
        )
        val exponent = BigInteger(1, entropy) + BigInteger.valueOf(2)
        val publicKey = g.modPow(exponent, p)
        val secret = server.modPow(exponent, p)
        requireProtocol(publicKey > BigInteger.ONE && secret > BigInteger.ONE, "맥 인증 키 교환에 실패했습니다.")
        val key = MessageDigest.getInstance("MD5").digest(padded(secret, modulus.size))
        return Cipher.getInstance("AES/ECB/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
            doFinal(block)
        } + padded(publicKey, modulus.size)
    }
}

object FrameLimits {
    fun valid(w: Int, h: Int) = w in 1..8192 && h in 1..8192 && w.toLong() * h <= 6016L * 3384

    fun check(w: Int, h: Int) = requireProtocol(valid(w, h), "지원 가능한 화면 크기를 초과했습니다.")

    fun plain(w: Int, h: Int): Int {
        check(w, h)
        return w * h * 4 + ((w + 63) / 64) * ((h + 63) / 64)
    }

    fun compressed(w: Int, h: Int) = plain(w, h) + 1024
}

/** A connection owns one inflater AND one palette decoder, including macOS palette reuse. */
class ZRLE : Closeable {
    private val inflater = Inflater()
    private var palette = emptyList<ByteArray>()

    fun inflate(bytes: ByteArray, cap: Int): ByteArray {
        requireProtocol(inflater.needsInput(), "압축 스트림이 맞지 않습니다.")
        inflater.setInput(bytes)
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16384)
        while (!inflater.finished()) {
            val n = inflater.inflate(buffer)
            requireProtocol(out.size().toLong() + n <= cap, "화면 압축 크기가 잘못되었습니다.")
            out.write(buffer, 0, n)
            if (n == 0) {
                requireProtocol(inflater.needsInput() || inflater.finished(), "화면 압축을 풀지 못했습니다.")
                break
            }
        }
        requireProtocol(inflater.remaining == 0, "화면 압축 데이터가 남았습니다.")
        return out.toByteArray()
    }

    fun compressed(w: Int, h: Int, bytes: ByteArray): ByteArray {
        requireProtocol(bytes.size in 1..FrameLimits.compressed(w, h), "화면 압축 크기가 잘못되었습니다.")
        return decode(w, h, inflate(bytes, FrameLimits.plain(w, h)))
    }

    fun decode(w: Int, h: Int, bytes: ByteArray): ByteArray {
        FrameLimits.check(w, h)
        val input = DataInputStream(ByteArrayInputStream(bytes))
        val pixels = ByteArray(w * h * 4)
        fun pixel() = ByteArray(3).also(input::readFully)
        fun run(limit: Int): Int {
            var n = 1
            do {
                val b = input.readUnsignedByte()
                requireProtocol(n <= limit - b, "화면 압축의 반복 길이가 잘못되었습니다.")
                n += b
            } while (b == 255)
            return n
        }
        for (ty in 0 until h step 64) for (tx in 0 until w step 64) {
            val tw = minOf(64, w - tx)
            val th = minOf(64, h - ty)
            val count = tw * th
            fun paint(i: Int, p: ByteArray) {
                val at = ((ty + i / tw) * w + tx + i % tw) * 4
                p.copyInto(pixels, at)
                pixels[at + 3] = -1
            }
            val sub = input.readUnsignedByte()
            when {
                sub == 0 -> repeat(count) { paint(it, pixel()) }
                sub == 1 -> {
                    val p = pixel()
                    repeat(count) { paint(it, p) }
                }
                sub in 2..16 || sub == 127 -> {
                    if (sub != 127) palette = List(sub) { pixel() }
                    requireProtocol(palette.size in 2..16, "재사용할 ZRLE 팔레트가 없습니다.")
                    val bits = if (palette.size <= 2) 1 else if (palette.size <= 4) 2 else 4
                    repeat(th) { row ->
                        var left = 0
                        var value = 0
                        repeat(tw) { col ->
                            if (left < bits) {
                                value = input.readUnsignedByte()
                                left = 8
                            }
                            left -= bits
                            val index = (value shr left) and ((1 shl bits) - 1)
                            requireProtocol(index < palette.size, "화면 압축 팔레트가 잘못되었습니다.")
                            paint(row * tw + col, palette[index])
                        }
                    }
                }
                sub >= 128 -> {
                    if (sub >= 130) palette = List(sub - 128) { pixel() }
                    if (sub != 128) requireProtocol(palette.isNotEmpty(), "재사용할 ZRLE 팔레트가 없습니다.")
                    var written = 0
                    while (written < count) {
                        val p: ByteArray
                        val n: Int
                        if (sub == 128) {
                            p = pixel()
                            n = run(count - written)
                        } else {
                            val marker = input.readUnsignedByte()
                            val index = marker and 127
                            requireProtocol(index < palette.size, "화면 압축 팔레트가 잘못되었습니다.")
                            p = palette[index]
                            n = if (marker < 128) 1 else run(count - written)
                        }
                        repeat(n) { paint(written + it, p) }
                        written += n
                    }
                }
                else -> throw IOException("지원하지 않는 ZRLE 타일입니다: $sub")
            }
        }
        requireProtocol(input.available() == 0, "화면 압축 데이터가 남았습니다.")
        return pixels
    }

    override fun close() = inflater.end()
}
